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
        try fixture(named: "omp-session")
    }

    private func fixture(named name: String) throws -> Data {
        let bundle = Bundle(for: OmpCollectorFixtureBundleToken.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "jsonl"))
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

    /// Writes the worker-MCP fixture into a tree of its own, beside the agent tree of a real machine.
    private func makeWorkerRoot() throws -> URL {
        let root = directory.appendingPathComponent("worker-sessions", isDirectory: true)
        let cwd = root.appendingPathComponent("ot-omp-worker-synthetic-1", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try fixture(named: "omp-worker-session").write(to: cwd.appendingPathComponent("session-a.jsonl"))
        return root
    }

    private func collector(root: URL, timeZone: TimeZone? = nil) -> OmpCollector {
        collector(roots: [root], timeZone: timeZone)
    }

    private func collector(roots: [URL], timeZone: TimeZone? = nil) -> OmpCollector {
        OmpCollector(
            roots: roots, deviceID: "device-a", timeZone: timeZone ?? utc,
            now: { OmpCollectorTests.now }
        )
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

    func testWorkerTreeIsScanned() async throws {
        let agentRoot = try makeRoot(files: ["session-a.jsonl"])
        let workerRoot = try makeWorkerRoot()

        let agentOnly = try await collector(root: agentRoot).collect()
        let both = try await collector(roots: [agentRoot, workerRoot]).collect()

        XCTAssertEqual(agentOnly.daily.map(\.modelID), ["claude-opus-5", "gpt-5", "z-ai/glm-5.2:free"])
        XCTAssertEqual(both.daily.map(\.modelID), [
            "gemini-3.8-flash", "glm-5.3", "claude-opus-5", "gpt-5", "z-ai/glm-5.2:free",
        ])

        let glm = try record(both, modelID: "glm-5.3")
        XCTAssertEqual(glm.day, "2026-09-17")
        // output 12 less reasoning 2: reasoning stays inside output and is split out, not added.
        XCTAssertEqual(glm.counts, TokenCounts(input: 40, cacheRead: 5, output: 10, reasoning: 2))

        // The worker reply, a `model_usage` auxiliary call and the model-less compaction, all on the
        // session's model.
        let gemini = try record(both, modelID: "gemini-3.8-flash")
        XCTAssertEqual(gemini.counts, TokenCounts(input: 583, cacheRead: 3, output: 23, reasoning: 4))
        XCTAssertEqual(gemini.eventCount, 3)

        XCTAssertEqual(both.daily.reduce(Int64(0)) { $0 + $1.eventCount }, 7)
    }

    func testMissingEitherRootStillCollectsTheOther() async throws {
        let agentRoot = try makeRoot(files: ["session-a.jsonl"])
        let missing = directory.appendingPathComponent("missing-worker-sessions", isDirectory: true)

        let alone = try await collector(root: agentRoot).collect()
        let withMissing = try await collector(roots: [agentRoot, missing]).collect()
        XCTAssertEqual(withMissing.daily, alone.daily)

        let workerOnly = try await collector(
            roots: [missing, try makeWorkerRoot()]
        ).collect()
        XCTAssertEqual(workerOnly.daily.map(\.modelID), ["gemini-3.8-flash", "glm-5.3"])
    }

    func testEntryIdPresentInBothTreesIsCountedOnce() async throws {
        let contents = try fixture(named: "omp-worker-session")
        let agentRoot = directory.appendingPathComponent("agent-sessions", isDirectory: true)
        let workerRoot = directory.appendingPathComponent("worker-sessions", isDirectory: true)
        for root in [agentRoot, workerRoot] {
            let cwd = root.appendingPathComponent("--tmp-omp-worker--", isDirectory: true)
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            try contents.write(to: cwd.appendingPathComponent("session-a.jsonl"))
        }

        let single = try await collector(root: workerRoot).collect()
        let both = try await collector(roots: [agentRoot, workerRoot]).collect()

        XCTAssertEqual(both.daily.map(\.counts), single.daily.map(\.counts))
        XCTAssertEqual(both.daily.map(\.eventCount), single.daily.map(\.eventCount))
        XCTAssertEqual(both.daily.reduce(Int64(0)) { $0 + $1.eventCount }, 4)
    }

    func testModelUsageRecordIsCountedLikeUsage() async throws {
        let root = directory.appendingPathComponent("model-usage", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"model_usage","id":"mu-1","timestamp":"2026-11-10T10:00:00Z","purpose":"auto-thinking","role":"tiny","model":"gemini-3.8-flash","usage":{"input":445,"cacheRead":3,"output":1,"totalTokens":446}}"#,
            // No model of its own and no session model yet: unknown, never dropped.
            #"{"type":"model_usage","id":"mu-2","timestamp":"2026-11-10T10:01:00Z","purpose":"session-title","role":"tiny","usage":{"input":9,"output":2,"totalTokens":11}}"#,
        ].joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: root.appendingPathComponent("session.jsonl"))

        let batch = try await collector(root: root).collect()

        XCTAssertEqual(batch.daily.map(\.modelID), ["gemini-3.8-flash", "unknown"])
        XCTAssertEqual(
            try record(batch, modelID: "gemini-3.8-flash").counts,
            TokenCounts(input: 445, cacheRead: 3, output: 1)
        )
        XCTAssertEqual(
            try record(batch, modelID: "unknown").counts,
            TokenCounts(input: 9, output: 2)
        )
    }

    func testNonCountedControlAndStringMessageTimestampDoNotMarkPartial() async throws {
        let root = directory.appendingPathComponent("lenient-omp", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"custom","id":"omp-ctrl","message":"text mentioning usage","timestamp":12345}"#,
            #"{"type":"message","id":"omp-str-ts","timestamp":"2026-11-10T10:15:00Z","message":{"role":"assistant","model":"gpt-5","timestamp":"2026-11-10T09:00:00Z","usage":{"input":14,"output":6,"reasoningTokens":2}}}"#,
            #"{"type":"usage","id":"omp-bad-usage","timestamp":"2026-11-10T10:20:00Z","usage":"oops"}"#,
        ].joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: root.appendingPathComponent("session.jsonl"))

        let batch = try await collector(root: root).collect()
        let formatter = ISO8601DateFormatter()
        XCTAssertEqual(batch.skippedRecords, 1)
        XCTAssertEqual(batch.daily.map(\.modelID), ["gpt-5"])
        XCTAssertEqual(batch.daily.first?.counts, TokenCounts(input: 14, output: 4, reasoning: 2))
        XCTAssertEqual(batch.hourly.map { formatter.string(from: $0.hourStart) }, ["2026-11-10T10:00:00Z"])
    }
}

