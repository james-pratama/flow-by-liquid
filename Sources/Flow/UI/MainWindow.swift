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
            w.title = "Flow"
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
            w.setFrameAutosaveName("FlowMain")
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
            List(AppTab.allCases, selection: Binding(get: { nav.tab }, set: { if let t = $0 { nav.tab = t } })) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
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
        .tint(Theme.violet)
    }

    private var wordmark: some View {
        HStack(spacing: 6) {
            LiquidMark().fill(Theme.ink).frame(width: 18, height: 22)
            Text("Flow").font(Theme.serif(22)).foregroundStyle(Theme.ink)
            Text("by Liquid").font(Theme.mono(10)).foregroundStyle(Theme.muted).padding(.top, 5)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let m = recorder.active {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("Recording \(m.title)").font(.caption).lineLimit(1)
                    Spacer()
                    Button("Stop") { Task { await MeetingRecorder.shared.stop() } }.controlSize(.small)
                }
            }
            MonoLabel(servers.allReady ? "LFM2.5 on-device · ready" : "Loading models…",
                      color: servers.allReady ? Theme.violet : .orange)
            Text("Hold \(settings.shortcut.displayString) to talk\nHold \(settings.dictationShortcut.displayString) to dictate\nDouble-tap \(settings.shortcut.displayString) to record a meeting")
                .font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Kind colours shared by the calendar, feed and detail views.
extension EntryKind {
    var color: Color {
        switch self {
        case .memory: return Theme.violet                                   // #7C3AED
        case .question: return Color(red: 0.15, green: 0.39, blue: 0.92)    // #2563EB
        case .action: return Color(red: 0.85, green: 0.47, blue: 0.02)      // #D97706
        case .reminder: return Color(red: 0.88, green: 0.11, blue: 0.28)    // #E11D48
        case .meeting: return Color(red: 0.02, green: 0.59, blue: 0.41)     // #059669
        case .dictation: return Color(red: 0.44, green: 0.44, blue: 0.48)   // #71717A
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
                        Rectangle().fill(k.color).frame(width: 6, height: 6)
                        Text(k.label.uppercased()).font(Theme.mono(10)).tracking(0.6).lineLimit(1).fixedSize()
                            .foregroundStyle(on ? Theme.ink : Theme.muted)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Rectangle().fill(on ? k.color.opacity(0.08) : Color.clear))
                    .overlay(Rectangle().strokeBorder(on ? k.color.opacity(0.35) : Theme.hairline))
                    .opacity(on ? 1 : 0.55)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
