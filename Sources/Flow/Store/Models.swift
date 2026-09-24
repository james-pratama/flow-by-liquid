import Foundation

/// Every item Flow shows on the calendar and in the feed is an Entry.
enum EntryKind: String, Codable, CaseIterable, Identifiable {
    case memory, question, action, reminder, meeting, dictation
    var id: String { rawValue }

    var label: String {
        switch self {
        case .memory: return "Memory"
        case .question: return "Question"
        case .action: return "Action"
        case .reminder: return "Reminder"
        case .meeting: return "Meeting"
        case .dictation: return "Dictation"
        }
    }

    var symbol: String {
        switch self {
        case .memory: return "brain.head.profile"
        case .question: return "questionmark.bubble"
        case .action: return "bolt.fill"
        case .reminder: return "bell.fill"
        case .meeting: return "person.2.wave.2.fill"
        case .dictation: return "text.cursor"
        }
    }
}

enum EntryStatus: String, Codable {
    case done        // finished normally
    case pending     // reminder waiting to fire
    case proposed    // reminder extracted from a meeting, awaiting the user's OK
    case fired       // reminder has been shown
    case missed      // reminder came due while Flow was not running
    case dismissed   // proposed reminder the user rejected
    case failed      // a tool failed
    case recording   // meeting in progress
    case processing  // meeting being summarized
    case scheduled   // meeting from the user's real calendar (not stored)
}

struct Entry: Identifiable, Hashable {
    var id: String = UUID().uuidString
    var kind: EntryKind
    var title: String
    var body: String = ""
    var transcript: String = ""
    var startAt: Date = Date()
    var endAt: Date? = nil
    var status: EntryStatus = .done
    var source: String = "hotkey"
    var sessionId: String? = nil
    var parentId: String? = nil
    var meta: [String: String] = [:]
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// Text used for keyword and semantic search.
    var searchText: String {
        var parts = [title, body]
        if kind != .meeting, !transcript.isEmpty, transcript != body { parts.append(transcript) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var isExternal: Bool { status == .scheduled }
}

struct ToolRun: Identifiable, Hashable {
    var id: String = UUID().uuidString
    var entryId: String
    var tool: String
    var args: String
    var result: String
    var status: String
    var latencyMs: Int
    var createdAt: Date = Date()
}

struct MeetingSegment: Hashable {
    var entryId: String
    var tStart: Double
    var tEnd: Double
    var speaker: String
    var text: String
}