// MARK: - Incremental collection

private let ompIncrementalEntryOne = #"{"type":"message","id":"omp-inc-1","timestamp":"2026-11-10T08:00:00Z","message":{"role":"assistant","model":"claude-opus-5","usage":{"input":17,"output":10,"reasoningTokens":4}}}"#
private let ompIncrementalEntryTwo = #"{"type":"message","id":"omp-inc-2","timestamp":"2026-11-10T09:00:00Z","message":{"role":"assistant","model":"gpt-5","usage":{"input":8,"cacheRead":3,"output":12,"reasoning":2}}}"#
private let ompIncrementalEntryThree = #"{"type":"message","id":"omp-inc-3","timestamp":"2026-11-10T10:00:00Z","message":{"role":"assistant","model":"kimi-k2","usage":{"input":11,"output":4,"reasoning":1}}}"#

extension OmpCollectorTests {
    private var stateDirectory: URL {
        directory.appendingPathComponent("state", isDirectory: true)
    }

    private func incrementalCollector(root: URL) -> OmpCollector {
        incrementalCollector(roots: [root])
    }

    private func incrementalCollector(roots: [URL]) -> OmpCollector {
        OmpCollector(
            roots: roots, deviceID: "device-a", timeZone: utc,
            stateDirectory: stateDirectory, now: { OmpCollectorTests.now }
        )
    }

    private func fullCollector(roots: [URL]) -> OmpCollector {
        OmpCollector(roots: roots, deviceID: "device-a", timeZone: utc, now: { OmpCollectorTests.now })
    }

    @discardableResult
    private func collectAndCommit(_ collector: OmpCollector) async throws -> CollectionBatch {
        let batch = try await collector.collect()
        for commit in batch.stateCommits { try commit() }
        return batch
    }

