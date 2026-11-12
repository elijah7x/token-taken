import XCTest
@testable import TokenTakenKit

final class DeepSeekCollectorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private let utc = TimeZone(identifier: "UTC")!

    private func session(
        id: String?,
        total: Any?,
        createdAt: String?,
        model: String = "deepseek-v4-pro"
    ) -> [String: Any] {
        var metadata: [String: Any] = [
            "title": "Synthetic session",
            "workspace": "/tmp/synthetic",
            "message_count": 12,
            "cost": ["session_cost_usd": 0.42, "subagent_cost_usd": 0.37],
        ]
        if let id { metadata["id"] = id }
        if let total { metadata["total_tokens"] = total }
        if let createdAt { metadata["created_at"] = createdAt }
        metadata["model"] = model
        return ["metadata": metadata, "messages": [["role": "user", "content": "synthetic"]]]
    }

    private func sessionRoot() -> URL {
        directory.appendingPathComponent(".deepseek/sessions", isDirectory: true)
    }

    private func write(_ object: [String: Any], named name: String) throws {
        try write(data: try JSONSerialization.data(withJSONObject: object), named: name)
    }

    private func write(data: Data, named name: String) throws {
        let root = sessionRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent(name))
    }

    private func collector(
        home: URL,
        timeZone: TimeZone? = nil,
        stateDirectory: URL? = nil
    ) -> DeepSeekCollector {
        DeepSeekCollector(
            deviceID: "device-a", home: home, timeZone: timeZone ?? utc, stateDirectory: stateDirectory
        )
    }

    func testSessionTotalsBecomeUncategorizedDailyRows() async throws {
        try write(session(id: "session-a", total: 1_000, createdAt: "2026-05-20T03:07:32.711069Z"),
                  named: "a.json")
        try write(session(id: "session-b", total: 500, createdAt: "2026-05-20T20:00:00Z"),
                  named: "b.json")
        try write(session(id: "session-c", total: 250, createdAt: "2026-05-21T10:00:00Z"),
                  named: "c.json")

        let batch = try await collector(home: directory).collect()

        XCTAssertEqual(batch.daily.count, 2)
        XCTAssertEqual(batch.daily.map(\.day), ["2026-05-20", "2026-05-21"])
        let merged = batch.daily[0]
        XCTAssertEqual(merged.sourceID, "deepseek-cli")
        XCTAssertEqual(merged.deviceID, "device-a")
        XCTAssertEqual(merged.modelID, "deepseek-v4-pro")
        XCTAssertEqual(merged.rawModelID, "deepseek-v4-pro")
        XCTAssertEqual(merged.counts, TokenCounts(uncategorized: 1_500))
        XCTAssertEqual(merged.counts.input + merged.counts.cacheRead + merged.counts.cacheWrite
            + merged.counts.output + merged.counts.reasoning, 0)
        XCTAssertEqual(merged.eventCount, 0)
        XCTAssertEqual(batch.daily[1].counts, TokenCounts(uncategorized: 250))
        XCTAssertTrue(batch.hourly.isEmpty)
        XCTAssertEqual(batch.skippedRecords, 0)
    }

    func testDayIsTheLocalCalendarDayOfCreatedAt() async throws {
        try write(session(id: "session-late", total: 700, createdAt: "2026-01-02T07:30:00.123456Z"),
                  named: "late.json")
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

        let batch = try await collector(home: directory, timeZone: losAngeles).collect()

        XCTAssertEqual(batch.daily.count, 1)
        XCTAssertEqual(batch.daily[0].day, "2026-01-01")
        XCTAssertEqual(batch.daily[0].timeZoneID, "America/Los_Angeles")
        XCTAssertEqual(batch.daily[0].counts, TokenCounts(uncategorized: 700))
    }

    func testDuplicateSessionIDIsCountedOnce() async throws {
        try write(session(id: "session-dup", total: 100, createdAt: "2026-06-01T00:00:00Z"), named: "a.json")
        try write(session(id: "session-dup", total: 900, createdAt: "2026-06-01T01:00:00Z"), named: "b.json")

        let batch = try await collector(home: directory).collect()

        XCTAssertEqual(batch.daily.count, 1)
        XCTAssertEqual(batch.daily[0].counts, TokenCounts(uncategorized: 100))
    }

    func testUnparsableZeroAndUndatedSessionsAreSkipped() async throws {
        try write(session(id: "session-zero", total: 0, createdAt: "2026-06-01T00:00:00Z"), named: "zero.json")
        try write(session(id: "session-undated", total: 50, createdAt: nil), named: "undated.json")
        try write(data: Data("{ not json".utf8), named: "broken.json")
        try write(session(id: "session-valid", total: 40, createdAt: "2026-06-02T00:00:00Z"), named: "valid.json")

        let batch = try await collector(home: directory).collect()

        XCTAssertEqual(batch.skippedRecords, 3)
        XCTAssertEqual(batch.daily.count, 1)
        XCTAssertEqual(batch.daily[0].counts, TokenCounts(uncategorized: 40))
    }

    func testOnlySessionFilesDirectlyInTheRootAreRead() async throws {
        try write(session(id: "session-root", total: 10, createdAt: "2026-06-01T00:00:00Z"), named: "root.json")
        let nested = sessionRoot().appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: session(id: "session-nested", total: 9_999,
            createdAt: "2026-06-01T00:00:00Z"))
            .write(to: nested.appendingPathComponent("nested.json"))

        let batch = try await collector(home: directory).collect()

        XCTAssertEqual(batch.daily.count, 1)
        XCTAssertEqual(batch.daily[0].counts, TokenCounts(uncategorized: 10))
    }

    private func stateDirectory() -> URL {
        directory.appendingPathComponent("collector-state", isDirectory: true)
    }

    func testSecondCollectWithoutChangesSkipsWork() async throws {
        try write(session(id: "session-a", total: 100, createdAt: "2026-06-01T00:00:00Z"), named: "a.json")
        let subject = collector(home: directory, stateDirectory: stateDirectory())

        let first = try await subject.collect()
        XCTAssertEqual(first.daily.count, 1)
        XCTAssertEqual(first.stateCommits.count, 1)
        for commit in first.stateCommits { try commit() }

        let second = try await subject.collect()
        XCTAssertEqual(second.unchangedSourceIDs, ["deepseek-cli"])
        XCTAssertTrue(second.daily.isEmpty)
        XCTAssertTrue(second.stateCommits.isEmpty)

        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(120)],
            ofItemAtPath: sessionRoot().appendingPathComponent("a.json").path
        )
        let third = try await subject.collect()
        XCTAssertTrue(third.unchangedSourceIDs.isEmpty)
        XCTAssertEqual(third.daily.count, 1)
    }

    func testMissingRootThrowsUnavailable() async throws {
        let subject = collector(home: directory.appendingPathComponent("missing", isDirectory: true))
        do {
            _ = try await subject.collect()
            XCTFail("A missing session root must not replace the cached rows with empty data")
        } catch CollectorError.sourceUnavailable {
        }
    }
}
