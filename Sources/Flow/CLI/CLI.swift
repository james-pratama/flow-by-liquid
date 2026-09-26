import SwiftUI
import AppKit
import Foundation

/// Headless commands for testing the harness without the UI:
///   Flow --route "open spotify" [--focused]     route one utterance
///   Flow --eval evals/router_cases.jsonl        router accuracy + latency
///   Flow --asr recording.wav                    transcribe a file
///   Flow --date "thursday at 3pm"               resolve a spoken time
///   Flow --ask "where did I park?"              run the question agent
///   Flow --meeting transcript.txt [title]       summarize a transcript ("Me: …" / "Them: …" lines)
///   Flow --apps [filter]                        list the app actions Flow knows
///   Flow --app "skip this song" [Spotify]       pick an app action (set FLOW_DRY_RUN to only print it)
///   Flow --app-eval evals/app_cases.jsonl       app-action accuracy + latency
///   open -W /Applications/Flow.app --args --spotify-probe "only time" [--press]
///                                               what Flow sees in Spotify (→ logs/spotify-probe.txt; needs Flow.app's Accessibility)
/// Set FLOW_HOME to use a separate data folder.
enum CLI {
    static let commands = ["--clean-text", "--overlay-preview", "--make-icon", "--logo-png", "--meeting-sim", "--handle", "--route", "--eval", "--asr", "--date", "--ask", "--meeting", "--remember", "--apps", "--app", "--app-eval", "--spotify-probe"]

    static func handles(_ args: [String]) -> Bool { args.dropFirst().first.map(commands.contains) ?? false }

    static func run(_ args: [String]) -> Never {
        Task {
            let code = await main(Array(args.dropFirst()))
            ModelServers.shared.stopAll()
            exit(code)
        }
        RunLoop.main.run()
        exit(0)
    }

    private static func need(_ kinds: [ModelServers.Kind]) async -> Bool {
        for k in kinds {
            if await ModelServers.healthy(k) { continue }
            print("starting \(k.rawValue) server…")
            await ModelServers.shared.start(k)
            guard await ModelServers.healthy(k) else { print("✗ \(k.rawValue) failed: \(ModelServers.shared.status[k]?.label ?? "")"); return false }
        }
        return true
    }