    func testIncrementalAppendMatchesFullScan() async throws {
        let root = directory.appendingPathComponent("sessions", isDirectory: true)
        let cwd = root.appendingPathComponent("--tmp-omp-inc--", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let file = cwd.appendingPathComponent("a.jsonl")
        try Data((ompIncrementalEntryOne + "\n").utf8).write(to: file)

        let incremental = incrementalCollector(root: root)
        try await collectAndCommit(incremental)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: stateDirectory.appendingPathComponent("omp.json").path
        ))

        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((ompIncrementalEntryTwo + "\n").utf8))

        let batch = try await collectAndCommit(incremental)
        XCTAssertEqual(batch.daily.map(\.modelID), ["claude-opus-5", "gpt-5"])
        XCTAssertEqual(batch.daily.map(\.counts), [
            TokenCounts(input: 17, output: 6, reasoning: 4),
            TokenCounts(input: 8, cacheRead: 3, output: 10, reasoning: 2),
        ])
        XCTAssertEqual(batch.hourly.map(\.counts), [
            TokenCounts(input: 17, output: 6, reasoning: 4),
            TokenCounts(input: 8, cacheRead: 3, output: 10, reasoning: 2),
        ])
    }

    func testNoChangesReturnsUnchangedSourceIDs() async throws {
        let root = directory.appendingPathComponent("sessions", isDirectory: true)
        let cwd = root.appendingPathComponent("--tmp-omp-inc2--", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try Data((ompIncrementalEntryOne + "\n").utf8).write(to: cwd.appendingPathComponent("a.jsonl"))

        let incremental = incrementalCollector(root: root)
        try await collectAndCommit(incremental)

        let again = try await incremental.collect()
        XCTAssertEqual(again.unchangedSourceIDs, ["omp"])
        XCTAssertTrue(again.daily.isEmpty)
        XCTAssertTrue(again.stateCommits.isEmpty)
    }

    func testIncrementalTracksBothTrees() async throws {
        // Both trees hold a file at the same relative path, so a shared state key would collide.
        let agentRoot = directory.appendingPathComponent("agent-sessions", isDirectory: true)
        let workerRoot = directory.appendingPathComponent("worker-sessions", isDirectory: true)
        let shared = [
            (agentRoot, ompIncrementalEntryOne),
            (workerRoot, ompIncrementalEntryTwo),
        ]
        for (root, entry) in shared {
            let cwd = root.appendingPathComponent("--tmp-omp-inc--", isDirectory: true)
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            try Data((entry + "\n").utf8).write(to: cwd.appendingPathComponent("a.jsonl"))
        }

        let roots = [agentRoot, workerRoot]
        let incremental = incrementalCollector(roots: roots)
        let full = fullCollector(roots: roots)
        var batch = try await collectAndCommit(incremental)
        var fullBatch = try await full.collect()
        XCTAssertEqual(batch.daily, fullBatch.daily)
        XCTAssertEqual(batch.daily.map(\.modelID), ["claude-opus-5", "gpt-5"])

        // An append into the worker tree alone leaves the fast path and counts exactly once.
        let workerFile = workerRoot.appendingPathComponent("--tmp-omp-inc--/a.jsonl")
        var handle = try FileHandle(forWritingTo: workerFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((ompIncrementalEntryThree + "\n").utf8))
        try handle.close()
        batch = try await collectAndCommit(incremental)
        fullBatch = try await full.collect()
        XCTAssertEqual(batch.daily, fullBatch.daily)
        XCTAssertEqual(batch.daily.map(\.modelID), ["claude-opus-5", "gpt-5", "kimi-k2"])

        // A copy of an agent entry written into the worker tree is deduplicated across roots.
        handle = try FileHandle(forWritingTo: workerFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((ompIncrementalEntryOne + "\n").utf8))
        try handle.close()
        batch = try await collectAndCommit(incremental)
        fullBatch = try await full.collect()
        XCTAssertEqual(batch.daily, fullBatch.daily)
        XCTAssertEqual(batch.daily.reduce(Int64(0)) { $0 + $1.eventCount }, 3)
    }

    func testSharedScanSupportsHalfHourTimeZoneAndSkipsDisappearingFile() async throws {
        let kolkata = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let root = directory.appendingPathComponent("omp-kolkata", isDirectory: true)
        let dirA = root.appendingPathComponent("cwd-a", isDirectory: true)
        let dirB = root.appendingPathComponent("cwd-b", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        let entry = #"{"type":"message","id":"omp-ist-1","timestamp":"2026-11-11T05:45:00Z","message":{"role":"assistant","model":"gpt-5","usage":{"input":10,"output":4,"reasoningTokens":1}}}"# + "\n"
        try Data(entry.utf8).write(to: dirA.appendingPathComponent("a.jsonl"))
        let vanish = dirB.appendingPathComponent("vanish.jsonl")
        try Data((ompIncrementalEntryTwo + "\n").utf8).write(to: vanish)

        let batch = try PiFormatScan(
            roots: [root],
            sourceID: "omp",
            deviceID: "device-a",
            timeZone: kolkata,
            stateDirectory: nil,
            now: OmpCollectorTests.now,
            beforeScan: { try? FileManager.default.removeItem(at: vanish) }
        ).run()
        XCTAssertEqual(batch.daily.map(\.modelID), ["gpt-5"])
        XCTAssertEqual(batch.hourly.map { ISO8601DateFormatter().string(from: $0.hourStart) }, ["2026-11-11T05:30:00Z"])
    }
}
