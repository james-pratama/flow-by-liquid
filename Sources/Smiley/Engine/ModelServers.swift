import Foundation

/// Launches and supervises the local llama-server processes Smiley talks to.
/// If a server is already listening on a port with the right model (e.g. started by scripts/run-servers.sh), it is reused.
final class ModelServers: ObservableObject {
    static let shared = ModelServers()

    enum Kind: String, CaseIterable, Identifiable {
        /// `router` is small and fast: it decides what a command means. `answer` is larger: it answers, writes and takes notes.
        case router, answer, asr, embed
        var id: String { rawValue }

        var title: String {
            switch self {
            case .router: return "Commands"
            case .answer: return "Answers & writing"
            case .asr: return "Speech"
            case .embed: return "Memory search"
            }
        }
        var port: Int {
            switch self {
            case .router: return 8191
            case .asr: return 8192
            case .embed: return 8193
            case .answer: return 8194
            }
        }
        var files: [String] {
            switch self {
            case .router: return ["Qwen3.5-4B-Q4_K_M.gguf"]
            case .answer: return ["Qwen3.5-9B-Q4_K_M.gguf"]
            case .asr: return ["Qwen3-ASR-1.7B-Q8_0.gguf", "mmproj-Qwen3-ASR-1.7B-Q8_0.gguf"]
            case .embed: return ["Qwen3-Embedding-0.6B-Q8_0.gguf"]
            }
        }
        var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

        func arguments(models: URL) -> [String] {
            let path = { (name: String) in models.appendingPathComponent(name).path }
            // --cache-ram 0: llama-server otherwise parks idle prompts in up to 8 GB of host memory per server,
            // which here cost memory and made routing slower, not faster.
            var args = ["--host", "127.0.0.1", "--port", String(port), "-ngl", "99", "--cache-ram", "0"]
            switch self {
            case .router:
                // Two slots: one stays warm for hotkey routing, the other handles follow-ups and action picks.
                // The small batch is for latency: this model can only rewind its cached prompt to a checkpoint one
                // batch before the end, so each command re-reads that much of the (otherwise cached) few-shot prefix.
                args += ["-m", path(files[0]), "-c", "16384", "-np", "2", "-b", "128"]
            case .answer:
                // Two slots: an answer never waits behind a meeting summary.
                args += ["-m", path(files[0]), "-c", "32768", "-np", "2"]
            case .asr:
                args += ["-m", path(files[0]), "--mmproj", path(files[1]), "-c", "8192", "-np", "2"]
            case .embed:
                // This embedding model reads its vector off the last token.
                args += ["-m", path(files[0]), "--embeddings", "--pooling", "last", "-c", "4096", "-np", "2"]
            }
            return args
        }
    }

    enum Status: Equatable {
        case stopped, missingModel, starting, ready, failed(String)
        var label: String {
            switch self {
            case .stopped: return "Stopped"
            case .missingModel: return "Model not downloaded"
            case .starting: return "Loading…"
            case .ready: return "Ready"
            case .failed(let m): return "Failed: \(m)"
            }
        }
    }

    @Published private(set) var status: [Kind: Status] = Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0, .stopped) })
    private var processes: [Kind: Process] = [:]
    /// `start` runs for all three servers at once, off the main thread, so `processes` needs guarding.
    private let processesLock = NSLock()

    /// Records the process serving `kind` (nil when stopped) and returns the one it replaces.
    @discardableResult
    private func track(_ process: Process?, for kind: Kind) -> Process? {
        processesLock.lock(); defer { processesLock.unlock() }
        let old = processes[kind]
        processes[kind] = process
        return old
    }

    var allReady: Bool { Kind.allCases.allSatisfy { status[$0] == .ready } }

    static func findLlamaServer() -> String? {
        let custom = Settings.shared.llamaServerPath
        let candidates = [custom, "/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
        return candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }

    func startAll(_ kinds: [Kind] = Kind.allCases) {
        for k in kinds { Task { await self.start(k) } }
    }

    private func set(_ k: Kind, _ s: Status) {
        DispatchQueue.main.async { self.status[k] = s }
    }

    func start(_ kind: Kind) async {
        if await Self.healthy(kind) { set(kind, .ready); return }
        let models = Paths.models
        guard kind.files.allSatisfy({ FileManager.default.fileExists(atPath: models.appendingPathComponent($0).path) }) else {
            set(kind, .missingModel); return
        }
        guard let exe = Self.findLlamaServer() else {
            set(kind, .failed("llama-server not found (brew install llama.cpp)")); return
        }
        set(kind, .starting)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = kind.arguments(models: models)
        let logURL = Paths.logs.appendingPathComponent("\(kind.rawValue).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: logURL) { p.standardOutput = h; p.standardError = h }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            smileyLog("\(kind.rawValue) server exited (\(proc.terminationStatus))")
            DispatchQueue.main.async {
                if self.status[kind] != .stopped { self.status[kind] = .failed("exited with \(proc.terminationStatus)") }
            }
        }
        do { try p.run() } catch {
            set(kind, .failed(error.localizedDescription)); return
        }
        track(p, for: kind)
        smileyLog("started \(kind.rawValue) server pid \(p.processIdentifier)")

        for _ in 0..<240 {
            if await Self.healthy(kind) {
                set(kind, .ready)
                if kind == .router { await Router.shared.warmUp() }
                return
            }
            if !p.isRunning { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        set(kind, .failed("timed out loading"))
    }

    func restart(_ kind: Kind) {
        stop(kind)
        Task { try? await Task.sleep(nanoseconds: 500_000_000); await start(kind) }
    }

    func stop(_ kind: Kind) {
        set(kind, .stopped)
        track(nil, for: kind)?.terminate()
    }

    func stopAll() { Kind.allCases.forEach(stop) }

    /// Up, and serving this kind's model: a server left over from an older build may still hold the port with another one.
    static func healthy(_ kind: Kind) async -> Bool {
        var req = URLRequest(url: kind.baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 1
        guard let (_, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        var props = URLRequest(url: kind.baseURL.appendingPathComponent("props"))
        props.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: props),
              let model = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["model_path"] as? String else { return true }
        return model.hasSuffix(kind.files[0])
    }

    /// Waits until a server is ready (used by the CLI and by tools that need a model).
    func waitReady(_ kind: Kind, timeout: TimeInterval = 120) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await Self.healthy(kind) { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }
}
