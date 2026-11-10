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

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.utcGregorian.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func record(
        _ source: String = "claude",
        device: String = "device-a",
        model: String = "model-a",
        input: Int64 = 100
    ) -> UsageRecord {
        UsageRecord(
            day: day(2026, 11, 9),
            deviceID: device,
            sourceID: source,
            modelID: model,
            counts: TokenCounts(input: input, cacheRead: 20, cacheWrite: 10, output: 30, reasoning: 5)
        )
    }

    func testRoundTrip() throws {
        let device = Device(id: "device-a", name: "Test Mac")
        let expected = record()
        do {
            let store = try SQLiteUsageStore(url: databaseURL)
            XCTAssertTrue(store.isEmpty)
            try store.upsert(device: device)
            try store.replace(records: [expected], sourceID: expected.sourceID, deviceID: expected.deviceID)
        }

        let store = try SQLiteUsageStore(url: databaseURL, readOnly: true)
        XCTAssertFalse(store.isEmpty)
        XCTAssertEqual(store.records(), [expected])
        XCTAssertEqual(store.devices, [device])
    }

    func testReplaceIsIdempotentAndScopedToSourceAndDevice() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let claudeA = record()
        let codexA = record("codex", model: "model-b", input: 200)
        let claudeB = record(device: "device-b", input: 300)
        try store.replace(records: [claudeA], sourceID: "claude", deviceID: "device-a")
        try store.replace(records: [codexA], sourceID: "codex", deviceID: "device-a")
        try store.replace(records: [claudeB], sourceID: "claude", deviceID: "device-b")
        try store.replace(records: [claudeA], sourceID: "claude", deviceID: "device-a")
        XCTAssertEqual(Set(store.records()), Set([claudeA, codexA, claudeB]))

        let replacement = record(model: "model-c", input: 400)
        try store.replace(records: [replacement], sourceID: "claude", deviceID: "device-a")
        XCTAssertEqual(Set(store.records()), Set([replacement, codexA, claudeB]))

        try store.replace(records: [], sourceID: "claude", deviceID: "device-a")
        XCTAssertEqual(Set(store.records()), Set([codexA, claudeB]))
    }

    func testHealthRoundTrip() throws {
        let store = try SQLiteUsageStore(url: databaseURL)
        let expected = SourceHealth(
            sourceID: "claude",
            lastAttempt: Date(timeIntervalSince1970: 1_000.25),
            lastSuccess: Date(timeIntervalSince1970: 900.5),
            recordCount: 12,
            errorMessage: "synthetic error"
        )
        try store.record(health: expected)
        XCTAssertEqual(store.health(), [expected])

        let updated = SourceHealth(
            sourceID: "claude",
            lastAttempt: Date(timeIntervalSince1970: 1_100),
            lastSuccess: Date(timeIntervalSince1970: 1_100),
            recordCount: 20
        )
        try store.record(health: updated)
        XCTAssertEqual(store.health(), [updated])
    }

    func testReadOnlyOpenOfMissingFileThrows() {
        XCTAssertThrowsError(try SQLiteUsageStore(url: databaseURL, readOnly: true)) { error in
            guard let storeError = error as? StoreError else {
                return XCTFail("Expected StoreError.open, got \(error)")
            }
            guard case .open = storeError else {
                return XCTFail("Expected StoreError.open, got \(error)")
            }
        }
    }
}
