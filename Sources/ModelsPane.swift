import AppKit

/// Models settings: one-click local model downloads plus third-party cloud polish configuration.
/// Visual language mirrors SettingsPane: section headings, glass cards, icon badges, glass buttons.
final class ModelsPane: NSViewController {
    var onCloudSaved: (() -> Void)?
    var onModelActivated: (() -> Void)?

    // MARK: - Stored state

    private var models: [ModelItem] = []
    private var loaded = false
    private var listFailed = false
    private var downloadErrors: [String: String] = [:]   // download could not be started
    private var activateErrors: [String: String] = [:]   // activation failed
    private var removeErrors: [String: String] = [:]     // custom model removal failed
    private var visible = false
    private var pollTimer: Timer?
    private var selectedFolder = ""
    private var guideFetched = false
    private var lastSig = ""
    private var awaitingInstall: Set<String> = []        // "下载并启用" started, not yet active
    private var justInstalled: Set<String> = []          // shows "✓ 已安装并启用" for 2 s

    private static let paneSize = NSSize(width: 690, height: 560)
    private static let sideInset: CGFloat = 24
    private static let cardRadius: CGFloat = 20
    private static let fallbackGuide = "只接受 MLX 格式（Apple Silicon）：文件夹含 config.json 和 *.safetensors；不支持 GGUF / PyTorch .bin / ONNX。"

    // MARK: - Views (built in loadView)

    private var mirrorSwitch: NSSwitch!
    private var headerRow: NSView!
    private var localStack: NSStackView!
    private var cloudStack: NSStackView!
    private var presetPopup: NSPopUpButton!
    private var baseField: NSTextField!
    private var modelField: NSTextField!
    private var keyField: NSSecureTextField!
    private var hintLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var importSegment: NSSegmentedControl!
    private var importKindPopup: NSPopUpButton!
    private var hfField: NSTextField!
    private var pathField: NSTextField!
    private var displayNameField: NSTextField!
    private var hfRowView: NSView!
    private var localRowView: NSView!
    private var importStatusLabel: NSTextField!
    private var guideToggle: NSButton!
    private var guideLabel: NSTextField!

