import AppKit
import CoreGraphics

/// Tag our own posted CGEvents carry in `.eventSourceUserData`, so user-input tracking can ignore them.
let zhiyuSyntheticTag: Int64 = 0x5A48_5955

/// A push-to-talk key: a modifier (handled via flagsChanged) or an ordinary key (keyDown/keyUp).
struct Hotkey: Equatable {
    var keycode: Int64      // CGKeyCode
    var modifier: Bool      // true if keycode is a modifier key (handled via flagsChanged)
    var label: String       // human label in Chinese, e.g. "右 Option"

    static let rightOption = Hotkey(keycode: 61, modifier: true, label: "右 Option")

    private static let names: [Int64: String] = [
        54: "右 Command", 55: "左 Command", 56: "左 Shift", 60: "右 Shift",
        58: "左 Option", 61: "右 Option", 59: "左 Control", 62: "右 Control",
        63: "fn", 57: "Caps Lock",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        49: "空格", 36: "回车", 48: "Tab",
    ]

    static func label(for keycode: Int64) -> String { names[keycode] ?? "键 \(keycode)" }

    static func isModifierKeycode(_ k: Int64) -> Bool { (54...63).contains(k) }
}

/// Global push-to-talk trigger: a configurable hotkey and/or Force Click (pressure stage 2) start, release ends.
final class TrackpadTrigger {
    var onBegin: ((CGPoint) -> Void)?   // global CG coords (top-left origin), main thread
    var onEnd: (() -> Void)?            // main thread
    var onCancel: (() -> Void)?         // Esc while active, main thread
    var onCaptureRejected: ((String) -> Void)?  // capture picked a key that would break normal typing, main thread
    private(set) var active = false
    /// systemUptime of the last real (non-synthetic) keyDown or mouse press, excluding the hotkey and Esc-cancel.
    private(set) var lastUserInput: TimeInterval = 0
    var hotkey: Hotkey = .rightOption
    var forceClickEnabled = true
    var handsFreeEnabled = true
    var onLocked: (() -> Void)?         // hands-free locked by a second press, main thread
    var onDiscard: (() -> Void)?        // lone quick tap discarded silently (no onEnd), main thread

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var beginTime: TimeInterval = 0
    private var toggleMode = false      // quick force click => hands-free until next force click
    private var deepDown = false        // last pressure stage was >= 2 (for edge detection)
    private var lastEnd: TimeInterval = -1e9
    private var autoEnd: DispatchWorkItem?
    private var keyHold = false         // session started by the hotkey; ends on its release only
    private var captureDone: ((Hotkey?) -> Void)?
    private var captureTimeout: DispatchWorkItem?
    private var hotkeyDownState = false             // hotkey physically down (ignores autorepeat / duplicate flagsChanged)
    private var handsFreeTimer: DispatchWorkItem?   // quick release: waiting for a second press
    private var locked = false                      // hands-free: recording until the next hotkey press
    private var ignoreRelease = false               // release of the press that locked the session

    private static let quickClick: TimeInterval = 0.35
    private static let debounce: TimeInterval = 0.4
    private static let maxDuration: TimeInterval = 120
    private static let chordWindow: TimeInterval = 0.4  // other key within this after a modifier press = normal shortcut
    private static let handsFreeQuick: TimeInterval = 0.30   // hotkey release sooner than this = candidate hands-free tap
    private static let handsFreeWindow: TimeInterval = 0.35  // time to wait for a second press
    private static let lockedMaxDuration: TimeInterval = 600 // hands-free session cap

    /// Returns false if the event tap cannot be created (usually missing Input Monitoring / Accessibility permission).
    func start() -> Bool {
        if tap != nil { return true }
        // Raw type 34 = NSEvent.EventType.pressure; CGEventType has no case for it.
        let mask: CGEventMask = (CGEventMask(1) << 34)
            | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                return Unmanaged<TrackpadTrigger>.fromOpaque(info)
                    .takeUnretainedValue()
                    .handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        tap = t
        source = src
        return true
    }

