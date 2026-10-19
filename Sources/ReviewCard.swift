import AppKit

/// Learned pairs wait in lexicon.json "pending" until the user confirms them. OpenLess #917: of 5 pairs a learner
/// accepted on its own in 2 days, 1 was right. A confirmed pair becomes a rule (`confirmed: true`);
/// a rejected one goes to "rejected" and is never offered again.
enum PendingStore {
    struct Item: Equatable {
        let wrong: String
        let right: String
        let hits: Int
        let source: String
        var isTerm = false   // a new word (wrong == ""), not a replacement rule

        var label: String { isTerm ? "新词：\(right)" : "\(wrong) → \(right)" }
    }

    static func load(_ url: URL) -> [Item] {
        guard let d = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [] }
        return ((root["pending"] as? [[String: Any]]) ?? []).compactMap { c in
            let isTerm = (c["kind"] as? String) == "term"
            guard let w = c["wrong"] as? String, let r = c["right"] as? String, !r.isEmpty, isTerm || !w.isEmpty else { return nil }
            return Item(wrong: w, right: r, hits: (c["hits"] as? NSNumber)?.intValue ?? 0,
                        source: (c["source"] as? String) ?? "", isTerm: isTerm)
        }
    }

    static func confirm(_ items: [(wrong: String, right: String)], url: URL) -> Bool {
        mutate(url) { root in
            var pending = (root["pending"] as? [[String: Any]]) ?? []
            var corr = (root["corrections"] as? [[String: Any]]) ?? []
            for item in items {
                let same: ([String: Any]) -> Bool = { ($0["wrong"] as? String) == item.wrong && ($0["right"] as? String) == item.right }
                guard let i = pending.firstIndex(where: same) else { continue }
                var c = pending.remove(at: i)
                if (c["kind"] as? String) == "term" {
                    var terms = (root["terms"] as? [String]) ?? []
                    if !terms.contains(item.right) { terms.append(item.right) }
                    root["terms"] = terms
                    continue
                }
                c["confirmed"] = true
                if !corr.contains(where: same) { corr.append(c) }
            }
            root["pending"] = pending
            root["corrections"] = corr
        }
    }

    static func reject(_ items: [(wrong: String, right: String)], url: URL) -> Bool {
        mutate(url) { root in
            var pending = (root["pending"] as? [[String: Any]]) ?? []
            var rejected = (root["rejected"] as? [String: Any]) ?? [:]
            var rejCorr = (rejected["corrections"] as? [[String: Any]]) ?? []
            var rejTerms = (rejected["terms"] as? [String]) ?? []
            for item in items {
                pending.removeAll { ($0["wrong"] as? String) == item.wrong && ($0["right"] as? String) == item.right }
                if item.wrong.isEmpty {   // a new word
                    if !rejTerms.contains(item.right) { rejTerms.append(item.right) }
                    continue
                }
                if !rejCorr.contains(where: { ($0["wrong"] as? String) == item.wrong && ($0["right"] as? String) == item.right }) {
                    rejCorr.append(["wrong": item.wrong, "right": item.right])
                }
            }
            root["pending"] = pending
            rejected["corrections"] = rejCorr
            rejected["terms"] = rejTerms
            root["rejected"] = rejected
        }
    }

    static func setUnless(wrong: String, right: String, unless: [String], url: URL) -> Bool {
        mutate(url) { root in
            var corr = (root["corrections"] as? [[String: Any]]) ?? []
            if let i = corr.firstIndex(where: { ($0["wrong"] as? String) == wrong && ($0["right"] as? String) == right }) {
                if unless.isEmpty { corr[i].removeValue(forKey: "unless") } else { corr[i]["unless"] = unless }
            }
            root["corrections"] = corr
        }
    }

    /// Re-reads lexicon.json (the learner may have just written it), applies `body`, writes atomically.
    static func mutate(_ url: URL, _ body: (inout [String: Any]) -> Void) -> Bool {
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let d = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return false }
            root = obj
        }
        body(&root)
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes]) else {
            return false
        }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".lexicon-\(UUID().uuidString).tmp")
        do {
            try out.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }
}

/// Small card at the bottom-right of the screen: "要记住这个纠错吗？ 扣德克斯 → Codex  ✓ ✗".
/// Shown after a learner run that queued new pairs. More than 3 new pairs: one summary card that opens the dictionary.
final class ReviewCard: NSObject {
    var onOpenDictionary: (() -> Void)?
    var onChanged: (() -> Void)?

    private let lexURL: URL
    private var panel: NSPanel?
    private var queue: [PendingStore.Item] = []
    private let title = NSTextField(labelWithString: "")
    private let pair = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private var buttons = NSStackView()

    init(lexURL: URL) {
        self.lexURL = lexURL
        super.init()
    }

    /// `items`: pairs that were not pending before the learner ran.
    func offer(_ items: [PendingStore.Item]) {
        guard !items.isEmpty else { return }
        if items.count > 3 {
            queue = []
            show(title: "学到 \(items.count) 条，等你确认", pair: items.prefix(3).map(\.label).joined(separator: "，") + "…",
                 note: "确认前它们不会改你的字", single: false)
        } else {
            queue = items
            next()
        }
    }

    private func next() {
        guard let item = queue.first else { close(); return }
        if item.isTerm {
            show(title: "要记住这个新词吗？", pair: item.right,
                 note: "记住后，识别时会优先认这个词", single: true)
        } else {
            show(title: "要记住这个纠错吗？", pair: item.label,
                 note: "以后识别出「\(item.wrong)」都会改成「\(item.right)」", single: true)
        }
    }

    private func show(title t: String, pair p: String, note n: String, single: Bool) {
        if panel == nil { build() }
        title.stringValue = t
        pair.stringValue = p
        note.stringValue = n
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if single {
            buttons.addArrangedSubview(button("✓ 记住", #selector(yes), key: "\r"))
            buttons.addArrangedSubview(button("✗ 不要", #selector(no)))
            buttons.addArrangedSubview(button("稍后", #selector(later)))
        } else {
            buttons.addArrangedSubview(button("去确认", #selector(open), key: "\r"))
            buttons.addArrangedSubview(button("稍后", #selector(later)))
        }
        guard let panel, let screen = NSScreen.main?.visibleFrame else { return }
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 360, height: 120)
        panel.setFrame(NSRect(x: screen.maxX - size.width - 20, y: screen.minY + 20, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    private func button(_ t: String, _ action: Selector, key: String = "") -> NSButton {
        let b = NSButton(title: t, target: self, action: action)
        b.bezelStyle = .push
        b.keyEquivalent = key
        return b
    }

    private func build() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                        styleMask: [.titled, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        title.font = .systemFont(ofSize: 13, weight: .semibold)
        pair.font = .systemFont(ofSize: 16, weight: .medium)
        pair.lineBreakMode = .byTruncatingTail
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [title, pair, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            root.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])
        p.contentView = root
        panel = p
    }

    @objc private func yes() {
        guard let item = queue.first else { return }
        if !PendingStore.confirm([(item.wrong, item.right)], url: lexURL) { NSSound.beep() }
        onChanged?()
        queue.removeFirst()
        next()
    }

    @objc private func no() {
        guard let item = queue.first else { return }
        if !PendingStore.reject([(item.wrong, item.right)], url: lexURL) { NSSound.beep() }
        onChanged?()
        queue.removeFirst()
        next()
    }

    @objc private func later() { queue = []; close() }

    @objc private func open() { close(); onOpenDictionary?() }

    private func close() { panel?.orderOut(nil) }
}
