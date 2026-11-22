import SQLite3
import XCTest
@testable import TokenTakenKit

final class HistoryRetentionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private var databaseURL: URL { directory.appendingPathComponent("usage.sqlite") }

    private func record(day: String, model: String = "model-a", input: Int64, eventCount: Int64 = 1,
                        zone: String = "Asia/Shanghai", source: String = "claude",
                        device: String = "device-a") -> UsageRecord {
        UsageRecord(day: day, timeZoneID: zone, deviceID: device, sourceID: source,
            modelID: model, rawModelID: "raw-" + model, counts: TokenCounts(input: input), eventCount: eventCount)
    }

    private func totals(_ records: [UsageRecord]) -> [String: Int64] {
        Dictionary(grouping: records, by: \.day).mapValues { rows in
            rows.reduce(Int64(0)) { $0 + $1.counts.total }
        }
    }

    private func withHandle(_ body: (OpaquePointer) -> Void) {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        body(handle!)
    }

    private func setEpoch(_ epoch: String) {
        withHandle { handle in
            let sql = """
                INSERT INTO history_epochs (device_id, source_id, epoch) VALUES ('device-a', 'claude', '\(epoch)')
                ON CONFLICT(device_id, source_id) DO UPDATE SET epoch = excluded.epoch;
                """
            XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        }
    }

    private func schemaVersion() -> Int32 {
        var version: Int32 = 0
        withHandle { handle in
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            version = sqlite3_column_int(statement, 0)
        }
        return version
    }

    private func storedEpoch() -> String? {
        var epoch: String?
        withHandle { handle in
            var statement: OpaquePointer?
            let sql = "SELECT epoch FROM history_epochs WHERE device_id = 'device-a' AND source_id = 'claude';"
            XCTAssertEqual(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return }
            epoch = sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }
        return epoch
    }

    private func storedTimeZone() -> String? {
        var zone: String?
        withHandle { handle in
            var statement: OpaquePointer?
            let sql = "SELECT time_zone FROM history_epochs WHERE device_id = 'device-a' AND source_id = 'claude';"
            XCTAssertEqual(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return }
            if sqlite3_column_type(statement, 0) != SQLITE_NULL {
                zone = sqlite3_column_text(statement, 0).map { String(cString: $0) }
            }
        }
        return zone
    }

    /// A store as schema version 2 left it: rows present, no `history_epochs` table.
    private func seedVersion2(_ rows: [(day: String, model: String, input: Int64)]) {
        withHandle { handle in
            var sql = """
                CREATE TABLE daily_usage (
                    device_id TEXT NOT NULL, source_id TEXT NOT NULL, model_id TEXT NOT NULL,
                    raw_model_id TEXT NOT NULL, day TEXT NOT NULL, time_zone TEXT NOT NULL,
                    input INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL,
                    output INTEGER NOT NULL, reasoning INTEGER NOT NULL, uncategorized INTEGER NOT NULL,
                    event_count INTEGER NOT NULL,
                    PRIMARY KEY (device_id, source_id, model_id, day)
                );
                CREATE TABLE hourly_usage (
                    device_id TEXT NOT NULL, source_id TEXT NOT NULL, hour_start INTEGER NOT NULL,
                    input INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL,
                    output INTEGER NOT NULL, reasoning INTEGER NOT NULL, uncategorized INTEGER NOT NULL,
                    event_count INTEGER NOT NULL, reasoning_known INTEGER NOT NULL,
                    PRIMARY KEY (device_id, source_id, hour_start)
                );
                """
            for row in rows {
                sql += """
                    INSERT INTO daily_usage VALUES ('device-a', 'claude', '\(row.model)', 'raw-\(row.model)',
                        '\(row.day)', 'Asia/Shanghai', \(row.input), 0, 0, 0, 0, 0, 1);

                    """
            }
            sql += "PRAGMA user_version = 2;"
            XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        }
    }

    /// A store as schema version 3 left it: rows and epochs present, no `cache_write_1h` column.
    private func seedVersion3(_ rows: [(day: String, model: String, input: Int64, cacheWrite: Int64)], epoch: String) {
        withHandle { handle in
            var sql = """
                CREATE TABLE daily_usage (
                    device_id TEXT NOT NULL, source_id TEXT NOT NULL, model_id TEXT NOT NULL,
                    raw_model_id TEXT NOT NULL, day TEXT NOT NULL, time_zone TEXT NOT NULL,
                    input INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL,
                    output INTEGER NOT NULL, reasoning INTEGER NOT NULL, uncategorized INTEGER NOT NULL,
                    event_count INTEGER NOT NULL,
                    PRIMARY KEY (device_id, source_id, model_id, day)
                );
                CREATE TABLE hourly_usage (
                    device_id TEXT NOT NULL, source_id TEXT NOT NULL, hour_start INTEGER NOT NULL,
                    input INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL,
                    output INTEGER NOT NULL, reasoning INTEGER NOT NULL, uncategorized INTEGER NOT NULL,
                    event_count INTEGER NOT NULL, reasoning_known INTEGER NOT NULL,
                    PRIMARY KEY (device_id, source_id, hour_start)
                );
                CREATE TABLE history_epochs (
                    device_id TEXT NOT NULL, source_id TEXT NOT NULL, epoch TEXT NOT NULL,
                    PRIMARY KEY (device_id, source_id)
                );
                INSERT INTO history_epochs VALUES ('device-a', 'claude', '\(epoch)');
                """
            for row in rows {
                sql += """
                    INSERT INTO daily_usage VALUES ('device-a', 'claude', '\(row.model)', 'raw-\(row.model)',
                        '\(row.day)', 'Asia/Shanghai', \(row.input), 0, \(row.cacheWrite), 0, 0, 0, 1);

                    """
            }
            sql += "PRAGMA user_version = 3;"
            XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        }
    }

    func testPrunedDayKeepsStoredRows() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        try store.replace(batch: CollectionBatch(daily: [
            record(day: "2026-10-12", model: "sonnet-4-5", input: 100),
            record(day: "2026-10-12", model: "opus-4", input: 20),
        ]), sourceID: "claude", deviceID: "device-a")
        // The next scan sees only what the transcript still holds: one smaller model row.
        try store.replace(batch: CollectionBatch(daily: [
            record(day: "2026-10-12", model: "sonnet-4-5", input: 30),
        ]), sourceID: "claude", deviceID: "device-a")
        let records = try store.records()
        XCTAssertEqual(totals(records), ["2026-10-12": 120])
        XCTAssertEqual(Set(records.map(\.modelID)), ["sonnet-4-5", "opus-4"])
    }

    func testVanishedDayIsKept() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        try store.replace(batch: CollectionBatch(daily: [
            record(day: "2026-11-04", input: 100),
            record(day: "2026-11-05", input: 50),
        ]), sourceID: "claude", deviceID: "device-a")
        // Older transcripts are gone; the batch only reports a newer day.
        try store.replace(batch: CollectionBatch(daily: [record(day: "2026-11-06", input: 70)]),
            sourceID: "claude", deviceID: "device-a")
        XCTAssertEqual(totals(try store.records()), ["2026-11-04": 100, "2026-11-05": 50, "2026-11-06": 70])
    }

    func testLargerDayReplacesIncludingModelRename() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        try store.replace(batch: CollectionBatch(daily: [record(day: "2026-10-12", model: "model-a", input: 100)]),
            sourceID: "claude", deviceID: "device-a")
        let renamed = record(day: "2026-10-12", model: "model-b", input: 120)
        try store.replace(batch: CollectionBatch(daily: [renamed]), sourceID: "claude", deviceID: "device-a")
        XCTAssertEqual(try store.records(), [renamed])
    }

    func testEqualTotalWithRenamedModelAdoptsBatch() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        try store.replace(batch: CollectionBatch(daily: [record(day: "2026-10-12", model: "model-a", input: 100)]),
            sourceID: "claude", deviceID: "device-a")
        let renamed = record(day: "2026-10-12", model: "model-b", input: 100)
        try store.replace(batch: CollectionBatch(daily: [renamed]), sourceID: "claude", deviceID: "device-a")
        XCTAssertEqual(try store.records(), [renamed])
    }

    func testSmallerDayKeepsWholeStoredDayWithEventCount() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let stored = [
            record(day: "2026-10-12", model: "model-a", input: 100, eventCount: 4),
            record(day: "2026-10-12", model: "model-b", input: 60, eventCount: 2),
        ]
        try store.replace(batch: CollectionBatch(daily: stored), sourceID: "claude", deviceID: "device-a")
        try store.replace(batch: CollectionBatch(daily: [
            record(day: "2026-10-12", model: "model-a", input: 50, eventCount: 1),
            record(day: "2026-10-12", model: "model-c", input: 20, eventCount: 1),
        ]), sourceID: "claude", deviceID: "device-a")
        XCTAssertEqual(try store.records(), stored)
    }

    func testEpochChangeRebaselinesWithoutDoubleCounting() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        try store.replace(batch: CollectionBatch(daily: [
            record(day: "2026-11-05", input: 200),
            record(day: "2026-11-06", input: 100),
            record(day: "2026-11-07", input: 30),
        ]), sourceID: "claude", deviceID: "device-a")
        setEpoch("0+tokscale-4.21.0")
        // The corrected release attributes 50 tokens to 11-06 that were previously counted on 11-05, prunes
        // 11-05 from its report, and no longer reports 11-07 at all.
        try store.replace(batch: CollectionBatch(daily: [record(day: "2026-11-06", input: 250)]),
            sourceID: "claude", deviceID: "device-a")
        let records = try store.records()
        // 11-07 is after the earliest reported day (11-06), so it is dropped; 11-05 is kept as the floor and
        // 11-06 is the batch total, not the previous total plus the batch.
        XCTAssertEqual(totals(records), ["2026-11-05": 200, "2026-11-06": 250])
        XCTAssertEqual(records.count, 2)
    }

    func testCachedRestoreDoesNotApplyEpoch() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        try store.replace(batch: CollectionBatch(daily: [
            record(day: "2026-11-05", input: 200),
            record(day: "2026-11-06", input: 100),
        ]), sourceID: "claude", deviceID: "device-a")
        setEpoch("0+tokscale-4.21.0")
        // Unchanged inputs: the runner re-stores the cached rows, which were produced under the old epoch.
        try store.replace(batch: CollectionBatch(daily: try store.records()),
            sourceID: "claude", deviceID: "device-a", appliesEpoch: false)
        // The epoch is still pending, so the next real collection rebaselines the corrected 11-06.
        try store.replace(batch: CollectionBatch(daily: [
            record(day: "2026-11-05", input: 200),
            record(day: "2026-11-06", input: 40),
        ]), sourceID: "claude", deviceID: "device-a")
        XCTAssertEqual(totals(try store.records()), ["2026-11-05": 200, "2026-11-06": 40])
    }

    func testStampChangesWhenHistoryEpochChanges() {
        let zone = TimeZone(identifier: "UTC")!
        let withEpoch = CollectionStamp(formatVersion: 1, timeZone: zone, sourceIDs: ["devin"])
        let legacy = CollectionStamp(formatVersion: 1, timeZone: zone)
        XCTAssertNotEqual(withEpoch, legacy)
        XCTAssertEqual(withEpoch.historyEpochs, ["devin=\(HistoryEpochs.epoch(for: "devin"))"])
    }

    func testTimeZoneChangeTriggersRebaseline() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        try store.replace(batch: CollectionBatch(daily: [
            record(day: "2026-11-05", input: 100),
            record(day: "2026-11-06", input: 200),
            record(day: "2026-11-07", input: 30),
        ]), sourceID: "claude", deviceID: "device-a")
        let moved = record(day: "2026-11-06", input: 220, zone: "America/New_York")
        try store.replace(batch: CollectionBatch(daily: [moved]), sourceID: "claude", deviceID: "device-a")
        let records = try store.records()
        XCTAssertEqual(totals(records), ["2026-11-05": 100, "2026-11-06": 220])
        XCTAssertEqual(records.first { $0.day == "2026-11-05" }?.timeZoneID, "Asia/Shanghai")
        XCTAssertEqual(records.first { $0.day == "2026-11-06" }?.timeZoneID, "America/New_York")
    }

    func testSubsequentCollectionInNewZoneUsesFloorRule() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        try store.replace(batch: CollectionBatch(daily: [
            record(day: "2026-11-05", input: 100),
            record(day: "2026-11-06", input: 200),
            record(day: "2026-11-07", input: 30),
        ]), sourceID: "claude", deviceID: "device-a")
        // Switch zone once: rebaselines days after 2026-11-06 while 2026-11-05 keeps its old zone.
        try store.replace(batch: CollectionBatch(daily: [
            record(day: "2026-11-06", input: 220, zone: "America/New_York"),
            record(day: "2026-11-07", input: 40, zone: "America/New_York"),
            record(day: "2026-11-08", input: 50, zone: "America/New_York"),
        ]), sourceID: "claude", deviceID: "device-a")
        XCTAssertEqual(storedTimeZone(), "America/New_York")

        // A second run in the new zone with a smaller recent day and a missing day must use the floor rule.
        try store.replace(batch: CollectionBatch(daily: [
            record(day: "2026-11-06", input: 220, zone: "America/New_York"),
            record(day: "2026-11-07", input: 10, zone: "America/New_York"),
        ]), sourceID: "claude", deviceID: "device-a")
        XCTAssertEqual(totals(try store.records()), [
            "2026-11-05": 100,
            "2026-11-06": 220,
            "2026-11-07": 40,
            "2026-11-08": 50,
        ])
    }

    func testEmptyDailyBatchWithHourlyRowsDoesNotConsumePendingEpoch() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        try store.replace(batch: CollectionBatch(daily: [
            record(day: "2026-11-05", input: 200),
            record(day: "2026-11-06", input: 100),
        ]), sourceID: "claude", deviceID: "device-a")
        setEpoch("0+tokscale-4.21.0")

        let hour = Date(timeIntervalSince1970: 1_762_000_000)
        let hourly = HourlyUsage(hourStart: hour, deviceID: "device-a", sourceID: "claude",
            counts: TokenCounts(input: 8), eventCount: 1, reasoningKnown: false)
        try store.replace(batch: CollectionBatch(daily: [], hourly: [hourly]),
            sourceID: "claude", deviceID: "device-a")
        XCTAssertEqual(try store.hourly(), [hourly])
        XCTAssertEqual(storedEpoch(), "0+tokscale-4.21.0")
        XCTAssertEqual(totals(try store.records()), ["2026-11-05": 200, "2026-11-06": 100])

        // The pending epoch is still applied on the next non-empty daily batch.
        try store.replace(batch: CollectionBatch(daily: [
            record(day: "2026-11-05", input: 200),
            record(day: "2026-11-06", input: 40),
        ]), sourceID: "claude", deviceID: "device-a")
        XCTAssertEqual(totals(try store.records()), ["2026-11-05": 200, "2026-11-06": 40])
        XCTAssertEqual(storedEpoch(), HistoryEpochs.epoch(for: "claude"))
    }

    func testMigrationFromVersion2PreservesRows() throws {
        seedVersion2([
            (day: "2026-10-12", model: "model-a", input: 100),
            (day: "2026-10-13", model: "model-b", input: 40),
        ])
        let store = try SQLiteUsageStore(url: databaseURL)
        XCTAssertEqual(totals(try store.records()), ["2026-10-12": 100, "2026-10-13": 40])
        XCTAssertEqual(Int(schemaVersion()), SQLiteUsageStore.schemaVersion)
    }

    func testMigrationFromVersion3AddsTheOneHourSubsetColumn() throws {
        seedVersion3([(day: "2026-11-09", model: "claude-sonnet-4-5", input: 10, cacheWrite: 500)],
                     epoch: "1+tokscale-4.21.0")
        let store = try SQLiteUsageStore(url: databaseURL)
        XCTAssertEqual(Int(schemaVersion()), SQLiteUsageStore.schemaVersion)
        let migrated = try XCTUnwrap(try store.records().first)
        // Migrated rows know nothing about 1-hour writes, so the whole cache write keeps the 5-minute rate.
        XCTAssertEqual(migrated.counts.cacheWrite, 500)
        XCTAssertEqual(migrated.counts.cacheWrite1h, 0)
        XCTAssertEqual(migrated.counts.total, 510)
        XCTAssertEqual(storedEpoch(), "1+tokscale-4.21.0")
        // The day total excludes the subset, so the floor rule still compares like with like.
        try store.replace(batch: CollectionBatch(daily: [record(day: "2026-11-09", input: 1)]),
            sourceID: "claude", deviceID: "device-a")
        XCTAssertEqual(totals(try store.records()), ["2026-11-09": 510])
        // A larger batch replaces the day and persists its 1-hour split.
        let split = UsageRecord(day: "2026-11-09", timeZoneID: "Asia/Shanghai", deviceID: "device-a",
            sourceID: "claude", modelID: "claude-sonnet-4-5",
            counts: TokenCounts(input: 10, cacheWrite: 900, cacheWrite1h: 700), eventCount: 1)
        try store.replace(batch: CollectionBatch(daily: [split]), sourceID: "claude", deviceID: "device-a")
        XCTAssertEqual(try store.records(), [split])
    }

    func testCacheWrite1hRoundTripsAndStaysOutOfTheTotal() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let row = UsageRecord(day: "2026-11-09", timeZoneID: "Asia/Shanghai", deviceID: "device-a",
            sourceID: "claude", modelID: "claude-sonnet-4-5",
            counts: TokenCounts(input: 10, cacheRead: 20, cacheWrite: 500, output: 40, cacheWrite1h: 300),
            eventCount: 2)
        try store.replace(batch: CollectionBatch(daily: [row]), sourceID: "claude", deviceID: "device-a")
        let stored = try XCTUnwrap(try store.records().first)
        XCTAssertEqual(stored.counts, row.counts)
        XCTAssertEqual(stored.counts.cacheWrite1h, 300)
        XCTAssertEqual(stored.counts.total, 570)
    }

    func testFirstRunAfterMigrationUsesNormalMerge() throws {
        seedVersion2([
            (day: "2026-11-06", model: "model-a", input: 100),
            (day: "2026-11-07", model: "model-a", input: 30),
        ])
        let store = try SQLiteUsageStore(url: databaseURL)
        // No epoch row yet: the normal merge applies even though the batch is smaller and comes from a different
        // collection zone, so nothing is rebaselined, lowered or deleted.
        try store.replace(batch: CollectionBatch(daily: [
            record(day: "2026-11-06", input: 50, zone: "America/New_York"),
        ]), sourceID: "claude", deviceID: "device-a")
        XCTAssertEqual(totals(try store.records()), ["2026-11-06": 100, "2026-11-07": 30])
        XCTAssertEqual(storedEpoch(), "1+tokscale-4.21.0")
    }

    func testHourlyIsStillReplaced() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let hour = Date(timeIntervalSince1970: 1_762_000_000)
        let first = HourlyUsage(hourStart: hour, deviceID: "device-a", sourceID: "claude",
            counts: TokenCounts(input: 10), eventCount: 2, reasoningKnown: false)
        let second = HourlyUsage(hourStart: hour, deviceID: "device-a", sourceID: "claude",
            counts: TokenCounts(input: 5), eventCount: 1, reasoningKnown: false)
        let daily = record(day: "2026-11-06", input: 100)
        try store.replace(batch: CollectionBatch(daily: [daily], hourly: [first]),
            sourceID: "claude", deviceID: "device-a")
        try store.replace(batch: CollectionBatch(daily: [], hourly: [second]),
            sourceID: "claude", deviceID: "device-a")
        XCTAssertEqual(try store.hourly(), [second])
        XCTAssertEqual(try store.records(), [daily])
    }

    private func historyHour(
        _ offsetHours: Int,
        input: Int64,
        output: Int64 = 0,
        cacheWrite1h: Int64 = 0,
        eventCount: Int64 = 1,
        reasoningKnown: Bool = false,
        source: String = "claude",
        device: String = "device-a"
    ) -> HourlyUsage {
        let base: TimeInterval = 1_762_002_000
        return HourlyUsage(
            hourStart: Date(timeIntervalSince1970: base + Double(offsetHours) * 3_600),
            deviceID: device,
            sourceID: source,
            counts: TokenCounts(input: input, output: output, cacheWrite1h: cacheWrite1h),
            eventCount: eventCount,
            reasoningKnown: reasoningKnown
        )
    }

    private func installHourlyHistoryWriteGuards() {
        withHandle { handle in
            let sql = """
                CREATE TRIGGER guard_hh_ins BEFORE INSERT ON hourly_history BEGIN SELECT RAISE(FAIL, 'unexpected insert'); END;
                CREATE TRIGGER guard_hh_upd BEFORE UPDATE ON hourly_history BEGIN SELECT RAISE(FAIL, 'unexpected update'); END;
                CREATE TRIGGER guard_hh_del BEFORE DELETE ON hourly_history BEGIN SELECT RAISE(FAIL, 'unexpected delete'); END;
                """
            XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        }
    }

    private func dropHourlyHistoryWriteGuards() {
        withHandle { handle in
            let sql = """
                DROP TRIGGER IF EXISTS guard_hh_ins;
                DROP TRIGGER IF EXISTS guard_hh_upd;
                DROP TRIGGER IF EXISTS guard_hh_del;
                """
            XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        }
    }

    func testHourlyHistoryFloorMergeAndZeroRowExclusion() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let zero = historyHour(0, input: 0, eventCount: 0)
        let h1 = historyHour(1, input: 100, eventCount: 2)
        let h2 = historyHour(2, input: 200, eventCount: 1)
        let h3 = historyHour(3, input: 50, eventCount: 1)
        try store.replace(
            batch: CollectionBatch(daily: [record(day: "2026-11-05", input: 350)]),
            sourceID: "claude", deviceID: "device-a",
            hourlyHistory: [zero, h1, h2, h3]
        )
        XCTAssertEqual(try store.hourlyHistory(), [h1, h2, h3])

        let h1Smaller = historyHour(1, input: 40, eventCount: 1)
        let h2Larger = historyHour(2, input: 250, eventCount: 3, reasoningKnown: true)
        let h4New = historyHour(4, input: 80, eventCount: 2)
        let h5Zero = historyHour(5, input: 0, eventCount: 0)
        try store.replace(
            batch: CollectionBatch(daily: [record(day: "2026-11-05", input: 370)]),
            sourceID: "claude", deviceID: "device-a",
            hourlyHistory: [h1Smaller, h2Larger, h4New, h5Zero]
        )
        XCTAssertEqual(try store.hourlyHistory(), [h1, h2Larger, h3, h4New])
    }

    func testHourlyHistoryEqualTotalUpdatesChangedFields() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let initial = historyHour(1, input: 100, output: 0, eventCount: 1, reasoningKnown: false)
        let updated = historyHour(1, input: 60, output: 40, eventCount: 2, reasoningKnown: true)
        try store.replace(
            batch: CollectionBatch(daily: [record(day: "2026-11-05", input: 100)]),
            sourceID: "claude", deviceID: "device-a",
            hourlyHistory: [initial]
        )
        try store.replace(
            batch: CollectionBatch(daily: [record(day: "2026-11-05", input: 100)]),
            sourceID: "claude", deviceID: "device-a",
            hourlyHistory: [updated]
        )
        XCTAssertEqual(try store.hourlyHistory(), [updated])
    }

    func testHourlyHistoryRebaselinesOnEpochButNotZoneChange() throws {
        // Epoch change rebaseline: hours strictly after earliest batch hour adopt batch (absent deleted),
        // while hours at or before earliest batch hour keep the floor rule.
        let store = try SQLiteUsageStore(url: databaseURL)
        let h1 = historyHour(1, input: 100)
        let h2 = historyHour(2, input: 200)
        let h3 = historyHour(3, input: 50)
        let h4 = historyHour(4, input: 90)
        try store.replace(
            batch: CollectionBatch(daily: [
                record(day: "2026-11-05", input: 300),
                record(day: "2026-11-06", input: 140),
            ]),
            sourceID: "claude", deviceID: "device-a",
            hourlyHistory: [h1, h2, h3, h4]
        )
        setEpoch("0+tokscale-4.21.0")
        let h2Smaller = historyHour(2, input: 80)
        let h4Smaller = historyHour(4, input: 40)
        try store.replace(
            batch: CollectionBatch(daily: [record(day: "2026-11-06", input: 120)]),
            sourceID: "claude", deviceID: "device-a",
            hourlyHistory: [h2Smaller, h4Smaller]
        )
        // h1 (< earliest) kept; h2 (== earliest) keeps floor (200 > 80); h3 (> earliest, absent) deleted;
        // h4 (> earliest) lowered to 40.
        XCTAssertEqual(try store.hourlyHistory(), [h1, h2, h4Smaller])

        // A zone-key change never moves absolute hours, so it keeps the floor rule.
        let h5 = historyHour(5, input: 70)
        try store.replace(
            batch: CollectionBatch(daily: [record(day: "2026-11-06", input: 190)]),
            sourceID: "claude", deviceID: "device-a",
            hourlyHistory: [h2, h4Smaller, h5]
        )
        let h4ZoneLowered = historyHour(4, input: 20)
        try store.replace(
            batch: CollectionBatch(daily: [record(day: "2026-11-06", input: 190, zone: "America/New_York")]),
            sourceID: "claude", deviceID: "device-a",
            hourlyHistory: [h2Smaller, h4ZoneLowered]
        )
        XCTAssertEqual(try store.hourlyHistory(), [h1, h2, h4Smaller, h5])
    }

    func testHourlyHistoryKeepsFloorOnEpochChangeWithSkippedRecords() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let h1 = historyHour(1, input: 100)
        let h2 = historyHour(2, input: 200)
        try store.replace(batch: CollectionBatch(daily: [record(day: "2026-11-05", input: 300)]),
            sourceID: "claude", deviceID: "device-a", hourlyHistory: [h1, h2])
        setEpoch("0+tokscale-4.21.0")
        try store.replace(batch: CollectionBatch(daily: [record(day: "2026-11-05", input: 50)], skippedRecords: 1),
            sourceID: "claude", deviceID: "device-a", hourlyHistory: [historyHour(1, input: 50)])
        XCTAssertEqual(try store.hourlyHistory(), [h1, h2])
    }

    func testHourlyHistoryKeepsZeroTokenHoursWithEvents() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let request = historyHour(1, input: 0, eventCount: 2)
        try store.replace(batch: CollectionBatch(daily: [record(day: "2026-11-05", input: 1)]),
            sourceID: "claude", deviceID: "device-a", hourlyHistory: [request, historyHour(2, input: 0, eventCount: 0)])
        XCTAssertEqual(try store.hourlyHistory(), [request])
    }

    func testHourlyHistorySteadyStateSecondApplyWritesNothing() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let h1 = historyHour(1, input: 100, eventCount: 2)
        let h2 = historyHour(2, input: 200, output: 15, eventCount: 3, reasoningKnown: true)
        let daily = [record(day: "2026-11-05", input: 315)]
        try store.replace(
            batch: CollectionBatch(daily: daily),
            sourceID: "claude", deviceID: "device-a",
            hourlyHistory: [h1, h2]
        )

        installHourlyHistoryWriteGuards()
        // Identical persisted columns (even with non-zero cacheWrite1h) must produce zero writes.
        let h2WithCacheWrite1h = historyHour(2, input: 200, output: 15, cacheWrite1h: 50, eventCount: 3, reasoningKnown: true)
        try store.replace(
            batch: CollectionBatch(daily: daily),
            sourceID: "claude", deviceID: "device-a",
            hourlyHistory: [h1, h2WithCacheWrite1h]
        )
        // Cached re-store (`appliesEpoch: false`) must not touch hourly_history even if passed rows differ.
        try store.replace(
            batch: CollectionBatch(daily: daily),
            sourceID: "claude", deviceID: "device-a",
            appliesEpoch: false,
            hourlyHistory: [historyHour(9, input: 999)]
        )
        XCTAssertEqual(try store.hourlyHistory(), [h1, h2])

        // Confirm the guard actually catches a real write.
        let h2Grown = historyHour(2, input: 250, output: 15, eventCount: 4, reasoningKnown: true)
        XCTAssertThrowsError(try store.replace(
            batch: CollectionBatch(daily: daily),
            sourceID: "claude", deviceID: "device-a",
            hourlyHistory: [h1, h2Grown]
        ))

        dropHourlyHistoryWriteGuards()
        try store.replace(
            batch: CollectionBatch(daily: daily),
            sourceID: "claude", deviceID: "device-a",
            hourlyHistory: [h1, h2Grown]
        )
        XCTAssertEqual(try store.hourlyHistory(), [h1, h2Grown])
    }

    func testHourlyHistoryRollsBackWithDailyAndHourly() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let h1 = historyHour(1, input: 100)
        let daily = record(day: "2026-11-05", input: 100)
        try store.replace(
            batch: CollectionBatch(daily: [daily], hourly: [h1]),
            sourceID: "claude", deviceID: "device-a",
            hourlyHistory: [h1]
        )
        let h2 = historyHour(2, input: 200)
        let invalid = CollectionBatch(daily: [record(day: "2026-11-05", input: 300)], hourly: [h1, h1])
        XCTAssertThrowsError(try store.replace(
            batch: invalid, sourceID: "claude", deviceID: "device-a", hourlyHistory: [h1, h2]
        ))
        XCTAssertEqual(try store.records(), [daily])
        XCTAssertEqual(try store.hourly(), [h1])
        XCTAssertEqual(try store.hourlyHistory(), [h1])
    }
}
