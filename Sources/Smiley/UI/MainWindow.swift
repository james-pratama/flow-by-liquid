import AppKit
import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case calendar, feed, prompt, tools, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .calendar: return "Calendar"
        case .feed: return "Feed"
        case .prompt: return "System Prompt"
        case .tools: return "Tools & Permissions"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .calendar: return "calendar"
        case .feed: return "list.bullet.rectangle"
        case .prompt: return "text.bubble"
        case .tools: return "wrench.and.screwdriver"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
final class AppNavigator: ObservableObject {
    static let shared = AppNavigator()
    @Published var tab: AppTab = .calendar
    @Published var selected: String?
    @Published var focusDate = Date()
    private var window: NSWindow?

    func open(_ tab: AppTab, entry: String? = nil) {
        self.tab = tab
        selected = entry
        if let id = entry, let e = Store.shared.entry(id) { focusDate = e.startAt }
        showWindow()
    }

    /// Keeps the window within the screen it's on (never taller than the visible area).
    static func fitToScreen(_ w: NSWindow) {
        guard let vf = (w.screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = w.frame
        f.size.width = min(f.width, vf.width)
        f.size.height = min(f.height, vf.height)
        f.origin.x = min(max(f.minX, vf.minX), vf.maxX - f.width)
        f.origin.y = min(max(f.minY, vf.minY), vf.maxY - f.height)
        if f != w.frame { w.setFrame(f, display: true) }
    }

    func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Smiley"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 900, height: 560)
            let host = NSHostingController(rootView: MainView().environmentObject(self))
            // Don't let tall content (e.g. a long prompt) resize the window past the screen.
            host.sizingOptions = []
            w.contentViewController = host
            if let vf = NSScreen.main?.visibleFrame {
                w.setContentSize(NSSize(width: min(1240, vf.width - 80), height: min(800, vf.height - 60)))
            }
            w.center()
            w.setFrameAutosaveName("SmileyMain")
            NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { AppNavigator.fitToScreen(w) }
            }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
            }
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        if let w = window { Self.fitToScreen(w) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MainView: View {
    @EnvironmentObject var nav: AppNavigator
    @ObservedObject var servers = ModelServers.shared
    @ObservedObject var settings = Settings.shared
    @ObservedObject var recorder = MeetingRecorder.shared

    var body: some View {
        NavigationSplitView {
            // Rows draw their own selection: the system highlight uses the Mac's accent colour, not Smiley's.
            List(AppTab.allCases) { tab in
                let selected = nav.tab == tab
                Button { nav.tab = tab } label: {
                    Label(tab.title, systemImage: tab.symbol)
                        .font(Theme.title(13.5, selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.accent : Theme.ink.opacity(0.8))
                        .padding(.vertical, 5).padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Theme.accentSoft : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
            }
            .scrollContentBackground(.hidden)
            .background(Theme.wash)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .top) { wordmark }
            .safeAreaInset(edge: .bottom) { statusFooter }
        } detail: {
            ZStack(alignment: .topLeading) {
                Theme.paper.ignoresSafeArea()
                Group {
                    switch nav.tab {
                    case .calendar: CalendarView()
                    case .feed: FeedView()
                    case .tools: ToolsView()
                    case .prompt: PromptsView()
                    case .settings: SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .tint(Theme.accent)
    }

    private var wordmark: some View {
        HStack(spacing: 6) {
            SmileyPortrait().frame(width: 26, height: 24)
            Text("Smiley").font(Theme.title(21, .bold)).foregroundStyle(Theme.ink)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let m = recorder.active {
                HStack(spacing: 6) {
                    Circle().fill(Theme.bad).frame(width: 7, height: 7)
                    Text("Recording \(m.title)").font(.caption).lineLimit(1)
                    Spacer()
                    Button("Stop") { Task { await MeetingRecorder.shared.stop() } }.controlSize(.small)
                }
            }
            SectionLabel(servers.allReady ? "On-device · ready" : "Loading models…",
                      color: servers.allReady ? Theme.accent : Theme.warn)
            Text("Hold \(settings.shortcut.displayString) to talk\nHold \(settings.dictationShortcut.displayString) to dictate\nDouble-tap \(settings.shortcut.displayString) to record a meeting")
                .font(Theme.label(10.5)).foregroundStyle(Theme.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Kind colours shared by the calendar, feed and detail views.
extension EntryKind {
    var color: Color {
        switch self {
        // Muted, but dark enough to read as text on their own tint.
        case .memory: return Theme.accent                                   // dusty rose
        case .question: return Theme.calm                                   // dusty blue
        case .action: return Color(red: 0.72, green: 0.50, blue: 0.23)      // ochre
        case .reminder: return Theme.bad                                    // soft coral
        case .meeting: return Color(red: 0.29, green: 0.58, blue: 0.46)     // sage
        case .dictation: return Color(red: 0.53, green: 0.49, blue: 0.50)   // warm grey
        }
    }
}

struct KindFilter: View {
    @Binding var hidden: Set<EntryKind>
    /// Chip order, left to right.
    var kinds: [EntryKind] = EntryKind.allCases
    var body: some View {
        HStack(spacing: 6) {
            ForEach(kinds) { k in
                let on = !hidden.contains(k)
                Button {
                    if on { hidden.insert(k) } else { hidden.remove(k) }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(k.color).frame(width: 6, height: 6)
                        Text(k.label).font(Theme.label(11.5)).lineLimit(1).fixedSize()
                            .foregroundStyle(on ? Theme.ink : Theme.muted)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(on ? k.color.opacity(0.1) : Color.clear))
                    .overlay(Capsule().strokeBorder(on ? k.color.opacity(0.3) : Theme.hairline))
                    .opacity(on ? 1 : 0.55)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
