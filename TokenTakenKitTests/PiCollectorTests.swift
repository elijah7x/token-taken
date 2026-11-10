import XCTest
@testable import TokenTakenKit

private final class PiCollectorFixtureBundleToken {}

final class PiCollectorTests: XCTestCase {
    /// Pinned so the 48-hour hourly window is deterministic.
    static let now = ISO8601DateFormatter().date(from: "2026-11-11T06:00:00Z")!
    private let utc = TimeZone(identifier: "UTC")!

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func fixture() throws -> Data {
        let bundle = Bundle(for: PiCollectorFixtureBundleToken.self)
        let url = try XCTUnwrap(bundle.url(forResource: "pi-session", withExtension: "jsonl"))
        return try Data(contentsOf: url)
    }

    /// Writes the fixture once per file name, each under its own encoded-cwd directory.
    private func makeRoot(files: [String]) throws -> URL {
        let contents = try fixture()
        let root = directory.appendingPathComponent("sessions", isDirectory: true)
        for name in files {
            let cwd = root.appendingPathComponent("--tmp-pi-\(name)--", isDirectory: true)
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            try contents.write(to: cwd.appendingPathComponent(name))
        }
        return root
    }

    private func collector(root: URL, timeZone: TimeZone? = nil) -> PiCollector {
        let zone = timeZone ?? utc
        return PiCollector(root: root, deviceID: "device-a", timeZone: zone, now: { PiCollectorTests.now })
    }

    private func record(_ batch: CollectionBatch, day: String, modelID: String) throws -> UsageRecord {
        try XCTUnwrap(batch.daily.first { $0.day == day && $0.modelID == modelID }, modelID)
    }

    func testCountsAssistantOperationsAndReasoningSplit() async throws {
        let collector = collector(root: try makeRoot(files: ["session-a.jsonl"]))
        XCTAssertEqual(collector.sourceIDs, ["pi"])

        let batch = try await collector.collect()

        XCTAssertEqual(batch.skippedRecords, 1)
        XCTAssertEqual(batch.daily.map(\.day), [
            "2026-11-07", "2026-11-10", "2026-11-10", "2026-11-10", "2026-11-10", "2026-11-10",
        ])
        XCTAssertEqual(batch.daily.map(\.modelID), [
            "gpt-5-mini", "claude-sonnet-4-5", "kimi-k2", "ollama/qwen3:4b",
            "tools/summaries", "vendor/custom-warm-model",
        ])
        XCTAssertTrue(batch.daily.allSatisfy {
            $0.sourceID == "pi" && $0.deviceID == "device-a" && $0.timeZoneID == utc.identifier
        })

        let claude = try record(batch, day: "2026-11-10", modelID: "claude-sonnet-4-5")
        XCTAssertEqual(claude.rawModelID, "Claude-Sonnet-4-5")
        XCTAssertEqual(claude.counts, TokenCounts(input: 100, cacheRead: 10, cacheWrite: 5, output: 30, reasoning: 20))
        XCTAssertEqual(claude.eventCount, 1, "The exact duplicate entry must collapse.")

        XCTAssertEqual(
            try record(batch, day: "2026-11-10", modelID: "ollama/qwen3:4b").counts,
            TokenCounts(input: 40, output: 20)
        )

        // compaction + branch_summary + model-less toolResult share pi's tools/summaries bucket.
        let operations = try record(batch, day: "2026-11-10", modelID: "tools/summaries")
        XCTAssertEqual(operations.counts, TokenCounts(input: 221, output: 40, reasoning: 8))
        XCTAssertEqual(operations.eventCount, 3)

        let cacheWarm = try record(batch, day: "2026-11-10", modelID: "vendor/custom-warm-model")
        XCTAssertEqual(cacheWarm.rawModelID, "vendor/Custom-Warm-Model")
        XCTAssertEqual(cacheWarm.counts, TokenCounts(input: 7, cacheRead: 90, cacheWrite: 10))

        XCTAssertEqual(
            try record(batch, day: "2026-11-10", modelID: "kimi-k2").counts,
            TokenCounts(input: 11, output: 3, reasoning: 1)
        )
        XCTAssertEqual(
            try record(batch, day: "2026-11-07", modelID: "gpt-5-mini").counts,
            TokenCounts(input: 5, output: 5)
        )
    }

