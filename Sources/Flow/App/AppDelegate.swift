import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    /// Keeps macOS from App-Napping Flow while it has no visible window; otherwise timers and the
    /// hotkey callback get throttled and Flow looks dead until it's brought to the front.
    private var noNap: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.ensure()
        noNap = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Flow listens for its push-to-talk hotkey and fires reminders")
        ProcessInfo.processInfo.disableAutomaticTermination("Flow runs in the background")
        ProcessInfo.processInfo.disableSuddenTermination()
        _ = Store.shared
        NSApp.setActivationPolicy(.accessory)

        Overlay.shared.setup()
        ModelServers.shared.startAll()
        FlowEngine.shared.start()
        ReminderScheduler.shared.start()
        CalendarWatcher.shared.start()
        LocationService.shared.start()
        // Index everything that isn't searchable yet, once the embedding model is up.
        Task.detached(priority: .utility) {
            if await ModelServers.shared.waitReady(.embed, timeout: 180) { await LocalMemory.shared.backfill(limit: 2000) }
        }
        setupStatusItem()

        let needsSetup = [SystemPermission.microphone, .inputMonitoring, .accessibility].contains { !$0.isGranted }
        if !Settings.shared.onboarded || needsSetup {
            AppNavigator.shared.open(.tools)
            Settings.shared.onboarded = true
        }
        flowLog("Flow launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        if var m = MeetingRecorder.shared.active {
            m.status = .done
            m.endAt = Date()
            m.body = "Flow quit while recording; notes were not generated."
            Store.shared.save(m)
        }
        ModelServers.shared.stopAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppNavigator.shared.showWindow()
        return true
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = LogoRenderer.menuBarImage()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let hint = NSMenuItem(title: "Hold \(Settings.shared.shortcut.displayString) to talk", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        if !HotkeyMonitor.shared.isActive {
            let warn = NSMenuItem(title: "⚠︎ Hotkey inactive — grant permissions", action: #selector(openTools), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }
        menu.addItem(item(FlowEngine.shared.isRecording ? "Stop listening" : "Start listening (without hotkey)", #selector(toggleTalk)))
        menu.addItem(.separator())
        menu.addItem(item("Open Calendar", #selector(openCalendar)))
        menu.addItem(item("Open Feed", #selector(openFeed)))
        menu.addItem(item("System Prompt", #selector(openPrompt)))
        menu.addItem(item("Tools & Permissions", #selector(openTools)))
        menu.addItem(.separator())
        if let m = MeetingRecorder.shared.active {
            menu.addItem(item("Stop recording “\(m.title)”", #selector(toggleMeeting)))
        } else {
            menu.addItem(item("Transcribe a meeting", #selector(toggleMeeting)))
        }
        menu.addItem(.separator())
        let ready = ModelServers.shared.allReady
        let status = NSMenuItem(title: ready ? "Models ready" : "Models loading…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Quit Flow", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func openCalendar() { AppNavigator.shared.open(.calendar) }
    @objc private func openFeed() { AppNavigator.shared.open(.feed) }
    @objc private func openPrompt() { AppNavigator.shared.open(.prompt) }
    @objc private func openTools() { AppNavigator.shared.open(.tools) }
    @objc private func openSettings() { AppNavigator.shared.open(.settings) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleTalk() { FlowEngine.shared.toggleTalk() }
    @objc private func toggleMeeting() {
        Task {
            if MeetingRecorder.shared.active != nil {
                await MeetingRecorder.shared.stop()
            } else {
                let title = CalendarWatcher.shared.currentEventTitle() ?? "Meeting"
                do { _ = try await MeetingRecorder.shared.start(title: title) }
                catch { Overlay.shared.result("Couldn't start recording", error.localizedDescription, style: .error) }
            }
        }
    }
}
