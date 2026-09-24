import Foundation

struct MemorySaveTool: FlowTool {
    let name = "memory_save"
    let title = "Save memory"
    let summary = "Stores anything you tell Flow so it can recall it later."
    let symbol = "brain.head.profile"
    let risk = ToolRisk.reversible
    let permissions: [SystemPermission] = []
    let defaultPolicy = ToolPolicy.always
    let args: [(String, OJ)] = [("title", .str), ("content", .str)]

    func describe(_ a: Args) -> String { "Remember “\(a.string("title"))”" }

    func run(_ a: Args, _ ctx: ToolContext) async throws -> ToolOutcome {
        let title = a.string("title").isEmpty ? Router.titleFrom(ctx.transcript) : a.string("title")
        let body = a.string("content").isEmpty ? ctx.transcript : a.string("content")
        let e = ctx.log(.memory, title: title, body: body)
        LocalMemory.shared.index(e)
        return ToolOutcome(message: "Saved to memory", detail: title, entry: e)
    }
}

struct CreateReminderTool: FlowTool {
    let name = "create_reminder"
    let title = "Create reminder"
    let summary = "Puts a commitment on your Flow calendar and pops up a reminder when it's due."
    let symbol = "bell.fill"
    let risk = ToolRisk.reversible
    let permissions: [SystemPermission] = []
    let defaultPolicy = ToolPolicy.always
    let args: [(String, OJ)] = [("title", .str), ("when", .str), ("notes", .str)]

    func describe(_ a: Args) -> String { "Remind you to \(a.string("title").lowercased()) \(a.string("when"))" }

    func run(_ a: Args, _ ctx: ToolContext) async throws -> ToolOutcome {
        let spoken = a.string("when")
        var guessed = false
        let fireAt: Date
        if let d = DateResolver.resolve(spoken, now: ctx.now) ?? DateResolver.resolve(ctx.transcript, now: ctx.now) {
            fireAt = d
        } else {
            // No time given: default to the next morning.
            fireAt = Calendar.current.date(bySettingHour: DateResolver.defaultHour, minute: 0, second: 0,
                                           of: Calendar.current.date(byAdding: .day, value: 1, to: ctx.now)!)!
            guessed = true
        }
        let title = a.string("title").isEmpty ? Router.titleFrom(ctx.transcript) : a.string("title")
        var meta = ["spoken_time": spoken]
        if guessed { meta["time_guessed"] = "true" }
        let e = ctx.log(.reminder, title: title, body: a.string("notes"), status: .pending, startAt: fireAt, meta: meta)
        LocalMemory.shared.index(e)
        let when = DateResolver.friendly(fireAt, now: ctx.now)
        return ToolOutcome(message: "Reminder set", detail: "\(title) · \(when)\(guessed ? " (no time given)" : "")", entry: e)
    }
}

/// Finds the reminder the user means by a few words ("dentist", "the laundry one").
enum ReminderMatcher {
    static func find(_ which: String, now: Date = Date()) -> Entry? {
        let candidates = Store.shared.recent(limit: 300, kinds: [.reminder])
            .filter { [.pending, .proposed, .fired, .missed].contains($0.status) }
        guard !candidates.isEmpty else { return nil }
        let stop: Set<String> = ["the", "a", "my", "reminder", "about", "to", "for", "one", "that", "this", "on", "at"]
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 && !stop.contains($0) })
        }
        let want = words(which)
        // No description: the next upcoming reminder.
        guard !want.isEmpty else {
            return candidates.filter { $0.startAt >= now }.min { $0.startAt < $1.startAt } ?? candidates.first
        }
        let scored = candidates.map { e -> (Entry, Int) in
            let have = words(e.title + " " + e.body)
            // Prefix match so "dentist" finds "dentist's".
            let hits = want.filter { w in have.contains { $0.hasPrefix(w) || w.hasPrefix($0) } }.count
            return (e, hits)
        }.filter { $0.1 > 0 }
        return scored.max { a, b in a.1 != b.1 ? a.1 < b.1 : a.0.startAt > b.0.startAt }?.0
    }
}

