import AppKit
import ApplicationServices

struct OpenAppTool: FlowTool {
    let name = "open_app"
    let title = "Open apps & sites"
    let summary = "Opens applications on this Mac, or websites by name."
    let symbol = "macwindow"
    let risk = ToolRisk.reversible
    let permissions: [SystemPermission] = []
    let defaultPolicy = ToolPolicy.always
    let args: [(String, OJ)] = [("name", .str)]

    func describe(_ a: Args) -> String { "Open \(a.string("name"))" }

    func run(_ a: Args, _ ctx: ToolContext) async throws -> ToolOutcome {
        let name = a.string("name")
        guard !name.isEmpty else { throw ToolError("Which app should I open?") }

        if DryRun.active { return ToolOutcome(message: "[dry run] would open \(name)") }
        if let app = Self.findApp(name) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: config)
            let appName = app.deletingPathExtension().lastPathComponent
            let e = ctx.log(.action, title: "Opened \(appName)", meta: ["tool": name])
            return ToolOutcome(message: "Opened \(appName)", entry: e)
        }
        // Looks like a website ("gmail", "nytimes.com").
        let host = name.lowercased().replacingOccurrences(of: " ", with: "")
        let url = URL(string: host.contains(".") ? "https://\(host)" : "https://\(host).com")!
        NSWorkspace.shared.open(url)
        let e = ctx.log(.action, title: "Opened \(url.host ?? name)", meta: ["url": url.absoluteString])
        return ToolOutcome(message: "Opened \(url.host ?? name)", entry: e)
    }

    static func findApp(_ spoken: String) -> URL? {
        let target = normalize(spoken)
        let aliases = ["vscode": "visualstudiocode", "code": "visualstudiocode", "chrome": "googlechrome",
                       "settings": "systemsettings", "calendarapp": "calendar", "mycalendar": "calendar", "word": "microsoftword",
                       "excel": "microsoftexcel", "powerpoint": "microsoftpowerpoint", "teams": "microsoftteams"]
        let wanted = aliases[target] ?? target
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    NSHomeDirectory() + "/Applications"]
        var best: (URL, Int)?
        for dir in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let n = normalize(String(item.dropLast(4)))
                let url = URL(fileURLWithPath: dir).appendingPathComponent(item)
                if n == wanted { return url }
                let score = n.hasPrefix(wanted) ? 2 : (n.contains(wanted) || wanted.contains(n) && n.count > 3 ? 1 : 0)
                if score > (best?.1 ?? 0) { best = (url, score) }
            }
        }
        return best?.0
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "the ", with: "").replacingOccurrences(of: " app", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
}

struct PasteTextTool: FlowTool {
    let name = "paste_text"
    let title = "Type into apps"
    let summary = "Pastes your dictation or requested text into the field you were typing in."
    let symbol = "text.cursor"
    let risk = ToolRisk.reversible
    let permissions: [SystemPermission] = [.accessibility]
    let defaultPolicy = ToolPolicy.always
    let args: [(String, OJ)] = [("text", .str)]

    func describe(_ a: Args) -> String { "Type “\(a.string("text").prefix(80))”" }

    func run(_ a: Args, _ ctx: ToolContext) async throws -> ToolOutcome {
        let text = a.string("text")
        guard !text.isEmpty else { throw ToolError("Nothing to type") }
        await Keyboard.paste(text, into: ctx.focus)
        let kind: EntryKind = ctx.intent == "dictation" ? .dictation : .action
        let where_ = ctx.focus?.appName ?? "the current app"
        let e = ctx.log(kind, title: kind == .dictation ? String(text.prefix(80)) : "Typed into \(where_)", body: text,
                        meta: ["app": where_])
        return ToolOutcome(message: kind == .dictation ? "Dictated into \(where_)" : "Pasted into \(where_)",
                           detail: String(text.prefix(140)), entry: e, holdSeconds: 2)
    }
}

