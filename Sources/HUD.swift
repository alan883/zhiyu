import AppKit
/// Brand violet for the level bars.
private let brandViolet = NSColor(srgbRed: 0.56, green: 0.36, blue: 1.0, alpha: 1)
/// Five rounded bars; HUD sets `heights`, `draw` paints them.
private final class BarsView: NSView {
    var heights: [CGFloat] = Array(repeating: 4, count: 5) { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let barW: CGFloat = 3.5, gap: CGFloat = 3
        var x = (bounds.width - (CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap)) / 2
        brandViolet.setFill()
        for h in heights {
            NSBezierPath(roundedRect: NSRect(x: x, y: (bounds.height - h) / 2, width: barW, height: h),
                         xRadius: 1.75, yRadius: 1.75).fill()
            x += barW + gap
        }
    }
}
/// Floating voice pill near the cursor: status text, live preview, mic level bars.
/// All calls must run on the main thread.
final class HUD {
    enum Mode { case idle, listening, thinking, success, info, polish }
    private enum Metrics {
        static let height: CGFloat = 48, padX: CGFloat = 18
        static let iconW: CGFloat = 32, iconH: CGFloat = 26, gap: CGFloat = 12
        static let minW: CGFloat = 200, maxW: CGFloat = 480
        static let barWeights: [CGFloat] = [0.55, 0.8, 1.0, 0.8, 0.55]
        static let previewChars = 34
        // Multi-line: past maxW the text wraps and the pill grows in both directions. No line cap.
        static let lineH: CGFloat = 20, vPad: CGFloat = 14, maxLines = 0
        static let previewCharsWrapped = 200
    }
    private static let labelFont = NSFont.systemFont(ofSize: 15, weight: .medium)
    private let panel: NSPanel
    private var glassView: NSView?
    private var materialView: NSView?
    private let label = NSTextField(labelWithString: "")
    private let barsView = BarsView()
    private let iconView = NSImageView()
    private let successIcon = HUD.symbol("checkmark.circle.fill", 21)
    private let infoIcon = HUD.symbol("info.circle.fill", 19)
    private let polishIcon = HUD.symbol("pencil.circle.fill", 19)
    private static func symbol(_ n: String, _ s: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: n, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: s, weight: .regular))
    }
    private var hideWork: DispatchWorkItem?
    private var timer: Timer?
    private var mode: Mode = .idle
    private var generation = 0          // bumped by show/hide; stale fade-out completions are ignored
    private var targetLevel: CGFloat = 0
    private var smoothLevel: CGFloat = 0
    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: Metrics.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Liquid Glass capsule on macOS 26+, dark HUD material before that
        let frame = panel.contentView!.bounds
        let host = NSView(frame: frame)
        host.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = frame.height / 2
            glass.autoresizingMask = [.width, .height]
            glass.contentView = host
            panel.contentView?.addSubview(glass)
            glassView = glass
            label.textColor = .labelColor
        } else {
            let bg = NSVisualEffectView(frame: frame)
            bg.material = .hudWindow
            bg.state = .active
            bg.wantsLayer = true
            bg.layer?.cornerRadius = frame.height / 2
            bg.autoresizingMask = [.width, .height]
            bg.addSubview(host)
            panel.contentView?.addSubview(bg)
            materialView = bg
            label.textColor = .white
        }
        host.addSubview(barsView)
        host.addSubview(iconView)
        iconView.imageAlignment = .alignCenter
        iconView.imageScaling = .scaleNone
        label.font = HUD.labelFont
        label.maximumNumberOfLines = 0
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.usesSingleLineMode = false
        host.addSubview(label)
        relayout()
    }
    /// Shows a message. `cgPoint` is a CoreGraphics point (top-left origin of the primary screen).
    func show(_ text: String, at cgPoint: CGPoint? = nil, autoHide: TimeInterval? = nil, force: Mode? = nil) {
        hideWork?.cancel()
        generation += 1
        mode = force ?? HUD.classify(text)
        // Success text drops the leading "✓" and the spaces after it
        let shown = mode == .success ? String(String(text.dropFirst()).drop(while: { $0 == " " })) : text
        let size = layoutSize(for: shown)
        label.lineBreakMode = .byTruncatingHead
        label.stringValue = shown
        let origin = anchorOrigin(size: size)
        let wasHidden = !panel.isVisible
        if wasHidden { panel.alphaValue = 0 }
        apply(NSRect(origin: origin, size: size), animated: !wasHidden && cgPoint == nil)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            self.panel.animator().alphaValue = 1
        }
        updateModeUI()
        syncTimer()
        if let t = autoHide {
            let w = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: w)
        }
    }
    /// Reports what the background polish changed, without touching the typed text.
    func showPolishChange(_ text: String) {
        let shown = text.count > 60 ? String(text.prefix(60)) + "…" : text
        show("已纠正：\(shown)", autoHide: 3.0, force: .polish)
    }
    /// Live words while speaking (about 5 calls per second). Keeps the newest words visible.
    func preview(_ text: String) {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let n = Metrics.previewCharsWrapped
        let shown = flat.count > n ? "…" + String(flat.suffix(n)) : flat
        mode = .listening
        let size = layoutSize(for: shown)
        label.lineBreakMode = .byTruncatingHead
        label.stringValue = shown
        updateModeUI()
        if panel.isVisible {
            apply(NSRect(origin: anchorOrigin(size: size), size: size), animated: true)
        }
        syncTimer()
    }
    /// Mic level 0...1 (about 20 calls per second while recording).
    func level(_ v: Float) { targetLevel = CGFloat(max(0, min(1, v))) }
    /// Fades out over 0.18 s, then orders the panel out. A show() during the fade cancels the removal.
    func hide() {
        hideWork?.cancel()
        generation += 1
        let gen = generation
        mode = .idle
        targetLevel = 0
        smoothLevel = 0
        syncTimer()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            self.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, gen == self.generation else { return }
            self.panel.orderOut(nil)
        })
    }

    // MARK: - Private
    private static func classify(_ text: String) -> Mode {
        if text.hasPrefix("听着") { return .listening }
        if text.hasPrefix("识别中") || text.hasPrefix("整理中") { return .thinking }
        if text.hasPrefix("✓") { return .success }
        return .info
    }
    /// Horizontally centred, just above the Dock. visibleFrame already excludes the Dock and menu bar.
    /// The pill is a fixed one-line strip: it never grows, so it cannot cover the text above it.
    private func anchorOrigin(size: NSSize) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: area.midX - size.width / 2, y: area.minY + 12)
    }
    /// One line, fixed height. The width follows the text up to maxW and never goes past it.
    private func layoutSize(for s: String) -> NSSize {
        let oneW = ceil(NSAttributedString(string: s, attributes: [.font: HUD.labelFont]).size().width) + 8   // slack: NSTextField insets
        let w = min(max(Metrics.padX * 2 + Metrics.iconW + Metrics.gap + oneW, Metrics.minW), Metrics.maxW)
        return NSSize(width: w, height: Metrics.height)
    }
    /// Positions the bars, icon and label for a given panel size (icon stays on the first text line).
    private func relayout(width: CGFloat? = nil, height: CGFloat? = nil) {
        let w = width ?? panel.frame.width
        let textX = Metrics.padX + Metrics.iconW + Metrics.gap
        let iconY = (Metrics.height - Metrics.iconH) / 2
        let iconFrame = NSRect(x: Metrics.padX, y: iconY, width: Metrics.iconW, height: Metrics.iconH)
        barsView.frame = iconFrame
        iconView.frame = iconFrame
        label.frame = NSRect(x: textX, y: (Metrics.height - Metrics.lineH) / 2,
                             width: max(40, w - textX - Metrics.padX), height: Metrics.lineH)
    }
    /// Sets the panel frame; the top edge is preserved so the pill grows downward.
    private func apply(_ f: NSRect, animated: Bool) {
        guard f != panel.frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self.panel.animator().setFrame(f, display: true)
            }
        } else {
            panel.setFrame(f, display: true)
        }
        relayout(width: f.width, height: f.height)
        let radius = min(24, f.height / 2)
        if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
            glass.cornerRadius = radius
        } else if let bg = materialView {
            bg.layer?.cornerRadius = radius
        }
    }
    /// Picks the icon-area content for the current mode.
    private func updateModeUI() {
        let bars = mode == .listening || mode == .thinking
        barsView.isHidden = !bars
        barsView.alphaValue = mode == .thinking ? 0.7 : 1
        iconView.isHidden = bars || mode == .idle
        switch mode {
        case .success: iconView.image = successIcon; iconView.contentTintColor = .systemGreen
        case .polish:  iconView.image = polishIcon;  iconView.contentTintColor = .systemPurple
        default:       iconView.image = infoIcon;    iconView.contentTintColor = .secondaryLabelColor
        }
    }
    /// The 30 fps timer runs only while the panel is visible in listening or thinking mode.
    private func syncTimer() {
        let animated = panel.isVisible && (mode == .listening || mode == .thinking)
        if animated, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
        } else if !animated {
            timer?.invalidate()
            timer = nil
        }
    }
    private func tick() {
        guard panel.isVisible else { return }
        // Fast attack (0.6), slow release (0.15)
        smoothLevel += (targetLevel - smoothLevel) * (targetLevel > smoothLevel ? 0.6 : 0.15)
        let t = ProcessInfo.processInfo.systemUptime
        barsView.heights = (0..<5).map { i -> CGFloat in
            let w = Metrics.barWeights[i], phase = Double(i)
            if mode == .thinking {
                // travelling wave across the bars
                return 5 + 17 * CGFloat(0.5 + 0.5 * sin(t * 6 - phase * 1.1)) * w
            }
            // level-driven height plus a small wobble so the bars move at a constant level
            return min(Metrics.iconH, 5 + 20 * smoothLevel * w + 1.5 * CGFloat(0.5 + 0.5 * sin(t * 7 + phase * 1.9)))
        }
    }
}
