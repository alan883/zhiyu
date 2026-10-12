import AppKit
import ApplicationServices

struct TextTarget {
    let element: AXUIElement
    let pid: pid_t
    let appName: String
    let bundleID: String
    let role: String
    let contextBefore: String   // up to 300 chars before caret (or end of value), "" if unreadable
}

enum AXTarget {
    /// point is in global CG coordinates (origin top-left of main display), e.g. from CGEvent.location
    static func editableElement(at point: CGPoint) -> TextTarget? {
        let sys = bounded(AXUIElementCreateSystemWide())
        guard var hit = hitElement(sys, point) else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(hit, &pid)
        // Chromium/Electron build their AX tree lazily; re-hit once after enabling so we get the real node.
        if enableAccessibility(pid: pid), let again = hitElement(sys, point) { hit = again }
        if isSecure(hit) { return nil }   // never touch password fields

        var cur: AXUIElement? = hit
        for _ in 0...6 {   // hit element + up to 6 ancestors
            guard let el = cur else { break }
            if isEditable(el) { return makeTarget(el) }
            cur = copyElement(el, "AXParent")
        }
        return nil
    }

    /// currently focused UI element if editable
    static func focusedTarget() -> TextTarget? {
        // the system-wide focused-element query fails (-25204) on recent macOS; ask the frontmost app first
        var found: AXUIElement?
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            found = copyElement(bounded(AXUIElementCreateApplication(pid)), "AXFocusedUIElement")
        }
        guard let el = found ?? copyElement(bounded(AXUIElementCreateSystemWide()), "AXFocusedUIElement") else { return nil }
        if isSecure(el) { return nil }   // never touch password fields
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        _ = enableAccessibility(pid: pid)
        return isEditable(el) ? makeTarget(el) : nil
    }

    /// bring app to front and set AXFocused=true on the element
    static func focus(_ t: TextTarget) {
        NSRunningApplication(processIdentifier: t.pid)?.activate(options: [])
        AXUIElementSetAttributeValue(t.element, "AXFocused" as CFString, kCFBooleanTrue)
    }

    /// insert text at caret/selection; returns true on success
    static func insert(_ text: String, into t: TextTarget) -> Bool {
        // terminals accept AXSelectedText writes silently without inserting anything: always paste there
        if !isTerminal(t), insertViaSelectedText(text, t) { return true }
        // Paste goes to the frontmost app, so make sure the target is frontmost and focused first.
        focus(t)
        usleep(80_000)
        if !isFrontmost(t.pid) {
            usleep(120_000)
            if !isFrontmost(t.pid) {
                // Cmd+V would land in another app: leave the text on the pasteboard for the user instead.
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                return false
            }
        }
        return insertViaPaste(text)
    }

    private static func isFrontmost(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// Current caret (UTF-16 offset) if the selection is empty; nil if unreadable or a range is selected.
    static func caretLocation(of t: TextTarget) -> Int? {
        guard let r = copyRange(t.element), r.length == 0 else { return nil }
        return r.location
    }

    /// Currently selected text in the element (non-empty) or nil.
    static func selectedText(of t: TextTarget) -> String? {
        guard let s = copyString(t.element, "AXSelectedText"), !s.isEmpty else { return nil }
        return s
    }

    /// Replaces `old` with `new` only if the text right before `caret` is still `old` and the caret has not moved.
    /// Never falls back to paste/keystrokes. Returns true only on verified success.
    static func replaceRecent(old: String, new: String, caret: Int, in t: TextTarget) -> Bool {
        let n = (old as NSString).length
        guard n > 0, caret >= n, let vs = copyString(t.element, "AXValue") else { return false }
        let v = vs as NSString
        guard caret <= v.length, caretLocation(of: t) == caret else { return false }
        let range = NSRange(location: caret - n, length: n)
        guard v.substring(with: range) == old else { return false }

        guard setSelectedRange(t.element, CFRange(location: caret - n, length: n)) else { return false }
        AXUIElementSetAttributeValue(t.element, "AXSelectedText" as CFString, new as CFString)
        usleep(40_000)

        let expected = v.replacingCharacters(in: range, with: new)
        let after = copyString(t.element, "AXValue")
        if after == expected {
            let pos = caret - n + (new as NSString).length
            if caretLocation(of: t) != pos { setSelectedRange(t.element, CFRange(location: pos, length: 0)) }
            return true
        }
        // Nothing changed: put the caret back where the user had it. Otherwise leave the field alone.
        if after == vs { setSelectedRange(t.element, CFRange(location: caret, length: 0)) }
        return false
    }

    /// Terminals / TUI hosts: AXValue is the whole screen buffer, so AX-based replace and edit read-back are meaningless there.
    static func isTerminal(_ t: TextTarget) -> Bool {
        let ids: Set<String> = [
            "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
            "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
            "com.otty.app", "io.otty.Otty",
        ]
        if ids.contains(t.bundleID) { return true }
        let name = t.appName.lowercased()
        return ["terminal", "iterm", "warp", "ghostty", "kitty", "alacritty", "wezterm", "otty", "hyper"].contains { name.contains($0) }
    }

    /// UNSAFE, DISABLED: posts Backspaces without verifying the deletion. A terminal TUI drops most of a fast burst,
    /// then the paste lands on top -> duplicated text. Kept only for API compatibility. Use replaceBySelection.
    static func replaceByKeystrokes(old: String, new: String, in t: TextTarget) -> Bool {
        return false
    }

    /// Replace the just-inserted `old` (ending at the caret) with `new` by extending a selection leftwards and pasting over it,
    /// verifying via Accessibility that the selection is exactly the text to replace before pasting.
    /// Returns false (changing nothing) if anything cannot be verified.
    static func replaceBySelection(old: String, new: String, in t: TextTarget) -> Bool {
        guard !isTerminal(t), NSWorkspace.shared.frontmostApplication?.processIdentifier == t.pid else { return false }
        guard !old.contains("\n"), !new.contains("\n"), !old.contains("\r"), !new.contains("\r"),
              old.unicodeScalars.count == old.count else { return false }
        let p = zip(old, new).prefix(while: { $0 == $1 }).count
        let del = old.count - p
        guard (1...300).contains(del) else { return false }
        let tail = String(new.dropFirst(p))
        let oldTail = String(old.suffix(del))

        // Precondition: empty selection, and the text right before the caret is exactly oldTail (UTF-16 based).
        guard let vs = copyString(t.element, "AXValue"), let caret = caretLocation(of: t) else { return false }
        let ns = vs as NSString
        let tailLen = (oldTail as NSString).length
        guard caret >= tailLen, caret <= ns.length,
              ns.substring(with: NSRange(location: caret - tailLen, length: tailLen)) == oldTail else { return false }

        // Extend the selection leftwards by del graphemes, spaced out so the TUI cannot drop presses.
        let src = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<del {
            for keyDown in [true, false] {
                let ev = CGEvent(keyboardEventSource: src, virtualKey: 123, keyDown: keyDown)   // 123 = LeftArrow
                ev?.flags = [.maskShift]
                postTagged(ev)
            }
            usleep(10_000)
        }
        var matched = false
        let deadline = Date().addingTimeInterval(0.3)
        while true {
            if copyString(t.element, "AXSelectedText") == oldTail { matched = true; break }
            if Date() >= deadline { break }
            usleep(50_000)
        }
        guard matched else {
            // Collapse whatever got selected back to the caret and stop.
            for keyDown in [true, false] {
                let ev = CGEvent(keyboardEventSource: src, virtualKey: 124, keyDown: keyDown)   // 124 = RightArrow
                ev?.flags = []
                postTagged(ev)
            }
            return false
        }

        if tail.isEmpty {
            for keyDown in [true, false] {
                let ev = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: keyDown)   // 51 = Backspace removes selection
                ev?.flags = []
                postTagged(ev)
            }
        } else if !insertViaPaste(tail, expectedPid: t.pid) {
            return false
        }

        // Post-verify: the last 12 chars of `new` must sit immediately before the caret.
        usleep(150_000)
        let want = String(new.suffix(12))
        let wantLen = (want as NSString).length
        guard let after = copyString(t.element, "AXValue"), let pos = caretLocation(of: t) else { return false }
        let ns2 = after as NSString
        guard pos >= wantLen, pos <= ns2.length else { return false }
        return ns2.substring(with: NSRange(location: pos - wantLen, length: wantLen)) == want
    }

    // MARK: - Editability

    private static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    private static let nonEditableRoles: Set<String> = ["AXStaticText", "AXButton", "AXCheckBox", "AXSlider"]

    private static func isEditable(_ el: AXUIElement) -> Bool {
        let role = copyString(el, "AXRole") ?? ""
        let subrole = copyString(el, "AXSubrole") ?? ""
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" { return false }   // never touch passwords
        if editableRoles.contains(role) || subrole == "AXSearchField" { return true }
        if nonEditableRoles.contains(role) { return false }
        if isValueSettable(el) { return true }
        return isTruthy(el, "AXEditableAncestor") || isTruthy(el, "AXEditable")
    }

    // MARK: - Accessibility enabling (Chromium / Electron)

    private static var enabledPIDs = Set<pid_t>()   // main-thread only; each pid is probed once

    /// Returns true if this call newly enabled AX for a Chromium-family app.
    private static func enableAccessibility(pid: pid_t) -> Bool {
        guard pid > 0, !enabledPIDs.contains(pid) else { return false }
        enabledPIDs.insert(pid)
        guard isChromiumFamily(pid: pid) else { return false }
        let app = bounded(AXUIElementCreateApplication(pid))
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return true
    }

    /// Apps whose text we cannot verify after insertion (terminals, Electron/Chromium apps, browsers):
    /// the caller must insert exactly once there and never edit afterwards.
    static func isUnverifiable(_ t: TextTarget) -> Bool {
        if isTerminal(t) || isChromiumFamily(pid: t.pid) { return true }
        let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "company.thebrowser.Browser",
                                     "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera"]
        return browsers.contains(t.bundleID)
    }

    private static func isChromiumFamily(pid: pid_t) -> Bool {
        guard let bundleURL = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let markers = ["Electron Framework.framework", "Chromium Embedded Framework.framework", "Google Chrome Framework.framework"]
        return markers.contains { FileManager.default.fileExists(atPath: frameworks.appendingPathComponent($0).path) }
    }

    // MARK: - Insertion

    /// Strategy A: AXSelectedText. Many Chromium fields return .success without changing anything,
    /// so an unchanged value is re-checked (50 ms, then 200 ms) before falling back to paste.
    /// Falls back only if the write errored, or the value is readable and still equals the pre-insert value at both checks
    /// (proving nothing was inserted). Any change, or an unreadable value, counts as success (avoids double insertion).
    private static func insertViaSelectedText(_ text: String, _ t: TextTarget) -> Bool {
        let before = copyString(t.element, "AXValue")
        guard AXUIElementSetAttributeValue(t.element, "AXSelectedText" as CFString, text as CFString) == .success else {
            return false
        }
        guard let before else { return true }   // pre-insert value unreadable: trust .success
        // "value changed" is not proof: live content (streaming output, timers) changes by itself.
        // Success = our text now occurs more often than before.
        let n0 = occurrences(of: text, in: before)
        for wait in [50_000, 150_000] as [useconds_t] {
            usleep(wait)
            guard let now = copyString(t.element, "AXValue") else { return true }
            if occurrences(of: text, in: now) > n0 { return true }
        }
        return false   // not visibly inserted -> let paste fall back
    }

    private static func occurrences(of needle: String, in hay: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return hay.components(separatedBy: needle).count - 1
    }

    /// Strategy B: save the full pasteboard, offer the text lazily (Cmd+V), restore once the target has read it.
    private static func insertViaPaste(_ text: String, expectedPid: pid_t? = nil) -> Bool {
        let pb = NSPasteboard.general
        if let expected = expectedPid, !isFrontmost(expected) {
            // Target lost focus mid-edit: never Cmd+V into another app. Leave the text on the pasteboard.
            pb.clearContents()
            pb.setString(text, forType: .string)
            return false
        }
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let session = PasteSession(text: text, saved: saved)
        activePaste = session
        let item = NSPasteboardItem()
        item.setDataProvider(session, forTypes: [.string])
        pb.clearContents()
        pb.writeObjects([item])
        session.pasteboardChangeCount = pb.changeCount
        postCommandV()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { session.restore(after: 0) }   // safety net
        return true
    }

    private static var activePaste: PasteSession?   // main-thread only; keeps the provider alive until restored

    /// Supplies the string when the target app reads the pasteboard, then restores the saved contents.
    /// Main-thread state only; the provider callback hops to main before scheduling the restore.
    private final class PasteSession: NSObject, NSPasteboardItemDataProvider {
        private let text: String
        private let saved: [[(NSPasteboard.PasteboardType, Data)]]
        private var scheduled = false
        /// NSPasteboard.changeCount right after our writeObjects; restore is skipped if it has moved since.
        var pasteboardChangeCount = -1

        init(text: String, saved: [[(NSPasteboard.PasteboardType, Data)]]) {
            self.text = text
            self.saved = saved
        }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            guard type == .string else { return }
            item.setString(text, forType: .string)
            DispatchQueue.main.async { self.restore(after: 0.2) }
        }

        func restore(after delay: TimeInterval) {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                defer { if AXTarget.activePaste === self { AXTarget.activePaste = nil } }
                let pb = NSPasteboard.general
                // Something was copied/written after our paste: do not clobber it with the saved contents.
                guard pb.changeCount == self.pasteboardChangeCount else { return }
                pb.clearContents()
                let items: [NSPasteboardItem] = self.saved.map { entries in
                    let item = NSPasteboardItem()
                    for (type, data) in entries { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { pb.writeObjects(items) }
            }
        }
    }

    private static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let ev = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: keyDown)   // 9 = 'v'
            ev?.flags = .maskCommand
            postTagged(ev)
        }
    }

    /// Marks the event as ours (so the event tap can ignore it) and posts it to the HID tap.
    private static func postTagged(_ ev: CGEvent?) {
        ev?.setIntegerValueField(.eventSourceUserData, value: zhiyuSyntheticTag)
        ev?.post(tap: .cghidEventTap)
    }

    // MARK: - Helpers

    private static func makeTarget(_ el: AXUIElement) -> TextTarget {
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        let app = NSRunningApplication(processIdentifier: pid)
        return TextTarget(
            element: el,
            pid: pid,
            appName: app?.localizedName ?? "",
            bundleID: app?.bundleIdentifier ?? "",
            role: copyString(el, "AXRole") ?? "",
            contextBefore: contextBefore(el)
        )
    }

    /// Up to 300 UTF-16 units before the caret, never splitting a surrogate pair, never crashing.
    private static func contextBefore(_ el: AXUIElement) -> String {
        guard let value = copyString(el, "AXValue") else { return "" }
        let ns = value as NSString
        let caret = copyRange(el)?.location ?? ns.length
        let end = min(max(caret, 0), ns.length)
        var start = max(0, end - 300)
        if start > 0, (0xDC00...0xDFFF).contains(ns.character(at: start)) { start += 1 }   // low surrogate
        guard start < end else { return "" }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    /// Caps how long any AX call on this element may block, so a hung app cannot freeze the main thread (event tap).
    @discardableResult
    private static func bounded(_ el: AXUIElement) -> AXUIElement {
        _ = AXUIElementSetMessagingTimeout(el, 0.4)
        return el
    }

    private static func isSecure(_ el: AXUIElement) -> Bool {
        let role = copyString(el, "AXRole") ?? ""
        let subrole = copyString(el, "AXSubrole") ?? ""
        return role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    private static func hitElement(_ sys: AXUIElement, _ p: CGPoint) -> AXUIElement? {
        var out: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &out) == .success, let out else { return nil }
        return bounded(out)
    }

    private static func copyElement(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return bounded(v as! AXUIElement)
    }

    private static func copyString(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func copyRange(_ el: AXUIElement) -> CFRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXSelectedTextRange" as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
    }

    @discardableResult
    private static func setSelectedRange(_ el: AXUIElement, _ range: CFRange) -> Bool {
        var r = range
        guard let v = AXValueCreate(.cfRange, &r) else { return false }
        return AXUIElementSetAttributeValue(el, "AXSelectedTextRange" as CFString, v) == .success
    }

    private static func isValueSettable(_ el: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, "AXValue" as CFString, &settable) == .success && settable.boolValue
    }

    /// Non-nil and not CFBoolean false (attribute may be a bool or an element reference).
    private static func isTruthy(_ el: AXUIElement, _ attr: String) -> Bool {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v else { return false }
        if let n = v as? NSNumber { return n.boolValue }
        return true
    }
}
