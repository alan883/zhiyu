import AppKit
import AVFoundation
import Carbon
import ServiceManagement

// MARK: - HUD (small pill near the cursor)


// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    private struct Job {
        let wav: Data
        let target: TextTarget?
        let selection: String?     // non-nil: the user selected text before speaking => voice command on it
        var retried = false
        var audio: String? = nil   // file name in audio/ (kept for replay / re-transcribe in 历史记录)
        var preview = ""           // live-preview text: tells the server which dictionary words were likely said
        var released = Date()      // key release: the user's clock starts here, not at the ASR request
    }

    private var statusItem: NSStatusItem!
    private let hud = HUD()
    private let trigger = TrackpadTrigger()
    private let recorder = AudioRecorder()
    private lazy var livePreview = LivePreview(base: cfg.asrURL)
    private var cfg = ZConfig.load()
    private lazy var window = MainWindowController(configDir: cfgDir)
    private var server: Process?
    private var learner: Process?
    private var lastPreview = ""
    private lazy var review = ReviewCard(lexURL: URL(fileURLWithPath: cfgDir + "/lexicon.json"))
    private var target: TextTarget?
    private var selection: String?
    private var jobs: [Job] = []          // sentences recorded while an earlier one is still processing
    private var processing = false
    private var sinceLearn = 0
    private var recent: [(at: Date, app: String, text: String)] = []   // last few dictations, context for terminals
    private var deliverySeq = 0
    private var onceApps = Set<String>()   // apps where a verified in-place swap failed: insert once from now on          // bumps on every insertion; a stale second pass must not touch newer text
    private var tapOK = false
    // project folder (holds .venv and the Python server); override with ZHIYU_HOME
    private let base = ProcessInfo.processInfo.environment["ZHIYU_HOME"]
        ?? (NSHomeDirectory() as NSString).appendingPathComponent("zhiyu")
    private let cfgDir = (NSHomeDirectory() as NSString).appendingPathComponent(".config/zhiyu")

    func applicationDidFinishLaunching(_ n: Notification) {
        migrateKeyToKeychain()
        try? FileManager.default.createDirectory(atPath: cfgDir, withIntermediateDirectories: true)
        buildMenu()
        replaceOutdatedServer { [weak self] in self?.startServerIfNeeded() }

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { log("accessibility not trusted yet") }
        AudioRecorder.requestPermission { ok in if !ok { self.log("microphone denied") } }

        applyConfig()
        trigger.onBegin = { [weak self] p in self?.begin(at: p) }
        trigger.onEnd = { [weak self] in self?.end() }
        trigger.onCancel = { [weak self] in self?.cancel() }
        trigger.onLocked = { [weak self] in
            guard let self else { return }
            self.hud.show("免提录音中… 再按一次 \(self.cfg.hotkeyLabel) 结束", at: CGEvent(source: nil)?.location)
        }
        trigger.onDiscard = { [weak self] in   // a lone quick tap: drop it silently
            guard let self else { return }
            _ = self.recorder.stop()
            if !self.processing { self.hud.hide() }
        }
        recorder.onLevel = { [weak self] v in self?.hud.level(v) }
        livePreview.onText = { [weak self] t in
            guard let self, self.recorder.isRecording else { return }
            self.lastPreview = t
            self.hud.preview(t)
        }
        recorder.onReady = { NSSound(named: "Tink")?.play() }
        tapOK = trigger.start()
        // headphones plugged in / mic switched: drop the warm engine so the next start rebuilds it
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.recorder.isRecording else { return }
            self.recorder.shutdown()
        }

        wireWindow()
        refreshStatus()
        window.show()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshStatus() }
        Commands.ensureFile()   // example file so users can see the format
        runLearner()   // catch up on anything dictated while the app was closed
        log("started")
    }

    /// A key found in config.json (plain text) moves into the Keychain, written by THIS app so later reads never prompt.
    private func migrateKeyToKeychain() {
        let path = cfgDir + "/config.json"
        guard let data = FileManager.default.contents(atPath: path),
              var j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let key = j["llm_key"] as? String, !key.isEmpty, Keychain.set(key) else { return }
        j.removeValue(forKey: "llm_key")
        if let out = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        cfg = ZConfig.load()
        log("api key moved into keychain")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.show()
        return true
    }

    func applicationWillTerminate(_ n: Notification) {
        recorder.shutdown()
        server?.terminate()
    }

    private func applyConfig() {
        trigger.hotkey = Hotkey(keycode: cfg.hotkeyCode, modifier: cfg.hotkeyModifier, label: cfg.hotkeyLabel)
        trigger.forceClickEnabled = cfg.forceClick
        trigger.handsFreeEnabled = cfg.handsFree
        window.settings.setFeatures(handsFree: cfg.handsFree, autoSend: cfg.autoSend, offline: cfg.offlineOnly)
        window.settings.setAppStyles(appStyleRows())
        window.overview.setNetworkPlan(Cleaner.networkPlan(cfg: cfg), offline: cfg.offlineOnly)
        recorder.noiseMode = cfg.noiseMode
        recorder.preferBuiltIn = cfg.micPreferBuiltIn
        recorder.pinnedMic = cfg.micDevice
        window.settings.setMics(DeviceInfo.allInputs(), selected: cfg.micDevice)
        window.settings.setPrompt(cfg.polishPrompt, builtIn: Cleaner.builtInPrompt)
        window.settings.setHooks(filter: Hooks.hasFilter, after: Hooks.hasAfter)
        window.settings.setMicPreferBuiltIn(cfg.micPreferBuiltIn)
        window.settings.setLivePreview(cfg.livePreview)
        window.settings.setSettings(hotkeyLabel: cfg.hotkeyLabel, forceClick: cfg.forceClick, noiseMode: cfg.noiseMode, polish: cfg.polish)
        window.settings.setExtra(twoPass: cfg.twoPass, launchAtLogin: SMAppService.mainApp.status == .enabled)
        window.overview.setLexicon(manual: cfg.dictionary.count, learnedTerms: cfg.learnedTerms.count,
                          corrections: cfg.corrections.count, lastLearn: lexiconUpdated())
    }

    private func wireWindow() {
        window.settings.onChangeHotkey = { [weak self] done in
            guard let self else { return }
            self.trigger.captureNext { hk in
                if let hk {
                    self.cfg.hotkeyCode = hk.keycode
                    self.cfg.hotkeyModifier = hk.modifier
                    self.cfg.hotkeyLabel = hk.label
                    self.cfg.save()
                    self.applyConfig()
                }
                done(hk?.label)
            }
        }
        window.settings.onToggleForceClick = { [weak self] on in self?.cfg.forceClick = on; self?.cfg.save(); self?.applyConfig() }
        window.settings.onToggleNoiseMode = { [weak self] on in self?.cfg.noiseMode = on; self?.cfg.save(); self?.applyConfig() }
        window.settings.onToggleLivePreview = { [weak self] on in
            guard let self else { return }
            self.cfg.livePreview = on
            self.cfg.save()
            self.applyConfig()
            if on { self.livePreview.refreshStatus() }
        }
        window.settings.onChangeMic = { [weak self] uid in
            guard let self else { return }
            self.cfg.micDevice = uid
            self.cfg.save()
            self.applyConfig()
            self.showMic(announce: true)
        }
        window.settings.onSavePrompt = { [weak self] text in
            guard let self else { return }
            self.cfg.polishPrompt = text
            self.cfg.save()
            self.hud.show(text.isEmpty ? "已恢复默认提示词" : "提示词已保存", autoHide: 1.2)
        }
        window.settings.onOpenCommands = {
            Commands.ensureFile()
            NSWorkspace.shared.open(Commands.fileURL)
        }
        window.settings.onOpenHooksFolder = {
            try? FileManager.default.createDirectory(at: Hooks.dir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Hooks.dir)
        }
        window.settings.onTogglePreferBuiltIn = { [weak self] on in
            guard let self else { return }
            self.cfg.micPreferBuiltIn = on
            self.cfg.save()
            self.applyConfig()
            self.showMic(announce: true)
        }
        window.settings.onChangePolish = { [weak self] mode in self?.cfg.polish = mode; self?.cfg.save(); self?.applyConfig() }
        window.settings.onToggleTwoPass = { [weak self] on in self?.cfg.twoPass = on; self?.cfg.save(); self?.applyConfig() }
        window.settings.onToggleLaunchAtLogin = { [weak self] on in
            guard let self else { return }
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                self.cfg.launchAtLogin = on
            } catch {
                self.hud.show("开机自启设置失败：\(error.localizedDescription)", autoHide: 3)
                self.cfg.launchAtLogin = SMAppService.mainApp.status == .enabled
            }
            self.cfg.save(); self.applyConfig()
        }
        trigger.onCaptureRejected = { [weak self] reason in self?.hud.show(reason, autoHide: 2.5) }
        window.settings.onToggleHandsFree = { [weak self] on in self?.cfg.handsFree = on; self?.cfg.save(); self?.applyConfig() }
        window.settings.onToggleAutoSend = { [weak self] on in self?.cfg.autoSend = on; self?.cfg.save(); self?.applyConfig() }
        window.settings.onToggleOffline = { [weak self] on in
            guard let self else { return }
            self.cfg.offlineOnly = on; self.cfg.save(); self.applyConfig()
            self.hud.show(on ? "已切换为完全离线：不再连接任何云端" : "已恢复联网润色", autoHide: 1.8)
        }
        window.settings.onChangeAppStyle = { [weak self] bundleID, style in
            guard let self else { return }
            if style.isEmpty { self.cfg.appStyles.removeValue(forKey: bundleID) } else { self.cfg.appStyles[bundleID] = style }
            self.cfg.save(); self.applyConfig()
        }
        // dictionary edited in the app: reload terms/corrections so the next dictation uses them
        window.dictionary.onChanged = { [weak self] in
            guard let self else { return }
            let keep = self.cfg
            self.cfg = ZConfig.load()
            self.cfg.polish = keep.polish
            self.applyConfig()
        }
        review.onChanged = { [weak self] in self?.window.dictionary.onChanged?(); self?.window.dictionary.reload() }
        review.onOpenDictionary = { [weak self] in
            guard let self else { return }
            self.window.show()
            self.window.select(3)
            self.window.dictionary.showPending()
        }
        offerNewPending()
        // cloud provider / local model changed in the 模型 page: pick up new credentials and server state
        window.models.onCloudSaved = { [weak self] in
            guard let self else { return }
            let keep = self.cfg
            self.cfg = ZConfig.load()
            self.cfg.polish = keep.polish
            self.applyConfig()
            self.hud.show("云端模型已更新", autoHide: 1.2)
        }
        window.models.onModelActivated = { [weak self] in self?.refreshStatus() }
        // 历史记录 → 重新识别: run a saved take through the current model again (no polish, nothing typed)
        window.history.onRetranscribe = { [weak self] url, done in
            guard let self, let wav = try? Data(contentsOf: url) else { done(nil); return }
            ASRClient.transcribe(wav: wav, hotwords: self.cfg.allTerms, cfg: self.cfg) { r in
                DispatchQueue.main.async { done((try? r.get())?.text) }
            }
        }
        DeviceInfo.observe { [weak self] _ in
            guard let self else { return }
            self.showMic(announce: self.micShown != nil)   // the first report at launch is not announced
            self.window.settings.setMics(DeviceInfo.allInputs(), selected: self.cfg.micDevice)
        }
    }

    private var hooksShown: [Bool] = []
    private var commandsShown = -1
    private var micShown: String?   // "default>recording" device pair last shown; a change is announced

    /// Shows the device the next take will record from (may differ from the system default: Bluetooth → built-in).
    /// With `announce`, a real switch is also shown next to the mouse.
    private func showMic(announce: Bool) {
        let def = DeviceInfo.currentInput()
        let rec = DeviceInfo.info(DeviceInfo.recordingInput(preferBuiltIn: cfg.micPreferBuiltIn, pinnedUID: cfg.micDevice))
        let name = rec?.name ?? "未检测到麦克风"
        window.overview.setMic(name: name, symbol: rec?.symbol ?? "mic.slash", builtIn: rec?.isBuiltIn ?? false)
        let key = "\(def?.id ?? 0)>\(rec?.id ?? 0)"
        defer { micShown = key }
        if announce, key != micShown, !recorder.isRecording {
            let msg = def != nil && def?.id != rec?.id
                ? "🎧 \(def!.name) 只放声音 · 录音用 \(name)"
                : "🎙 已切换到 \(name)"
            hud.show(msg, at: CGEvent(source: nil)?.location, autoHide: 2.2)
        }
    }

    private var statsAt = Date.distantPast

    /// Usage stats for the overview card, recomputed at most every 30 s.
    private func refreshStats() {
        guard Date().timeIntervalSince(statsAt) > 30 else { return }
        statsAt = Date()
        let path = cfgDir + "/history.jsonl"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
            var n = 0, chars = 0, firsts: [Int] = []
            for line in text.split(separator: "\n") {
                guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                n += 1
                if let ts = d["ts"] as? String, ts.hasPrefix(today), let c = d["clean"] as? String { chars += c.count }
                if let f = d["first_ms"] as? Int { firsts.append(f) }
            }
            firsts.sort()
            let median = firsts.isEmpty ? nil : firsts[firsts.count / 2]
            DispatchQueue.main.async { self?.window.overview.setStats(dictations: n, todayChars: chars, medianFirstMs: median) }
        }
    }

    private func refreshStatus() {
        showMic(announce: true)   // the lid can close/open without a device-change event
        if cfg.livePreview, !livePreview.available { livePreview.refreshStatus() }
        let hooks = [Hooks.hasFilter, Hooks.hasAfter]
        if hooks != hooksShown || Commands.count != commandsShown {   // only on change: these rebuild settings controls
            hooksShown = hooks
            commandsShown = Commands.count
            window.settings.setHooks(filter: hooks[0], after: hooks[1])
            window.settings.setCommands(count: commandsShown)
        }
        refreshStats()
        if !tapOK && AXIsProcessTrusted() { tapOK = trigger.start() }
        // Secure Keyboard Entry (password fields, some terminals) silently blinds every event tap
        window.overview.setWarning(IsSecureEventInputEnabled()
            ? "“安全输入”已开启（密码框或终端的安全键盘输入），快捷键暂时收不到。关掉它或离开密码框后恢复。" : nil)
        ASRClient.health(cfg: cfg) { [weak self] ok in
            guard let self else { return }
            self.window.overview.update(asrOK: ok, axOK: AXIsProcessTrusted(),
                                        micOK: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                                        tapOK: self.tapOK)
            let ready = ok && AXIsProcessTrusted() && self.tapOK
            self.window.setFooterStatus(ready: ready, text: ready ? "就绪 · \(self.cfg.hotkeyLabel)" : "需要处理")
        }
    }

    // MARK: pipeline

    private func begin(at p: CGPoint) {
        if IsSecureEventInputEnabled() { hud.show("安全输入已开启，无法录音", at: p, autoHide: 2); return }
        target = AXTarget.editableElement(at: p) ?? AXTarget.focusedTarget()
        selection = target.flatMap { AXTarget.selectedText(of: $0) }
        Cleaner.prewarm(cfg: cfg)   // TLS to the polish LLM is ready by the time the user stops talking
        do {
            try recorder.start()
            let what = selection != nil ? "说出修改指令…（改写选中文字）" : "听着… " + (target.map { "→ \($0.appName)" } ?? "→ 当前焦点")
            hud.show(processing ? "听着…（上一句还在处理）" : what, at: p)
            lastPreview = ""
            if cfg.livePreview, selection == nil { livePreview.start(recorder) }
        } catch {
            hud.show("录音失败：\(error.localizedDescription)", at: p, autoHide: 3)
        }
    }

    private func cancel() {
        livePreview.stop()
        _ = recorder.stop()
        hud.show("已取消", autoHide: 0.8)
    }

    private func end() {
        livePreview.stop()
        let tgt = target, sel = selection, pv = lastPreview, releasedAt = Date()
        recorder.stop(postRoll: 0.25) { [weak self] wav in   // keep listening a moment so the last word isn't clipped
            guard let self else { return }
            guard !wav.isEmpty else {
                // nothing captured (mic switched mid-flight or released too fast): reset the pipeline, say so
                self.recorder.shutdown()
                if !self.processing { self.hud.show("没收到声音：麦克风已重置，请再说一次", autoHide: 2.5) }
                return
            }
            self.jobs.append(Job(wav: wav, target: tgt, selection: sel, audio: self.saveAudio(wav), preview: pv, released: releasedAt))
            self.processNext()
        }
    }

    private func processNext() {
        guard !processing, !jobs.isEmpty else { return }
        processing = true
        let job = jobs.removeFirst()
        hud.level(0)
        hud.show("识别中…")
        let t0 = Date()
        if let a = job.audio { releaseGap[a] = Int(t0.timeIntervalSince(job.released) * 1000) }
        ASRClient.transcribe(wav: job.wav, hotwords: cfg.allTerms, preview: job.preview, cfg: cfg) { [weak self] r in
            guard let self else { return }
            switch r {
            case .failure(let e):
                self.startServerIfNeeded()
                if !job.retried {   // server may be restarting: try once more before giving up
                    var again = job; again.retried = true
                    self.jobs.insert(again, at: 0)
                    self.processing = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.processNext() }
                    return
                }
                let saved = self.saveFailed(job.wav)
                self.finishJob(message: "识别失败：\(e.localizedDescription)（录音已存 \(saved)）", hold: 4)
            case .success(let asr):
                let asrMs = Int(Date().timeIntervalSince(t0) * 1000)
                if asr.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.finishJob(message: "没听清", hold: 1)
                    return
                }
                // a spoken command (commands.txt): the whole utterance is the trigger; nothing is typed
                if job.selection == nil, let cmd = Commands.match(asr.text) ?? Commands.match(asr.raw) {
                    let ok = Commands.run(cmd, appName: job.target?.appName ?? "", bundleID: job.target?.bundleID ?? "")
                    self.record(raw: asr.raw, clean: "", app: job.target?.appName ?? "", asrMs: asrMs, totalMs: asrMs, firstMs: asrMs,
                                swap: "command:\(cmd.phrase)" + (ok ? "" : ":failed"), audio: job.audio)
                    self.finishJob(message: ok ? "⌘ \(cmd.phrase)" : "口令没执行成功：\(cmd.action)", hold: ok ? 1.0 : 3)
                    return
                }
                let (sendText, send) = self.cfg.autoSend ? Cleaner.extractSend(asr.text) : (asr.text, false)
                if let sel = job.selection, let t = job.target {
                    self.runCommand(asr.text, on: sel, in: t, t0: t0)
                } else if send {
                    // never submit a half-corrected sentence: settle the text first, insert once, then press Return
                    self.terminalOnce(ASRResult(text: sendText, raw: asr.raw, similar: asr.similar), job: job, t0: t0, asrMs: asrMs, sendAfter: true)
                } else if self.cfg.twoPass, let t = job.target, AXTarget.isUnverifiable(t) || self.onceApps.contains(t.bundleID) {
                    self.terminalOnce(asr, job: job, t0: t0, asrMs: asrMs)
                } else if self.cfg.twoPass {
                    self.twoPass(asr, job: job, t0: t0, asrMs: asrMs)
                } else {
                    self.onePass(asr, job: job, t0: t0, asrMs: asrMs)
                }
            }
        }
    }

    /// Pass 1: local rules + pinyin-dictionary fixes go on screen immediately.
    /// Pass 2: LLM refines in the background and swaps the text in place — only if the user hasn't touched it since.
    private func twoPass(_ asr: ASRResult, job: Job, t0: Date, asrMs: Int) {
        let env = hookEnv(job, raw: asr.raw)
        let fast = Hooks.filter(Cleaner.rules(asr.text, cfg: cfg), env: env)
        guard let out = deliver(fast, to: job.target) else {
            finishJob(message: "没找到输入框，已复制到剪贴板（⌘V 粘贴）", hold: 3)
            return
        }
        let firstMs = Int(Date().timeIntervalSince(t0) * 1000)
        deliverySeq += 1
        let mySeq = deliverySeq
        let insertedAt = ProcessInfo.processInfo.systemUptime
        let terminal = out.map { AXTarget.isTerminal($0) } ?? false
        let caret = terminal ? nil : out.flatMap { AXTarget.caretLocation(of: $0) }
        finishJob(message: "✓ \(fast)", hold: 1.0)
        window.overview.setLast(raw: asr.raw, clean: fast, ms: firstMs)
        let tgt = job.target
        let appName = tgt?.appName ?? ""
        recent = recent.filter { Date().timeIntervalSince($0.at) < 180 }
        // terminals expose no readable field text: use what the user just dictated there as context instead
        let ctx = terminal || (tgt?.contextBefore ?? "").isEmpty
            ? recent.filter { $0.app == appName }.suffix(3).map(\.text).joined(separator: " ")
            : (tgt?.contextBefore ?? "")
        recent.append((Date(), appName, fast))
        Cleaner.refine(fast, appName: appName, contextBefore: ctx, similar: asr.similar,
                       singleLine: terminal, style: cfg.style(for: tgt?.bundleID ?? ""), cfg: cfg) { [weak self] polished in
            guard let self else { return }
            let better = polished.map { Hooks.filter($0, env: env) }.flatMap { $0 == fast ? nil : $0 }
            var final = fast
            var swap = better == nil ? "unchanged:\(Cleaner.lastRefineNote)" : "no-target"
            if let better, let t = out { swap = self.swapIn(fast, better, in: t, caret: caret, seq: mySeq, since: insertedAt) }
            if let better, swap == "ax" {
                final = better
                if let i = self.recent.lastIndex(where: { $0.text == fast }) { self.recent[i].text = better }
                self.hud.show("✎ 已纠正", autoHide: 0.8)
                self.window.overview.setLast(raw: asr.raw, clean: better, ms: firstMs)
            }
            let totalMs = Int(Date().timeIntervalSince(t0) * 1000)
            self.record(raw: asr.raw, clean: final, app: tgt?.appName ?? "", asrMs: asrMs, totalMs: totalMs, firstMs: firstMs,
                        swap: swap, refined: better, audio: job.audio)
            if let t = out, !terminal { self.watchEdits(of: final, in: t) }
            self.noteDictation()
        }
    }

    /// Native fields: verified AX range replace. Terminals/Electron (no reliable AXValue): backspace + paste,
    /// only if nothing has happened since our insertion — no newer dictation, no recording, no user key/click, same app in front.
    /// Returns how the swap went: "ax" | "keys" | "skipped:<why>".
    private func swapIn(_ old: String, _ new: String, in t: TextTarget, caret: Int?, seq: Int, since: TimeInterval) -> String {
        guard seq == deliverySeq else { return "skipped:newer-text" }
        guard !recorder.isRecording else { return "skipped:recording" }
        // only a verified AX range replace is allowed; anything else risks duplicated or mangled text
        if let caret, AXTarget.replaceRecent(old: old, new: new, caret: caret, in: t) { return "ax" }
        if !trigger.userInputSince(since) { onceApps.insert(t.bundleID) }   // the app itself can't do it, not the user's fault
        return "skipped:unverifiable"
    }

    /// Terminals can't be verified after the fact, so never edit there: wait up to 1.2 s for the polish, then type once.
    private func terminalOnce(_ asr: ASRResult, job: Job, t0: Date, asrMs: Int, sendAfter: Bool = false) {
        let fast = Cleaner.rules(asr.text, cfg: cfg)
        let appName = job.target?.appName ?? ""
        recent = recent.filter { Date().timeIntervalSince($0.at) < 180 }
        let ctx = recent.filter { $0.app == appName }.suffix(3).map(\.text).joined(separator: " ")
        var done = false
        let finish: (String, String) -> Void = { [weak self] text, how in
            guard let self, !done else { return }
            done = true
            let text = Hooks.filter(text, env: self.hookEnv(job, raw: asr.raw))
            let out = self.deliver(text, to: job.target)
            if sendAfter, out != nil { self.pressReturn(after: 0.15) }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            self.recent.append((Date(), appName, text))
            self.window.overview.setLast(raw: asr.raw, clean: text, ms: ms)
            self.record(raw: asr.raw, clean: text, app: appName, asrMs: asrMs, totalMs: ms, firstMs: ms, swap: sendAfter ? how + "+send" : how, audio: job.audio)
            self.finishJob(message: out != nil ? "✓ \(text)" : "没找到输入框，已复制到剪贴板（⌘V 粘贴）", hold: 1.0)
            self.noteDictation()
        }
        // Short and clean: polish changed the words of none of 16 such sentences (history, 10-12/13), so don't wait.
        // The polish still runs in the background, logged as tag "quick" in polish.jsonl: note "ok" there means
        // skipping lost a real fix, and the rule should be tightened.
        if cfg.polish == "auto", Self.quickEnough(fast, asr) {
            finish(fast, "terminal:quick")
            Cleaner.refine(fast, appName: appName, contextBefore: ctx, similar: asr.similar, singleLine: true,
                           style: cfg.style(for: job.target?.bundleID ?? ""), tag: "quick", cfg: cfg) { _ in }
            return
        }
        // Ship at ASR speed. The insertion runs on the next main-queue turn, which is the same context the
        // old 1.2 s timer used, so no AX work happens inside the ASR completion stack. A 300-take replay
        // showed a full-budget polish leaves 66% of sentences byte-identical, so the wait is dropped here:
        // the terminal is never rewritten, and a different polish result is reported in the HUD instead.
        let style = cfg.style(for: job.target?.bundleID ?? "")
        let polishEnabled = cfg.polish != "fast"
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            finish(fast, "terminal:immediate")
            guard polishEnabled else { return }
            // The polish keeps running for the log and the learner, but it must not pop a second HUD:
            // the user reads the green tick as "done", and anything after it is noise.
            Cleaner.refine(fast, appName: appName, contextBefore: ctx, similar: asr.similar, singleLine: true,
                           style: style, cfg: self.cfg) { _ in }
        }
    }

    private func onePass(_ asr: ASRResult, job: Job, t0: Date, asrMs: Int) {
        if cfg.polish != "fast" { hud.show("整理中…") }
        Cleaner.clean(asr.text, appName: job.target?.appName ?? "", contextBefore: job.target?.contextBefore ?? "",
                      style: cfg.style(for: job.target?.bundleID ?? ""), cfg: cfg) { [weak self] text in
            guard let self else { return }
            let out = self.deliver(text, to: job.target)
            let totalMs = Int(Date().timeIntervalSince(t0) * 1000)
            self.window.overview.setLast(raw: asr.raw, clean: text, ms: totalMs)
            self.record(raw: asr.raw, clean: text, app: job.target?.appName ?? "", asrMs: asrMs, totalMs: totalMs, firstMs: totalMs, audio: job.audio)
            if let t = out ?? nil, !AXTarget.isTerminal(t) { self.watchEdits(of: text, in: t) }
            self.finishJob(message: out != nil ? "✓ \(text)" : "没找到输入框，已复制到剪贴板（⌘V 粘贴）", hold: out != nil ? 1.2 : 3)
            self.noteDictation()
        }
    }

    private func runCommand(_ instruction: String, on selected: String, in t: TextTarget, t0: Date) {
        hud.show("改写中：\(instruction)")
        Cleaner.command(instruction, selected: selected, appName: t.appName, cfg: cfg) { [weak self] result in
            guard let self else { return }
            guard let result, !result.isEmpty else {
                self.finishJob(message: "改写失败（网络或超时），原文未动", hold: 2.5)
                return
            }
            // the selection is still active, so inserting replaces it
            let ok = AXTarget.selectedText(of: t) == selected && AXTarget.insert(result, into: t)
            if !ok {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
            }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            self.window.overview.setLast(raw: "指令：\(instruction)", clean: result, ms: ms)
            self.finishJob(message: ok ? "✓ 已改写" : "选区变了，结果已复制到剪贴板", hold: ok ? 1.2 : 3)
        }
    }

    private func finishJob(message: String, hold: TimeInterval) {
        processing = false
        if recorder.isRecording { processNext(); return }   // don't cover the "听着" HUD of a live recording
        hud.show(message, autoHide: jobs.isEmpty ? hold : nil)
        processNext()
    }

    private func noteDictation() {
        sinceLearn += 1
        if sinceLearn >= 5 { runLearner() }
    }

    /// Insert into the target. Returns the element written to (nil element inside = unknown, but written),
    /// or nil if nothing safe was found — then the text is only put on the clipboard (never blind-pasted).
    private func deliver(_ text: String, to tgt: TextTarget?) -> TextTarget?? {
        if let t = tgt ?? AXTarget.focusedTarget() {
            return AXTarget.insert(text, into: t) ? .some(t) : nil
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return nil
    }

    private func pressReturn(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let src = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: down)
                e?.flags = []
                e?.setIntegerValueField(.eventSourceUserData, value: zhiyuSyntheticTag)
                e?.post(tap: .cghidEventTap)
            }
        }
    }

    /// Rows for the per-app style list: user choices plus defaults for apps that are actually installed.
    private func appStyleRows() -> [(bundleID: String, name: String, style: String, isDefault: Bool)] {
        var ids = Set(cfg.appStyles.keys)
        for id in ZConfig.defaultAppStyles.keys where NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil { ids.insert(id) }
        return ids.map { id in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
            return (id, name, cfg.style(for: id), cfg.appStyles[id] == nil)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A sentence the polish almost never improves: under 20 characters, no filler sound, no near-sound dictionary candidate.
    private static func quickEnough(_ text: String, _ asr: ASRResult) -> Bool {
        text.count < 20 && asr.similar.isEmpty
            && asr.raw.range(of: "[呃嗯额]", options: .regularExpression) == nil
    }

    /// Environment for plug-in scripts (see Hooks.swift).
    private func hookEnv(_ job: Job, raw: String) -> [String: String] {
        ["ZHIYU_APP": job.target?.appName ?? "", "ZHIYU_BUNDLE": job.target?.bundleID ?? "", "ZHIYU_RAW": raw,
         "ZHIYU_MIC": DeviceInfo.info(recorder.activeDevice)?.name ?? ""]
    }

    private static let audioKeep = 200   // newest takes kept on disk (~5 s each ≈ 160 KB → ~32 MB)

    /// Saves a take to audio/ for replay and re-transcription, then prunes all but the newest `audioKeep`. Returns the file name.
    private func saveAudio(_ wav: Data) -> String? {
        let dir = cfgDir + "/audio"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let name = "\(Int(Date().timeIntervalSince1970 * 1000)).wav"
        guard fm.createFile(atPath: dir + "/" + name, contents: wav) else { return nil }
        DispatchQueue.global(qos: .utility).async {
            let files = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".wav") }.sorted()
            for f in files.dropLast(Self.audioKeep) { try? fm.removeItem(atPath: dir + "/" + f) }
        }
        return name
    }

    private func saveFailed(_ wav: Data) -> String {
        let dir = cfgDir + "/failed"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/\(Int(Date().timeIntervalSince1970)).wav"
        FileManager.default.createFile(atPath: path, contents: wav)
        return "~/.config/zhiyu/failed"
    }

    // MARK: learning

    /// 8 s after inserting, look at the field again; if the user hand-fixed our text, log it for the learner.
    private func watchEdits(of inserted: String, in t: TextTarget) {
        // look twice like VoiceInk's observation window: quick fixes (8 s) and later proofreading (45 s)
        let seen = Box()
        for delay in [8.0, 45.0] { checkEdits(of: inserted, in: t, after: delay, seen: seen) }
    }

    private final class Box { var logged: String? }   // one edit must be logged once, not once per look

    private func checkEdits(of inserted: String, in t: TextTarget, after delay: TimeInterval, seen: Box) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(t.element, kAXValueAttribute as CFString, &v) == .success,
                  let value = v as? String, !value.contains(inserted) else { return }
            // anchor on the text that was before the caret, take the region where our text went
            let anchor = String(t.contextBefore.suffix(20))
            var region = Substring(value)
            if !anchor.isEmpty {
                // The anchor must occur exactly once. A repeated phrase would otherwise pick the wrong
                // copy of the text and teach a correction from something the user never typed.
                let hits = value.components(separatedBy: anchor).count - 1
                guard hits == 1, let r = value.range(of: anchor) else { return }
                region = value[r.upperBound...]
            }
            let final = String(region.prefix(inserted.count + inserted.count / 2 + 4))
            // terminals soft-wrap long lines (newline + indent in AXValue): whitespace-only differences are not edits
            let squash = { (x: String) in x.components(separatedBy: .whitespacesAndNewlines).joined() }
            guard !final.isEmpty, squash(final) != squash(inserted), !squash(final).hasPrefix(squash(inserted)) else { return }
            let row: [String: Any] = ["ts": ISO8601DateFormatter().string(from: Date()), "app": t.appName,
                                      "inserted": inserted, "final": final]
            guard seen.logged != final else { return }
            seen.logged = final
            self.appendJSONL(row, to: "edits.jsonl")
        }
    }

    private func runLearner() {
        guard learner?.isRunning != true else { return }
        sinceLearn = 0
        let p = Process()
        p.executableURL = URL(fileURLWithPath: base + "/.venv/bin/python")
        p.arguments = ["-I", base + "/learner.py"]
        // hand the key over directly: the learner must never touch the Keychain (that triggers a password prompt)
        var env = ProcessInfo.processInfo.environment
        if !cfg.llmKey.isEmpty { env["ZHIYU_LLM_KEY"] = cfg.llmKey }
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let keep = self.cfg
                self.cfg = ZConfig.load()
                self.cfg.polish = keep.polish
                self.applyConfig()
                self.offerNewPending()
            }
        }
        do { try p.run(); learner = p } catch { log("learner spawn failed: \(error)") }
    }

    /// Pairs the learner queued that the user has not been shown yet get a review card.
    private func offerNewPending() {
        let key = "reviewShown"
        var shown = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let fresh = PendingStore.load(URL(fileURLWithPath: cfgDir + "/lexicon.json")).filter { !shown.contains("\($0.wrong)→\($0.right)") }
        guard !fresh.isEmpty else { return }
        fresh.forEach { shown.insert("\($0.wrong)→\($0.right)") }
        UserDefaults.standard.set(Array(shown), forKey: key)
        review.offer(fresh)
    }

    private func lexiconUpdated() -> String? {
        guard let d = FileManager.default.contents(atPath: cfgDir + "/lexicon.json"),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let u = j["updated"] as? String else { return nil }
        return String(u.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }

    // MARK: ASR server

    static let serverVersion = 10

    /// An ASR server left over from an older app build keeps answering /health but lacks new endpoints:
    /// if its version is older than ours, stop it so startServerIfNeeded() spawns the current one.
    private func replaceOutdatedServer(then: @escaping () -> Void) {
        var req = URLRequest(url: cfg.asrURL.appendingPathComponent("health"))
        req.timeoutInterval = 2
        ASRClient.session.dataTask(with: req) { data, _, _ in
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let v = obj?["version"] as? Int ?? 0
            if obj != nil, v < App.serverVersion {
                let port = self.cfg.asrURL.port ?? 8776
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", "lsof -ti tcp:\(port) -sTCP:LISTEN | xargs kill 2>/dev/null"]
                try? p.run(); p.waitUntilExit()
                Thread.sleep(forTimeInterval: 1)
            }
            DispatchQueue.main.async(execute: then)
        }.resume()
    }

    private func startServerIfNeeded() {
        ASRClient.health(cfg: cfg) { [weak self] ok in
            guard let self, !ok, self.server?.isRunning != true else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: self.base + "/.venv/bin/python")
            p.arguments = ["-I", self.base + "/asr_server.py"]
            p.currentDirectoryURL = URL(fileURLWithPath: self.cfgDir)
            var env = ProcessInfo.processInfo.environment
            env["HF_HUB_OFFLINE"] = "1"   // models already cached; never block on network
            // The recognizer talks to nothing. A SOCKS proxy inherited from the launching shell makes
            // huggingface_hub build an httpx client that needs `socksio`, which the venv does not have.
            for key in ["all_proxy", "ALL_PROXY", "http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY"] {
                env.removeValue(forKey: key)
            }
            p.environment = env
            let logURL = URL(fileURLWithPath: self.cfgDir + "/asr_server.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            if let h = try? FileHandle(forWritingTo: logURL) { p.standardOutput = h; p.standardError = h }
            do { try p.run(); self.server = p; self.log("asr server spawned pid \(p.processIdentifier)") }
            catch { self.log("asr server spawn failed: \(error)") }
        }
    }

    // MARK: menu / misc

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let glyph = Bundle.main.image(forResource: "menubar") ?? NSImage(systemSymbolName: "mic.circle", accessibilityDescription: "指语")!
        glyph.size = NSSize(width: 18, height: 18)
        glyph.isTemplate = true
        statusItem.button?.image = glyph
        let m = NSMenu()
        let w = NSMenuItem(title: "打开指语", action: #selector(showWindow), keyEquivalent: "")
        w.target = self
        m.addItem(w)
        let d = NSMenuItem(title: "编辑个人词典…", action: #selector(openDictionary), keyEquivalent: "")
        d.target = self
        m.addItem(d)
        m.addItem(.separator())
        m.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = m
    }

    @objc private func showWindow() { window.show() }

    @objc private func openDictionary() {
        let path = cfgDir + "/dictionary.txt"
        if !FileManager.default.fileExists(atPath: path) {
            try? "# 一行一个词：人名、术语、项目名…\n".write(toFile: path, atomically: true, encoding: .utf8)
        }
        window.show()
        window.select(3)   // built-in dictionary page; no external editor needed
    }

    private var releaseGap: [String: Int] = [:]   // audio file → ms from key release to ASR request

    private func record(raw: String, clean: String, app: String, asrMs: Int, totalMs: Int, firstMs: Int,
                        swap: String? = nil, refined: String? = nil, audio: String? = nil) {
        var row: [String: Any] = ["ts": ISO8601DateFormatter().string(from: Date()), "app": app, "raw": raw, "clean": clean,
                                  "polish": cfg.polish, "two_pass": cfg.twoPass, "asr_ms": asrMs, "first_ms": firstMs,
                                  "total_ms": totalMs]
        if let mic = DeviceInfo.info(recorder.activeDevice)?.name { row["mic"] = mic }
        if let audio { row["audio"] = audio }
        // release_ms = key release → text on screen (post-roll + queue wait + ASR + rules), what the user feels
        if let audio, let gap = releaseGap.removeValue(forKey: audio) { row["release_ms"] = gap + firstMs }
        Hooks.after(clean, env: ["ZHIYU_APP": app, "ZHIYU_RAW": raw, "ZHIYU_MIC": (row["mic"] as? String) ?? ""])
        if let swap { row["swap"] = swap }
        if let refined, refined != clean { row["refined_unapplied"] = refined }   // second pass had a fix but couldn't apply it
        appendJSONL(row, to: "history.jsonl")
    }

    private func appendJSONL(_ row: [String: Any], to name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: row),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let path = cfgDir + "/" + name
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func log(_ s: String) {
        FileHandle.standardError.write("[zhiyu] \(s)\n".data(using: .utf8)!)
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
