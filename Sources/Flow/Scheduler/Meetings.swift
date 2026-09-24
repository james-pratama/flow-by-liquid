import Foundation

/// Accumulates one speaker's audio and hands out chunks at natural pauses.
final class ChunkBuffer {
    let speaker: String
    private var samples: [Float] = []
    private var consumed = 0            // samples already handed out (absolute)
    private let lock = NSLock()
    private let rate = Int(AudioHub.sampleRate)

    init(speaker: String) { self.speaker = speaker }

    private(set) var total = 0   // samples received since the meeting started

    func append(_ s: [Float]) { lock.lock(); samples += s; total += s.count; lock.unlock() }

    /// Returns (startSeconds, samples) when ≥10 s have built up and the speaker paused, or at 25 s, or when forced.
    func take(force: Bool) -> (Double, [Float])? {
        lock.lock(); defer { lock.unlock() }
        let n = samples.count
        guard n > rate / 2 else { return nil }
        let pause = AudioMath.rms(samples[max(0, n - rate / 2)...]) < 0.004
        guard force || n >= 25 * rate || (n >= 10 * rate && pause) else { return nil }
        let chunk = samples
        let start = Double(consumed) / Double(rate)
        consumed += n
        samples.removeAll(keepingCapacity: true)
        return (start, chunk)
    }
}

/// Records a meeting: your mic as "Me", system audio as "Them". Chunks are transcribed as the meeting goes.
@MainActor
final class MeetingRecorder: ObservableObject {
    static let shared = MeetingRecorder()

    @Published private(set) var active: Entry?
    @Published private(set) var capturingSystemAudio = false

    private var micSub: UUID?
    private let system = SystemAudioCapture()
    private var buffers: [ChunkBuffer] = []
    private var timer: Timer?
    private var chain: Task<Void, Never>?

    func start(title: String, eventId: String? = nil, scheduledEnd: Date? = nil) async throws -> Entry {
        if let a = active { return a }
        var meta: [String: String] = [:]
        if let eventId { meta["event_id"] = eventId }
        if let scheduledEnd { meta["scheduled_end"] = String(scheduledEnd.timeIntervalSince1970) }
        var e = Entry(kind: .meeting, title: title, startAt: Date(), status: .recording, source: "meeting", meta: meta)

        let me = ChunkBuffer(speaker: "Me"), them = ChunkBuffer(speaker: "Them")
        buffers = [me, them]
        micSub = try AudioHub.shared.subscribe { me.append($0) }

        capturingSystemAudio = false
        if SystemPermission.screenAudio.isGranted {
            system.onSamples = { them.append($0) }
            do { try await system.start(); capturingSystemAudio = true } catch { flowLog("system audio unavailable: \(error)") }
        }
        e.meta["system_audio"] = capturingSystemAudio ? "yes" : "no"
        Store.shared.save(e)
        active = e
        Overlay.shared.model.meetingStartedAt = e.startAt
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drain(force: false) }
        }
        flowLog("meeting started: \(title)")
        return e
    }

    /// Transcribes ready chunks one at a time, in order.
    private func drain(force: Bool) {
        guard let meeting = active else { return }
        for b in buffers {
            guard let (start, samples) = b.take(force: force) else { continue }
            // Skip only true silence. Averaging over a whole 10–30 s chunk let quiet speech on a laptop
            // mic look silent, so judge by the loudest 100 ms instead.
            let peak = AudioMath.peakFrameRMS(samples, frame: 1600)
            let seconds = Double(samples.count) / AudioHub.sampleRate
            guard peak > 0.002 else {
                flowLog(String(format: "meeting: skipped %.1fs of silence from %@ (peak %.4f)", seconds, b.speaker, peak))
                continue
            }
            let previous = chain
            let speaker = b.speaker
            chain = Task.detached(priority: .utility) {
                await previous?.value
                let text: String
                do { text = try await ASR.transcribe(samples) } catch {
                    flowLog("meeting: ASR failed on \(String(format: "%.1f", seconds))s chunk: \(error.localizedDescription)")
                    return
                }
                flowLog("meeting: \(speaker) \(String(format: "%.1f", seconds))s → \(text.count) chars")
                guard !text.isEmpty else { return }
                Store.shared.appendSegment(MeetingSegment(entryId: meeting.id, tStart: start,
                                                          tEnd: start + Double(samples.count) / AudioHub.sampleRate,
                                                          speaker: speaker, text: text))
            }
        }
    }

    @discardableResult
    func stop() async -> Entry? {
        guard var e = active else { return nil }
        timer?.invalidate()
        if let s = micSub { AudioHub.shared.unsubscribe(s) }
        micSub = nil
        await system.stop()
        let captured = buffers.map { "\($0.speaker) \(String(format: "%.1f", Double($0.total) / AudioHub.sampleRate))s" }.joined(separator: ", ")
        flowLog("meeting stopped: captured \(captured)")
        e.meta["captured"] = captured
        drain(force: true)
        active = nil
        Overlay.shared.model.meetingStartedAt = nil
        e.endAt = Date()
        e.status = .processing
        Store.shared.save(e)
        let meetingId = e.id
        let pending = chain
        Task {
            await pending?.value
            await MeetingProcessor.process(meetingId)
        }
        return e
    }
}

/// After a meeting: summary, decisions, and your commitments as proposed reminders.
enum MeetingProcessor {
    static func transcript(_ segs: [MeetingSegment]) -> String {
        segs.map { s in
            let m = Int(s.tStart) / 60, sec = Int(s.tStart) % 60
            return String(format: "[%02d:%02d] ", m, sec) + "\(s.speaker): \(s.text)"
        }.joined(separator: "\n")
    }

