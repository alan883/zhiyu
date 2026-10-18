import AppKit

// MARK: - Brand

fileprivate extension NSColor {
    /// 指语 brand colors from the app icon: #8F5BFF violet, #22D3EE cyan.
    static let zhiyuViolet = NSColor(srgbRed: 143.0 / 255, green: 91.0 / 255, blue: 255.0 / 255, alpha: 1)
    static let zhiyuCyan = NSColor(srgbRed: 34.0 / 255, green: 211.0 / 255, blue: 238.0 / 255, alpha: 1)
}

// MARK: - Main window controller

final class MainWindowController: NSObject, NSWindowDelegate {
    let overview: OverviewPane
    let settings: SettingsPane
    let models: ModelsPane
    let dictionary: DictionaryPane
    let history: HistoryPane

    private let configDir: String
    private let sidebarVC = MainWindowSidebarVC()
    private let detailHost = MainWindowDetailVC()
    private(set) var window: NSWindow?
    private var selectedIndex = -1

    /// Own key, not setFrameAutosaveName: AppKit's autosave also stores sizes the app never chose
    /// (it once saved 1852×483 on a 1440-wide screen and restored it on every launch).
    /// This key is written only when the user finishes dragging the window.
    private static let frameKey = "ZhiyuMainFrame.v2"
    private static let defaultSize = NSSize(width: 880, height: 560)

    private var panes: [NSViewController] { [overview, settings, models, dictionary, history] }

    init(configDir: String) {
        self.configDir = configDir
        overview = OverviewPane()
        settings = SettingsPane()
        models = ModelsPane()
        dictionary = DictionaryPane(configDir: configDir)
        history = HistoryPane(configDir: configDir)
        super.init()
    }

    func show() {
        if window == nil { buildWindow() }
        if let w = window { restoreFrame(w) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// 0 概览, 1 设置, 2 模型, 3 个人词典, 4 历史记录
    func select(_ index: Int) {
        guard (0..<5).contains(index) else { return }
        if window == nil { buildWindow() }
        selectedIndex = index
        switch index {
        case 2: models.reload()
        case 3: dictionary.reload()
        case 4: history.reload()
        default: break
        }
        detailHost.setPane(panes[index])
        sidebarVC.setSelected(index)
    }

    /// Sidebar footer status capsule. Orange dot when `ready == false`.
    func setFooterStatus(ready: Bool, text: String) {
        sidebarVC.setFooterStatus(ready: ready, text: text)
    }

    // MARK: Construction

    private func buildWindow() {
        sidebarVC.onSelect = { [weak self] index in self?.select(index) }

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 240
        sidebarItem.canCollapse = false
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: detailHost))

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "指语"
        w.titlebarAppearsTransparent = true
        w.titlebarSeparatorStyle = .none
        w.titleVisibility = .hidden
        let toolbar = NSToolbar(identifier: "ZhiyuMainToolbar")
        w.toolbar = toolbar
        w.toolbarStyle = .unified
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentViewController = split
        w.contentMinSize = NSSize(width: 760, height: 480)
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame ZhiyuMain")   // drop the old bad autosave

        window = w
        select(0)
    }

