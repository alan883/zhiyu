import AppKit

/// 概览面板：麦克风 / 运行状态 / 使用统计 / 个人词典 / 上次输入。
/// 所有 setter 只存状态；视图加载后统一由 render() 刷新。
final class OverviewPane: NSViewController {

    // MARK: - 状态

    private var asrOK = false
    private var axOK = false
    private var micOK = false
    private var tapOK = false
    private var micName = "—"
    private var micSymbol = "mic.fill"
    private var micBuiltIn = true
    private var prevMicName: String?             // 上一次 setMic 的设备名，判断是否切换
    private var micGen = 0                       // 每次切换 +1，过期动画回调直接丢弃
    private var micAnimating = false             // 动效进行中，render 不覆盖麦克风区
    private var micCardView: NSView?             // 麦克风卡片，强调环加在它的图层上
    private var lastRaw = ""
    private var lastClean = ""
    private var lastMs = 0
    private var warning: String?
    private var dictations = 0
    private var todayChars = 0
    private var medianFirstMs: Int?
    private var manualCount = 0
    private var learnedTerms = 0
    private var corrections = 0
    private var lastLearn: String?

    // MARK: - 视图引用（在 loadView 中创建）

    private var pillBox: NSView!
    private var pillLabel: NSTextField!
    private var warnBox: NSView!
    private var warnLabel: NSTextField!
    private var micIcon: NSImageView!
    private var micNameLabel: NSTextField!
    private var micSubLabel: NSTextField!
    private var dots: [NSImageView] = []         // 顺序：ASR / AX / MIC / TAP（SF Symbol 状态图标）
    private var fixButtons: [NSButton?] = []     // 同上，仅权限行有按钮
    private var statValues: [NSTextField] = []   // 总句数 / 今日字数 / 上屏中位
    private var lexLabel: NSTextField!
    private var lexLearnLabel: NSTextField!
    private var lastCleanLabel: NSTextField!
    private var lastRawLabel: NSTextField!
    private var netRow: NSStackView!             // 数据去向：每步一列
    private var netBadgeBox: NSView!
    private var netBadgeLabel: NSTextField!
    private var netBadgeIcon: NSImageView!
    private var netPlan: [(step: String, where: String)] = []
    private var netOffline = false

    // MARK: - 生命周期

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var built = false

    override func loadView() {
        let root = NSView()
        view = root
        buildUI(in: root)
        built = true   // render() may be triggered while views are still being created
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
    }

    // MARK: - 公开接口

    func update(asrOK: Bool, axOK: Bool, micOK: Bool, tapOK: Bool) {
        self.asrOK = asrOK
        self.axOK = axOK
        self.micOK = micOK
        self.tapOK = tapOK
        render()
    }

    func setMic(name: String, symbol: String, builtIn: Bool) {
        let prev = prevMicName
        prevMicName = name
        micName = name
        micSymbol = symbol
        micBuiltIn = builtIn
        if built, let p = prev, p != name, view.window != nil {
            animateMicChange()
        }
        render()
    }

    func setLast(raw: String, clean: String, ms: Int) {
        lastRaw = raw
        lastClean = clean
        lastMs = ms
        render()
    }

    func setWarning(_ text: String?) {
        warning = text
        render()
    }

    func setStats(dictations: Int, todayChars: Int, medianFirstMs: Int?) {
        self.dictations = dictations
        self.todayChars = todayChars
        self.medianFirstMs = medianFirstMs
        render()
    }

    func setLexicon(manual: Int, learnedTerms: Int, corrections: Int, lastLearn: String?) {
        manualCount = manual
        self.learnedTerms = learnedTerms
        self.corrections = corrections
        self.lastLearn = lastLearn
        render()
    }

    /// 数据去向：每步一项（步骤名 → 去向）；offline 为全程本机时 true。render 前安全。
    func setNetworkPlan(_ plan: [(step: String, where: String)], offline: Bool) {
        netPlan = plan
        netOffline = offline
        rebuildNetworkRow()
        render()
    }

    // MARK: - 构建界面

