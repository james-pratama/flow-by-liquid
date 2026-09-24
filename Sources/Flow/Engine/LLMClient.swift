import Foundation

enum LLMError: Error, LocalizedError {
    case badResponse(String)
    case unavailable
    var errorDescription: String? {
        switch self {
        case .badResponse(let m): return m
        case .unavailable: return "The model isn't loaded yet"
        }
    }
}

/// Thin client for llama-server's HTTP API.
struct LLMClient {
    let base: URL

    static let router = LLMClient(base: ModelServers.Kind.router.baseURL)
    static let asr = LLMClient(base: ModelServers.Kind.asr.baseURL)
    static let embed = LLMClient(base: ModelServers.Kind.embed.baseURL)

    /// `rawFields` are spliced into the body as pre-serialized JSON (used for order-sensitive schemas).
    func post(_ path: String, _ body: [String: Any], rawFields: [String: String] = [:],
              timeout: TimeInterval = 120) async throws -> [String: Any] {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        var payload = try JSONSerialization.data(withJSONObject: body)
        if !rawFields.isEmpty, var text = String(data: payload, encoding: .utf8), text.hasSuffix("}") {
            text.removeLast()
            for (k, v) in rawFields { text += ",\"\(k)\":\(v)" }
            payload = Data((text + "}").utf8)
        }
        req.httpBody = payload
        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch { throw LLMError.unavailable }
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.badResponse(String(data: data, encoding: .utf8) ?? "HTTP error")
        }
        return obj
    }

    /// Raw completion with a hand-built ChatML prompt. Used for LFM2.5-2.6B so Flow can prefill an empty
    /// <think></think> block (skipping reasoning for latency) and constrain output with a JSON schema.
    func complete(prompt: String, schema: OJ? = nil, maxTokens: Int = 400,
                  temperature: Double = 0, stop: [String] = ["<|im_end|>"]) async throws -> (text: String, timings: [String: Any]) {
        var body: [String: Any] = [
            "prompt": prompt, "n_predict": maxTokens, "temperature": temperature,
            "cache_prompt": true, "stop": stop,
        ]
        if temperature > 0 { body["min_p"] = 0.15; body["repeat_penalty"] = 1.05 }
        let obj = try await post("completion", body, rawFields: schema.map { ["json_schema": $0.json] } ?? [:])
        guard let text = obj["content"] as? String else { throw LLMError.badResponse("no content") }
        return (text, obj["timings"] as? [String: Any] ?? [:])
    }

    func chat(_ messages: [[String: Any]], maxTokens: Int = 400, temperature: Double = 0) async throws -> String {
        let obj = try await post("v1/chat/completions", [
            "messages": messages, "max_tokens": maxTokens, "temperature": temperature, "cache_prompt": true,
        ])
        guard let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else { throw LLMError.badResponse("no choices") }
        return content
    }
}

/// Builds LFM ChatML prompts with thinking disabled.
enum ChatML {
    /// Same prompt but with the model's reasoning left open ("<think>"), for questions that deserve thought.
    static func thinkingPrompt(system: String, turns: [(user: String, assistant: String)] = [], user: String) -> String {
        String(prompt(system: system, turns: turns, user: user).dropLast("</think>".count))
    }

    static func prompt(system: String, turns: [(user: String, assistant: String)] = [], user: String,
                       assistantPrefix: String = "") -> String {
        var s = "<|im_start|>system\n\(system)<|im_end|>\n"
        for t in turns {
            s += "<|im_start|>user\n\(t.user)<|im_end|>\n<|im_start|>assistant\n<think></think>\(t.assistant)<|im_end|>\n"
        }
        s += "<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n<think></think>\(assistantPrefix)"
        return s
    }
}

enum JSON {
    static func parse(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
    static func string(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "\(obj)" }
        return String(data: d, encoding: .utf8) ?? ""
    }
}

/// Order-preserving JSON for schemas: llama.cpp generates object properties in the order written,
/// and the router relies on "kind" before "calls" and "tool" before "args". Stored as pre-rendered text.
struct OJ {
    let json: String

    static func string(_ s: String) -> OJ { OJ(json: quote(s)) }
    static func int(_ i: Int) -> OJ { OJ(json: String(i)) }
    static func object(_ kv: [(String, OJ)]) -> OJ { OJ(json: "{" + kv.map { "\(quote($0.0)):\($0.1.json)" }.joined(separator: ",") + "}") }
    static func array(_ items: [OJ]) -> OJ { OJ(json: "[" + items.map(\.json).joined(separator: ",") + "]") }

    private static func quote(_ s: String) -> String {
        let d = try! JSONSerialization.data(withJSONObject: [s])
        let t = String(data: d, encoding: .utf8)!
        return String(t.dropFirst().dropLast())
    }

    static let str = OJ.object([("type", .string("string"))])
    static let bool = OJ.object([("type", .string("boolean"))])
    static func enumeration(_ values: [String]) -> OJ { .object([("type", .string("string")), ("enum", .array(values.map(OJ.string)))]) }
    /// An object whose properties are all required, in the given order.
    static func props(_ props: [(String, OJ)]) -> OJ {
        .object([("type", .string("object")), ("properties", .object(props)), ("required", .array(props.map { .string($0.0) }))])
    }
    static func array(_ items: OJ, min: Int = 0, max: Int? = nil) -> OJ {
        var kv: [(String, OJ)] = [("type", .string("array")), ("items", items), ("minItems", .int(min))]
        if let max { kv.append(("maxItems", .int(max))) }
        return .object(kv)
    }
    static func anyOf(_ options: [OJ]) -> OJ { .object([("anyOf", .array(options))]) }
}