struct UpdateReminderTool: FlowTool {
    let name = "update_reminder"
    let title = "Edit reminders"
    let summary = "Renames or reschedules an existing reminder (“move my dentist reminder to Friday”)."
    let symbol = "bell.badge"
    let risk = ToolRisk.reversible
    let permissions: [SystemPermission] = []
    let defaultPolicy = ToolPolicy.always
    let args: [(String, OJ)] = [("which", .str), ("new_title", .str), ("new_when", .str)]

    func describe(_ a: Args) -> String { "Change the “\(a.string("which"))” reminder" }

    func run(_ a: Args, _ ctx: ToolContext) async throws -> ToolOutcome {
        guard let r = ReminderMatcher.find(a.string("which"), now: ctx.now) else {
            throw ToolError("Couldn't find a reminder matching “\(a.string("which"))”")
        }
        let before = r
        var updated = r
        if !a.string("new_title").isEmpty { updated.title = a.string("new_title") }
        if !a.string("new_when").isEmpty {
            guard let d = DateResolver.resolve(a.string("new_when"), now: ctx.now) else {
                throw ToolError("Couldn't understand the time “\(a.string("new_when"))”")
            }
            updated.startAt = d
            updated.meta["spoken_time"] = a.string("new_when")
            updated.meta["time_guessed"] = nil
            if updated.status != .proposed { updated.status = .pending }
        }
        Store.shared.save(updated)
        let log = ctx.log(.action, title: "Updated reminder: \(updated.title)",
                          body: "Was \(DateResolver.friendly(before.startAt, now: ctx.now)), now \(DateResolver.friendly(updated.startAt, now: ctx.now))")
        return ToolOutcome(message: "Reminder updated", detail: "\(updated.title) · \(DateResolver.friendly(updated.startAt, now: ctx.now))",
                           entry: log, actions: [CardAction(title: "Undo") { Store.shared.save(before) }], openId: updated.id)
    }
}

struct DeleteReminderTool: FlowTool {
    let name = "delete_reminder"
    let title = "Delete reminders"
    let summary = "Removes a reminder you no longer need (“cancel the laundry reminder”). Undo is on the card."
    let symbol = "bell.slash"
    let risk = ToolRisk.reversible
    let permissions: [SystemPermission] = []
    let defaultPolicy = ToolPolicy.always
    let args: [(String, OJ)] = [("which", .str)]

    func describe(_ a: Args) -> String { "Delete the “\(a.string("which"))” reminder" }

    func run(_ a: Args, _ ctx: ToolContext) async throws -> ToolOutcome {
        guard let r = ReminderMatcher.find(a.string("which"), now: ctx.now) else {
            throw ToolError("Couldn't find a reminder matching “\(a.string("which"))”")
        }
        Store.shared.delete(r.id)
        let log = ctx.log(.action, title: "Deleted reminder: \(r.title)", body: "Was due \(DateResolver.friendly(r.startAt, now: ctx.now))")
        return ToolOutcome(message: "Reminder deleted", detail: "\(r.title) · was \(DateResolver.friendly(r.startAt, now: ctx.now))",
                           entry: log, actions: [CardAction(title: "Undo") { Store.shared.restore(r.id) }])
    }
}

/// Finds the memory the user means ("my memory about Marcus's email") with the same hybrid search as questions.
enum MemoryMatcher {
    static func find(_ which: String) async -> Entry? {
        let hits = await LocalMemory.shared.search(which, limit: 8).filter { $0.entry.kind == .memory }
        return hits.first(where: \.isRelevant)?.entry
    }
}

