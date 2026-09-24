import Foundation

/// Launches and supervises the local llama-server processes Flow talks to.
/// If a healthy server is already listening on a port (e.g. started by scripts/run-servers.sh), it is reused.
final class ModelServers: ObservableObject {
    static let shared = ModelServers()

    enum Kind: String, CaseIterable, Identifiable {
        case router, asr, embed
        var id: String { rawValue }

        var title: String {
            switch self {
            case .router: return "LFM2.5-2.6B · agent"
            case .asr: return "LFM2.5-Audio-1.5B · speech"
            case .embed: return "LFM2.5-Embedding-350M · memory search"
            }
        }
        var port: Int {
            switch self {
            case .router: return 8181
            case .asr: return 8182
            case .embed: return 8183
            }
        }
        var files: [String] {
            switch self {
            case .router: return ["LFM2.5-2.6B-Q4_K_M.gguf"]
            case .asr: return ["LFM2.5-Audio-1.5B-Q8_0.gguf", "mmproj-LFM2.5-Audio-1.5B-Q8_0.gguf"]
            case .embed: return ["LFM2.5-Embedding-350M-Q8_0.gguf"]
            }
        }
        var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

        func arguments(models: URL) -> [String] {
            let path = { (name: String) in models.appendingPathComponent(name).path }
            var args = ["--host", "127.0.0.1", "--port", String(port), "-ngl", "99"]
            switch self {
            case .router:
                // Two slots: one stays warm for hotkey routing, the other handles meeting summaries.
                args += ["-m", path(files[0]), "-c", "32768", "-np", "2"]
            case .asr:
                args += ["-m", path(files[0]), "--mmproj", path(files[1]), "-c", "8192", "-np", "2"]
            case .embed:
                args += ["-m", path(files[0]), "--embeddings", "-c", "4096", "-np", "2"]
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
            flowLog("\(kind.rawValue) server exited (\(proc.terminationStatus))")
            DispatchQueue.main.async {
                if self.status[kind] != .stopped { self.status[kind] = .failed("exited with \(proc.terminationStatus)") }
            }
        }
        do { try p.run() } catch {
            set(kind, .failed(error.localizedDescription)); return
        }
        processes[kind] = p
        flowLog("started \(kind.rawValue) server pid \(p.processIdentifier)")

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
        processes[kind]?.terminate()
        processes[kind] = nil
    }

    func stopAll() { Kind.allCases.forEach(stop) }

    static func healthy(_ kind: Kind) async -> Bool {
        var req = URLRequest(url: kind.baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 1
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
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