    /// The user's saved frame if it still fits the screen, else the default size centred.
    private func restoreFrame(_ w: NSWindow) {
        let screen = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 870)
        let minSize = w.frameRect(forContentRect: NSRect(origin: .zero, size: w.contentMinSize)).size
        if let str = UserDefaults.standard.string(forKey: Self.frameKey) {
            let f = NSRectFromString(str)
            if f.width >= minSize.width, f.height >= minSize.height, screen.contains(f) {
                w.setFrame(f, display: true)
                return
            }
        }
        var f = w.frameRect(forContentRect: NSRect(origin: .zero, size: Self.defaultSize))
        f.size.width = min(f.width, screen.width)
        f.size.height = min(f.height, screen.height)
        f.origin = NSPoint(x: screen.midX - f.width / 2, y: screen.midY - f.height / 2)
        w.setFrame(f, display: true)
    }

    private func saveFrame(_ w: NSWindow) {
        UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: Self.frameKey)
    }

    // MARK: NSWindowDelegate

    func windowDidEndLiveResize(_ notification: Notification) {
        if let w = notification.object as? NSWindow { saveFrame(w) }
    }

    func windowDidMove(_ notification: Notification) {
        // only moves while the user drags; programmatic setFrame during restore is skipped
        if let w = notification.object as? NSWindow, w.isVisible, w.inLiveResize || NSEvent.pressedMouseButtons != 0 { saveFrame(w) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

// MARK: - Sidebar

fileprivate final class MainWindowSidebarVC: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((Int) -> Void)?

    private let table = NSTableView()
    private var isProgrammatic = false
    private let rows: [(symbol: String, title: String)] = [
        ("square.grid.2x2", "概览"),
        ("gearshape", "设置"),
        ("cpu", "模型"),
        ("character.book.closed", "个人词典"),
        ("clock.arrow.circlepath", "历史记录"),
    ]
    private static let rowHeight: CGFloat = 34

    private let statusDot = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "就绪")
    private var footerReady = true

    override func loadView() {
        let root = NSView()
        view = root

        // Header: app icon with brand glow + name + tagline
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.shadowColor = NSColor.zhiyuViolet.withAlphaComponent(0.35).cgColor
        icon.layer?.shadowOpacity = 1
        icon.layer?.shadowRadius = 10
        icon.layer?.shadowOffset = CGSize(width: 0, height: -2)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: "指语")
        name.font = .systemFont(ofSize: 18, weight: .bold)
        let tagline = NSTextField(labelWithString: "指哪说哪 · 语音输入")
        tagline.font = .systemFont(ofSize: 11)
        tagline.textColor = .secondaryLabelColor

        let titles = NSStackView(views: [name, tagline])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1

        let header = NSStackView(views: [icon, titles])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false

        // Source list
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main")))
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = Self.rowHeight
        table.allowsEmptySelection = false
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.translatesAutoresizingMaskIntoConstraints = false

        // Footer: compact status capsule
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        let versionLabel = NSTextField(labelWithString: "v0.3")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        applyFooterStatus()

        let capsule = NSStackView(views: [statusDot, statusLabel, versionLabel])
        capsule.orientation = .horizontal
        capsule.alignment = .centerY
        capsule.spacing = 6
        capsule.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)

        var footer: NSView = capsule
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 14
            glass.contentView = capsule
            footer = glass
        } else {
            capsule.wantsLayer = true
            capsule.layer?.cornerRadius = 14
            capsule.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        }
        footer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(table)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 44),
            icon.heightAnchor.constraint(equalToConstant: 44),

            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            table.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            table.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            table.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            table.heightAnchor.constraint(equalToConstant: CGFloat(rows.count) * Self.rowHeight),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            footer.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            footer.heightAnchor.constraint(equalToConstant: 28),
            footer.topAnchor.constraint(greaterThanOrEqualTo: table.bottomAnchor, constant: 8),
        ])
    }

    func setSelected(_ index: Int) {
        guard table.selectedRow != index, (0..<rows.count).contains(index) else { return }
        isProgrammatic = true
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        isProgrammatic = false
    }

    func setFooterStatus(ready: Bool, text: String) {
        footerReady = ready
        statusLabel.stringValue = text
        applyFooterStatus()
    }

    private func applyFooterStatus() {
        statusDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .regular))
        statusDot.contentTintColor = footerReady ? .systemGreen : .systemOrange
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("sidebarCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? SidebarCell) ?? makeCell(id: id)
        let item = rows[row]
        cell.configure(symbol: item.symbol, title: item.title)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammatic, table.selectedRow >= 0 else { return }
        onSelect?(table.selectedRow)
    }

    private func makeCell(id: NSUserInterfaceItemIdentifier) -> SidebarCell {
        let cell = SidebarCell()
        cell.identifier = id

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let textField = NSTextField(labelWithString: "")
        textField.font = .systemFont(ofSize: 13)
        textField.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.imageView = imageView
        cell.textField = textField

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// Sidebar row. Re-tints its hierarchical symbol when the source-list selection changes
/// so the icon stays readable on the accent-colored selection.
fileprivate final class SidebarCell: NSTableCellView {
    private var symbol = ""

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applySymbol() }
    }

    func configure(symbol: String, title: String) {
        self.symbol = symbol
        textField?.stringValue = title
        applySymbol()
    }

    private func applySymbol() {
        let tint: NSColor = backgroundStyle == .emphasized ? .white : .labelColor
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: tint))
        imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }
}

// MARK: - Detail container with aurora background and cross-fade

/// Base fill plus two soft radial blobs (violet top-left, cyan top-right).
fileprivate final class AuroraView: NSView {
    private let violetBlob = CAGradientLayer()
    private let cyanBlob = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        violetBlob.type = .radial
        cyanBlob.type = .radial
        // Layer coordinates are unit-space with y pointing up, so (0, 1) is top-left.
        violetBlob.startPoint = CGPoint(x: 0, y: 1)
        violetBlob.endPoint = CGPoint(x: 0.6, y: 0.4)
        cyanBlob.startPoint = CGPoint(x: 1, y: 1)
        cyanBlob.endPoint = CGPoint(x: 0.4, y: 0.4)
        layer?.addSublayer(violetBlob)
        layer?.addSublayer(cyanBlob)
        updateColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        violetBlob.frame = bounds
        cyanBlob.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let alpha: CGFloat = isDark ? 0.22 : 0.16
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        violetBlob.colors = Self.fade(.zhiyuViolet, alpha)
        cyanBlob.colors = Self.fade(.zhiyuCyan, alpha)
    }

    private static func fade(_ color: NSColor, _ alpha: CGFloat) -> [CGColor] {
        [color.withAlphaComponent(alpha).cgColor, color.withAlphaComponent(0).cgColor]
    }
}

fileprivate final class MainWindowDetailVC: NSViewController {
    private var current: NSViewController?

    override func loadView() {
        view = AuroraView()
    }

    func setPane(_ pane: NSViewController) {
        guard pane !== current else { return }
        let old = current
        current = pane

        if pane.parent !== self { addChild(pane) }
        let paneView = pane.view
        if paneView.superview !== view {
            paneView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(paneView)
            NSLayoutConstraint.activate([
                paneView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                paneView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                paneView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                paneView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }

        guard let old else {
            paneView.alphaValue = 1
            return
        }

        // Old pane is removed immediately: no overlap, so nothing ghosts over the aurora.
        old.view.removeFromSuperview()
        old.removeFromParent()

        // Final model values first, so the animation ends cleanly on its own.
        paneView.alphaValue = 1
        paneView.wantsLayer = true
        guard let layer = paneView.layer else { return }
        layer.opacity = 1
        layer.transform = CATransform3DIdentity

        // Enter animation: opacity 0 -> 1, plus a 14 pt slide from the right unless Reduce Motion is on.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        var animations: [CAAnimation] = [fade]
        if !reduceMotion {
            let slide = CABasicAnimation(keyPath: "transform")
            slide.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(14, 0, 0))
            slide.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            animations.append(slide)
        }

        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = reduceMotion ? 0.15 : 0.22
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.0)
        layer.add(group, forKey: "paneEnter")
    }
}
