import XCTest
@testable import TokenTakenKit

private final class OmpCollectorFixtureBundleToken {}

final class OmpCollectorTests: XCTestCase {
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
        let bundle = Bundle(for: OmpCollectorFixtureBundleToken.self)
        let url = try XCTUnwrap(bundle.url(forResource: "omp-session", withExtension: "jsonl"))
        return try Data(contentsOf: url)
    }

    /// Writes the fixture once per file name, each under its own encoded-cwd directory.
    private func makeRoot(files: [String]) throws -> URL {
        let contents = try fixture()
        let root = directory.appendingPathComponent("sessions", isDirectory: true)
        for name in files {
            let cwd = root.appendingPathComponent("--tmp-omp-\(name)--", isDirectory: true)
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            try contents.write(to: cwd.appendingPathComponent(name))
        }
        return root
    }

    private func collector(root: URL, timeZone: TimeZone? = nil) -> OmpCollector {
        let zone = timeZone ?? utc
        return OmpCollector(root: root, deviceID: "device-a", timeZone: zone, now: { OmpCollectorTests.now })
    }

    private func record(_ batch: CollectionBatch, modelID: String) throws -> UsageRecord {
        try XCTUnwrap(batch.daily.first { $0.modelID == modelID }, modelID)
    }

    func testReasoningIsSplitOutOfOutput() async throws {
        let collector = collector(root: try makeRoot(files: ["session-a.jsonl"]))
        XCTAssertEqual(collector.sourceIDs, ["omp"])

        let batch = try await collector.collect()

        XCTAssertEqual(batch.daily.map(\.modelID), ["claude-opus-5", "gpt-5", "z-ai/glm-5.2:free"])
        XCTAssertTrue(batch.daily.allSatisfy {
            $0.day == "2026-11-10" && $0.sourceID == "omp" && $0.deviceID == "device-a"
        })

        // `reasoningTokens: 4` sits inside `output: 10`.
        let claude = try record(batch, modelID: "claude-opus-5")
        XCTAssertEqual(claude.counts, TokenCounts(input: 17, cacheRead: 0, cacheWrite: 0, output: 6, reasoning: 4))
        XCTAssertEqual(claude.eventCount, 1, "The exact duplicate entry must collapse.")

        // The same breakdown recorded under the older `reasoning` spelling.
        let gpt = try record(batch, modelID: "gpt-5")
        XCTAssertEqual(gpt.counts, TokenCounts(input: 8, cacheRead: 3, cacheWrite: 0, output: 10, reasoning: 2))

        let glm = try record(batch, modelID: "z-ai/glm-5.2:free")
        XCTAssertEqual(glm.rawModelID, "z-ai/glm-5.2:free")
        XCTAssertEqual(glm.counts, TokenCounts(input: 22, cacheRead: 6, cacheWrite: 0, output: 3, reasoning: 1))
    }

    func testDuplicatedEntryIdIsCountedOnceAcrossFiles() async throws {
        let single = try await collector(root: try makeRoot(files: ["session-a.jsonl"])).collect()
        let copied = try await collector(
            root: try makeRoot(files: ["session-a.jsonl", "session-b.jsonl"])
        ).collect()

        XCTAssertEqual(copied.daily.map(\.modelID), single.daily.map(\.modelID))
        XCTAssertEqual(copied.daily.map(\.counts), single.daily.map(\.counts))
        XCTAssertEqual(copied.daily.map(\.eventCount), single.daily.map(\.eventCount))
        XCTAssertEqual(copied.hourly.map(\.counts), single.hourly.map(\.counts))
    }

    func testMalformedLineIsSkippedAndCounted() async throws {
        let batch = try await collector(root: try makeRoot(files: ["session-a.jsonl"])).collect()

        XCTAssertEqual(batch.skippedRecords, 1)
        XCTAssertEqual(batch.daily.reduce(Int64(0)) { $0 + $1.eventCount }, 3)
    }

    func testHourlyBucketsAndReasoningKnown() async throws {
        let batch = try await collector(root: try makeRoot(files: ["session-a.jsonl"])).collect()
        let formatter = ISO8601DateFormatter()

        XCTAssertEqual(batch.hourly.map { formatter.string(from: $0.hourStart) }, [
            "2026-11-10T10:00:00Z", "2026-11-10T17:00:00Z",
        ])
        XCTAssertEqual(
            batch.hourly[0].counts,
            TokenCounts(input: 25, cacheRead: 3, cacheWrite: 0, output: 16, reasoning: 6)
        )
        XCTAssertEqual(batch.hourly[0].eventCount, 2)
        XCTAssertTrue(batch.hourly[0].reasoningKnown)
        XCTAssertEqual(batch.hourly[1].counts, TokenCounts(input: 22, cacheRead: 6, output: 3, reasoning: 1))
        XCTAssertTrue(batch.hourly[1].reasoningKnown)
    }

    func testLocalDayUsesTheCollectorTimeZone() async throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let batch = try await collector(root: try makeRoot(files: ["session-a.jsonl"]), timeZone: zone).collect()

        let glm = try XCTUnwrap(batch.daily.first { $0.modelID == "z-ai/glm-5.2:free" })
        XCTAssertEqual(glm.day, "2026-11-11")
        XCTAssertEqual(glm.timeZoneID, "Asia/Shanghai")
        XCTAssertEqual(batch.daily.filter { $0.day == "2026-11-11" }.map(\.modelID), ["z-ai/glm-5.2:free"])
        XCTAssertEqual(try record(batch, modelID: "claude-opus-5").day, "2026-11-10")
    }

    func testMissingRootThrowsSourceUnavailable() async throws {
        let collector = collector(root: directory.appendingPathComponent("missing", isDirectory: true))
        do {
            _ = try await collector.collect()
            XCTFail("Expected sourceUnavailable")
        } catch CollectorError.sourceUnavailable {
        }
    }
}
