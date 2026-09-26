import AppKit

/// Thread-safe growing sample buffer.
final class SampleBuffer {
    private var samples: [Float] = []
    private let lock = NSLock()

    func reset() { lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock() }
    func append(_ s: [Float]) { lock.lock(); samples += s; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return samples.count }
    func slice(_ from: Int, _ to: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let a = max(0, min(from, samples.count)), b = max(a, min(to, samples.count))
        return Array(samples[a..<b])
    }
    func rms(last n: Int) -> Float {
        lock.lock(); defer { lock.unlock() }
        return AudioMath.rms(samples[max(0, samples.count - n)...])
    }
}

/// Push-to-talk pipeline: hotkey → mic → LFM2.5-Audio → router → tools → bottom card.
@MainActor
final class FlowEngine {
    static let shared = FlowEngine()

    private var focus: FocusContext?
    private var subscription: UUID?
    private let buffer = SampleBuffer()
    private var chunks: [Task<String, Never>] = []
    private var cutAt = 0
    private var recording = false
    private var pressedAt = Date.distantPast
    private var meter: Timer?

    private let rate = Int(AudioHub.sampleRate)

    func start() {
        let hk = HotkeyMonitor.shared
        hk.onPress = { [weak self] b in MainActor.assumeIsolated { self?.pressed(b) } }
        hk.onRelease = { [weak self] b in MainActor.assumeIsolated { self?.released(b) } }
        hk.onCancel = { [weak self] _ in MainActor.assumeIsolated { self?.lastTapAt = .distantPast; self?.cancel() } }
        hk.start()
    }

    /// Release time of the last quick tap; a second press soon after it is a double-tap.
    private var lastTapAt = Date.distantPast
    private var swallowNextRelease = false
    private static let tapMax: TimeInterval = 0.3
    private static let doubleTapWindow: TimeInterval = 0.45

    /// Which hotkey started the current recording.
    private var mode: HotkeyBinding = .agent

    /// Agent key: hold = talk to Flow, double-tap = start/stop meeting transcription.
    /// Dictation key: hold = transcribe and paste, nothing else.
    private func pressed(_ binding: HotkeyBinding) {
        if binding == .dictation { begin(mode: .dictation); return }
        if Date().timeIntervalSince(lastTapAt) < Self.doubleTapWindow {
            lastTapAt = .distantPast
            swallowNextRelease = true
            cancel()
            toggleMeeting()
            return
        }
        begin()
    }

    private func released(_ binding: HotkeyBinding) {
        if swallowNextRelease && binding == .agent { swallowNextRelease = false; return }
        guard recording, binding == mode else { return }
        if Date().timeIntervalSince(pressedAt) < Self.tapMax {
            if binding == .dictation { cancel(); return }
            // A quick tap: maybe the first half of a double-tap. Discard the audio.
            lastTapAt = Date()
            cancel()
            return
        }
        finish()
    }

    func toggleMeeting() {
        Task {
            let rec = MeetingRecorder.shared
            if let m = rec.active {
                await rec.stop()
                Overlay.shared.result("Meeting ended", "Writing notes for “\(m.title)”…", style: .meeting, symbol: "stop.circle.fill",
                                      actions: openAction(m.id))
            } else {
                let title = CalendarWatcher.shared.currentEventTitle() ?? "Meeting"
                do {
                    let meeting = try await rec.start(title: title)
                    let note = rec.capturingSystemAudio ? "Recording your mic and the call's audio."
                        : "Recording your mic only — allow Screen & System Audio Recording to capture the other side."
                    Overlay.shared.result("Transcribing “\(title)”", note + " Double-tap \(Settings.shared.shortcut.displayString) to stop.",
                                          style: .meeting, symbol: "record.circle", actions: openAction(meeting.id))
                } catch {
                    Overlay.shared.result("Couldn't start recording", error.localizedDescription, style: .error)
                }
            }
        }
    }

    var isRecording: Bool { recording }

    /// Start/stop without the hotkey (menu bar item).
    func toggleTalk() { recording ? finish() : begin(mode: .agent) }

