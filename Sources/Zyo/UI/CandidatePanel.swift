import AppKit
import ZyoCore

struct CandidatePanelModel {
    var candidates: [String] = []
    var highlightedIndex = 0
    var focus: Focus = .candidates
    var translation = ""
    var translationDimmed = true
    /// 提示（flash）左侧的 SF Symbol 名，只在提示时设置
    var symbol: String?
}

/// 全局唯一的候选窗，不抢焦点；点击通过回调交给当前激活的 InputController。
@MainActor
final class CandidatePanel {
    static let shared = CandidatePanel()

    var onSelectCandidate: ((Int) -> Void)?
    var onCommitTranslation: (() -> Void)?

    private let panel: NSPanel
    private let view = CandidateView()
    private var flashHideTask: Task<Void, Never>?

    private init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        // 用 maskImage 而不是 layer 圆角裁剪，窗口阴影才会跟随圆角
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: CandidateView.cornerRadius)
        view.autoresizingMask = [.width, .height]
        background.addSubview(view)
        panel.contentView = background

        view.onSelectCandidate = { [weak self] in self?.onSelectCandidate?($0) }
        view.onCommitTranslation = { [weak self] in self?.onCommitTranslation?() }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let mask = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        return mask
    }

    func show(_ model: CandidatePanelModel, cursorRect: NSRect) {
        flashHideTask?.cancel()
        view.model = model
        let size = view.contentSize
        let anchor = cursorRect == .zero ? NSRect(origin: NSEvent.mouseLocation, size: .zero) : cursorRect
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        var origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height - 4)
        if origin.y < visible.minY {
            origin.y = anchor.maxY + 4
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.invalidateShadow()
        panel.orderFrontRegardless()
    }

    func hide() {
        flashHideTask?.cancel()
        panel.orderOut(nil)
    }

    /// 短暂显示一条提示（如切换方向、词库部署中），1 秒后自动隐藏
    func flash(_ message: String, symbol: String, cursorRect: NSRect) {
        show(CandidatePanelModel(translation: message, translationDimmed: false, symbol: symbol), cursorRect: cursorRect)
        flashHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.panel.orderOut(nil)
        }
    }
}

private final class CandidateView: NSView {
    enum Target: Equatable {
        case candidate(Int)
        case translation
    }

    var onSelectCandidate: ((Int) -> Void)?
    var onCommitTranslation: (() -> Void)?

    var model = CandidatePanelModel() {
        didSet {
            relayout()
            needsDisplay = true
        }
    }

    private(set) var contentSize: NSSize = .zero
    private var candidateRects: [NSRect] = []
    private var translationRect: NSRect = .zero
    private var hovered: Target? {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }

    static let cornerRadius: CGFloat = 10
    private let padding: CGFloat = 6
    private let itemPadX: CGFloat = 8
    private let itemPadY: CGFloat = 4
    /// 候选行与译文行之间分隔线上下各留的间距
    private let separatorGap: CGFloat = 4
    private let maxTranslationWidth: CGFloat = 520
    private let candidateFont = NSFont.systemFont(ofSize: 17)
    private let indexFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let translationFont = NSFont.systemFont(ofSize: 14)
    private let flashFont = NSFont.systemFont(ofSize: 15, weight: .medium)
    private let symbolGap: CGFloat = 6
    private var separatorY: CGFloat?
    private var symbolImage: NSImage?

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 布局

