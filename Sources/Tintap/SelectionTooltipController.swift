import AppKit

/// Geometry taken from the Figma frame `32:30`.
enum TooltipDesignSpec {
    static let compactSize = NSSize(width: 162, height: 42)
    static let progressSize = NSSize(width: 254, height: 97)
    static let resultWidth: CGFloat = 400
    static let resultMinimumHeight: CGFloat = 130
    static let resultMaximumHeight: CGFloat = 353
    static let resultMaximumContentHeight: CGFloat = 240
    static let cornerRadius: CGFloat = 10
    static let borderWidth: CGFloat = 1
    static let usesSystemWindowShadow = false
    static let horizontalInset: CGFloat = 17
    static let headerDividerTop: CGFloat = 45
    static let resultContentTop: CGFloat = 65
    static let resultFooterHeight: CGFloat = 47
    static let compactButtonSize = NSSize(width: 56, height: 23)

    static func resultSize(forContentHeight contentHeight: CGFloat) -> NSSize {
        let clampedContentHeight = min(resultMaximumContentHeight, max(18, contentHeight))
        let height = clampedContentHeight >= resultMaximumContentHeight
            ? resultMaximumHeight
            : min(resultMaximumHeight, max(resultMinimumHeight, resultContentTop + clampedContentHeight + resultFooterHeight))
        return NSSize(width: resultWidth, height: ceil(height))
    }
}

private enum TooltipPalette {
    static let compactBackground = NSColor(calibratedWhite: 64 / 255, alpha: 0.8)
    static let resultBackground = NSColor(calibratedWhite: 102 / 255, alpha: 0.8)
    static let border = NSColor.white.withAlphaComponent(0.16)
    static let hoverFill = NSColor.white.withAlphaComponent(0.12)
    static let divider = NSColor.white.withAlphaComponent(0.72)
    static let primaryText = NSColor.white
    static let errorText = NSColor(calibratedRed: 1, green: 0.55, blue: 0.55, alpha: 1)
}

@MainActor
final class SelectionTooltipController {
    private enum ResultMode {
        case hidden
        case status
        case progress
        case translation
        case error
    }

    var onTranslate: ((String) -> Void)?

    private let panel: NSPanel
    private let backgroundView: NSVisualEffectView
    private let compactView = NSView()
    private let resultView = NSView()
    private let translateButton = TooltipTextButton(title: "翻译", symbol: "character.book.closed")
    private let selectionCopyButton = TooltipTextButton(title: "复制", symbol: "document.on.document")
    private let dragHandle = TooltipDragHandle()
    private let titleLabel = NSTextField(labelWithString: "Tintap 翻译工具")
    private let closeButton = TooltipIconButton(symbol: "xmark", accessibilityLabel: "关闭")
    private let pinButton = TooltipIconButton(symbol: "pin", accessibilityLabel: "固定浮窗")
    private let divider = NSBox()
    private let progressIndicator = NSProgressIndicator()
    private let resultScrollView = NSScrollView()
    private let resultTextView = NSTextView()
    private let resultCopyButton = TooltipIconButton(symbol: "document.on.document", accessibilityLabel: "复制内容")
    private let retryButton = TooltipIconButton(symbol: "arrow.clockwise", accessibilityLabel: "重新翻译")

    private var dismissWorkItem: DispatchWorkItem?
    private var copyFeedbackWorkItem: DispatchWorkItem?
    private var selectedText = ""
    private var resultText = ""
    private var resultMode: ResultMode = .hidden
    private var isPinned = false
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    init() {
        backgroundView = NSVisualEffectView(frame: NSRect(origin: .zero, size: TooltipDesignSpec.compactSize))
        backgroundView.material = .hudWindow
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = TooltipDesignSpec.cornerRadius
        backgroundView.layer?.borderWidth = TooltipDesignSpec.borderWidth
        backgroundView.layer?.borderColor = TooltipPalette.border.cgColor
        backgroundView.layer?.masksToBounds = true

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: TooltipDesignSpec.compactSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = backgroundView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = TooltipDesignSpec.usesSystemWindowShadow
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true

        configureCompactView()
        configureResultView()
        installOutsideClickMonitors()
        applyCurrentState()
    }

    func showStatus(_ message: String) {
        selectedText = ""
        resultText = message
        resultMode = .status
        isPinned = false
        applyCurrentState()
        showPanel(origin: positionedNearPointer(NSEvent.mouseLocation, size: panelSize()), dismissAfter: 3)
    }

