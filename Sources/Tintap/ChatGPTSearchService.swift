import AppKit
import ApplicationServices

@MainActor
final class ChatGPTSearchService {
    enum SearchError: LocalizedError {
        case appNotFound
        case launchFailed(String)
        case temporaryChatUnavailable
        case pasteFailed

        var errorDescription: String? {
            switch self {
            case .appNotFound: "ChatGPT for macOS is not installed."
            case let .launchFailed(message): "Could not open ChatGPT: \(message)"
            case .temporaryChatUnavailable:
                "无法确认 ChatGPT 的 Temporary Chat 已启用；为避免将内容发送到现有会话，本次搜索已取消。"
            case .pasteFailed: "Could not paste the query into ChatGPT."
            }
        }
    }

    func search(_ selectedText: String) async throws {
        guard let applicationURL = chatGPTApplicationURL() else {
            throw SearchError.appNotFound
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let application: NSRunningApplication
        do {
            application = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
        } catch {
            throw SearchError.launchFailed(error.localizedDescription)
        }

        try await prepareTemporaryChat(in: application)

        let prompt = "请基于下面的内容进行 AI 搜索与解释。必要时请使用网络搜索，并给出可靠来源。\n\n\(selectedText)"
        let snapshot = snapshot(of: NSPasteboard.general)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        guard postPasteAndSend() else {
            restore(snapshot, to: NSPasteboard.general)
            throw SearchError.pasteFailed
        }
        try? await Task.sleep(for: .milliseconds(350))
        restore(snapshot, to: NSPasteboard.general)
    }

    func openChatGPT() {
        guard let applicationURL = chatGPTApplicationURL() else { return }
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: .init())
    }

    private func chatGPTApplicationURL() -> URL? {
        let workspace = NSWorkspace.shared
        let namedApp = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        if isChatGPTApplication(namedApp) { return namedApp }
        for bundleIdentifier in ["com.openai.codex", "com.openai.chat"] {
            if let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier), isChatGPTApplication(url) {
                return url
            }
        }
        return nil
    }

    private func isChatGPTApplication(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let bundle = Bundle(url: url) else { return false }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName")
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName")) as? String
        return name?.caseInsensitiveCompare("ChatGPT") == .orderedSame
    }

    /// Creates a fresh ChatGPT conversation and enables Temporary Chat before a
    /// query is ever copied into ChatGPT. If the version-specific accessibility
    /// controls cannot prove the temporary mode is on, the caller does not paste.
    private func prepareTemporaryChat(in application: NSRunningApplication) async throws {
        guard AXIsProcessTrusted() else { throw SearchError.temporaryChatUnavailable }

        if #available(macOS 14.0, *) {
            application.activate(options: [.activateAllWindows])
        } else {
            application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
        try await Task.sleep(for: .milliseconds(500))
        guard postKeyCommand(keyCode: 45, command: true) else { // Command-N
            throw SearchError.temporaryChatUnavailable
        }
        try await Task.sleep(for: .milliseconds(650))

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let modelControl = bestModelControl(in: appElement),
              AXUIElementPerformAction(modelControl, kAXPressAction as CFString) == .success else {
            throw SearchError.temporaryChatUnavailable
        }
        try await Task.sleep(for: .milliseconds(250))

        guard let temporaryControl = firstElement(in: appElement, where: { element in
            let role = attributeString(kAXRoleAttribute, from: element) ?? ""
            guard [kAXButtonRole, kAXCheckBoxRole, kAXMenuItemRole].contains(role) else { return false }
            return isTemporaryChatLabel(accessibilityLabel(of: element))
        }) else {
            throw SearchError.temporaryChatUnavailable
        }

        if temporaryControlIsEnabled(temporaryControl) { return }
        guard AXUIElementPerformAction(temporaryControl, kAXPressAction as CFString) == .success else {
            throw SearchError.temporaryChatUnavailable
        }
        try await Task.sleep(for: .milliseconds(250))

        // The toggle may disappear when its popover closes. In that case the
        // conversation header must expose the active Temporary Chat state.
        guard temporaryChatIsConfirmed(in: appElement) else {
            throw SearchError.temporaryChatUnavailable
        }
    }

    private func bestModelControl(in root: AXUIElement) -> AXUIElement? {
        var best: (element: AXUIElement, score: Int)?
        enumerateElements(in: root) { element in
            let role = attributeString(kAXRoleAttribute, from: element) ?? ""
            guard [kAXButtonRole, kAXPopUpButtonRole].contains(role) else { return }
            let label = accessibilityLabel(of: element).lowercased()
            var score = role == kAXPopUpButtonRole ? 80 : 0
            if label.contains("model") || label.contains("模型") { score += 100 }
            if label.contains("gpt") || label.contains("o1") || label.contains("o3") || label.contains("o4") {
                score += 60
            }
            guard score > 0, best.map({ score > $0.score }) ?? true else { return }
            best = (element, score)
        }
        return best?.element
    }

    private func temporaryChatIsConfirmed(in root: AXUIElement) -> Bool {
        var confirmed = false
        enumerateElements(in: root) { element in
            guard isTemporaryChatLabel(accessibilityLabel(of: element)) else { return }
            if temporaryControlIsEnabled(element) { confirmed = true }
            // After the popover closes, ChatGPT exposes the active mode as a
            // header label rather than an AX toggle.
            if attributeString(kAXRoleAttribute, from: element) == kAXStaticTextRole {
                confirmed = true
            }
        }
        return confirmed
    }

    private func temporaryControlIsEnabled(_ element: AXUIElement) -> Bool {
        if let value = attributeValue(kAXValueAttribute, from: element) as? NSNumber {
            return value.boolValue
        }
        if let mark = attributeString(kAXMenuItemMarkCharAttribute, from: element), !mark.isEmpty {
            return true
        }
        return false
    }

    private func isTemporaryChatLabel(_ label: String) -> Bool {
        let normalized = label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return normalized.contains("temporary chat")
            || normalized.contains("临时聊天")
            || normalized.contains("临时对话")
            || normalized.contains("临时会话")
    }

    private func accessibilityLabel(of element: AXUIElement) -> String {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
            .compactMap { attributeString($0, from: element) }
            .joined(separator: " ")
    }

    private func firstElement(in root: AXUIElement, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        var result: AXUIElement?
        enumerateElements(in: root) { element in
            if result == nil, matches(element) { result = element }
        }
        return result
    }

    private func enumerateElements(in root: AXUIElement, visit: (AXUIElement) -> Void) {
        var queue = [root]
        var index = 0
        // A limit keeps this safe in complex Electron accessibility trees.
        while index < queue.count, index < 800 {
            let element = queue[index]
            index += 1
            visit(element)
            if let children = attributeValue(kAXChildrenAttribute, from: element) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
    }

    private func attributeValue(_ attribute: String, from element: AXUIElement) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private func attributeString(_ attribute: String, from element: AXUIElement) -> String? {
        guard let value = attributeValue(attribute, from: element) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private func restore(_ snapshot: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !snapshot.isEmpty { pasteboard.writeObjects(snapshot) }
    }

    private func postPasteAndSend() -> Bool {
        guard postKeyCommand(keyCode: 9, command: true) else { return false } // Command-V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            _ = self.postKeyCommand(keyCode: 36) // Return
        }
        return true
    }

    private func postKeyCommand(keyCode: CGKeyCode, command: Bool = false) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        if command { down?.flags = .maskCommand; up?.flags = .maskCommand }
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        return true
    }
}
