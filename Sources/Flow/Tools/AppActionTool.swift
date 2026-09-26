import AppKit

/// "Play Daft Punk on Spotify", "new note called groceries", "toggle the sidebar": does something inside an app.
/// Two steps: the catalog search narrows every action Flow knows to a handful, then one constrained
/// model call picks one of them and fills in its arguments.
struct AppActionTool: FlowTool {
    let name = "app_action"
    let title = "Control apps"
    let summary = "Does things inside your apps: plays music, makes notes, drives Chrome, Notion, Claude and Mail, runs menu commands and Shortcuts."
    let symbol = "wand.and.stars"
    let risk = ToolRisk.reversible
    let permissions: [SystemPermission] = [.accessibility]
    let defaultPolicy = ToolPolicy.always
    let args: [(String, OJ)] = [("app", .str), ("request", .str)]

    func describe(_ a: Args) -> String {
        a.string("app").isEmpty ? a.string("request") : "\(a.string("request")) in \(a.string("app"))"
    }

    func run(_ a: Args, _ ctx: ToolContext) async throws -> ToolOutcome {
        let request = ctx.transcript
        let frontmost = ctx.focus?.app ?? NSWorkspace.shared.frontmostApplication
        let (target, candidates) = await AppCatalog.shared.candidates(for: request, app: a.string("app"), frontmost: frontmost)
        guard let choice = await Self.pick(request, target: target, candidates: candidates,
                                           frontmost: ctx.focus?.appName ?? frontmost?.localizedName) else {
            let app = target?.name ?? a.string("app")
            let ideas = candidates.prefix(3).map { "· \($0.title)" }.joined(separator: "\n")
            throw ToolError((app.isEmpty ? "I don't know how to do that yet" : "I don't know how to do that in \(app) yet")
                            + (ideas.isEmpty ? "" : ". Things I can do:\n\(ideas)"))
        }
        let (action, args) = choice
        let described = Self.describe(action, args)
        flowLog("app action: \(action.id) \(JSON.string(args.raw))")

        if action.risk == .outward, !DryRun.active {
            let ok = await Overlay.shared.confirm(described, "This can't easily be undone.")
            if !ok { return ToolOutcome(message: "Cancelled", detail: described, style: .info, holdSeconds: 2) }
        }
        if DryRun.active {
            return ToolOutcome(message: "[dry run] \(action.id) \(JSON.string(args.raw))", detail: described)
        }

        let result: AppResult
        do {
            result = try await action.perform(args, ctx)
        } catch let AutomationError.notPermitted(app) {
            return ToolOutcome(message: "Flow needs permission to control \(app)",
                               detail: "Turn on \(app) under Flow in Privacy & Security → Automation.", style: .warning,
                               actions: [CardAction(title: "Open Settings", primary: true) { AutomationError.openAutomationSettings() }])
        }
        let e = ctx.log(.action, title: result.message, body: [described, result.detail].filter { !$0.isEmpty }.joined(separator: "\n"),
                        meta: ["app": action.app, "app_action": action.id, "args": JSON.string(args.raw)])
        return ToolOutcome(message: result.message, detail: result.detail, entry: e, style: result.style,
                           holdSeconds: result.style == .answer ? Settings.shared.answerSeconds + 3 : nil)
    }

    /// The model's choice, plus deterministic fixes for requests whose meaning is unambiguous.
    static func pick(_ request: String, target: TargetApp?, candidates: [AppAction], frontmost: String?) async -> (AppAction, Args)? {
        let choice = await choose(request, candidates: candidates, frontmost: frontmost)
        // "Play <something>" always means find it and play it, never resume, toggle or go back.
        // (play_search also looks in the user's library when they say "my".)
        if let query = playQuery(request), target == nil || target?.bundleId == SpotifyPlayer.app.bundleId,
           choice?.0.id != "spotify.play_search", let play = CuratedApps.all.first(where: { $0.id == "spotify.play_search" }) {
            return (play, Args(raw: ["query": query, "kind": ""]))
        }
        return choice
    }

