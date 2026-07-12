import AppKit
import Foundation

struct UsageStatisticsSnapshot: Codable, Sendable, Equatable {
    var requestCount = 0
    var successCount = 0
    var failureCount = 0
    var cacheHitCount = 0
    var inputTokens = 0
    var outputTokens = 0
    var lastUpdated: Date?

    var totalTokens: Int { inputTokens + outputTokens }
}

actor UsageStatisticsStore {
    static let shared = UsageStatisticsStore()

    private let defaults: UserDefaults
    private let key = "usage.statistics.v1"
    private var snapshot: UsageStatisticsSnapshot

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(UsageStatisticsSnapshot.self, from: data) {
            snapshot = decoded
        } else {
            snapshot = UsageStatisticsSnapshot()
        }
    }

    func current() -> UsageStatisticsSnapshot { snapshot }

    func recordCacheHit() {
        snapshot.cacheHitCount += 1
        touchAndPersist()
    }

    func recordRequestStarted() {
        snapshot.requestCount += 1
        touchAndPersist()
    }

    func recordRequestSucceeded(inputTokens: Int?, outputTokens: Int?) {
        snapshot.successCount += 1
        snapshot.inputTokens += max(0, inputTokens ?? 0)
        snapshot.outputTokens += max(0, outputTokens ?? 0)
        touchAndPersist()
    }

    func recordRequestFailed() {
        snapshot.failureCount += 1
        touchAndPersist()
    }

    func reset() {
        snapshot = UsageStatisticsSnapshot()
        persist()
    }

    private func touchAndPersist() {
        snapshot.lastUpdated = Date()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
final class UsageStatisticsPanel: NSWindowController, NSWindowDelegate {
    private static var visiblePanel: UsageStatisticsPanel?

    private let store: UsageStatisticsStore
    private let requestValue = NSTextField(labelWithString: "—")
    private let successValue = NSTextField(labelWithString: "—")
    private let failureValue = NSTextField(labelWithString: "—")
    private let cacheValue = NSTextField(labelWithString: "—")
    private let inputTokenValue = NSTextField(labelWithString: "—")
    private let outputTokenValue = NSTextField(labelWithString: "—")
    private let totalTokenValue = NSTextField(labelWithString: "—")
    private let updatedValue = NSTextField(labelWithString: "—")

    static func present(store: UsageStatisticsStore) {
        if let visiblePanel {
            visiblePanel.showWindow(nil)
            visiblePanel.window?.makeKeyAndOrderFront(nil)
            visiblePanel.refresh()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = UsageStatisticsPanel(store: store)
        visiblePanel = controller
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        controller.refresh()
        NSApp.activate(ignoringOtherApps: true)
    }

    init(store: UsageStatisticsStore) {
        self.store = store
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 390),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Tintap 用量统计"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self
        configureContent(in: panel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        Self.visiblePanel = nil
    }

    private func configureContent(in panel: NSPanel) {
        let content = NSView()
        panel.contentView = content

        let title = NSTextField(labelWithString: "累计用量")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString: "Token 数来自模型服务返回的 usage 字段；不返回 usage 的兼容服务只统计请求次数。")
        description.textColor = .secondaryLabelColor

        let rows = NSStackView(views: [
            row("网络请求", requestValue), row("成功", successValue), row("失败", failureValue),
            row("缓存命中", cacheValue), row("输入 Token", inputTokenValue),
            row("输出 Token", outputTokenValue), row("总 Token", totalTokenValue),
            row("最后更新", updatedValue)
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8

        let resetButton = NSButton(title: "清空统计", target: self, action: #selector(reset))
        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closePanel))
        closeButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [resetButton, spacer, closeButton])
        footer.orientation = .horizontal

        let stack = NSStackView(views: [title, description, divider(), rows, footer])
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
            rows.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func row(_ title: String, _ value: NSTextField) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        return NSStackView(views: [label, value])
    }

    private func divider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 372).isActive = true
        return box
    }

    private func refresh() {
        Task { [weak self] in
            guard let self else { return }
            apply(await store.current())
        }
    }

    private func apply(_ statistics: UsageStatisticsSnapshot) {
        requestValue.stringValue = statistics.requestCount.formatted()
        successValue.stringValue = statistics.successCount.formatted()
        failureValue.stringValue = statistics.failureCount.formatted()
        cacheValue.stringValue = statistics.cacheHitCount.formatted()
        inputTokenValue.stringValue = statistics.inputTokens.formatted()
        outputTokenValue.stringValue = statistics.outputTokens.formatted()
        totalTokenValue.stringValue = statistics.totalTokens.formatted()
        updatedValue.stringValue = statistics.lastUpdated?.formatted(date: .abbreviated, time: .shortened) ?? "暂无"
    }

    @objc private func reset() {
        Task { [weak self] in
            guard let self else { return }
            await store.reset()
            apply(await store.current())
        }
    }

    @objc private func closePanel() { window?.close() }
}
