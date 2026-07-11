import AppKit
import ApplicationServices

struct TextSelection {
    let text: String
    let anchor: Anchor
    let pointer: NSPoint

    enum Anchor {
        case accessibilityBounds(CGRect)
        case pointer(NSPoint)
    }
}

final class SelectionTracker: NSObject {
    var onSelection: ((TextSelection) -> Void)?

    private var mouseUpMonitor: Any?
    private var mouseDownLocation: NSPoint?
    private var lastPointer = NSEvent.mouseLocation
    private var lastSelectionSignature = ""
    private var lastSelectionTime = Date.distantPast
    private var clipboardSnapshot: [NSPasteboardItem]?
    private var clipboardChangeCount = 0
    private(set) var isRunning = false

    private var clipboardFallbackIsEnabled: Bool {
        ProcessInfo.processInfo.environment["TINTAP_CLIPBOARD_FALLBACK"] != "0"
    }

    func start() {
        guard !isRunning else { return }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self else { return }

            if event.type == .leftMouseDown {
                self.mouseDownLocation = NSEvent.mouseLocation
                return
            }

            // The target app updates its accessibility selection just after mouse-up.
            self.lastPointer = NSEvent.mouseLocation
            guard self.isLikelySelectionGesture(event) else { return }
            self.perform(#selector(Self.readCurrentSelection), with: nil, afterDelay: 0.08)
        }
        isRunning = true
        DebugLogger.log("Global mouse-up monitor installed.")
    }

    func stop() {
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
        }
        mouseUpMonitor = nil
        isRunning = false
    }

    @objc private func readCurrentSelection() {
        let systemWide = AXUIElementCreateSystemWide()
        guard let focusedValue = copyAttribute(kAXFocusedUIElementAttribute, from: systemWide),
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            DebugLogger.log("No accessibility focused element.")
            beginClipboardFallback(for: nil)
            return
        }
        let focusedElement = unsafeDowncast(focusedValue, to: AXUIElement.self)

        guard let rawText = copyAttribute(kAXSelectedTextAttribute, from: focusedElement) as? String else {
            DebugLogger.log("Focused element does not expose AXSelectedText.")
            beginClipboardFallback(for: focusedElement)
            return
        }

        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            DebugLogger.log("Selection is empty.")
            beginClipboardFallback(for: focusedElement)
            return
        }

        guard let rangeValueReference = copyAttribute(kAXSelectedTextRangeAttribute, from: focusedElement),
              CFGetTypeID(rangeValueReference) == AXValueGetTypeID() else {
            DebugLogger.log("Focused element does not expose AXSelectedTextRange; using pointer anchor.")
            emit(text: text, anchor: .pointer(lastPointer), source: "Accessibility text + pointer")
            return
        }
        let rangeValue = unsafeDowncast(rangeValueReference, to: AXValue.self)

        guard let boundsValue = copyBounds(for: rangeValue, in: focusedElement),
              AXValueGetType(boundsValue) == .cgRect else {
            DebugLogger.log("Focused element does not expose bounds for the selected range; using pointer anchor.")
            emit(text: text, anchor: .pointer(lastPointer), source: "Accessibility text + pointer")
            return
        }

        var bounds = CGRect.zero
        AXValueGetValue(boundsValue, .cgRect, &bounds)
        guard !bounds.isEmpty else {
            DebugLogger.log("Selection bounds are empty; using pointer anchor.")
            emit(text: text, anchor: .pointer(lastPointer), source: "Accessibility text + pointer")
            return
        }

        emit(text: text, anchor: .accessibilityBounds(bounds), source: "Accessibility")
    }

    private func emit(text: String, anchor: TextSelection.Anchor, source: String) {
        let signature: String
        switch anchor {
        case let .accessibilityBounds(bounds):
            signature = "\(text)|\(bounds)"
        case let .pointer(point):
            signature = "\(text)|\(point)"
        }

        // Some apps deliver two mouse-up events. A short debounce prevents flicker but allows reselecting the same text.
        let now = Date()
        guard signature != lastSelectionSignature || now.timeIntervalSince(lastSelectionTime) > 0.4 else {
            DebugLogger.log("Ignoring duplicate selection event.")
            return
        }
        lastSelectionSignature = signature
        lastSelectionTime = now
        DebugLogger.log("Selection from \(source): \(text.prefix(80))")
        onSelection?(TextSelection(text: text, anchor: anchor, pointer: lastPointer))
    }

    private func beginClipboardFallback(for focusedElement: AXUIElement?) {
        guard clipboardFallbackIsEnabled else {
            DebugLogger.log("Clipboard fallback is disabled (TINTAP_CLIPBOARD_FALLBACK=0).")
            return
        }

        if let focusedElement,
           let role = copyAttribute(kAXRoleAttribute, from: focusedElement) as? String,
           role == "AXSecureTextField" {
            DebugLogger.log("Skipping clipboard fallback for a secure text field.")
            return
        }

        let pasteboard = NSPasteboard.general
        clipboardSnapshot = snapshot(of: pasteboard)
        clipboardChangeCount = pasteboard.changeCount

        guard postCopyShortcut() else {
            DebugLogger.log("Could not post Command-C for clipboard fallback.")
            clipboardSnapshot = nil
            return
        }

        DebugLogger.log("AXSelectedText unavailable; trying clipboard fallback.")
        perform(#selector(Self.readClipboardFallback), with: nil, afterDelay: 0.12)
    }

    @objc private func readClipboardFallback() {
        let pasteboard = NSPasteboard.general
        defer {
            restoreClipboard()
        }

        guard pasteboard.changeCount != clipboardChangeCount else {
            DebugLogger.log("Clipboard did not change after Command-C.")
            return
        }

        guard let rawText = pasteboard.string(forType: .string) else {
            DebugLogger.log("Clipboard fallback produced no text.")
            return
        }

        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            DebugLogger.log("Clipboard fallback produced empty text.")
            return
        }

        emit(text: text, anchor: .pointer(lastPointer), source: "Clipboard fallback")
    }

    private func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private func restoreClipboard() {
        defer { clipboardSnapshot = nil }
        guard let clipboardSnapshot else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !clipboardSnapshot.isEmpty {
            pasteboard.writeObjects(clipboardSnapshot)
        }
        DebugLogger.log("Restored clipboard after fallback.")
    }

    private func postCopyShortcut() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        // kVK_ANSI_C. Keeping the literal avoids taking a Carbon dependency for one key code.
        let copyKeyCode: CGKeyCode = 8
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: copyKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: copyKeyCode, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func isLikelySelectionGesture(_ event: NSEvent) -> Bool {
        if event.clickCount > 1 {
            return true
        }
        guard let mouseDownLocation else {
            return false
        }
        return hypot(lastPointer.x - mouseDownLocation.x, lastPointer.y - mouseDownLocation.y) >= 3
    }

    private func copyAttribute(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }
        return value
    }

    private func copyBounds(for range: AXValue, in element: AXUIElement) -> AXValue? {
        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            range,
            &value
        )
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXValue.self)
    }
}
