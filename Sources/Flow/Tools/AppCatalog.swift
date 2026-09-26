import AppKit

/// One thing Flow can do in an app: hand-written for the apps people use most (curated), or discovered
/// on this Mac (AppleScript commands, menu bar items, Shortcuts).
struct AppAction {
    enum Source: String { case curated, script, menu, shortcut }

    let id: String
    let app: String
    let bundleId: String?
    let title: String
    var hint = ""
    /// Arguments the model fills from what the user said: (name, what it means).
    var args: [(name: String, about: String)] = []
    var risk = ToolRisk.reversible
    let source: Source
    let perform: (Args, ToolContext) async throws -> AppResult

    var searchText: String { "\(app): \(title). \(hint)" }
}

struct AppResult {
    var message: String
    var detail = ""
    var style = CardStyle.success
}

/// Everything Flow can do in apps, and the search that narrows it to a few candidates per request.
final class AppCatalog {
    static let shared = AppCatalog()

    private let lock = NSLock()
    private var discovered: [AppAction] = []
    private var discoveredAt = Date.distantPast
    private var menus: [String: (at: Date, actions: [AppAction])] = [:]
    private var vectors: [String: [Float]] = [:]

    // MARK: Discovery

    /// Scans installed apps' AppleScript dictionaries and the user's Shortcuts, then embeds anything new.
    func refresh() async {
        let curatedBundles = Set(CuratedApps.all.compactMap(\.bundleId))
        var found = ScriptingDictionary.actions(skipping: curatedBundles)
        found += await ShortcutsRunner.list().map(Self.shortcutAction)
        lock.withLock { discovered = found; discoveredAt = Date() }
        await embedMissing(CuratedApps.all + found)
        flowLog("app catalog: \(CuratedApps.all.count) curated, \(found.count) discovered")
    }

    private func refreshIfStale() {
        let stale = lock.withLock { Date().timeIntervalSince(discoveredAt) > 600 }
        if stale {
            lock.withLock { discoveredAt = Date() }
            Task.detached(priority: .utility) { await self.refresh() }
        }
    }

    var all: [AppAction] { CuratedApps.all + lock.withLock { discovered } }

    static func shortcutAction(_ name: String) -> AppAction {
        AppAction(id: "shortcut:\(name)", app: "Shortcuts", bundleId: nil, title: "Run the “\(name)” shortcut",
                  hint: name, args: [("input", "text to give the shortcut, or \"\"")], risk: riskOf(name), source: .shortcut) { a, _ in
            let out = try await ShortcutsRunner.run(name, input: a.string("input"))
            return AppResult(message: "Ran “\(name)”", detail: String(out.prefix(300)), style: out.isEmpty ? .success : .answer)
        }
    }

    /// Menu bar items of a running app, cached for a few minutes.
    func menuActions(for app: NSRunningApplication) async -> [AppAction] {
        guard let bundle = app.bundleIdentifier, AXIsProcessTrusted() else { return [] }
        if let cached = lock.withLock({ menus[bundle] }), Date().timeIntervalSince(cached.at) < 300 { return cached.actions }
        let name = app.localizedName ?? bundle
        let target = TargetApp(name: name, bundleId: bundle)
        let actions = Menus.items(of: app.processIdentifier).map { item in
            AppAction(id: "menu:\(bundle):\(item.label)", app: name, bundleId: bundle,
                      title: "Menu \(item.label)" + (item.shortcut.isEmpty ? "" : " (\(item.shortcut))"),
                      risk: Self.riskOf(item.label), source: .menu) { _, _ in
                let running = try await target.activate()
                try Menus.press(item.path, in: running)
                return AppResult(message: "\(item.path.last ?? "Done") in \(name)")
            }
        }
        lock.withLock { menus[bundle] = (Date(), actions) }
        await embedMissing(actions)
        return actions
    }

    /// Reads the front app's menus while the user is still talking, so the lookup is instant when they finish.
    func prefetch(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let pid = app.processIdentifier
        Task.detached(priority: .utility) {
            if let app = NSRunningApplication(processIdentifier: pid) { _ = await self.menuActions(for: app) }
        }
    }

    // MARK: Search

    /// Resolves the named app ("" = none named) and returns the best-matching actions for the request.
    func candidates(for request: String, app spoken: String, frontmost: NSRunningApplication?,
                    limit: Int = 8) async -> (target: TargetApp?, actions: [AppAction]) {
        refreshIfStale()
        let target = Self.resolveApp(spoken)
        var pool: [AppAction]
        var preferred = frontmost?.bundleIdentifier
        if let target {
            preferred = target.bundleId
            pool = all.filter { $0.bundleId == target.bundleId }
            if target.bundleId == "com.apple.shortcuts" || request.matches(#"\bshortcuts?\b"#) {
                pool += all.filter { $0.source == .shortcut }
            }
            var running = target.running
            // An app Flow has no commands for: open it so its menus can be read.
            if pool.isEmpty, running == nil, !DryRun.active { running = try? await target.activate() }
            if let running { pool += await menuActions(for: running) }
        } else {
            // Nothing named: don't launch an app the user isn't using just to run one of its commands.
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            pool = all.filter { $0.source != .script || running.contains($0.bundleId ?? "") }
            if let frontmost, frontmost.bundleIdentifier != Bundle.main.bundleIdentifier { pool += await menuActions(for: frontmost) }
        }
        return (target, await rank(pool, request: request, preferred: preferred, limit: limit))
    }

