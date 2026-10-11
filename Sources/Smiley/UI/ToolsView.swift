import SwiftUI

/// The tools Smiley can use on the user's behalf, their policies, and the macOS permissions behind them.
struct ToolsView: View {
    @ObservedObject var store = Store.shared
    @State private var granted: [SystemPermission: Bool] = [:]
    @State private var hotkeyActive = HotkeyMonitor.shared.isActive
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    PageTitle(accent: "What", rest: "Smiley can do.")
                    Text("The tools Smiley uses on your behalf, and what it needs from macOS to use them.").foregroundStyle(Theme.muted)
                }

                if SystemPermission.allCases.contains(where: { granted[$0] == false }) {
                    Label("Grant the permissions below so Smiley can hear your hotkey, paste for you and capture calls.",
                          systemImage: "hand.wave")
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accentSoft))
                }

                HotkeyStatusBox(hotkeyActive: hotkeyActive)

                GroupBox {
                    VStack(spacing: 0) {
                        ForEach(SystemPermission.allCases) { p in
                            PermissionRow(permission: p, granted: granted[p] ?? false)
                            if p != SystemPermission.allCases.last { Divider() }
                        }
                    }
                } label: { SectionLabel("macOS permissions") }

                GroupBox {
                    VStack(spacing: 0) {
                        let counts = store.runCounts()
                        ForEach(ToolRegistry.all, id: \.name) { tool in
                            ToolRow(tool: tool, runs: counts[tool.name] ?? 0, granted: granted)
                            if tool.name != ToolRegistry.all.last?.name { Divider() }
                        }
                    }
                } label: { SectionLabel("Tools") }

                Text("“Ask first” shows a confirmation in the bottom popup before the tool runs. Smiley never sends messages on its own; drafts open in your mail app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24).padding(.top, 36).padding(.bottom, 24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollContentBackground(.hidden)
        .groupBoxStyle(.soft)
        .onAppear(perform: update)
        .onReceive(refresh) { _ in update() }
    }

    private func update() {
        for p in SystemPermission.allCases { granted[p] = p.isGranted }
        hotkeyActive = HotkeyMonitor.shared.isActive
    }
}

struct HotkeyStatusBox: View {
    let hotkeyActive: Bool
    @ObservedObject var settings = Settings.shared

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(hotkeyActive ? Theme.good : Theme.warn).frame(width: 9, height: 9)
                    Text(hotkeyActive ? "Listening for \(settings.shortcut.displayString) in every app" : "Hotkey only works while Smiley is in front")
                        .font(.body.weight(.medium))
                    Spacer()
                    Button("Test microphone") { SmileyEngine.shared.toggleTalk() }.buttonStyle(.pillOutline)
                }
                if !hotkeyActive {
                    Text("""
                    macOS only lets Smiley hear the hotkey in other apps with Input Monitoring.
                    1. Click Allow… next to Input Monitoring below. System Settings opens on the right page.
                    2. Turn Smiley on. If Smiley isn't in the list, click +, then pick Smiley.app (“Show Smiley.app” reveals it).
                    3. If macOS asks to quit & reopen Smiley, do it. The dot turns green once it works everywhere.
                    """)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Show Smiley.app in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                } else {
                    Text("Hold \(settings.shortcut.displayString), speak, and let go — the pill at the bottom of the screen shows a level meter while you talk. Double-tap \(settings.shortcut.displayString) to start or stop transcribing a meeting.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
        } label: { SectionLabel("Push-to-talk") }
    }
}

struct PermissionRow: View {
    let permission: SystemPermission
    let granted: Bool
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: permission.symbol).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(.body.weight(.medium))
                Text(permission.why).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good).font(.callout)
            } else {
                Button("Allow…") { Task { await permission.request() } }
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 6)
    }
}

struct ToolRow: View {
    let tool: SmileyTool
    let runs: Int
    let granted: [SystemPermission: Bool]
    @ObservedObject var store = Store.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: tool.symbol).frame(width: 22).foregroundStyle(Color.accentColor).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(tool.title).font(.body.weight(.medium))
                    Text(tool.risk.rawValue).font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(riskColor.opacity(0.15))).foregroundStyle(riskColor)
                    Text(tool.name).font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
                Text(tool.summary).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(tool.permissions) { p in
                        Label(p.title, systemImage: granted[p] == true ? "checkmark.circle" : "exclamationmark.circle")
                            .font(.caption).foregroundStyle(granted[p] == true ? Color.secondary : Theme.warn)
                    }
                    if runs > 0 { Text("Used \(runs)×").font(.caption).foregroundStyle(.tertiary) }
                }
            }
            Spacer()
            Picker("", selection: Binding(get: { _ = store.revision; return tool.policy }, set: { store.setPolicy(tool.name, $0) })) {
                ForEach(ToolPolicy.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
        }
        .padding(.vertical, 10).padding(.horizontal, 6)
    }

    private var riskColor: Color {
        switch tool.risk {
        case .read: return Theme.good
        case .reversible: return Theme.calm
        case .outward: return Theme.warn
        }
    }
}
