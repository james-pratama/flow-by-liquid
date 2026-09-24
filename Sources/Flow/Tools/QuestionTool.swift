import Foundation
import PDFKit
import AppKit

struct AnswerQuestionTool: FlowTool {
    let name = "answer_question"
    let title = "Answer questions"
    let summary = "Answers from your memory, searches files on this Mac, and searches the web when needed."
    let symbol = "questionmark.bubble"
    let risk = ToolRisk.read
    let permissions: [SystemPermission] = []
    let defaultPolicy = ToolPolicy.always
    let args: [(String, OJ)] = [("question", .str), ("use_memory", .bool), ("use_files", .bool), ("use_web", .bool)]

    func describe(_ a: Args) -> String { "Look up: \(a.string("question"))" }

    func run(_ a: Args, _ ctx: ToolContext) async throws -> ToolOutcome {
        var q = a.string("question").isEmpty ? ctx.transcript : a.string("question")
        // Small talk and plain statements get a short conversational reply, not a search.
        let chatting = Router.isSmallTalk(ctx.transcript) || !Router.looksLikeQuestion(ctx.transcript)
        // Follow-ups were already made self-contained (Conversation.resolve); ctx.transcript is the full request.
        let history = ctx.history
        if !chatting && ctx.said != nil && ctx.said != ctx.transcript { q = ctx.transcript }
        let result = await QuestionAgent.answer(chatting ? ctx.transcript : q, useFiles: a.bool("use_files"),
                                                useWeb: a.bool("use_web"), chatting: chatting, history: history)
        var meta: [String: String] = ["sources": result.sources.joined(separator: "\n")]
        if !result.searched.isEmpty { meta["searched"] = result.searched.joined(separator: ", ") }
        if !result.reasoning.isEmpty { meta["reasoning"] = result.reasoning }
        if !result.steps.isEmpty { meta["steps"] = result.steps.joined(separator: "\n") }
        let e = ctx.log(.question, title: chatting ? (ctx.said ?? ctx.transcript) : q, body: result.answer, meta: meta)
        var actions: [CardAction] = []
        if let url = result.openURL {
            actions.append(CardAction(title: url.isFileURL ? "Open file" : "Open link", primary: true) {
                NSWorkspace.shared.open(url)
            })
        }
        return ToolOutcome(message: chatting ? (ctx.said ?? ctx.transcript) : q, detail: result.answer, entry: e, style: .answer,
                           holdSeconds: Settings.shared.answerSeconds, actions: actions)
    }
}

/// A small agent loop: memory first, then files and web when asked for (or when memory comes up empty).
enum QuestionAgent {
    struct Result {
        var answer: String
        var sources: [String]
        var searched: [String]
        var openURL: URL?
        var reasoning = ""
        var steps: [String] = []
    }

    /// The model likes to say "I've noted that" — but chat replies don't save anything. Drop those sentences.
    static func withoutFalseSaveClaims(_ reply: String) -> String {
        let claim = #"(?i)\b(i'?ve noted|i'?ll note|noted|got (that|a|the) note|made a note|i'?ll (keep|make sure|remember)|keep (that|it|this) (in mind|on your radar)|i'?ve (saved|got that noted)|saved (that|it|this))\b"#
        let sentences = reply.components(separatedBy: CharacterSet(charactersIn: ".!")).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let kept = sentences.filter { !$0.matches(claim) }
        guard kept.count < sentences.count else { return reply }
        let base = kept.isEmpty ? "Got it" : kept.joined(separator: ". ")
        return base + ". Say “remember…” if you want me to save it."
    }