enum Keyboard {
    /// ⌘A in the focused field (used to replace text Flow just wrote).
    @MainActor
    static func selectAll(in focus: FocusContext?) async {
        if DryRun.active { flowLog("[dry run] would select all"); return }
        if let app = focus?.app, app != NSWorkspace.shared.frontmostApplication {
            app.activate()
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    /// Pastes via the clipboard (fast, works everywhere), then restores the user's clipboard.
    @MainActor
    static func paste(_ text: String, into focus: FocusContext?) async {
        // Tests (CLI) must never type into whatever app the user is using.
        if DryRun.active { flowLog("[dry run] would paste: \(text)"); return }
        if let app = focus?.app, app != NSWorkspace.shared.frontmostApplication {
            app.activate()
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        } ?? []
        pb.clearContents()
        pb.setString(text, forType: .string)

        let src = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        try? await Task.sleep(nanoseconds: 400_000_000)
        pb.clearContents()
        let items = saved.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, d) in dict { item.setData(d, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}

struct ClickElementTool: FlowTool {
    let name = "click_element"
    let title = "Press buttons"
    let summary = "Finds a button in the app you're using by its name and presses it."
    let symbol = "cursorarrow.click.2"
    let risk = ToolRisk.outward
    let permissions: [SystemPermission] = [.accessibility]
    let defaultPolicy = ToolPolicy.ask
    let args: [(String, OJ)] = [("label", .str)]

    func describe(_ a: Args) -> String { "Press “\(a.string("label"))” in \(currentApp)" }
    private var currentApp: String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "the current app" }

    func run(_ a: Args, _ ctx: ToolContext) async throws -> ToolOutcome {
        let label = a.string("label")
        if DryRun.active { return ToolOutcome(message: "[dry run] would press \(label)") }
        guard let app = ctx.focus?.app ?? NSWorkspace.shared.frontmostApplication else { throw ToolError("No app in front") }
        guard let el = AX.findPressable(in: app.processIdentifier, label: label) else {
            throw ToolError("Couldn't find “\(label)” in \(app.localizedName ?? "this app")")
        }
        app.activate()
        let result = AXUIElementPerformAction(el, kAXPressAction as CFString)
        guard result == .success else { throw ToolError("\(app.localizedName ?? "The app") didn't accept the click") }
        let e = ctx.log(.action, title: "Pressed “\(label)” in \(app.localizedName ?? "app")")
        return ToolOutcome(message: "Pressed \(label)", entry: e)
    }
}

struct DraftMessageTool: FlowTool {
    let name = "draft_message"
    let title = "Draft messages"
    let summary = "Writes email drafts (recaps, follow-ups) in your mail app. Flow never hits send."
    let symbol = "envelope"
    let risk = ToolRisk.reversible
    let permissions: [SystemPermission] = []
    let defaultPolicy = ToolPolicy.always
    let args: [(String, OJ)] = [("to", .str), ("subject", .str), ("body", .str), ("include_last_meeting", .bool)]

    func describe(_ a: Args) -> String { "Draft a message to \(a.string("to"))" }

    func run(_ a: Args, _ ctx: ToolContext) async throws -> ToolOutcome {
        let who = a.string("to")
        var subject = a.string("subject")
        var body = a.string("body")
        var meeting: Entry?
        if a.bool("include_last_meeting"), let m = Store.shared.lastMeeting() {
            meeting = m
            if subject.isEmpty { subject = "Recap: \(m.title)" }
        }

        // Resolve "Marcus" to an address from memory ("which Marcus").
        var address = who.contains("@") ? who : ""
        var resolvedFrom: String?
        if address.isEmpty, !who.isEmpty {
            for hit in await LocalMemory.shared.search("\(who) email address", limit: 8) {
                if let found = Self.firstEmail(in: hit.entry.searchText + " " + hit.entry.transcript, near: who) {
                    address = found; resolvedFrom = hit.entry.title; break
                }
            }
        }

        do {
            // Always write the full email; the router's quick body (if any) is just a hint.
            let request = body.isEmpty ? ctx.transcript : "\(ctx.transcript)\n(Key point: \(body))"
            let draft = await Self.compose(to: who, request: request, meeting: meeting, fallback: body)
            body = draft.body
            if subject.isEmpty { subject = draft.subject }
        }
        body = GeneratedText.clean(body)

        var c = URLComponents()
        c.scheme = "mailto"
        c.path = address
        c.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        guard let url = c.url else { throw ToolError("Couldn't build the draft") }
        if DryRun.active { flowLog("[dry run] would open draft: \(url.absoluteString.prefix(200))") } else { NSWorkspace.shared.open(url) }

        var meta = ["to": who, "address": address, "subject": subject]
        if let m = meeting { meta["meeting_id"] = m.id }
        let e = ctx.log(.action, title: "Drafted message to \(who.isEmpty ? "someone" : who)",
                        body: "Subject: \(subject)\n\n\(body)", meta: meta)
        let detail = address.isEmpty ? "No address on file for \(who); add it in the draft."
            : "To \(address)\(resolvedFrom.map { " (from “\($0)”)" } ?? "")"
        return ToolOutcome(message: "Draft ready in Mail", detail: detail, entry: e)
    }

    static func firstEmail(in text: String, near name: String) -> String? {
        let re = try! NSRegularExpression(pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: .caseInsensitive)
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        let first = name.lowercased().split(separator: " ").first.map(String.init) ?? name.lowercased()
        return matches.first { $0.lowercased().contains(first) } ?? (text.lowercased().contains(first) ? matches.first : nil)
    }

    /// Returns (subject, body). The schema keeps the model from answering in its tool-call syntax.
    static func compose(to: String, request: String, meeting: Entry?, fallback: String) async -> (subject: String, body: String) {
        var context = ""
        if let m = meeting {
            let commitments = Store.shared.children(of: m.id).filter { $0.status != .dismissed }.map { "- \($0.title)" }
            context = "Meeting: \(m.title) on \(m.startAt.formatted(date: .abbreviated, time: .shortened))\n\(m.body)\n"
                + (commitments.isEmpty ? "" : "My follow-ups:\n" + commitments.joined(separator: "\n"))
        }
        let system = Prompts.system(.email)
        let user = "Write an email to \(to.isEmpty ? "the recipient" : to).\nThe user said: \"\(request)\"\n\(context.isEmpty ? "" : "\nUse this context:\n\(context)")"
        if let (text, _) = try? await LLMClient.router.complete(prompt: ChatML.prompt(system: system, user: user),
                                                                schema: .props([("subject", .str), ("body", .str)]),
                                                                maxTokens: 450, temperature: 0.2),
           let obj = JSON.parse(text) {
            let body = GeneratedText.clean(obj["body"] as? String ?? "")
            if !body.isEmpty { return (GeneratedText.clean(obj["subject"] as? String ?? ""), body) }
        }
        return ("", fallback.isEmpty ? context : fallback)
    }
}

/// "Write an email here telling Kevin…" — Flow composes the text and types it into the focused field.
struct WriteTextTool: FlowTool {
    let name = "write_text"
    let title = "Write for you"
    let summary = "Composes an email, reply or message from your instructions and types it where your cursor is."
    let symbol = "square.and.pencil"
    let risk = ToolRisk.reversible
    let permissions: [SystemPermission] = [.accessibility]
    let defaultPolicy = ToolPolicy.always
    let args: [(String, OJ)] = [("instructions", .str)]

    func describe(_ a: Args) -> String { "Write: \(a.string("instructions"))" }

    func run(_ a: Args, _ ctx: ToolContext) async throws -> ToolOutcome {
        let instructions = a.string("instructions").isEmpty ? ctx.transcript : a.string("instructions")
        let app = ctx.focus?.appName ?? "the current app"
        var context = "It will be typed into \(app)"
        if let w = ctx.focus?.windowTitle, !w.isEmpty { context += " (window: “\(w)”)" }
        if let sel = ctx.focus?.selectedText, !sel.isEmpty { context += ".\nSelected text \(Prompts.name) may be replying to:\n\(sel.prefix(1500))" }
        let system = Prompts.system(.email) + """

        Now write exactly what \(Prompts.name) asks for, ready to paste. Output only the text itself — no subject line, no quotes, no notes.
        Match the medium: an email gets a greeting, a short body and a sign-off; a chat message is short and casual.
        Say only what they asked for; don't add details they didn't give.
        """
        let turns = ctx.history.suffix(6).map { (user: $0.user, assistant: JSON.string(["text": $0.assistant])) }
        guard let (out, _) = try? await LLMClient.router.complete(
                prompt: ChatML.prompt(system: system, turns: turns, user: "\(context).\n\n\(Prompts.name): \(instructions)"),
                schema: .props([("text", .str)]), maxTokens: 450, temperature: 0.2),
              let text = (JSON.parse(out)?["text"] as? String).map(GeneratedText.clean),
              !text.isEmpty else { throw ToolError("Couldn't write that") }
        var body = text
        if body.lowercased().hasPrefix("subject:"), let nl = body.firstIndex(of: "\n") {
            body = String(body[nl...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A revision ("also say thanks") of text Flow just wrote here replaces it instead of pasting a second copy.
        let revising = ctx.said != nil && ctx.said != ctx.transcript
            && (ctx.history.last?.assistant.hasPrefix("(Wrote in \(app)") ?? false)
        if revising { await Keyboard.selectAll(in: ctx.focus) }
        await Keyboard.paste(body, into: ctx.focus)
        let e = ctx.log(.action, title: "Wrote in \(app)", body: body, meta: ["app": app])
        return ToolOutcome(message: revising ? "Rewrote it in \(app)" : "Wrote it in \(app)", detail: String(body.prefix(160)), entry: e)
    }
}

/// Cleans model-written text before it's shown or typed.
enum GeneratedText {
    /// LFM2.5 sometimes answers in its native tool-call syntax even when asked for prose, e.g.
    /// `[write(email_body='Hi Kevin,\n\n…', subject='…')]`. Pull out the actual text and unescape it.
    static func clean(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "<|tool_call_start|>", with: "").replacingOccurrences(of: "<|tool_call_end|>", with: "")
        if t.hasPrefix("[") && t.contains("(") && t.contains("=") {
            for key in ["email_body", "body", "text", "content", "message", "answer"] {
                for quote in ["'", "\""] {
                    let pattern = "\\b\(key)\\s*=\\s*\(quote)((?:[^\(quote)\\\\]|\\\\.)*)\(quote)"
                    if let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                       let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                       let r = Range(m.range(at: 1), in: t) {
                        return unescape(String(t[r])).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }
        return t
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\'", with: "'").replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