    private static func main(_ a: [String]) async -> Int32 {
        let cmd = a[0]
        let arg = a.count > 1 ? a[1] : ""
        switch cmd {
        case "--date":
            if let d = DateResolver.resolve(arg) { print(d.formatted(date: .complete, time: .shortened), "·", DateResolver.friendly(d)) } else { print("unresolved") }
            return 0

        case "--clean-text":
            print(GeneratedText.clean(arg))
            return 0

        case "--overlay-preview":
            let ok: Bool = await MainActor.run {
                let m = OverlayModel()
                let now = Date()
                let cards = [
                    Card(style: .success, symbol: "checkmark.circle.fill", title: "Reminder updated", body: "Call Sam · Tomorrow 3:00 PM", seconds: 5),
                    Card(style: .answer, symbol: "sparkle", title: "What is the capital of Korea?", body: "Seoul is the capital of South Korea.", seconds: 5),
                    Card(style: .success, symbol: "checkmark.circle.fill", title: "Wrote it in Google Chrome", body: "Hi Kevin, I've submitted my case study…", seconds: 5),
                ]
                var work = Card(steps: [CardStep(text: "Memories: 4 matches for “Acme deal”", done: true),
                                        CardStep(text: "Your notes cover this — skipping the web", done: true),
                                        CardStep(text: "Reasoning over 4 findings…")],
                                working: true, style: .answer, symbol: "sparkle", title: "What do I know about the Acme deal?", seconds: nil)
                work.priority = 2
                m.cards = [work] + Array(cards.prefix(1))
                m.deadlines = [cards[0].id: now.addingTimeInterval(4.8), cards[1].id: now.addingTimeInterval(2.6), cards[2].id: now.addingTimeInterval(0.9)]
                m.phase = .idle
                let r = ImageRenderer(content: OverlayRoot(model: m, onHover: { _ in }).background(Color(white: 0.85)))
                r.scale = 2
                guard let cg = r.cgImage, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return false }
                return (try? data.write(to: URL(fileURLWithPath: arg))) != nil
            }
            return ok ? 0 : 1

        case "--make-icon":
            do { try await MainActor.run { try LogoRenderer.writeIconset(to: URL(fileURLWithPath: arg)) } }
            catch { print("error: \(error)"); return 1 }
            return 0

        case "--logo-png":
            let data = await MainActor.run { LogoRenderer.png(size: 1024, iconGrid: true) }
            guard let data, (try? data.write(to: URL(fileURLWithPath: arg))) != nil else { print("render failed"); return 1 }
            return 0

        case "--meeting-sim":
            // Plays a WAV through the real MeetingRecorder (as the mic) in real time.
            guard await need([.router, .asr]) else { return 1 }
            AudioHub.shared.simulated = true
            guard let samples = try? AudioFile.load(URL(fileURLWithPath: arg)) else { print("can't load"); return 1 }
            let rec = await MeetingRecorder.shared
            guard let m = try? await rec.start(title: "Simulated meeting") else { print("start failed"); return 1 }
            let step = 1600
            var i = 0
            while i < samples.count {
                AudioHub.shared.inject(Array(samples[i..<min(i + step, samples.count)]))
                i += step
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            _ = await rec.stop()
            for _ in 0..<120 {
                if Store.shared.entry(m.id)?.status == .done { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            let done = Store.shared.entry(m.id)
            print("segments: \(Store.shared.segments(m.id).count)")
            for s in Store.shared.segments(m.id) { print("  [\(Int(s.tStart))s] \(s.speaker): \(s.text)") }
            print("\n\(done?.body ?? "")")
            return 0

        case "--handle":
            guard await need([.router, .embed]) else { return 1 }
            await LocalMemory.shared.backfill(limit: 500)
            await AppCatalog.shared.refresh()
            let focus = a.contains("--focused") ? FocusContext(app: nil, appName: "Google Chrome", bundleId: "", element: nil, role: "AXTextArea",
                                                               isTextInput: true, selectedText: "", windowTitle: "Gmail") : nil
            await FlowEngine.shared.handle(arg, focus: focus)
            let card = await Overlay.shared.model.cards.first
            print("card: \(card?.title ?? "none") — \(card?.body ?? "")")
            for e in Store.shared.recent(limit: 1) { print("entry: [\(e.kind.rawValue)/\(e.status.rawValue)] \(e.title) @ \(DateResolver.friendly(e.startAt))") }
            return 0

        case "--route":
            guard await need([.router]) else { return 1 }
            let focused = a.contains("--focused")
            let focus = focused ? FocusContext(app: nil, appName: "Slack", bundleId: "", element: nil, role: "AXTextArea",
                                               isTextInput: true, selectedText: "", windowTitle: "") : nil
            _ = try? await Router.shared.route("warm up", focus: nil)
            do {
                let r = try await Router.shared.route(arg, focus: focus)
                print("intent: \(r.intent)  (\(r.latencyMs) ms, model kind: \(r.kind))")
                for c in r.calls { print("  \(c.tool) \(JSON.string(c.args))") }
                if !r.corrections.isEmpty { print("  harness: \(r.corrections.joined(separator: ", "))") }
            } catch { print("error: \(error)"); return 1 }
            return 0

        case "--eval":
            guard await need([.router]) else { return 1 }
            return await Eval.run(path: arg)

        case "--apps":
            guard await need([.embed]) else { return 1 }
            await AppCatalog.shared.refresh()
            let actions = AppCatalog.shared.all.filter { arg.isEmpty || $0.searchText.lowercased().contains(arg.lowercased()) }
            for a in actions { print("[\(a.source.rawValue)] \(a.app): \(a.title)\(a.args.isEmpty ? "" : " (" + a.args.map(\.name).joined(separator: ", ") + ")")\(a.risk == .outward ? " ⚠︎ asks first" : "")") }
            let counts = Dictionary(grouping: AppCatalog.shared.all, by: \.source).mapValues(\.count)
            print("\n\(AppCatalog.shared.all.count) actions: " + counts.map { "\($0.value) \($0.key.rawValue)" }.sorted().joined(separator: ", ")
                  + " (+ menu items of whichever app is in front)")
            return 0

        case "--app":
            guard await need([.router, .embed]) else { return 1 }
            await AppCatalog.shared.refresh()
            let t0 = Date()
            let (target, candidates) = await AppCatalog.shared.candidates(for: arg, app: a.count > 2 ? a[2] : "", frontmost: nil)
            let t1 = Date()
            print("app: \(target?.name ?? "(none named)")  · search \(Int(t1.timeIntervalSince(t0) * 1000)) ms")
            for (i, c) in candidates.enumerated() { print("  \(i + 1). \(c.id)") }
            guard let (action, args) = await AppActionTool.pick(arg, target: target, candidates: candidates, frontmost: nil) else { print("→ none"); return 0 }
            print("→ \(action.id) \(JSON.string(args.raw))  · pick \(Int(Date().timeIntervalSince(t1) * 1000)) ms")
            if DryRun.active { return 0 }
            let ctx = ToolContext(transcript: arg, focus: nil, now: Date(), sessionId: UUID().uuidString, intent: "action")
            do { let r = try await action.perform(args, ctx); print("✓ \(r.message) \(r.detail)") } catch { print("✗ \(error.localizedDescription)") }
            return 0

        case "--spotify-probe":
            // Lists the play buttons and library playlists Flow can see in Spotify, without pressing any.
            // Written to logs/spotify-probe.txt, since this is run through `open` (for Flow.app's Accessibility grant).
            var lines = ["accessibility: \(AXIsProcessTrusted())"]
            defer { try? lines.joined(separator: "\n").write(to: Paths.logs.appendingPathComponent("spotify-probe.txt"), atomically: true, encoding: .utf8) }
            if a.contains("--press") {
                // The same path a spoken request takes: catalog search, model pick, then the action.
                let (target, candidates) = await AppCatalog.shared.candidates(for: arg, app: "Spotify", frontmost: nil)
                guard let (action, args) = await AppActionTool.pick(arg, target: target, candidates: candidates, frontmost: nil) else {
                    lines.append("picked: none"); return 1
                }
                lines.append("picked: \(action.id) \(JSON.string(args.raw))")
                let ctx = ToolContext(transcript: arg, focus: nil, now: Date(), sessionId: "probe", intent: "action")
                let pressed: String
                do { pressed = try await action.perform(args, ctx).message } catch { pressed = "error: \(error.localizedDescription)" }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let playing = (try? await Script.tell(SpotifyPlayer.app, "return (name of current track) & \" — \" & (artist of current track)")) ?? "?"
                lines += ["pressed: \(pressed)", "now playing: \(playing)"] + SpotifyUI.lastResults
                return 0
            }
            if !arg.isEmpty, let url = URL(string: "spotify:search:\(arg.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? arg)") {
                NSWorkspace.shared.open(url)
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
            _ = try? await SpotifyPlayer.app.activate()
            let found: [String]? = await SpotifyUI.withPage { root in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                var wins: CFTypeRef?
                AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &wins)
                let windows = (wins as? [AXUIElement]) ?? []
                var counted = 0, q = AX.children(root)
                while !q.isEmpty && counted < 20000 { let n = q.removeFirst(); counted += 1; q += AX.children(n) }
                let winInfo = windows.map { w -> String in
                    var mini: CFTypeRef?
                    AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &mini)
                    return "\(AX.string(w, kAXTitleAttribute) ?? "?") minimized=\((mini as? Bool) ?? false)"
                }
                var header = ["windows: \(winInfo)", "nodes: \(counted)"]
                var fq = AX.children(root), fseen = 0
                while !fq.isEmpty && fseen < 20000 {
                    let n = fq.removeFirst(); fseen += 1
                    let role = AX.string(n, kAXRoleAttribute) ?? ""
                    if ["AXTextField", "AXComboBox", "AXSearchField", "AXTextArea"].contains(role) {
                        header.append("field: \(role) subrole=\(AX.string(n, kAXSubroleAttribute) ?? "") desc=\(AX.string(n, kAXDescriptionAttribute) ?? "") placeholder=\(AX.string(n, kAXPlaceholderValueAttribute) ?? "") value=\(AX.string(n, kAXValueAttribute) ?? "")")
                    }
                    fq += AX.children(n)
                }
                let library = SpotifyUI.first(in: root) { AX.string($0, kAXDescriptionAttribute) == "Your Library" }
                let main = SpotifyUI.first(in: root) { AX.string($0, kAXSubroleAttribute) == "AXLandmarkMain" }
                return header + ["main area: \(main.flatMap { AX.string($0, kAXDescriptionAttribute) } ?? "not found")"]
                    + (library.map { SpotifyUI.libraryRows(in: $0).map { "library: \($0.label)" } } ?? ["library: not found"])
                    + (main.map { SpotifyUI.playButtons(in: $0).prefix(8).map { b in
                        "result: \(b.label)  ⟨\(SpotifyUI.nearbyText(b.element).prefix(6).joined(separator: " · ").prefix(120))⟩"
                    } } ?? [])
            }
            lines += found ?? ["Spotify isn't running"]
            let playing = (try? await Script.tell(SpotifyPlayer.app, "return (player state as text) & \": \" & (name of current track) & \" — \" & (artist of current track)")) ?? "?"
            lines.insert("now playing: \(playing)", at: 1)
            return 0

        case "--app-eval":
            guard await need([.router, .embed]) else { return 1 }
            return await AppEval.run(path: arg)

        case "--asr":
            guard await need([.asr]) else { return 1 }
            do {
                let samples = try AudioFile.load(URL(fileURLWithPath: arg))
                _ = try? await ASR.transcribe(Array(samples.prefix(16000)))
                let t0 = Date()
                let text = try await ASR.transcribe(samples)
                print(String(format: "%.1fs audio → %d ms", Double(samples.count) / 16000, Int(Date().timeIntervalSince(t0) * 1000)))
                print(text)
            } catch { print("error: \(error)"); return 1 }
            return 0

        case "--remember":
            guard await need([.embed]) else { return 1 }
            let e = Entry(kind: .memory, title: Router.titleFrom(arg), body: arg, transcript: arg)
            Store.shared.save(e)
            if let v = try? await Embedder.embed("document: " + e.searchText) { Store.shared.setEmbedding(e.id, v) }
            print("saved \(e.id)")
            return 0

        case "--ask":
            guard await need([.router, .embed]) else { return 1 }
            let t0 = Date()
            let r = await QuestionAgent.answer(arg, useFiles: a.contains("--files"), useWeb: a.contains("--web"))
            print("(\(Int(Date().timeIntervalSince(t0) * 1000)) ms, searched \(r.searched.joined(separator: ", ")))")
            print(r.answer)
            for s in r.sources { print("  · \(s)") }
            return 0

        case "--meeting":
            guard await need([.router]) else { return 1 }
            guard let text = try? String(contentsOfFile: arg, encoding: .utf8) else { print("can't read \(arg)"); return 1 }
            let title = a.count > 2 ? a[2] : "Test meeting"
            let start = Date().addingTimeInterval(-1800)
            let m = Entry(kind: .meeting, title: title, startAt: start, endAt: Date(), status: .processing, source: "cli")
            Store.shared.save(m)
            var t = 0.0
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                Store.shared.appendSegment(MeetingSegment(entryId: m.id, tStart: t, tEnd: t + 10, speaker: parts[0], text: parts[1]))
                t += 12
            }
            let t0 = Date()
            await MeetingProcessor.process(m.id)
            let done = Store.shared.entry(m.id)
            print("(\(Int(Date().timeIntervalSince(t0) * 1000)) ms)\n\(done?.body ?? "")\n\nProposed reminders:")
            for c in Store.shared.children(of: m.id) { print("  · \(c.title) — \(DateResolver.friendly(c.startAt, now: Date()))  [spoken: \(c.meta["spoken_time"] ?? "")]") }
            return 0

        default:
            return 2
        }
    }
}

