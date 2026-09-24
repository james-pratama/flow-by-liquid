import Foundation

struct MemoryHit {
    let entry: Entry
    /// Cosine similarity when embeddings are available, otherwise a keyword-rank score in (0, 0.5].
    let score: Float
    /// Matched the query's keywords (BM25).
    let keyword: Bool

    /// Measured on LFM2.5-Embedding-350M: related memories score ≥ 0.2, unrelated ones ≤ 0.13.
    var isRelevant: Bool { keyword || score >= 0.2 }
}

/// The interface Flow's agent uses for memory. The local implementation below is SQLite + embeddings;
/// a cloud-synced or OEM-provided store can implement the same protocol.
protocol MemoryProvider {
    func index(_ entry: Entry)
    func search(_ query: String, limit: Int) async -> [MemoryHit]
}

final class LocalMemory: MemoryProvider {
    static let shared = LocalMemory()

    func index(_ entry: Entry) {
        guard !entry.isExternal else { return }
        let text = "document: " + entry.searchText
        Task.detached(priority: .utility) {
            if let v = try? await Embedder.embed(text) { Store.shared.setEmbedding(entry.id, v) }
        }
    }

    /// Hybrid search: BM25 keyword hits fused with embedding similarity (reciprocal rank fusion).
    /// Everything the user has told Flow or had Flow do: memories, meeting notes, reminders, emails Flow wrote, dictations.
    /// Not past Q&A (answers can be wrong) and not memory-edit logs (they quote forgotten facts).
    static func isKnowledge(_ e: Entry) -> Bool {
        guard [.memory, .meeting, .reminder, .action, .dictation].contains(e.kind) else { return false }
        return !e.title.hasPrefix("Forgot memory:") && !e.title.hasPrefix("Updated memory:") && e.status != .failed
    }

    /// Embeds anything searchable that isn't indexed yet (older entries, actions, dictations).
    func backfill(limit: Int = 200) async {
        for e in Store.shared.unindexed(limit: limit) where Self.isKnowledge(e) {
            if let v = try? await Embedder.embed("document: " + e.searchText) { Store.shared.setEmbedding(e.id, v) }
        }
    }

    func search(_ query: String, limit: Int = 8) async -> [MemoryHit] {
        let store = Store.shared
        let keyword = store.ftsSearch(query, limit: 40).filter(Self.isKnowledge)
        var semantic: [(String, Float)] = []
        if let q = try? await Embedder.embed("query: " + query) {
            semantic = store.allEmbeddings()
                .map { ($0.key, Embedder.cosine(q, $0.value)) }
                .sorted { $0.1 > $1.1 }
                .prefix(40)
                .map { $0 }
        }
        var fused: [String: Double] = [:]
        var cos: [String: Float] = [:]
        for (rank, e) in keyword.enumerated() { fused[e.id, default: 0] += 1.0 / Double(60 + rank) }
        for (rank, (id, c)) in semantic.enumerated() {
            fused[id, default: 0] += 1.0 / Double(60 + rank)
            cos[id] = c
        }
        // Filter to knowledge first, then take the top results (filtering after the cut dropped good matches).
        let ranked = fused.sorted { $0.value > $1.value }
        return ranked.lazy.compactMap { id, _ -> MemoryHit? in
            guard let e = store.entry(id), Self.isKnowledge(e) else { return nil }
            let kwRank = keyword.firstIndex { $0.id == id }
            let score = cos[id] ?? (kwRank.map { Float(0.5) / Float($0 + 1) } ?? 0)
            return MemoryHit(entry: e, score: score, keyword: kwRank != nil)
        }.prefix(limit).map { $0 }
    }
}
