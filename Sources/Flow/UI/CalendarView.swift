import SwiftUI

/// Google Calendar–style week view of everything Flow knows about.
struct CalendarView: View {
    @EnvironmentObject var nav: AppNavigator
    @ObservedObject var store = Store.shared
    @ObservedObject var calendars = CalendarWatcher.shared
    /// The calendar shows what's scheduled or kept by default; conversational items are opt-in.
    @State private var hidden: Set<EntryKind> = [.question, .action, .dictation]
    private let filterOrder: [EntryKind] = [.memory, .reminder, .meeting, .question, .action, .dictation]

    private let hourHeight: CGFloat = 52
    private let gutter: CGFloat = 54
    private var cal: Calendar { Calendar.current }
    private var weekStart: Date { cal.dateInterval(of: .weekOfYear, for: nav.focusDate)?.start ?? cal.startOfDay(for: nav.focusDate) }
    private var days: [Date] { (0..<7).map { cal.date(byAdding: .day, value: $0, to: weekStart)! } }

    private var entries: [Entry] {
        _ = store.revision
        let end = cal.date(byAdding: .day, value: 7, to: weekStart)!
        let own = store.entries(from: weekStart, to: end)
        // Hide calendar events that Flow recorded (the recording replaces them).
        let recordedEvents = Set(own.compactMap { $0.meta["event_id"] })
        let external = calendars.entries(from: weekStart, to: end).filter { !recordedEvents.contains($0.meta["event_id"] ?? "") }
        return (own + external).filter { !hidden.contains($0.kind) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header.fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            dayHeader.fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    grid.id("grid")
                }
                .onAppear { DispatchQueue.main.async { proxy.scrollTo("h7", anchor: .top) } }
            }
        }
        .inspector(isPresented: Binding(get: { nav.selected != nil }, set: { if !$0 { nav.selected = nil } })) {
            if let id = nav.selected {
                EntryDetailView(entryId: id, fallback: entries.first { $0.id == id })
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                PageTitle(accent: "Your", rest: "week.")
                MonoLabel(weekTitle)
                Spacer()
                HStack(spacing: 6) {
                    Button { shift(-7) } label: { Image(systemName: "chevron.left") }.buttonStyle(.pillOutline)
                    Button("Today") { nav.focusDate = Date() }.buttonStyle(.pill)
                    Button { shift(7) } label: { Image(systemName: "chevron.right") }.buttonStyle(.pillOutline)
                }
            }
            KindFilter(hidden: $hidden, kinds: filterOrder)
        }
        .padding(.horizontal, 24).padding(.bottom, 14)
        .padding(.top, 36)
    }

    private var weekTitle: String {
        let end = cal.date(byAdding: .day, value: 6, to: weekStart)!
        let sameMonth = cal.component(.month, from: weekStart) == cal.component(.month, from: end)
        let a = weekStart.formatted(.dateTime.month(.abbreviated).day())
        let b = sameMonth ? end.formatted(.dateTime.day()) : end.formatted(.dateTime.month(.abbreviated).day())
        return "\(a) – \(b), \(end.formatted(.dateTime.year()))"
    }

    private func shift(_ days: Int) { nav.focusDate = cal.date(byAdding: .day, value: days, to: nav.focusDate)! }

    private var dayHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter)
            ForEach(days, id: \.self) { d in
                let today = cal.isDateInToday(d)
                VStack(spacing: 2) {
                    Text(d.formatted(.dateTime.weekday(.abbreviated)).uppercased()).font(Theme.mono(10)).tracking(0.8)
                        .foregroundStyle(today ? Theme.violet : Theme.muted)
                    Text(d.formatted(.dateTime.day())).font(Theme.serif(20))
                        .foregroundStyle(today ? .white : Theme.ink)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(today ? Theme.violet : .clear))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            let colW = (geo.size.width - gutter) / 7
            ZStack(alignment: .topLeading) {
                // Hour rows (laid out, not offset, so ScrollViewReader can jump to them)
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { h in
                        HStack(alignment: .top, spacing: 0) {
                            Text(h > 0 ? hourLabel(h) : "").font(Theme.mono(9.5)).foregroundStyle(Theme.muted)
                                .frame(width: gutter - 8, alignment: .trailing)
                                .offset(y: -7)
                            Spacer().frame(width: 8)
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                        }
                        .frame(height: hourHeight, alignment: .top)
                        .id("h\(h)")
                    }
                }
                // Day separators
                ForEach(0..<8, id: \.self) { i in
                    Path { p in
                        let x = gutter + CGFloat(i) * colW
                        p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: hourHeight * 24))
                    }
                    .stroke(Theme.hairline, lineWidth: 1)
                }
                // Entries
                ForEach(Array(days.enumerated()), id: \.offset) { idx, day in
                    ForEach(layout(for: day)) { p in
                        let x = gutter + CGFloat(idx) * colW + 2 + CGFloat(p.col) * (colW - 4) / CGFloat(p.cols)
                        let w = (colW - 4) / CGFloat(p.cols) - 2
                        EventBlock(entry: p.entry, selected: nav.selected == p.entry.id, height: p.height)
                            .frame(width: max(w, 10), height: p.height)
                            .offset(x: x, y: p.y)
                            .onTapGesture { nav.selected = p.entry.id }
                            .contextMenu { EntryActions(entry: p.entry) }
                    }
                }
                // Now line
                if let idx = days.firstIndex(where: { cal.isDateInToday($0) }) {
                    TimelineView(.periodic(from: .now, by: 60)) { ctx in
                        let y = yFor(ctx.date)
                        let x = gutter + CGFloat(idx) * colW
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Theme.violet).frame(width: colW, height: 1.5)
                            Circle().fill(Theme.violet).frame(width: 9, height: 9).offset(x: -4.5)
                        }
                        .offset(x: x, y: y - 0.75)
                    }
                }
            }
        }
        .frame(height: hourHeight * 24)
    }

    private func hourLabel(_ h: Int) -> String {
        var c = DateComponents(); c.hour = h
        return (cal.date(from: c) ?? Date()).formatted(.dateTime.hour())
    }

    private func yFor(_ d: Date) -> CGFloat {
        let c = cal.dateComponents([.hour, .minute], from: d)
        return (CGFloat(c.hour ?? 0) + CGFloat(c.minute ?? 0) / 60) * hourHeight
    }

    struct Placed: Identifiable {
        let entry: Entry
        var col: Int
        var cols: Int
        let y: CGFloat
        let height: CGFloat
        var id: String { entry.id }
    }

    /// Places a day's entries, splitting overlapping ones into side-by-side columns.
    private func layout(for day: Date) -> [Placed] {
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!
        let minSpan: TimeInterval = 25 * 60
        let items = entries.filter { $0.startAt < dayEnd && ($0.endAt ?? $0.startAt) >= dayStart }
            .sorted { $0.startAt < $1.startAt }
        var placed: [Placed] = []
        var cluster: [Int] = []
        var colEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func closeCluster() {
            let n = max(1, colEnds.count)
            for i in cluster { placed[i].cols = n }
            cluster = []; colEnds = []
        }

        for e in items {
            let start = max(e.startAt, dayStart)
            let rawEnd = min(e.endAt ?? e.startAt, dayEnd)
            let end = max(rawEnd, start.addingTimeInterval(minSpan))
            if start >= clusterEnd { closeCluster() }
            let col = colEnds.firstIndex { $0 <= start } ?? colEnds.count
            if col == colEnds.count { colEnds.append(end) } else { colEnds[col] = end }
            clusterEnd = max(clusterEnd, end)
            let y = yFor(start)
            let h = max(CGFloat(end.timeIntervalSince(start) / 3600) * hourHeight - 2, 20)
            placed.append(Placed(entry: e, col: col, cols: 1, y: y, height: h))
            cluster.append(placed.count - 1)
        }
        closeCluster()
        return placed
    }
}

