import Foundation
import AppKit
import CoreGraphics

/// 一条语音口令：整句话等于 phrase 时，执行 action。
struct VoiceCommand {
    let phrase: String
    let action: String
}

/// 语音口令表：读取 commands.txt，匹配整句话，执行动作。
enum Commands {
    private static var cache: [VoiceCommand] = []
    private static var cachedMTime: Date?
    private static var loaded = false

    /// commands.txt 的位置（ZConfig.configDir 下）。
    static var fileURL: URL { ZConfig.configDir.appendingPathComponent("commands.txt") }

    /// 口令表条数（先按需重新加载）。
    static var count: Int {
        reloadIfNeeded()
        return cache.count
    }

    /// 默认文件内容。
    static let defaultContent = #"""
# 指语语音口令：整句话等于口令时，执行动作，不上屏文字。
# 格式：口令 => 动作      （一行一条，# 开头是注释）
# 动作：
#   key:return            按键（return tab esc delete space up down left right，或字母，可加 cmd+ shift+ opt+ ctrl+）
#   text:你好，世界        上屏一段固定文字（\n 表示换行）
#   run:~/bin/脚本.sh       运行脚本（会传入环境变量 ZHIYU_APP）
#   open:https://...        打开网址或文件
# 例子（去掉行首 # 生效）：
# 全选 => key:cmd+a
# 撤销 => key:cmd+z
# 换行 => key:shift+return
# 我的邮箱 => text:me@example.com
# 打开日历 => open:/System/Applications/Calendar.app

"""#

    /// 文件不存在时，写入默认内容。
    static func ensureFile() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: fileURL.path) else { return }
        try? fm.createDirectory(at: ZConfig.configDir, withIntermediateDirectories: true)
        try? defaultContent.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// 整句话等于某条口令时返回它；否则返回 nil。规范化后超过 12 字不匹配。
    static func match(_ text: String) -> VoiceCommand? {
        reloadIfNeeded()
        let spoken = normalize(text)
        guard !spoken.isEmpty, spoken.count <= 12 else { return nil }
        return cache.first { normalize($0.phrase) == spoken }
    }

    /// 执行口令动作。返回 true 表示动作已发出或已启动。
    static func run(_ c: VoiceCommand, appName: String, bundleID: String) -> Bool {
        guard let colon = c.action.firstIndex(of: ":") else { return false }
        let kind = c.action[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let arg = String(c.action[c.action.index(after: colon)...])
        switch kind {
        case "key": return sendKey(arg.trimmingCharacters(in: .whitespaces))
        case "text": return pasteText(arg)
        case "run": return runScript(arg.trimmingCharacters(in: .whitespaces), appName, bundleID)
        case "open": return openTarget(arg.trimmingCharacters(in: .whitespaces))
        default: return false
        }
    }

    // MARK: - 加载

    /// 文件修改时间变化时重新读取。
    private static func reloadIfNeeded() {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        if loaded && mtime == cachedMTime { return }
        loaded = true
        cachedMTime = mtime
        guard mtime != nil, let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            cache = []
            return
        }
        cache = parse(text)
    }

    /// 解析 "口令 => 动作" 行；跳过注释、空行和不完整的行。
    private static func parse(_ text: String) -> [VoiceCommand] {
        var out: [VoiceCommand] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let arrow = line.range(of: "=>") else { continue }
            let phrase = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            let action = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            if phrase.isEmpty || action.isEmpty { continue }
            out.append(VoiceCommand(phrase: phrase, action: action))
        }
        return out
    }

    /// 去掉空白和标点、符号，转小写。
    private static func normalize(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            if scalar.properties.isWhitespace { continue }
            switch scalar.properties.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .otherPunctuation,
                 .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
                continue
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out.lowercased()
    }

    // MARK: - 动作

    /// 虚拟键码表（macOS）。
    private static let keyCodes: [String: CGKeyCode] = [
        "return": 36, "tab": 48, "space": 49, "delete": 51, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]

    /// 发送一次按键（按下+抬起），如 "cmd+shift+z"。
    private static func sendKey(_ spec: String) -> Bool {
        let parts = spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, let code = keyCodes[key] else { return false }
        var flags = CGEventFlags()
        for mod in parts.dropLast() {
            switch mod {
            case "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "alt": flags.insert(.maskAlternate)
            case "ctrl": flags.insert(.maskControl)
            default: return false
            }
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown) else {
                return false
            }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    /// 经剪贴板上屏固定文字，0.5 秒后恢复原剪贴板文字。
    private static func pasteText(_ value: String) -> Bool {
        let text = value.replacingOccurrences(of: "\\n", with: "\n")
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        _ = sendKey("cmd+v")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pasteboard.clearContents()
            if let previous = previous {
                pasteboard.setString(previous, forType: .string)
            }
        }
        return true
    }

    /// 用 /bin/sh 启动脚本，不等待结束。
    private static func runScript(_ path: String, _ appName: String, _ bundleID: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", (path as NSString).expandingTildeInPath]
        var env = ProcessInfo.processInfo.environment
        env["ZHIYU_APP"] = appName
        env["ZHIYU_BUNDLE"] = bundleID
        process.environment = env
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    /// 打开网址或文件。
    private static func openTarget(_ value: String) -> Bool {
        let s = (value as NSString).expandingTildeInPath
        let url: URL?
        if s.hasPrefix("http://") || s.hasPrefix("https://") {
            url = URL(string: s)
        } else {
            url = URL(fileURLWithPath: s)
        }
        guard let target = url else { return false }
        return NSWorkspace.shared.open(target)
    }
}
