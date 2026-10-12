import AppKit

/// History pane: reads `<configDir>/history.jsonl` and shows the newest rows
/// in a searchable, sortable table with a detail card below.
final class HistoryPane: NSViewController {

    private struct Row {
        let id: Int
        let ts: Date
        let app: String
        let raw: String
        let clean: String
        let firstMs: Double?
        let totalMs: Double?
        let polish: String?
    }

    private static let maxRows = 1000
    private static let maxBytes: UInt64 = 2 * 1024 * 1024

    private let path: String
    private let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    private var rows: [Row] = []
    private var shown: [Row] = []
    private var loadToken = 0

    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let detailScroll = NSScrollView()
    private let detailText = NSTextView()
    private let metaLabel = NSTextField(labelWithString: "")
    private var copyResultButton = NSButton()
    private var copyRawButton = NSButton()

    init(configDir: String) {
        self.path = (configDir as NSString).appendingPathComponent("history.jsonl")
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("HistoryPane does not support init(coder:)")
    }

    // MARK: - View

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 690, height: 560))
        view = root

        let title = NSTextField(labelWithString: "历史记录")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.textColor = .labelColor

        searchField.placeholderString = "搜索内容或应用"
        searchField.sendsSearchStringImmediately = true
        searchField.controlSize = .large
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))

        let refresh = modernButton("", symbol: "arrow.clockwise", prominent: false, action: #selector(refreshTapped(_:)))
        refresh.toolTip = "刷新"

        // Table card
        let (tableOuter, tableInner) = HistoryPane.makeCard()

        func addColumn(_ id: String, _ title: String, width: CGFloat, flexible: Bool = false) -> NSTableColumn {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = flexible ? 200 : width
            c.resizingMask = flexible ? .autoresizingMask : .userResizingMask
            c.headerCell.font = .systemFont(ofSize: 11, weight: .semibold)
            c.headerCell.textColor = .secondaryLabelColor
            table.addTableColumn(c)
            return c
        }
        let timeCol = addColumn("time", "时间", width: 110)
        timeCol.sortDescriptorPrototype = NSSortDescriptor(key: "ts", ascending: false)
        _ = addColumn("app", "应用", width: 90)
        _ = addColumn("clean", "内容", width: 300, flexible: true)
        let firstCol = addColumn("first", "上屏", width: 70)
        firstCol.headerCell.alignment = .right

        table.style = .inset
        table.rowHeight = 34
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .sequentialColumnAutoresizingStyle
        table.sortDescriptors = [NSSortDescriptor(key: "ts", ascending: false)]
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        tableInner.addSubview(scroll)
        HistoryPane.pin(scroll, to: tableInner, inset: 6)

        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        tableInner.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: tableInner.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableInner.centerYAnchor)
        ])

        // Detail card
        let (detailOuter, detailInner) = HistoryPane.makeCard()
        detailInner.clipsToBounds = true

        detailText.isEditable = false
        detailText.isSelectable = true
        detailText.drawsBackground = false
        detailText.textContainerInset = .zero
        detailText.isVerticallyResizable = true
        detailText.isHorizontallyResizable = false
        detailText.autoresizingMask = [.width]
        detailText.minSize = NSSize(width: 0, height: 0)
        detailText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        detailText.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        detailText.textContainer?.widthTracksTextView = true
        detailText.textContainer?.lineFragmentPadding = 0

        detailScroll.documentView = detailText
        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true
        detailScroll.borderType = .noBorder
        detailScroll.drawsBackground = false
        detailScroll.backgroundColor = .clear
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detailInner.addSubview(detailScroll)

        metaLabel.font = .systemFont(ofSize: 11)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail

        copyResultButton = modernButton("复制结果", symbol: "doc.on.doc", prominent: true, action: #selector(copyResult(_:)))
        copyResultButton.isEnabled = false
        copyRawButton = modernButton("复制原文", symbol: "text.quote", prominent: false, action: #selector(copyRaw(_:)))
        copyRawButton.isEnabled = false

        let btnRow = NSStackView(views: [copyResultButton, copyRawButton])
        btnRow.orientation = .horizontal
        btnRow.spacing = 8

        // Bottom bar (pinned, outside the scroll area)
        let bottomStack = NSStackView(views: [btnRow, metaLabel])
        bottomStack.orientation = .vertical
        bottomStack.alignment = .width
        bottomStack.spacing = 6
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        detailInner.addSubview(bottomStack)
        NSLayoutConstraint.activate([
            detailScroll.topAnchor.constraint(equalTo: detailInner.topAnchor, constant: 14),
            detailScroll.leadingAnchor.constraint(equalTo: detailInner.leadingAnchor, constant: 14),
            detailScroll.trailingAnchor.constraint(equalTo: detailInner.trailingAnchor, constant: -14),
            detailScroll.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -8),

            bottomStack.leadingAnchor.constraint(equalTo: detailInner.leadingAnchor, constant: 14),
            bottomStack.trailingAnchor.constraint(equalTo: detailInner.trailingAnchor, constant: -14),
            bottomStack.bottomAnchor.constraint(equalTo: detailInner.bottomAnchor, constant: -14)
        ])

        // Root layout
        for v in [title, searchField, refresh, tableOuter, detailOuter] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),

            refresh.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            refresh.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            searchField.trailingAnchor.constraint(equalTo: refresh.leadingAnchor, constant: -10),
            searchField.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 260),

            tableOuter.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            tableOuter.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            tableOuter.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            tableOuter.bottomAnchor.constraint(equalTo: detailOuter.topAnchor, constant: -12),

            detailOuter.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            detailOuter.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            detailOuter.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            detailOuter.heightAnchor.constraint(equalToConstant: 220)
        ])

        updateDetail()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    // MARK: - Loading

    func reload() {
        loadToken += 1
        let token = loadToken
        let path = self.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loaded = HistoryPane.loadRows(path: path)
            DispatchQueue.main.async {
                guard let self = self, token == self.loadToken else { return }
                self.rows = loaded
                self.applyFilter()
            }
        }
    }

    /// Reads the last `maxBytes` of the file (off the main thread). Skips malformed lines.
    private static func loadRows(path: String) -> [Row] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }

        let size = (try? fh.seekToEnd()) ?? 0
        let start: UInt64 = size > maxBytes ? size - maxBytes : 0
        guard (try? fh.seek(toOffset: start)) != nil,
              let data = try? fh.readToEnd() else { return [] }

        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        // If we seeked into the middle of the file, the first line is partial.
        if start > 0, !lines.isEmpty { lines.removeFirst() }

        let plainFmt = ISO8601DateFormatter()
        plainFmt.formatOptions = [.withInternetDateTime]
        let fracFmt = ISO8601DateFormatter()
        fracFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var out: [Row] = []
        for (i, line) in lines.enumerated() {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let tsStr = obj["ts"] as? String,
                  let ts = plainFmt.date(from: tsStr) ?? fracFmt.date(from: tsStr) else { continue }
            out.append(Row(
                id: i,
                ts: ts,
                app: (obj["app"] as? String) ?? "",
                raw: (obj["raw"] as? String) ?? "",
                clean: (obj["clean"] as? String) ?? "",
                firstMs: (obj["first_ms"] as? NSNumber)?.doubleValue,
                totalMs: (obj["total_ms"] as? NSNumber)?.doubleValue,
                polish: obj["polish"] as? String
            ))
        }
        out.sort { $0.ts > $1.ts }
        if out.count > maxRows { out = Array(out.prefix(maxRows)) }
        return out
    }

    // MARK: - Filtering / sorting

    private func applyFilter() {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = rows
        if !q.isEmpty {
            list = rows.filter {
                $0.raw.localizedCaseInsensitiveContains(q)
                    || $0.clean.localizedCaseInsensitiveContains(q)
                    || $0.app.localizedCaseInsensitiveContains(q)
            }
        }
        let ascending = table.sortDescriptors.first?.ascending ?? false
        list.sort { ascending ? $0.ts < $1.ts : $0.ts > $1.ts }

        let keepId = selectedRow()?.id
        shown = list
        table.reloadData()
        if let k = keepId, let idx = shown.firstIndex(where: { $0.id == k }) {
            table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }

        emptyLabel.stringValue = rows.isEmpty ? "还没有历史记录" : "没有匹配的记录"
        emptyLabel.isHidden = !shown.isEmpty
        updateDetail()
    }

    private func selectedRow() -> Row? {
        let i = table.selectedRow
        return (i >= 0 && i < shown.count) ? shown[i] : nil
    }

    // MARK: - Detail

    /// Writes clean text (14 pt) and raw text (12 pt) into the scrollable text view,
    /// with 8 pt spacing between them.
    private func setDetailText(clean: String, cleanColor: NSColor, raw: String?) {
        let cleanPara = NSMutableParagraphStyle()
        cleanPara.lineBreakMode = .byWordWrapping
        cleanPara.paragraphSpacing = raw == nil ? 0 : 8
        let text = NSMutableAttributedString(string: clean + (raw == nil ? "" : "\n"), attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: cleanColor,
            .paragraphStyle: cleanPara
        ])
        if let raw = raw {
            let rawPara = NSMutableParagraphStyle()
            rawPara.lineBreakMode = .byWordWrapping
            text.append(NSAttributedString(string: raw, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: rawPara
            ]))
        }
        detailText.textStorage?.setAttributedString(text)
        detailText.scrollToBeginningOfDocument(nil)
    }

    private func updateDetail() {
        guard let r = selectedRow() else {
            setDetailText(clean: "在上方选一条记录查看详情", cleanColor: .secondaryLabelColor, raw: nil)
            metaLabel.stringValue = ""
            copyResultButton.isEnabled = false
            copyRawButton.isEnabled = false
            return
        }
        setDetailText(clean: r.clean, cleanColor: .labelColor, raw: "原文：" + r.raw)

        var parts = ["模式：" + (r.polish ?? "无")]
        if let f = r.firstMs { parts.append("上屏 " + HistoryPane.fmtSec(f)) }
        if let t = r.totalMs { parts.append("总耗时 " + HistoryPane.fmtSec(t)) }
        metaLabel.stringValue = parts.joined(separator: "  ·  ")

        copyResultButton.isEnabled = true
        copyRawButton.isEnabled = true
    }

    private static func fmtSec(_ ms: Double) -> String {
        String(format: "%.2f s", ms / 1000)
    }

    // MARK: - Actions

    @objc private func searchChanged(_ sender: Any?) {
        applyFilter()
    }

    @objc private func refreshTapped(_ sender: Any?) {
        reload()
    }

    @objc private func copyResult(_ sender: Any?) {
        guard let r = selectedRow() else { return }
        copyToPasteboard(r.clean)
        flashCopied(copyResultButton, title: "复制结果", symbol: "doc.on.doc")
    }

    @objc private func copyRaw(_ sender: Any?) {
        guard let r = selectedRow() else { return }
        copyToPasteboard(r.raw)
        flashCopied(copyRawButton, title: "复制原文", symbol: "text.quote")
    }

    /// Shows "已复制" with a checkmark for 1.2 s, then restores the original title and symbol.
    private func flashCopied(_ button: NSButton, title: String, symbol: String) {
        button.title = "已复制"
        button.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "已复制")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            button.title = title
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        }
    }

    private func copyToPasteboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    // MARK: - Cells

    private func makeCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: 13)
        tf.textColor = .labelColor
        tf.lineBreakMode = .byTruncatingTail
        tf.maximumNumberOfLines = 1
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    // MARK: - Glass helpers

    /// Builds a button in the macOS 26 glass style (capsule, or circle for icon-only).
    /// Falls back to `.push` on earlier systems.
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
        return b
    }

    /// Returns (outer card view, inner content view). Uses NSGlassEffectView on macOS 26+,
    /// NSVisualEffectView otherwise.
    private static func makeCard() -> (NSView, NSView) {
        let inner = NSView()
        inner.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 20
            glass.contentView = inner
            return (glass, inner)
        } else {
            let vfx = NSVisualEffectView()
            vfx.material = .contentBackground
            vfx.blendingMode = .withinWindow
            vfx.state = .active
            vfx.wantsLayer = true
            vfx.layer?.cornerRadius = 14
            vfx.layer?.masksToBounds = true
            vfx.addSubview(inner)
            pin(inner, to: vfx, inset: 0)
            return (vfx, inner)
        }
    }

    private static func pin(_ v: NSView, to parent: NSView, inset: CGFloat) {
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            v.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
            v.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            v.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset)
        ])
    }
}

// MARK: - NSTableView

extension HistoryPane: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        shown.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row < shown.count else { return nil }
        let r = shown[row]
        let text: String
        switch col.identifier.rawValue {
        case "time": text = timeFmt.string(from: r.ts)
        case "app": text = r.app
        case "clean": text = r.clean
        default:
            if let ms = r.firstMs ?? r.totalMs {
                text = HistoryPane.fmtSec(ms)
            } else {
                text = "—"
            }
        }
        let cell = (tableView.makeView(withIdentifier: col.identifier, owner: self) as? NSTableCellView)
            ?? makeCell(id: col.identifier)
        if col.identifier.rawValue == "first" {
            cell.textField?.alignment = .right
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        } else {
            cell.textField?.alignment = .left
            cell.textField?.font = .systemFont(ofSize: 13)
        }
        cell.textField?.stringValue = text
        cell.textField?.toolTip = text
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetail()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        applyFilter()
    }
}