    func begin(mode: HotkeyBinding = .agent) {
        guard !recording else { return }
        self.mode = mode
        guard SystemPermission.microphone.isGranted else {
            Overlay.shared.result("Flow needs the microphone", "Allow access so Flow can hear you.", style: .warning,
                                  actions: [CardAction(title: "Allow", primary: true) { Task { await SystemPermission.microphone.request() } }])
            return
        }
        focus = FocusContext.capture()
        AppCatalog.shared.prefetch(focus?.app)
        buffer.reset()
        chunks = []
        cutAt = 0
        do {
            let buf = buffer
            subscription = try AudioHub.shared.subscribe { buf.append($0) }
        } catch {
            Overlay.shared.result("Couldn't start the microphone", error.localizedDescription, style: .error)
            return
        }
        recording = true
        pressedAt = Date()
        flowLog("listening (front app: \(focus?.appName ?? "?"), text field: \(focus?.isTextInput == true))")
        Overlay.shared.listening(dictating: mode == .dictation)
        meter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Updates the level meter and, on long dictations, sends finished sentences to ASR while the user keeps talking.
    private func tick() {
        guard recording else { return }
        Overlay.shared.level(buffer.rms(last: rate / 10))
        let n = buffer.count
        if n - cutAt >= 12 * rate && buffer.rms(last: rate / 2) < 0.008 {
            let chunk = buffer.slice(cutAt, n)
            cutAt = n
            chunks.append(Task { (try? await ASR.transcribe(chunk)) ?? "" })
        }
    }

    private func stopCapture() {
        meter?.invalidate()
        meter = nil
        if let s = subscription { AudioHub.shared.unsubscribe(s) }
        subscription = nil
        recording = false
    }

    func cancel() {
        guard recording else { return }
        flowLog("cancelled")
        stopCapture()
        chunks.forEach { $0.cancel() }
        Overlay.shared.idle()
    }

    func finish() {
        guard recording else { return }
        stopCapture()
        let n = buffer.count
        let tail = buffer.slice(cutAt, n)
        let pending = chunks
        let seconds = Double(n) / Double(rate)
        let focus = self.focus
        let mode = self.mode
        Overlay.shared.thinking(mode == .dictation ? "Transcribing…" : "")

        Task {
            let t0 = Date()
            if AudioMath.rms(tail) < 0.002 && pending.isEmpty {
                Overlay.shared.idle()
                Overlay.shared.result("Didn't hear anything", style: .info, seconds: 2)
                return
            }
            var parts: [String] = []
            for c in pending { parts.append(await c.value) }
            do {
                parts.append(try await ASR.transcribe(tail))
            } catch {
                Overlay.shared.idle()
                Overlay.shared.result("Speech model isn't ready", "Check Flow → Settings → Models.", style: .warning)
                return
            }
            let transcript = parts.filter { !$0.isEmpty }.joined(separator: " ")
            let asrMs = Int(Date().timeIntervalSince(t0) * 1000)
            flowLog("asr \(asrMs)ms (\(String(format: "%.1f", seconds))s audio): \(transcript)")
            guard !transcript.isEmpty else {
                Overlay.shared.idle()
                Overlay.shared.result("Didn't catch that", style: .info, seconds: 2)
                return
            }
            if mode == .dictation {
                await dictate(transcript, focus: focus, asrMs: asrMs)
            } else {
                await handle(transcript, focus: focus, asrMs: asrMs)
            }
        }
    }

    /// Wispr-style: paste exactly what was said (lightly cleaned) where the cursor is. No routing, no tools.
    func dictate(_ transcript: String, focus: FocusContext?, asrMs: Int) async {
        let text = Dictation.clean(transcript)
        Overlay.shared.idle()
        guard !text.isEmpty else { return }
        let app = focus?.appName ?? "the current app"
        if SystemPermission.accessibility.isGranted {
            await Keyboard.paste(text, into: focus)
        } else {
            // Can't type for the user without Accessibility: leave it on the clipboard instead.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Overlay.shared.result("Copied — press ⌘V to paste", "Allow Accessibility so Flow can paste for you.", style: .warning,
                                  actions: [CardAction(title: "Allow", primary: true) { Task { await SystemPermission.accessibility.request() } }])
        }
        var e = Entry(kind: .dictation, title: String(text.prefix(80)), body: text, transcript: transcript,
                      source: "dictation", meta: ["app": app, "asr_ms": String(asrMs)])
        e.sessionId = UUID().uuidString
        Store.shared.save(e)
        flowLog("dictated \(text.count) chars into \(app)")
    }

