import Foundation
import Combine

/// Local store for entries, tool runs, meeting transcripts, embeddings and tool policies.
/// Views observe `revision` and re-query when it changes.
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var revision = 0
    let db: SQLiteDB
    private var embeddingCache: [String: [Float]]?
    private let cacheLock = NSLock()

    private init() {
        Paths.ensure()
        do { db = try SQLiteDB(path: Paths.database.path) } catch { fatalError("Flow could not open its database: \(error)") }
        migrate()
    }

    private func migrate() {
        do {
            try db.exec("""
            CREATE TABLE IF NOT EXISTS entries(
              id TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT NOT NULL, body TEXT, transcript TEXT,
              start_at REAL NOT NULL, end_at REAL, status TEXT NOT NULL, source TEXT, session_id TEXT,
              parent_id TEXT, meta TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL, deleted_at REAL);
            CREATE INDEX IF NOT EXISTS idx_entries_start ON entries(start_at);
            CREATE INDEX IF NOT EXISTS idx_entries_parent ON entries(parent_id);
            CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(id UNINDEXED, title, body, transcript);
            CREATE TABLE IF NOT EXISTS embeddings(entry_id TEXT PRIMARY KEY, vector BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS tool_runs(
              id TEXT PRIMARY KEY, entry_id TEXT, tool TEXT, args TEXT, result TEXT, status TEXT,
              latency_ms INTEGER, created_at REAL);
            CREATE INDEX IF NOT EXISTS idx_runs_entry ON tool_runs(entry_id);
            CREATE TABLE IF NOT EXISTS meeting_segments(
              id INTEGER PRIMARY KEY AUTOINCREMENT, entry_id TEXT, t_start REAL, t_end REAL, speaker TEXT, text TEXT);
            CREATE INDEX IF NOT EXISTS idx_segments_entry ON meeting_segments(entry_id);
            CREATE TABLE IF NOT EXISTS tool_policy(tool TEXT PRIMARY KEY, mode TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS catalog_vectors(text TEXT PRIMARY KEY, vector BLOB NOT NULL);
            """)
        } catch {
            flowLog("migration failed: \(error)")
        }
    }

    private func changed() {
        DispatchQueue.main.async { self.revision += 1 }
    }

    // MARK: Entries

    func save(_ entry: Entry) {
        var e = entry
        e.updatedAt = Date()
        let meta = (try? JSONSerialization.data(withJSONObject: e.meta)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        do {
            try db.transaction {
                try db.run("""
                INSERT OR REPLACE INTO entries(id, kind, title, body, transcript, start_at, end_at, status, source,
                  session_id, parent_id, meta, created_at, updated_at, deleted_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)
                """, [e.id, e.kind.rawValue, e.title, e.body, e.transcript, e.startAt, e.endAt, e.status.rawValue,
                      e.source, e.sessionId, e.parentId, meta, e.createdAt, e.updatedAt])
                try db.run("DELETE FROM entries_fts WHERE id = ?", [e.id])
                try db.run("INSERT INTO entries_fts(id, title, body, transcript) VALUES(?,?,?,?)",
                           [e.id, e.title, e.body, e.transcript])
            }
        } catch {
            flowLog("save entry failed: \(error)")
        }
        changed()
    }

    func update(_ id: String, _ mutate: (inout Entry) -> Void) {
        guard var e = entry(id) else { return }
        mutate(&e)
        save(e)
    }

    func delete(_ id: String) {
        _ = try? db.run("UPDATE entries SET deleted_at = ? WHERE id = ? OR parent_id = ?", [Date(), id, id])
        _ = try? db.run("DELETE FROM entries_fts WHERE id = ?", [id])
        _ = try? db.run("DELETE FROM embeddings WHERE entry_id = ?", [id])
        cacheLock.lock(); embeddingCache?[id] = nil; cacheLock.unlock()
        changed()
    }

    /// Undo for `delete`.
    func restore(_ id: String) {
        _ = try? db.run("UPDATE entries SET deleted_at = NULL WHERE id = ? OR parent_id = ?", [id, id])
        if let e = entry(id) { save(e) }   // re-indexes search
    }

    func entry(_ id: String) -> Entry? {
        (try? db.query("SELECT * FROM entries WHERE id = ? AND deleted_at IS NULL", [id]))?.first.map(Self.decode)
    }

    /// Entries overlapping [from, to).
    func entries(from: Date, to: Date) -> [Entry] {
        let rows = (try? db.query("""
            SELECT * FROM entries WHERE deleted_at IS NULL AND status != 'dismissed'
              AND start_at < ? AND COALESCE(end_at, start_at) >= ?
            ORDER BY start_at
            """, [to, from])) ?? []
        return rows.map(Self.decode)
    }

    func recent(limit: Int = 400, kinds: Set<EntryKind>? = nil) -> [Entry] {
        var sql = "SELECT * FROM entries WHERE deleted_at IS NULL AND status != 'dismissed' AND parent_id IS NULL"
        var args: [SQLConvertible] = []
        if let kinds, !kinds.isEmpty {
            sql += " AND kind IN (" + kinds.map { _ in "?" }.joined(separator: ",") + ")"
            args += kinds.map { $0.rawValue }
        }
        // Reminders sort by when they were created, everything else by when it happened.
        sql += " ORDER BY CASE WHEN kind = 'reminder' THEN created_at ELSE start_at END DESC LIMIT ?"
        args.append(limit)
        return ((try? db.query(sql, args)) ?? []).map(Self.decode)
    }

    /// the user's recent exchanges with Flow (oldest first), one per spoken command: what they said and how Flow responded.
    /// Dictation isn't a conversation, so it's excluded.
    func conversation(limit: Int = 15, excludingSession: String? = nil) -> [(user: String, assistant: String, at: Date)] {
        let rows = (try? db.query("""
            SELECT * FROM entries WHERE deleted_at IS NULL AND source = 'hotkey' AND session_id IS NOT NULL
              AND kind != 'dictation' ORDER BY created_at DESC LIMIT ?
            """, [limit * 4])) ?? []
        var order: [String] = []
        var bySession: [String: [Entry]] = [:]
        for e in rows.map(Self.decode) {
            guard let s = e.sessionId, s != excludingSession else { continue }
            if bySession[s] == nil { order.append(s) }
            bySession[s, default: []].append(e)
        }
        // Things the user asked Flow to forget are dropped from the conversation too, not just from memory.
        let forgotten = rows.map(Self.decode).filter { $0.title.hasPrefix("Forgot memory:") }
        let forgottenWords = Set(forgotten.flatMap { f in
            (f.title + " " + f.body).lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 3 }
        }).subtracting(["forgot", "memory", "that", "what", "where", "with", "have", "from", "this", "your"])
        let turns = order.prefix(limit).compactMap { s -> (String, String, Date)? in
            let entries = bySession[s]!.sorted { $0.createdAt < $1.createdAt }
            guard let said = entries.first(where: { !$0.transcript.isEmpty })?.transcript else { return nil }
            let reply = entries.map { e -> String in
                switch e.kind {
                case .question: return e.body
                case .memory: return "(Saved to memory: \(e.title))"
                case .reminder: return "(Reminder set: \(e.title), \(DateResolver.friendly(e.startAt, now: e.createdAt)))"
                case .meeting: return "(Started transcribing \(e.title))"
                default: return e.title.hasPrefix("Forgot memory:") ? "(Forgot that, as you asked)" : "(\(e.title))"
                }
            }.joined(separator: " ")
            if !forgottenWords.isEmpty, !entries.contains(where: { $0.title.hasPrefix("Forgot memory:") }) {
                let words = Set((said + " " + reply).lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted))
                if words.intersection(forgottenWords).count >= 2 { return nil }
            }
            return (said, reply, entries[0].createdAt)
        }
        return turns.reversed()
    }

    func unindexed(limit: Int) -> [Entry] {
        ((try? db.query("""
            SELECT * FROM entries WHERE deleted_at IS NULL AND status != 'scheduled'
              AND id NOT IN (SELECT entry_id FROM embeddings) ORDER BY created_at DESC LIMIT ?
            """, [limit])) ?? []).map(Self.decode)
    }

    func children(of id: String) -> [Entry] {
        ((try? db.query("SELECT * FROM entries WHERE parent_id = ? AND deleted_at IS NULL ORDER BY start_at", [id])) ?? [])
            .map(Self.decode)
    }

    func pendingReminders() -> [Entry] {
        ((try? db.query("""
            SELECT * FROM entries WHERE kind = 'reminder' AND status = 'pending' AND deleted_at IS NULL ORDER BY start_at
            """)) ?? []).map(Self.decode)
    }

    func lastMeeting() -> Entry? {
        (try? db.query("""
            SELECT * FROM entries WHERE kind = 'meeting' AND deleted_at IS NULL AND status IN ('done','processing')
            ORDER BY start_at DESC LIMIT 1
            """))?.first.map(Self.decode)
    }

    func ftsSearch(_ query: String, limit: Int = 20) -> [Entry] {
        let stop: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "is", "are", "was", "what",
                                 "who", "when", "where", "how", "did", "do", "does", "i", "my", "me", "about", "that", "this", "with"]
        let tokens = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stop.contains($0) }
        guard !tokens.isEmpty else { return [] }
        let match = tokens.map { "\"\($0)\"*" }.joined(separator: " OR ")
        let rows = (try? db.query("""
            SELECT e.* FROM entries_fts f JOIN entries e ON e.id = f.id
            WHERE entries_fts MATCH ? AND e.deleted_at IS NULL
            ORDER BY bm25(entries_fts) LIMIT ?
            """, [match, limit])) ?? []
        return rows.map(Self.decode)
    }

    // MARK: Embeddings

    func setEmbedding(_ entryId: String, _ vector: [Float]) {
        let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        _ = try? db.run("INSERT OR REPLACE INTO embeddings(entry_id, vector) VALUES(?,?)", [entryId, data])
        cacheLock.lock(); embeddingCache?[entryId] = vector; cacheLock.unlock()
    }

    func allEmbeddings() -> [String: [Float]] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cache = embeddingCache { return cache }
        var out: [String: [Float]] = [:]
        let rows = (try? db.query("""
            SELECT m.entry_id, m.vector FROM embeddings m JOIN entries e ON e.id = m.entry_id WHERE e.deleted_at IS NULL
            """)) ?? []
        for row in rows {
            guard let id = row["entry_id"]?.string, let d = row["vector"]?.data else { continue }
            out[id] = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        embeddingCache = out
        return out
    }

    /// Embeddings of app actions (see AppCatalog), keyed by the text that was embedded.
    func catalogVectors(_ texts: [String]) -> [String: [Float]] {
        var out: [String: [Float]] = [:]
        for chunk in stride(from: 0, to: texts.count, by: 200).map({ Array(texts[$0..<min($0 + 200, texts.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = (try? db.query("SELECT text, vector FROM catalog_vectors WHERE text IN (\(marks))", chunk)) ?? []
            for row in rows {
                guard let t = row["text"]?.string, let d = row["vector"]?.data else { continue }
                out[t] = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
        }
        return out
    }

    func setCatalogVectors(_ vectors: [String: [Float]]) {
        try? db.transaction {
            for (text, v) in vectors {
                _ = try db.run("INSERT OR REPLACE INTO catalog_vectors(text, vector) VALUES(?,?)",
                               [text, v.withUnsafeBufferPointer { Data(buffer: $0) }])
            }
        }
    }

    // MARK: Tool runs

    func addToolRun(_ run: ToolRun) {
        _ = try? db.run("INSERT INTO tool_runs(id, entry_id, tool, args, result, status, latency_ms, created_at) VALUES(?,?,?,?,?,?,?,?)",
                        [run.id, run.entryId, run.tool, run.args, run.result, run.status, run.latencyMs, run.createdAt])
        changed()
    }

    func toolRuns(entryId: String) -> [ToolRun] {
        ((try? db.query("SELECT * FROM tool_runs WHERE entry_id = ? ORDER BY created_at", [entryId])) ?? []).map { r in
            ToolRun(id: r["id"]?.string ?? "", entryId: entryId, tool: r["tool"]?.string ?? "", args: r["args"]?.string ?? "",
                    result: r["result"]?.string ?? "", status: r["status"]?.string ?? "",
                    latencyMs: Int(r["latency_ms"]?.int ?? 0),
                    createdAt: Date(timeIntervalSince1970: r["created_at"]?.double ?? 0))
        }
    }

    func runCounts() -> [String: Int] {
        var out: [String: Int] = [:]
        for r in (try? db.query("SELECT tool, COUNT(*) AS n FROM tool_runs GROUP BY tool")) ?? [] {
            if let t = r["tool"]?.string { out[t] = Int(r["n"]?.int ?? 0) }
        }
        return out
    }

    // MARK: Meetings

    func appendSegment(_ s: MeetingSegment) {
        _ = try? db.run("INSERT INTO meeting_segments(entry_id, t_start, t_end, speaker, text) VALUES(?,?,?,?,?)",
                        [s.entryId, s.tStart, s.tEnd, s.speaker, s.text])
        changed()
    }

    func segments(_ entryId: String) -> [MeetingSegment] {
        ((try? db.query("SELECT * FROM meeting_segments WHERE entry_id = ? ORDER BY t_start", [entryId])) ?? []).map { r in
            MeetingSegment(entryId: entryId, tStart: r["t_start"]?.double ?? 0, tEnd: r["t_end"]?.double ?? 0,
                           speaker: r["speaker"]?.string ?? "", text: r["text"]?.string ?? "")
        }
    }

    // MARK: Policies

    func policy(_ tool: String) -> ToolPolicy? {
        (try? db.query("SELECT mode FROM tool_policy WHERE tool = ?", [tool]))?.first?["mode"]?.string.flatMap(ToolPolicy.init)
    }

    func setPolicy(_ tool: String, _ policy: ToolPolicy) {
        _ = try? db.run("INSERT OR REPLACE INTO tool_policy(tool, mode) VALUES(?,?)", [tool, policy.rawValue])
        changed()
    }

    // MARK: Decoding

    private static func decode(_ r: SQLRow) -> Entry {
        var meta: [String: String] = [:]
        if let s = r["meta"]?.string, let d = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: String] { meta = obj }
        return Entry(
            id: r["id"]?.string ?? UUID().uuidString,
            kind: EntryKind(rawValue: r["kind"]?.string ?? "") ?? .memory,
            title: r["title"]?.string ?? "",
            body: r["body"]?.string ?? "",
            transcript: r["transcript"]?.string ?? "",
            startAt: Date(timeIntervalSince1970: r["start_at"]?.double ?? 0),
            endAt: r["end_at"]?.double.map { Date(timeIntervalSince1970: $0) },
            status: EntryStatus(rawValue: r["status"]?.string ?? "") ?? .done,
            source: r["source"]?.string ?? "",
            sessionId: r["session_id"]?.string,
            parentId: r["parent_id"]?.string,
            meta: meta,
            createdAt: Date(timeIntervalSince1970: r["created_at"]?.double ?? 0),
            updatedAt: Date(timeIntervalSince1970: r["updated_at"]?.double ?? 0))
    }
}
