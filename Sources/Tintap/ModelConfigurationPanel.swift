import AppKit

@MainActor
final class ModelConfigurationPanel: NSWindowController, NSWindowDelegate {
    private static var visiblePanel: ModelConfigurationPanel?

    private let store: ModelSettingsStore
    private let tooltipStore: TooltipPreferencesStore
    private let apiFormatPopup: NSPopUpButton
    private let baseURLField: NSTextField
    private let modelField: NSTextField
    private let targetLanguageField: NSTextField
    private let apiKeyField: NSSecureTextField
    private let systemPromptTextView: NSTextView
    private let systemPromptScrollView: NSScrollView
    private let offsetXField: NSTextField
    private let offsetYField: NSTextField

    static func present(store: ModelSettingsStore, tooltipStore: TooltipPreferencesStore) {
        if let visiblePanel {
            visiblePanel.showWindow(nil)
            visiblePanel.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = ModelConfigurationPanel(store: store, tooltipStore: tooltipStore)
        visiblePanel = panel
        panel.showWindow(nil)
        panel.window?.center()
        panel.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init(store: ModelSettingsStore, tooltipStore: TooltipPreferencesStore) {
        self.store = store
        self.tooltipStore = tooltipStore
        let configuration = store.load()
        let tooltipPreferences = tooltipStore.load()
        apiFormatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        apiFormatPopup.translatesAutoresizingMaskIntoConstraints = false
        apiFormatPopup.widthAnchor.constraint(equalToConstant: 350).isActive = true
        for format in ModelAPIFormat.allCases {
            apiFormatPopup.addItem(withTitle: format.displayName)
            apiFormatPopup.lastItem?.representedObject = format.rawValue
        }
        apiFormatPopup.selectItem(withTitle: configuration.apiFormat.displayName)
        baseURLField = Self.textField(value: configuration.baseURL, placeholder: "https://api.openai.com/v1")
        modelField = Self.textField(value: configuration.model, placeholder: "gpt-4.1-mini")
        targetLanguageField = Self.textField(value: configuration.targetLanguage, placeholder: "Simplified Chinese")
        apiKeyField = NSSecureTextField(string: configuration.apiKey)
        apiKeyField.placeholderString = "sk-…"
        apiKeyField.translatesAutoresizingMaskIntoConstraints = false
        apiKeyField.widthAnchor.constraint(equalToConstant: 350).isActive = true
        systemPromptTextView = NSTextView()
        systemPromptTextView.string = configuration.systemPrompt
        systemPromptTextView.font = .systemFont(ofSize: 13)
        systemPromptTextView.isRichText = false
        systemPromptTextView.isAutomaticQuoteSubstitutionEnabled = false
        systemPromptTextView.isAutomaticDashSubstitutionEnabled = false
        systemPromptTextView.textContainerInset = NSSize(width: 6, height: 6)
        systemPromptScrollView = NSScrollView()
        systemPromptScrollView.translatesAutoresizingMaskIntoConstraints = false
        systemPromptScrollView.borderType = .bezelBorder
        systemPromptScrollView.hasVerticalScroller = true
        systemPromptScrollView.documentView = systemPromptTextView
        systemPromptScrollView.widthAnchor.constraint(equalToConstant: 350).isActive = true
        systemPromptScrollView.heightAnchor.constraint(equalToConstant: 104).isActive = true
        offsetXField = Self.numberField(value: tooltipPreferences.offsetX)
        offsetYField = Self.numberField(value: tooltipPreferences.offsetY)

        let contentRect = NSRect(x: 0, y: 0, width: 520, height: 590)
        let panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Tintap 模型配置"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.center()

        super.init(window: panel)
        panel.delegate = self
        configureContent(in: panel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        Self.visiblePanel = nil
    }

    @objc private func save() {
        let configuration = ModelConfiguration(
            apiFormat: ModelAPIFormat(rawValue: apiFormatPopup.selectedItem?.representedObject as? String ?? "") ?? .openAICompatible,
            baseURL: baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            model: modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            targetLanguage: targetLanguageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            systemPrompt: systemPromptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        do {
            try store.save(configuration)
            tooltipStore.saveOffsets(
                x: offsetXField.doubleValue,
                y: offsetYField.doubleValue
            )
            dismissPanel()
        } catch {
            showErrorAlert(error)
        }
    }

    @objc private func cancel() {
        dismissPanel()
    }

    @objc private func restoreDefaultPrompt() {
        systemPromptTextView.string = ModelConfiguration.defaultSystemPrompt
    }

    private func configureContent(in panel: NSPanel) {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = content

        let title = NSTextField(labelWithString: "模型配置")
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        let description = NSTextField(wrappingLabelWithString: "支持 OpenAI Chat Completions 和 Anthropic Messages API。服务地址请填写 API Base（通常为 https://域名/v1），API Key 仅保存在本机钥匙串。")
        description.textColor = .secondaryLabelColor
        description.font = .systemFont(ofSize: 13)

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 12
        form.addArrangedSubview(Self.row(title: "接口格式", field: apiFormatPopup))
        form.addArrangedSubview(Self.row(title: "服务地址", field: baseURLField))
        form.addArrangedSubview(Self.row(title: "模型", field: modelField))
        form.addArrangedSubview(Self.row(title: "目标语言", field: targetLanguageField))
        form.addArrangedSubview(Self.row(title: "API Key", field: apiKeyField))
        form.addArrangedSubview(Self.promptRow(textView: systemPromptScrollView, target: self))
        form.addArrangedSubview(Self.divider())
        form.addArrangedSubview(Self.row(title: "水平偏移", field: offsetXField))
        form.addArrangedSubview(Self.row(title: "垂直偏移", field: offsetYField))

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        let saveButton = NSButton(title: "保存", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spacer, cancelButton, saveButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let stack = NSStackView(views: [title, description, Self.divider(), form, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            description.widthAnchor.constraint(equalTo: stack.widthAnchor),
            form.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func dismissPanel() {
        window?.close()
    }

    private func showErrorAlert(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private static func textField(value: String, placeholder: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 350).isActive = true
        return field
    }

    private static func numberField(value: Double) -> NSTextField {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        formatter.minimum = -500
        formatter.maximum = 500
        let field = NSTextField(string: String(format: "%.1f", value))
        field.formatter = formatter
        field.placeholderString = "0"
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 120).isActive = true
        return field
    }

    private static func row(title: String, field: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private static func promptRow(textView: NSView, target: AnyObject) -> NSStackView {
        let label = NSTextField(labelWithString: "系统提示词")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let resetButton = NSButton(title: "恢复默认", target: target, action: #selector(restoreDefaultPrompt))
        resetButton.bezelStyle = .inline
        resetButton.controlSize = .small
        let fieldStack = NSStackView(views: [textView, resetButton])
        fieldStack.orientation = .vertical
        fieldStack.alignment = .trailing
        fieldStack.spacing = 4

        let row = NSStackView(views: [label, fieldStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        return row
    }

    private static func divider() -> NSBox {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 472).isActive = true
        return divider
    }
}