    private func rank(_ pool: [AppAction], request: String, preferred: String?, limit: Int) async -> [AppAction] {
        let q = try? await Embedder.embed("query: " + request)
        let cached = lock.withLock { vectors }
        let words = Self.words(request)
        let scored = pool.map { a -> (AppAction, Double) in
            var s = 0.0
            if let q, let v = cached[a.searchText] { s += Double(Embedder.cosine(q, v)) }
            s += 0.08 * Double(min(3, words.intersection(Self.words(a.searchText)).count))
            if a.source == .curated { s += 0.05 }
            if let preferred, a.bundleId == preferred { s += 0.08 }
            return (a, s)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    private func embedMissing(_ actions: [AppAction]) async {
        let have = lock.withLock { Set(vectors.keys) }
        var missing = Array(Set(actions.map(\.searchText)).subtracting(have))
        // Vectors already stored from an earlier run.
        let stored = Store.shared.catalogVectors(missing)
        lock.withLock { vectors.merge(stored) { a, _ in a } }
        missing.removeAll { stored[$0] != nil }
        for batch in stride(from: 0, to: missing.count, by: 32).map({ Array(missing[$0..<min($0 + 32, missing.count)]) }) {
            guard let vs = try? await Embedder.embedBatch(batch.map { "document: " + $0 }) else { return }
            let pairs = Dictionary(uniqueKeysWithValues: zip(batch, vs))
            lock.withLock { vectors.merge(pairs) { a, _ in a } }
            Store.shared.setCatalogVectors(pairs)
        }
    }

    // MARK: Helpers

    /// "Chrome" → Google Chrome, "the browser" → Google Chrome, "Figma" → Figma.app. nil when no app was named.
    static func resolveApp(_ spoken: String) -> TargetApp? {
        let n = normalize(spoken)
        guard !n.isEmpty, !["this", "thisapp", "here", "current", "currentapp", "it", "app"].contains(n) else { return nil }
        if let c = CuratedApps.apps.first(where: { app in ([app.name] + app.aliases).contains { normalize($0) == n } }) {
            return c.target
        }
        if n == "shortcuts" || n == "shortcut" { return TargetApp(name: "Shortcuts", bundleId: "com.apple.shortcuts") }
        // Only a close match: a loose one would launch an app the user never named.
        guard let url = OpenAppTool.findApp(spoken), let bundle = Bundle(url: url)?.bundleIdentifier else { return nil }
        let found = normalize(url.deletingPathExtension().lastPathComponent)
        guard found == n || (n.count >= 4 && (found.hasPrefix(n) || n.hasPrefix(found))) else { return nil }
        return TargetApp(name: url.deletingPathExtension().lastPathComponent, bundleId: bundle)
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "the ", with: "").replacingOccurrences(of: " app", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    private static let stopwords: Set<String> = ["the", "a", "an", "to", "in", "on", "of", "my", "me", "and", "for", "it", "this",
                                                 "that", "please", "can", "you", "i", "with", "some", "menu", "or", "by", "is"]

    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 && !stopwords.contains($0) })
    }

    /// Commands that delete, send, quit or sign out ask first.
    static func riskOf(_ label: String) -> ToolRisk {
        label.matches(#"\b(delete|remove|erase|empty|trash|send|quit|close all|log ?out|sign ?out|restart|shut ?down|uninstall|reset|discard|revert|clear|purchase|buy|pay|submit|publish|post)\b"#)
            ? .outward : .reversible
    }
}

/// Parameterless commands from installed apps' AppleScript dictionaries (Music's "playpause", Mail's "check for new mail"…).
enum ScriptingDictionary {
    private static let generic: Set<String> = ["quit", "open", "close", "print", "save", "delete", "make", "duplicate", "move", "count",
                                               "exists", "run", "reopen", "activate", "set", "get", "launch", "open location", "select"]
    private static let genericSuites: Set<String> = ["Standard Suite", "Text Suite", "Type Definitions", "Type Names Suite"]

    static func actions(skipping: Set<String>) -> [AppAction] {
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    NSHomeDirectory() + "/Applications"]
        var out: [AppAction] = []
        for dir in dirs {
            for item in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where item.hasSuffix(".app") {
                guard let bundle = Bundle(path: "\(dir)/\(item)"), let id = bundle.bundleIdentifier, !skipping.contains(id),
                      let sdefName = bundle.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String,
                      let url = bundle.url(forResource: sdefName, withExtension: nil) ?? bundle.resourceURL?.appendingPathComponent(sdefName),
                      let doc = try? XMLDocument(contentsOf: url, options: []) else { continue }
                let name = String(item.dropLast(4))
                let target = TargetApp(name: name, bundleId: id)
                for suite in (try? doc.nodes(forXPath: "//suite")) ?? [] {
                    guard let suite = suite as? XMLElement, !genericSuites.contains(suite.attribute(forName: "name")?.stringValue ?? "") else { continue }
                    for cmd in suite.elements(forName: "command") {
                        guard let command = cmd.attribute(forName: "name")?.stringValue, !generic.contains(command),
                              // Script runners and plug-in hooks, not user-facing commands.
                              !command.matches(#"\b(script|javascript|execute|property|handler|event|browse)\b"#),
                              cmd.attribute(forName: "hidden")?.stringValue != "yes", isParameterless(cmd) else { continue }
                        let about = cmd.attribute(forName: "description")?.stringValue ?? ""
                        out.append(AppAction(id: "script:\(id):\(command)", app: name, bundleId: id, title: command.capitalizedFirst,
                                             hint: about, risk: AppCatalog.riskOf(command), source: .script) { _, _ in
                            try await Script.tell(target, command)
                            return AppResult(message: "\(command.capitalizedFirst) in \(name)")
                        })
                    }
                }
            }
        }
        return out
    }

    private static func isParameterless(_ cmd: XMLElement) -> Bool {
        let required = (cmd.elements(forName: "direct-parameter") + cmd.elements(forName: "parameter"))
            .filter { $0.attribute(forName: "optional")?.stringValue != "yes" }
        return required.isEmpty
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