    func testCollidingResponseIdWithDistinctEntryIdsIsCountedTwice() async throws {
        let batch = try await collector(root: try makeRoot(files: ["session-a.jsonl"])).collect()

        // Both records carry responseId "resp-3f2a" but differ in entry id and usage.
        let claude = try record(batch, day: "2026-11-10", modelID: "claude-sonnet-4-5")
        let ollama = try record(batch, day: "2026-11-10", modelID: "ollama/qwen3:4b")
        XCTAssertEqual(claude.eventCount, 1)
        XCTAssertEqual(ollama.eventCount, 1)
        XCTAssertEqual(claude.counts.total + ollama.counts.total, 225)
    }

    func testDuplicatedEntryIdIsCountedOnceAcrossFiles() async throws {
        let single = try await collector(root: try makeRoot(files: ["session-a.jsonl"])).collect()
        let copied = try await collector(
            root: try makeRoot(files: ["session-a.jsonl", "session-b.jsonl"])
        ).collect()

        XCTAssertEqual(copied.skippedRecords, single.skippedRecords * 2)
        XCTAssertEqual(copied.daily.map(\.modelID), single.daily.map(\.modelID))
        XCTAssertEqual(copied.daily.map(\.eventCount), single.daily.map(\.eventCount))
        XCTAssertEqual(copied.daily.map(\.counts), single.daily.map(\.counts))
        XCTAssertEqual(copied.hourly.map(\.counts), single.hourly.map(\.counts))
    }

    func testMalformedLineIsSkippedAndCounted() async throws {
        let batch = try await collector(root: try makeRoot(files: ["session-a.jsonl"])).collect()

        XCTAssertEqual(batch.skippedRecords, 1)
        XCTAssertEqual(batch.daily.reduce(Int64(0)) { $0 + $1.eventCount }, 8)
    }

    func testHourlyBucketsCoverTheLast48HoursOnly() async throws {
        let batch = try await collector(root: try makeRoot(files: ["session-a.jsonl"])).collect()
        let formatter = ISO8601DateFormatter()

        XCTAssertEqual(batch.hourly.map { formatter.string(from: $0.hourStart) }, [
            "2026-11-10T08:00:00Z", "2026-11-10T09:00:00Z", "2026-11-10T20:00:00Z",
        ])

        let first = batch.hourly[0]
        XCTAssertEqual(first.counts, TokenCounts(input: 328, cacheRead: 100, cacheWrite: 15, output: 70, reasoning: 28))
        XCTAssertEqual(first.eventCount, 5)
        XCTAssertFalse(first.reasoningKnown, "branch_summary and toolResult reported no reasoning.")

        XCTAssertEqual(batch.hourly[1].counts, TokenCounts(input: 40, output: 20))
        XCTAssertEqual(batch.hourly[1].eventCount, 1)
        XCTAssertFalse(batch.hourly[1].reasoningKnown)

        XCTAssertEqual(batch.hourly[2].counts, TokenCounts(input: 11, output: 3, reasoning: 1))
        XCTAssertTrue(batch.hourly[2].reasoningKnown)
        XCTAssertTrue(batch.hourly.allSatisfy { $0.sourceID == "pi" && $0.deviceID == "device-a" })
    }

    func testLocalDayUsesTheCollectorTimeZone() async throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let batch = try await collector(root: try makeRoot(files: ["session-a.jsonl"]), timeZone: zone).collect()

        let kimi = try XCTUnwrap(batch.daily.first { $0.modelID == "kimi-k2" })
        XCTAssertEqual(kimi.day, "2026-11-11")
        XCTAssertEqual(kimi.timeZoneID, "Asia/Shanghai")
        XCTAssertEqual(batch.daily.filter { $0.day == "2026-11-11" }.map(\.modelID), ["kimi-k2"])
        // 10:00Z is still the same local day in UTC+08:00.
        XCTAssertEqual(
            try record(batch, day: "2026-11-07", modelID: "gpt-5-mini").counts,
            TokenCounts(input: 5, output: 5)
        )
    }

    func testMissingRootThrowsSourceUnavailable() async throws {
        let collector = collector(root: directory.appendingPathComponent("missing", isDirectory: true))
        do {
            _ = try await collector.collect()
            XCTFail("Expected sourceUnavailable")
        } catch CollectorError.sourceUnavailable {
        }
    }

    func testEmptyRootCollectsNothing() async throws {
        let root = directory.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let batch = try await collector(root: root).collect()
        XCTAssertTrue(batch.daily.isEmpty)
        XCTAssertTrue(batch.hourly.isEmpty)
        XCTAssertEqual(batch.skippedRecords, 0)
    }
}