struct EventBlock: View {
    let entry: Entry
    let selected: Bool
    let height: CGFloat

    var body: some View {
        let c = entry.kind.color
        let external = entry.status == .scheduled
        let proposed = entry.status == .proposed
        HStack(spacing: 0) {
            Rectangle().fill(c).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Image(systemName: entry.kind.symbol).font(.system(size: 8, weight: .bold))
                    Text(entry.title).font(.system(size: 11, weight: .medium)).lineLimit(height > 36 ? 2 : 1)
                }
                if height > 34 {
                    Text(timeText).font(Theme.mono(9.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            .foregroundStyle(c.opacity(0.95))
            .padding(.horizontal, 4).padding(.vertical, 2)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 3).fill(external ? c.opacity(0.07) : c.opacity(selected ? 0.32 : 0.16)))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(style: StrokeStyle(lineWidth: selected ? 1.5 : 1, dash: entry.kind == .reminder || proposed || external ? [3, 2] : []))
                .foregroundStyle(c.opacity(selected ? 0.9 : 0.4))
        )
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .opacity(proposed || entry.status == .done && entry.kind == .reminder ? 0.6 : 1)
        .contentShape(Rectangle())
        .help(entry.title)
    }

    private var timeText: String {
        let s = entry.startAt.formatted(date: .omitted, time: .shortened)
        if let e = entry.endAt, e > entry.startAt { return "\(s) – \(e.formatted(date: .omitted, time: .shortened))" }
        return s
    }
}