    // MARK: - Lifecycle

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "模型"
    }

    required init?(coder: NSCoder) {
        fatalError("ModelsPane is code-only")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: Self.paneSize))
        view = root

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        pinEdges(scroll, to: root)

        let doc = ModelsFlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])

        // Card 1: local models
        mirrorSwitch = NSSwitch()
        mirrorSwitch.controlSize = .regular
        mirrorSwitch.state = Locale.current.region?.identifier == "CN" ? .on : .off
        headerRow = padded([horizontal([text("国内镜像", size: 13), flexibleSpacer(), mirrorSwitch], spacing: 8)])
        localStack = vertical([], spacing: 0)
        let localSection = section("本地模型（一键下载）", card: glassContainer(localStack))

        // Card: import custom models (HF repo or local MLX folder)
        importSegment = NSSegmentedControl(labels: ["Hugging Face 仓库", "本地文件夹"],
                                           trackingMode: .selectOne, target: self,
                                           action: #selector(importModeChanged(_:)))
        importSegment.selectedSegment = 0
        if #available(macOS 26.0, *) {
            importSegment.segmentDistribution = .fillEqually
        }
        importKindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        importKindPopup.controlSize = .large
        importKindPopup.addItems(withTitles: ["语音识别", "本地润色"])
        importKindPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        hfField = NSTextField(string: "")
        configureField(hfField, placeholder: "例如 mlx-community/whisper-large-v3-turbo")
        pathField = NSTextField(string: "")
        configureField(pathField, placeholder: "未选择")
        pathField.isEditable = false
        pathField.isSelectable = true
        let pickButton = modernButton("选择文件夹…", symbol: "folder", prominent: false,
                                      action: #selector(pickFolderTapped))
        displayNameField = NSTextField(string: "")
        configureField(displayNameField, placeholder: "显示名称（可选）")

        hfRowView = formRow("仓库", hfField)
        localRowView = formRow("文件夹", horizontal([pathField, pickButton], spacing: 8))
        localRowView.isHidden = true

        importStatusLabel = text("", size: 12, color: .secondaryLabelColor)
        let importButton = modernButton("导入", symbol: "square.and.arrow.down.on.square", prominent: true,
                                        action: #selector(importTapped))

        guideToggle = NSButton(title: "格式要求 ▸", target: self, action: #selector(guideToggled))
        guideToggle.isBordered = false
        guideToggle.font = .systemFont(ofSize: 11)
        guideToggle.contentTintColor = .controlAccentColor
        guideLabel = text(Self.fallbackGuide, size: 11, color: .secondaryLabelColor)
        guideLabel.isHidden = true

        let importItems: [NSView] = [
            padded([importSegment]),
            formRow("类型", importKindPopup),
            hfRowView,
            localRowView,
            formRow("显示名称", displayNameField),
            padded([horizontal([importButton, flexibleSpacer()], spacing: 10)]),
            padded([importStatusLabel]),
            padded([horizontal([guideToggle, flexibleSpacer()], spacing: 0), guideLabel]),
        ]
        let importStack = vertical(importItems, spacing: 0)
        fillWidth(importItems, in: importStack, inset: 0)
        let importSection = section("导入自定义模型", card: glassContainer(importStack))

        // Card 2: cloud polish
        presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        presetPopup.controlSize = .large
        presetPopup.addItems(withTitles: CloudConfig.presets.map { $0.name } + ["自定义"])
        presetPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged(_:))

        baseField = NSTextField(string: "")
        configureField(baseField, placeholder: "https://api.example.com/v1")
        modelField = NSTextField(string: "")
        configureField(modelField, placeholder: "模型名称")
        keyField = NSSecureTextField(string: "")
        configureField(keyField, placeholder: "粘贴你的 API Key")

        hintLabel = text("", size: 11, color: .secondaryLabelColor)
        statusLabel = text("", size: 12, color: .secondaryLabelColor)

        let testButton = modernButton("测试连接", symbol: "bolt.horizontal.circle", prominent: false,
                                      action: #selector(testTapped))
        let saveButton = modernButton("保存", symbol: "square.and.arrow.down", prominent: true,
                                      action: #selector(saveTapped))
        let deleteButton = NSButton(title: "删除密钥", target: self, action: #selector(deleteKeyTapped))
        deleteButton.isBordered = false
        deleteButton.font = .systemFont(ofSize: 12)
        deleteButton.contentTintColor = .systemRed
        let buttons = horizontal([testButton, saveButton, flexibleSpacer(), deleteButton], spacing: 10)

        cloudStack = vertical([], spacing: 0)
        setRows(cloudStack, [
            formRow("服务商", presetPopup),
            padded([hintLabel]),
            formRow("Base URL", baseField),
            formRow("模型名称", modelField),
            formRow("API Key", keyField),
            padded([buttons]),
            padded([statusLabel]),
        ])
        let cloudSection = section("云端润色模型（第三方）", card: glassContainer(cloudStack))

        let footer = text("API Key 保存在 macOS 钥匙串中，不写入任何文件。", size: 11,
                          color: .secondaryLabelColor)

        let sections: [NSView] = [
            text("模型", size: 26, weight: .bold),
            text("本地模型在你的 Mac 上运行，不上传任何声音；云端模型用于润色。", size: 13,
                 color: .secondaryLabelColor),
            localSection,
            importSection,
            cloudSection,
            footer,
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

        renderLocal()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        visible = false
        stopPolling()
    }

    /// Re-fetches the model list and cloud config. Call from viewWillAppear.
    func reload() {
        visible = true
        refreshCloud()
        fetchModels()
    }

    // MARK: - Local models

    private func fetchModels() {
        ModelAPI.list(cfg: ZConfig.load()) { [weak self] items in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let sig = (items ?? []).map { "\($0.id)|\($0.downloaded)|\($0.active)|\($0.downloading)|\($0.progress ?? -1)" }.joined(separator: ";")
                let changed = !self.loaded || self.listFailed != (items == nil) || sig != self.lastSig
                self.lastSig = sig
                self.loaded = true
                self.listFailed = items == nil
                self.models = items ?? []
                self.noteInstalls()
                if changed { self.renderLocal() }   // the 3 s idle poll must not rebuild rows under the cursor
                // also poll while idle: the model can change outside this page (another client, the server's
                // auto-activate after a download), and the page used to keep showing the old 使用中 row
                if self.visible {
                    self.startPolling(every: self.models.contains(where: { $0.downloading }) ? 1 : 3)
                } else {
                    self.stopPolling()
                }
            }
        }
    }

    /// Moves rows that finished "下载并启用" into the 2-second "已安装并启用" flash.
    private func noteInstalls() {
        for item in models where item.downloaded && item.active && awaitingInstall.contains(item.id) {
            awaitingInstall.remove(item.id)
            justInstalled.insert(item.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self = self else { return }
                self.justInstalled.remove(item.id)
                self.renderLocal()
            }
        }
    }

    private func startPolling(every interval: TimeInterval) {
        guard visible else { return }
        if let t = pollTimer, t.timeInterval == interval { return }
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.fetchModels()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func renderLocal() {
        guard isViewLoaded else { return }
        var rows: [NSView] = [headerRow]
        if listFailed {
            rows.append(padded([text("识别服务未运行，稍后再试", size: 12, color: .secondaryLabelColor)]))
        } else if !loaded {
            rows.append(padded([text("正在读取模型列表…", size: 12, color: .secondaryLabelColor)]))
        } else {
            let groups: [(kind: String, title: String, hint: String)] = [
                ("asr", "语音识别", "选一个即可；中文用户推荐标「推荐」的模型"),
                ("llm", "本地润色", "可选；用于完全离线模式和本地精修"),
            ]
            for group in groups {
                let items = models.filter { $0.kind == group.kind }.sorted { a, b in
                    if a.recommended != b.recommended { return a.recommended }
                    if a.size_gb != b.size_gb { return a.size_gb < b.size_gb }
                    return a.id < b.id
                }
                guard !items.isEmpty else { continue }
                let header = horizontal([
                    text(group.title, size: 11, weight: .semibold, color: .secondaryLabelColor),
                    text(group.hint, size: 11, color: .secondaryLabelColor),
                ], spacing: 8)
                rows.append(padded([header]))
                rows += items.map { modelRow($0) }
            }
        }
        setRows(localStack, rows)
    }

    private func modelRow(_ item: ModelItem) -> NSView {
        let isASR = item.kind == "asr"
        let badge = modelsIcon(isASR ? "waveform" : "sparkles", isASR ? .systemTeal : .systemIndigo)

        var titleItems: [NSView] = [text(item.name, size: 13, weight: .semibold)]
        if item.recommended { titleItems.append(modelsChip("推荐", color: .systemBlue)) }
        if item.tested { titleItems.append(modelsChip("已实测", color: .systemGreen)) }
        if item.custom == true { titleItems.append(modelsChip("自定义", color: .systemGray)) }
        // chips keep their natural width; a trailing spacer absorbs the free space instead of stretching a chip
        for v in titleItems { v.setContentHuggingPriority(.required, for: .horizontal) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleItems.append(spacer)

        let sizeText = String(format: "%.2f GB", item.size_gb)
        var textItems: [NSView] = [
            horizontal(titleItems, spacing: 6),
            text("\(item.desc) · \(sizeText)", size: 11, color: .secondaryLabelColor),
        ]
        if let intro = item.intro, !intro.isEmpty {
            let introLabel = text(intro, size: 11, color: .secondaryLabelColor)
            introLabel.maximumNumberOfLines = 3
            introLabel.toolTip = intro
            textItems.append(introLabel)
        }
        if let error = activateErrors[item.id] {
            textItems.append(text(error, size: 11, color: .systemOrange))
        }
        if let error = removeErrors[item.id] {
            textItems.append(text(error, size: 11, color: .systemOrange))
        }
        let column = vertical(textItems, spacing: 2)
        column.setContentHuggingPriority(.defaultLow, for: .horizontal)
        column.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var rowItems: [NSView] = [badge, column, flexibleSpacer(), modelControl(item)]
        if item.custom == true && !item.active && !item.downloading {
            rowItems.append(removeButton(item.id))
        }
        let row = horizontal(rowItems, spacing: 12)
        row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return row
    }

    /// Trailing control by state: progress, retry, in use, use, or download.
    private func modelControl(_ item: ModelItem) -> NSView {
        if item.downloading {
            let fraction = progressFraction(item.progress)
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
            bar.doubleValue = fraction
            bar.widthAnchor.constraint(equalToConstant: 120).isActive = true
            let percent = text("下载中 \(Int(fraction * 100))%", size: 11, color: .secondaryLabelColor)
            percent.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            percent.setContentHuggingPriority(.required, for: .horizontal)
            return horizontal([bar, percent], spacing: 8)
        }
        if item.downloaded {
            if item.active {
                if justInstalled.contains(item.id) {
                    return modelsChip("✓ 已安装并启用", color: .systemGreen)
                }
                return modelsChip("使用中", symbol: "checkmark.circle.fill", color: .systemGreen)
            }
            return modernButton("使用", symbol: "checkmark.circle", prominent: false,
                                action: #selector(activateTapped(_:)), id: item.id)
        }
        if let error = item.error ?? downloadErrors[item.id] {
            let label = text(error, size: 11, color: .systemOrange)
            label.preferredMaxLayoutWidth = 200
            let retry = modernButton("重试", symbol: "arrow.clockwise", prominent: false,
                                     action: #selector(downloadTapped(_:)), id: item.id)
            return horizontal([label, retry], spacing: 8)
        }
        return modernButton("下载并启用", symbol: "arrow.down.circle", prominent: true,
                            action: #selector(downloadTapped(_:)), id: item.id)
    }

    private func progressFraction(_ progress: Double?) -> Double {
        let raw = progress ?? 0
        let fraction = raw > 1 ? raw / 100 : raw   // accept 0...1 or 0...100
        return min(1, max(0, fraction))
    }

    /// Glass circle button that removes a custom model from the list (files are kept).
    private func removeButton(_ id: String) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(removeTapped(_:)))
        button.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "移除")
        button.identifier = NSUserInterfaceItemIdentifier(rawValue: id)
        button.toolTip = "从列表移除（不删除文件）"
        button.controlSize = .small
        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
            button.borderShape = .circle
        } else {
            button.bezelStyle = .circular
        }
        return button
    }

    private func setImportStatus(_ message: String, _ color: NSColor) {
        importStatusLabel.stringValue = message
        importStatusLabel.textColor = color
    }

    private func updateImportMode() {
        let isHF = importSegment.selectedSegment == 0
        hfRowView.isHidden = !isHF
        localRowView.isHidden = isHF
    }

    @objc private func importModeChanged(_ sender: NSSegmentedControl) {
        updateImportMode()
    }

    @objc private func pickFolderTapped() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedFolder = url.path
        pathField.stringValue = url.path
    }

    @objc private func importTapped() {
        let isHF = importSegment.selectedSegment == 0
        let value = isHF
            ? hfField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            : selectedFolder
        guard !value.isEmpty else {
            setImportStatus(isHF ? "请先填写 Hugging Face 仓库名" : "请先选择文件夹", .systemOrange)
            return
        }
        let kinds = ["asr", "llm"]
        let kind = kinds[max(0, importKindPopup.indexOfSelectedItem)]
        let typedName = displayNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String? = typedName.isEmpty ? nil : typedName
        setImportStatus("导入中…", .secondaryLabelColor)
        ModelAPI.importModel(source: isHF ? "hf" : "local", value: value, kind: kind, name: name,
                             mirror: mirrorSwitch.state == .on, cfg: ZConfig.load()) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error, !error.isEmpty {
                    self.setImportStatus("✗ \(error)", .systemRed)
                    return
                }
                self.setImportStatus(isHF ? "✓ 已导入，下载完成后点「使用」" : "✓ 已导入，点「使用」启用",
                                     .systemGreen)
                if isHF { self.hfField.stringValue = "" }
                self.displayNameField.stringValue = ""
                self.reload()
            }
        }
    }

    @objc private func guideToggled() {
        let expanding = guideLabel.isHidden
        guideLabel.isHidden = !expanding
        guideToggle.title = expanding ? "格式要求 ▾" : "格式要求 ▸"
        guard expanding, !guideFetched else { return }
        guideFetched = true
        ModelAPI.formatGuide(cfg: ZConfig.load()) { [weak self] guide in
            DispatchQueue.main.async {
                guard let self = self, let guide = guide, !guide.isEmpty else { return }
                self.guideLabel.stringValue = guide
            }
        }
    }

    @objc private func removeTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        ModelAPI.remove(id: id, cfg: ZConfig.load()) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error, !error.isEmpty {
                    self.removeErrors[id] = error
                } else {
                    self.removeErrors[id] = nil
                }
                self.reload()
            }
        }
    }

    // MARK: - Cloud config

    private func configureField(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.controlSize = .large
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func keyHint(forIndex index: Int) -> String {
        let presets = CloudConfig.presets
        guard index >= 0, index < presets.count else { return "" }
        return "密钥获取：\(presets[index].keyHint)"
    }

    /// Loads the saved cloud config into the fields. Does not touch the status label.
    private func refreshCloud() {
        guard isViewLoaded else { return }
        let current = CloudConfig.current()
        let presets = CloudConfig.presets
        let index = presets.firstIndex(where: { $0.name == current.provider }) ?? presets.count
        presetPopup.selectItem(at: index)
        baseField.stringValue = current.baseURL
        modelField.stringValue = current.model
        keyField.stringValue = ""
        keyField.placeholderString = current.hasKey ? "已保存（留空则不修改）" : "粘贴你的 API Key"
        hintLabel.stringValue = keyHint(forIndex: index)
    }

    private func applyPreset(_ index: Int) {
        hintLabel.stringValue = keyHint(forIndex: index)
        let presets = CloudConfig.presets
        guard index >= 0, index < presets.count else { return }
        let preset = presets[index]
        baseField.stringValue = preset.baseURL
        if !preset.model.isEmpty { modelField.stringValue = preset.model }
    }

    private func setStatus(_ message: String, _ color: NSColor) {
        statusLabel.stringValue = message
        statusLabel.textColor = color
    }

    private func currentProviderName() -> String {
        presetPopup.titleOfSelectedItem ?? "自定义"
    }

    // MARK: - Actions

    @objc private func downloadTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        ModelAPI.download(id: id, mirror: mirrorSwitch.state == .on, activate: true,
                          cfg: ZConfig.load()) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if ok {
                    self.downloadErrors[id] = nil
                    self.awaitingInstall.insert(id)
                    self.startPolling(every: 1)   // the timer refreshes the row within a second
                } else {
                    self.downloadErrors[id] = "下载启动失败"
                    self.fetchModels()
                }
            }
        }
    }

    @objc private func activateTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        ModelAPI.activate(id: id, cfg: ZConfig.load()) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error, !error.isEmpty {
                    self.activateErrors[id] = error
                } else {
                    self.activateErrors[id] = nil
                    self.onModelActivated?()
                }
                self.fetchModels()
            }
        }
    }

    @objc private func presetChanged(_ sender: NSPopUpButton) {
        applyPreset(sender.indexOfSelectedItem)
    }

    @objc private func testTapped() {
        let key = keyField.stringValue
        guard !key.isEmpty else {
            setStatus("请先粘贴 API Key（已保存的密钥不会回显）", .systemOrange)
            return
        }
        setStatus("测试中…", .secondaryLabelColor)
        CloudConfig.test(baseURL: baseField.stringValue, key: key, model: modelField.stringValue) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let reply):
                    self.setStatus("✓ 连接成功 · \(reply.0) ms · 回复：\(reply.1)", .systemGreen)
                case .failure(let error):
                    self.setStatus("✗ \(error.localizedDescription)", .systemRed)
                }
            }
        }
    }

    @objc private func saveTapped() {
        let saved = CloudConfig.save(provider: currentProviderName(),
                                     baseURL: baseField.stringValue,
                                     model: modelField.stringValue,
                                     key: keyField.stringValue)
        guard saved else {
            setStatus("保存失败", .systemRed)
            return
        }
        refreshCloud()
        setStatus("已保存", .systemGreen)
        onCloudSaved?()
    }

    @objc private func deleteKeyTapped() {
        let removed = CloudConfig.save(provider: currentProviderName(),
                                       baseURL: baseField.stringValue,
                                       model: modelField.stringValue,
                                       key: "-")
        guard removed else {
            setStatus("删除失败", .systemRed)
            return
        }
        refreshCloud()
        setStatus("已删除密钥", .systemGreen)
        onCloudSaved?()
    }

    // MARK: - Building blocks

    /// Small secondary heading above a glass card.
    private func section(_ title: String, card: NSView) -> NSView {
        let heading = text(title, size: 11, weight: .semibold, color: .secondaryLabelColor)
        let stack = vertical([heading, card], spacing: 8)
        fillWidth([card], in: stack, inset: 0)
        return stack
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

    /// Replaces a card's rows, separated by hairlines.
    private func setRows(_ stack: NSStackView, _ rows: [NSView]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        var items: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 { items.append(hairline()) }
            items.append(row)
        }
        for item in items { stack.addArrangedSubview(item) }
        fillWidth(items, in: stack, inset: 0)
    }

    /// Padded row whose children fill the width minus the side insets.
    private func padded(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let stack = vertical(views, spacing: spacing)
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        fillWidth(views, in: stack, inset: 28)
        return stack
    }

    /// Label column (84 pt) + control, inside a padded row.
    private func formRow(_ title: String, _ control: NSView) -> NSView {
        let label = text(title, size: 12, color: .secondaryLabelColor)
        label.widthAnchor.constraint(equalToConstant: 84).isActive = true
        return padded([horizontal([label, control], spacing: 10)], spacing: 0)
    }

    /// 28 x 28 continuous-corner colored square with a white SF Symbol.
    private func modelsIcon(_ symbol: String, _ color: NSColor) -> NSView {
        let badge = ModelsFillView(fill: color, radius: 7)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
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

    /// Capsule chip with optional symbol, tinted by its color.
    private func modelsChip(_ title: String, symbol: String? = nil, color: NSColor) -> NSView {
        var items: [NSView] = []
        if let symbol = symbol {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
            icon.contentTintColor = color
            items.append(icon)
        }
        let label = text(title, size: 11, weight: .semibold, color: color)
        label.setContentHuggingPriority(.required, for: .horizontal)
        items.append(label)
        return ModelsCapsuleView(content: horizontal(items, spacing: 3), fill: color.withAlphaComponent(0.16))
    }

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

    /// Capsule push button: Liquid Glass on macOS 26+, plain push bezel otherwise.
    private func modernButton(_ title: String, symbol: String?, prominent: Bool, action: Selector,
                              id: String? = nil) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        if let symbol = symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        if let id = id {
            button.identifier = NSUserInterfaceItemIdentifier(rawValue: id)
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

    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
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

    private func pinEdges(_ child: NSView, to parent: NSView) {
        if child.superview !== parent { parent.addSubview(child) }   // constraints need a common ancestor
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }
}

// MARK: - Helper views

/// Top-left origin so the scroll document lays out downward.
private final class ModelsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Capsule background behind content; fill re-resolves when the appearance changes.
private final class ModelsCapsuleView: NSView {
    private let fill: NSColor

    init(content: NSView, fill: NSColor) {
        self.fill = fill
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("ModelsCapsuleView is code-only")
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        layer?.cornerCurve = .continuous
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

/// Layer-backed rounded fill that re-resolves dynamic colors when the appearance changes.
private final class ModelsFillView: NSView {
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
        fatalError("ModelsFillView is code-only")
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
