import Foundation
import SQLite3

enum SQLValue {
    case text(String), int(Int64), real(Double), blob(Data), null

    var string: String? { if case .text(let s) = self { return s }; return nil }
    var double: Double? {
        switch self {
        case .real(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    var int: Int64? {
        switch self {
        case .int(let i): return i
        case .real(let d): return Int64(d)
        default: return nil
        }
    }
    var data: Data? { if case .blob(let d) = self { return d }; return nil }
}

protocol SQLConvertible { var sqlValue: SQLValue { get } }
extension String: SQLConvertible { var sqlValue: SQLValue { .text(self) } }
extension Int: SQLConvertible { var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLConvertible { var sqlValue: SQLValue { .int(self) } }
extension Double: SQLConvertible { var sqlValue: SQLValue { .real(self) } }
extension Bool: SQLConvertible { var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Data: SQLConvertible { var sqlValue: SQLValue { .blob(self) } }
extension Date: SQLConvertible { var sqlValue: SQLValue { .real(timeIntervalSince1970) } }
extension Optional: SQLConvertible where Wrapped: SQLConvertible {
    var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

typealias SQLRow = [String: SQLValue]

enum SQLError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case .failed(let m) = self { return m }; return "sqlite error" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal thread-safe SQLite wrapper. All access is serialized through a recursive lock.
final class SQLiteDB {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            throw SQLError.failed("could not open \(path)")
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
    }

    deinit { sqlite3_close(handle) }

    func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw SQLError.failed(message)
        }
    }

    @discardableResult
    func run(_ sql: String, _ args: [SQLConvertible] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        _ = try query(sql, args)
        return Int(sqlite3_changes(handle))
    }

    func transaction(_ body: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }

    func query(_ sql: String, _ args: [SQLConvertible] = []) throws -> [SQLRow] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLError.failed(String(cString: sqlite3_errmsg(handle)) + " — " + sql)
        }
        defer { sqlite3_finalize(stmt) }

        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg.sqlValue {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .real(let v): sqlite3_bind_double(stmt, idx, v)
            case .blob(let d):
                if d.isEmpty { sqlite3_bind_zeroblob(stmt, idx, 0) } else {
                    d.withUnsafeBytes { raw in
                        _ = sqlite3_bind_blob(stmt, idx, raw.baseAddress, Int32(d.count), SQLITE_TRANSIENT)
                    }
                }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }

        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLError.failed(String(cString: sqlite3_errmsg(handle))) }
            var row: SQLRow = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    if let p = sqlite3_column_blob(stmt, c), n > 0 { row[name] = .blob(Data(bytes: p, count: n)) } else { row[name] = .blob(Data()) }
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }
}