    /// Routes a transcript and runs its tool calls. Also used by the "type a command" field in the main window.
    func handle(_ transcript: String, focus: FocusContext?, asrMs: Int = 0) async {
        Overlay.shared.thinking("“\(transcript.prefix(70))\(transcript.count > 70 ? "…" : "")”")
        let now = Date()
        let session = UUID().uuidString

        // Multi-step conversation: resolve follow-ups against recent turns before deciding what to do.
        let history = Store.shared.conversation(limit: 15)
        let request = await Conversation.resolve(transcript, history: history, now: now) ?? transcript

        var route: Route
        do {
            route = try await Router.shared.route(request, focus: focus, now: now)
        } catch {
            flowLog("router failed: \(error.localizedDescription)")
            route = Router.fallback(request)
        }
        flowLog("route \(route.latencyMs)ms intent=\(route.intent) kind=\(route.kind) calls=\(route.calls.map(\.tool)) fixes=\(route.corrections)")

        // "Actually make it 3pm" right after Flow set a reminder corrects that reminder rather than adding another.
        if let last = history.last, now.timeIntervalSince(last.at) < Conversation.window,
           last.assistant.hasPrefix("(Reminder set:"),
           transcript.matches(#"^\s*(actually|no|nope|wait|make it|change it|instead|move it|push it|sorry)\b"#),
           let i = route.calls.firstIndex(where: { $0.tool == "create_reminder" }) {
            let when = route.calls[i].args["when"] as? String ?? ""
            let previous = last.assistant.replacingOccurrences(of: "(Reminder set: ", with: "")
                .components(separatedBy: ",").first ?? ""
            route.calls[i] = RoutedCall(tool: "update_reminder", args: ["which": previous, "new_title": "", "new_when": when])
            route.corrections.append("correction→update_reminder")
        }

        // "Actually it's level 4" right after saving a memory corrects that memory.
        if let last = history.last, now.timeIntervalSince(last.at) < Conversation.window,
           last.assistant.hasPrefix("(Saved to memory:"),
           transcript.matches(#"^\s*(actually|no|nope|wait|sorry|correction|i meant|make that|change that)\b"#),
           let i = route.calls.firstIndex(where: { $0.tool == "memory_save" || $0.tool == "answer_question" }) {
            let previous = last.assistant.replacingOccurrences(of: "(Saved to memory: ", with: "").replacingOccurrences(of: ")", with: "")
            route.calls[i] = RoutedCall(tool: "update_memory", args: ["which": previous, "change": transcript])
            route.intent = "memory"
            route.corrections.append("correction→update_memory")
        }

        let ctx = ToolContext(transcript: request, focus: focus, now: now, sessionId: session, intent: route.intent,
                              said: transcript, history: history)
        var outcomes: [ToolOutcome] = []
        for call in route.calls {
            var out = await execute(call, ctx)
            if var e = out.entry {
                e.meta["asr_ms"] = String(asrMs)
                e.meta["route_ms"] = String(route.latencyMs)
                e.meta["intent"] = route.intent
                if !route.corrections.isEmpty { e.meta["harness"] = route.corrections.joined(separator: ", ") }
                Store.shared.save(e)
                out.entry = e
            }
            outcomes.append(out)
        }
        Overlay.shared.idle()
        present(outcomes)
        // Keep the search index complete (new actions, dictations, anything embedded while models were loading).
        Task.detached(priority: .utility) { await LocalMemory.shared.backfill(limit: 50) }
    }

    private func execute(_ call: RoutedCall, _ ctx: ToolContext) async -> ToolOutcome {
        guard let tool = ToolRegistry.tool(call.tool) else {
            return ToolOutcome(message: "Unknown tool \(call.tool)", style: .error)
        }
        let args = Args(raw: call.args)
        let policy = tool.policy
        if policy == .off {
            return ToolOutcome(message: "“\(tool.title)” is turned off", detail: "Turn it on in Flow → Tools.", style: .warning,
                               actions: [CardAction(title: "Open Tools") { AppNavigator.shared.open(.tools) }])
        }
        if let missing = tool.missingPermissions.first, !DryRun.active {
            return ToolOutcome(message: "\(tool.title) needs \(missing.title)", detail: missing.why, style: .warning,
                               actions: [CardAction(title: "Allow", primary: true) { Task { await missing.request() } }])
        }
        if policy == .ask {
            let ok = await Overlay.shared.confirm(tool.describe(args), "“\(tool.title)” is set to Ask first.")
            if !ok { return ToolOutcome(message: "Cancelled", detail: tool.describe(args), style: .info, holdSeconds: 2) }
        }

        let t0 = Date()
        do {
            let out = try await tool.run(args, ctx)
            Store.shared.addToolRun(ToolRun(entryId: out.entry?.id ?? ctx.sessionId, tool: tool.name, args: JSON.string(call.args),
                                            result: [out.message, out.detail].filter { !$0.isEmpty }.joined(separator: " — "),
                                            status: "ok", latencyMs: Int(Date().timeIntervalSince(t0) * 1000)))
            return out
        } catch {
            let msg = error.localizedDescription
            let e = ctx.log(.action, title: "Couldn't \(tool.title.lowercased())", body: msg, status: .failed)
            Store.shared.addToolRun(ToolRun(entryId: e.id, tool: tool.name, args: JSON.string(call.args), result: msg,
                                            status: "error", latencyMs: Int(Date().timeIntervalSince(t0) * 1000)))
            return ToolOutcome(message: "Couldn't \(tool.title.lowercased())", detail: msg, entry: e, style: .error)
        }
    }

    private func present(_ outcomes: [ToolOutcome]) {
        let overlay = Overlay.shared
        for answer in outcomes where answer.style == .answer {
            overlay.show(Card(style: .answer, symbol: "sparkle", title: answer.message, body: answer.detail,
                              actions: answer.actions + openAction(answer.openTarget), priority: 2, seconds: answer.holdSeconds))
        }
        let rest = outcomes.filter { $0.style != .answer }
        guard !rest.isEmpty else { return }
        if rest.count == 1, let o = rest.first {
            var actions = o.actions
            if let e = o.entry, [.memory, .reminder].contains(e.kind) {
                actions.append(CardAction(title: "Undo") { Store.shared.delete(e.id) })
            }
            overlay.result(o.message, o.detail, style: o.style, seconds: o.holdSeconds, actions: actions + openAction(o.openTarget))
        } else {
            let worst = rest.contains { $0.style == .error } ? CardStyle.error : (rest.contains { $0.style == .warning } ? .warning : .success)
            overlay.result(rest.map(\.message).joined(separator: " · "),
                           rest.map { $0.detail }.filter { !$0.isEmpty }.joined(separator: "\n"), style: worst,
                           actions: rest.flatMap(\.actions) + openAction(rest.compactMap(\.openTarget).first))
        }
    }

    /// Every card about something Flow created or changed gets a way to open it in the app.
    func openAction(_ id: String?) -> [CardAction] {
        guard let id else { return [] }
        return [CardAction(title: "Open in Flow", primary: true) { AppNavigator.shared.open(.feed, entry: id) }]
    }
}

/// Light, deterministic cleanup for dictation (no model call, so it stays instant).
enum Dictation {
    static func clean(_ raw: String) -> String {
        var t = raw
        // Filler words, with the comma that often follows them.
        t = t.replacingOccurrences(of: #"(?i)\b(um+|uh+|erm+|er|ah+|hmm+)\b[,.]?\s*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
        if let first = t.first, first.isLowercase { t = first.uppercased() + t.dropFirst() }
        return t
    }
}
