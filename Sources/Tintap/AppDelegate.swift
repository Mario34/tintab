import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let selectionTracker = SelectionTracker()
    private let tooltip = SelectionTooltipController()
    private let modelSettings = ModelSettingsStore.shared
    private let tooltipPreferences = TooltipPreferencesStore.shared
    private let translator = TranslationService()
    private let chatGPTSearch = ChatGPTSearchService()
    private var statusItem: NSStatusItem?
    private var selectionToggleItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        tooltip.onTranslate = { [weak self] text in self?.translate(text) }
        tooltip.onAISearch = { [weak self] text in self?.searchWithChatGPT(text) }
        selectionTracker.onSelection = { [weak self] selection in
            guard let self else { return }
            guard !self.tooltip.contains(screenPoint: selection.pointer) else {
                DebugLogger.log("Ignoring selection event originating inside the tooltip.")
                return
            }
            self.tooltip.show(selection: selection, preferences: self.tooltipPreferences.load())
        }

        if tooltipPreferences.load().isSelectionEnabled {
            setSelectionTrackingEnabled(true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        selectionTracker.stop()
    }

    private func translate(_ text: String) {
        tooltip.showProgress("正在翻译…")
        let configuration = modelSettings.load()
        Task { [weak self] in
            do {
                let translated = try await self?.translator.translate(text, using: configuration)
                guard let translated else { return }
                self?.tooltip.showTranslation(translated)
            } catch {
                self?.tooltip.showError(error.localizedDescription)
            }
        }
    }

    private func searchWithChatGPT(_ text: String) {
        tooltip.showProgress("正在打开 ChatGPT…")
        Task { [weak self] in
            do {
                try await self?.chatGPTSearch.search(text)
                self?.tooltip.showStatus("已发送至 ChatGPT 临时聊天")
            } catch {
                self?.tooltip.showError(error.localizedDescription)
            }
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Tintap")
        item.button?.toolTip = "Tintap"

        let menu = NSMenu()
        let toggleItem = menu.addItem(withTitle: "启用划词工具", action: #selector(toggleSelectionTracking), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = tooltipPreferences.load().isSelectionEnabled ? .on : .off
        selectionToggleItem = toggleItem
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openModelConfiguration), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "打开 ChatGPT", action: #selector(openChatGPT), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Tintap", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func openModelConfiguration() {
        ModelConfigurationPanel.present(store: modelSettings, tooltipStore: tooltipPreferences)
    }

    @objc private func toggleSelectionTracking() {
        let enabled = !tooltipPreferences.load().isSelectionEnabled
        tooltipPreferences.setSelectionEnabled(enabled)
        setSelectionTrackingEnabled(enabled)
    }

    private func setSelectionTrackingEnabled(_ enabled: Bool) {
        selectionToggleItem?.state = enabled ? .on : .off
        guard enabled else {
            selectionTracker.stop()
            tooltip.hide()
            DebugLogger.log("Selection tracking disabled.")
            return
        }

        guard AccessibilityPermission.requestIfNeeded() else {
            DebugLogger.log("Accessibility permission is missing.")
            tooltip.showStatus("请在系统设置中允许 Tintap 使用辅助功能，然后重新启用。")
            return
        }
        selectionTracker.start()
        DebugLogger.log("Selection tracking enabled.")
    }

    @objc private func openChatGPT() {
        chatGPTSearch.openChatGPT()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
