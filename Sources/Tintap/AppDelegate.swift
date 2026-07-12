import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let selectionTracker = SelectionTracker()
    private let tooltip = SelectionTooltipController()
    private let modelSettings = ModelSettingsStore.shared
    private let tooltipPreferences = TooltipPreferencesStore.shared
    private let translator = TranslationService()
    private var statusItem: NSStatusItem?
    private var selectionToggleItem: NSMenuItem?
    private var accessibilityPermissionRetryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        tooltip.onTranslate = { [weak self] text in self?.translate(text) }
        selectionTracker.onSelection = { [weak self] selection in
            guard let self else { return }
            guard !self.tooltip.contains(screenPoint: selection.pointer) else {
                DebugLogger.log("Ignoring selection event originating inside the tooltip.")
                return
            }
            self.tooltip.show(selection: selection, preferences: self.tooltipPreferences.load())
        }

        let previewArgument = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("--ui-preview=") })?
            .replacingOccurrences(of: "--ui-preview=", with: "")
        if let previewMode = ProcessInfo.processInfo.environment["TINTAP_UI_PREVIEW"] ?? previewArgument {
            showUIPreview(previewMode)
            return
        }

        if tooltipPreferences.load().isSelectionEnabled {
            setSelectionTrackingEnabled(true)
        }
    }

    private func showUIPreview(_ mode: String) {
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1000, height: 1000)
        let pointer = NSPoint(x: screenFrame.midX, y: screenFrame.midY)
        let selection = TextSelection(
            text: "Tintap selection preview",
            anchor: .pointer(pointer),
            pointer: pointer
        )
        let preferences = TooltipPreferences(isSelectionEnabled: true, offsetX: 0, offsetY: 0)
        tooltip.show(selection: selection, preferences: preferences)
        switch mode {
        case "progress":
            tooltip.showProgress("正在翻译…")
        case "result":
            tooltip.showTranslation("翻译的结果在这里显示，翻译的结果在这里显示，翻译的结果在这里显示，翻译的结果在这里显示，翻译的结果在这里显示，翻译的结果在这里显示，翻译的结果在这里显示，翻译的结果在这里显示，翻译的结果在这里显示，翻译的结果在这里显示，翻译的结果在这里显示。")
        case "long-result":
            tooltip.showTranslation(String(repeating: "翻译的结果在这里显示，", count: 48))
        default:
            break
        }
        tooltip.activateVisualPreview()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopAccessibilityPermissionRetry()
        selectionTracker.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard tooltipPreferences.load().isSelectionEnabled, !selectionTracker.isRunning else { return }
        if AccessibilityPermission.isGranted {
            DebugLogger.log("Accessibility permission became available after app activation.")
            setSelectionTrackingEnabled(true, requestsPermissionPrompt: false)
        }
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

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = TintapMenuBarIcon.makeTemplateImage()
        item.button?.toolTip = "Tintap"
        item.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        let toggleItem = menu.addItem(withTitle: "启用划词工具", action: #selector(toggleSelectionTracking), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = tooltipPreferences.load().isSelectionEnabled ? .on : .off
        selectionToggleItem = toggleItem
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openModelConfiguration), keyEquivalent: ",").target = self
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

    private func setSelectionTrackingEnabled(_ enabled: Bool, requestsPermissionPrompt: Bool = true) {
        selectionToggleItem?.state = enabled ? .on : .off
        guard enabled else {
            stopAccessibilityPermissionRetry()
            selectionTracker.stop()
            tooltip.hide()
            DebugLogger.log("Selection tracking disabled.")
            return
        }

        let isAuthorized = requestsPermissionPrompt
            ? AccessibilityPermission.requestIfNeeded()
            : AccessibilityPermission.isGranted
        guard isAuthorized else {
            DebugLogger.log("Accessibility permission is missing.")
            tooltip.showStatus("请在系统设置中允许 Tintap 使用辅助功能；授权后会自动恢复划词。")
            startAccessibilityPermissionRetry()
            return
        }
        stopAccessibilityPermissionRetry()
        selectionTracker.start()
        DebugLogger.log("Selection tracking enabled.")
    }

    private func startAccessibilityPermissionRetry() {
        guard accessibilityPermissionRetryTimer == nil else { return }
        DebugLogger.log("Waiting for Accessibility permission to be granted.")
        accessibilityPermissionRetryTimer = Timer.scheduledTimer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(retrySelectionTrackingAfterPermissionGrant),
            userInfo: nil,
            repeats: true
        )
    }

    private func stopAccessibilityPermissionRetry() {
        accessibilityPermissionRetryTimer?.invalidate()
        accessibilityPermissionRetryTimer = nil
    }

    @objc private func retrySelectionTrackingAfterPermissionGrant() {
        guard tooltipPreferences.load().isSelectionEnabled else {
            stopAccessibilityPermissionRetry()
            return
        }
        guard AccessibilityPermission.isGranted else { return }
        DebugLogger.log("Accessibility permission granted; starting global selection tracking.")
        setSelectionTrackingEnabled(true, requestsPermissionPrompt: false)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