    static let schema: OJ = .props([
        ("summary", .str),
        ("decisions", .array(.str, max: 8)),
        ("commitments", .array(.props([("task", .str), ("owner", .str), ("due", .str)]), max: 10)),
    ])

    @MainActor
    static func process(_ meetingId: String) async {
        guard var meeting = Store.shared.entry(meetingId) else { return }
        let segs = Store.shared.segments(meetingId)
        let text = transcript(segs)
        meeting.transcript = text
        guard !text.isEmpty else {
            meeting.status = .done
            meeting.body = "No speech was captured (\(meeting.meta["captured"] ?? "no audio")). If the mic shows 0.0s, check Microphone access in Tools & Permissions."
            Store.shared.save(meeting)
            Overlay.shared.result("Meeting ended", "No speech was captured for “\(meeting.title)”.", style: .info)
            return
        }

        var summaries: [String] = []
        var decisions: [String] = []
        var commitments: [(task: String, owner: String, due: String)] = []
        for chunk in chunks(text, size: 7000) {
            let system = Prompts.system(.meeting)
            // The model reads the user as "You" so its summary addresses them naturally.
            let forModel = chunk.replacingOccurrences(of: "] Me: ", with: "] You: ")
            let prompt = ChatML.prompt(system: system, user: "Meeting: \(meeting.title)\nTranscript:\n\(forModel)")
            guard let (out, _) = try? await LLMClient.router.complete(prompt: prompt, schema: schema, maxTokens: 700),
                  let obj = JSON.parse(out) else { continue }
            if let s = obj["summary"] as? String { summaries.append(s) }
            decisions += obj["decisions"] as? [String] ?? []
            for c in obj["commitments"] as? [[String: Any]] ?? [] {
                let task = (c["task"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                guard !task.isEmpty, !commitments.contains(where: { $0.task.lowercased() == task.lowercased() }) else { continue }
                var due = c["due"] as? String ?? ""
                // Discard dates the model invented (e.g. "2026-07-21") that nobody said.
                if due.matches(#"\d{4}-\d{2}-\d{2}"#) && !text.contains(due) { due = "" }
                commitments.append((task, c["owner"] as? String ?? "", due))
            }
        }

        var summary = summaries.joined(separator: " ")
        if summaries.count > 1,
           let (s, _) = try? await LLMClient.router.complete(
            prompt: ChatML.prompt(system: "Merge these partial meeting summaries into one summary of at most 5 sentences. Output only the summary.",
                                  user: summaries.joined(separator: "\n\n")), maxTokens: 300) {
            summary = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let selfNames: Set<String> = ["me", "i", "user", "myself", "you"]
        let mine = commitments.filter { selfNames.contains($0.owner.lowercased()) }
        let theirs = commitments.filter { !selfNames.contains($0.owner.lowercased()) }
        var body = summary
        if !decisions.isEmpty { body += "\n\nDecisions\n" + decisions.map { "• \($0)" }.joined(separator: "\n") }
        if !theirs.isEmpty { body += "\n\nOthers will\n" + theirs.map { "• \($0.owner): \($0.task)\($0.due.isEmpty ? "" : " (\($0.due))")" }.joined(separator: "\n") }
        meeting.body = body
        meeting.status = .done
        meeting.meta["commitments"] = String(mine.count)
        Store.shared.save(meeting)
        LocalMemory.shared.index(meeting)

        let end = meeting.endAt ?? Date()
        var proposed: [Entry] = []
        for c in mine {
            var guessed = false
            let when = DateResolver.resolve(c.due, now: end) ?? {
                guessed = true
                return nextBusinessMorning(after: end)
            }()
            var meta = ["spoken_time": c.due]
            if guessed { meta["time_guessed"] = "true" }
            let r = Entry(kind: .reminder, title: c.task, body: "From “\(meeting.title)”", startAt: when, status: .proposed,
                          source: "meeting", parentId: meeting.id, meta: meta)
            Store.shared.save(r)
            proposed.append(r)
        }

        var actions = [CardAction(title: "Open notes") { AppNavigator.shared.open(.feed, entry: meetingId) }]
        if !proposed.isEmpty {
            actions.append(CardAction(title: "Add \(proposed.count) reminder\(proposed.count == 1 ? "" : "s")", primary: true) {
                for p in proposed { Store.shared.update(p.id) { $0.status = .pending } }
            })
        }
        let list = proposed.map { "• \($0.title) — \(DateResolver.friendly($0.startAt))" }.joined(separator: "\n")
        Overlay.shared.show(Card(style: .meeting, symbol: "doc.text.fill", title: "Notes ready: \(meeting.title)",
                                 body: proposed.isEmpty ? summary : "Your commitments:\n" + list,
                                 footnote: proposed.isEmpty ? "" : "Add them to your calendar as reminders?",
                                 actions: actions, priority: 1, seconds: nil))
    }

    static func chunks(_ text: String, size: Int) -> [String] {
        var out: [String] = []
        var cur = ""
        for line in text.split(separator: "\n") {
            if cur.count + line.count > size, !cur.isEmpty { out.append(cur); cur = "" }
            cur += line + "\n"
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func nextBusinessMorning(after d: Date) -> Date {
        let cal = Calendar.current
        var day = cal.date(byAdding: .day, value: 1, to: d)!
        while cal.isDateInWeekend(day) { day = cal.date(byAdding: .day, value: 1, to: day)! }
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
    }
}
