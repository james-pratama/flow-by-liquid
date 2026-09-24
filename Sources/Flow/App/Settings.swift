import Foundation
import ServiceManagement

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var shortcut: Shortcut {
        didSet {
            if let data = try? JSONEncoder().encode(shortcut) { d.set(data, forKey: "shortcut") }
            HotkeyMonitor.shared.update(shortcut)
        }
    }
    /// Wispr-style dictation: hold, speak, release → pasted where the cursor is. No agent.
    @Published var dictationShortcut: Shortcut {
        didSet {
            if let data = try? JSONEncoder().encode(dictationShortcut) { d.set(data, forKey: "dictationShortcut") }
            HotkeyMonitor.shared.update(dictationShortcut, for: .dictation)
        }
    }
    @Published var showIdlePill: Bool { didSet { d.set(showIdlePill, forKey: "showIdlePill") } }
    @Published var resultSeconds: Double { didSet { d.set(resultSeconds, forKey: "resultSeconds") } }
    @Published var answerSeconds: Double { didSet { d.set(answerSeconds, forKey: "answerSeconds") } }
    @Published var llamaServerPath: String { didSet { d.set(llamaServerPath, forKey: "llamaServerPath") } }
    /// How Flow addresses you and signs emails. Empty = the macOS account's first name.
    @Published var userName: String { didSet { d.set(userName, forKey: "userName") } }
    @Published var braveAPIKey: String { didSet { d.set(braveAPIKey, forKey: "braveAPIKey") } }
    @Published var promptForMeetings: Bool { didSet { d.set(promptForMeetings, forKey: "promptForMeetings") } }
    @Published var launchAtLogin: Bool {
        didSet {
            d.set(launchAtLogin, forKey: "launchAtLogin")
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { flowLog("launch at login: \(error.localizedDescription)") }
        }
    }
    var onboarded: Bool {
        get { d.bool(forKey: "onboarded") }
        set { d.set(newValue, forKey: "onboarded") }
    }

    private init() {
        shortcut = d.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default
        dictationShortcut = d.data(forKey: "dictationShortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
            ?? .defaultDictation
        showIdlePill = d.object(forKey: "showIdlePill") as? Bool ?? true
        resultSeconds = d.object(forKey: "resultSeconds") as? Double ?? 5
        answerSeconds = d.object(forKey: "answerSeconds") as? Double ?? 5
        llamaServerPath = d.string(forKey: "llamaServerPath") ?? ""
        braveAPIKey = d.string(forKey: "braveAPIKey") ?? ""
        userName = d.string(forKey: "userName") ?? ""
        promptForMeetings = d.object(forKey: "promptForMeetings") as? Bool ?? true
        launchAtLogin = d.object(forKey: "launchAtLogin") as? Bool ?? false
    }
}
