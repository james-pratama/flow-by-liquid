import SwiftUI

struct EntryDetailView: View {
    let entryId: String
    var fallback: Entry? = nil
    @EnvironmentObject var nav: AppNavigator
    @ObservedObject var store = Store.shared
    @State private var showTranscript = false

    private var entry: Entry? { _ = store.revision; return store.entry(entryId) ?? fallback }

    var body: some View {
        if let e = entry {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(e)
                    if e.kind == .reminder && !e.isExternal { reminderControls(e) }
                    if e.kind == .memory { memoryEditor(e) }
                    if !e.body.isEmpty && !(e.kind == .reminder && !e.isExternal) && e.kind != .memory { section(e.kind == .meeting ? "Notes" : (e.kind == .question ? "Answer" : "Details")) {
                        Text(e.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    } }
                    if e.kind == .meeting && !e.isExternal { meetingSections(e) }
                    if let sources = e.meta["sources"], !sources.isEmpty { section("Sources") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(sources.split(separator: "\n").map(String.init), id: \.self) { s in
                                if let url = URL(string: s), url.scheme?.hasPrefix("http") == true {
                                    Link(s, destination: url).font(.callout).lineLimit(1)
                                } else if s.hasPrefix("/") {
                                    Button(s) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s)]) }
                                        .buttonStyle(.link).font(.callout).lineLimit(1)
                                } else {
                                    Text(s).font(.callout).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } }
                    if let steps = e.meta["steps"], !steps.isEmpty { section("How Flow worked it out") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(steps.split(separator: "\n").enumerated()), id: \.offset) { _, s in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.violet)
                                    Text(String(s)).font(.callout).foregroundStyle(.secondary)
                                }
                            }
                            if let reasoning = e.meta["reasoning"], !reasoning.isEmpty {
                                DisclosureGroup("Reasoning") {
                                    Text(reasoning).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                                }
                                .font(.callout)
                            }
                        }
                    } }
                    if !e.transcript.isEmpty && e.kind != .meeting { section("You said") {
                        Text("“\(e.transcript)”").italic().foregroundStyle(.secondary).textSelection(.enabled)
                    } }
                    toolRuns(e)
                    diagnostics(e)
                    if !e.isExternal {
                        Button(role: .destructive) { store.delete(e.id); nav.selected = nil } label: { Label("Delete", systemImage: "trash") }
                            .padding(.top, 8)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Not found", systemImage: "questionmark")
        }
    }

    private func header(_ e: Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                MonoLabel(e.kind.label, color: e.kind.color)
                StatusChip(entry: e)
                Spacer()
                Button { nav.selected = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            if (e.kind == .reminder || e.kind == .memory) && !e.isExternal {
                TextField(e.kind == .memory ? "Memory" : "Reminder", text: Binding(get: { e.title }, set: { v in store.update(e.id) { $0.title = v } }), axis: .vertical)
                    .font(Theme.serif(22)).textFieldStyle(.plain)
            } else {
                Text(e.title).font(Theme.serif(22)).foregroundStyle(Theme.ink).textSelection(.enabled)
            }
            Text(timeRange(e)).font(Theme.mono(11)).foregroundStyle(Theme.muted)
        }
    }

    private func timeRange(_ e: Entry) -> String {
        let d = e.startAt.formatted(.dateTime.weekday(.wide).month().day().hour().minute())
        if let end = e.endAt, end > e.startAt { return "\(d) – \(end.formatted(date: .omitted, time: .shortened))" }
        return d
    }

    @ViewBuilder
    private func memoryEditor(_ e: Entry) -> some View {
        section("What Flow remembers") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Memory", text: Binding(get: { e.body }, set: { v in store.update(e.id) { $0.body = v } }), axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...8)
                    .onSubmit { if let m = store.entry(e.id) { LocalMemory.shared.index(m) } }
                if let edited = e.meta["edited"] {
                    Text("Edited by voice " + String(edited.prefix(10))).font(.caption).foregroundStyle(.secondary)
                }
                Text("Edit in place, or say “update my memory about …”.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func reminderControls(_ e: Entry) -> some View {
        section("Remind me") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Notes", text: Binding(get: { e.body }, set: { v in store.update(e.id) { $0.body = v } }), axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
                DatePicker("", selection: Binding(get: { e.startAt }, set: { d in
                    store.update(e.id) { $0.startAt = d; if $0.status == .fired || $0.status == .missed { $0.status = .pending } }
                }))
                .labelsHidden()
                if let spoken = e.meta["spoken_time"], !spoken.isEmpty {
                    Text("You said “\(spoken)”\(e.meta["time_guessed"] == "true" ? " — no time given, so Flow picked one" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if e.status == .proposed {
                        Button("Add reminder") { store.update(e.id) { $0.status = .pending } }.buttonStyle(.pill)
                        Button("Dismiss") { store.update(e.id) { $0.status = .dismissed } }
                    } else if e.status != .done {
                        Button("Mark done") { store.update(e.id) { $0.status = .done } }
                    } else {
                        Button("Reopen") { store.update(e.id) { $0.status = .pending } }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func meetingSections(_ e: Entry) -> some View {
        let kids = store.children(of: e.id)
        if !kids.isEmpty {
            section("Your commitments") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(kids) { k in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: k.status == .done ? "checkmark.circle.fill" : (k.status == .dismissed ? "xmark.circle" : "bell"))
                                .foregroundStyle(k.status == .dismissed ? Color.secondary : EntryKind.reminder.color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(k.title).strikethrough(k.status == .dismissed)
                                Text(DateResolver.friendly(k.startAt)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if k.status == .proposed {
                                Button("Add") { store.update(k.id) { $0.status = .pending } }.controlSize(.small)
                                Button("Dismiss") { store.update(k.id) { $0.status = .dismissed } }.controlSize(.small)
                            } else {
                                StatusChip(entry: k)
                            }
                        }
                    }
                    if kids.contains(where: { $0.status == .proposed }) {
                        Button("Add all") { kids.filter { $0.status == .proposed }.forEach { k in store.update(k.id) { $0.status = .pending } } }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            }
        }
        let segs = store.segments(e.id)
        if !segs.isEmpty {
            DisclosureGroup("Transcript (\(segs.count) segments)", isExpanded: $showTranscript) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(segs.enumerated()), id: \.offset) { _, s in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(String(format: "%02d:%02d", Int(s.tStart) / 60, Int(s.tStart) % 60))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(s.speaker).font(.caption.weight(.bold))
                                .foregroundStyle(s.speaker == "Me" ? EntryKind.meeting.color : .secondary)
                            Text(s.text).font(.callout).textSelection(.enabled)
                        }
                    }
                }
                .padding(.top, 6)
            }
            .font(.subheadline.weight(.semibold))
        }
        if e.status == .done {
            Button {
                Task { await FlowEngine.shared.handle("Send a recap of the meeting \(e.title)", focus: nil) }
            } label: { Label("Draft recap email", systemImage: "envelope") }
        }
    }

    @ViewBuilder
    private func toolRuns(_ e: Entry) -> some View {
        let runs = store.toolRuns(entryId: e.id)
        if !runs.isEmpty {
            section("Tool calls") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(runs) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(r.tool).font(.caption.monospaced().weight(.semibold))
                                Text("\(r.latencyMs) ms").font(.caption).foregroundStyle(.secondary)
                                if r.status != "ok" { Text(r.status).font(.caption).foregroundStyle(.red) }
                            }
                            Text(r.args).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func diagnostics(_ e: Entry) -> some View {
        let parts = [e.meta["asr_ms"].map { "Speech \($0) ms" }, e.meta["route_ms"].map { "Router \($0) ms" },
                     e.meta["harness"].map { "Harness: \($0)" }].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MonoLabel(title)
            content()
        }
    }
}