    private func candidateString(_ index: Int, active: Bool) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: "\(index + 1) ",
            attributes: [
                .font: indexFont,
                .foregroundColor: active ? NSColor.white.withAlphaComponent(0.8) : NSColor.secondaryLabelColor,
                .baselineOffset: 2,
            ]
        )
        text.append(NSAttributedString(
            string: model.candidates[index],
            attributes: [.font: candidateFont, .foregroundColor: active ? NSColor.white : NSColor.labelColor]
        ))
        return text
    }

    private func translationString() -> NSAttributedString {
        let active = model.focus == .translation
        let color: NSColor = active ? .white : (model.translationDimmed ? .secondaryLabelColor : .labelColor)
        let font = model.symbol == nil ? translationFont : flashFont
        return NSAttributedString(string: model.translation, attributes: [.font: font, .foregroundColor: color])
    }

    private func relayout() {
        candidateRects = []
        var x = padding
        var rowHeight: CGFloat = 0
        for index in model.candidates.indices {
            let size = candidateString(index, active: false).size()
            let rect = NSRect(x: x, y: padding, width: ceil(size.width) + itemPadX * 2, height: ceil(size.height) + itemPadY * 2)
            candidateRects.append(rect)
            x = rect.maxX
            rowHeight = max(rowHeight, rect.height)
        }

        let candidateRowWidth = x - padding
        let translation = translationString()
        let textWidth = max(candidateRowWidth - itemPadX * 2, min(ceil(translation.size().width), maxTranslationWidth))
        let bounds = translation.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        symbolImage = model.symbol
            .flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
                    .applying(.init(paletteColors: [.controlAccentColor]))
            )
        let symbolWidth = symbolImage.map { ceil($0.size.width) + symbolGap } ?? 0
        let rowWidth = symbolWidth + textWidth + itemPadX * 2
        // 只有提示文字（flash）时没有候选行，也就不画分隔线
        separatorY = candidateRects.isEmpty ? nil : padding + rowHeight + separatorGap
        translationRect = NSRect(
            x: padding,
            y: separatorY.map { $0 + 1 + separatorGap } ?? padding,
            width: rowWidth,
            height: ceil(bounds.height) + itemPadY * 2
        )
        contentSize = NSSize(width: rowWidth + padding * 2, height: translationRect.maxY + padding)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        // 毛玻璃上叠一层半透明底色：否则深色内容（如终端）会透上来，底色发灰、描边发白
        let radius = Self.cornerRadius
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSColor.windowBackgroundColor.withAlphaComponent(0.5).setFill()
        outline.fill()
        NSColor.separatorColor.setStroke()
        outline.stroke()

        for (index, rect) in candidateRects.enumerated() {
            let highlighted = index == model.highlightedIndex
            let active = highlighted && model.focus == .candidates
            if highlighted {
                (active ? NSColor.controlAccentColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            } else if hovered == .candidate(index) {
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            }
            candidateString(index, active: active).draw(at: NSPoint(x: rect.minX + itemPadX, y: rect.minY + itemPadY))
        }

        if let separatorY {
            NSColor.separatorColor.setFill()
            NSRect(x: padding + itemPadX, y: separatorY, width: bounds.width - (padding + itemPadX) * 2, height: 1).fill()
        }

        if model.focus == .translation {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: translationRect, xRadius: 6, yRadius: 6).fill()
        } else if hovered == .translation {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: translationRect, xRadius: 6, yRadius: 6).fill()
        }
        var textRect = translationRect.insetBy(dx: itemPadX, dy: itemPadY)
        if let symbolImage {
            let size = symbolImage.size
            symbolImage.draw(in: NSRect(
                x: textRect.minX, y: textRect.midY - size.height / 2, width: size.width, height: size.height
            ))
            textRect.origin.x += ceil(size.width) + symbolGap
            textRect.size.width -= ceil(size.width) + symbolGap
        }
        translationString().draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    // MARK: 鼠标

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    private func target(at event: NSEvent) -> Target? {
        let point = convert(event.locationInWindow, from: nil)
        if let index = candidateRects.firstIndex(where: { $0.contains(point) }) {
            return .candidate(index)
        }
        return translationRect.contains(point) ? .translation : nil
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = target(at: event)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
    }

    override func mouseDown(with event: NSEvent) {
        switch target(at: event) {
        case let .candidate(index): onSelectCandidate?(index)
        case .translation: onCommitTranslation?()
        case nil: break
        }
    }
}
