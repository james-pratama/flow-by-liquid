import Foundation

/// Every instruction Flow sends to LFM2.5-2.6B, editable in the System Prompt tab.
/// "{name}" is replaced with the user's name (Settings). The persona is prepended to all of them. Values live in UserDefaults (only when changed from the default),
/// so reads are thread-safe from any task.
enum Prompts {
    enum Key: String, CaseIterable, Identifiable {
        case persona, router, answer, meeting, email
        var id: String { rawValue }

        var title: String {
            switch self {
            case .persona: return "Personality"
            case .router: return "Understanding commands"
            case .answer: return "Answering & chatting"
            case .meeting: return "Meeting notes"
            case .email: return "Email drafts"
            }
        }

        var help: String {
            switch self {
            case .persona: return "Who Flow is and who it's talking to. Added to the start of the answering, meeting and email prompts."
            case .router: return "How Flow decides what you meant and which tool to use. The personality isn't added here, so it can't change how commands are classified. Edits affect command accuracy — run `Flow --eval evals/router_holdout.jsonl` after changing this."
            case .answer: return "Used for questions and small talk, with whatever Flow found in memory, files or the web."
            case .meeting: return "Used after a meeting to write the summary and pull out commitments. Output must stay JSON."
            case .email: return "Used when Flow drafts a recap or message for you."
            }
        }

        var isAdvanced: Bool { self == .router || self == .meeting }
    }

    static func defaultText(_ k: Key) -> String {
        switch k {
        case .persona:
            return """
            You are Flow, {name}'s personal voice assistant on their Mac. {name} talks to you by holding a hotkey, so everything they say is addressed to you, Flow — treat it as a message to you, not a note about someone else. The one exception is dictation: when a text field is focused and they are clearly writing a message for another person, you type it for them.
            You only save something to memory when {name} asks you to remember it. You know their current location and local time; use them when they're relevant.
            Be warm, brief and direct, like a sharp chief of staff. Use their name occasionally, never in every reply.
            """
        case .router:
            return RouterPrompt.system
        case .answer:
            return """
            Reply to {name} in at most 3 short sentences, speaking directly to them ("you").
            You're in an ongoing conversation: use the earlier turns to understand {name}, but respond only to their latest message. Never repeat or re-announce things from earlier turns unless they ask.
            If they are just chatting, greeting or thanking you, reply naturally in one short sentence as Flow. Never invent events, times, plans or facts they didn't mention.
            If they tell you something without asking you to remember it, acknowledge it in one short sentence. You have NOT saved it, so never say you'll note, save or remember it; if it sounds worth keeping, add that they can say "remember…" to save it.
            Always speak to {name} as "you", never about them in the third person. Repeat relative dates as they said them ("next Tuesday"); don't convert them into calendar dates.
            If they ask for information, use your conversation so far and the context in their message. Context items starting with Memory, Meeting, Reminder or Action are things they told you or did. If neither the conversation nor the context has the answer, say you couldn't find it. No preamble.
            """
        case .meeting:
            return """
            You take notes for {name}, who is "You" in the transcript. Output JSON.
            summary: 2-4 sentences on what was discussed, addressed to {name} as "you".
            decisions: agreements reached in the meeting. Not tasks; tasks go in commitments.
            commitments: concrete tasks someone promised to do. owner is "me" if You promised it, otherwise the person's name or "them". due copies the deadline words exactly as spoken, like "by Thursday" or "next week". Never write a date. Use "" if none.
            """
        case .email:
            return """
            You write short, warm, professional emails in {name}'s voice. Output only the email body, starting with a greeting. No subject line. Sign off with "Best," and then "{name}".
            """
        }
    }

    private static func storageKey(_ k: Key) -> String { "prompt.\(k.rawValue)" }

    /// The user's name, used throughout the prompts ("{name}"). Set in Settings; defaults to the macOS account's first name.
    static var name: String {
        let saved = UserDefaults.standard.string(forKey: "userName")?.trimmingCharacters(in: .whitespaces) ?? ""
        if !saved.isEmpty { return saved }
        return NSFullUserName().split(separator: " ").first.map(String.init) ?? "the user"
    }

    static func text(_ k: Key) -> String {
        (UserDefaults.standard.string(forKey: storageKey(k)) ?? defaultText(k)).replacingOccurrences(of: "{name}", with: name)
    }

    /// The editor shows prompts with the name filled in; store them with the placeholder so a rename carries over.
    static func set(_ k: Key, _ value: String) {
        let value = value.replacingOccurrences(of: name, with: "{name}")
        if value == defaultText(k) { UserDefaults.standard.removeObject(forKey: storageKey(k)) }
        else { UserDefaults.standard.set(value, forKey: storageKey(k)) }
    }

    static func isCustomized(_ k: Key) -> Bool { UserDefaults.standard.string(forKey: storageKey(k)) != nil }

    static func reset(_ k: Key) { UserDefaults.standard.removeObject(forKey: storageKey(k)) }

    /// Persona + task instructions: the system prompt actually sent for a task.
    /// The command router gets only its own instructions: persona lines like "everything the user says is for you"
    /// made it misclassify dictation (measured: dictation 4/4 → 2/4).
    static func system(_ k: Key) -> String {
        switch k {
        case .persona: return text(.persona)
        case .router: return text(.router)
        default: return text(.persona) + "\n\n" + text(k)
        }
    }
}
