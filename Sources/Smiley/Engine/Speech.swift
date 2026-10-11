import Foundation

/// Speech-to-text with Qwen3-ASR-1.7B served by llama-server.
enum ASR {
    static func transcribe(_ samples: [Float], sampleRate: Int = 16000) async throws -> String {
        // Near-silence makes the model invent a sentence, so it never gets to hear it.
        guard samples.count > sampleRate / 5, AudioMath.peakFrameRMS(samples, frame: sampleRate / 10) >= 0.002 else { return "" }
        let wav = WAV.encode(samples, sampleRate: sampleRate).base64EncodedString()
        let seconds = Double(samples.count) / Double(sampleRate)
        var messages: [[String: Any]] = [
            ["role": "user", "content": [["type": "input_audio", "input_audio": ["data": wav, "format": "wav"]]]],
        ]
        // The speech model treats its system message as context: words listed there are heard and spelled as written.
        let words = Settings.shared.dictionary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { messages.insert(["role": "system", "content": words], at: 0) }
        let text = try await LLMClient.asr.chat(messages, maxTokens: Int(40 + seconds * 8))
        return clean(text)
    }

    static func clean(_ s: String) -> String {
        // The model answers "language English<asr_text>…": keep what follows the tag.
        var t = s.components(separatedBy: "<asr_text>").last ?? s
        t = t.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // Whisper-style hallucinations on silence.
        let junk: Set<String> = ["", ".", "you", "thank you.", "thanks for watching!", "[silence]", "[music]"]
        return junk.contains(t.lowercased()) ? "" : t
    }
}

enum WAV {
    static func encode(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        let byteRate = sampleRate * 2
        let dataSize = samples.count * 2
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; data.append(Data(bytes: &x, count: 2)) }
        data.append("RIFF".data(using: .ascii)!); u32(36 + dataSize)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(sampleRate); u32(byteRate); u16(2); u16(16)
        data.append("data".data(using: .ascii)!); u32(dataSize)
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count { pcm[i] = Int16(max(-1, min(1, samples[i])) * 32767) }
        pcm.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        return data
    }
}

enum AudioMath {
    static func rms(_ s: ArraySlice<Float>) -> Float {
        guard !s.isEmpty else { return 0 }
        var sum: Float = 0
        for v in s { sum += v * v }
        return (sum / Float(s.count)).squareRoot()
    }
    static func rms(_ s: [Float]) -> Float { rms(s[...]) }

    /// RMS of the loudest frame: robust to long pauses when deciding whether a chunk has any speech.
    static func peakFrameRMS(_ s: [Float], frame: Int) -> Float {
        var best: Float = 0
        var i = 0
        while i < s.count {
            best = max(best, rms(s[i..<min(i + frame, s.count)]))
            i += frame
        }
        return best
    }
}

/// Dense embeddings with Qwen3-Embedding-0.6B. Asymmetric: a query carries an instruction, a document is embedded as it is.
enum Embedder {
    enum Role { case query, document }
    /// The model file, recorded with the stored vectors: vectors from different models can't be compared.
    static var model: String { ModelServers.Kind.embed.files[0] }

    private static func input(_ text: String, _ role: Role, limit: Int) -> String {
        let body = String(text.prefix(limit))
        return role == .query ? "Instruct: Given a request, retrieve the notes and actions that are relevant to it\nQuery: \(body)" : body
    }

    static func embed(_ text: String, as role: Role) async throws -> [Float] {
        let obj = try await LLMClient.embed.post("v1/embeddings", ["input": input(text, role, limit: 4000)], timeout: 30)
        guard let data = obj["data"] as? [[String: Any]],
              let raw = data.first?["embedding"] as? [Double] else { throw LLMError.badResponse("no embedding") }
        var v = raw.map { Float($0) }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        if norm > 0 { v = v.map { $0 / norm } }
        return v
    }

    /// Several texts in one request (llama-server batches them).
    static func embedBatch(_ texts: [String], as role: Role) async throws -> [[Float]] {
        let obj = try await LLMClient.embed.post("v1/embeddings", ["input": texts.map { input($0, role, limit: 2000) }], timeout: 60)
        guard let data = obj["data"] as? [[String: Any]], data.count == texts.count else { throw LLMError.badResponse("no embeddings") }
        return data.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }.map { item in
            var v = (item["embedding"] as? [Double] ?? []).map { Float($0) }
            let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
            if norm > 0 { v = v.map { $0 / norm } }
            return v
        }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var s: Float = 0
        for i in 0..<a.count { s += a[i] * b[i] }
        return s
    }
}
