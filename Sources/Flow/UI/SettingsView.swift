import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var servers = ModelServers.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(accent: "Your", rest: "settings.").padding(.horizontal, 24).padding(.top, 36).padding(.bottom, 4)
            form.padding(.horizontal, 4)
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var form: some View {
        Form {
            Section("You") {
                TextField("Your name", text: $settings.userName, prompt: Text(Prompts.name))
                Text("How Flow addresses you and signs emails you ask it to write.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Talk to Flow") {
                LabeledContent("Hotkey") {
                    VStack(alignment: .trailing, spacing: 4) {
                        ShortcutRecorder(shortcut: $settings.shortcut)
                        if let w = settings.shortcut.warning { Text(w).font(.caption).foregroundStyle(.orange) }
                    }
                }
                Text("Hold to talk to Flow. Double-tap to start or stop transcribing a meeting. Press Esc while talking to cancel.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Dictation hotkey") {
                    VStack(alignment: .trailing, spacing: 4) {
                        ShortcutRecorder(shortcut: $settings.dictationShortcut)
                        if settings.dictationShortcut == settings.shortcut {
                            Text("Same as the talk hotkey — pick a different key.").font(.caption).foregroundStyle(.orange)
                        } else if let w = settings.dictationShortcut.warning {
                            Text(w).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                Text("Like Wispr Flow: hold, speak, release — your words are pasted where your cursor is. No commands, no tools.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Bottom popup") {
                Toggle("Show the small pill when idle", isOn: $settings.showIdlePill)
                Stepper("Results stay for \(Int(settings.resultSeconds)) s", value: $settings.resultSeconds, in: 2...30)
                Stepper("Answers stay for \(Int(settings.answerSeconds)) s", value: $settings.answerSeconds, in: 2...60, step: 1)
                Text("Hovering a card keeps it open. Reminders stay until you act on them.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Meetings") {
                Toggle("Offer to record meetings from my calendar when they start", isOn: $settings.promptForMeetings)
            }

            Section("Models (on-device)") {
                ForEach(ModelServers.Kind.allCases) { k in
                    HStack {
                        Circle().fill(color(servers.status[k] ?? .stopped)).frame(width: 8, height: 8)
                        VStack(alignment: .leading) {
                            Text(k.title)
                            Text((servers.status[k] ?? .stopped).label + " · port \(k.port)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restart") { servers.restart(k) }.controlSize(.small)
                    }
                }
                TextField("llama-server path", text: $settings.llamaServerPath, prompt: Text(ModelServers.findLlamaServer() ?? "/opt/homebrew/bin/llama-server"))
                HStack {
                    Button("Show models folder") { NSWorkspace.shared.open(Paths.models) }
                    Button("Show logs") { NSWorkspace.shared.open(Paths.logs) }
                }
            }

            Section("Web search") {
                SecureField("Brave Search API key (optional)", text: $settings.braveAPIKey)
                Text("Without a key, Flow uses DuckDuckGo's HTML results.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Spotify") {
                TextField("Client ID (optional)", text: $settings.spotifyClientId)
                SecureField("Client secret", text: $settings.spotifyClientSecret)
                Text("Lets “play <song>” find the exact track. Create a free app at developer.spotify.com and paste its ID and secret. Without them, Flow finds tracks through web search, or opens Spotify's search results.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Open Flow at login", isOn: $settings.launchAtLogin)
                Text("Reminders pop up only while Flow is running, so keep this on.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func color(_ s: ModelServers.Status) -> Color {
        switch s {
        case .ready: return .green
        case .starting: return .orange
        case .failed, .missingModel: return .red
        case .stopped: return .gray
        }
    }
}

/// Click, then press either a single modifier (release it to confirm) or a key combination.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    @State private var recording = false
    @State private var monitor: Any?
    @State private var pendingModifier: UInt16?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Press a key or modifier…" : shortcut.displayString)
                .font(.system(.body, design: .rounded).weight(.medium))
                .frame(minWidth: 150)
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        pendingModifier = nil
        HotkeyMonitor.shared.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { ev in
            handle(ev)
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
        HotkeyMonitor.shared.paused = false
    }

    private func handle(_ ev: NSEvent) {
        let flags = cgFlags(ev.modifierFlags)
        if ev.type == .flagsChanged {
            let code = ev.keyCode
            guard let info = Shortcut.modifierKeys[code] else { return }
            if flags.contains(info.flag) {
                pendingModifier = flags == info.flag ? code : nil   // only a lone modifier qualifies
            } else if pendingModifier == code {
                shortcut = Shortcut(keyCode: code, modifiers: 0, modifierOnly: true)
                stop()
            }
            return
        }
        if ev.keyCode == 53 && flags.isEmpty { stop(); return }   // Esc cancels
        shortcut = Shortcut(keyCode: ev.keyCode, modifiers: flags.rawValue, modifierOnly: false)
        stop()
    }

    private func cgFlags(_ f: NSEvent.ModifierFlags) -> CGEventFlags {
        var out: CGEventFlags = []
        if f.contains(.command) { out.insert(.maskCommand) }
        if f.contains(.option) { out.insert(.maskAlternate) }
        if f.contains(.control) { out.insert(.maskControl) }
        if f.contains(.shift) { out.insert(.maskShift) }
        if f.contains(.function) { out.insert(.maskSecondaryFn) }
        return out
    }
}
