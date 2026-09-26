import AppKit
import ApplicationServices

/// The ways Flow can drive another app: AppleScript, keystrokes, menu items, media keys and Shortcuts.

/// A macOS app Flow can target, by bundle id.
struct TargetApp {
    let name: String
    let bundleId: String

    var running: NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first }
    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil }

    /// Launches the app if needed and brings it to the front, waiting until it can take keystrokes.
    @discardableResult
    func activate(timeout: TimeInterval = 8) async throws -> NSRunningApplication {
        if DryRun.active { throw ToolError("dry run") }
        if let app = running, app.isFinishedLaunching {
            if !app.isActive {
                app.activate()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            return app
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            throw ToolError("\(name) isn't installed")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !(app.isFinishedLaunching && app.isActive) {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        // Electron apps report "launched" before their first window can take input.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        return app
    }
}

enum AutomationError: LocalizedError {
    case notPermitted(String)
    var errorDescription: String? {
        switch self {
        case .notPermitted(let app): return "Flow isn't allowed to control \(app) yet"
        }
    }

    static func openAutomationSettings() {
        let modern = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation")!
        if !NSWorkspace.shared.open(modern) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
        }
    }
}

/// AppleScript through `osascript`. Values are passed as `argv`, never spliced into the source,
/// so nothing the user says can change what a script does.
enum Script {
    @discardableResult
    static func run(_ source: String, _ args: [String] = [], app: String = "the app", timeout: TimeInterval = 15) async throws -> String {
        if DryRun.active { flowLog("[dry run] would run AppleScript for \(app)"); return "" }
        let (status, stdout, stderr) = try await Subprocess.run("/usr/bin/osascript", ["-e", source, "--"] + args, timeout: timeout,
                                                                 timeoutMessage: "\(app) didn't respond")
        guard status == 0 else {
            if stderr.contains("-1743") { throw AutomationError.notPermitted(app) }
            let reason = stderr.replacingOccurrences(of: #"^.*execution error: "#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*\(-?\d+\)\s*$"#, with: "", options: .regularExpression)
            throw ToolError(reason.isEmpty ? "\(app) refused the command" : reason.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return stdout
    }

    /// `tell application id "<bundle>" to <command>`; the command text must be fixed, not user input.
    @discardableResult
    static func tell(_ app: TargetApp, _ command: String, _ args: [String] = []) async throws -> String {
        try await run("on run argv\ntell application id \"\(app.bundleId)\"\n\(command)\nend tell\nend run", args, app: app.name)
    }
}

/// Synthetic key presses ("cmd+shift+n", "return") sent to the frontmost app.
enum Keys {
    private static let codes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "tab": 48, "space": 49, "`": 50, "delete": 51, "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    static func press(_ combo: String) async {
        if DryRun.active { flowLog("[dry run] would press \(combo)"); return }
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for part in combo.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: key = codes[part]
            }
        }
        guard let key else { flowLog("unknown key combo \(combo)"); return }
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    /// Types text into whatever has focus (via the clipboard, which is restored afterwards).
    static func type(_ text: String) async {
        await Keyboard.paste(text, into: nil)
    }
}

/// The hardware play/pause, next and previous keys: control whatever is playing, in any app.
enum MediaKeys {
    static let playPause: Int32 = 16, next: Int32 = 17, previous: Int32 = 18

    static func press(_ key: Int32) {
        if DryRun.active { flowLog("[dry run] would press media key \(key)"); return }
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((key << 16) | ((down ? 0xa : 0xb) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                               context: nil, subtype: 8, data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

/// Every app's menu bar, read and pressed through the Accessibility API. Works for native and Electron apps alike.
enum Menus {
    struct Item {
        let path: [String]
        let shortcut: String
        var label: String { path.joined(separator: " › ") }
    }

    /// Menu titles that hold the user's content (history, bookmarks, open windows), not commands.
    private static let skippedMenus: Set<String> = ["History", "Bookmarks", "Window", "Help", "Profiles", "Tab", "Open Recent",
                                                    // Items macOS adds to every app's Edit menu.
                                                    "Start Dictation…", "Start Dictation", "Emoji & Symbols", "AutoFill", "Writing Tools",
                                                    "Speech", "Substitutions", "Transformations", "Spelling and Grammar"]

    static func items(of pid: pid_t, limit: Int = 500) -> [Item] {
        let app = AXUIElementCreateApplication(pid)
        guard let bar = AX.element(app, kAXMenuBarAttribute) else { return [] }
        var out: [Item] = []
        // The first menu is the Apple menu.
        for top in AX.children(bar).dropFirst() {
            guard let title = AX.string(top, kAXTitleAttribute), !title.isEmpty, !skippedMenus.contains(title) else { continue }
            for menu in AX.children(top) { walk(menu, path: [title], depth: 0, into: &out, limit: limit) }
            if out.count >= limit { break }
        }
        return out
    }

    private static func walk(_ menu: AXUIElement, path: [String], depth: Int, into out: inout [Item], limit: Int) {
        for item in AX.children(menu).prefix(60) {
            guard out.count < limit else { return }
            guard let title = AX.string(item, kAXTitleAttribute), !title.isEmpty, !skippedMenus.contains(title) else { continue }
            let submenu = AX.children(item).first { AX.string($0, kAXRoleAttribute) == kAXMenuRole }
            if let submenu, depth < 2 {
                walk(submenu, path: path + [title], depth: depth + 1, into: &out, limit: limit)
            } else if submenu == nil {
                out.append(Item(path: path + [title], shortcut: shortcut(item)))
            }
        }
    }

    private static func shortcut(_ item: AXUIElement) -> String {
        guard let char = AX.string(item, kAXMenuItemCmdCharAttribute), !char.isEmpty else { return "" }
        var mods: CFTypeRef?
        AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString, &mods)
        let m = (mods as? Int) ?? 0
        // Bit 0 shift, bit 1 option, bit 2 control, bit 3 = no command key.
        var s = ""
        if m & 4 != 0 { s += "⌃" }
        if m & 2 != 0 { s += "⌥" }
        if m & 1 != 0 { s += "⇧" }
        if m & 8 == 0 { s += "⌘" }
        return s + char
    }

    /// Presses the menu item at `path` ("File", "New Window"). Titles match case-insensitively.
    static func press(_ path: [String], in app: NSRunningApplication) throws {
        if DryRun.active { flowLog("[dry run] would choose \(path.joined(separator: " › "))"); return }
        guard let item = find(path, in: app.processIdentifier) else {
            throw ToolError("\(app.localizedName ?? "The app") has no “\(path.joined(separator: " › "))” menu item right now")
        }
        var enabled: CFTypeRef?
        AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &enabled)
        if (enabled as? Bool) == false { throw ToolError("“\(path.last ?? "")” isn't available right now") }
        guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            throw ToolError("\(app.localizedName ?? "The app") didn't respond to “\(path.last ?? "")”")
        }
    }

    /// The first menu item whose title matches one of `titles`, anywhere in the menu bar (for curated fallbacks).
    static func firstPath(in app: NSRunningApplication, titled titles: [String]) -> [String]? {
        let wanted = titles.map { $0.lowercased() }
        return items(of: app.processIdentifier, limit: 800).first { wanted.contains($0.path.last?.lowercased() ?? "") }?.path
    }

    private static func find(_ path: [String], in pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard var node = AX.element(app, kAXMenuBarAttribute) else { return nil }
        for (i, title) in path.enumerated() {
            // Menu bar items and menu items hold their children inside an AXMenu.
            let container = i == 0 ? node : (AX.children(node).first { AX.string($0, kAXRoleAttribute) == kAXMenuRole } ?? node)
            guard let next = AX.children(container).first(where: {
                AX.string($0, kAXTitleAttribute)?.caseInsensitiveCompare(title) == .orderedSame
            }) else { return nil }
            node = next
        }
        return node
    }
}

/// The user's Shortcuts, run through the `shortcuts` command-line tool.
enum ShortcutsRunner {
    static func list() async -> [String] {
        guard let (status, stdout, _) = try? await Subprocess.run("/usr/bin/shortcuts", ["list"], timeout: 15), status == 0 else { return [] }
        return stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    static func run(_ name: String, input: String) async throws -> String {
        if DryRun.active { flowLog("[dry run] would run shortcut \(name)"); return "" }
        var args = ["run", name, "--output-path", "-"]
        var inputFile: URL?
        if !input.isEmpty {
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("flow-shortcut-\(UUID().uuidString).txt")
            try input.write(to: f, atomically: true, encoding: .utf8)
            args += ["--input-path", f.path]
            inputFile = f
        }
        defer { if let inputFile { try? FileManager.default.removeItem(at: inputFile) } }
        let (status, stdout, stderr) = try await Subprocess.run("/usr/bin/shortcuts", args, timeout: 60,
                                                                 timeoutMessage: "“\(name)” is taking too long")
        guard status == 0 else { throw ToolError(stderr.isEmpty ? "“\(name)” failed" : stderr) }
        return stdout
    }
}

/// Runs a command-line tool without blocking, reading its output as it arrives (so large output can't stall it).
enum Subprocess {
    static func run(_ path: String, _ args: [String], timeout: TimeInterval,
                    timeoutMessage: String = "Timed out") async throws -> (status: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let readOut = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }
        let readErr = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() > deadline { p.terminate(); throw ToolError(timeoutMessage) }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        func text(_ d: Data) -> String { (String(data: d, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        return (p.terminationStatus, text(await readOut.value), text(await readErr.value))
    }
}
