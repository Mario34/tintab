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
    private var selectionReadWorkItem: DispatchWorkItem?
    private var clipboardReadWorkItem: DispatchWorkItem?
    private var selectionEmissionWorkItem: DispatchWorkItem?
    private var latestSelectionRequestID = 0
    private var activeClipboardFallbackRequestID: Int?
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
                self.cancelPendingSelectionWork(shouldRestoreClipboard: true)
                self.mouseDownLocation = NSEvent.mouseLocation
                return
            }

            // The target app updates its accessibility selection just after mouse-up.
            self.lastPointer = NSEvent.mouseLocation
            defer { self.mouseDownLocation = nil }
            guard self.isLikelySelectionGesture(event) else { return }
            self.scheduleSelectionRead(pointer: self.lastPointer)
        }
        isRunning = true
        DebugLogger.log("Global mouse-up monitor installed.")
    }

    func stop() {
        cancelPendingSelectionWork(shouldRestoreClipboard: true)
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
        }
        mouseUpMonitor = nil
        isRunning = false
    }

    private func scheduleSelectionRead(pointer: NSPoint) {
        cancelPendingSelectionWork(shouldRestoreClipboard: true)
        latestSelectionRequestID += 1
        let requestID = latestSelectionRequestID
        let workItem = DispatchWorkItem { [weak self] in
            self?.readCurrentSelection(requestID: requestID, pointer: pointer)
        }
        selectionReadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    private func readCurrentSelection(requestID: Int, pointer: NSPoint) {
        guard isRunning, requestID == latestSelectionRequestID else {
            DebugLogger.log("Ignoring stale accessibility selection read.")
            return
        }
        selectionReadWorkItem = nil
        let systemWide = AXUIElementCreateSystemWide()
        guard let focusedValue = copyAttribute(kAXFocusedUIElementAttribute, from: systemWide),
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            DebugLogger.log("No accessibility focused element.")
            beginClipboardFallback(for: nil, requestID: requestID, pointer: pointer)
            return
        }
        let focusedElement = unsafeDowncast(focusedValue, to: AXUIElement.self)

        guard let rawText = copyAttribute(kAXSelectedTextAttribute, from: focusedElement) as? String else {
            if selectedRangeLength(in: focusedElement) == 0 {
                DebugLogger.log("Selection range is empty; skipping clipboard fallback.")
                return
            }
            DebugLogger.log("Focused element does not expose AXSelectedText.")
            beginClipboardFallback(for: focusedElement, requestID: requestID, pointer: pointer)
            return
        }

        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            DebugLogger.log("Selection is empty.")
            if rawText.isEmpty, selectedRangeLength(in: focusedElement) != 0 {
                DebugLogger.log("Selection range may be non-empty; trying clipboard fallback.")
                beginClipboardFallback(for: focusedElement, requestID: requestID, pointer: pointer)
            }
            return
        }

        guard let rangeValueReference = copyAttribute(kAXSelectedTextRangeAttribute, from: focusedElement),
              CFGetTypeID(rangeValueReference) == AXValueGetTypeID() else {
            DebugLogger.log("Focused element does not expose AXSelectedTextRange; using pointer anchor.")
            emit(text: text, anchor: .pointer(pointer), source: "Accessibility text + pointer", pointer: pointer)
            return
        }
        let rangeValue = unsafeDowncast(rangeValueReference, to: AXValue.self)

        guard let boundsValue = copyBounds(for: rangeValue, in: focusedElement),
              AXValueGetType(boundsValue) == .cgRect else {
            DebugLogger.log("Focused element does not expose bounds for the selected range; using pointer anchor.")
            emit(text: text, anchor: .pointer(pointer), source: "Accessibility text + pointer", pointer: pointer)
            return
        }

        var bounds = CGRect.zero
        AXValueGetValue(boundsValue, .cgRect, &bounds)
        guard !bounds.isEmpty else {
            DebugLogger.log("Selection bounds are empty; using pointer anchor.")
            emit(text: text, anchor: .pointer(pointer), source: "Accessibility text + pointer", pointer: pointer)
            return
        }

        emit(text: text, anchor: .accessibilityBounds(bounds), source: "Accessibility", pointer: pointer)
    }

    private func emit(text: String, anchor: TextSelection.Anchor, source: String, pointer: NSPoint) {
        // Deliver only the most recent selection after the event stream settles.
        // This avoids showing stale text when several selections happen quickly.
        selectionEmissionWorkItem?.cancel()
        let selection = TextSelection(text: text, anchor: anchor, pointer: pointer)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.selectionEmissionWorkItem = nil
            DebugLogger.log("Selection from \(source): \(text.prefix(80))")
            self.onSelection?(selection)
        }
        selectionEmissionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func beginClipboardFallback(for focusedElement: AXUIElement?, requestID: Int, pointer: NSPoint) {
        guard isRunning, requestID == latestSelectionRequestID else {
            DebugLogger.log("Ignoring stale clipboard fallback request.")
            return
        }
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
        activeClipboardFallbackRequestID = requestID

        guard postCopyShortcut() else {
            DebugLogger.log("Could not post Command-C for clipboard fallback.")
            activeClipboardFallbackRequestID = nil
            clipboardSnapshot = nil
            return
        }

        DebugLogger.log("AXSelectedText unavailable; trying clipboard fallback.")
        let workItem = DispatchWorkItem { [weak self] in
            self?.readClipboardFallback(requestID: requestID, pointer: pointer)
        }
        clipboardReadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func readClipboardFallback(requestID: Int, pointer: NSPoint) {
        let pasteboard = NSPasteboard.general
        defer {
            clipboardReadWorkItem = nil
            if activeClipboardFallbackRequestID == requestID {
                activeClipboardFallbackRequestID = nil
            }
            restoreClipboard()
        }

        guard isRunning,
              requestID == latestSelectionRequestID,
              activeClipboardFallbackRequestID == requestID else {
            DebugLogger.log("Ignoring stale clipboard fallback read.")
            return
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

        emit(text: text, anchor: .pointer(pointer), source: "Clipboard fallback", pointer: pointer)
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

    private func cancelPendingSelectionWork(shouldRestoreClipboard: Bool) {
        selectionReadWorkItem?.cancel()
        selectionReadWorkItem = nil
        clipboardReadWorkItem?.cancel()
        clipboardReadWorkItem = nil
        selectionEmissionWorkItem?.cancel()
        selectionEmissionWorkItem = nil
        activeClipboardFallbackRequestID = nil
        if shouldRestoreClipboard {
            restoreClipboard()
        }
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

    private func selectedRangeLength(in element: AXUIElement) -> Int? {
        guard let value = copyAttribute(kAXSelectedTextRangeAttribute, from: element),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let rangeValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return range.length
    }
}
