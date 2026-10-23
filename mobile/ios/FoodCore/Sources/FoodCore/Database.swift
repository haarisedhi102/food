import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum DatabaseError: Error, CustomStringConvertible {
    case open(String)
    case exec(String)
    case step(String)

    public var description: String {
        switch self {
        case .open(let m): return "sqlite open failed: \(m)"
        case .exec(let m): return "sqlite exec failed: \(m)"
        case .step(let m): return "sqlite step failed: \(m)"
        }
    }
}

/// A value that can be bound to / read from a SQLite column.
public enum SQLValue: Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public var stringValue: String? {
        if case let .text(s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case let .int(i): return Int(i)
        case let .double(d): return Int(d)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .double(d): return d
        case let .int(i): return Double(i)
        default: return nil
        }
    }
}

/// A tiny libsqlite3 wrapper — deliberately dependency-free so the core stays portable
/// (no third-party package to resolve on iOS or Android-via-KMP).
public final class Database {
    var handle: OpaquePointer?

    public init(path: String) throws {
        if sqlite3_open(path, &handle) != SQLITE_OK {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw DatabaseError.open(msg)
        }
        sqlite3_busy_timeout(handle, 30_000)
        try exec("PRAGMA foreign_keys = ON")
    }

    /// In-memory database (tests, previews).
    public static func inMemory() throws -> Database {
        try Database(path: ":memory:")
    }

    deinit { sqlite3_close(handle) }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DatabaseError.exec(msg)
        }
    }

    /// Run a statement, returning the number of rows changed (for `INSERT OR IGNORE`,
    /// 1 when inserted, 0 when ignored — matching Python's `cursor.rowcount`).
    @discardableResult
    public func run(_ sql: String, _ binds: [SQLValue] = []) throws -> Int {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DatabaseError.step(String(cString: sqlite3_errmsg(handle)))
        }
        return Int(sqlite3_changes(handle))
    }

    public func query(_ sql: String, _ binds: [SQLValue] = []) throws -> [[String: SQLValue]] {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        var out: [[String: SQLValue]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(readRow(stmt))
        }
        return out
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    // MARK: - internals

    private func prepare(_ sql: String, _ binds: [SQLValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else {
            throw DatabaseError.step(String(cString: sqlite3_errmsg(handle)))
        }
        for (i, value) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case .null: sqlite3_bind_null(prepared, idx)
            case .int(let v): sqlite3_bind_int64(prepared, idx, v)
            case .double(let v): sqlite3_bind_double(prepared, idx, v)
            case .text(let s): sqlite3_bind_text(prepared, idx, s, -1, SQLITE_TRANSIENT)
            case .blob(let d):
                d.withUnsafeBytes { buf in
                    sqlite3_bind_blob(prepared, idx, buf.baseAddress, Int32(d.count), SQLITE_TRANSIENT)
                }
            }
        }
        return prepared
    }

    private func readRow(_ stmt: OpaquePointer) -> [String: SQLValue] {
        var row: [String: SQLValue] = [:]
        for i in 0..<sqlite3_column_count(stmt) {
            let name = String(cString: sqlite3_column_name(stmt, i))
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_NULL: row[name] = .null
            case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, i))
            case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, i))
            case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
            case SQLITE_BLOB:
                let n = Int(sqlite3_column_bytes(stmt, i))
                if let p = sqlite3_column_blob(stmt, i) {
                    row[name] = .blob(Data(bytes: p, count: n))
                } else {
                    row[name] = .blob(Data())
                }
            default: row[name] = .null
            }
        }
        return row
    }
}
