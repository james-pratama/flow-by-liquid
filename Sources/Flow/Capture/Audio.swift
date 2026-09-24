import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// One microphone engine shared by push-to-talk and meeting capture. Delivers 16 kHz mono Float32 samples.
final class AudioHub {
    static let shared = AudioHub()
    static let sampleRate = 16000.0

    private let engine = AVAudioEngine()
    private var subscribers: [UUID: ([Float]) -> Void] = [:]
    private let lock = NSLock()
    private var running = false
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioHub.sampleRate, channels: 1, interleaved: false)!
    private var configObserver: NSObjectProtocol?

    /// Test mode (CLI): no microphone; audio arrives through `inject`.
    var simulated = false

    func subscribe(_ handler: @escaping ([Float]) -> Void) throws -> UUID {
        let id = UUID()
        lock.lock(); subscribers[id] = handler; let needsStart = !running && !simulated; lock.unlock()
        if needsStart { try start() }
        return id
    }

    func inject(_ samples: [Float]) {
        lock.lock(); let handlers = Array(subscribers.values); lock.unlock()
        handlers.forEach { $0(samples) }
    }

    func unsubscribe(_ id: UUID) {
        lock.lock(); subscribers[id] = nil; let empty = subscribers.isEmpty; lock.unlock()
        if empty && !simulated { stop() }
    }

    private func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw ToolError("No microphone available") }
        guard let converter = AVAudioConverter(from: format, to: target) else { throw ToolError("Unsupported microphone format") }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * self.target.sampleRate / format.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: self.target, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            guard error == nil, let ch = out.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            self.lock.lock(); let handlers = Array(self.subscribers.values); self.lock.unlock()
            handlers.forEach { $0(samples) }
        }
        engine.prepare()
        try engine.start()
        running = true
        flowLog("mic started (\(Int(format.sampleRate)) Hz, \(format.channelCount) ch)")
        if configObserver == nil {
            // Headphones plugged in / device switched: rebuild the tap with the new format.
            configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); let wanted = !self.subscribers.isEmpty; self.lock.unlock()
                guard wanted else { return }
                flowLog("mic configuration changed; restarting")
                self.engine.stop(); self.running = false
                do { try self.start() } catch { flowLog("mic restart failed: \(error.localizedDescription)") }
            }
        }
    }

    private func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        flowLog("mic stopped")
    }
}

/// Captures what other apps play (the other side of a call) via ScreenCaptureKit. Needs Screen & System Audio Recording.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "flow.systemaudio")
    var onSamples: (([Float]) -> Void)?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw ToolError("No display to capture") }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        // Video is required by the API; keep it tiny and slow.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid,
              let desc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else { return }
        var blockBuffer: CMBlockBuffer?
        var abl = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: &abl, bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, let data = abl.mBuffers.mData else { return }
        let count = Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        var samples = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        if asbd.mSampleRate > 0 && Int(asbd.mSampleRate) != 16000 {
            samples = Resample.linear(samples, from: asbd.mSampleRate, to: 16000)
        }
        onSamples?(samples)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        flowLog("system audio stopped: \(error.localizedDescription)")
    }
}

enum Resample {
    static func linear(_ x: [Float], from: Double, to: Double) -> [Float] {
        guard !x.isEmpty, from != to else { return x }
        let n = Int(Double(x.count) * to / from)
        var out = [Float](repeating: 0, count: n)
        let step = from / to
        for i in 0..<n {
            let p = Double(i) * step
            let j = Int(p)
            let f = Float(p - Double(j))
            out[i] = j + 1 < x.count ? x[j] * (1 - f) + x[j + 1] * f : x[min(j, x.count - 1)]
        }
        return out
    }
}

/// Loads an audio file as 16 kHz mono (used by the CLI).
enum AudioFile {
    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buf)
        guard let conv = AVAudioConverter(from: file.processingFormat, to: target),
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * 16000 / file.processingFormat.sampleRate) + 64)
        else { return [] }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, st in
            if fed { st.pointee = .endOfStream; return nil }
            fed = true; st.pointee = .haveData; return buf
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}
