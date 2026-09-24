import Foundation

struct RoutedCall {
    let tool: String
    var args: [String: Any]
}

struct Route {
    var intent: String          // memory | question | action | reminder | meeting
    var kind: String            // the model's raw classification
    var calls: [RoutedCall]
    var latencyMs: Int
    var corrections: [String]   // harness rules that changed the model's answer
}

/// Turns a transcript into tool calls with one constrained LFM2.5-2.6B completion, then applies
/// deterministic harness corrections for the model's known failure modes.
final class Router {
    static let shared = Router()

    /// The model first labels the utterance; the schema then only allows that label's tools.
    static let kinds: [(name: String, intent: String, tools: [String])] = [
        ("asking_a_question", "question", ["answer_question"]),
        ("stating_a_fact_to_remember", "memory", ["memory_save", "update_memory", "delete_memory", "create_reminder"]),
        ("asking_to_be_reminded", "reminder", ["create_reminder", "update_reminder", "delete_reminder", "memory_save"]),
        ("command_for_the_computer", "action", ToolRegistry.all.map(\.name)),
        ("meeting_control", "meeting", ["start_meeting", "stop_meeting"]),
    ]

    lazy var schema: OJ = {
        func item(_ name: String) -> OJ {
            let tool = ToolRegistry.tool(name)!
            let args: OJ = tool.args.isEmpty ? .object([("type", .string("object")), ("properties", .object([]))]) : .props(tool.args)
            return .props([("tool", .enumeration([name])), ("args", args)])
        }
        return .anyOf(Self.kinds.map { k in
            .props([("kind", .enumeration([k.name])), ("calls", .array(.anyOf(k.tools.map(item)), min: 1, max: 3))])
        })
    }()

    /// Static prompt prefix (system + few-shot turns). It never changes, so llama-server keeps it cached.
    lazy var prefixTurns: [(user: String, assistant: String)] = RouterPrompt.examples.map { ex in
        (Self.userMessage(said: ex.said, app: ex.app, focused: ex.focused, selected: "",
                          now: Self.exampleDate), ex.output)
    }