    /// Rewrites a follow-up into a self-contained question using the last few turns. nil when not a follow-up.
    static func standalone(_ question: String, history: [(user: String, assistant: String, at: Date)]) async -> String? {
        guard let last = history.last, Date().timeIntervalSince(last.at) < 30 * 60 else { return nil }
        let followUp = question.matches(#"^\s*(and|also|what about|how about|same|then|so|but)\b|\b(it|that|there|them|this one|he|she|they)\b"#)
            || question.split(separator: " ").count <= 4
        guard followUp else { return nil }
        let recent = history.suffix(3).map { "\(Prompts.name): \($0.user)\nFlow: \($0.assistant)" }.joined(separator: "\n")
        let system = """
        Rewrite \(Prompts.name)'s latest question as a complete, self-contained question, filling in what it refers to from the conversation. Don't answer it.
        Example — Conversation: "\(Prompts.name): What's the weather in Paris? / Flow: Sunny, 22°C." Latest: "And tomorrow?" → "What's the weather in Paris tomorrow?"
        Example — Conversation: "\(Prompts.name): Who founded Nvidia? / Flow: Jensen Huang and two others." Latest: "How old is he?" → "How old is Jensen Huang?"
        """
        let example = (user: "Conversation:\n\(Prompts.name): What's the population of Canada?\nFlow: About 40 million.\n\nLatest question: What about Mexico?",
                       assistant: #"{"question":"What's the population of Mexico?"}"#)
        guard let (text, _) = try? await LLMClient.router.complete(
                prompt: ChatML.prompt(system: system, turns: [example], user: "Conversation:\n\(recent)\n\nLatest question: \(question)"),
                schema: .props([("question", .str)]), maxTokens: 60),
              let out = (JSON.parse(text)?["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !out.isEmpty else { return nil }
        if out != question { flowLog("follow-up rewritten: \(question) → \(out)") }
        return out
    }

    /// Research loop: search memory → plan the next step (search again / files / web / answer) up to 3 times →
    /// reason over the findings with the model's thinking → answer. Steps show live on a working card.
    static func answer(_ question: String, useFiles: Bool, useWeb: Bool, chatting: Bool? = nil,
                       history: [(user: String, assistant: String, at: Date)] = []) async -> Result {
        let chatting = chatting ?? Router.isSmallTalk(question)
        if chatting { return await chat(question, history: history) }

        let card = await MainActor.run { Overlay.shared.beginWork(question) }
        defer { Task { @MainActor in Overlay.shared.dismiss(card) } }
        func step(_ text: String) async -> UUID { await MainActor.run { Overlay.shared.addStep(card, text) } }
        func done(_ id: UUID, _ text: String) async { await MainActor.run { Overlay.shared.finishStep(card, id, text) } }

        var findings: [String] = []
        var sources: [String] = []
        var seen = Set<String>()
        var searched: [String] = []
        var openURL: URL?
        var bestMemoryScore: Float = 0

        func searchMemory(_ q: String) async {
            let s = await step("Searching your memories for “\(q)”")
            let hits = await LocalMemory.shared.search(q, limit: 8).filter(\.isRelevant)
            var added = 0
            for h in hits where seen.insert(h.entry.id).inserted {
                let e = h.entry
                let when = e.startAt.formatted(date: .abbreviated, time: .shortened)
                let body = e.kind == .meeting ? e.body + (e.transcript.isEmpty ? "" : "\nTranscript: " + e.transcript.prefix(1500))
                                              : (e.body.isEmpty ? e.transcript : e.body)
                findings.append("[\(findings.count + 1)] \(e.kind.label) from \(when): \(e.title)\n\(body.prefix(1800))")
                sources.append("\(e.kind.label): \(e.title)")
                bestMemoryScore = max(bestMemoryScore, h.score)
                added += 1
            }
            searched.append("memory")
            await done(s, added == 0 ? "Memories: nothing new for “\(q)”" : "Memories: \(added) match\(added == 1 ? "" : "es") for “\(q)”")
        }
        func searchFiles(_ q: String) async {
            let s = await step("Searching files for “\(q)”")
            let files = FileSearch.search(q)
            for f in files.prefix(4) where seen.insert(f.path).inserted {
                findings.append("[\(findings.count + 1)] File \(f.path)\n\((FileSearch.snippet(f) ?? "").prefix(1200))")
                sources.append(f.path)
            }
            if openURL == nil { openURL = files.first }
            searched.append("files")
            await done(s, "Files: \(files.count) found")
        }
        func searchWeb(_ q: String) async {
            let query = LocationService.shared.localize(q)
            let s = await step("Searching the web for “\(query)”")
            let results = (try? await WebSearch.search(query)) ?? []
            for r in results.prefix(4) where seen.insert(r.url.absoluteString).inserted {
                findings.append("[\(findings.count + 1)] \(r.title) (\(r.url.host ?? ""))\n\(r.snippet)")
                sources.append(r.url.absoluteString)
            }
            if let top = results.first, let page = await WebSearch.fetchText(top.url) {
                findings.append("[\(findings.count + 1)] Page text of \(top.url.host ?? "")\n\(page)")
            }
            if openURL == nil { openURL = results.first?.url }
            searched.append("web")
            await done(s, "Web: \(results.count) results")
        }

        // Questions about the user's own world stay in their data unless it comes up empty.
        let personal = question.matches(#"\b(i|my|me|mine|we|our|us)\b"#)

        // 1. Always start with memory.
        await searchMemory(question)
        if useFiles { await searchFiles(question) }

        // 2. Loop: let the model look at what it found and choose the next step.
        var tried = Set([question.lowercased()])
        // Budget per source: the planner likes to repeat searches that already answered the question.
        var budget = ["search_memory": 1, "search_web": 1, "search_files": 1]
        for _ in 0..<3 {
            let s = await step("Deciding what to look up next…")
            guard let next = await plan(question, history: history, findings: findings, searched: searched,
                                        hints: (files: useFiles, web: useWeb)) else { await done(s, "Ready to answer"); break }
            let label = ["search_memory": "search memories again", "search_files": "search files",
                         "search_web": "search the web", "answer": "answer"][next.action] ?? next.action
            // The model narrates in the third person ("The user is asking…"); show just the decision then.
            let raw = next.thought.lowercased().hasPrefix("the user") ? "" : next.thought
            let thought = raw.count > 80 ? String(raw.prefix(77)) + "…" : raw
            await done(s, thought.isEmpty ? "Next: \(label)" : "\(thought) → \(label)")
            let q = next.query.isEmpty ? question : next.query
            if next.action == "answer" || !tried.insert(next.action + q.lowercased()).inserted { break }
            if (budget[next.action] ?? 0) <= 0 { break }
            budget[next.action, default: 0] -= 1
            // Personal questions stay in the user's data when it has answers, whatever the router guessed.
            if next.action == "search_web" && ((personal && !findings.isEmpty) || (!useWeb && bestMemoryScore >= 0.45)) {
                await done(await step("Your notes cover this — skipping the web"), "Your notes cover this — skipping the web")
                break
            }
            switch next.action {
            case "search_memory": await searchMemory(q)
            case "search_files": await searchFiles(q)
            case "search_web": await searchWeb(q)
            default: break
            }
        }
        if findings.isEmpty && !searched.contains("web") && !useFiles { await searchWeb(question) }

        // 3. Reason over everything found, then answer.
        let r = await step("Reasoning over \(findings.count) finding\(findings.count == 1 ? "" : "s")…")
        var now = Date().formatted(date: .complete, time: .shortened)
        if let place = LocationService.shared.place { now += "\n\(Prompts.name) is currently in: \(place)" }
        let user = "Now: \(now)\n\nFindings:\n\(findings.isEmpty ? "(nothing found)" : findings.joined(separator: "\n\n"))\n\n\(Prompts.name) asked: \(question)"
        let system = Prompts.system(.answer) + "\nThink it through: check which findings actually answer the question, reconcile conflicts (newer beats older), then answer."
        let turns = history.map { (user: $0.user, assistant: JSON.string(["answer": $0.assistant])) }
        let thinking = ChatML.thinkingPrompt(system: system, turns: turns, user: user)
        var reasoning = ""
        var answer: String
        do {
            let (thought, _) = try await LLMClient.router.complete(prompt: thinking, maxTokens: 450, temperature: 0.1, stop: ["</think>"])
            reasoning = thought.trimmingCharacters(in: .whitespacesAndNewlines)
            await done(r, "Reasoned it through")
            let (text, _) = try await LLMClient.router.complete(prompt: thinking + thought + "</think>",
                                                                schema: .props([("answer", .str)]), maxTokens: 260, temperature: 0.1)
            answer = GeneratedText.clean(JSON.parse(text)?["answer"] as? String ?? text)
            answer = answer.replacingOccurrences(
                of: #"\s*\((Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)?,?\s*(January|February|March|April|May|June|July|August|September|October|November|December) \d{1,2}(, \d{4})?\)"#,
                with: "", options: .regularExpression)
        } catch {
            answer = findings.isEmpty ? "I couldn't find anything about that." : "Here's what I found: " + sources.prefix(3).joined(separator: "; ")
        }
        var result = Result(answer: answer, sources: sources, searched: Array(NSOrderedSet(array: searched)) as? [String] ?? searched, openURL: openURL)
        result.reasoning = reasoning
        result.steps = await MainActor.run { Overlay.shared.model.cards.first { $0.id == card }?.steps.map(\.text) ?? [] }
        return result
    }

    struct Plan { let thought: String; let action: String; let query: String }

    /// One planning step (no reasoning tokens — it has to be fast): what to look up next, or answer.
    static func plan(_ question: String, history: [(user: String, assistant: String, at: Date)], findings: [String],
                     searched: [String], hints: (files: Bool, web: Bool)) async -> Plan? {
        let system = """
        You are Flow's research planner. Decide the single next step toward answering \(Prompts.name)'s question.
        Actions:
        - search_memory(query): everything \(Prompts.name) told Flow, their meetings, reminders, notes, emails Flow wrote. Use NEW wording or a narrower angle each time (names, topics, synonyms).
        - search_files(query): documents on their Mac.
        - search_web(query): the internet, for public facts, news, prices, weather.
        - answer: the findings already answer the question, or more searching won't help.
        Personal questions → memory. Public facts → web.
        thought: under 10 words, written to \(Prompts.name), about what you have or still need (e.g. "Have the budget, checking who owns it"). Never say "the user".
        Output JSON with the thought, the action and the query.
        """
        let recent = history.suffix(3).map { "\(Prompts.name): \($0.user)\nFlow: \($0.assistant)" }.joined(separator: "\n")
        var user = "Question: \(question)\n"
        if !recent.isEmpty { user += "\nRecent conversation:\n\(recent)\n" }
        if hints.files { user += "\nHint: they're asking about a document or file.\n" }
        if hints.web { user += "\nHint: this likely needs the web.\n" }
        user += "\nSearches done: \(searched.isEmpty ? "none" : searched.joined(separator: ", "))"
        user += "\nFindings so far:\n\(findings.isEmpty ? "(none)" : findings.map { String($0.prefix(300)) }.joined(separator: "\n"))"
        let schema = OJ.props([("thought", OJ.object([("type", .string("string")), ("maxLength", .int(90))])),
                               ("action", .enumeration(["search_memory", "search_files", "search_web", "answer"])),
                               ("query", .str)])
        guard let (text, _) = try? await LLMClient.router.complete(prompt: ChatML.prompt(system: system, user: user),
                                                                   schema: schema, maxTokens: 90),
              let obj = JSON.parse(text), let action = obj["action"] as? String else { return nil }
        return Plan(thought: (obj["thought"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                    action: action, query: (obj["query"] as? String ?? "").trimmingCharacters(in: .whitespaces))
    }

    /// Small talk: instant, no searching.
    static func chat(_ said: String, history: [(user: String, assistant: String, at: Date)]) async -> Result {
        var now = Date().formatted(date: .complete, time: .shortened)
        if let place = LocationService.shared.place { now += "\n\(Prompts.name) is currently in: \(place)" }
        let user = "Now: \(now)\n\n\(Prompts.name) said: \(said)\n\n(Reply in one short sentence. You have not saved anything, so don't say you noted or saved it.)"
        let turns = history.map { (user: $0.user, assistant: JSON.string(["answer": $0.assistant])) }
        var answer = "I'm here — the language model isn't responding right now."
        if let (text, _) = try? await LLMClient.router.complete(prompt: ChatML.prompt(system: Prompts.system(.answer), turns: turns, user: user),
                                                                schema: .props([("answer", .str)]), maxTokens: 120, temperature: 0.1) {
            answer = withoutFalseSaveClaims((JSON.parse(text)?["answer"] as? String ?? text).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Result(answer: answer, sources: [], searched: [], openURL: nil)
    }
}

enum FileSearch {
    /// Spotlight search in the home folder for the question's keywords.
    static func search(_ question: String, limit: Int = 6) -> [URL] {
        let stop: Set<String> = ["find", "where", "is", "are", "the", "my", "a", "an", "of", "from", "for", "i", "was", "working",
                                 "on", "last", "week", "file", "files", "document", "doc", "pdf", "show", "me", "that", "with",
                                 "what", "which", "did", "put", "can", "you", "open", "about", "to", "in"]
        let words = question.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stop.contains($0) }
        guard !words.isEmpty else { return [] }
        let terms = Array(words.prefix(3))
        // Match file names first (most precise), then full-text.
        let nameQuery = terms.map { "kMDItemDisplayName == \"*\($0)*\"cd" }.joined(separator: " && ")
        var results = mdfind(nameQuery)
        if results.count < limit { results += mdfind(terms.joined(separator: " ")) }
        var seen = Set<String>()
        return results.filter { url in
            let p = url.path
            guard !p.contains("/Library/"), !p.contains("/."), !p.contains(".app/"), !p.contains("/node_modules/"),
                  seen.insert(p).inserted else { return false }
            return true
        }.prefix(limit).map { $0 }
    }

    private static func mdfind(_ query: String) -> [URL] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-onlyin", NSHomeDirectory(), query]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate() }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n").prefix(40).map { URL(fileURLWithPath: String($0)) }
    }

    static func snippet(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .formatted(date: .abbreviated, time: .omitted) ?? ""
        var text: String?
        if ext == "pdf" {
            text = PDFDocument(url: url)?.string
        } else if ["txt", "md", "markdown", "csv", "json", "swift", "py", "js", "ts", "html", "rtf", "yaml", "yml"].contains(ext) {
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        let body = text.map { String($0.prefix(1000)) } ?? "(\(ext.uppercased()) file)"
        return "Modified \(modified). \(body)"
    }
}

enum WebSearch {
    struct Result { let title: String; let url: URL; let snippet: String }

    static func search(_ query: String, limit: Int = 5) async throws -> [Result] {
        let key = Settings.shared.braveAPIKey
        if !key.isEmpty { return try await brave(query, key: key, limit: limit) }
        let ddg = (try? await duckDuckGo(query, limit: limit)) ?? []
        if !ddg.isEmpty { return ddg }
        // DuckDuckGo sometimes answers automated requests with a bot challenge; Wikipedia's API is a reliable fallback.
        return (try? await wikipedia(query, limit: limit)) ?? []
    }

    private static func wikipedia(_ q: String, limit: Int) async throws -> [Result] {
        var c = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        c.queryItems = [URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "list", value: "search"),
                        URLQueryItem(name: "srsearch", value: q), URLQueryItem(name: "srlimit", value: String(limit)),
                        URLQueryItem(name: "format", value: "json")]
        var req = URLRequest(url: c.url!)
        req.setValue("Flow/0.1 (on-device assistant)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8
        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hits = (obj?["query"] as? [String: Any])?["search"] as? [[String: Any]] ?? []
        return hits.compactMap { h in
            guard let title = h["title"] as? String,
                  let url = URL(string: "https://en.wikipedia.org/wiki/" + title.replacingOccurrences(of: " ", with: "_")
                                    .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!) else { return nil }
            return Result(title: title + " — Wikipedia", url: url, snippet: stripTags(h["snippet"] as? String ?? ""))
        }
    }

    private static func brave(_ q: String, key: String, limit: Int) async throws -> [Result] {
        var c = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        c.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "count", value: String(limit))]
        var req = URLRequest(url: c.url!)
        req.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 8
        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = (obj?["web"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
        return results.compactMap { r in
            guard let u = (r["url"] as? String).flatMap(URL.init) else { return nil }
            return Result(title: stripTags(r["title"] as? String ?? ""), url: u, snippet: stripTags(r["description"] as? String ?? ""))
        }
    }

    private static func duckDuckGo(_ q: String, limit: Int) async throws -> [Result] {
        var req = URLRequest(url: URL(string: "https://html.duckduckgo.com/html/")!)
        req.httpMethod = "POST"
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "q=\(q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q)".data(using: .utf8)
        req.timeoutInterval = 8
        let (data, _) = try await URLSession.shared.data(for: req)
        let html = String(data: data, encoding: .utf8) ?? ""
        let linkRe = try NSRegularExpression(pattern: #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])
        let snipRe = try NSRegularExpression(pattern: #"class="result__snippet"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])
        let ns = html as NSString
        let links = linkRe.matches(in: html, range: NSRange(location: 0, length: ns.length))
        let snips = snipRe.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var out: [Result] = []
        for (i, m) in links.enumerated() {
            var href = ns.substring(with: m.range(at: 1))
            if href.hasPrefix("//") { href = "https:" + href }
            // DuckDuckGo wraps results in a redirect: /l/?uddg=<encoded url>
            if let c = URLComponents(string: href), let target = c.queryItems?.first(where: { $0.name == "uddg" })?.value {
                href = target
            }
            guard let url = URL(string: href), !href.contains("duckduckgo.com/y.js") else { continue }
            let snippet = i < snips.count ? stripTags(ns.substring(with: snips[i].range(at: 1))) : ""
            out.append(Result(title: stripTags(ns.substring(with: m.range(at: 2))), url: url, snippet: snippet))
            if out.count >= limit { break }
        }
        return out
    }

    static func fetchText(_ url: URL, maxChars: Int = 2500) async -> String? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.setValue("Mozilla/5.0 (Macintosh) Flow/0.1", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        var s = html.replacingOccurrences(of: #"(?is)<(script|style|nav|header|footer|svg)[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
        s = stripTags(s)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return String(s.prefix(maxChars))
    }

    static func stripTags(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (k, v) in ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