    private func buildUI(in root: NSView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        root.addSubview(scroll)
        pin(scroll, in: root)

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
        ])

        let main = stack([], vertical: true, spacing: 16, alignment: .leading)
        doc.addSubview(main)
        NSLayoutConstraint.activate([
            main.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 24),
            main.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -24),
            main.topAnchor.constraint(equalTo: doc.topAnchor, constant: 24),
            main.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -24),
        ])

        // 标题 + 状态胶囊
        let title = label("概览", size: 26, weight: .bold, lines: 1)
        pillLabel = label("", size: 13, weight: .semibold, lines: 1)
        pillBox = makePill(pillLabel)
        addFull(stack([title, spacer(), pillBox], vertical: false, spacing: 12, alignment: .centerY), to: main)

        // 警告横幅
        let warnIcon = NSImageView(image: symbolImage("exclamationmark.triangle.fill", size: 16, tint: .systemOrange))
        warnLabel = label("", size: 13, weight: .medium, lines: 3)
        warnBox = glass(stack([warnIcon, warnLabel], vertical: false, spacing: 10, alignment: .top),
                        tint: NSColor.systemOrange.withAlphaComponent(0.25), inset: 12)
        addFull(warnBox, to: main)

        // 卡片：麦克风
        micIcon = NSImageView()
        micNameLabel = label("", size: 15, weight: .medium, lines: 1)
        micSubLabel = label("", size: 12, weight: .regular, color: .secondaryLabelColor, lines: 2)
        let micBody = stack([micIcon, stack([micNameLabel, micSubLabel], vertical: true, spacing: 4, alignment: .leading)],
                            vertical: false, spacing: 14, alignment: .centerY)
        let micCard = card("mic.fill", "麦克风", micBody)
        micCardView = micCard

        // 卡片：运行状态
        dots = []
        fixButtons = []
        var statusViews: [NSView] = []
        let rowSpecs: [(String, Int?)] = [("识别引擎", nil), ("辅助功能权限", 1), ("麦克风权限", 2), ("快捷键监听", nil)]
        for (text, tag) in rowSpecs {
            let (row, dot, btn) = statusRow(text, fixTag: tag)
            statusViews.append(row)
            dots.append(dot)
            fixButtons.append(btn)
        }
        let statusCard = card("checkmark.shield.fill", "运行状态", stack(statusViews, vertical: true, spacing: 8, alignment: .leading))

        // 卡片：使用统计
        var statCols: [NSView] = []
        statValues = []
        for caption in ["总句数", "今日字数", "上屏中位"] {
            let value = label("0", size: 28, weight: .semibold, lines: 1)
            let statBase = NSFont.systemFont(ofSize: 28, weight: .semibold)
            let statDesc = (statBase.fontDescriptor.withDesign(.rounded) ?? statBase.fontDescriptor).addingAttributes([
                .featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]],
            ])
            value.font = NSFont(descriptor: statDesc, size: 28) ?? statBase
            let cap = label(caption, size: 11, weight: .regular, color: .secondaryLabelColor, lines: 1)
            statValues.append(value)
            statCols.append(stack([value, cap], vertical: true, spacing: 2, alignment: .leading))
        }
        let statsRow = stack(statCols, vertical: false, spacing: 12, alignment: .top)
        statsRow.distribution = .fillEqually
        let statsCard = card("chart.bar.fill", "使用统计", statsRow)

        // 卡片：个人词典
        lexLabel = label("", size: 13, weight: .regular, lines: 2)
        lexLearnLabel = label("", size: 12, weight: .regular, color: .secondaryLabelColor, lines: 1)
        let lexCard = card("character.book.closed.fill", "个人词典",
                           stack([lexLabel, lexLearnLabel], vertical: true, spacing: 6, alignment: .leading))

        // 两列网格：每行等宽，同行卡片等高
        let row1 = stack([micCard, statusCard], vertical: false, spacing: 16, alignment: .top)
        row1.distribution = .fillEqually
        let row2 = stack([statsCard, lexCard], vertical: false, spacing: 16, alignment: .top)
        row2.distribution = .fillEqually
        addFull(row1, to: main)
        addFull(row2, to: main)
        equalHeight(micCard, statusCard)
        equalHeight(statsCard, lexCard)

        // 全宽卡片：数据去向（2×2 之下、上次输入之上）
        addFull(networkCard(), to: main)

        // 底部全宽卡片：上次输入
        lastCleanLabel = label("", size: 15, weight: .medium, lines: 4)
        lastRawLabel = label("", size: 12, weight: .regular, color: .secondaryLabelColor, lines: 2)
        let lastCard = card("text.bubble.fill", "上次输入",
                            stack([lastCleanLabel, lastRawLabel], vertical: true, spacing: 6, alignment: .leading))
        addFull(lastCard, to: main)
    }

    // MARK: - 渲染

    private func render() {
        guard isViewLoaded, built else { return }

        // 胶囊
        let allOK = asrOK && axOK && micOK && tapOK
        let statusColor: NSColor = allOK ? .systemGreen : .systemOrange
        pillLabel.stringValue = allOK ? "● 就绪" : "● 需要处理"
        pillLabel.textColor = statusColor
        if #available(macOS 26.0, *), let g = pillBox as? NSGlassEffectView {
            g.tintColor = statusColor.withAlphaComponent(0.25)
        } else {
            pillBox.layer?.backgroundColor = statusColor.withAlphaComponent(0.18).cgColor
        }

        // 数据去向徽章
        let netTint: NSColor = netOffline ? .systemGreen : .systemGray
        netBadgeLabel.stringValue = netOffline ? "完全离线" : "部分联网"
        netBadgeLabel.textColor = netOffline ? .systemGreen : .secondaryLabelColor
        netBadgeIcon.isHidden = !netOffline
        if #available(macOS 26.0, *), let g = netBadgeBox as? NSGlassEffectView {
            g.tintColor = netTint.withAlphaComponent(0.25)
        } else {
            netBadgeBox.layer?.backgroundColor = netTint.withAlphaComponent(0.18).cgColor
        }

        // 警告
        let warnText = warning ?? ""
        warnBox.isHidden = warnText.isEmpty
        warnLabel.stringValue = warnText

        // 麦克风
        // 切换动效进行中不覆盖，动效收尾时统一落值
        if !micAnimating {
            applyMicIcon()
            applyMicText()
        }

        // 运行状态
        let oks = [asrOK, axOK, micOK, tapOK]
        for i in 0..<min(oks.count, dots.count) {
            dots[i].image = oks[i]
                ? symbolImage("checkmark.circle.fill", size: 13, tint: .systemGreen)
                : symbolImage("exclamationmark.circle.fill", size: 13, tint: .systemOrange)
            fixButtons[i]?.isHidden = oks[i]
        }

        // 统计
        if statValues.count == 3 {
            statValues[0].stringValue = "\(dictations)"
            statValues[1].stringValue = "\(todayChars)"
            if let ms = medianFirstMs {
                statValues[2].stringValue = String(format: "%.2f s", Double(ms) / 1000)
            } else {
                statValues[2].stringValue = "—"
            }
        }

        // 词典
        lexLabel.stringValue = "手动 \(manualCount) · 学到 \(learnedTerms) 词 · \(corrections) 条纠错"
        let learn = lastLearn ?? "—"
        lexLearnLabel.stringValue = "上次学习 \(learn)"

        // 上次输入
        let shown = lastClean.isEmpty ? lastRaw : lastClean
        if shown.isEmpty {
            lastCleanLabel.stringValue = "还没有输入。按住快捷键说话试试。"
            lastCleanLabel.textColor = .secondaryLabelColor
            lastCleanLabel.toolTip = nil
            lastRawLabel.isHidden = true
        } else {
            lastCleanLabel.stringValue = shown
            lastCleanLabel.textColor = .labelColor
            lastCleanLabel.toolTip = shown
            lastRawLabel.isHidden = false
            let sec = String(format: "%.1f", Double(lastMs) / 1000)
            lastRawLabel.stringValue = "原文：\(lastRaw) · 耗时 \(sec) s"
        }
    }

    /// 数据去向卡片：标题行 + 右侧胶囊徽章 + 四列流 + 脚注。
    private func networkCard() -> NSView {
        netBadgeLabel = label("", size: 12, weight: .semibold, lines: 1)
        netBadgeIcon = NSImageView(image: symbolImage("lock.fill", size: 11, tint: .systemGreen))
        netBadgeBox = makePill(stack([netBadgeIcon, netBadgeLabel], vertical: false, spacing: 4, alignment: .centerY))

        let icon = NSImageView(image: symbolImage("arrow.triangle.branch", size: 17, tint: .controlAccentColor))
        let head = stack([icon, label("数据去向", size: 13, weight: .semibold, lines: 1), spacer(), netBadgeBox],
                         vertical: false, spacing: 8, alignment: .centerY)

        netRow = stack([], vertical: false, spacing: 12, alignment: .top)
        netRow.distribution = .fillEqually
        rebuildNetworkRow()

        let foot = label("声音始终只在本机处理，从不上传。", size: 11, weight: .regular,
                         color: .secondaryLabelColor, lines: 1)
        let body = stack([], vertical: true, spacing: 12, alignment: .leading)
        addFull(head, to: body)
        addFull(netRow, to: body)
        addFull(foot, to: body)
        return glass(body, inset: 18, radius: 20)
    }

    /// 按 netPlan 重建四列流；视图未加载时直接返回（buildUI 会再调一次）。
    private func rebuildNetworkRow() {
        guard let row = netRow else { return }
        for v in row.arrangedSubviews {
            row.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for (step, dest) in netPlan {
            let local = dest.hasPrefix("本地") || dest.hasPrefix("仅本地")
            let cloud = dest.hasPrefix("云端")
            let symName = local ? "laptopcomputer" : (cloud ? "cloud" : "questionmark.circle")
            let symTint: NSColor = local ? .systemGreen : (cloud ? .systemBlue : .secondaryLabelColor)
            let icon = NSImageView(image: symbolImage(symName, size: 12, tint: symTint))
            let destRow = stack([icon, label(dest, size: 13, weight: .medium, lines: 2)],
                                vertical: false, spacing: 4, alignment: .centerY)
            let col = stack([label(step, size: 11, weight: .regular, color: .secondaryLabelColor, lines: 1), destRow],
                            vertical: true, spacing: 4, alignment: .leading)
            row.addArrangedSubview(col)
        }
    }

    // MARK: - 行与卡片

    private func statusRow(_ text: String, fixTag: Int?) -> (NSStackView, NSImageView, NSButton?) {
        let dot = NSImageView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        var views: [NSView] = [dot, label(text, size: 13, weight: .regular, lines: 1), spacer()]
        var button: NSButton?
        if let tag = fixTag {
            let b = NSButton(title: "去开启", target: self, action: #selector(openPrivacy(_:)))
            b.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
            b.imagePosition = .imageTrailing
            b.controlSize = .small
            if #available(macOS 26.0, *) {
                b.bezelStyle = .glass
                b.borderShape = .capsule
                b.tintProminence = .primary
            } else {
                b.bezelStyle = .push
            }
            b.tag = tag
            b.isHidden = true
            views.append(b)
            button = b
        }
        return (stack(views, vertical: false, spacing: 8, alignment: .centerY), dot, button)
    }

    private func card(_ symbol: String, _ title: String, _ content: NSView) -> NSView {
        let icon = NSImageView(image: symbolImage(symbol, size: 17, tint: .controlAccentColor))
        let head = stack([icon, label(title, size: 13, weight: .semibold, lines: 1)],
                         vertical: false, spacing: 8, alignment: .centerY)
        let body = stack([], vertical: true, spacing: 12, alignment: .leading)
        addFull(head, to: body)
        addFull(content, to: body)
        return glass(body, inset: 18, radius: 20)
    }

    private func makePill(_ text: NSView) -> NSView {
        let box: NSView
        let host = NSView()
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = 12   // 胶囊：高 24 的一半
            g.contentView = host
            box = g
        } else {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.cornerRadius = 12
            v.addSubview(host)
            box = v
        }
        box.translatesAutoresizingMaskIntoConstraints = false
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(text)
        text.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            host.topAnchor.constraint(equalTo: box.topAnchor),
            host.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            text.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -10),
            text.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            box.heightAnchor.constraint(equalToConstant: 24),
        ])
        return box
    }

    /// 毛玻璃卡片：macOS 26+ 用 NSGlassEffectView，否则回退 NSVisualEffectView。
    private func glass(_ content: NSView, tint: NSColor? = nil, inset: CGFloat, radius: CGFloat = 18) -> NSView {
        let box = NSView()
        pin(content, in: box, inset: inset)
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = radius
            g.tintColor = tint
            g.contentView = box
            return g
        }
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .withinWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = radius
        v.layer?.masksToBounds = true
        v.layer?.backgroundColor = tint?.cgColor
        pin(box, in: v)
        return v
    }

    private func equalHeight(_ a: NSView, _ b: NSView) {
        let c = a.heightAnchor.constraint(equalTo: b.heightAnchor)
        c.priority = .defaultHigh
        c.isActive = true
    }

    // MARK: - 麦克风切换动效

    private func applyMicIcon() {
        micIcon.image = symbolImage(micSymbol, size: 36, tint: .controlAccentColor)
    }

    private func applyMicText() {
        micNameLabel.stringValue = micName
        micSubLabel.stringValue = micBuiltIn ? "内置麦克风" : "外接设备 · 已自动切换"
    }

    /// 图标：淡出缩到 0.6 → 换图 → 淡入 + 弹簧回 1.0；文字：淡出 → 换字 → 上滑淡入；加强调环。
    /// 减弱动态效果时只做淡入淡出。
    private func animateMicChange() {
        micGen += 1
        let gen = micGen
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let easeIn = CAMediaTimingFunction(name: .easeIn)
        let easeOut = CAMediaTimingFunction(name: .easeOut)
        let labels = [micNameLabel!, micSubLabel!]

        guard let icon = centerAnchor(micIcon) else { return }
        micAnimating = true
        icon.removeAllAnimations()
        let out = CAAnimationGroup()
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1
        fadeOut.toValue = 0
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1
        shrink.toValue = reduce ? 1 : 0.6
        out.animations = [fadeOut, shrink]
        out.duration = 0.18
        out.timingFunction = easeIn
        out.fillMode = .forwards
        out.isRemovedOnCompletion = false   // 收尾前保持终态，避免闪回
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self = self, gen == self.micGen else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            icon.removeAllAnimations()
            self.applyMicIcon()
            icon.opacity = 1
            icon.transform = CATransform3DIdentity
            CATransaction.commit()
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.duration = 0.2
            icon.add(fadeIn, forKey: "micFadeIn")
            if !reduce {
                let spring = CASpringAnimation(keyPath: "transform.scale")
                spring.mass = 1
                spring.stiffness = 260
                spring.damping = 14
                spring.initialVelocity = 0
                spring.fromValue = 0.6
                spring.toValue = 1.0
                spring.duration = spring.settlingDuration
                icon.add(spring, forKey: "micSpring")
                self.pulseRing()
            }
        }
        icon.add(out, forKey: "micOut")
        CATransaction.commit()

        // 文字
        labels.forEach { $0.wantsLayer = true; $0.layer?.removeAllAnimations() }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = easeIn
            labels.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            guard let self = self, gen == self.micGen else { return }
            self.applyMicText()
            let dy: CGFloat = reduce ? 0 : 6
            for l in labels {
                // 翻转坐标层里 +y 朝下，所以"从下方"的起点按 isGeometryFlipped 取符号
                let flipped = l.layer?.isGeometryFlipped ?? true
                let slide = CABasicAnimation(keyPath: "transform.translation.y")
                slide.fromValue = flipped ? dy : -dy
                slide.toValue = 0
                slide.duration = 0.25
                slide.timingFunction = easeOut
                l.layer?.add(slide, forKey: "micSlide")
            }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.timingFunction = easeOut
                labels.forEach { $0.animator().alphaValue = 1 }
            }, completionHandler: { [weak self] in
                guard let self = self, gen == self.micGen else { return }
                self.micAnimating = false
            })
        })
    }

    /// 图标强调环：以图标中心为圆心，缩放 1.0→1.8、透明度 0.6→0，0.6s 后移除。
    private func pulseRing() {
        guard let host = micCardView else { return }
        host.wantsLayer = true
        guard let hl = host.layer else { return }
        let c = host.convert(NSPoint(x: micIcon.bounds.midX, y: micIcon.bounds.midY), from: micIcon)
        let r: CGFloat = 22
        let ring = CAShapeLayer()
        ring.frame = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = NSColor.controlAccentColor.cgColor
        ring.lineWidth = 2
        ring.opacity = 0
        hl.addSublayer(ring)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 1.8
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.6
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.6
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "pulse")
        CATransaction.commit()
    }

    /// 把锚点挪到中心并补偿 position，视觉位置不变（缩放才围绕中心）。
    private func centerAnchor(_ v: NSView) -> CALayer? {
        v.wantsLayer = true
        guard let l = v.layer else { return nil }
        l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        l.position = CGPoint(x: v.frame.midX, y: v.frame.midY)
        return l
    }

    // MARK: - 小工具

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       color: NSColor = .labelColor, lines: Int) -> NSTextField {
        let t = NSTextField(labelWithString: text)
        t.font = .systemFont(ofSize: size, weight: weight)
        t.textColor = color
        t.maximumNumberOfLines = lines
        t.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        t.cell?.truncatesLastVisibleLine = true
        t.isSelectable = false
        return t
    }

    private func stack(_ views: [NSView], vertical: Bool, spacing: CGFloat,
                       alignment: NSLayoutConstraint.Attribute) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = vertical ? .vertical : .horizontal
        s.spacing = spacing
        s.alignment = alignment
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    private func addFull(_ v: NSView, to s: NSStackView) {
        s.addArrangedSubview(v)
        v.leadingAnchor.constraint(equalTo: s.leadingAnchor).isActive = true
        v.trailingAnchor.constraint(equalTo: s.trailingAnchor).isActive = true
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        return v
    }

    private func symbolImage(_ name: String, size: CGFloat, tint: NSColor) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: tint))
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        return img?.withSymbolConfiguration(config) ?? NSImage()
    }

    private func pin(_ child: NSView, in parent: NSView, inset: CGFloat = 0) {
        if child.superview !== parent { parent.addSubview(child) }   // constraints need a common ancestor
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
        ])
    }

    @objc private func openPrivacy(_ sender: NSButton) {
        let pane = sender.tag == 1 ? "Privacy_Accessibility" : "Privacy_Microphone"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