    private static let exampleDate: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 22; c.hour = 14; c.minute = 5
        return Calendar.current.date(from: c) ?? Date()
    }()

    private static let nowFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE d MMMM yyyy, HH:mm"; return f
    }()

    static func userMessage(said: String, app: String, focused: Bool, selected: String, now: Date) -> String {
        var s = "Now: \(nowFormatter.string(from: now))\nFrontmost app: \(app)\nText field focused: \(focused ? "yes" : "no")\n"
        if !selected.isEmpty { s += "Selected text: \"\(selected.prefix(300))\"\n" }
        return s + "Said: \"\(said)\""
    }

    func prompt(transcript: String, focus: FocusContext?, now: Date) -> String {
        ChatML.prompt(system: Prompts.system(.router), turns: prefixTurns,
                      user: Self.userMessage(said: transcript, app: focus?.appName ?? "Finder",
                                             focused: focus?.isTextInput ?? false,
                                             selected: focus?.selectedText ?? "", now: now))
    }

    /// Fills the KV cache with the static prefix so the first real command is fast.
    func warmUp() async {
        _ = try? await LLMClient.router.complete(prompt: prompt(transcript: "Open Notes", focus: nil, now: Date()),
                                                 schema: schema, maxTokens: 1)
    }

    func route(_ transcript: String, focus: FocusContext?, now: Date = Date()) async throws -> Route {
        let t0 = Date()
        let (text, _) = try await LLMClient.router.complete(prompt: prompt(transcript: transcript, focus: focus, now: now),
                                                            schema: schema, maxTokens: 400)
        guard let obj = JSON.parse(text), let kind = obj["kind"] as? String,
              let rawCalls = obj["calls"] as? [[String: Any]] else {
            throw LLMError.badResponse("router returned: \(text)")
        }
        let calls = rawCalls.compactMap { c -> RoutedCall? in
            guard let t = c["tool"] as? String else { return nil }
            return RoutedCall(tool: t, args: c["args"] as? [String: Any] ?? [:])
        }
        var route = Route(intent: Self.kinds.first { $0.name == kind }?.intent ?? "action", kind: kind, calls: calls,
                          latencyMs: Int(Date().timeIntervalSince(t0) * 1000), corrections: [])
        Self.correct(&route, transcript: transcript, focused: focus?.isTextInput ?? false)
        return route
    }

    /// Fallback when the model is unavailable or returns garbage: never lose what the user said.
    static func fallback(_ transcript: String) -> Route {
        if transcript.matches(memoryCue) {
            return Route(intent: "memory", kind: "fallback",
                         calls: [RoutedCall(tool: "memory_save", args: ["title": titleFrom(transcript), "content": transcript])],
                         latencyMs: 0, corrections: ["fallback"])
        }
        return Route(intent: "question", kind: "fallback",
                     calls: [RoutedCall(tool: "answer_question", args: ["question": transcript, "use_memory": true,
                                                                        "use_files": false, "use_web": false])],
                     latencyMs: 0, corrections: ["fallback"])
    }

    // MARK: Harness corrections

    /// Explicit requests to insert words. The talk hotkey never pastes without one (dictation has its own hotkey).
    private static let pasteCue = #"\b(insert|paste|type|input|text ?box|(in|into) the (box|field|input|chat)|put (this|that|it)|add (this|that|the following))\b"#
    private static let remindCue = #"\b(remind me|don'?t let me forget|make sure i|i need to|i have to|i promised|i told \w+ i'?d)\b"#
    private static let questionStart = #"^\s*(find|where|what|who|when|how|did|do|does|is|are|which|why|can you find|show me)\b"#
    private static let commandStart = #"^\s*(open|launch|click|press|start|stop)\b"#
    private static let fileWords = #"\b(file|doc|docs|document|deck|pdf|folder|spreadsheet|slides|notes)\b"#

    private static let openCue = #"\b(open|launch|start|pull up|bring up|go to|switch to|fire up|show)\b"#
    private static let clickCue = #"\b(click|press|tap|hit|select|push)\b"#
    private static let draftCue = #"\b(send|email|e-mail|message|text|draft|write|reach out|reply|recap|follow up|ping)\b"#
    private static let draftStart = #"^\s*(please\s+)?(email|message|send|text|reach out|ping|draft|reply|write (an? )?(email|message|note) to)\b"#
    private static let writeCue = #"\b(write|compose|draft|reply|respond|help me (write|say|word))\b"#
    private static let hereCue = #"\b(here|this (email|message|field|box|thread|doc)|reply|respond)\b"#
    private static let questionLike = #"\?\s*$|\b(tell me|look up|search|check|find)\b"#
    private static let smallTalkCue = #"^\s*(hi|hey|hello|yo|hiya|thanks|thank you|good (morning|afternoon|evening|night)|how are you|how's it going|what's up|sup|test(ing)?)\b"#
    private static let keepCue = #"\b(remember|note|save|idea|remind)\b"#
    /// Flow only stores a memory when the user explicitly asks it to.
    static let memoryCue = #"\b(remember|note to self|make a note|take a note|note (that|this|down)|save (this|that|it)|keep in mind|don'?t forget|write (this|that|it) down|jot)\b"#
    /// Changing or removing something Flow remembers.
    private static let memoryEditCue = #"\b(update|change|correct|fix|edit|actually|forget|delete|remove|erase|no longer|now)\b"#
    private static let editCue = #"\b(move|change|reschedule|push|update|rename|cancel|delete|remove|clear|drop|scratch)\b"#

    /// A real request for information (vs. a remark or statement).
    static func looksLikeQuestion(_ t: String) -> Bool { t.matches(questionStart) || t.matches(questionLike) }

    /// Greetings and short remarks addressed to Flow: answer them, don't file them as memories.
    static func isSmallTalk(_ t: String) -> Bool {
        let words = t.split(separator: " ").count
        return t.matches(smallTalkCue) || (words <= 4 && !t.matches(keepCue) && !looksLikeQuestion(t))
    }

    static func correct(_ r: inout Route, transcript t: String, focused: Bool) {
        let explicitPaste = t.matches(pasteCue)
        let questionish = t.matches(questionStart) || t.matches(questionLike) || (!focused && isSmallTalk(t))

        // Memory search is local and cheap, so every question checks it.
        for i in r.calls.indices where r.calls[i].tool == "answer_question" { r.calls[i].args["use_memory"] = true }

        // Drop calls whose trigger words never appear in what was said (the model copying a few-shot example).
        let before = r.calls.count
        r.calls.removeAll { c in
            switch c.tool {
            case "open_app": return !t.matches(openCue)
            case "click_element": return !t.matches(clickCue)
            case "draft_message": return !t.matches(draftCue)
            case "paste_text": return !explicitPaste
            case "answer_question": return !questionish && t.matches(memoryCue)
            case "update_reminder", "delete_reminder": return !t.matches(editCue)
            case "update_memory", "delete_memory": return !t.matches(memoryEditCue)
            default: return false
            }
        }
        if r.calls.count < before { r.corrections.append("dropped \(before - r.calls.count) unsupported call(s)") }

        if r.calls.isEmpty {
            if t.matches(memoryCue) {
                r.calls = [RoutedCall(tool: "memory_save", args: ["title": titleFrom(t), "content": t])]
            } else {
                r.calls = [RoutedCall(tool: "answer_question", args: ["question": t, "use_memory": true,
                                                                      "use_files": t.matches(fileWords), "use_web": false])]
            }
        }

        // Questions the model turned into UI actions.
        if ["open_app", "click_element", "paste_text"].contains(r.calls[0].tool), t.matches(questionStart),
           !explicitPaste, !t.matches(commandStart) {
            r.calls = [RoutedCall(tool: "answer_question", args: ["question": t, "use_memory": true,
                                                                  "use_files": t.matches(fileWords), "use_web": false])]
            r.corrections.append("action→question")
        }
        // Explicit reminder language the model filed as a plain memory.
        if r.calls[0].tool == "memory_save", t.matches(remindCue), !r.calls.contains(where: { $0.tool == "create_reminder" }) {
            let title = (r.calls[0].args["title"] as? String) ?? titleFrom(t)
            r.calls[0] = RoutedCall(tool: "create_reminder", args: ["title": title, "when": t, "notes": ""])
            r.corrections.append("memory→reminder")
        }
        // Editing or forgetting existing memories, however the model filed it.
        let updateMemoryCue = #"^\s*(please\s+)?(update|change|correct|fix|edit)\s+(my\s+|the\s+)?(memory|memories|what you (know|remember))\b"#
        let forgetCue = #"^\s*(please\s+)?(forget|erase|delete|remove)\b(?!.*\breminder\b)"#
        if t.matches(updateMemoryCue), !r.calls.contains(where: { $0.tool == "update_memory" }) {
            r.calls = [RoutedCall(tool: "update_memory", args: ["which": aboutClause(t) ?? t, "change": t])]
            r.corrections.append("→update_memory")
        } else if t.matches(forgetCue), !r.calls.contains(where: { $0.tool == "delete_memory" }) {
            let which = t.replacingOccurrences(of: #"(?i)^\s*(please\s+)?(forget|erase|delete|remove)\s+(that|what i (said|told you)( about)?|about|my memory (of|about)|the memory (of|about))?\s*"#,
                                               with: "", options: .regularExpression)
            r.calls = [RoutedCall(tool: "delete_memory", args: ["which": which.isEmpty ? t : which])]
            r.corrections.append("→delete_memory")
        }
        // "Remember X and remind me Friday to Y": keep the memory half if the model dropped it.
        if t.matches(#"^\s*(remember|note to self)\b"#), !r.calls.contains(where: { $0.tool == "memory_save" }),
           r.calls.contains(where: { $0.tool == "create_reminder" }) {
            let fact = t.components(separatedBy: #" and remind"#).first ?? t
            r.calls.insert(RoutedCall(tool: "memory_save", args: ["title": titleFrom(fact), "content": fact]), at: 0)
            r.corrections.append("kept memory half")
        }

        // Memories only on request: anything else said to Flow gets a reply instead of being filed away.
        if !t.matches(memoryCue) && r.calls.contains(where: { $0.tool == "memory_save" }) {
            if r.calls.contains(where: { $0.tool != "memory_save" }) {
                r.calls.removeAll { $0.tool == "memory_save" }          // another tool is doing the real work
                r.corrections.append("dropped unrequested memory")
            } else {
                r.calls = [RoutedCall(tool: "answer_question", args: ["question": t, "use_memory": true, "use_files": false, "use_web": false])]
                r.corrections.append("memory→reply (not asked to remember)")
            }
        }
        r.calls = r.calls.enumerated().filter { i, c in
            c.tool != "answer_question" || !r.calls[..<i].contains { $0.tool == "answer_question" }
        }.map(\.element)

        // "Write an email here to Kevin…" with a text field focused: compose it in place.
        if focused, t.matches(writeCue), t.matches(hereCue),
           ["draft_message", "paste_text", "answer_question", "memory_save"].contains(r.calls[0].tool) {
            r.calls = [RoutedCall(tool: "write_text", args: ["instructions": t])]
            r.corrections.append("→write_text (compose in focused field)")
        }
        // Without a focused field there's nowhere to type: draft it in Mail instead.
        if !focused, r.calls.first?.tool == "write_text" {
            r.calls[0] = RoutedCall(tool: "draft_message", args: ["to": recipient(t), "subject": "", "body": "", "include_last_meeting": false])
        }

        // "Reach out to Marcus…" is a message to draft now, not a reminder.
        if ["create_reminder", "answer_question", "memory_save"].contains(r.calls[0].tool), t.matches(draftStart), !t.matches(remindCue) {
            r.calls[0] = RoutedCall(tool: "draft_message", args: ["to": recipient(t), "subject": "", "body": "",
                                                                  "include_last_meeting": t.matches(#"\b(recap|meeting|call)\b"#)])
            r.corrections.append("reminder→draft")
        }

        // Derive the intent from what will actually run.
        let tool = r.calls[0].tool
        if tool == "paste_text" {
            r.intent = "action"
        } else {
            r.intent = ["memory_save": "memory", "answer_question": "question", "create_reminder": "reminder",
                        "start_meeting": "meeting", "stop_meeting": "meeting",
                        "update_reminder": "reminder", "delete_reminder": "reminder",
                        "update_memory": "memory", "delete_memory": "memory"][tool] ?? "action"
        }
    }

    /// "update my memory about Marcus, his email…" → "Marcus"
    static func aboutClause(_ t: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"(?i)\babout\s+([^,.;]+)"#),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let r = Range(m.range(at: 1), in: t) else { return nil }
        return String(t[r])
    }

    static func recipient(_ t: String) -> String {
        let pattern = #"\b(?:to|email|message|text|ping|reach out to|reply to)\s+([A-Z][a-z]+(?:\s[A-Z][a-z]+)?)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let r = Range(m.range(at: 1), in: t) else { return "" }
        return String(t[r])
    }

    static func titleFrom(_ t: String) -> String {
        let words = t.split(separator: " ").prefix(7).joined(separator: " ")
        return words.trimmingCharacters(in: .punctuationCharacters)
    }

    static func wordOverlap(_ a: String, _ b: String) -> Double {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        }
        let wa = words(a), wb = words(b)
        return Double(wa.intersection(wb).count) / Double(max(1, wa.union(wb).count))
    }
}

extension String {
    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
