import Foundation

/// User plug-in scripts in ~/.config/zhiyu/hooks/ (the "socket": anyone can add behavior without changing the app).
///
/// - `filter`: runs before text goes on screen. stdin = the text (UTF-8); stdout = the text to insert.
///   Gets 0.3 s. Non-zero exit, timeout or empty output → the original text is used.
/// - `after`: runs after the text is on screen, in the background. stdin = the final text. Output is ignored.
///
/// Both get these environment variables: ZHIYU_APP (app name), ZHIYU_BUNDLE (bundle id), ZHIYU_RAW (recognizer text),
/// ZHIYU_MIC (microphone name). A script must be executable (chmod +x).
enum Hooks {
    static var dir: URL { ZConfig.configDir.appendingPathComponent("hooks") }
    private static let filterTimeout: TimeInterval = 0.3

    static func path(_ name: String) -> String? {
        let p = dir.appendingPathComponent(name).path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    static var hasFilter: Bool { path("filter") != nil }
    static var hasAfter: Bool { path("after") != nil }

    /// Runs `filter` synchronously (at most 0.3 s). Returns the new text, or `text` unchanged.
    static func filter(_ text: String, env: [String: String]) -> String {
        guard let p = path("filter") else { return text }
        let started = Date()
        guard let out = run(p, input: text, env: env, wait: filterTimeout) else {
            log("filter: no result after \(Int(Date().timeIntervalSince(started) * 1000)) ms, kept original")
            return text
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? text : trimmed
    }

    /// Runs `after` in the background with the final text. Never blocks.
    static func after(_ text: String, env: [String: String]) {
        guard let p = path("after") else { return }
        DispatchQueue.global(qos: .utility).async { _ = run(p, input: text, env: env, wait: 30) }
    }

    /// Starts the script, writes `input` to stdin, waits up to `wait` seconds. Returns stdout on exit status 0.
    private static func run(_ path: String, input: String, env: [String: String], wait: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        // stdin is written and closed BEFORE launch: otherwise the child inherits our write end and never sees EOF
        // (measured: every stdin-reading script hit the timeout). Dictated text is far below the 64 KB pipe buffer.
        let bytes = Data(input.utf8)
        guard bytes.count < 60_000 else { log("\(path): input too large, skipped"); return nil }
        inPipe.fileHandleForWriting.write(bytes)
        try? inPipe.fileHandleForWriting.close()
        do { try p.run() } catch { log("\(path): \(error.localizedDescription)"); return nil }
        // read stdout concurrently so a chatty script can't fill the pipe and stall
        var outData = Data()
        let reader = DispatchQueue(label: "zhiyu.hook.read")
        let readDone = DispatchSemaphore(value: 0)
        reader.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); readDone.signal() }
        if done.wait(timeout: .now() + wait) == .timedOut {
            p.terminate()
            return nil
        }
        _ = readDone.wait(timeout: .now() + 0.1)
        guard p.terminationStatus == 0 else { log("\(path): exit \(p.terminationStatus)"); return nil }
        return String(data: outData, encoding: .utf8)
    }

    private static func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        let url = ZConfig.configDir.appendingPathComponent("hooks.log")
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
