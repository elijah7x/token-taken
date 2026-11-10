import Foundation
import SQLite3

public enum StoreError: Error, Sendable {
    case open(String)
    case sql(String)
}

public final class SQLiteUsageStore: UsageStore, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.elijah7x.TokenTaken.store")
    private let db: OpaquePointer

    public init(url: URL, readOnly: Bool = false) throws {
        if !readOnly {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        var handle: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open failed with code \(result)"
            if let handle { sqlite3_close(handle) }
            throw StoreError.open(message)
        }
        db = handle

        if !readOnly {
            do {
                try execute("PRAGMA journal_mode=WAL;")
                try execute("""
                    CREATE TABLE IF NOT EXISTS usage (
                        day TEXT NOT NULL,
                        device_id TEXT NOT NULL,
                        source_id TEXT NOT NULL,
                        model_id TEXT NOT NULL,
                        input INTEGER NOT NULL,
                        cache_read INTEGER NOT NULL,
                        cache_write INTEGER NOT NULL,
                        output INTEGER NOT NULL,
                        reasoning INTEGER NOT NULL,
                        PRIMARY KEY(day, device_id, source_id, model_id)
                    );
                    CREATE TABLE IF NOT EXISTS devices (
                        id TEXT PRIMARY KEY,
                        name TEXT NOT NULL,
                        last_seen REAL NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS health (
                        source_id TEXT PRIMARY KEY,
                        last_attempt REAL,
                        last_success REAL,
                        record_count INTEGER NOT NULL,
                        error TEXT
                    );
                    PRAGMA user_version = 1;
                    """)
            } catch {
                sqlite3_close(handle)
                throw error
            }
        }
    }

    deinit {
        queue.sync {
            sqlite3_close(db)
        }
    }

    public func records() -> [UsageRecord] {
        queue.sync {
            guard let statement = try? prepare("""
                SELECT day, device_id, source_id, model_id, input, cache_read, cache_write, output, reasoning
                FROM usage ORDER BY day, device_id, source_id, model_id;
                """) else { return [] }
            defer { sqlite3_finalize(statement) }

            var result: [UsageRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let day = UsageDay.date(from: text(statement, 0)) else { continue }
                result.append(UsageRecord(
                    day: day,
                    deviceID: text(statement, 1),
                    sourceID: text(statement, 2),
                    modelID: text(statement, 3),
                    counts: TokenCounts(
                        input: sqlite3_column_int64(statement, 4),
                        cacheRead: sqlite3_column_int64(statement, 5),
                        cacheWrite: sqlite3_column_int64(statement, 6),
                        output: sqlite3_column_int64(statement, 7),
                        reasoning: sqlite3_column_int64(statement, 8)
                    )
                ))
            }
            return result
        }
    }

    public var devices: [Device] {
        queue.sync {
            guard let statement = try? prepare("SELECT id, name FROM devices ORDER BY id;") else { return [] }
            defer { sqlite3_finalize(statement) }
            var result: [Device] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(Device(id: text(statement, 0), name: text(statement, 1)))
            }
            return result
        }
    }

    public func replace(records: [UsageRecord], sourceID: String, deviceID: String) throws {
        try queue.sync {
            try execute("BEGIN IMMEDIATE TRANSACTION;")
            do {
                let delete = try prepare("DELETE FROM usage WHERE source_id = ? AND device_id = ?;")
                try bind(sourceID, to: delete, at: 1)
                try bind(deviceID, to: delete, at: 2)
                try step(delete)
                sqlite3_finalize(delete)

                let insert = try prepare("""
                    INSERT INTO usage (
                        day, device_id, source_id, model_id,
                        input, cache_read, cache_write, output, reasoning
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """)
                defer { sqlite3_finalize(insert) }
                for record in records {
                    sqlite3_reset(insert)
                    sqlite3_clear_bindings(insert)
                    try bind(UsageDay.string(from: record.day), to: insert, at: 1)
                    try bind(record.deviceID, to: insert, at: 2)
                    try bind(record.sourceID, to: insert, at: 3)
                    try bind(record.modelID, to: insert, at: 4)
                    try check(sqlite3_bind_int64(insert, 5, record.counts.input))
                    try check(sqlite3_bind_int64(insert, 6, record.counts.cacheRead))
                    try check(sqlite3_bind_int64(insert, 7, record.counts.cacheWrite))
                    try check(sqlite3_bind_int64(insert, 8, record.counts.output))
                    try check(sqlite3_bind_int64(insert, 9, record.counts.reasoning))
                    try step(insert)
                }
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
    }

    public func upsert(device: Device) throws {
        try queue.sync {
            let statement = try prepare("""
                INSERT INTO devices (id, name, last_seen) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, last_seen = excluded.last_seen;
                """)
            defer { sqlite3_finalize(statement) }
            try bind(device.id, to: statement, at: 1)
            try bind(device.name, to: statement, at: 2)
            sqlite3_bind_double(statement, 3, Date.now.timeIntervalSince1970)
            try step(statement)
        }
    }

    public func health() -> [SourceHealth] {
        queue.sync {
            guard let statement = try? prepare("""
                SELECT source_id, last_attempt, last_success, record_count, error FROM health ORDER BY source_id;
                """) else { return [] }
            defer { sqlite3_finalize(statement) }
            var result: [SourceHealth] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(SourceHealth(
                    sourceID: text(statement, 0),
                    lastAttempt: date(statement, 1),
                    lastSuccess: date(statement, 2),
                    recordCount: Int(sqlite3_column_int64(statement, 3)),
                    errorMessage: optionalText(statement, 4)
                ))
            }
            return result
        }
    }

    public func record(health: SourceHealth) throws {
        try queue.sync {
            let statement = try prepare("""
                INSERT INTO health (source_id, last_attempt, last_success, record_count, error)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(source_id) DO UPDATE SET
                    last_attempt = excluded.last_attempt,
                    last_success = excluded.last_success,
                    record_count = excluded.record_count,
                    error = excluded.error;
                """)
            defer { sqlite3_finalize(statement) }
            try bind(health.sourceID, to: statement, at: 1)
            try bind(health.lastAttempt, to: statement, at: 2)
            try bind(health.lastSuccess, to: statement, at: 3)
            try check(sqlite3_bind_int64(statement, 4, Int64(health.recordCount)))
            try bind(health.errorMessage, to: statement, at: 5)
            try step(statement)
        }
    }

    public var isEmpty: Bool {
        queue.sync {
            guard let statement = try? prepare("SELECT NOT EXISTS(SELECT 1 FROM usage);"),
                  sqlite3_step(statement) == SQLITE_ROW else { return true }
            defer { sqlite3_finalize(statement) }
            return sqlite3_column_int(statement, 0) == 1
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let error = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(message)
            throw StoreError.sql(error)
        }
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(
                statement, index, pointer, -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        try check(result)
    }

    private func bind(_ value: Date?, to statement: OpaquePointer, at index: Int32) throws {
        if let value {
            try check(sqlite3_bind_double(statement, index, value.timeIntervalSince1970))
        } else {
            try check(sqlite3_bind_null(statement, index))
        }
    }

    private func bind(_ value: String?, to statement: OpaquePointer, at index: Int32) throws {
        if let value {
            try bind(value, to: statement, at: index)
        } else {
            try check(sqlite3_bind_null(statement, index))
        }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(statement, index)
    }

    private func date(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        sqlite3_column_type(statement, index) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }
}
