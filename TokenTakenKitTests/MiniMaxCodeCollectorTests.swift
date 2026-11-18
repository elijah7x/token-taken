import XCTest
@testable import TokenTakenKit

final class MiniMaxCodeCollectorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private let utc = TimeZone(identifier: "UTC")!

    private func milliseconds(_ value: String) -> Int64 {
        Int64(ISO8601DateFormatter().date(from: value)!.timeIntervalSince1970 * 1_000)
    }

    private func line(
        id: String?,
        role: String = "assistant",
        model: String = "MiniMax-M3.1-Flash",
        timestamp: Int64,
        usage: [String: Any]? = nil
    ) -> [String: Any] {
        var message: [String: Any] = ["role": role, "model": model, "timestamp": timestamp]
        if let usage { message["usage"] = usage }
        var object: [String: Any] = ["message": message, "turn_id": "turn-a"]
        if let id { object["message_id"] = id }
        return object
    }

    /// Writes one `messages.jsonl` per session path, relative to the `v2/sessions` root.
    private func makeHome(_ sessions: [String: [[String: Any]]]) throws -> URL {
        let root = directory.appendingPathComponent(".minimax/v2/sessions", isDirectory: true)
        for (path, lines) in sessions {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = Data()
            for line in lines {
                data.append(try JSONSerialization.data(withJSONObject: line))
                data.append(0x0A)
            }
            try data.write(to: url)
        }
        return directory
    }

    private func session(_ name: String) -> String {
        "2026/01/01/\(name)-session_synthetic/messages.jsonl"
    }

    private func collector(
        home: URL,
        timeZone: TimeZone? = nil,
        now: Date = ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z")!,
        stateDirectory: URL? = nil
    ) -> MiniMaxCodeCollector {
        MiniMaxCodeCollector(
            deviceID: "device-a", home: home, environment: [:],
            timeZone: timeZone ?? utc, now: now, stateDirectory: stateDirectory
        )
    }

    func testCountsAssistantUsageAndIgnoresZeroAndCostOnlyLines() async throws {
        let home = try makeHome([
            session("a"): [
                line(id: "message-a", timestamp: milliseconds("2026-01-01T10:00:00Z"), usage: [
                    "input": 100, "cacheRead": 20, "cacheWrite": 5, "output": 3, "totalTokens": 128,
                    "cost": ["input": 0.5, "output": 0.5, "cacheRead": 0, "cacheWrite": 0, "total": 1],
                ]),
                // Only assistant messages carry billable usage.
                line(id: "message-user", role: "user", timestamp: milliseconds("2026-01-01T10:01:00Z"), usage: [
                    "input": 999, "cacheRead": 999, "cacheWrite": 0, "output": 999,
                ]),
                line(id: "message-zero", timestamp: milliseconds("2026-01-01T10:02:00Z"), usage: [
                    "input": 0, "cacheRead": 0, "cacheWrite": 0, "output": 0, "totalTokens": 0,
                ]),
                // The cost object is present but every token counter is absent.
                line(id: "message-cost", timestamp: milliseconds("2026-01-01T10:03:00Z"), usage: [
                    "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0],
                ]),
            ],
        ])

        let batch = try await collector(home: home).collect()

        XCTAssertEqual(batch.daily.count, 1)
        let record = try XCTUnwrap(batch.daily.first)
        XCTAssertEqual(record.sourceID, "mcode")
        XCTAssertEqual(record.deviceID, "device-a")
        XCTAssertEqual(record.day, "2026-01-01")
        XCTAssertEqual(record.modelID, "minimax-m3.1-flash")
        XCTAssertEqual(record.rawModelID, "MiniMax-M3.1-Flash")
        XCTAssertEqual(record.counts, TokenCounts(input: 100, cacheRead: 20, cacheWrite: 5, output: 3))
        XCTAssertEqual(record.eventCount, 1)
        XCTAssertEqual(batch.skippedRecords, 0)
    }

    func testMessageIDIsCountedOnceAcrossFiles() async throws {
        let shared = line(id: "message-shared", timestamp: milliseconds("2026-01-01T10:00:00Z"), usage: [
            "input": 50, "cacheRead": 10, "cacheWrite": 0, "output": 5,
        ])
        let home = try makeHome([
            session("a"): [shared],
            session("b"): [shared],
        ])

        let batch = try await collector(home: home).collect()

        XCTAssertEqual(batch.daily.count, 1)
        XCTAssertEqual(batch.daily[0].counts, TokenCounts(input: 50, cacheRead: 10, output: 5))
        XCTAssertEqual(batch.daily[0].eventCount, 1)
    }

    func testDayAndHourComeFromTheMessageTimestamp() async throws {
        let home = try makeHome([
            session("a"): [
                // 23:30 in Los Angeles, already 07:30 of the next UTC day.
                line(id: "message-late", timestamp: milliseconds("2026-01-02T07:30:00Z"), usage: [
                    "input": 10, "cacheRead": 1, "cacheWrite": 0, "output": 2,
                ]),
            ],
        ])
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

        let batch = try await collector(
            home: home, timeZone: losAngeles,
            now: ISO8601DateFormatter().date(from: "2026-01-02T08:00:00Z")!
        ).collect()

        XCTAssertEqual(batch.daily.map(\.day), ["2026-01-01"])
        XCTAssertEqual(batch.daily[0].timeZoneID, "America/Los_Angeles")
        XCTAssertEqual(batch.hourly.count, 1)
        XCTAssertEqual(batch.hourly[0].hourStart, ISO8601DateFormatter().date(from: "2026-01-02T07:00:00Z"))
        XCTAssertEqual(batch.hourly[0].counts, batch.daily[0].counts)
    }

    func testMalformedUsageIsSkippedWithoutLosingValidMessages() async throws {
        let home = try makeHome([
            session("a"): [
                line(id: "message-negative", timestamp: milliseconds("2026-01-01T10:00:00Z"), usage: [
                    "input": -1, "cacheRead": 0, "cacheWrite": 0, "output": 0,
                ]),
                line(id: "message-text", timestamp: milliseconds("2026-01-01T10:01:00Z"), usage: [
                    "input": "100", "cacheRead": 0, "cacheWrite": 0, "output": 0,
                ]),
                line(id: "message-missing", timestamp: milliseconds("2026-01-01T10:02:00Z"), usage: [
                    "input": 10, "cacheRead": 0, "cacheWrite": 0,
                ]),
                line(id: "message-valid", timestamp: milliseconds("2026-01-01T10:03:00Z"), usage: [
                    "input": 100, "cacheRead": 0, "cacheWrite": 0, "output": 5,
                ]),
            ],
        ])

        let batch = try await collector(home: home).collect()

        XCTAssertEqual(batch.skippedRecords, 3)
        XCTAssertEqual(batch.daily.count, 1)
        XCTAssertEqual(batch.daily[0].counts, TokenCounts(input: 100, output: 5))
    }

    private func stateDirectory() -> URL {
        directory.appendingPathComponent("collector-state", isDirectory: true)
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(120)], ofItemAtPath: url.path
        )
    }

    func testSecondCollectWithoutChangesSkipsWork() async throws {
        let home = try makeHome([
            session("a"): [
                line(id: "message-a", timestamp: milliseconds("2026-01-01T10:00:00Z"), usage: [
                    "input": 10, "cacheRead": 0, "cacheWrite": 0, "output": 1,
                ]),
            ],
        ])
        let subject = collector(home: home, stateDirectory: stateDirectory())

        let first = try await subject.collect()
        XCTAssertEqual(first.daily.count, 1)
        XCTAssertEqual(first.stateCommits.count, 1)
        for commit in first.stateCommits { try commit() }

        let second = try await subject.collect()
        XCTAssertEqual(second.unchangedSourceIDs, ["mcode"])
        XCTAssertTrue(second.daily.isEmpty && second.hourly.isEmpty)
        XCTAssertTrue(second.stateCommits.isEmpty)

        try touch(home.appendingPathComponent(".minimax/v2/sessions/2026/01/01/a-session_synthetic/messages.jsonl"))
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

    func testMiniMaxHomeOverridesTheSessionRoot() async throws {
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let overrideHome = directory.appendingPathComponent("override", isDirectory: true)
        try FileManager.default.createDirectory(at: overrideHome, withIntermediateDirectories: true)
        XCTAssertEqual(
            MiniMaxCodeCollector.sessionRoot(home: home, environment: ["MINIMAX_HOME": overrideHome.path]).path,
            overrideHome.appendingPathComponent("v2/sessions").path
        )
        XCTAssertEqual(
            MiniMaxCodeCollector.sessionRoot(home: home, environment: [:]).path,
            home.appendingPathComponent(".minimax/v2/sessions").path
        )
    }

    func testMissingCacheKeysDefaultToZero() async throws {
        let home = try makeHome([
            session("a"): [
                line(id: "message-no-cache", timestamp: milliseconds("2026-01-01T10:00:00Z"), usage: [
                    "input": 10, "output": 5,
                ]),
                line(id: "message-bad-cache", timestamp: milliseconds("2026-01-01T10:01:00Z"), usage: [
                    "input": 10, "output": 5, "cacheRead": -1,
                ]),
            ],
        ])

        let batch = try await collector(home: home).collect()

        XCTAssertEqual(batch.skippedRecords, 1)
        XCTAssertEqual(batch.daily.count, 1)
        XCTAssertEqual(batch.daily[0].counts, TokenCounts(input: 10, cacheRead: 0, cacheWrite: 0, output: 5))
    }

    func testStripsLeadingUTF8BOMOnFirstLine() async throws {
        let url = directory.appendingPathComponent(".minimax/v2/sessions", isDirectory: true)
            .appendingPathComponent(session("bom"))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(try JSONSerialization.data(withJSONObject: line(
            id: "message-bom", timestamp: milliseconds("2026-01-01T10:00:00Z"),
            usage: ["input": 25, "output": 5]
        )))
        data.append(0x0A)
        try data.write(to: url)

        let batch = try await collector(home: directory).collect()

        XCTAssertEqual(batch.skippedRecords, 0)
        XCTAssertEqual(batch.daily.count, 1)
        XCTAssertEqual(batch.daily[0].counts, TokenCounts(input: 25, output: 5))
    }

    func testFutureTimestampIsSkipped() async throws {
        let home = try makeHome([
            session("a"): [
                line(id: "message-future", timestamp: milliseconds("2026-01-03T00:00:00Z"), usage: [
                    "input": 10, "output": 5,
                ]),
            ],
        ])

        let batch = try await collector(home: home).collect()

        XCTAssertTrue(batch.daily.isEmpty)
        XCTAssertEqual(batch.skippedRecords, 1)
    }
}