struct UpdateMemoryTool: FlowTool {
    let name = "update_memory"
    let title = "Edit memories"
    let summary = "Finds a past memory and updates it (“update my memory about Marcus — his email changed”)."
    let symbol = "brain.head.profile"
    let risk = ToolRisk.reversible
    let permissions: [SystemPermission] = []
    let defaultPolicy = ToolPolicy.always
    let args: [(String, OJ)] = [("which", .str), ("change", .str)]

    func describe(_ a: Args) -> String { "Update the memory about “\(a.string("which"))”" }

    func run(_ a: Args, _ ctx: ToolContext) async throws -> ToolOutcome {
        let which = a.string("which").isEmpty ? ctx.transcript : a.string("which")
        guard let m = await MemoryMatcher.find(which) else {
            throw ToolError("Couldn't find a memory about “\(which)”")
        }
        let change = a.string("change").isEmpty ? ctx.transcript : a.string("change")
        // Merge the change into the old memory so unrelated details survive.
        let system = """
        Rewrite a saved memory to include \(Prompts.name)'s correction. Keep every detail that still holds and replace what changed. \
        Write the result as a clean statement of the facts — never mention the change itself. Output JSON with a 3-8 word title and the full updated content.
        """
        let examples = [
            (user: "Memory: Dana's flight lands at 6pm on Sunday at SFO.\nCorrection: Actually it lands at 8",
             assistant: #"{"title":"Dana's flight lands Sunday 8pm","content":"Dana's flight lands at 8pm on Sunday at SFO."}"#),
            (user: "Memory: I left my bike at the north rack, spot 12.\nCorrection: Actually it's spot 14",
             assistant: #"{"title":"Bike at north rack, spot 14","content":"I left my bike at the north rack, spot 14."}"#),
        ]
        guard let (out, _) = try? await LLMClient.router.complete(
                prompt: ChatML.prompt(system: system, turns: examples, user: "Memory: \(m.body)\nCorrection: \(change)"),
                schema: .props([("title", .str), ("content", .str)]), maxTokens: 250),
              let obj = JSON.parse(out), let content = (obj["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else { throw ToolError("Couldn't update that memory") }
        let before = m
        var updated = m
        updated.body = content
        if let t = obj["title"] as? String, !t.isEmpty { updated.title = t }
        updated.meta["edited"] = ISO8601DateFormatter().string(from: ctx.now)
        Store.shared.save(updated)
        LocalMemory.shared.index(updated)
        let log = ctx.log(.action, title: "Updated memory: \(updated.title)", body: "Was: \(before.body)\nNow: \(content)")
        return ToolOutcome(message: "Memory updated", detail: content, entry: log,
                           actions: [CardAction(title: "Undo") { Store.shared.save(before); LocalMemory.shared.index(before) }],
                           openId: updated.id)
    }
}

struct DeleteMemoryTool: FlowTool {
    let name = "delete_memory"
    let title = "Forget memories"
    let summary = "Deletes a memory you don't want Flow to keep (“forget where I parked”). Undo is on the card."
    let symbol = "brain"
    let risk = ToolRisk.reversible
    let permissions: [SystemPermission] = []
    let defaultPolicy = ToolPolicy.always
    let args: [(String, OJ)] = [("which", .str)]

    func describe(_ a: Args) -> String { "Forget the memory about “\(a.string("which"))”" }

    func run(_ a: Args, _ ctx: ToolContext) async throws -> ToolOutcome {
        let which = a.string("which").isEmpty ? ctx.transcript : a.string("which")
        guard let m = await MemoryMatcher.find(which) else {
            throw ToolError("Couldn't find a memory about “\(which)”")
        }
        Store.shared.delete(m.id)
        let log = ctx.log(.action, title: "Forgot memory: \(m.title)", body: m.body)
        return ToolOutcome(message: "Forgotten", detail: m.title, entry: log,
                           actions: [CardAction(title: "Undo") { Store.shared.restore(m.id); LocalMemory.shared.index(m) }])
    }
}
