import AppKit
import CoreGraphics

/// A user-configurable push-to-talk shortcut: either a lone modifier (e.g. right ⌥) or a key combo (e.g. ⌃⌥Space).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64      // CGEventFlags raw value, masked to ⌘⌥⌃⇧fn
    var modifierOnly: Bool

    static let `default` = Shortcut(keyCode: 59, modifiers: 0, modifierOnly: true)   // left Control
    static let defaultDictation = Shortcut(keyCode: 61, modifiers: 0, modifierOnly: true)   // right Option

    static let relevantFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]

    static let modifierKeys: [UInt16: (flag: CGEventFlags, name: String)] = [
        54: (.maskCommand, "Right ⌘"), 55: (.maskCommand, "Left ⌘"),
        56: (.maskShift, "Left ⇧"), 60: (.maskShift, "Right ⇧"),
        58: (.maskAlternate, "Left ⌥"), 61: (.maskAlternate, "Right ⌥"),
        59: (.maskControl, "Left ⌃"), 62: (.maskControl, "Right ⌃"),
        63: (.maskSecondaryFn, "fn"),
    ]

    var displayString: String {
        if modifierOnly { return Self.modifierKeys[keyCode]?.name ?? "Key \(keyCode)" }
        let f = CGEventFlags(rawValue: modifiers)
        var s = ""
        if f.contains(.maskSecondaryFn) { s += "fn " }
        if f.contains(.maskControl) { s += "⌃" }
        if f.contains(.maskAlternate) { s += "⌥" }
        if f.contains(.maskShift) { s += "⇧" }
        if f.contains(.maskCommand) { s += "⌘" }
        return s + KeyNames.name(keyCode)
    }

    /// Shortcuts that would clash with common system or app behaviour.
    var warning: String? {
        let f = CGEventFlags(rawValue: modifiers)
        if !modifierOnly && f.intersection(Self.relevantFlags).isEmpty { return "A key without modifiers will stop working for typing." }
        if !modifierOnly && f == .maskCommand && [49, 12, 13, 8, 9, 7, 0, 1].contains(keyCode) { return "This is a common system shortcut." }
        if modifierOnly && keyCode == 63 { return "fn may also trigger macOS dictation or the emoji picker." }
        return nil
    }
}

enum KeyNames {
    static func name(_ code: UInt16) -> String {
        let map: [UInt16: String] = [
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 50: "`", 27: "-", 24: "=", 33: "[", 30: "]",
            42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/",
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
            45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
            29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        ]
        return map[code] ?? "Key \(code)"
    }
}

/// Global push-to-talk detection with a CGEventTap. Modifier-only shortcuts pass through untouched;
/// combo shortcuts are swallowed so they don't also type into the focused app.
/// Which push-to-talk action a hotkey triggers.
enum HotkeyBinding: String, CaseIterable {
    /// Talk to Flow: routed to tools (questions, reminders, actions…). Double-tap = meeting.
    case agent
    /// Wispr-style dictation: transcribe and paste into the focused field, no agent.
    case dictation
}

/// Global push-to-talk detection with a CGEventTap. Modifier-only shortcuts pass through untouched;
/// combo shortcuts are swallowed so they don't also type into the focused app.
final class HotkeyMonitor {
    static let shared = HotkeyMonitor()

    var onPress: ((HotkeyBinding) -> Void)?
    var onRelease: ((HotkeyBinding) -> Void)?
    var onCancel: ((HotkeyBinding) -> Void)?
    /// Paused while the shortcut recorder in Settings is listening.
    var paused = false

