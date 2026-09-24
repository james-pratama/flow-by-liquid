import Foundation

enum ToolRisk: String {
    case read = "Read-only"
    case reversible = "Changes things"
    case outward = "Outward-facing"
}

enum ToolPolicy: String, CaseIterable, Identifiable {
    case always, ask, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .always: return "Always"
        case .ask: return "Ask first"
        case .off: return "Off"
        }
    }
}

/// What a tool knows about the moment the user spoke.
struct ToolContext {
    /// The request tools act on: what the user said, made self-contained using the conversation so far.
    let transcript: String
    let focus: FocusContext?
    let now: Date
    let sessionId: String
    let intent: String
    /// the user's exact words (logged, and used as their side of the conversation history).
    var said: String? = nil
    /// Recent conversation (oldest first), for tools that write or answer.
    var history: [(user: String, assistant: String, at: Date)] = []

    /// Saves an entry stamped with what the user said.
    func log(_ kind: EntryKind, title: String, body: String = "", status: EntryStatus = .done,
             startAt: Date? = nil, meta: [String: String] = [:]) -> Entry {
        var meta = meta
        if let said, said != transcript { meta["understood_as"] = transcript }
        let e = Entry(kind: kind, title: title, body: body, transcript: said ?? transcript, startAt: startAt ?? now,
                      status: status, source: "hotkey", sessionId: sessionId, meta: meta)
        Store.shared.save(e)
        return e
    }
}

struct ToolOutcome {
    var message: String
    var detail: String = ""
    var entry: Entry? = nil
    var style: CardStyle = .success
    var holdSeconds: Double? = nil
    var actions: [CardAction] = []
    /// What "Open in Flow" shows (e.g. the reminder that was edited, not the log of the edit). Defaults to `entry`.
    var openId: String? = nil
    var openTarget: String? { openId ?? entry?.id }
}

struct Args {
    let raw: [String: Any]
    func string(_ k: String) -> String { (raw[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    func bool(_ k: String) -> Bool { raw[k] as? Bool ?? false }
}

protocol FlowTool {
    var name: String { get }
    var title: String { get }
    var summary: String { get }
    var symbol: String { get }
    var risk: ToolRisk { get }
    var permissions: [SystemPermission] { get }
    var defaultPolicy: ToolPolicy { get }
    /// Argument properties, in generation order.
    var args: [(String, OJ)] { get }
    /// One-line description of a call, shown on "Ask first" confirmations.
    func describe(_ args: Args) -> String
    func run(_ args: Args, _ ctx: ToolContext) async throws -> ToolOutcome
}

extension FlowTool {
    var policy: ToolPolicy { Store.shared.policy(name) ?? defaultPolicy }
    var missingPermissions: [SystemPermission] { permissions.filter { !$0.isGranted } }
}

enum ToolRegistry {
    static let all: [FlowTool] = [
        MemorySaveTool(), UpdateMemoryTool(), DeleteMemoryTool(), AnswerQuestionTool(), CreateReminderTool(), UpdateReminderTool(), DeleteReminderTool(),
        OpenAppTool(), PasteTextTool(), WriteTextTool(),
        ClickElementTool(), DraftMessageTool(), StartMeetingTool(), StopMeetingTool(),
    ]
    static func tool(_ name: String) -> FlowTool? { all.first { $0.name == name } }
}

struct ToolError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// Test mode (FLOW_DRY_RUN): tools log what they would do instead of touching the user's apps.
enum DryRun {
    static let active = ProcessInfo.processInfo.environment["FLOW_DRY_RUN"] != nil
}