    /// Capture the next key (modifier press or key down) for a settings UI. Esc or 10 s timeout reports nil.
    func captureNext(_ done: @escaping (Hotkey?) -> Void) {
        guard captureDone == nil else { DispatchQueue.main.async { done(nil) }; return }
        captureDone = done
        let item = DispatchWorkItem { [weak self] in self?.endCapture(nil) }
        captureTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: item)
    }

    private func endCapture(_ h: Hotkey?) {
        guard let done = captureDone else { return }
        captureDone = nil
        captureTimeout?.cancel()
        captureTimeout = nil
        DispatchQueue.main.async { done(h) }
    }

    private static let rejectedCaptureKeys: Set<Int64> = [36, 48, 49, 51, 117, 123, 124, 125, 126]  // Return, Tab, Space, Delete, fwd Delete, arrows
    private static let captureRejectReason = "这个键会影响正常打字，请换一个（推荐右 Option / F 键）"

    /// A captured keyDown is rejected if swallowing it would break normal typing: listed keys, or any printable character.
    /// Function keys (private-use range U+F700–U+F8FF) stay allowed.
    private static func isCaptureRejected(_ k: Int64, _ event: CGEvent) -> Bool {
        if rejectedCaptureKeys.contains(k) { return true }
        guard let chars = NSEvent(cgEvent: event)?.charactersIgnoringModifiers,
              let first = chars.unicodeScalars.first else { return false }
        return !(0xF700...0xF8FF).contains(first.value)
    }

    private static func modifierFlag(_ k: Int64) -> CGEventFlags? {
        switch k {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 63: return .maskSecondaryFn
        case 57: return .maskAlphaShift
        default: return nil
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            hotkeyDownState = false
            finish(cancel: false)  // the key release may have been lost while the tap was disabled
            return pass
        }
        trackUserInput(type, event)  // observe-only; never swallows
        if captureDone != nil {  // capture mode: only a key/modifier press counts; nothing starts recording
            guard type == .keyDown || type == .flagsChanged else { return pass }
            let k = event.getIntegerValueField(.keyboardEventKeycode)
            if type == .keyDown {
                if k == 53 { endCapture(nil); return nil }
                if Self.isCaptureRejected(k, event) {  // keep capturing; let the key through so typing works
                    DispatchQueue.main.async { [weak self] in self?.onCaptureRejected?(Self.captureRejectReason) }
                    return pass
                }
                endCapture(Hotkey(keycode: k, modifier: false, label: Hotkey.label(for: k)))
                return nil
            }
            guard Hotkey.isModifierKeycode(k), let f = Self.modifierFlag(k), event.flags.contains(f) else { return pass }
            endCapture(Hotkey(keycode: k, modifier: true, label: Hotkey.label(for: k)))
            return nil
        }
        let now = ProcessInfo.processInfo.systemUptime
        if type == .keyDown {
            let k = event.getIntegerValueField(.keyboardEventKeycode)
            if active && k == 53 {  // Esc cancels
                finish(cancel: true)
                return nil
            }
            if !hotkey.modifier && k == hotkey.keycode {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 && !hotkeyDownState {
                    hotkeyDownState = true
                    hotkeyPress(at: CGEvent(source: nil)?.location ?? event.location, now)
                }
                return nil  // swallow hotkey down (autorepeat is a no-op)
            }
            if active && keyHold && hotkey.modifier && now - beginTime < Self.chordWindow {
                finish(cancel: true)  // Option+letter etc.: a normal shortcut, not push-to-talk
            }
            return pass
        }
        if type == .keyUp {
            if !hotkey.modifier && event.getIntegerValueField(.keyboardEventKeycode) == hotkey.keycode {
                hotkeyUp(now)
                return nil
            }
            return pass
        }
        if type == .flagsChanged {  // modifier hotkey: hold to talk at the mouse position; never swallowed
            let k = event.getIntegerValueField(.keyboardEventKeycode)
            guard hotkey.modifier, k == hotkey.keycode, let f = Self.modifierFlag(k) else { return pass }
            if k == 57 {  // Caps Lock: each flagsChanged toggles start/stop
                if active && keyHold {
                    finish(cancel: false)
                } else if !active && now - lastEnd >= Self.debounce {
                    keyHold = true
                    begin(at: CGEvent(source: nil)?.location ?? event.location, now)
                }
            } else if event.flags.contains(f) {
                if !hotkeyDownState {
                    hotkeyDownState = true
                    hotkeyPress(at: CGEvent(source: nil)?.location ?? event.location, now)
                }
            } else if hotkeyDownState {
                hotkeyUp(now)
            }
            return pass
        }
        if type == .leftMouseUp {  // never swallowed; only drives hold-mode release
            if active && !toggleMode && !keyHold { releaseHold(now) }
            return pass
        }
        if type == .leftMouseDown || type == .rightMouseDown { return pass }

        // Pressure event (raw 34)
        guard forceClickEnabled, let ns = NSEvent(cgEvent: event) else { return pass }
        let deep = ns.stage >= 2
        let edge = deep && !deepDown
        deepDown = deep
        if !active {
            if edge && now - lastEnd >= Self.debounce { begin(at: event.location, now) }
        } else if edge && toggleMode {
            finish(cancel: false)
        } else if ns.stage == 0 && !toggleMode && !keyHold {
            releaseHold(now)
        }
        // Swallow deep-press pressure so the system Look Up / Quick Look does not fire.
        return deep ? nil : pass
    }

    /// True if the user typed or clicked after `t` (systemUptime basis).
    func userInputSince(_ t: TimeInterval) -> Bool { lastUserInput > t }

    /// Records real user keyDown / modifier / mouse-down events. Excludes our own synthetic events,
    /// the configured hotkey itself, and Esc while a session is active. Never changes the event's fate.
    private func trackUserInput(_ type: CGEventType, _ event: CGEvent) {
        guard type == .keyDown || type == .flagsChanged
            || type == .leftMouseDown || type == .rightMouseDown else { return }
        guard event.getIntegerValueField(.eventSourceUserData) != zhiyuSyntheticTag else { return }
        if type == .keyDown || type == .flagsChanged {
            let k = event.getIntegerValueField(.keyboardEventKeycode)
            if hotkey.keycode == k && (type == .flagsChanged ? hotkey.modifier : !hotkey.modifier) { return }
            if type == .keyDown && active && k == 53 { return }  // Esc cancel
        }
        lastUserInput = ProcessInfo.processInfo.systemUptime
    }

    private func begin(at point: CGPoint, _ now: TimeInterval) {
        active = true
        toggleMode = false
        beginTime = now
        ignoreRelease = false
        locked = false
        armAutoEnd(Self.maxDuration)
        DispatchQueue.main.async { [weak self] in self?.onBegin?(point) }
    }

    private func armAutoEnd(_ seconds: TimeInterval) {
        autoEnd?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.finish(cancel: false) }
        autoEnd = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// Hotkey press. Hands-free: a second press inside the wait window locks the session;
    /// in locked mode the next press ends it.
    private func hotkeyPress(at point: CGPoint, _ now: TimeInterval) {
        if active {
            guard keyHold else { return }  // force-click session: hotkey does nothing
            if handsFreeTimer != nil {
                handsFreeTimer?.cancel()
                handsFreeTimer = nil
                locked = true
                ignoreRelease = true
                armAutoEnd(Self.lockedMaxDuration)
                DispatchQueue.main.async { [weak self] in self?.onLocked?() }
            } else if locked {
                finish(cancel: false)
            }
            return
        }
        if now - lastEnd >= Self.debounce {
            keyHold = true
            begin(at: point, now)
        }
    }

    /// Hotkey release. Quick release (< 0.30 s) with hands-free on waits for a second press instead of ending.
    private func hotkeyUp(_ now: TimeInterval) {
        hotkeyDownState = false
        if ignoreRelease {
            ignoreRelease = false
            return
        }
        guard active, keyHold, !locked, handsFreeTimer == nil else { return }
        if handsFreeEnabled && now - beginTime < Self.handsFreeQuick {
            let item = DispatchWorkItem { [weak self] in self?.discardWait() }
            handsFreeTimer = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.handsFreeWindow, execute: item)
        } else {
            finish(cancel: false)
        }
    }

    /// No second press within the window: the lone quick tap is discarded silently.
    private func discardWait() {
        guard active, !locked, handsFreeTimer != nil else { return }
        finish(cancel: false, discard: true)
    }

    /// Release in hold mode: a quick click (< 0.35 s) switches to toggle mode instead of ending.
    private func releaseHold(_ now: TimeInterval) {
        if now - beginTime < Self.quickClick {
            toggleMode = true
        } else {
            finish(cancel: false)
        }
    }

    private func finish(cancel: Bool, discard: Bool = false) {
        guard active else { return }
        active = false
        toggleMode = false
        keyHold = false
        locked = false
        ignoreRelease = false
        handsFreeTimer?.cancel()
        handsFreeTimer = nil
        lastEnd = ProcessInfo.processInfo.systemUptime
        autoEnd?.cancel()
        autoEnd = nil
        DispatchQueue.main.async { [weak self] in
            if cancel { self?.onCancel?() } else if discard { self?.onDiscard?() } else { self?.onEnd?() }
        }
    }
}
