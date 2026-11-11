import Foundation
import SQLite3

public enum StoreError: Error, Sendable {
    case open(String)
    case sql(String)
}

public final class SQLiteUsageStore: UsageStore, @unchecked Sendable {
    public static let schemaVersion = 2
    private let queue = DispatchQueue(label: "io.github.elijah7x.TokenTaken.store")
    private let db: OpaquePointer

    public init(url: URL, readOnly: Bool = false) throws {
        if !readOnly {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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
        do {
            sqlite3_busy_timeout(db, 5_000)
            let statement = try prepare("PRAGMA user_version;")
            let code = sqlite3_step(statement)
            let version = Int(sqlite3_column_int(statement, 0))
            sqlite3_finalize(statement)
            guard code == SQLITE_ROW else { throw sqlError() }
            guard version <= Self.schemaVersion else { throw StoreError.open("Unsupported usage cache version") }
            if readOnly {
                guard version == Self.schemaVersion else {
                    throw StoreError.open("Open Token Taken to rebuild the usage cache")
                }
            } else {
                try execute("PRAGMA journal_mode=WAL;")
                try migrate(from: version)
                if version < Self.schemaVersion {
                    // A new or rebuilt cache has no rows, so collector state that marks sources unchanged
                    // would keep them empty; drop it to force a full collection (ADR-0006).
                    try? FileManager.default.removeItem(
                        at: url.deletingLastPathComponent().appendingPathComponent("collector-state", isDirectory: true)
                    )
                }
            }
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { queue.sync { sqlite3_close(db) } }

    private func migrate(from version: Int) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try execute("""
                CREATE TABLE IF NOT EXISTS devices (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, last_seen REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS health (
                    source_id TEXT PRIMARY KEY, last_attempt REAL, last_success REAL,
                    record_count INTEGER NOT NULL, error TEXT
                );
                """)
            if version < Self.schemaVersion {
                try execute("DROP TABLE IF EXISTS usage; DROP TABLE IF EXISTS daily_usage; DROP TABLE IF EXISTS hourly_usage;")
                let columns = try prepare("PRAGMA table_info(health);")
                var names = Set<String>()
                while sqlite3_step(columns) == SQLITE_ROW { names.insert(text(columns, 1)) }
                sqlite3_finalize(columns)
                if !names.contains("skipped_records") {
                    try execute("ALTER TABLE health ADD COLUMN skipped_records INTEGER NOT NULL DEFAULT 0;")
                }
                if !names.contains("state") {
                    try execute("ALTER TABLE health ADD COLUMN state TEXT NOT NULL DEFAULT 'stale';")
                }
                // Old usage was labelled UTC incorrectly. Preserve metadata, but label its cleared cache stale.
                try execute("UPDATE health SET state = 'stale';")
            }
            try execute("""
                CREATE TABLE IF NOT EXISTS daily_usage (
                    device_id TEXT NOT NULL, source_id TEXT NOT NULL, model_id TEXT NOT NULL,
                    raw_model_id TEXT NOT NULL, day TEXT NOT NULL, time_zone TEXT NOT NULL,
                    input INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL,
                    output INTEGER NOT NULL, reasoning INTEGER NOT NULL, uncategorized INTEGER NOT NULL,
                    event_count INTEGER NOT NULL,
                    PRIMARY KEY (device_id, source_id, model_id, day)
                );
                CREATE TABLE IF NOT EXISTS hourly_usage (
                    device_id TEXT NOT NULL, source_id TEXT NOT NULL, hour_start INTEGER NOT NULL,
                    input INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL,
                    output INTEGER NOT NULL, reasoning INTEGER NOT NULL, uncategorized INTEGER NOT NULL,
                    event_count INTEGER NOT NULL, reasoning_known INTEGER NOT NULL,
                    PRIMARY KEY (device_id, source_id, hour_start)
                );
                PRAGMA user_version = 2;
                COMMIT;
                """)
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func records() throws -> [UsageRecord] {
        try queue.sync {
            let statement = try prepare("""
                SELECT day, time_zone, device_id, source_id, model_id, raw_model_id,
                       input, cache_read, cache_write, output, reasoning, uncategorized, event_count
                FROM daily_usage ORDER BY day, device_id, source_id, model_id;
                """)
            defer { sqlite3_finalize(statement) }
            var result: [UsageRecord] = []
            while try next(statement) {
                let record = UsageRecord(
                    day: text(statement, 0), timeZoneID: text(statement, 1),
                    deviceID: text(statement, 2), sourceID: text(statement, 3),
                    modelID: text(statement, 4), rawModelID: text(statement, 5),
                    counts: counts(statement, start: 6), eventCount: sqlite3_column_int64(statement, 12)
                )
                guard record.dayInterval != nil else { throw StoreError.sql("Invalid usage day or time zone") }
                result.append(record)
            }
            return result
        }
    }

    public func hourly() throws -> [HourlyUsage] {
        try queue.sync {
            let statement = try prepare("""
                SELECT hour_start, device_id, source_id, input, cache_read, cache_write,
                       output, reasoning, uncategorized, event_count, reasoning_known
                FROM hourly_usage ORDER BY hour_start, device_id, source_id;
                """)
            defer { sqlite3_finalize(statement) }
            var result: [HourlyUsage] = []
            while try next(statement) {
                result.append(HourlyUsage(
                    hourStart: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0))),
                    deviceID: text(statement, 1), sourceID: text(statement, 2),
                    counts: counts(statement, start: 3), eventCount: sqlite3_column_int64(statement, 9),
                    reasoningKnown: sqlite3_column_int(statement, 10) != 0
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

    public func replace(batch: CollectionBatch, sourceID: String, deviceID: String) throws {
        guard batch.daily.allSatisfy({ $0.sourceID == sourceID && $0.deviceID == deviceID && $0.dayInterval != nil }),
              batch.hourly.allSatisfy({ $0.sourceID == sourceID && $0.deviceID == deviceID }) else {
            throw StoreError.sql("Collection batch does not match its source/device or contains an invalid day")
        }
        try queue.sync {
            try execute("BEGIN IMMEDIATE;")
            do {
                for table in ["daily_usage", "hourly_usage"] {
                    let statement = try prepare("DELETE FROM \(table) WHERE source_id = ? AND device_id = ?;")
                    defer { sqlite3_finalize(statement) }
                    try bind(sourceID, to: statement, at: 1)
                    try bind(deviceID, to: statement, at: 2)
                    try step(statement)
                }
                let daily = try prepare("INSERT INTO daily_usage VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);")
                defer { sqlite3_finalize(daily) }
                for record in batch.daily {
                    sqlite3_reset(daily)
                    sqlite3_clear_bindings(daily)
                    for (index, value) in [deviceID, sourceID, record.modelID, record.rawModelID, record.day, record.timeZoneID].enumerated() {
                        try bind(value, to: daily, at: Int32(index + 1))
                    }
                    try bind(record.counts, to: daily, at: 7)
                    try check(sqlite3_bind_int64(daily, 13, record.eventCount))
                    try step(daily)
                }
                let hourly = try prepare("INSERT INTO hourly_usage VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);")
                defer { sqlite3_finalize(hourly) }
                for record in batch.hourly {
                    sqlite3_reset(hourly)
                    sqlite3_clear_bindings(hourly)
                    try bind(deviceID, to: hourly, at: 1)
                    try bind(sourceID, to: hourly, at: 2)
                    try check(sqlite3_bind_int64(hourly, 3, Int64(record.hourStart.timeIntervalSince1970)))
                    try bind(record.counts, to: hourly, at: 4)
                    try check(sqlite3_bind_int64(hourly, 10, record.eventCount))
                    try check(sqlite3_bind_int(hourly, 11, record.reasoningKnown ? 1 : 0))
                    try step(hourly)
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
            try check(sqlite3_bind_double(statement, 3, Date.now.timeIntervalSince1970))
            try step(statement)
        }
    }

    public func health() throws -> [SourceHealth] {
        try queue.sync {
            let statement = try prepare("""
                SELECT source_id, last_attempt, last_success, record_count, error, skipped_records, state
                FROM health ORDER BY source_id;
                """)
            defer { sqlite3_finalize(statement) }
            var result: [SourceHealth] = []
            while try next(statement) {
                guard let state = SourceHealth.State(rawValue: text(statement, 6)) else {
                    throw StoreError.sql("Invalid source health state")
                }
                result.append(SourceHealth(
                    sourceID: text(statement, 0), lastAttempt: date(statement, 1), lastSuccess: date(statement, 2),
                    recordCount: Int(sqlite3_column_int64(statement, 3)), errorMessage: optionalText(statement, 4),
                    skippedRecords: Int(sqlite3_column_int64(statement, 5)), state: state
                ))
            }
            return result
        }
    }

    public func record(health: SourceHealth) throws {
        try queue.sync {
            let statement = try prepare("""
                INSERT INTO health (source_id, last_attempt, last_success, record_count, error, skipped_records, state)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_id) DO UPDATE SET last_attempt = excluded.last_attempt,
                    last_success = excluded.last_success, record_count = excluded.record_count,
                    error = excluded.error, skipped_records = excluded.skipped_records, state = excluded.state;
                """)
            defer { sqlite3_finalize(statement) }
            try bind(health.sourceID, to: statement, at: 1)
            try bind(health.lastAttempt, to: statement, at: 2)
            try bind(health.lastSuccess, to: statement, at: 3)
            try check(sqlite3_bind_int64(statement, 4, Int64(health.recordCount)))
            try bind(health.errorMessage, to: statement, at: 5)
            try check(sqlite3_bind_int64(statement, 6, Int64(health.skippedRecords)))
            try bind(health.state.rawValue, to: statement, at: 7)
            try step(statement)
        }
    }

    public var isEmpty: Bool {
        queue.sync {
            guard let statement = try? prepare("SELECT NOT EXISTS(SELECT 1 FROM daily_usage);") else { return true }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return true }
            return sqlite3_column_int(statement, 0) == 1
        }
    }

    private func counts(_ statement: OpaquePointer, start: Int32) -> TokenCounts {
        TokenCounts(input: sqlite3_column_int64(statement, start), cacheRead: sqlite3_column_int64(statement, start + 1),
                    cacheWrite: sqlite3_column_int64(statement, start + 2), output: sqlite3_column_int64(statement, start + 3),
                    reasoning: sqlite3_column_int64(statement, start + 4), uncategorized: sqlite3_column_int64(statement, start + 5))
    }

    private func bind(_ counts: TokenCounts, to statement: OpaquePointer, at start: Int32) throws {
        for (offset, value) in [counts.input, counts.cacheRead, counts.cacheWrite, counts.output, counts.reasoning, counts.uncategorized].enumerated() {
            try check(sqlite3_bind_int64(statement, start + Int32(offset), value))
        }
    }

    private func sqlError() -> StoreError { .sql(String(cString: sqlite3_errmsg(db))) }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqlError() }
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

    private func next(_ statement: OpaquePointer) throws -> Bool {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return false }
        guard code == SQLITE_ROW else { throw sqlError() }
        return true
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqlError() }
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw sqlError() }
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        try check(value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        })
    }

    private func bind(_ value: Date?, to statement: OpaquePointer, at index: Int32) throws {
        if let value { try check(sqlite3_bind_double(statement, index, value.timeIntervalSince1970)) }
        else { try check(sqlite3_bind_null(statement, index)) }
    }

    private func bind(_ value: String?, to statement: OpaquePointer, at index: Int32) throws {
        if let value { try bind(value, to: statement, at: index) }
        else { try check(sqlite3_bind_null(statement, index)) }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(statement, index)
    }

    private func date(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }
}
