import AppKit

/// System Settings style detail pane: grouped glass cards of rows.
/// Setters may be called before the view loads; state is stored and applied once views exist.
final class SettingsPane: NSViewController {
    var onChangeHotkey: ((@escaping (String?) -> Void) -> Void)?
    var onToggleForceClick: ((Bool) -> Void)?
    var onToggleNoiseMode: ((Bool) -> Void)?
    var onTogglePreferBuiltIn: ((Bool) -> Void)?
    var onChangePolish: ((String) -> Void)?      // "fast" | "auto" | "local"
    var onToggleTwoPass: ((Bool) -> Void)?
    var onToggleLaunchAtLogin: ((Bool) -> Void)?
    var onToggleHandsFree: ((Bool) -> Void)?
    var onToggleAutoSend: ((Bool) -> Void)?
    var onToggleOffline: ((Bool) -> Void)?
    var onChangeAppStyle: ((String, String) -> Void)?   // (bundleID, style) ; style "" = remove user override

    // MARK: - Stored state

    private var hotkeyLabel = "右 Option"
    private var forceClick = false
    private var noiseMode = false
    private var preferBuiltIn = true
    private var polish = "fast"
    private var twoPass = false
    private var launchAtLogin = false
    private var handsFree = false
    private var autoSend = false
    private var offline = false
    private var appStyleRows: [(bundleID: String, name: String, style: String, isDefault: Bool)] = []

    private static let polishValues = ["fast", "auto", "local"]
    private static let polishHints: [String: String] = [
        "fast": "只用本地规则 + 拼音词典纠错 · 零延迟",
        "auto": "云端 DeepSeek 润色（两遍模式下不拖慢上屏）",
        "local": "本地 4B 模型润色，可离线 · 约 3 秒",
    ]
    private static let appStyleValues = ["default", "casual", "formal", "code"]
    private static let appStyleTitles = ["默认", "口语", "正式", "技术"]
    private static let paneSize = NSSize(width: 690, height: 560)
    private static let sideInset: CGFloat = 24
    private static let cardRadius: CGFloat = 20

    // MARK: - Views updated after load

    private var keycapLabel: NSTextField?
    private var hotkeyButton: NSButton?
    private var forceSwitch: NSSwitch?
    private var noiseSwitch: NSSwitch?
    private var preferBuiltInSwitch: NSSwitch?
    private var polishControl: NSSegmentedControl?
    private var polishHint: NSTextField?
    private var twoPassSwitch: NSSwitch?
    private var launchSwitch: NSSwitch?
    private var handsFreeSwitch: NSSwitch?
    private var autoSendSwitch: NSSwitch?
    private var offlineSwitch: NSSwitch?
    private var appStyleStack: NSStackView?
    private var appStyleHeight: NSLayoutConstraint?

