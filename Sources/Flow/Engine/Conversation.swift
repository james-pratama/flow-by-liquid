import Foundation

/// Flow treats talking to it as one multi-step conversation. Before routing, a follow-up
/// ("just that, nothing else", "make it 3pm", "and tomorrow?") is merged with the earlier turns into a
/// single self-contained request, so every tool — not just answers — sees what the user actually means.
enum Conversation {
    typealias Turn = (user: String, assistant: String, at: Date)

    /// How long a conversation stays "live" for follow-ups.
    static let window: TimeInterval = 10 * 60

    /// Openers that continue the previous request.
    private static let followUpCue = #"^\s*(and|also|actually|no|nope|yes|yeah|yep|ok|okay|sure|just|only|instead|then|but|make it|change it|move it|send it|what about|how about|same|that one|the first|the second)\b"#
    /// Pronouns that point back — only a follow-up signal in short messages right after Flow replied.
    private static let pointerCue = #"\b(it|that|this|those|them|there|he|she|they|him|her)\b"#

    private static let freshStart = #"^\s*(remind|remember|open|launch|what|who|where|when|how|why|is|are|can|email|message|write|click|press|start|stop|find|note|save|draft|send|type|paste)\b"#

    /// Returns the self-contained request, or nil when the message already stands alone.
    static func resolve(_ said: String, history: [Turn], now: Date = Date()) async -> String? {
        guard let last = history.last, now.timeIntervalSince(last.at) < window else { return nil }
        let flowAsked = last.assistant.trimmingCharacters(in: .whitespaces).hasSuffix("?")
        let words = said.split(separator: " ").count
        // Plain small talk ("hi", "thanks") doesn't need rewriting.
        if Router.isSmallTalk(said) && !flowAsked && !said.matches(followUpCue) { return nil }
        // A fresh command ("Remind me to call Sam tomorrow") stands alone unless it points back at something
        // ("it", "that", "also"…) or answers a question Flow just asked.
        let recentReply = now.timeIntervalSince(last.at) < 3 * 60
        let pointsBack = recentReply && words <= 8 && said.matches(pointerCue) && !said.matches(freshStart)
        guard flowAsked || said.matches(followUpCue) || pointsBack || (words <= 3 && !said.matches(freshStart)) else { return nil }

        let recent = history.suffix(4).map { "\(Prompts.name): \($0.user)\nFlow: \($0.assistant)" }.joined(separator: "\n")
        let system = """
        \(Prompts.name) is in a multi-step conversation with Flow, their voice assistant. Rewrite their LATEST message as one complete, \
        self-contained request that includes everything from the conversation needed to act on it.
        - If it answers a question Flow just asked, merge it with \(Prompts.name)'s original request.
        - If it changes or refers to something earlier ("make it 3pm", "send it to him"), spell that thing out.
        - If it is already self-contained or starts something new, return it unchanged.
        Keep \(Prompts.name)'s voice (first person, imperative). Don't answer or perform it.
        """
        let examples: [(user: String, assistant: String)] = [
            ("Conversation:\n\(Prompts.name): Help me write an email here telling Dana the deck is attached\nFlow: Happy to — anything else you want to include?\n\nLatest: Just that and say thanks",
             #"{"request":"Write an email here telling Dana the deck is attached, and say thanks. Nothing else."}"#),
            ("Conversation:\n\(Prompts.name): Remind me to call Sam tomorrow\nFlow: (Reminder set: Call Sam, Tomorrow 9:00 AM)\n\nLatest: Actually make it 3pm",
             #"{"request":"Move my reminder to call Sam to tomorrow at 3pm"}"#),
            ("Conversation:\n\(Prompts.name): What's the weather in Paris?\nFlow: Sunny and 22 degrees.\n\nLatest: And tomorrow?",
             #"{"request":"What's the weather in Paris tomorrow?"}"#),
            ("Conversation:\n\(Prompts.name): What's the capital of Japan?\nFlow: Tokyo.\n\nLatest: Open Spotify",
             #"{"request":"Open Spotify"}"#),
            ("Conversation:\n\(Prompts.name): Write an email here telling Dana the deck is attached\nFlow: (Wrote in Gmail)\n\nLatest: Remind me to follow up with her on Friday",
             #"{"request":"Remind me to follow up with Dana on Friday"}"#),
        ]
        guard let (text, _) = try? await LLMClient.router.complete(
                prompt: ChatML.prompt(system: system, turns: examples, user: "Conversation:\n\(recent)\n\nLatest: \(said)"),
                schema: .props([("request", .str)]), maxTokens: 120),
              let out = (JSON.parse(text)?["request"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !out.isEmpty, out.lowercased() != said.lowercased() else { return nil }
        // Reject rewrites that bring in names the user never mentioned (the model borrowing from its examples).
        let known = (said + " " + recent).lowercased()
        let names = out.split(whereSeparator: { !$0.isLetter && $0 != "'" }).dropFirst()
            .filter { $0.first?.isUppercase == true && !["I", Prompts.name, "Flow"].contains(String($0)) }
        if let stray = names.first(where: { !known.contains($0.lowercased()) }) {
            flowLog("conversation: rejected rewrite “\(out)” (introduces “\(stray)”)")
            return nil
        }
        flowLog("conversation: “\(said)” → “\(out)”")
        return out
    }
}
