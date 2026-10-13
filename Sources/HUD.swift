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
    private enum Mode { case idle, listening, thinking, success, info }
    private enum Metrics {
        static let height: CGFloat = 48, padX: CGFloat = 18
        static let iconW: CGFloat = 32, iconH: CGFloat = 26, gap: CGFloat = 12
        static let minW: CGFloat = 220, maxW: CGFloat = 560
        static let barWeights: [CGFloat] = [0.55, 0.8, 1.0, 0.8, 0.55]
        static let previewChars = 34
    }
    private static let labelFont = NSFont.systemFont(ofSize: 15, weight: .medium)
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let barsView = BarsView()
    private let iconView = NSImageView()
    private let successIcon = HUD.symbol("checkmark.circle.fill", 21)
    private let infoIcon = HUD.symbol("info.circle.fill", 19)
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
            label.textColor = .white
        }
        let iconFrame = NSRect(x: Metrics.padX, y: (Metrics.height - Metrics.iconH) / 2,
                               width: Metrics.iconW, height: Metrics.iconH)
        barsView.frame = iconFrame
        iconView.frame = iconFrame
        iconView.imageAlignment = .alignCenter
        iconView.imageScaling = .scaleNone
        host.addSubview(barsView)
        host.addSubview(iconView)
        let textX = Metrics.padX + Metrics.iconW + Metrics.gap
        label.font = HUD.labelFont
        label.frame = NSRect(x: textX, y: (Metrics.height - 20) / 2, width: 260 - textX - Metrics.padX, height: 20)
        label.autoresizingMask = [.width]   // left edge fixed; text area follows panel width
        host.addSubview(label)
    }
    /// Shows a message. `cgPoint` is a CoreGraphics point (top-left origin of the primary screen).
    func show(_ text: String, at cgPoint: CGPoint? = nil, autoHide: TimeInterval? = nil) {
        hideWork?.cancel()
        generation += 1
        mode = HUD.classify(text)
        // Success text drops the leading "✓" and the spaces after it
        let shown = mode == .success ? String(String(text.dropFirst()).drop(while: { $0 == " " })) : text
        label.lineBreakMode = .byTruncatingTail
        label.stringValue = shown
        var origin = panel.frame.origin
        if let p = cgPoint {
            // CG (top-left origin) -> Cocoa (bottom-left origin of the primary screen)
            let h = NSScreen.screens.first?.frame.height ?? 0
            origin = NSPoint(x: p.x + 14, y: h - p.y - 60)   // just below the cursor
        }
        let wasHidden = !panel.isVisible
        if wasHidden { panel.alphaValue = 0 }
        let size = NSSize(width: targetWidth(for: shown), height: Metrics.height)
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
    /// Live words while speaking (about 5 calls per second). Keeps the newest words visible.
    func preview(_ text: String) {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let n = Metrics.previewChars
        let shown = flat.count > n ? "…" + String(flat.suffix(n)) : flat
        mode = .listening
        label.lineBreakMode = .byTruncatingHead
        label.stringValue = shown
        updateModeUI()
        if panel.isVisible {
            var f = panel.frame
            f.size.width = targetWidth(for: shown)
            apply(f, animated: true)
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
    /// Width = padding + icon + gap + text + padding, clamped to min...max.
    private func targetWidth(for s: String) -> CGFloat {
        let textW = ceil(NSAttributedString(string: s, attributes: [.font: HUD.labelFont]).size().width) + 8   // slack: NSTextField insets
        return min(max(Metrics.padX * 2 + Metrics.iconW + Metrics.gap + textW, Metrics.minW), Metrics.maxW)
    }
    /// Sets the panel frame. Animated changes keep the left edge where it is.
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
    }
    /// Picks the icon-area content for the current mode.
    private func updateModeUI() {
        let bars = mode == .listening || mode == .thinking
        barsView.isHidden = !bars
        barsView.alphaValue = mode == .thinking ? 0.7 : 1
        iconView.isHidden = bars || mode == .idle
        iconView.image = mode == .success ? successIcon : infoIcon
        iconView.contentTintColor = mode == .success ? .systemGreen : .secondaryLabelColor
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