enum Eval {
    static func run(path: String) async -> Int32 {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("can't read \(path)"); return 1 }
        _ = try? await Router.shared.route("warm up", focus: nil)
        var ok = 0, total = 0
        var latencies: [Int] = []
        var byIntent: [String: (Int, Int)] = [:]
        for line in text.split(separator: "\n") {
            guard let c = JSON.parse(String(line)), let said = c["text"] as? String else { continue }
            total += 1
            let focused = c["focused"] as? Bool ?? false
            let focus = focused ? FocusContext(app: nil, appName: "Slack", bundleId: "", element: nil, role: "AXTextArea",
                                               isTextInput: true, selectedText: "", windowTitle: "") : nil
            guard let r = try? await Router.shared.route(said, focus: focus) else { print("✗ error: \(said)"); continue }
            latencies.append(r.latencyMs)
            let tools = r.calls.map(\.tool)
            var good = r.intent == c["intent"] as? String && tools.first == c["tool"] as? String
            if let t2 = c["tool2"] as? String { good = good && tools.contains(t2) }
            for (k, v) in c["args"] as? [String: Any] ?? [:] {
                let got = r.calls.first?.args[k]
                if let b = v as? Bool { good = good && (got as? Bool) == b }
                else if let s = v as? String { good = good && ((got as? String)?.lowercased().contains(s.lowercased()) ?? false) }
            }
            let intent = c["intent"] as? String ?? "?"
            byIntent[intent, default: (0, 0)].1 += 1
            if good { ok += 1; byIntent[intent, default: (0, 0)].0 += 1 }
            else { print("✗ \(said)\n    → \(r.intent) \(r.calls.map { "\($0.tool) \(JSON.string($0.args))" }.joined(separator: " + "))") }
        }
        latencies.sort()
        let p50 = latencies.isEmpty ? 0 : latencies[latencies.count / 2]
        let p95 = latencies.isEmpty ? 0 : latencies[min(latencies.count - 1, Int(Double(latencies.count) * 0.95))]
        print("\nRouter: \(ok)/\(total) = \(total > 0 ? ok * 100 / total : 0)%   p50 \(p50) ms   p95 \(p95) ms")
        for (k, v) in byIntent.sorted(by: { $0.key < $1.key }) { print("  \(k.padding(toLength: 10, withPad: " ", startingAt: 0)) \(v.0)/\(v.1)") }
        return 0
    }
}