    private(set) var shortcuts: [HotkeyBinding: Shortcut] = [
        .agent: Settings.shared.shortcut,
        .dictation: Settings.shared.dictationShortcut,
    ]
    var shortcut: Shortcut { shortcuts[.agent]! }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// The binding whose key is currently held (only one at a time).
    private var down: HotkeyBinding?
    private var loggedFailure = false
    private var retryTimer: Timer?
    /// false when only Input Monitoring is granted: the tap can listen but not swallow combo keys.
    private(set) var canSwallow = true
    var isInstalled: Bool { tap != nil }
    /// Without Input Monitoring the tap still installs, but macOS only delivers keys typed into Flow itself.
    var isActive: Bool { tap != nil && CGPreflightListenEventAccess() }
    private var lastActive: Bool?

    func update(_ s: Shortcut, for binding: HotkeyBinding = .agent) { shortcuts[binding] = s; down = nil }

    func start() {
        // Registers Flow in System Settings → Input Monitoring (and shows the prompt the first time).
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reportStatus() }
        guard tap == nil else { return }
        if install() { return }
        // Permissions not granted yet: keep trying until the user allows Input Monitoring / Accessibility.
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            if self?.install() == true { t.invalidate() }
        }
    }

    private func install() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            return monitor.handle(type, event)
        }
        let info = Unmanaged.passUnretained(self).toOpaque()
        // An active tap (can swallow combo keys) needs Accessibility; a listen-only tap needs just Input Monitoring.
        var created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: info)
        canSwallow = created != nil
        if created == nil {
            created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                        eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: info)
        }
        guard let t = created else {
            if !loggedFailure {
                loggedFailure = true
                flowLog("hotkey tap not installed: grant Input Monitoring (and Accessibility) to this build of Flow")
            }
            return false
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        reportStatus()
        return true
    }

    private func reportStatus() {
        let active = isActive
        guard active != lastActive else { return }
        lastActive = active
        let keys = "talk \(shortcuts[.agent]!.displayString), dictate \(shortcuts[.dictation]!.displayString)"
        flowLog(active ? "hotkeys active everywhere (\(keys), \(canSwallow ? "active tap" : "listen-only"))"
                       : "hotkeys only work while Flow is in front: Input Monitoring not granted to this build")
        NotificationCenter.default.post(name: .flowHotkeyStatusChanged, object: nil)
    }

    private func cancelHeld() {
        if let b = down { down = nil; onCancel?(b) }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard !paused else { return pass }
        // ⌃-click / ⌥-click: the modifier is being used with the mouse, not for push-to-talk.
        if type == .leftMouseDown || type == .rightMouseDown { cancelHeld(); return pass }

        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection(Shortcut.relevantFlags)

        // Esc cancels an active recording.
        if type == .keyDown && code == 53 && down != nil { cancelHeld(); return nil }

        for binding in HotkeyBinding.allCases {
            guard let s = shortcuts[binding] else { continue }
            if s.modifierOnly {
                guard type == .flagsChanged, code == s.keyCode, let info = Shortcut.modifierKeys[code] else { continue }
                let pressed = flags.contains(info.flag)
                // Only a lone modifier counts (holding ⌥ with ⌘ is someone else's shortcut).
                if pressed && down == nil && flags.subtracting(info.flag).isEmpty { down = binding; onPress?(binding) }
                else if !pressed && down == binding { down = nil; onRelease?(binding) }
                return pass
            } else if code == s.keyCode {
                let wanted = CGEventFlags(rawValue: s.modifiers).intersection(Shortcut.relevantFlags)
                if type == .keyDown && flags == wanted {
                    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 && down == nil { down = binding; onPress?(binding) }
                    return canSwallow ? nil : pass
                }
                if type == .keyUp && down == binding {
                    down = nil; onRelease?(binding)
                    return canSwallow ? nil : pass
                }
            }
        }
        // Any other key while a lone modifier is held: it's being used to type (⌥-e → é), not push-to-talk.
        if type == .keyDown, let b = down, shortcuts[b]?.modifierOnly == true { cancelHeld() }
        return pass
    }
}

extension Notification.Name {
    static let flowHotkeyStatusChanged = Notification.Name("flowHotkeyStatusChanged")
}
