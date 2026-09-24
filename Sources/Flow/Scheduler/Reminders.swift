import AppKit
import Combine
import EventKit

/// Fires reminder cards in the bottom popup. Flow runs from login, so an in-app timer is enough;
/// reminders that came due while Flow wasn't running are shown as "missed" on launch.
@MainActor
final class ReminderScheduler {
    static let shared = ReminderScheduler()
    private var timer: Timer?
    private var bag: Set<AnyCancellable> = []
    private var shown: Set<String> = []

    func start() {
        markMissed()
        Store.shared.$revision
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reschedule() }
            .store(in: &bag)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        reschedule()
    }

    private func markMissed() {
        let cutoff = Date().addingTimeInterval(-5 * 60)
        let missed = Store.shared.pendingReminders().filter { $0.startAt < cutoff }
        for r in missed {
            Store.shared.update(r.id) { $0.status = .missed }
        }
        if missed.count == 1, let r = missed.first {
            show(r, missed: true)
        } else if missed.count > 1 {
            Overlay.shared.show(Card(style: .reminder, symbol: "bell.badge.fill", title: "\(missed.count) missed reminders",
                                     body: missed.map { "• \($0.title) — \(DateResolver.friendly($0.startAt))" }.joined(separator: "\n"),
                                     actions: [CardAction(title: "Open calendar", primary: true) { AppNavigator.shared.open(.calendar) }],
                                     priority: 1, seconds: nil))
        }
    }

    func reschedule() {
        timer?.invalidate()
        guard let next = Store.shared.pendingReminders().first else { return }
        let wait = max(0.2, next.startAt.timeIntervalSinceNow)
        timer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func check() {
        let now = Date()
        for r in Store.shared.pendingReminders() where r.startAt <= now.addingTimeInterval(1) {
            let late = now.timeIntervalSince(r.startAt) > 5 * 60
            Store.shared.update(r.id) { $0.status = late ? .missed : .fired }
            show(r, missed: late)
        }
        reschedule()
    }

    private func show(_ r: Entry, missed: Bool) {
        guard shown.insert(r.id + (missed ? "m" : "")).inserted else { return }
        let id = r.id
        Overlay.shared.show(Card(
            style: .reminder, symbol: missed ? "bell.badge.fill" : "bell.fill",
            title: r.title,
            body: r.body,
            footnote: missed ? "Missed · was due \(DateResolver.friendly(r.startAt))" : "Reminder · \(r.startAt.formatted(date: .omitted, time: .shortened))",
            actions: [
                CardAction(title: "Snooze 10 min") {
                    Store.shared.update(id) { $0.status = .pending; $0.startAt = Date().addingTimeInterval(600) }
                    self.shown.remove(id)
                },
                CardAction(title: "Open") { AppNavigator.shared.open(.calendar, entry: id) },
                CardAction(title: "Done", primary: true) { Store.shared.update(id) { $0.status = .done } },
            ],
            priority: 1, seconds: nil))
        NSSound(named: "Glass")?.play()
    }
}

/// Reads the user's real calendars: shows meetings in Flow's calendar and offers to record them when they start.
@MainActor
final class CalendarWatcher: ObservableObject {
    static let shared = CalendarWatcher()
    let eventStore = EKEventStore()
    @Published private(set) var authorized = false
    private var timer: Timer?
    private var prompted: Set<String> = []

    func start() {
        authorizationChanged()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: .main) { _ in
            Task { @MainActor in Store.shared.objectWillChange.send() }
        }
    }

    func authorizationChanged() {
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    private func meetings(from: Date, to: Date) -> [EKEvent] {
        guard authorized else { return [] }
        let pred = eventStore.predicateForEvents(withStart: from, end: to, calendars: nil)
        return eventStore.events(matching: pred).filter { !$0.isAllDay && $0.status != .canceled }
    }

    /// Calendar events as read-only entries for the calendar and feed views.
    func entries(from: Date, to: Date) -> [Entry] {
        meetings(from: from, to: to).map { ev in
            Entry(id: "ek:\(ev.eventIdentifier ?? UUID().uuidString):\(ev.startDate.timeIntervalSince1970)",
                  kind: .meeting, title: ev.title ?? "Event", body: ev.location ?? "",
                  startAt: ev.startDate, endAt: ev.endDate, status: .scheduled, source: "calendar",
                  meta: ["event_id": ev.eventIdentifier ?? "", "calendar": ev.calendar?.title ?? "",
                         "attendees": String(ev.attendees?.count ?? 0)])
        }
    }

    func currentEventTitle() -> String? {
        let now = Date()
        return meetings(from: now.addingTimeInterval(-3 * 3600), to: now.addingTimeInterval(600))
            .first { $0.startDate <= now.addingTimeInterval(600) && $0.endDate > now }?.title
    }

    private func tick() {
        guard authorized else { return }
        let now = Date()
        let recorder = MeetingRecorder.shared

        // Offer to record meetings as they start.
        if Settings.shared.promptForMeetings, recorder.active == nil {
            for ev in meetings(from: now.addingTimeInterval(-120), to: now.addingTimeInterval(60)) {
                let key = "start:\(ev.eventIdentifier ?? ""):\(ev.startDate.timeIntervalSince1970)"
                guard ev.startDate >= now.addingTimeInterval(-120), ev.startDate <= now.addingTimeInterval(60),
                      prompted.insert(key).inserted else { continue }
                let title = ev.title ?? "Meeting"
                let end = ev.endDate
                let eventId = ev.eventIdentifier
                Overlay.shared.show(Card(
                    style: .meeting, symbol: "person.2.wave.2.fill", title: "Starting now: \(title)",
                    body: "Transcribe this meeting? Flow will write notes and catch your commitments.",
                    actions: [
                        CardAction(title: "Skip") {},
                        CardAction(title: "Record", primary: true) {
                            Task { _ = try? await MeetingRecorder.shared.start(title: title, eventId: eventId, scheduledEnd: end) }
                        },
                    ],
                    priority: 1, seconds: 120))
                break
            }
        }

        // When a recorded calendar meeting reaches its scheduled end, ask whether to stop.
        if let active = recorder.active, let endRaw = active.meta["scheduled_end"], let end = Double(endRaw),
           now.timeIntervalSince1970 > end + 60, prompted.insert("end:\(active.id)").inserted {
            Overlay.shared.show(Card(
                style: .meeting, symbol: "stop.circle.fill", title: "“\(active.title)” was scheduled to end",
                body: "Stop recording and write notes?",
                actions: [
                    CardAction(title: "Keep going") {},
                    CardAction(title: "Stop", primary: true) { Task { await MeetingRecorder.shared.stop() } },
                ],
                priority: 1, seconds: nil))
        }
    }
}