    // MARK: - Lifecycle

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "设置"
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsPane is code-only")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: Self.paneSize))
        view = root
        preferredContentSize = Self.paneSize

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        pinEdges(scroll, to: root)

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])

        let triggerSection = section("触发", card: triggerCard())
        let polishSection = section("识别与润色", card: polishCard())
        let appStyleSection = section("按应用的风格", card: appStyleCard())
        let privacySection = section("隐私", card: privacyCard())
        let generalSection = section("通用", card: generalCard())

        let sections: [NSView] = [
            text("设置", size: 26, weight: .bold),
            triggerSection,
            polishSection,
            appStyleSection,
            privacySection,
            generalSection,
        ]
        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: Self.sideInset, left: Self.sideInset,
                                        bottom: Self.sideInset, right: Self.sideInset)
        doc.addSubview(stack)
        pinEdges(stack, to: doc)
        fillWidth(sections, in: stack, inset: Self.sideInset * 2)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyState()
    }

    // MARK: - Public API

    func setSettings(hotkeyLabel: String, forceClick: Bool, noiseMode: Bool, polish: String) {
        self.hotkeyLabel = hotkeyLabel
        self.forceClick = forceClick
        self.noiseMode = noiseMode
        let normalized = ["off": "fast", "cloud": "auto"][polish] ?? polish
        self.polish = Self.polishValues.contains(normalized) ? normalized : "fast"
        applyState()
    }

    func setExtra(twoPass: Bool, launchAtLogin: Bool) {
        self.twoPass = twoPass
        self.launchAtLogin = launchAtLogin
        applyState()
    }

    /// Mic preference: use the Mac built-in mic when Bluetooth headphones are connected. Stored until the view loads.
    func setMicPreferBuiltIn(_ on: Bool) {
        preferBuiltIn = on
        applyState()
    }

    /// Feature toggles owned by the core app. Stored until the view loads.
    func setFeatures(handsFree: Bool, autoSend: Bool, offline: Bool) {
        self.handsFree = handsFree
        self.autoSend = autoSend
        self.offline = offline
        applyState()
    }

    /// Per-app style rows. Stored until the view loads; the list is rebuilt on every call once loaded.
    func setAppStyles(_ rows: [(bundleID: String, name: String, style: String, isDefault: Bool)]) {
        appStyleRows = rows
        applyState()
    }

    /// Pushes stored state into the views. No-op until the view is loaded.
    private func applyState() {
        guard isViewLoaded else { return }
        keycapLabel?.stringValue = hotkeyLabel
        forceSwitch?.state = forceClick ? .on : .off
        noiseSwitch?.state = noiseMode ? .on : .off
        preferBuiltInSwitch?.state = preferBuiltIn ? .on : .off
        polishControl?.selectedSegment = Self.polishValues.firstIndex(of: polish) ?? 0
        polishHint?.stringValue = Self.polishHints[polish] ?? ""
        twoPassSwitch?.state = twoPass ? .on : .off
        launchSwitch?.state = launchAtLogin ? .on : .off
        handsFreeSwitch?.state = handsFree ? .on : .off
        autoSendSwitch?.state = autoSend ? .on : .off
        offlineSwitch?.state = offline ? .on : .off
        rebuildAppStyleList()
    }

    // MARK: - Cards

    private func triggerCard() -> NSView {
        let capLabel = text(hotkeyLabel, size: 13, weight: .semibold)
        capLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        capLabel.setContentHuggingPriority(.required, for: .horizontal)
        keycapLabel = capLabel
        let cap = KeycapChip(label: capLabel)
        cap.setContentHuggingPriority(.required, for: .horizontal)

        let change = modernButton("更改", symbol: "keyboard", prominent: false, action: #selector(changeHotkey))
        hotkeyButton = change

        let hotkeyControl = horizontal([cap, change], spacing: 8)
        let hotkeyRow = row(symbol: "keyboard", color: .systemBlue, title: "快捷键",
                            subtitle: "按住说话，松开结束", control: hotkeyControl, textWidth: 400)

        let force = makeSwitch(#selector(forceClickChanged(_:)))
        forceSwitch = force
        let forceRow = row(symbol: "hand.tap", color: .systemPurple, title: "重按触控板也能触发",
                           subtitle: "按下“咔”一声后再用力压", control: force, textWidth: 480)

        let handsFreeSw = makeSwitch(#selector(handsFreeChanged(_:)))
        handsFreeSwitch = handsFreeSw
        let handsFreeRow = row(symbol: "hand.raised.fingers.spread", color: .systemTeal, title: "免提模式",
                               subtitle: "双击快捷键开始，松手继续录，再按一次结束", control: handsFreeSw, textWidth: 480)

        return card([hotkeyRow, forceRow, handsFreeRow])
    }

    private func polishCard() -> NSView {
        let control = NSSegmentedControl(
            labels: ["极速", "智能", "本地精修"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(polishChanged(_:))
        )
        control.segmentStyle = .automatic
        control.controlSize = .regular
        if #available(macOS 26.0, *) {
            control.segmentDistribution = .fillEqually
            control.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        polishControl = control
        let hint = text(Self.polishHints[polish] ?? "", size: 11, color: .secondaryLabelColor)
        hint.preferredMaxLayoutWidth = 300
        polishHint = hint
        let polishRow = row(symbol: "wand.and.stars", color: .systemPink, title: "润色",
                            subtitle: nil, customSubtitle: hint, control: control, textWidth: 300)

        let twoPassSw = makeSwitch(#selector(twoPassChanged(_:)))
        twoPassSwitch = twoPassSw
        let twoPassRow = row(symbol: "text.cursor", color: .systemGreen, title: "先上屏，再自动纠错",
                             subtitle: "像豆包：1–3 秒后原地替换为润色版", control: twoPassSw, textWidth: 480)

        let preferSw = makeSwitch(#selector(preferBuiltInChanged(_:)))
        preferBuiltInSwitch = preferSw
        let preferRow = row(symbol: "airpodspro", color: .systemTeal, title: "戴蓝牙耳机时用 Mac 麦克风",
                            subtitle: "耳机只放声音，不切换通话 / 降噪模式，开口快约 0.5 秒。合上屏幕时自动改用耳机麦克风。",
                            control: preferSw, textWidth: 480)

        let noiseSw = makeSwitch(#selector(noiseModeChanged(_:)))
        noiseSwitch = noiseSw
        let noiseRow = row(symbol: "waveform.badge.mic", color: .systemOrange, title: "嘈杂环境模式",
                           subtitle: "系统多麦克风人声隔离 · 内置麦克风上可能不稳定，失败会自动退回普通录音",
                           control: noiseSw, textWidth: 480)

        let autoSendSw = makeSwitch(#selector(autoSendChanged(_:)))
        autoSendSwitch = autoSendSw
        let autoSendRow = row(symbol: "return", color: .systemIndigo, title: "说“发送”自动回车",
                              subtitle: "句尾单独说“发送 / 回车 / 发出去”时，上屏后自动按回车",
                              control: autoSendSw, textWidth: 480)

        return card([polishRow, twoPassRow, preferRow, noiseRow, autoSendRow])
    }

    private func appStyleCard() -> NSView {
        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        appStyleStack = listStack

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(listStack)
        pinEdges(listStack, to: doc)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = doc
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])
        let height = scroll.heightAnchor.constraint(equalToConstant: 44)
        height.isActive = true
        appStyleHeight = height

        let addButton = modernButton("添加应用…", symbol: "plus", prominent: false,
                                     action: #selector(addAppTapped(_:)))
        let hint = text("风格只调整标点和格式，不改你的用词。", size: 11, color: .secondaryLabelColor)

        let content = NSStackView(views: [scroll, addButton, hint])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        fillWidth([scroll], in: content, inset: 28)
        return glassContainer(content)
    }

    private func privacyCard() -> NSView {
        let offlineSw = makeSwitch(#selector(offlineChanged(_:)))
        offlineSwitch = offlineSw
        let offlineRow = row(symbol: "lock.shield", color: .systemGreen, title: "完全离线模式",
                             subtitle: "识别、润色、语音改写、自动学词全部在本机完成；不连接任何云端服务",
                             control: offlineSw, textWidth: 480)
        return card([offlineRow])
    }

    private func generalCard() -> NSView {
        let launchSw = makeSwitch(#selector(launchAtLoginChanged(_:)))
        launchSwitch = launchSw
        let launchRow = row(symbol: "power", color: .systemGray, title: "开机自动启动",
                            subtitle: nil, control: launchSw, textWidth: 480)
        let tipRow = row(symbol: "lightbulb", color: .systemYellow, title: "小技巧",
                         subtitle: "先选中一段文字再按快捷键说话 = 语音改写（如“改正式点”“翻成英文”）",
                         control: nil, textWidth: 560)
        return card([launchRow, tipRow])
    }

    // MARK: - Per-app style list

    /// Rebuilds the per-app rows (capped at 220 pt, scrolls beyond). No-op until the view loads.
    private func rebuildAppStyleList() {
        guard let stack = appStyleStack else { return }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        var items: [NSView] = []
        for (index, app) in appStyleRows.enumerated() {
            if index > 0 { items.append(hairline()) }
            items.append(appStyleRow(app))
        }
        if items.isEmpty {
            items.append(text("还没有为应用单独设置风格", size: 12, color: .secondaryLabelColor))
        }
        for item in items { stack.addArrangedSubview(item) }
        fillWidth(items, in: stack, inset: 0)

        let count = appStyleRows.count
        let natural: CGFloat = count == 0 ? 28 : CGFloat(count) * 44 + CGFloat(count - 1)
        appStyleHeight?.constant = min(220, natural)
    }

    private func appStyleRow(_ app: (bundleID: String, name: String, style: String, isDefault: Bool)) -> NSView {
        let icon = NSImageView()
        icon.image = appIcon(bundleID: app.bundleID)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
        ])

        let name = text(app.name, size: 13)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var views: [NSView] = [icon, name]
        if app.isDefault {
            views.append(chip("默认"))
        }
        views.append(flexibleSpacer())

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: Self.appStyleTitles)
        popup.selectItem(at: Self.appStyleValues.firstIndex(of: app.style) ?? 0)
        popup.identifier = NSUserInterfaceItemIdentifier(app.bundleID)
        popup.target = self
        popup.action = #selector(appStyleChanged(_:))
        popup.setContentHuggingPriority(.required, for: .horizontal)
        views.append(popup)

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return stack
    }

    private func appIcon(bundleID: String) -> NSImage? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil)
    }

    /// Small secondary capsule label, e.g. the "默认" chip.
    private func chip(_ string: String) -> NSView {
        let label = text(string, size: 10, color: .secondaryLabelColor)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        let box = DynamicFillView(fill: .quaternaryLabelColor, radius: 4)
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
        ])
        box.setContentHuggingPriority(.required, for: .horizontal)
        return box
    }

    // MARK: - Building blocks

    /// Small secondary heading above a glass card.
    private func section(_ title: String, card: NSView) -> NSView {
        let heading = text(title, size: 11, weight: .semibold, color: .secondaryLabelColor)
        let stack = NSStackView(views: [heading, card])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        fillWidth([card], in: stack, inset: 0)
        return stack
    }

    /// Glass card holding rows separated by hairlines.
    private func card(_ rows: [NSView]) -> NSView {
        var items: [NSView] = []
        for (index, item) in rows.enumerated() {
            if index > 0 { items.append(hairline()) }
            items.append(item)
        }
        let content = NSStackView(views: items)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        fillWidth(items, in: content, inset: 0)
        return glassContainer(content)
    }

    /// One row: badge, title + optional subtitle, trailing control.
    private func row(symbol: String, color: NSColor, title: String, subtitle: String?,
                     customSubtitle: NSTextField? = nil, control: NSView?, textWidth: CGFloat) -> NSView {
        var textItems: [NSView] = [text(title, size: 13)]
        if let custom = customSubtitle {
            textItems.append(custom)
        } else if let subtitle = subtitle {
            let sub = text(subtitle, size: 11, color: .secondaryLabelColor)
            sub.preferredMaxLayoutWidth = textWidth
            textItems.append(sub)
        }
        let column = NSStackView(views: textItems)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.setContentHuggingPriority(.defaultLow, for: .horizontal)
        column.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var views: [NSView] = [iconBadge(symbol, color), column]
        if let control = control {
            views.append(flexibleSpacer())
            views.append(control)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return stack
    }

    /// 28 x 28 continuous-corner colored square with a white SF Symbol, like System Settings.
    private func iconBadge(_ symbol: String, _ color: NSColor) -> NSView {
        let badge = DynamicFillView(fill: color, radius: 7)
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        icon.contentTintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(icon)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 28),
            badge.heightAnchor.constraint(equalToConstant: 28),
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])
        return badge
    }

    /// Wraps content in a Liquid Glass card on macOS 26+, else a rounded visual effect view.
    private func glassContainer(_ content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.cardRadius
            glass.contentView = content
            pinEdges(content, to: glass)
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Self.cardRadius
        effect.layer?.masksToBounds = true
        effect.addSubview(content)
        pinEdges(content, to: effect)
        return effect
    }

    /// Separator that starts after the 28 pt icon column (leading 52).
    private func hairline() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(line)
        NSLayoutConstraint.activate([
            holder.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 52),
            line.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            line.topAnchor.constraint(equalTo: holder.topAnchor),
            line.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        return holder
    }

    private func makeSwitch(_ action: Selector) -> NSSwitch {
        let toggle = NSSwitch()
        toggle.controlSize = .regular
        toggle.target = self
        toggle.action = action
        return toggle
    }

    /// Capsule-style push button: Liquid Glass on macOS 26+, plain push bezel otherwise.
    private func modernButton(_ title: String, symbol: String?, prominent: Bool, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        if let symbol = symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        button.imagePosition = .imageLeading
        button.controlSize = .regular
        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
            button.borderShape = .capsule
            if prominent { button.tintProminence = .primary }
        } else {
            button.bezelStyle = .push
        }
        return button
    }

    private func horizontal(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func flexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return spacer
    }

    /// Pins every view to the container's width minus `inset`.
    private func fillWidth(_ views: [NSView], in container: NSView, inset: CGFloat) {
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -inset).isActive = true
        }
    }

    private func pinEdges(_ child: NSView, to parent: NSView, insets: NSEdgeInsets = NSEdgeInsetsZero) {
        if child.superview !== parent { parent.addSubview(child) }   // constraints need a common ancestor
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: insets.left),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -insets.right),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: insets.top),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -insets.bottom),
        ])
    }

    // MARK: - Actions

    @objc private func changeHotkey() {
        guard let request = onChangeHotkey else { return }
        hotkeyButton?.title = "请按下新按键…（Esc 取消）"
        hotkeyButton?.isEnabled = false
        request { [weak self] newLabel in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.hotkeyButton?.title = "更改"
                self.hotkeyButton?.isEnabled = true
                if let newLabel = newLabel {
                    self.hotkeyLabel = newLabel
                    self.applyState()
                }
            }
        }
    }

    @objc private func forceClickChanged(_ sender: NSSwitch) {
        forceClick = sender.state == .on
        onToggleForceClick?(forceClick)
    }

    @objc private func noiseModeChanged(_ sender: NSSwitch) {
        noiseMode = sender.state == .on
        onToggleNoiseMode?(noiseMode)
    }

    @objc private func preferBuiltInChanged(_ sender: NSSwitch) {
        preferBuiltIn = sender.state == .on
        onTogglePreferBuiltIn?(preferBuiltIn)
    }

    @objc private func polishChanged(_ sender: NSSegmentedControl) {
        let index = max(0, min(sender.selectedSegment, Self.polishValues.count - 1))
        polish = Self.polishValues[index]
        polishHint?.stringValue = Self.polishHints[polish] ?? ""
        onChangePolish?(polish)
    }

    @objc private func twoPassChanged(_ sender: NSSwitch) {
        twoPass = sender.state == .on
        onToggleTwoPass?(twoPass)
    }

    @objc private func launchAtLoginChanged(_ sender: NSSwitch) {
        launchAtLogin = sender.state == .on
        onToggleLaunchAtLogin?(launchAtLogin)
    }

    @objc private func handsFreeChanged(_ sender: NSSwitch) {
        handsFree = sender.state == .on
        onToggleHandsFree?(handsFree)
    }

    @objc private func autoSendChanged(_ sender: NSSwitch) {
        autoSend = sender.state == .on
        onToggleAutoSend?(autoSend)
    }

    @objc private func offlineChanged(_ sender: NSSwitch) {
        offline = sender.state == .on
        onToggleOffline?(offline)
    }

    @objc private func appStyleChanged(_ sender: NSPopUpButton) {
        guard let bundleID = sender.identifier?.rawValue else { return }
        let index = max(0, min(sender.indexOfSelectedItem, Self.appStyleValues.count - 1))
        let style = Self.appStyleValues[index]
        if let i = appStyleRows.firstIndex(where: { $0.bundleID == bundleID }) {
            appStyleRows[i].style = style
        }
        onChangeAppStyle?(bundleID, style)
    }

    @objc private func addAppTapped(_ sender: NSButton) {
        let menu = NSMenu()
        var seen = Set<String>()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, !seen.contains(bundleID) else { continue }
            seen.insert(bundleID)
            let item = NSMenuItem(title: app.localizedName ?? bundleID,
                                  action: #selector(pickRunningApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = bundleID
            if let icon = app.icon {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: "没有正在运行的应用", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func pickRunningApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        onChangeAppStyle?(bundleID, "casual")
    }
}

// MARK: - Helper views

/// Top-left origin so the scroll document lays out downward.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Capsule key-cap chip: glass on macOS 26+, else a layer-backed control-background capsule.
private final class KeycapChip: NSView {
    private let label: NSTextField
    private var glassBox: NSView?

    init(label: NSTextField) {
        self.label = label
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: host.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -3),
        ])

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.translatesAutoresizingMaskIntoConstraints = false
            glass.contentView = host
            addSubview(glass)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            glassBox = glass
        } else {
            wantsLayer = true
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.topAnchor.constraint(equalTo: topAnchor),
                host.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) {
        fatalError("KeycapChip is code-only")
    }

    override var intrinsicContentSize: NSSize {
        let size = label.intrinsicContentSize
        return NSSize(width: size.width + 20, height: size.height + 6)
    }

    override func layout() {
        super.layout()
        let radius = bounds.height / 2
        if #available(macOS 26.0, *), let glass = glassBox as? NSGlassEffectView {
            glass.cornerRadius = radius
        } else {
            layer?.cornerRadius = radius
        }
    }

    override var wantsUpdateLayer: Bool { glassBox == nil }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Layer-backed rounded fill that re-resolves dynamic colors when the appearance changes.
private final class DynamicFillView: NSView {
    var fill: NSColor {
        didSet { needsDisplay = true }
    }

    init(fill: NSColor, radius: CGFloat) {
        self.fill = fill
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("DynamicFillView is code-only")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fill.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
