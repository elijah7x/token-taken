import SQLite3
import XCTest
@testable import TokenTakenKit

final class SQLiteUsageStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private var databaseURL: URL { directory.appendingPathComponent("usage.sqlite") }
    private var now: Date { ISO8601DateFormatter().date(from: "2026-11-09T10:30:00Z")! }

    private func record(_ source: String = "claude", device: String = "device-a", model: String = "model-a", input: Int64 = 100) -> UsageRecord {
        UsageRecord(day: "2026-11-09", timeZoneID: "Asia/Shanghai", deviceID: device, sourceID: source,
            modelID: model, rawModelID: "raw-" + model,
            counts: TokenCounts(input: input, cacheRead: 20, cacheWrite: 10, output: 30, reasoning: 5, uncategorized: 7), eventCount: 3)
    }

    private func hourly() -> HourlyUsage {
        HourlyUsage(hourStart: now.addingTimeInterval(-1_800), deviceID: "device-a", sourceID: "claude",
            counts: TokenCounts(input: 4, output: 5, uncategorized: 6), eventCount: 2, reasoningKnown: false)
    }

    func testRoundTrip() throws {
        let device = Device(id: "device-a", name: "Test Mac")
        let expected = record()
        let hour = hourly()
        do {
            let store = try SQLiteUsageStore(url: databaseURL)
            XCTAssertTrue(store.isEmpty)
            try store.upsert(device: device)
            try store.replace(batch: CollectionBatch(daily: [expected], hourly: [hour]), sourceID: expected.sourceID, deviceID: expected.deviceID)
        }
        let store = try SQLiteUsageStore(url: databaseURL, readOnly: true)
        XCTAssertFalse(store.isEmpty)
        XCTAssertEqual(try store.records(), [expected])
        XCTAssertEqual(try store.hourly(), [hour])
        XCTAssertEqual(store.devices, [device])
    }

    func testReplaceIsIdempotentAndScopedToSourceAndDevice() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let claudeA = record()
        let codexA = record("codex", model: "model-b", input: 200)
        let claudeB = record(device: "device-b", input: 300)
        for row in [claudeA, codexA, claudeB, claudeA] {
            try store.replace(batch: CollectionBatch(daily: [row]), sourceID: row.sourceID, deviceID: row.deviceID)
        }
        XCTAssertEqual(Set(try store.records()), Set([claudeA, codexA, claudeB]))
        let replacement = record(model: "model-c", input: 400)
        try store.replace(batch: CollectionBatch(daily: [replacement]), sourceID: "claude", deviceID: "device-a")
        XCTAssertEqual(Set(try store.records()), Set([replacement, codexA, claudeB]))
        // An empty batch keeps stored days: daily history is a floor, not a snapshot (ADR-0008).
        try store.replace(batch: CollectionBatch(), sourceID: "claude", deviceID: "device-a")
        XCTAssertEqual(Set(try store.records()), Set([replacement, codexA, claudeB]))
    }

    func testBothTablesRollBackTogether() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let original = CollectionBatch(daily: [record()], hourly: [hourly()])
        try store.replace(batch: original, sourceID: "claude", deviceID: "device-a")
        let invalid = CollectionBatch(daily: [record(input: 999)], hourly: [hourly(), hourly()])
        XCTAssertThrowsError(try store.replace(batch: invalid, sourceID: "claude", deviceID: "device-a"))
        XCTAssertEqual(try store.records(), original.daily)
        XCTAssertEqual(try store.hourly(), original.hourly)
    }

    func testHealthRoundTrip() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let expected = SourceHealth(sourceID: "claude", lastAttempt: now, lastSuccess: now.addingTimeInterval(-600),
            recordCount: 12, errorMessage: "synthetic error", skippedRecords: 2, state: .failed)
        try store.record(health: expected)
        XCTAssertEqual(try store.health(), [expected])
        let updated = SourceHealth(sourceID: "claude", lastAttempt: now, lastSuccess: now, recordCount: 20)
        try store.record(health: updated)
        XCTAssertEqual(try store.health(), [updated])
        XCTAssertEqual(updated.markingStale(now: now.addingTimeInterval(86_401)).state, .stale)
    }

    func testMigrationRebuildsUsageAndPreservesDeviceAndHealth() throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        let sql = """
            CREATE TABLE usage (day TEXT, device_id TEXT, source_id TEXT, model_id TEXT);
            INSERT INTO usage VALUES ('2026-11-09', 'device-a', 'claude', 'model-a');
            CREATE TABLE devices (id TEXT PRIMARY KEY, name TEXT NOT NULL, last_seen REAL NOT NULL);
            INSERT INTO devices VALUES ('device-a', 'Test Mac', 1000);
            CREATE TABLE health (source_id TEXT PRIMARY KEY, last_attempt REAL, last_success REAL, record_count INTEGER NOT NULL, error TEXT);
            INSERT INTO health VALUES ('claude', 1000, 900, 12, NULL);
            PRAGMA user_version = 1;
            """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        XCTAssertThrowsError(try SQLiteUsageStore(url: databaseURL, readOnly: true))
        let store = try SQLiteUsageStore(url: databaseURL)
        XCTAssertEqual(try store.records(), [])
        XCTAssertEqual(try store.hourly(), [])
        XCTAssertEqual(store.devices, [Device(id: "device-a", name: "Test Mac")])
        let health = try XCTUnwrap(store.health().first)
        XCTAssertEqual(health.lastSuccess, Date(timeIntervalSince1970: 900))
        XCTAssertEqual(health.recordCount, 12)
        XCTAssertEqual(health.state, .stale)
        XCTAssertEqual(health.skippedRecords, 0)
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var version: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &version, nil), SQLITE_OK)
        defer { sqlite3_finalize(version) }
        XCTAssertEqual(sqlite3_step(version), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(version, 0), 5)
    }

    func testFailedAndUnavailableCollectorsPreserveBothCaches() async throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let original = CollectionBatch(daily: [record()], hourly: [hourly()])
        try store.replace(batch: original, sourceID: "claude", deviceID: "device-a")
        let success = now.addingTimeInterval(-600)
        try store.record(health: SourceHealth(sourceID: "claude", lastSuccess: success, recordCount: 1))
        for unavailable in [false, true] {
            let runner = CollectionRunner(store: store, device: Device(id: "device-a", name: "Test Mac"),
                collectors: [FailingCollector(unavailable: unavailable)])
            let results = await runner.runAll(now: now)
            XCTAssertEqual(results.first?.state, unavailable ? .unavailable : .failed)
            XCTAssertEqual(results.first?.lastSuccess, success)
            XCTAssertEqual(try store.records(), original.daily)
            XCTAssertEqual(try store.hourly(), original.hourly)
            XCTAssertEqual(try store.health().first?.state, unavailable ? .unavailable : .failed)
        }
    }

    func testSuccessfulCollectionPersistsOnly48HoursAndConfirmedZeroes() async throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let old = HourlyUsage(hourStart: now.addingTimeInterval(-72 * 3_600), deviceID: "device-a", sourceID: "claude",
            counts: TokenCounts(input: 100), eventCount: 1, reasoningKnown: false)
        let runner = CollectionRunner(store: store, device: Device(id: "device-a", name: "Test Mac"),
            collectors: [SuccessfulCollector(batch: CollectionBatch(daily: [record()], hourly: [old]))])
        let result = await runner.runAll(now: now)
        XCTAssertEqual(result.first?.state, .ok)
        let hours = try store.hourly()
        XCTAssertEqual(hours.count, 48)
        XCTAssertTrue(hours.allSatisfy { $0.counts == .zero && !$0.reasoningKnown })
        XCTAssertEqual(try store.records().count, 1)
    }

    func testHealthWriteErrorIsReturnedInsteadOfSwallowed() async throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "CREATE TRIGGER reject_health BEFORE INSERT ON health BEGIN SELECT RAISE(FAIL, 'synthetic health error'); END;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        let runner = CollectionRunner(store: store, device: Device(id: "device-a", name: "Test Mac"),
            collectors: [SuccessfulCollector(batch: CollectionBatch(daily: [record()]))])
        let result = await runner.runAll(now: now)
        XCTAssertEqual(result.first?.state, .failed)
        XCTAssertTrue(result.first?.errorMessage?.contains("persist source health") == true)
    }

    func testReadOnlyOpenOfMissingFileThrows() {
        XCTAssertThrowsError(try SQLiteUsageStore(url: databaseURL, readOnly: true))
    }

    func testCorruptRowFailsInsteadOfBeingSkipped() throws {
        do {
            let store = try SQLiteUsageStore(url: databaseURL)
            try store.replace(batch: CollectionBatch(daily: [record()]), sourceID: "claude", deviceID: "device-a")
        }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "UPDATE daily_usage SET day = 'not-a-day';", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        let store = try SQLiteUsageStore(url: databaseURL, readOnly: true)
        XCTAssertThrowsError(try store.records())
    }

    func testNeverSeenUnavailableSourceIsNotInstalledWhileCachedSourceBecomesUnavailable() async throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let device = Device(id: "device-a", name: "Test Mac")
        let cachedRecord = record("codex", model: "gpt-5", input: 50)
        try store.replace(batch: CollectionBatch(daily: [cachedRecord]), sourceID: "codex", deviceID: device.id)

        let multiCollector = MultiSourceCollector(
            sourceIDs: ["claude", "codex", "kimi"],
            batch: CollectionBatch(
                daily: [record("claude")],
                unavailableSourceIDs: ["codex", "kimi"]
            )
        )
        let runner = CollectionRunner(store: store, device: device, collectors: [
            multiCollector,
            FailingCollector(sourceIDs: ["grok"], unavailable: true),
        ])
        let results = await runner.runAll(now: now)
        let bySource = Dictionary(uniqueKeysWithValues: results.map { ($0.sourceID, $0) })

        XCTAssertEqual(bySource["claude"]?.state, .ok)
        XCTAssertEqual(bySource["codex"]?.state, .unavailable)
        XCTAssertEqual(bySource["kimi"]?.state, .notInstalled)
        XCTAssertNil(bySource["kimi"]?.errorMessage)
        XCTAssertEqual(bySource["grok"]?.state, .notInstalled)
        XCTAssertEqual(bySource["grok"]?.markingStale(now: now.addingTimeInterval(100_000)).state, .notInstalled)

        let persisted = Dictionary(uniqueKeysWithValues: try store.health().map { ($0.sourceID, $0) })
        XCTAssertEqual(persisted["kimi"]?.state, .notInstalled)
        XCTAssertEqual(persisted["grok"]?.state, .notInstalled)
        XCTAssertEqual(persisted["codex"]?.state, .unavailable)
        XCTAssertTrue(try store.records().contains(cachedRecord))
    }

    func testInstalledSourceWithoutUsageIsHealthyNotFailed() async throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let runner = CollectionRunner(
            store: store,
            device: Device(id: "device-a", name: "Test Mac"),
            collectors: [MultiSourceCollector(sourceIDs: ["fx"], batch: CollectionBatch())]
        )
        _ = await runner.runAll(now: now)
        let health = try XCTUnwrap(try store.health().first { $0.sourceID == "fx" })
        XCTAssertNotEqual(health.state, .failed)
        XCTAssertNil(health.errorMessage)
        XCTAssertEqual(health.recordCount, 0)
    }

    func testRunnerSanitizesPathsFromHealthErrorMessages() async throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let runner = CollectionRunner(
            store: store,
            device: Device(id: "device-a", name: "Test Mac"),
            collectors: [PathLeakingCollector()]
        )
        let results = await runner.runAll(now: now)
        let message = try XCTUnwrap(results.first?.errorMessage)
        XCTAssertFalse(message.contains("/Users/"))
        XCTAssertFalse(message.contains("/tmp/"))
        XCTAssertFalse(message.contains("~"))
        XCTAssertEqual(try store.health().first?.errorMessage, message)
    }
}

private struct FailingCollector: UsageCollector {
    var sourceIDs = ["claude"]
    let unavailable: Bool
    func collect() async throws -> CollectionBatch {
        if unavailable { throw CollectorError.sourceUnavailable }
        throw CollectorError.invalidOutput("synthetic failure")
    }
}

private struct MultiSourceCollector: UsageCollector {
    let sourceIDs: [String]
    let batch: CollectionBatch
    func collect() async throws -> CollectionBatch { batch }
}

private struct PathLeakingCollector: UsageCollector {
    let sourceIDs = ["claude"]
    func collect() async throws -> CollectionBatch {
        throw NSError(
            domain: "TestDomain",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Failed reading /Users/alice/.claude/projects and ~/secret or /tmp/cache"]
        )
    }
}

private struct SuccessfulCollector: UsageCollector {
    let sourceIDs = ["claude"]
    let batch: CollectionBatch
    func collect() async throws -> CollectionBatch { batch }
}
