import SwiftUI

/// Reverse-chronological feed of everything: memories, questions, actions, reminders, meetings, dictation.
struct FeedView: View {
    @EnvironmentObject var nav: AppNavigator
    @ObservedObject var store = Store.shared
    @State private var hidden: Set<EntryKind> = []
    @State private var query = ""

    private var entries: [Entry] {
        _ = store.revision
        let all = query.trimmingCharacters(in: .whitespaces).isEmpty ? store.recent(limit: 500) : store.ftsSearch(query, limit: 200)
        return all.filter { !hidden.contains($0.kind) }
    }

    private func feedDate(_ e: Entry) -> Date { e.kind == .reminder ? e.createdAt : e.startAt }

    private var groups: [(day: Date, items: [Entry])] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: entries) { cal.startOfDay(for: feedDate($0)) }
        return dict.keys.sorted(by: >).map { day in (day, dict[day]!.sorted { feedDate($0) > feedDate($1) }) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    PageTitle(accent: "Everything", rest: "you've said.")
                    Spacer()
                    TextField("Search", text: $query).textFieldStyle(.roundedBorder).frame(width: 220)
                }
                KindFilter(hidden: $hidden)
            }
            .padding(.horizontal, 24).padding(.top, 36).padding(.bottom, 16)
            Rectangle().fill(Theme.hairline).frame(height: 1)

            if entries.isEmpty {
                ContentUnavailableView(query.isEmpty ? "Nothing yet" : "No results",
                                       systemImage: query.isEmpty ? "waveform" : "magnifyingglass",
                                       description: Text(query.isEmpty ? "Hold \(Settings.shared.shortcut.displayString) and talk to Flow." : "Try other words."))
                    .frame(maxHeight: .infinity)
            } else {
                // Custom rows instead of List selection: the system highlight is a solid accent fill
                // that hides the colored kind labels. Selection here is a violet wash + edge bar.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.day) { g in
                            Section {
                                ForEach(g.items) { e in
                                    FeedRow(entry: e, selected: nav.selected == e.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture { nav.selected = nav.selected == e.id ? nil : e.id }
                                        .contextMenu { EntryActions(entry: e) }
                                }
                            } header: {
                                MonoLabel(dayTitle(g.day))
                                    .padding(.horizontal, 24).padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.paper)
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .inspector(isPresented: Binding(get: { nav.selected != nil }, set: { if !$0 { nav.selected = nil } })) {
            if let id = nav.selected {
                EntryDetailView(entryId: id).inspectorColumnWidth(min: 300, ideal: 360, max: 480)
            }
        }
    }

    private func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        let date = d.formatted(.dateTime.month(.twoDigits).day(.twoDigits)).replacingOccurrences(of: "/", with: ".")
        if cal.isDateInToday(d) { return "\(date) · Today" }
        if cal.isDateInYesterday(d) { return "\(date) · Yesterday" }
        return "\(date) · " + d.formatted(.dateTime.weekday(.wide))
    }
}

/// Right-click actions shared by the feed and calendar.
struct EntryActions: View {
    let entry: Entry
    var body: some View {
        if entry.kind == .reminder && !entry.isExternal {
            if entry.status == .done {
                Button("Reopen") { Store.shared.update(entry.id) { $0.status = .pending } }
            } else {
                Button("Mark done") { Store.shared.update(entry.id) { $0.status = .done } }
                Button("Snooze 1 hour") {
                    Store.shared.update(entry.id) { $0.startAt = max(Date(), $0.startAt).addingTimeInterval(3600); $0.status = .pending }
                }
            }
            Divider()
        }
        if !entry.isExternal {
            Button("Delete", role: .destructive) {
                let id = entry.id
                Store.shared.delete(id)
                Task { @MainActor in
                    Overlay.shared.result("Deleted", entry.title, style: .info,
                                          actions: [CardAction(title: "Undo") { Store.shared.restore(id) }])
                }
            }
        }
    }
}

struct FeedRow: View {
    let entry: Entry
    var selected = false
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(timeText).font(Theme.mono(11)).foregroundStyle(Theme.muted).frame(width: 64, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.kind.label.uppercased()).font(Theme.mono(10)).tracking(0.6).foregroundStyle(entry.kind.color)
                    StatusChip(entry: entry)
                }
                Text(entry.title).font(Theme.serif(17)).foregroundStyle(Theme.ink).lineLimit(2)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(Theme.muted).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        // Light gray on the row itself (inset, rounded), violet when selected.
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Theme.violetSoft : (hovering ? Theme.hover : Color.clear))
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5).fill(Theme.violet).frame(width: 3).padding(.vertical, 8).opacity(selected ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 24)
        }
        .onHover { hovering = $0 }
    }

    private var subtitle: String {
        switch entry.kind {
        case .reminder: return "Due \(DateResolver.friendly(entry.startAt))" + (entry.body.isEmpty ? "" : " · \(entry.body)")
        case .meeting:
            let mins = entry.endAt.map { Int($0.timeIntervalSince(entry.startAt) / 60) } ?? 0
            return (mins > 0 ? "\(mins) min · " : "") + entry.body.replacingOccurrences(of: "\n", with: " ")
        case .question: return entry.body
        default: return entry.body == entry.title ? "" : entry.body
        }
    }

    private var timeText: String {
        (entry.kind == .reminder ? entry.createdAt : entry.startAt).formatted(date: .omitted, time: .shortened)
    }
}

struct StatusChip: View {
    let entry: Entry
    var body: some View {
        if let (text, color) = info {
            Text(text.uppercased()).font(Theme.mono(9.5)).tracking(0.5)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .foregroundStyle(color)
                .overlay(Rectangle().strokeBorder(color.opacity(0.35)))
        }
    }
    private var info: (String, Color)? {
        switch entry.status {
        case .pending: return ("Upcoming", EntryKind.reminder.color)
        case .proposed: return ("Suggested", .orange)
        case .fired: return ("Reminded", Theme.muted)
        case .missed: return ("Missed", .orange)
        case .failed: return ("Failed", .red)
        case .recording: return ("Recording", .red)
        case .processing: return ("Writing notes", Theme.muted)
        case .scheduled: return ("Calendar", Theme.muted)
        case .done: return entry.kind == .reminder ? ("Done", EntryKind.meeting.color) : nil
        case .dismissed: return nil
        }
    }
}
