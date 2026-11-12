import SQLite3
import XCTest
@testable import TokenTakenKit

final class AccountDeviceStoreTests: XCTestCase {
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
    private let accountID = "account-cursor-10b9e7b4b52b0976545513032a2ed3f4"
    private var accountDevice: Device { Device(id: accountID, name: "Cursor", kind: .account) }

    private enum TestError: Error {
        case sqlite(String)
    }

    private func execute(_ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let db = handle else {
            throw TestError.sqlite("Could not open the store database")
        }
        defer { sqlite3_close(db) }
        var message: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let error = message.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(message)
            throw TestError.sqlite(error)
        }
    }

    private func userVersion() throws -> Int32 {
        var handle: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let db = handle else {
            throw TestError.sqlite("Could not open the store database")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw TestError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw TestError.sqlite("Could not read the schema version") }
        return sqlite3_column_int(statement, 0)
    }

    private func record(_ day: String, input: Int64, device: String? = nil, model: String = "composer-1") -> UsageRecord {
        UsageRecord(day: day, timeZoneID: "UTC", deviceID: device ?? accountID, sourceID: "cursor",
            modelID: model, rawModelID: model, counts: TokenCounts(input: input, output: 10), eventCount: 2)
    }

    private func dayTotals(_ store: SQLiteUsageStore) throws -> [String: Int64] {
        try store.records().reduce(into: [String: Int64]()) { $0[$1.day, default: 0] += $1.counts.total }
    }

    func testV4StoreGainsDeviceKindWithoutLosingRows() throws {
        do {
            let store = try SQLiteUsageStore(url: databaseURL)
            try store.upsert(device: Device(id: "device-a", name: "Test Mac"))
            try store.replace(batch: CollectionBatch(daily: [record("2026-11-02", input: 10, device: "device-a")]),
                sourceID: "cursor", deviceID: "device-a")
        }
        // The v4 device table had no kind column; recreate that shape and downgrade the recorded version.
        try execute("ALTER TABLE devices DROP COLUMN kind; PRAGMA user_version = 4;")
        XCTAssertThrowsError(try SQLiteUsageStore(url: databaseURL, readOnly: true))

        let store = try SQLiteUsageStore(url: databaseURL)

        XCTAssertEqual(store.devices, [Device(id: "device-a", name: "Test Mac", kind: .mac)])
        XCTAssertEqual(try store.records().map(\.day), ["2026-11-02"])
        XCTAssertEqual(try userVersion(), 5)
    }

    func testAccountDeviceRoundTripsItsKind() throws {
        do {
            let store = try SQLiteUsageStore(url: databaseURL)
            try store.upsert(device: accountDevice)
            XCTAssertEqual(store.devices, [accountDevice])
        }
        let reopened = try SQLiteUsageStore(url: databaseURL, readOnly: true)
        XCTAssertEqual(reopened.devices, [accountDevice])
        XCTAssertEqual(reopened.devices.first?.kind, .account)
    }

    func testUnknownDeviceKindReadsAsMac() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        try store.upsert(device: Device(id: "device-a", name: "Test Mac"))
        try execute("UPDATE devices SET kind = 'tablet' WHERE id = 'device-a';")

        XCTAssertEqual(store.devices.first?.kind, .mac)
    }

    func testAuthoritativeReplaceAdoptsSmallerDaysFromTheEarliestDay() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let seeded = ["2026-11-01", "2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05"].map {
            record($0, input: 100)
        }
        try store.replace(batch: CollectionBatch(daily: seeded), sourceID: "cursor", deviceID: accountID)
        XCTAssertEqual(try dayTotals(store).count, 5)

        // A correction lowers one day, raises another, and stops reporting a third.
        let correction = [record("2026-11-03", input: 50), record("2026-11-05", input: 200)]
        try store.replace(batch: CollectionBatch(daily: correction), sourceID: "cursor", deviceID: accountID,
            authoritative: true)

        let totals = try dayTotals(store)
        XCTAssertEqual(totals["2026-11-01"], 110)
        XCTAssertEqual(totals["2026-11-02"], 110)
        XCTAssertEqual(totals["2026-11-03"], 60)
        XCTAssertNil(totals["2026-11-04"])
        XCTAssertEqual(totals["2026-11-05"], 210)
    }

    func testEmptyAuthoritativeBatchKeepsHistory() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let seeded = [record("2026-11-01", input: 100), record("2026-11-02", input: 200)]
        try store.replace(batch: CollectionBatch(daily: seeded), sourceID: "cursor", deviceID: accountID)

        try store.replace(batch: CollectionBatch(), sourceID: "cursor", deviceID: accountID, authoritative: true)

        XCTAssertEqual(Set(try store.records()), Set(seeded))
    }

    func testNonAuthoritativeReplaceKeepsTheFloor() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let seeded = [record("2026-11-01", input: 100), record("2026-11-02", input: 100), record("2026-11-03", input: 100)]
        try store.replace(batch: CollectionBatch(daily: seeded), sourceID: "cursor", deviceID: accountID)

        // A smaller day and a day missing from the batch are both ignored on the floor path (ADR-0008).
        try store.replace(batch: CollectionBatch(daily: [record("2026-11-02", input: 40)]),
            sourceID: "cursor", deviceID: accountID)

        XCTAssertEqual(Set(try store.records()), Set(seeded))
    }

    func testRunnerStoresAnAccountBatchUnderTheAccountID() async throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let accountRecord = record("2026-11-09", input: 40)
        // The runner's zero-coverage rows sit on local hour boundaries, so the sample row does too.
        let hourStart = Calendar.current.dateInterval(of: .hour, for: now.addingTimeInterval(-3_600))!.start
        let hour = HourlyUsage(hourStart: hourStart, deviceID: accountID, sourceID: "cursor",
            counts: TokenCounts(input: 4), eventCount: 1, reasoningKnown: true)
        let batch = CollectionBatch(
            daily: [accountRecord], hourly: [hour],
            accountDevice: accountDevice, authoritativeSourceIDs: ["cursor"]
        )
        let runner = CollectionRunner(
            store: store,
            device: Device(id: "device-a", name: "Test Mac"),
            collectors: [AccountBatchCollector(batch: batch)]
        )

        let results = await runner.runAll(now: now)

        XCTAssertEqual(results.map(\.sourceID), ["cursor"])
        XCTAssertEqual(results.first?.state, .ok)
        XCTAssertEqual(try store.records(), [accountRecord])
        let hours = try store.hourly()
        XCTAssertEqual(hours.count, 48)
        XCTAssertTrue(hours.allSatisfy { $0.deviceID == accountID })
        XCTAssertEqual(hours.first { $0.eventCount == 1 }?.counts, TokenCounts(input: 4))
        let kinds = Dictionary(uniqueKeysWithValues: store.devices.map { ($0.id, $0.kind) })
        XCTAssertEqual(kinds[accountID], .account)
        XCTAssertEqual(kinds["device-a"], .mac)
    }

    func testRunnerUsesTheAccountIDForZeroCoverage() async throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let batch = CollectionBatch(
            daily: [record("2026-10-01", input: 5, model: "gpt-5")],
            accountDevice: accountDevice, authoritativeSourceIDs: ["cursor"]
        )
        let runner = CollectionRunner(
            store: store,
            device: Device(id: "device-a", name: "Test Mac"),
            collectors: [AccountBatchCollector(batch: batch)]
        )

        _ = await runner.runAll(now: now)

        let hours = try store.hourly()
        XCTAssertEqual(hours.count, 48)
        XCTAssertTrue(hours.allSatisfy { $0.deviceID == accountID && $0.counts == .zero && $0.reasoningKnown })
        XCTAssertEqual(try store.records().map(\.day), ["2026-10-01"])
    }
}

private struct AccountBatchCollector: UsageCollector {
    let sourceIDs = ["cursor"]
    let batch: CollectionBatch
    func collect() async throws -> CollectionBatch { batch }
}
