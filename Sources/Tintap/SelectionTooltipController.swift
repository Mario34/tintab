import AppKit

@MainActor
final class SelectionTooltipController {
    private enum Layout {
        static let width: CGFloat = 304
        static let minimumHeight: CGFloat = 46
        static let maximumHeight: CGFloat = 260
        static let actionHeight: CGFloat = 32
        static let contentSpacing: CGFloat = 8
        static let contentHorizontalInset: CGFloat = 8
        static let contentVerticalInset: CGFloat = 7
        static let horizontalPadding: CGFloat = contentHorizontalInset * 2
        static let verticalPadding: CGFloat = contentVerticalInset * 2
    }

    var onTranslate: ((String) -> Void)?
    var onAISearch: ((String) -> Void)?

    private let panel: NSPanel
    private let resultLabel = NSTextField(labelWithString: "")
    private let actionStack = NSStackView()
    private let resultDivider = NSBox()
    private var dismissWorkItem: DispatchWorkItem?
    private var selectedText = ""
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    init() {
        resultLabel.font = .systemFont(ofSize: 13.5, weight: .regular)
        resultLabel.textColor = .labelColor
        resultLabel.lineBreakMode = .byCharWrapping
        resultLabel.maximumNumberOfLines = 0
        resultLabel.alignment = .left
        resultLabel.usesSingleLineMode = false
        resultLabel.cell?.wraps = true
        resultLabel.cell?.isScrollable = false
        resultLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let translateButton = Self.makeButton(title: "翻译", symbol: "character.bubble")
        let searchButton = Self.makeButton(title: "ChatGPT 搜索", symbol: "magnifyingglass")
        let actionDivider = Self.makeDivider(vertical: true)
        actionStack.orientation = .horizontal
        actionStack.distribution = .fill
        actionStack.alignment = .centerY
        actionStack.spacing = 4
        actionStack.addArrangedSubview(translateButton)
        actionStack.addArrangedSubview(actionDivider)
        actionStack.addArrangedSubview(searchButton)
        searchButton.widthAnchor.constraint(equalTo: translateButton.widthAnchor).isActive = true
        actionDivider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        actionDivider.heightAnchor.constraint(equalToConstant: 22).isActive = true

        resultDivider.boxType = .separator
        resultDivider.isHidden = true

        let contentStack = NSStackView(views: [actionStack, resultDivider, resultLabel])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = Layout.contentSpacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let contentContainer = NSView(
            frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.minimumHeight)
        )
        contentContainer.autoresizingMask = [.width, .height]
        contentContainer.wantsLayer = true
        contentContainer.layer?.masksToBounds = true
        contentContainer.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: Layout.contentHorizontalInset),
            contentStack.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -Layout.contentHorizontalInset),
            contentStack.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: Layout.contentVerticalInset),
            contentStack.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -Layout.contentVerticalInset),
            actionStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            resultDivider.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            resultLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
        ])

        let glassBackground = Self.makeGlassBackground(contentView: contentContainer)

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.minimumHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = glassBackground
        panel.contentMinSize = NSSize(width: Layout.width, height: Layout.minimumHeight)
        panel.contentMaxSize = NSSize(width: Layout.width, height: Layout.maximumHeight)
        panel.minSize = NSSize(width: Layout.width, height: Layout.minimumHeight)
        panel.maxSize = NSSize(width: Layout.width, height: Layout.maximumHeight)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        translateButton.target = self
        translateButton.action = #selector(translateClicked)
        searchButton.target = self
        searchButton.action = #selector(aiSearchClicked)

        installOutsideClickMonitors()
    }

    func showStatus(_ message: String) {
        selectedText = ""
        actionStack.isHidden = true
        resultDivider.isHidden = true
        resultLabel.stringValue = message
        resultLabel.isHidden = false
        showPanel(origin: positionedNearPointer(NSEvent.mouseLocation, size: panelSize()), dismissAfter: 3)
    }

    func show(selection: TextSelection, preferences: TooltipPreferences) {
        selectedText = selection.text
        actionStack.isHidden = false
        resultDivider.isHidden = true
        resultLabel.isHidden = true
        let size = panelSize()
        let origin = positionedOrigin(for: selection, size: size, preferences: preferences)
        showPanel(origin: origin, dismissAfter: nil)
    }

    func showProgress(_ message: String) {
        guard !selectedText.isEmpty else { return }
        actionStack.isHidden = true
        resultDivider.isHidden = true
        resultLabel.stringValue = message
        resultLabel.isHidden = false
        resizePreservingPosition(dismissAfter: nil)
    }

    func showTranslation(_ translation: String) {
        guard !selectedText.isEmpty else { return }
        actionStack.isHidden = false
        resultDivider.isHidden = false
        resultLabel.stringValue = translation
        resultLabel.isHidden = false
        resizePreservingPosition(dismissAfter: nil)
    }

    func showError(_ message: String) {
        if selectedText.isEmpty {
            showStatus(message)
            return
        }
        actionStack.isHidden = false
        resultDivider.isHidden = false
        resultLabel.stringValue = message
        resultLabel.isHidden = false
        resizePreservingPosition(dismissAfter: nil)
    }

    func hide() {
        dismissWorkItem?.cancel()
        panel.orderOut(nil)
        selectedText = ""
    }

    func contains(screenPoint: NSPoint) -> Bool {
        panel.isVisible && panel.frame.contains(screenPoint)
    }

    @objc private func translateClicked() {
        guard !selectedText.isEmpty else { return }
        onTranslate?(selectedText)
    }

    @objc private func aiSearchClicked() {
        guard !selectedText.isEmpty else { return }
        onAISearch?(selectedText)
    }

    private static func makeButton(title: String, symbol: String) -> NSButton {
        let button = TooltipActionButton(title: title, target: nil, action: nil)
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.contentTintColor = .labelColor
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.heightAnchor.constraint(equalToConstant: Layout.actionHeight).isActive = true
        return button
    }

    private static func makeDivider(vertical: Bool) -> NSBox {
        let divider = NSBox()
        divider.boxType = .separator
        divider.alphaValue = 0.55
        return divider
    }

    private static func makeGlassBackground(contentView: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(
                frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.minimumHeight)
            )
            glass.autoresizingMask = [.width, .height]
            glass.style = .regular
            glass.cornerRadius = 12
            glass.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.22)
            glass.contentView = contentView
            return glass
        }

        let blur = NSVisualEffectView(
            frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.minimumHeight)
        )
        blur.autoresizingMask = [.width, .height]
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true
        contentView.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: blur.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: blur.bottomAnchor)
        ])
        return blur
    }

    private func installOutsideClickMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.hideIfClickIsOutside()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.hideIfClickIsOutside()
            return event
        }
    }

    private func hideIfClickIsOutside() {
        guard panel.isVisible, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        hide()
    }

    private func positionedOrigin(for selection: TextSelection, size: NSSize, preferences: TooltipPreferences) -> NSPoint {
        let screen = screen(containing: selection.pointer) ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let anchorRect: NSRect
        switch selection.anchor {
        case let .accessibilityBounds(bounds):
            anchorRect = appKitRect(from: bounds)
        case let .pointer(point):
            anchorRect = NSRect(x: point.x, y: point.y, width: 1, height: 1)
        }

        let gap: CGFloat = 8
        let x = anchorRect.midX - size.width / 2 + preferences.offsetX
        let belowY = anchorRect.minY - gap - size.height + preferences.offsetY
        let aboveY = anchorRect.maxY + gap + preferences.offsetY
        let fitsBelow = belowY >= visible.minY
        let fitsAbove = aboveY + size.height <= visible.maxY
        let y: CGFloat
        if fitsBelow {
            y = belowY
        } else if fitsAbove {
            y = aboveY
        } else {
            let roomBelow = anchorRect.minY - visible.minY
            let roomAbove = visible.maxY - anchorRect.maxY
            y = roomBelow >= roomAbove ? belowY : aboveY
        }

        return clampedOrigin(NSPoint(x: x, y: y), size: size, visibleFrame: visible)
    }

    private func positionedNearPointer(_ point: NSPoint, size: NSSize) -> NSPoint {
        let screen = screen(containing: point) ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        return clampedOrigin(
            NSPoint(x: point.x - size.width / 2, y: point.y - size.height - 8),
            size: size,
            visibleFrame: visible
        )
    }

    private func clampedOrigin(_ origin: NSPoint, size: NSSize, visibleFrame: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        )
    }

    private func appKitRect(from accessibilityBounds: CGRect) -> NSRect {
        let primaryScreen = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main ?? NSScreen.screens[0]
        return NSRect(
            x: accessibilityBounds.minX,
            y: primaryScreen.frame.maxY - accessibilityBounds.maxY,
            width: accessibilityBounds.width,
            height: accessibilityBounds.height
        )
    }

    private func showPanel(origin: NSPoint, dismissAfter: TimeInterval?) {
        dismissWorkItem?.cancel()
        let size = panelSize()
        panel.setContentSize(size)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        DebugLogger.log("Tooltip frame: \(panel.frame), requested size: \(size)")

        if let dismissAfter {
            let dismissal = DispatchWorkItem { [weak self] in self?.hide() }
            dismissWorkItem = dismissal
            DispatchQueue.main.asyncAfter(deadline: .now() + dismissAfter, execute: dismissal)
        }
    }

    private func resizePreservingPosition(dismissAfter: TimeInterval?) {
        let oldFrame = panel.frame
        let size = panelSize()
        let screen = screen(containing: oldFrame.center) ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let origin = clampedOrigin(oldFrame.origin, size: size, visibleFrame: visible)
        showPanel(origin: origin, dismissAfter: dismissAfter)
    }

    private func panelSize() -> NSSize {
        let actionHeight: CGFloat = actionStack.isHidden ? 0 : Layout.actionHeight
        let showsResult = !resultLabel.isHidden
        let spacing: CGFloat = actionStack.isHidden || !showsResult ? 0 : Layout.contentSpacing
        let dividerHeight: CGFloat = resultDivider.isHidden ? 0 : 1 + Layout.contentSpacing
        let maximumResultHeight = Layout.maximumHeight - Layout.verticalPadding - actionHeight - spacing - dividerHeight
        let measuredResultHeight = resultLabel.isHidden
            ? 0
            : resultLabel.sizeThatFits(
                NSSize(
                    width: Layout.width - Layout.horizontalPadding,
                    height: .greatestFiniteMagnitude
                )
            ).height
        let resultHeight = min(maximumResultHeight, max(resultLabel.isHidden ? 0 : 18, measuredResultHeight))
        let measuredHeight = Layout.verticalPadding + actionHeight + spacing + dividerHeight + resultHeight
        return NSSize(
            width: Layout.width,
            height: min(Layout.maximumHeight, max(Layout.minimumHeight, measuredHeight))
        )
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}

@MainActor
private final class TooltipActionButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