    func show(selection: TextSelection, preferences: TooltipPreferences) {
        guard !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            DebugLogger.log("Ignoring tooltip request for an empty selection.")
            return
        }
        guard !isPinned || !panel.isVisible else { return }
        selectedText = selection.text
        resultText = ""
        resultMode = .hidden
        applyCurrentState()
        let size = panelSize()
        showPanel(origin: positionedOrigin(for: selection, size: size, preferences: preferences), dismissAfter: nil)
    }

    func showProgress(_ message: String) {
        guard !selectedText.isEmpty else { return }
        resultText = message
        resultMode = .progress
        applyCurrentState()
        resizePreservingPosition()
    }

    func showTranslation(_ translation: String) {
        guard !selectedText.isEmpty else { return }
        resultText = translation
        resultMode = .translation
        applyCurrentState()
        resizePreservingPosition()
    }

    func showError(_ message: String) {
        if selectedText.isEmpty {
            showStatus(message)
            return
        }
        resultText = message
        resultMode = .error
        applyCurrentState()
        resizePreservingPosition()
    }

    func hide() {
        dismissWorkItem?.cancel()
        copyFeedbackWorkItem?.cancel()
        progressIndicator.stopAnimation(nil)
        panel.orderOut(nil)
        selectedText = ""
        resultText = ""
        resultMode = .hidden
        isPinned = false
        resetCopyFeedback()
    }

    func contains(screenPoint: NSPoint) -> Bool {
        panel.isVisible && panel.frame.contains(screenPoint)
    }

    /// Makes the otherwise non-activating utility panel discoverable to screenshot tooling.
    /// This is called only by the explicit `--ui-preview=` verification path.
    func activateVisualPreview() {
        panel.styleMask = [.borderless]
        panel.level = .normal
        panel.collectionBehavior = []
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func configureCompactView() {
        compactView.frame = NSRect(origin: .zero, size: TooltipDesignSpec.compactSize)
        compactView.autoresizingMask = [.width, .height]
        backgroundView.addSubview(compactView)

        translateButton.frame = frameFromTop(
            x: 13,
            top: 9,
            width: TooltipDesignSpec.compactButtonSize.width,
            height: TooltipDesignSpec.compactButtonSize.height,
            containerHeight: 42
        )
        selectionCopyButton.frame = frameFromTop(
            x: 75,
            top: 9,
            width: TooltipDesignSpec.compactButtonSize.width,
            height: TooltipDesignSpec.compactButtonSize.height,
            containerHeight: 42
        )
        dragHandle.frame = frameFromTop(x: 137, top: 12, width: 18, height: 18, containerHeight: 42)
        translateButton.target = self
        translateButton.action = #selector(translateClicked)
        selectionCopyButton.target = self
        selectionCopyButton.action = #selector(copySelectionClicked)
        compactView.addSubview(translateButton)
        compactView.addSubview(selectionCopyButton)
        compactView.addSubview(dragHandle)
    }

    private func configureResultView() {
        resultView.frame = NSRect(x: 0, y: 0, width: TooltipDesignSpec.resultWidth, height: 205)
        resultView.autoresizingMask = [.width, .height]
        resultView.isHidden = true
        backgroundView.addSubview(resultView)

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = TooltipPalette.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        resultView.addSubview(titleLabel)

        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        pinButton.target = self
        pinButton.action = #selector(pinClicked)
        resultCopyButton.target = self
        resultCopyButton.action = #selector(copyResultClicked)
        retryButton.target = self
        retryButton.action = #selector(retryClicked)
        resultView.addSubview(closeButton)
        resultView.addSubview(pinButton)

        divider.boxType = .separator
        divider.alphaValue = 0.9
        resultView.addSubview(divider)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        resultView.addSubview(progressIndicator)

        resultTextView.isEditable = false
        resultTextView.isSelectable = true
        resultTextView.drawsBackground = false
        resultTextView.textColor = TooltipPalette.primaryText
        resultTextView.font = .systemFont(ofSize: 13, weight: .medium)
        resultTextView.textContainerInset = .zero
        resultTextView.textContainer?.lineFragmentPadding = 0
        resultTextView.textContainer?.widthTracksTextView = true
        resultTextView.isVerticallyResizable = true
        resultTextView.isHorizontallyResizable = false
        resultScrollView.documentView = resultTextView
        resultScrollView.drawsBackground = false
        resultScrollView.borderType = .noBorder
        // Trackpad and mouse-wheel scrolling still work without a visible
        // scroller, avoiding the overlay that covered the final text column.
        resultScrollView.hasVerticalScroller = false
        resultScrollView.verticalScrollElasticity = .automatic
        resultView.addSubview(resultScrollView)
        resultView.addSubview(resultCopyButton)
        resultView.addSubview(retryButton)
    }

    private func applyCurrentState() {
        dismissWorkItem?.cancel()
        resetCopyFeedback()
        compactView.isHidden = resultMode != .hidden
        resultView.isHidden = resultMode == .hidden
        backgroundView.layer?.backgroundColor = (
            resultMode == .hidden ? TooltipPalette.compactBackground : TooltipPalette.resultBackground
        ).cgColor

        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        resultScrollView.isHidden = true
        resultCopyButton.isHidden = true
        retryButton.isHidden = true
        pinButton.isHidden = true
        divider.isHidden = false
        resultTextView.textColor = TooltipPalette.primaryText

        switch resultMode {
        case .hidden:
            break
        case .progress:
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
        case .translation:
            pinButton.isHidden = false
            resultScrollView.isHidden = false
            resultCopyButton.isHidden = false
            retryButton.isHidden = false
            resultTextView.string = resultText
        case .error:
            pinButton.isHidden = false
            resultScrollView.isHidden = false
            retryButton.isHidden = false
            resultTextView.string = resultText
            resultTextView.textColor = TooltipPalette.errorText
        case .status:
            resultScrollView.isHidden = false
            resultTextView.string = resultText
        }
        updatePinAppearance()
        layoutForCurrentState(size: panelSize())
    }

    private func layoutForCurrentState(size: NSSize) {
        backgroundView.frame = NSRect(origin: .zero, size: size)
        compactView.frame = backgroundView.bounds
        resultView.frame = backgroundView.bounds
        guard resultMode != .hidden else { return }

        let height = size.height
        titleLabel.frame = frameFromTop(x: 17, top: 14, width: 250, height: 19, containerHeight: height)
        closeButton.frame = frameFromTop(x: size.width - 36, top: 15, width: 20, height: 20, containerHeight: height)
        pinButton.frame = frameFromTop(x: size.width - 65, top: 16, width: 18, height: 18, containerHeight: height)
        divider.frame = frameFromTop(
            x: TooltipDesignSpec.horizontalInset,
            top: TooltipDesignSpec.headerDividerTop,
            width: size.width - TooltipDesignSpec.horizontalInset * 2,
            height: 1,
            containerHeight: height
        )
        progressIndicator.frame = frameFromTop(x: 17, top: 57, width: 16, height: 16, containerHeight: height)

        let contentHeight = min(
            TooltipDesignSpec.resultMaximumContentHeight,
            max(18, measuredResultTextHeight(width: size.width - TooltipDesignSpec.horizontalInset * 2))
        )
        resultScrollView.frame = frameFromTop(
            x: TooltipDesignSpec.horizontalInset,
            top: TooltipDesignSpec.resultContentTop,
            width: size.width - TooltipDesignSpec.horizontalInset * 2,
            height: contentHeight,
            containerHeight: height
        )
        resultTextView.frame = NSRect(x: 0, y: 0, width: resultScrollView.bounds.width, height: max(contentHeight, measuredResultTextHeight(width: resultScrollView.bounds.width)))
        resultCopyButton.frame = NSRect(x: 17, y: 18, width: 16, height: 16)
        retryButton.frame = NSRect(x: 44, y: 18, width: 16, height: 16)
    }

    private func panelSize() -> NSSize {
        switch resultMode {
        case .hidden:
            return TooltipDesignSpec.compactSize
        case .progress:
            return TooltipDesignSpec.progressSize
        case .translation, .error, .status:
            return TooltipDesignSpec.resultSize(
                forContentHeight: measuredResultTextHeight(
                    width: TooltipDesignSpec.resultWidth - TooltipDesignSpec.horizontalInset * 2
                )
            )
        }
    }

    private func measuredResultTextHeight(width: CGFloat) -> CGFloat {
        guard !resultText.isEmpty else { return 18 }
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let bounds = (resultText as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(bounds.height)
    }

    @objc private func translateClicked() {
        guard !selectedText.isEmpty, resultMode != .progress else { return }
        onTranslate?(selectedText)
    }

    @objc private func retryClicked() {
        guard !selectedText.isEmpty, resultMode != .progress else { return }
        onTranslate?(selectedText)
    }

    @objc private func copySelectionClicked() {
        copyToPasteboard(selectedText, feedbackButton: selectionCopyButton)
    }

    @objc private func copyResultClicked() {
        guard resultMode == .translation else { return }
        copyToPasteboard(resultText, feedbackButton: resultCopyButton)
    }

    @objc private func closeClicked() {
        hide()
    }

    @objc private func pinClicked() {
        isPinned.toggle()
        updatePinAppearance()
    }

    private func updatePinAppearance() {
        pinButton.setSymbol(isPinned ? "pin.fill" : "pin.slash")
        pinButton.toolTip = isPinned ? "取消固定" : "固定浮窗"
        pinButton.setAccessibilityLabel(isPinned ? "取消固定浮窗" : "固定浮窗")
    }

    private func copyToPasteboard(_ text: String, feedbackButton: NSButton) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyFeedbackWorkItem?.cancel()
        feedbackButton.contentTintColor = NSColor.white.withAlphaComponent(0.5)
        let workItem = DispatchWorkItem { [weak self, weak feedbackButton] in
            feedbackButton?.contentTintColor = .white
            self?.copyFeedbackWorkItem = nil
        }
        copyFeedbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    private func resetCopyFeedback() {
        selectionCopyButton.contentTintColor = .white
        resultCopyButton.contentTintColor = .white
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
        guard panel.isVisible, !isPinned, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        hide()
    }

    private func resizePreservingPosition() {
        let oldFrame = panel.frame
        let size = panelSize()
        let screen = screen(containing: oldFrame.center) ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        var origin = oldFrame.origin
        origin.y = oldFrame.maxY - size.height
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        layoutForCurrentState(size: size)
        panel.orderFrontRegardless()
    }

    private func showPanel(origin: NSPoint, dismissAfter delay: TimeInterval?) {
        dismissWorkItem?.cancel()
        let size = panelSize()
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        layoutForCurrentState(size: size)
        panel.orderFrontRegardless()
        guard let delay else { return }
        let workItem = DispatchWorkItem { [weak self] in self?.hide() }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
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
        let below = anchorRect.minY - gap - size.height + preferences.offsetY
        let above = anchorRect.maxY + gap + preferences.offsetY
        let y = below >= visible.minY ? below : above
        return clamp(NSPoint(x: x, y: y), size: size, to: visible)
    }

    private func positionedNearPointer(_ pointer: NSPoint, size: NSSize) -> NSPoint {
        let screen = screen(containing: pointer) ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        return clamp(NSPoint(x: pointer.x + 12, y: pointer.y - size.height - 12), size: size, to: visible)
    }

    private func clamp(_ origin: NSPoint, size: NSSize, to visible: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, visible.minX), visible.maxX - size.width),
            y: min(max(origin.y, visible.minY), visible.maxY - size.height)
        )
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func appKitRect(from accessibilityBounds: CGRect) -> NSRect {
        guard let desktopTop = NSScreen.screens.map(\.frame.maxY).max() else {
            return NSRect(x: accessibilityBounds.minX, y: accessibilityBounds.minY, width: accessibilityBounds.width, height: accessibilityBounds.height)
        }
        return NSRect(
            x: accessibilityBounds.minX,
            y: desktopTop - accessibilityBounds.maxY,
            width: accessibilityBounds.width,
            height: accessibilityBounds.height
        )
    }
}