/// Step two of app control: does "skip this song" (+ the app the router named) pick spotify.next?
enum AppEval {
    static func run(path: String) async -> Int32 {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("can't read \(path)"); return 1 }
        await AppCatalog.shared.refresh()
        var ok = 0, total = 0, inTop = 0
        var latencies: [Int] = []
        for line in text.split(separator: "\n") {
            guard let c = JSON.parse(String(line)), let said = c["text"] as? String, let want = c["action"] as? [String] ?? (c["action"] as? String).map({ [$0] }) else { continue }
            total += 1
            let t0 = Date()
            let (target, candidates) = await AppCatalog.shared.candidates(for: said, app: c["app"] as? String ?? "", frontmost: nil)
            let pick = await AppActionTool.pick(said, target: target, candidates: candidates, frontmost: nil)
            latencies.append(Int(Date().timeIntervalSince(t0) * 1000))
            if candidates.contains(where: { want.contains($0.id) }) { inTop += 1 }
            var good = pick.map { want.contains($0.0.id) } ?? want.contains("none")
            for (k, v) in c["args"] as? [String: String] ?? [:] {
                good = good && (pick?.1.string(k).lowercased().contains(v.lowercased()) ?? false)
            }
            if good { ok += 1 } else {
                print("✗ \(said)\n    → \(pick.map { "\($0.0.id) \(JSON.string($0.1.raw))" } ?? "none")   want \(want.joined(separator: " | "))"
                      + (candidates.contains { want.contains($0.id) } ? "" : "  (not in candidates)"))
            }
        }
        latencies.sort()
        let p50 = latencies.isEmpty ? 0 : latencies[latencies.count / 2]
        let p95 = latencies.isEmpty ? 0 : latencies[min(latencies.count - 1, Int(Double(latencies.count) * 0.95))]
        print("\nApp actions: \(ok)/\(total) = \(total > 0 ? ok * 100 / total : 0)%   right action in candidates: \(inTop)/\(total)   p50 \(p50) ms   p95 \(p95) ms")
        return 0
    }
}

/// Visible text inside an element (for probes).
private func texts(_ el: AXUIElement, limit: Int = 200) -> [String] {
    var out: [String] = [], queue = [el], seen = 0
    while !queue.isEmpty && seen < limit {
        let n = queue.removeFirst(); seen += 1
        if AX.string(n, kAXRoleAttribute) == "AXStaticText", let v = AX.string(n, kAXValueAttribute), !v.trimmingCharacters(in: .whitespaces).isEmpty { out.append(v) }
        queue += AX.children(n)
    }
    return out
}