    /// "Play only time" → "only time". nil for "play", "play the music", "play it again".
    static func playQuery(_ request: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"(?i)^\s*(?:please\s+)?(?:start\s+)?(?:play(?:ed|ing)?|put on|listen to)\s+(?:me\s+)?(?:a\s+song\s+|the\s+song\s+|some\s+)?(.+?)(?:\s+(?:on|in)\s+spotify)?[.!?]?\s*$"#),
              let m = re.firstMatch(in: request, range: NSRange(request.startIndex..., in: request)),
              let r = Range(m.range(at: 1), in: request) else { return nil }
        let q = String(request[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        let generic = #"^(it|this|that|music|the music|something|anything|again|it again|this again|(the )?(next|previous|last) (song|track)|next|previous|spotify)$"#
        return q.isEmpty || q.matches(generic) ? nil : q
    }

    static func describe(_ action: AppAction, _ args: Args) -> String {
        let filled = action.args.map { args.string($0.name) }.filter { !$0.isEmpty }
        return "\(action.app): \(action.title)" + (filled.isEmpty ? "" : " — " + filled.map { "“\($0)”" }.joined(separator: ", "))
    }

    /// One constrained completion: the schema only allows the listed actions (or "none") and each action's own arguments.
    static func choose(_ request: String, candidates: [AppAction], frontmost: String?) async -> (AppAction, Args)? {
        guard !candidates.isEmpty else { return nil }
        let list = candidates.enumerated().map { i, a in
            var line = "\(i + 1) · \(a.app): \(a.title)"
            if !a.hint.isEmpty, a.source != .shortcut { line += " (for: \(a.hint))" }
            if !a.args.isEmpty { line += ". Arguments: " + a.args.map { "\($0.name) (\($0.about))" }.joined(separator: ", ") }
            return line
        }.joined(separator: "\n") + "\n0 · None of these does what the user asked"
        let system = """
        You operate apps on the user's Mac. Pick the ONE action from the list that does what the user asked, \
        and fill in its arguments with their words. Keep names, titles and text exactly as they said them; \
        use "" for anything they didn't say. Pick 0 only if no action in the list does it.
        """
        let user = "Actions:\n\(list)\n\nFrontmost app: \(frontmost ?? "unknown")\nThe user said: \"\(request)\""
        let options = candidates.enumerated().map { i, a -> OJ in
            let args: OJ = a.args.isEmpty ? .object([("type", .string("object")), ("properties", .object([]))])
                : .props(a.args.map { ($0.name, .str) })
            return .props([("action", .enumeration([String(i + 1)])), ("args", args)])
        } + [.props([("action", .enumeration(["0"]))])]
        guard let (text, _) = try? await LLMClient.router.complete(prompt: ChatML.prompt(system: system, user: user),
                                                                   schema: .anyOf(options), maxTokens: 200),
              let obj = JSON.parse(text), let pick = obj["action"] as? String, let n = Int(pick),
              candidates.indices.contains(n - 1) else { return nil }
        let action = candidates[n - 1]
        var args = obj["args"] as? [String: Any] ?? [:]
        // Small models sometimes copy the argument's description instead of the user's words.
        for a in action.args {
            guard let v = (args[a.name] as? String)?.lowercased(), v.count > 3 else { continue }
            if a.about.lowercased() == v || (v.count >= 8 && a.about.lowercased().hasPrefix(v)) { args[a.name] = "" }
        }
        // "Run my Make GIF shortcut": the name isn't input for the shortcut.
        if action.source == .shortcut, let input = args["input"] as? String,
           AppCatalog.words(input).isSubset(of: AppCatalog.words(action.hint + " run shortcut")) {
            args["input"] = ""
        }
        return (action, Args(raw: args))
    }
}