private func frameFromTop(x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat, containerHeight: CGFloat) -> NSRect {
    NSRect(x: x, y: containerHeight - top - height, width: width, height: height)
}

@MainActor
private final class TooltipTextButton: NSButton {
    private var tracking: NSTrackingArea?

    init(title: String, symbol: String) {
        super.init(frame: .zero)
        self.title = title
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        imagePosition = .imageLeading
        imageHugsTitle = true
        imageScaling = .scaleProportionallyDown
        font = .systemFont(ofSize: 13, weight: .medium)
        contentTintColor = .white
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryPushIn)
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = TooltipPalette.hoverFill.cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor.clear.cgColor }
}

@MainActor
private final class TooltipIconButton: NSButton {
    init(symbol: String, accessibilityLabel: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        contentTintColor = .white
        setSymbol(symbol)
        toolTip = accessibilityLabel
        setAccessibilityLabel(accessibilityLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ name: String) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityLabel())
    }
}

@MainActor
private final class TooltipDragHandle: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    init() {
        super.init(frame: .zero)
        toolTip = "拖动浮窗"
        setAccessibilityLabel("拖动浮窗")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.white.withAlphaComponent(0.75).setFill()
        let dotSize: CGFloat = 2.4
        let horizontalGap: CGFloat = 4.2
        let verticalGap: CGFloat = 4.2
        let totalWidth = dotSize + horizontalGap
        let totalHeight = dotSize + verticalGap * 2
        let origin = NSPoint(
            x: floor((bounds.width - totalWidth) / 2),
            y: floor((bounds.height - totalHeight) / 2)
        )
        for row in 0..<3 {
            for column in 0..<2 {
                let rect = NSRect(
                    x: origin.x + CGFloat(column) * horizontalGap,
                    y: origin.y + CGFloat(row) * verticalGap,
                    width: dotSize,
                    height: dotSize
                )
                NSBezierPath(ovalIn: rect).fill()
            }
        }
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
