import AppKit
import ServiceManagement

/// One-time carry-over from the app's previous name and bundle IDs: quits the old copy, then moves its data
/// folder, database and settings over so memories, models and hotkeys survive the rename.
/// Does nothing once that is done. Safe to delete after every install has launched once.
enum LegacyMigration {
    private static let oldName = "Flow"
    /// Newest first: settings are taken from the most recent one that exists.
    private static let oldBundleIds = ["ai.liquid.smiley", "ai.liquid.flow"]

    static func run() {
        // Tests point SMILEY_HOME at a scratch folder and must never touch the real data.
        guard ProcessInfo.processInfo.environment["SMILEY_HOME"] == nil else { return }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent(oldName, isDirectory: true)
        let new = base.appendingPathComponent("Smiley", isDirectory: true)

        // The old copy holds the database open and listens for the same hotkeys.
        guard quitOldApp() else { return }

        if fm.fileExists(atPath: old.path) {
            try? fm.createDirectory(at: new, withIntermediateDirectories: true)
            for item in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] {
                let to = new.appendingPathComponent(item)
                // A folder a test run created empty (models/, logs/) shouldn't block the real one.
                if (try? fm.contentsOfDirectory(atPath: to.path))?.isEmpty == true { try? fm.removeItem(at: to) }
                if !fm.fileExists(atPath: to.path) { try? fm.moveItem(at: old.appendingPathComponent(item), to: to) }
            }
            if (try? fm.contentsOfDirectory(atPath: old.path))?.isEmpty == true { try? fm.removeItem(at: old) }
        }
        let renames = ["", "-wal", "-shm"].map { ("flow.sqlite\($0)", "smiley.sqlite\($0)") } + [("logs/flow.log", "logs/smiley.log")]
        if !fm.fileExists(atPath: new.appendingPathComponent("smiley.sqlite").path) {
            for (from, to) in renames {
                try? fm.moveItem(at: new.appendingPathComponent(from), to: new.appendingPathComponent(to))
            }
        }

        // Settings live under the bundle ID, which changed with the name.
        let d = UserDefaults.standard
        if Bundle.main.bundleIdentifier != nil, !d.bool(forKey: "migratedSettings") {
            let previous = oldBundleIds.lazy.compactMap { d.persistentDomain(forName: $0) }.first ?? [:]
            for (key, value) in previous where d.object(forKey: key) == nil && !key.hasPrefix("NS") && key != "migratedSettings" {
                d.set(value, forKey: key)
            }
            d.set(true, forKey: "migratedSettings")
            // The login item belonged to the old bundle; register this one in its place.
            if d.bool(forKey: "launchAtLogin") { try? SMAppService.mainApp.register() }
        }
        // Prompts edited in the System Prompt tab are stored whole, so they still address the assistant by its old name.
        if Bundle.main.bundleIdentifier != nil, !d.bool(forKey: "migratedPromptNames") {
            for (key, value) in d.dictionaryRepresentation() where key.hasPrefix("prompt.") {
                guard let text = value as? String else { continue }
                d.set(text.replacingOccurrences(of: #"(?<!Wispr )\bFlow\b"#, with: "Smiley", options: .regularExpression), forKey: key)
            }
            d.set(true, forKey: "migratedPromptNames")
        }
    }

    /// false if the old copy is still running after being asked (then forced) to quit.
    private static func quitOldApp() -> Bool {
        let running = oldBundleIds.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        guard !running.isEmpty else { return true }
        running.forEach { $0.terminate() }
        if wait(for: running, seconds: 5) { return true }
        running.forEach { $0.forceTerminate() }
        return wait(for: running, seconds: 2)
    }

    private static func wait(for apps: [NSRunningApplication], seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if apps.allSatisfy(\.isTerminated) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return apps.allSatisfy(\.isTerminated)
    }
}
