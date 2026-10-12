import AppKit

/// 个人词典面板：手动词典 / 自动学到 / 纠错规则 三个标签页。
/// 数据文件：configDir/dictionary.txt（手动词，# 为注释）、configDir/lexicon.json（学到的词与纠错）。
final class DictionaryPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    /// 任何写盘成功后调用
    var onChanged: (() -> Void)?

    private enum Tab: Int { case manual, auto, corr }

    private struct Correction {
        let wrong: String
        let right: String
        let hits: Int
        let source: String
    }

    private let dictURL: URL
    private let lexURL: URL

    private var tab: Tab = .manual
    /// dictionary.txt 全部原始行（含注释与空行，写回时原样保留）
    private var lines: [String] = []
    /// 手动词（去掉注释/空行后）
    private var words: [String] = []
    /// words[i] 对应 lines 中的原始下标
    private var manualRaw: [Int] = []
    private var terms: [String] = []
    private var corrections: [Correction] = []

    // MARK: - Init

    init(configDir: String) {
        let dir = URL(fileURLWithPath: configDir, isDirectory: true)
        dictURL = dir.appendingPathComponent("dictionary.txt")
        lexURL = dir.appendingPathComponent("lexicon.json")
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Controls

    private lazy var segmented: NSSegmentedControl = {
        let s = NSSegmentedControl(labels: ["手动词典 (0)", "自动学到 (0)", "纠错规则 (0)"],
                                   trackingMode: .selectOne, target: self, action: #selector(tabChanged))
        s.selectedSegment = 0
        s.segmentStyle = .automatic
        s.controlSize = .large
        if #available(macOS 26.0, *) {
            s.segmentDistribution = .fillEqually
        }
        return s
    }()

    private lazy var tableView: NSTableView = {
        let t = NSTableView()
        t.style = .inset
        t.rowHeight = 32
        t.gridStyleMask = []
        t.intercellSpacing = NSSize(width: 0, height: 4)
        t.usesAlternatingRowBackgroundColors = false
        t.allowsMultipleSelection = true
        t.backgroundColor = .clear
        t.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        t.dataSource = self
        t.delegate = self
        return t
    }()

    private lazy var addField: NSTextField = {
        let f = NSTextField()
        f.placeholderString = "添加新词，回车确认"
        f.target = self
        f.action = #selector(addWord)
        f.bezelStyle = .roundedBezel
        f.controlSize = .large
        if #available(macOS 26.0, *) {
            f.isBordered = false
            f.drawsBackground = false
        }
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return f
    }()

    /// 输入框外壳：macOS 26+ 为胶囊玻璃，否则就是输入框本身
    private lazy var addFieldContainer: NSView = {
        guard #available(macOS 26.0, *) else { return self.addField }
        let holder = NSView()
        self.addField.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(self.addField)
        NSLayoutConstraint.activate([
            self.addField.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 12),
            self.addField.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -12),
            self.addField.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        let glass = NSGlassEffectView()
        glass.contentView = holder
        glass.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return glass
    }()

    private lazy var plusButton: NSButton = {
        self.modernButton("添加", symbol: "plus", prominent: true, action: #selector(addWord))
    }()

    private lazy var minusButton: NSButton = {
        let b = self.modernButton("", symbol: "minus", prominent: false, action: #selector(deleteSelected))
        b.toolTip = "删除所选"
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }()

    /// 统一的按钮外观：macOS 26+ 用玻璃样式，否则用 push
    private func modernButton(_ title: String, symbol: String?, prominent: Bool, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        if let symbol = symbol {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title.isEmpty ? nil : title)
            b.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
        b.controlSize = .regular
        if #available(macOS 26.0, *) {
            b.bezelStyle = .glass
            b.borderShape = title.isEmpty ? .circle : .capsule
            if prominent { b.tintProminence = .primary }
        } else {
            b.bezelStyle = .push
        }
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    private lazy var emptyLabel: NSTextField = {
        let l = NSTextField(labelWithString: "还没有内容")
        l.font = .systemFont(ofSize: 13)
        l.textColor = .secondaryLabelColor
        l.alignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    // MARK: - View lifecycle

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 690, height: 560))

        let title = NSTextField(labelWithString: "个人词典")
        title.font = .systemFont(ofSize: 26, weight: .bold)

        let subtitle = NSTextField(labelWithString: "自动学习：你手动改过 2 次的词会被记住；也可以手动添加。")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let bar = NSStackView(views: [addFieldContainer, plusButton, minusButton])
        // the glass holder has no intrinsic width: give the field a real width and let it take the free space
        addFieldContainer.translatesAutoresizingMaskIntoConstraints = false
        addFieldContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        addFieldContainer.heightAnchor.constraint(equalToConstant: 32).isActive = true
        addFieldContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 8, right: 10)

        let container = NSView()
        container.addSubview(scroll)
        container.addSubview(bar)
        container.addSubview(emptyLabel)
        for v in [scroll, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])

        let card = makeCard(container)

        for v in [title, subtitle, segmented, card] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            segmented.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
            segmented.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            card.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 12),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28),
        ])

        self.view = root
    }

    private var built = false

    override func viewDidLoad() {
        super.viewDidLoad()
        built = true
        configureColumns()
        reload()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if #available(macOS 26.0, *), let glass = addFieldContainer as? NSGlassEffectView {
            glass.cornerRadius = glass.bounds.height / 2
        }
    }

    /// 重新读取两个文件并刷新界面与计数
    func reload() {
        loadData()
        refreshUI()
    }

    // MARK: - Glass card

    private func makeCard(_ content: NSView) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 20
            glass.contentView = content
            return glass
        } else {
            let fx = NSVisualEffectView()
            fx.material = .sidebar
            fx.blendingMode = .withinWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = 16
            fx.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: fx.topAnchor),
                content.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            ])
            return fx
        }
    }

    // MARK: - Data loading

    private func loadData() {
        let text = (try? String(contentsOf: dictURL, encoding: .utf8)) ?? ""
        var ls = text.components(separatedBy: "\n")
        if ls.last == "" { ls.removeLast() }
        lines = ls
        words = []
        manualRaw = []
        for (i, line) in ls.enumerated() {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t.hasPrefix("#") { continue }
            words.append(t)
            manualRaw.append(i)
        }

        var root: [String: Any] = [:]
        if let d = try? Data(contentsOf: lexURL),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            root = obj
        }
        terms = (root["terms"] as? [String]) ?? []
        corrections = ((root["corrections"] as? [[String: Any]]) ?? []).map { c in
            Correction(wrong: (c["wrong"] as? String) ?? "",
                       right: (c["right"] as? String) ?? "",
                       hits: (c["hits"] as? NSNumber)?.intValue ?? 0,
                       source: (c["source"] as? String) ?? "")
        }
    }

    private func refreshUI() {
        guard isViewLoaded, built else { return }
        segmented.setLabel("手动词典 (\(words.count))", forSegment: 0)
        segmented.setLabel("自动学到 (\(terms.count))", forSegment: 1)
        segmented.setLabel("纠错规则 (\(corrections.count))", forSegment: 2)
        let editing = tab == .manual
        addFieldContainer.isHidden = !editing
        plusButton.isHidden = !editing
        tableView.reloadData()
        emptyLabel.isHidden = rowCount > 0
    }

    private var rowCount: Int {
        switch tab {
        case .manual: return words.count
        case .auto: return terms.count
        case .corr: return corrections.count
        }
    }

    private func configureColumns() {
        for c in tableView.tableColumns {
            tableView.removeTableColumn(c)
        }
        let specs: [(id: String, title: String, width: CGFloat)]
        switch tab {
        case .manual, .auto:
            specs = [("word", "词", 400)]
        case .corr:
            specs = [("wrong", "识别成", 180), ("right", "改为", 180), ("hits", "次数", 70), ("source", "来源", 200)]
        }
        // 单列标签页不显示表头
        tableView.headerView = specs.count == 1 ? nil : NSTableHeaderView()
        for spec in specs {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            col.title = spec.title
            col.width = spec.width
            col.minWidth = 40
            col.headerCell.font = .systemFont(ofSize: 11, weight: .semibold)
            col.headerCell.textColor = .secondaryLabelColor
            tableView.addTableColumn(col)
        }
    }

    // MARK: - Writing

    @discardableResult
    private func atomicWrite(_ data: Data, to url: URL) -> Bool {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmp)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
            return true
        } catch {
            try? fm.removeItem(at: tmp)
            return false
        }
    }

    private func writeDictionary() -> Bool {
        let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        return atomicWrite(Data(body.utf8), to: dictURL)
    }

    /// 重新读取 lexicon.json（学习进程可能刚写过），修改后原子写回。其他键原样保留。
    private func mutateLexicon(_ body: (inout [String: Any]) -> Void) -> Bool {
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: lexURL.path) {
            guard let d = try? Data(contentsOf: lexURL),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                return false   // 解析失败就不写，避免覆盖
            }
            root = obj
        }
        body(&root)
        guard let out = try? JSONSerialization.data(withJSONObject: root,
                                                    options: [.prettyPrinted, .withoutEscapingSlashes]) else {
            return false
        }
        return atomicWrite(out, to: lexURL)
    }

    private func deleteAutoTerms(_ items: [String]) -> Bool {
        mutateLexicon { root in
            var terms = (root["terms"] as? [String]) ?? []
            var rejected = (root["rejected"] as? [String: Any]) ?? [:]
            var rejTerms = (rejected["terms"] as? [String]) ?? []
            for t in items {
                if let i = terms.firstIndex(of: t) {
                    terms.remove(at: i)
                    if !rejTerms.contains(t) { rejTerms.append(t) }
                }
            }
            root["terms"] = terms
            rejected["terms"] = rejTerms
            root["rejected"] = rejected
        }
    }

    private func deleteCorrections(_ items: [(wrong: String, right: String)]) -> Bool {
        mutateLexicon { root in
            var corr = (root["corrections"] as? [[String: Any]]) ?? []
            var rejected = (root["rejected"] as? [String: Any]) ?? [:]
            var rejCorr = (rejected["corrections"] as? [[String: Any]]) ?? []
            for item in items {
                let matches: ([String: Any]) -> Bool = {
                    ($0["wrong"] as? String) == item.wrong && ($0["right"] as? String) == item.right
                }
                if let i = corr.firstIndex(where: matches) {
                    corr.remove(at: i)
                    if !rejCorr.contains(where: matches) {
                        rejCorr.append(["wrong": item.wrong, "right": item.right])
                    }
                }
            }
            root["corrections"] = corr
            rejected["corrections"] = rejCorr
            root["rejected"] = rejected
        }
    }

    /// 写盘后统一刷新；失败只响一声
    private func didWrite(_ ok: Bool) {
        if !ok { NSSound.beep() }
        loadData()
        refreshUI()
        if ok { onChanged?() }
    }

    // MARK: - Actions

    @objc private func tabChanged() {
        tab = Tab(rawValue: segmented.selectedSegment) ?? .manual
        configureColumns()
        refreshUI()
    }

    @objc private func addWord() {
        let w = addField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        addField.stringValue = ""
        guard !w.isEmpty else { return }
        if words.contains(w) { NSSound.beep(); return }
        lines.append(w)
        didWrite(writeDictionary())
    }

    @objc private func deleteSelected() {
        let rows = tableView.selectedRowIndexes
        guard !rows.isEmpty else { return }
        switch tab {
        case .manual:
            let idx = rows.compactMap { $0 < manualRaw.count ? manualRaw[$0] : nil }
            for i in idx.sorted(by: >) where i < lines.count {
                lines.remove(at: i)
            }
            didWrite(writeDictionary())
        case .auto:
            let items = rows.compactMap { $0 < terms.count ? terms[$0] : nil }
            didWrite(deleteAutoTerms(items))
        case .corr:
            let items: [(wrong: String, right: String)] = rows.compactMap {
                $0 < corrections.count ? (corrections[$0].wrong, corrections[$0].right) : nil
            }
            didWrite(deleteCorrections(items))
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rowCount
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row < rowCount else { return nil }
        let id = col.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)

        let text: String
        switch (tab, id.rawValue) {
        case (.manual, _): text = words[row]
        case (.auto, _): text = terms[row]
        case (.corr, "wrong"): text = corrections[row].wrong
        case (.corr, "right"): text = corrections[row].right
        case (.corr, "hits"): text = String(corrections[row].hits)
        default: text = sourceLabel(corrections[row].source)
        }
        cell.textField?.stringValue = text
        cell.textField?.isEditable = (tab == .manual)
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.font = .systemFont(ofSize: 13)
        tf.lineBreakMode = .byTruncatingTail
        tf.delegate = self
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func sourceLabel(_ s: String) -> String {
        switch s {
        case "edit": return "你的修改"
        case "llm": return "AI 复核"
        default: return s
        }
    }

    /// 手动词双击编辑后提交
    func controlTextDidEndEditing(_ obj: Notification) {
        guard tab == .manual, let field = obj.object as? NSTextField else { return }
        let row = tableView.row(for: field)
        guard row >= 0, row < words.count else { return }
        let newWord = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if newWord == words[row] { return }
        if newWord.isEmpty || words.contains(newWord) {
            refreshUI()   // 回滚显示
            return
        }
        lines[manualRaw[row]] = newWord
        didWrite(writeDictionary())
    }
}
