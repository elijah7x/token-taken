import Foundation
import SQLite3

public enum StoreError: Error, Sendable {
    case open(String)
    case sql(String)
}

public final class SQLiteUsageStore: UsageStore, @unchecked Sendable {
    public static let schemaVersion = 7
    private let queue = DispatchQueue(label: "io.github.elijah7x.TokenTaken.store")
    private let db: OpaquePointer

    private enum HourlyTable: String {
        case hourlyUsage = "hourly_usage"
        case hourlyHistory = "hourly_history"
    }

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
                if version < Self.schemaVersion {
                    try migrate(from: version)
                }
                if version < 2 {
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

    private func columnNames(in table: String) throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { names.insert(text(statement, 1)) }
        return names
    }

    private func migrate(from version: Int) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try execute("""
                CREATE TABLE IF NOT EXISTS devices (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, last_seen REAL NOT NULL,
                    kind TEXT NOT NULL DEFAULT 'mac'
                );
                CREATE TABLE IF NOT EXISTS health (
                    source_id TEXT PRIMARY KEY, last_attempt REAL, last_success REAL,
                    record_count INTEGER NOT NULL, error TEXT
                );
                """)
            if version < 2 {
                try execute("DROP TABLE IF EXISTS usage; DROP TABLE IF EXISTS daily_usage; DROP TABLE IF EXISTS hourly_usage; DROP TABLE IF EXISTS hourly_history; DROP TABLE IF EXISTS hourly_history_epochs;")
                let names = try columnNames(in: "health")
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
                    event_count INTEGER NOT NULL, cache_write_1h INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (device_id, source_id, model_id, day)
                );
                CREATE TABLE IF NOT EXISTS hourly_usage (
                    device_id TEXT NOT NULL, source_id TEXT NOT NULL, hour_start INTEGER NOT NULL,
                    input INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL,
                    output INTEGER NOT NULL, reasoning INTEGER NOT NULL, uncategorized INTEGER NOT NULL,
                    event_count INTEGER NOT NULL, reasoning_known INTEGER NOT NULL,
                    PRIMARY KEY (device_id, source_id, hour_start)
                );
                CREATE TABLE IF NOT EXISTS hourly_history (
                    device_id TEXT NOT NULL, source_id TEXT NOT NULL, hour_start INTEGER NOT NULL,
                    input INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL,
                    output INTEGER NOT NULL, reasoning INTEGER NOT NULL, uncategorized INTEGER NOT NULL,
                    event_count INTEGER NOT NULL, reasoning_known INTEGER NOT NULL,
                    PRIMARY KEY (device_id, source_id, hour_start)
                );
                CREATE TABLE IF NOT EXISTS hourly_history_epochs (
                    device_id TEXT NOT NULL, source_id TEXT NOT NULL, epoch TEXT NOT NULL,
                    PRIMARY KEY (device_id, source_id)
                );
                CREATE TABLE IF NOT EXISTS history_epochs (
                    device_id TEXT NOT NULL, source_id TEXT NOT NULL, epoch TEXT NOT NULL,
                    time_zone TEXT,
                    PRIMARY KEY (device_id, source_id)
                );
                """)
            // Schema 4 adds the 1-hour cache-write subset of `cache_write`. It is appended so a migrated
            // table keeps the column order of a newly created one; existing rows default to zero, which
            // prices their whole cache write at the 5-minute rate. Hourly rows carry no model dimension and
            // stay on the 5-minute rate, so they gain no column.
            if !(try columnNames(in: "daily_usage").contains("cache_write_1h")) {
                try execute("ALTER TABLE daily_usage ADD COLUMN cache_write_1h INTEGER NOT NULL DEFAULT 0;")
            }
            // Schema 5 adds the device kind: `mac` for hardware, `account` for usage an account (not a machine)
            // reports. It is appended with a `mac` default so existing rows keep their meaning.
            if !(try columnNames(in: "devices").contains("kind")) {
                try execute("ALTER TABLE devices ADD COLUMN kind TEXT NOT NULL DEFAULT 'mac';")
            }
            // Schema 6 persists the last applied collection time-zone key per `(device_id, source_id)` so older
            // rows retaining earlier zones do not re-trigger zone rebaselines on every later collection.
            if !(try columnNames(in: "history_epochs").contains("time_zone")) {
                try execute("ALTER TABLE history_epochs ADD COLUMN time_zone TEXT;")
            }
            // Schema 7 adds the sparse long-term `hourly_history` table and its own applied epoch in `hourly_history_epochs`
            // above without modifying existing tables (ADR-0015).
            try execute("PRAGMA user_version = \(Self.schemaVersion); COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func records() throws -> [UsageRecord] {
        try queue.sync {
            let statement = try prepare("""
                SELECT day, time_zone, device_id, source_id, model_id, raw_model_id,
                       input, cache_read, cache_write, output, reasoning, uncategorized, event_count,
                       cache_write_1h
                FROM daily_usage ORDER BY day, device_id, source_id, model_id;
                """)
            defer { sqlite3_finalize(statement) }
            var result: [UsageRecord] = []
            while try next(statement) {
                var rowCounts = counts(statement, start: 6)
                rowCounts.cacheWrite1h = sqlite3_column_int64(statement, 13)
                let record = UsageRecord(
                    day: text(statement, 0), timeZoneID: text(statement, 1),
                    deviceID: text(statement, 2), sourceID: text(statement, 3),
                    modelID: text(statement, 4), rawModelID: text(statement, 5),
                    counts: rowCounts, eventCount: sqlite3_column_int64(statement, 12)
                )
                guard record.dayInterval != nil else { throw StoreError.sql("Invalid usage day or time zone") }
                result.append(record)
            }
            return result
        }
    }

    public func hourly() throws -> [HourlyUsage] {
        try readHourly(from: .hourlyUsage)
    }

    /// Returns long-term sparse hourly history retained locally (ADR-0015).
    public func hourlyHistory() throws -> [HourlyUsage] {
        try readHourly(from: .hourlyHistory)
    }

    private func readHourly(from table: HourlyTable) throws -> [HourlyUsage] {
        try queue.sync {
            let statement = try prepare("""
                SELECT hour_start, device_id, source_id, input, cache_read, cache_write,
                       output, reasoning, uncategorized, event_count, reasoning_known
                FROM \(table.rawValue) ORDER BY hour_start, device_id, source_id;
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
            guard let statement = try? prepare("SELECT id, name, kind FROM devices ORDER BY id;") else { return [] }
            defer { sqlite3_finalize(statement) }
            var result: [Device] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                // An unrecognized kind is treated as hardware rather than dropping the device.
                let kind = DeviceKind(rawValue: text(statement, 2)) ?? .mac
                result.append(Device(id: text(statement, 0), name: text(statement, 1), kind: kind))
            }
            return result
        }
    }

    /// Stores one source's batch. `authoritative` marks a complete snapshot of a source whose usage an account
    /// reports centrally: every day it reports is adopted exactly, smaller corrections included, from its earliest
    /// day on, and stored days at or after that date which the batch omits are deleted. Days before the batch's
    /// earliest day keep the floor rule, because the batch is no evidence for them. An empty batch stores nothing.
    ///
    /// `appliesEpoch` is false when the runner re-stores cached rows for unchanged inputs: those rows were produced under
    /// the stored epoch, so they neither rebaseline nor record the current one, and do not touch `hourly_history`.
    ///
    /// `hourlyHistory` carries sparse long-term per-hour rows for this source/device (ADR-0015), merged in the same
    /// transaction when `appliesEpoch` is true.
    public func replace(
        batch: CollectionBatch,
        sourceID: String,
        deviceID: String,
        authoritative: Bool = false,
        appliesEpoch: Bool = true,
        hourlyHistory: [HourlyUsage] = []
    ) throws {
        guard batch.daily.allSatisfy({ $0.sourceID == sourceID && $0.deviceID == deviceID && $0.dayInterval != nil }),
              batch.hourly.allSatisfy({ $0.sourceID == sourceID && $0.deviceID == deviceID }),
              hourlyHistory.allSatisfy({ $0.sourceID == sourceID && $0.deviceID == deviceID }) else {
            throw StoreError.sql("Collection batch does not match its source/device or contains an invalid day")
        }
        let epoch = appliesEpoch ? HistoryEpochs.epoch(for: sourceID) : nil
        try queue.sync {
            try execute("BEGIN IMMEDIATE;")
            do {
                // Hourly history is absolute time, so a collection time-zone change never moves it; only an
                // intentional epoch bump from a complete read may lower or delete stored hours (ADR-0015).
                // The hourly epoch is tracked apart from the daily one and only advances once a complete read has
                // applied it, so a bump first seen by a read with skipped records still rebaselines later.
                let priorHourlyEpoch = try storedHourlyEpoch(sourceID: sourceID, deviceID: deviceID)
                let completeRead = batch.skippedRecords == 0
                let hourlyRebaseline = completeRead && epoch != nil && priorHourlyEpoch != nil && priorHourlyEpoch != epoch
                let rebaseline: Bool
                if authoritative {
                    try adoptDaily(batch.daily, sourceID: sourceID, deviceID: deviceID, epoch: epoch)
                    rebaseline = false
                } else {
                    rebaseline = try mergeDaily(batch.daily, sourceID: sourceID, deviceID: deviceID, epoch: epoch)
                }
                if appliesEpoch && !hourlyHistory.isEmpty {
                    if authoritative && completeRead {
                        try adoptHourlyHistory(hourlyHistory, sourceID: sourceID, deviceID: deviceID)
                    } else {
                        try mergeHourlyHistory(hourlyHistory, sourceID: sourceID, deviceID: deviceID,
                            rebaseline: hourlyRebaseline, completeRead: completeRead)
                    }
                    if let epoch, completeRead || priorHourlyEpoch == nil {
                        try recordHourlyEpoch(epoch, sourceID: sourceID, deviceID: deviceID)
                    }
                }
                let clear = try prepare("DELETE FROM hourly_usage WHERE source_id = ? AND device_id = ?;")
                defer { sqlite3_finalize(clear) }
                try bind(sourceID, to: clear, at: 1)
                try bind(deviceID, to: clear, at: 2)
                try step(clear)
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

    private struct StoredDaily {
        var totals: [String: Int64] = [:]
        var days = Set<String>()
    }

    private struct StoredHourlyRow: Equatable {
        let counts: TokenCounts
        let eventCount: Int64
        let reasoningKnown: Bool

        var total: Int64 { counts.total }

        init(_ usage: HourlyUsage) {
            // `hourly_history` does not store `cacheWrite1h`, so drop it before diffing against stored rows.
            counts = TokenCounts(
                input: usage.counts.input,
                cacheRead: usage.counts.cacheRead,
                cacheWrite: usage.counts.cacheWrite,
                output: usage.counts.output,
                reasoning: usage.counts.reasoning,
                uncategorized: usage.counts.uncategorized
            )
            eventCount = usage.eventCount
            reasoningKnown = usage.reasoningKnown
        }

        init(counts: TokenCounts, eventCount: Int64, reasoningKnown: Bool) {
            self.counts = counts
            self.eventCount = eventCount
            self.reasoningKnown = reasoningKnown
        }
    }

    private func storedDaily(sourceID: String, deviceID: String) throws -> StoredDaily {
        // The day total deliberately excludes `cache_write_1h`, which is a subset of `cache_write`.
        let statement = try prepare("""
            SELECT day, input + cache_read + cache_write + output + reasoning + uncategorized
            FROM daily_usage WHERE source_id = ? AND device_id = ?;
            """)
        defer { sqlite3_finalize(statement) }
        try bind(sourceID, to: statement, at: 1)
        try bind(deviceID, to: statement, at: 2)
        var stored = StoredDaily()
        while try next(statement) {
            let day = text(statement, 0)
            stored.totals[day, default: 0] += sqlite3_column_int64(statement, 1)
            stored.days.insert(day)
        }
        return stored
    }

    private struct HistoryState {
        let epoch: String
        let timeZone: String?
    }

    private func storedHistoryState(sourceID: String, deviceID: String) throws -> HistoryState? {
        let statement = try prepare("SELECT epoch, time_zone FROM history_epochs WHERE device_id = ? AND source_id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(deviceID, to: statement, at: 1)
        try bind(sourceID, to: statement, at: 2)
        guard try next(statement) else { return nil }
        return HistoryState(epoch: text(statement, 0), timeZone: optionalText(statement, 1))
    }

    private func storedHourlyEpoch(sourceID: String, deviceID: String) throws -> String? {
        let statement = try prepare("SELECT epoch FROM hourly_history_epochs WHERE device_id = ? AND source_id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(deviceID, to: statement, at: 1)
        try bind(sourceID, to: statement, at: 2)
        guard try next(statement) else { return nil }
        return text(statement, 0)
    }

    private func recordHourlyEpoch(_ epoch: String, sourceID: String, deviceID: String) throws {
        let statement = try prepare("""
            INSERT INTO hourly_history_epochs (device_id, source_id, epoch) VALUES (?, ?, ?)
            ON CONFLICT(device_id, source_id) DO UPDATE SET epoch = excluded.epoch;
            """)
        defer { sqlite3_finalize(statement) }
        try bind(deviceID, to: statement, at: 1)
        try bind(sourceID, to: statement, at: 2)
        try bind(epoch, to: statement, at: 3)
        try step(statement)
    }

    private func record(epoch: String, timeZone: String, sourceID: String, deviceID: String) throws {
        let statement = try prepare("""
            INSERT INTO history_epochs (device_id, source_id, epoch, time_zone) VALUES (?, ?, ?, ?)
            ON CONFLICT(device_id, source_id) DO UPDATE SET epoch = excluded.epoch, time_zone = excluded.time_zone;
            """)
        defer { sqlite3_finalize(statement) }
        try bind(deviceID, to: statement, at: 1)
        try bind(sourceID, to: statement, at: 2)
        try bind(epoch, to: statement, at: 3)
        try bind(timeZone, to: statement, at: 4)
        try step(statement)
    }

    private func zoneKey(for records: [UsageRecord]) -> String {
        Set(records.map(\.timeZoneID)).sorted().joined(separator: ",")
    }

    /// Merges one source's daily snapshot into the store. Counted usage is a floor: a stored day is replaced only
    /// when the batch total is not smaller, and a stored day the batch no longer reports is kept, so an agent
    /// pruning its own logs cannot shrink history. A day never mixes stored and batch rows, so a model rename
    /// cannot leave a stale row behind (ADR-0008). Returns whether this merge triggered a rebaseline.
    private func mergeDaily(_ records: [UsageRecord], sourceID: String, deviceID: String, epoch: String?) throws -> Bool {
        guard !records.isEmpty else { return false }
        let stored = try storedDaily(sourceID: sourceID, deviceID: deviceID)
        let batchDays = Dictionary(grouping: records, by: \.day)
        let batchTotals = batchDays.mapValues { rows in rows.reduce(Int64(0)) { $0 + $1.counts.total } }
        let batchZoneKey = zoneKey(for: records)
        let previous = try storedHistoryState(sourceID: sourceID, deviceID: deviceID)
        let zoneChanged = previous?.timeZone.map { $0 != batchZoneKey } ?? false
        // A missing epoch row is the first run after the schema 3 upgrade: record the current epoch and use the
        // normal merge, so existing rows are protected immediately instead of being rebaselined unseen.
        let rebaseline = epoch.flatMap { epoch in previous.map { $0.epoch != epoch || zoneChanged } } ?? false
        // A rebaseline adopts every day after the earliest day the batch reports, which is how an intentional
        // correction or a collection time-zone change lowers or moves recent usage. Days up to and including that
        // date keep the floor rule, because the batch has no evidence for lowering them.
        let earliest = rebaseline ? batchDays.keys.min() : nil
        let adopted = Set(batchTotals.filter { entry in
            if let earliest, entry.key > earliest { return true }
            return entry.value >= stored.totals[entry.key, default: 0]
        }.keys)
        let delete = try prepare("DELETE FROM daily_usage WHERE device_id = ? AND source_id = ? AND day = ?;")
        defer { sqlite3_finalize(delete) }
        func remove(_ day: String) throws {
            sqlite3_reset(delete)
            sqlite3_clear_bindings(delete)
            try bind(deviceID, to: delete, at: 1)
            try bind(sourceID, to: delete, at: 2)
            try bind(day, to: delete, at: 3)
            try step(delete)
        }
        for day in adopted { try remove(day) }
        if let earliest {
            for day in stored.days where day > earliest && batchDays[day] == nil { try remove(day) }
        }
        try insertDaily(records.filter { adopted.contains($0.day) }, sourceID: sourceID, deviceID: deviceID)
        if let epoch { try record(epoch: epoch, timeZone: batchZoneKey, sourceID: sourceID, deviceID: deviceID) }
        return rebaseline
    }

    private func indexedHourlyHistory(_ records: [HourlyUsage]) throws -> [Int64: StoredHourlyRow] {
        var byHour: [Int64: StoredHourlyRow] = [:]
        byHour.reserveCapacity(records.count)
        for record in records {
            let row = StoredHourlyRow(record)
            guard row.total > 0 || row.eventCount > 0 else { continue }
            let hourStart = Int64(record.hourStart.timeIntervalSince1970)
            guard byHour.updateValue(row, forKey: hourStart) == nil else {
                throw StoreError.sql("Duplicate hour_start in hourly history")
            }
        }
        return byHour
    }

    private func storedHourlyHistory(sourceID: String, deviceID: String) throws -> [Int64: StoredHourlyRow] {
        let statement = try prepare("""
            SELECT hour_start, input, cache_read, cache_write, output, reasoning, uncategorized,
                   event_count, reasoning_known
            FROM hourly_history WHERE device_id = ? AND source_id = ?;
            """)
        defer { sqlite3_finalize(statement) }
        try bind(deviceID, to: statement, at: 1)
        try bind(sourceID, to: statement, at: 2)
        var stored: [Int64: StoredHourlyRow] = [:]
        while try next(statement) {
            let hourStart = sqlite3_column_int64(statement, 0)
            stored[hourStart] = StoredHourlyRow(
                counts: counts(statement, start: 1),
                eventCount: sqlite3_column_int64(statement, 7),
                reasoningKnown: sqlite3_column_int(statement, 8) != 0
            )
        }
        return stored
    }

    /// Merges one source's sparse long-term hourly history using per-hour floor semantics (ADR-0015).
    /// When `rebaseline` is true, hours strictly after the earliest batch hour adopt the batch exactly
    /// (deleting absent hours), while earlier hours keep the floor rule. Only changed rows are written.
    private func mergeHourlyHistory(
        _ records: [HourlyUsage], sourceID: String, deviceID: String, rebaseline: Bool, completeRead: Bool
    ) throws {
        let batchByHour = try indexedHourlyHistory(records)
        guard let earliest = batchByHour.keys.min() else { return }
        let stored = try storedHourlyHistory(sourceID: sourceID, deviceID: deviceID)
        var toInsert: [(Int64, StoredHourlyRow)] = []
        var toUpdate: [(Int64, StoredHourlyRow)] = []
        for (hourStart, row) in batchByHour {
            if let existing = stored[hourStart] {
                let notSmaller = row.total > existing.total
                    || (row.total == existing.total && row.eventCount >= existing.eventCount)
                let adopt = (rebaseline && hourStart > earliest) || notSmaller
                if adopt && row != existing {
                    toUpdate.append((hourStart, row))
                }
            } else {
                toInsert.append((hourStart, row))
            }
        }
        var toDelete: [Int64] = []
        if rebaseline {
            for hourStart in stored.keys where hourStart > earliest && batchByHour[hourStart] == nil {
                toDelete.append(hourStart)
            }
        } else if completeRead {
            // A move to a zone with a different minute offset (for example UTC+5:30) re-buckets the same events
            // on other boundaries. A complete read re-reports everything from its earliest hour on, so stored
            // hours on the old boundaries that overlap that range are superseded rather than kept beside the new
            // ones; an old hour straddling the earliest new boundary goes too, trading part of a pruned hour for
            // never double-counting.
            let alignments = Set(batchByHour.keys.map(Self.hourAlignment))
            for hourStart in stored.keys
            where hourStart + 3_600 > earliest && !alignments.contains(Self.hourAlignment(hourStart)) {
                toDelete.append(hourStart)
            }
        }
        try writeHourlyHistoryDiff(
            toDelete: toDelete, toUpdate: toUpdate, toInsert: toInsert, sourceID: sourceID, deviceID: deviceID
        )
    }

    private static func hourAlignment(_ hourStart: Int64) -> Int64 {
        ((hourStart % 3_600) + 3_600) % 3_600
    }

    /// Adopts an authoritative account-scoped source's sparse hourly history from its earliest reported hour on,
    /// keeping earlier stored hours and writing only rows that actually changed.
    private func adoptHourlyHistory(_ records: [HourlyUsage], sourceID: String, deviceID: String) throws {
        let batchByHour = try indexedHourlyHistory(records)
        guard let earliest = batchByHour.keys.min() else { return }
        let stored = try storedHourlyHistory(sourceID: sourceID, deviceID: deviceID)
        var toInsert: [(Int64, StoredHourlyRow)] = []
        var toUpdate: [(Int64, StoredHourlyRow)] = []
        for (hourStart, row) in batchByHour {
            if let existing = stored[hourStart] {
                if row != existing {
                    toUpdate.append((hourStart, row))
                }
            } else {
                toInsert.append((hourStart, row))
            }
        }
        let toDelete = stored.keys.filter { $0 > earliest && batchByHour[$0] == nil }
        try writeHourlyHistoryDiff(
            toDelete: toDelete, toUpdate: toUpdate, toInsert: toInsert, sourceID: sourceID, deviceID: deviceID
        )
    }

    private func writeHourlyHistoryDiff(
        toDelete: [Int64],
        toUpdate: [(Int64, StoredHourlyRow)],
        toInsert: [(Int64, StoredHourlyRow)],
        sourceID: String,
        deviceID: String
    ) throws {
        if !toDelete.isEmpty {
            let delete = try prepare("DELETE FROM hourly_history WHERE device_id = ? AND source_id = ? AND hour_start = ?;")
            defer { sqlite3_finalize(delete) }
            for hourStart in toDelete.sorted() {
                sqlite3_reset(delete)
                sqlite3_clear_bindings(delete)
                try bind(deviceID, to: delete, at: 1)
                try bind(sourceID, to: delete, at: 2)
                try check(sqlite3_bind_int64(delete, 3, hourStart))
                try step(delete)
            }
        }
        if !toUpdate.isEmpty {
            let update = try prepare("""
                UPDATE hourly_history
                SET input = ?, cache_read = ?, cache_write = ?, output = ?, reasoning = ?, uncategorized = ?,
                    event_count = ?, reasoning_known = ?
                WHERE device_id = ? AND source_id = ? AND hour_start = ?;
                """)
            defer { sqlite3_finalize(update) }
            for (hourStart, row) in toUpdate.sorted(by: { $0.0 < $1.0 }) {
                sqlite3_reset(update)
                sqlite3_clear_bindings(update)
                try bind(row.counts, to: update, at: 1)
                try check(sqlite3_bind_int64(update, 7, row.eventCount))
                try check(sqlite3_bind_int(update, 8, row.reasoningKnown ? 1 : 0))
                try bind(deviceID, to: update, at: 9)
                try bind(sourceID, to: update, at: 10)
                try check(sqlite3_bind_int64(update, 11, hourStart))
                try step(update)
            }
        }
        if !toInsert.isEmpty {
            let insert = try prepare("INSERT INTO hourly_history VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);")
            defer { sqlite3_finalize(insert) }
            for (hourStart, row) in toInsert.sorted(by: { $0.0 < $1.0 }) {
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
                try bind(deviceID, to: insert, at: 1)
                try bind(sourceID, to: insert, at: 2)
                try check(sqlite3_bind_int64(insert, 3, hourStart))
                try bind(row.counts, to: insert, at: 4)
                try check(sqlite3_bind_int64(insert, 10, row.eventCount))
                try check(sqlite3_bind_int(insert, 11, row.reasoningKnown ? 1 : 0))
                try step(insert)
            }
        }
    }

    /// Adopts a complete account-scoped snapshot: stored days at or after the batch's earliest day are replaced by
    /// the batch exactly, so a day Cursor lowers shrinks and a day it no longer reports disappears. Earlier days
    /// keep their stored rows. An empty batch adopts nothing rather than erasing history.
    private func adoptDaily(_ records: [UsageRecord], sourceID: String, deviceID: String, epoch: String?) throws {
        guard let earliest = records.map(\.day).min() else { return }
        let clear = try prepare("DELETE FROM daily_usage WHERE device_id = ? AND source_id = ? AND day >= ?;")
        defer { sqlite3_finalize(clear) }
        try bind(deviceID, to: clear, at: 1)
        try bind(sourceID, to: clear, at: 2)
        try bind(earliest, to: clear, at: 3)
        try step(clear)
        try insertDaily(records, sourceID: sourceID, deviceID: deviceID)
        if let epoch { try record(epoch: epoch, timeZone: zoneKey(for: records), sourceID: sourceID, deviceID: deviceID) }
    }

    private func insertDaily(_ records: [UsageRecord], sourceID: String, deviceID: String) throws {
        guard !records.isEmpty else { return }
        let insert = try prepare("INSERT INTO daily_usage VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);")
        defer { sqlite3_finalize(insert) }
        for record in records {
            sqlite3_reset(insert)
            sqlite3_clear_bindings(insert)
            for (index, value) in [deviceID, sourceID, record.modelID, record.rawModelID, record.day, record.timeZoneID].enumerated() {
                try bind(value, to: insert, at: Int32(index + 1))
            }
            try bind(record.counts, to: insert, at: 7)
            try check(sqlite3_bind_int64(insert, 13, record.eventCount))
            try check(sqlite3_bind_int64(insert, 14, record.counts.cacheWrite1h))
            try step(insert)
        }
    }

    public func upsert(device: Device) throws {
        try queue.sync {
            let statement = try prepare("""
                INSERT INTO devices (id, name, kind, last_seen) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, kind = excluded.kind, last_seen = excluded.last_seen;
                """)
            defer { sqlite3_finalize(statement) }
            try bind(device.id, to: statement, at: 1)
            try bind(device.name, to: statement, at: 2)
            try bind(device.kind.rawValue, to: statement, at: 3)
            try check(sqlite3_bind_double(statement, 4, Date.now.timeIntervalSince1970))
            try step(statement)
        }
    }

    /// Moves daily, hourly, and hourly-history rows for `sourceID` from a superseded account device to `newDeviceID`
    /// when `newDeviceID` has no rows for that day/hour, drops remaining legacy rows for that source, deletes the
    /// legacy `history_epochs` row for `(legacyDeviceID, sourceID)`, and deletes the legacy `devices` row if no
    /// rows remain for other sources.
    public func migrateAccountDevice(from legacyDeviceID: String, to newDeviceID: String, sourceID: String) throws {
        guard legacyDeviceID != newDeviceID,
              AccountDeviceID.isAccount(legacyDeviceID),
              AccountDeviceID.isAccount(newDeviceID) else {
            return
        }
        try queue.sync {
            try execute("BEGIN IMMEDIATE;")
            do {
                if let kind = try deviceKind(for: legacyDeviceID), kind != .account {
                    try execute("COMMIT;")
                    return
                }
                let existingDays = try storedDays(sourceID: sourceID, deviceID: newDeviceID)
                let legacyDays = try storedDays(sourceID: sourceID, deviceID: legacyDeviceID)
                let daysToMove = legacyDays.subtracting(existingDays).sorted()
                try moveDailyDays(daysToMove, from: legacyDeviceID, to: newDeviceID, sourceID: sourceID)
                try deleteDaily(deviceID: legacyDeviceID, sourceID: sourceID)

                for table in [HourlyTable.hourlyUsage, HourlyTable.hourlyHistory] {
                    let existingHours = try storedHours(in: table, sourceID: sourceID, deviceID: newDeviceID)
                    let legacyHours = try storedHours(in: table, sourceID: sourceID, deviceID: legacyDeviceID)
                    let hoursToMove = legacyHours.subtracting(existingHours).sorted()
                    try moveHourlyBuckets(hoursToMove, in: table, from: legacyDeviceID, to: newDeviceID, sourceID: sourceID)
                    try deleteHourly(in: table, deviceID: legacyDeviceID, sourceID: sourceID)
                }

                try deleteHistoryEpochs(deviceID: legacyDeviceID, sourceID: sourceID)
                try deleteUnusedAccountDevice(id: legacyDeviceID)
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
    }

    private func deviceKind(for deviceID: String) throws -> DeviceKind? {
        let statement = try prepare("SELECT kind FROM devices WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(deviceID, to: statement, at: 1)
        guard try next(statement) else { return nil }
        return DeviceKind(rawValue: text(statement, 0)) ?? .mac
    }

    private func storedDays(sourceID: String, deviceID: String) throws -> Set<String> {
        let statement = try prepare("SELECT DISTINCT day FROM daily_usage WHERE device_id = ? AND source_id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(deviceID, to: statement, at: 1)
        try bind(sourceID, to: statement, at: 2)
        var days = Set<String>()
        while try next(statement) { days.insert(text(statement, 0)) }
        return days
    }

    private func moveDailyDays(_ days: [String], from legacyDeviceID: String, to newDeviceID: String, sourceID: String) throws {
        guard !days.isEmpty else { return }
        let statement = try prepare("UPDATE daily_usage SET device_id = ? WHERE device_id = ? AND source_id = ? AND day = ?;")
        defer { sqlite3_finalize(statement) }
        for day in days {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bind(newDeviceID, to: statement, at: 1)
            try bind(legacyDeviceID, to: statement, at: 2)
            try bind(sourceID, to: statement, at: 3)
            try bind(day, to: statement, at: 4)
            try step(statement)
        }
    }

    private func deleteDaily(deviceID: String, sourceID: String) throws {
        let statement = try prepare("DELETE FROM daily_usage WHERE device_id = ? AND source_id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(deviceID, to: statement, at: 1)
        try bind(sourceID, to: statement, at: 2)
        try step(statement)
    }

    private func storedHours(in table: HourlyTable, sourceID: String, deviceID: String) throws -> Set<Int64> {
        let statement = try prepare("SELECT hour_start FROM \(table.rawValue) WHERE device_id = ? AND source_id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(deviceID, to: statement, at: 1)
        try bind(sourceID, to: statement, at: 2)
        var hours = Set<Int64>()
        while try next(statement) { hours.insert(sqlite3_column_int64(statement, 0)) }
        return hours
    }

    private func moveHourlyBuckets(
        _ hours: [Int64], in table: HourlyTable, from legacyDeviceID: String, to newDeviceID: String, sourceID: String
    ) throws {
        guard !hours.isEmpty else { return }
        let statement = try prepare("UPDATE \(table.rawValue) SET device_id = ? WHERE device_id = ? AND source_id = ? AND hour_start = ?;")
        defer { sqlite3_finalize(statement) }
        for hourStart in hours {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bind(newDeviceID, to: statement, at: 1)
            try bind(legacyDeviceID, to: statement, at: 2)
            try bind(sourceID, to: statement, at: 3)
            try check(sqlite3_bind_int64(statement, 4, hourStart))
            try step(statement)
        }
    }

    private func deleteHourly(in table: HourlyTable, deviceID: String, sourceID: String) throws {
        let statement = try prepare("DELETE FROM \(table.rawValue) WHERE device_id = ? AND source_id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(deviceID, to: statement, at: 1)
        try bind(sourceID, to: statement, at: 2)
        try step(statement)
    }

    private func deleteHistoryEpochs(deviceID: String, sourceID: String) throws {
        for table in ["history_epochs", "hourly_history_epochs"] {
            let statement = try prepare("DELETE FROM \(table) WHERE device_id = ? AND source_id = ?;")
            defer { sqlite3_finalize(statement) }
            try bind(deviceID, to: statement, at: 1)
            try bind(sourceID, to: statement, at: 2)
            try step(statement)
        }
    }

    private func deleteUnusedAccountDevice(id: String) throws {
        let statement = try prepare("""
            DELETE FROM devices
            WHERE id = ? AND kind = 'account'
              AND NOT EXISTS (SELECT 1 FROM daily_usage WHERE device_id = ?)
              AND NOT EXISTS (SELECT 1 FROM hourly_usage WHERE device_id = ?)
              AND NOT EXISTS (SELECT 1 FROM hourly_history WHERE device_id = ?)
              AND NOT EXISTS (SELECT 1 FROM history_epochs WHERE device_id = ?);
            """)
        defer { sqlite3_finalize(statement) }
        try bind(id, to: statement, at: 1)
        try bind(id, to: statement, at: 2)
        try bind(id, to: statement, at: 3)
        try bind(id, to: statement, at: 4)
        try bind(id, to: statement, at: 5)
        try step(statement)
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
