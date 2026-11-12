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
        XCTAssertEqual(claude.eventCount, 1)

        // The ollama reply is the session's latest model when the model-less compaction and
        // branch_summary arrive, so both bill it rather than the tools/summaries bucket.
        let ollama = try record(batch, day: "2026-11-10", modelID: "ollama/qwen3:4b")
        XCTAssertEqual(ollama.counts, TokenCounts(input: 254, output: 57, reasoning: 8))
        XCTAssertEqual(ollama.eventCount, 3)

        // Only the toolResult still lands in tools/summaries: it names no model of its own.
        let operations = try record(batch, day: "2026-11-10", modelID: "tools/summaries")
        XCTAssertEqual(operations.counts, TokenCounts(input: 7, output: 3))
        XCTAssertEqual(operations.eventCount, 1)

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
        XCTAssertEqual(ollama.eventCount, 3, "One reply, one compaction, one branch summary.")
        XCTAssertEqual(claude.counts.total + ollama.counts.total, 484)
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

    func testUnreadableRootThrowsAndRunnerKeepsCachedRows() async throws {
        let root = directory.appendingPathComponent("unreadable", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }

        do {
            _ = try await collector(root: root).collect()
            XCTFail("Unreadable session root must throw instead of returning an empty batch")
        } catch CollectorError.sourceUnavailable {
            XCTFail("Existing unreadable directory must not report sourceUnavailable")
        } catch {
        }

        let storeURL = directory.appendingPathComponent("usage.sqlite")
        let store = try SQLiteUsageStore(url: storeURL)
        let cachedDaily = UsageRecord(
            day: "2026-11-10", timeZoneID: utc.identifier, deviceID: "device-a",
            sourceID: "pi", modelID: "claude-sonnet-4-5",
            counts: TokenCounts(input: 100, output: 50), eventCount: 1
        )
        let cachedHourly = HourlyUsage(
            hourStart: PiCollectorTests.now.addingTimeInterval(-3_600), deviceID: "device-a",
            sourceID: "pi", counts: TokenCounts(input: 100, output: 50), eventCount: 1, reasoningKnown: true
        )
        try store.replace(
            batch: CollectionBatch(daily: [cachedDaily], hourly: [cachedHourly]),
            sourceID: "pi", deviceID: "device-a"
        )
        try store.record(health: SourceHealth(
            sourceID: "pi", lastSuccess: PiCollectorTests.now.addingTimeInterval(-600), recordCount: 1
        ))

        let runner = CollectionRunner(
            store: store,
            device: Device(id: "device-a", name: "Test Mac"),
            collectors: [collector(root: root)]
        )
        let results = await runner.runAll(now: PiCollectorTests.now)
        XCTAssertEqual(results.first?.state, .failed)
        XCTAssertEqual(try store.records(), [cachedDaily])
        XCTAssertEqual(try store.hourly(), [cachedHourly])
    }

    func testTimestamplessForkCopyAcrossFilesCountsOnce() async throws {
        let root = directory.appendingPathComponent("timeless", isDirectory: true)
        let dirA = root.appendingPathComponent("cwd-a", isDirectory: true)
        let dirB = root.appendingPathComponent("cwd-b", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)

        let entry = #"{"type":"message","id":"no-ts-1","message":{"role":"assistant","model":"claude-sonnet-4-5","responseId":"resp-same","usage":{"input":40,"output":15,"reasoning":5}}}"# + "\n"
        let fileA = dirA.appendingPathComponent("a.jsonl")
        let fileB = dirB.appendingPathComponent("b.jsonl")
        try Data(entry.utf8).write(to: fileA)
        try Data(entry.utf8).write(to: fileB)
        try FileManager.default.setAttributes(
            [.modificationDate: ISO8601DateFormatter().date(from: "2026-11-10T08:00:00Z")!],
            ofItemAtPath: fileA.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: ISO8601DateFormatter().date(from: "2026-11-10T12:00:00Z")!],
            ofItemAtPath: fileB.path
        )

        let batch = try await collector(root: root).collect()
        XCTAssertEqual(batch.daily.count, 1)
        XCTAssertEqual(batch.daily.first?.day, "2026-11-10")
        XCTAssertEqual(batch.daily.first?.eventCount, 1)
        XCTAssertEqual(batch.daily.first?.counts, TokenCounts(input: 40, output: 10, reasoning: 5))
    }

    func testInvalidReasoningSplitAndNegativeCounters() async throws {
        let root = directory.appendingPathComponent("splits", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"message","id":"bad-split","timestamp":"2026-11-10T10:00:00Z","message":{"role":"assistant","model":"claude-sonnet-4-5","usage":{"input":100,"output":20,"reasoning":50}}}"#,
            #"{"type":"message","id":"neg-counter","timestamp":"2026-11-10T10:05:00Z","message":{"role":"assistant","model":"claude-sonnet-4-5","usage":{"input":-5,"output":20,"reasoning":5}}}"#,
        ].joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: root.appendingPathComponent("session.jsonl"))

        let batch = try await collector(root: root).collect()
        XCTAssertEqual(batch.skippedRecords, 1)
        XCTAssertEqual(batch.daily.count, 1)
        XCTAssertEqual(batch.daily.first?.counts, TokenCounts(input: 100, output: 20, reasoning: 0))
        XCTAssertEqual(batch.daily.first?.eventCount, 1)
        XCTAssertEqual(batch.hourly.count, 1)
        XCTAssertEqual(batch.hourly.first?.counts, TokenCounts(input: 100, output: 20, reasoning: 0))
        XCTAssertEqual(batch.hourly.first?.reasoningKnown, false)
    }

    func testFiveMegabyteAssistantContentWithUsageIsCounted() async throws {
        let root = directory.appendingPathComponent("large-content", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entry: [String: Any] = [
            "type": "message",
            "id": "large-assistant",
            "timestamp": "2026-11-10T10:00:00Z",
            "message": [
                "role": "assistant",
                "model": "claude-sonnet-4-5",
                "content": String(repeating: "x", count: 5 * 1_024 * 1_024),
                "usage": ["input": 100, "cacheRead": 10, "cacheWrite": 5, "output": 50, "reasoning": 20],
            ],
        ]
        var line = try JSONSerialization.data(withJSONObject: entry)
        line.append(0x0A)
        XCTAssertGreaterThan(line.count, 5 * 1_024 * 1_024)
        try line.write(to: root.appendingPathComponent("session.jsonl"))

        let batch = try await collector(root: root).collect()
        XCTAssertEqual(batch.skippedRecords, 0)
        XCTAssertEqual(batch.daily.count, 1)
        XCTAssertEqual(batch.daily.first?.eventCount, 1)
        XCTAssertEqual(
            batch.daily.first?.counts,
            TokenCounts(input: 100, cacheRead: 10, cacheWrite: 5, output: 30, reasoning: 20)
        )
    }

    func testUsageMarkerInsideMessageContentIsNotCounted() async throws {
        let root = directory.appendingPathComponent("content-marker", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entry = #"{"type":"message","id":"text-only","timestamp":"2026-11-10T10:00:00Z","message":{"role":"user","content":"usage"}}"# + "\n"
        try Data(entry.utf8).write(to: root.appendingPathComponent("session.jsonl"))

        let batch = try await collector(root: root).collect()
        XCTAssertEqual(batch.skippedRecords, 0)
        XCTAssertTrue(batch.daily.isEmpty)
        XCTAssertTrue(batch.hourly.isEmpty)
    }

    func testCompactionBeforeAnyModelUsesToolsSummaries() async throws {
        let root = directory.appendingPathComponent("early-compaction", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"compaction","id":"early-c","timestamp":"2026-11-10T10:00:00Z","usage":{"input":30,"output":10,"totalTokens":40}}"#,
            #"{"type":"model_change","id":"early-mc","timestamp":"2026-11-10T10:01:00Z","modelId":"claude-sonnet-4-5"}"#,
            #"{"type":"compaction","id":"late-c","timestamp":"2026-11-10T10:02:00Z","usage":{"input":20,"output":5,"totalTokens":25}}"#,
        ].joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: root.appendingPathComponent("session.jsonl"))

        let batch = try await collector(root: root).collect()

        XCTAssertEqual(batch.daily.map(\.modelID), ["claude-sonnet-4-5", "tools/summaries"])
        XCTAssertEqual(
            try record(batch, day: "2026-11-10", modelID: "tools/summaries").counts,
            TokenCounts(input: 30, output: 10)
        )
        XCTAssertEqual(
            try record(batch, day: "2026-11-10", modelID: "claude-sonnet-4-5").counts,
            TokenCounts(input: 20, output: 5)
        )
    }

    func testNonDirectoryRootErrorDoesNotExposePath() async throws {
        let fileRoot = directory.appendingPathComponent("not-a-dir.jsonl")
        try Data().write(to: fileRoot)
        do {
            _ = try await collector(root: fileRoot).collect()
            XCTFail("Expected invalidOutput")
        } catch {
            let message = error.localizedDescription
            XCTAssertFalse(message.contains(fileRoot.path))
            XCTAssertFalse(message.contains("/"))
        }
    }
}

// MARK: - Incremental collection

private let incrementalAssistantClaude = #"{"type":"message","id":"inc-1","timestamp":"2026-11-10T08:00:00Z","message":{"role":"assistant","model":"claude-sonnet-4-5","usage":{"input":100,"output":40,"reasoning":10}}}"#
private let incrementalModelChange = #"{"type":"model_change","id":"inc-mc","timestamp":"2026-11-10T09:30:00Z","modelId":"test/seeded-model"}"#
private let incrementalSeededUsage = #"{"type":"usage","id":"inc-u1","timestamp":"2026-11-10T10:00:00Z","usage":{"input":7,"output":3}}"#
private let incrementalSeededUsageLater = #"{"type":"usage","id":"inc-u2","timestamp":"2026-11-10T11:00:00Z","usage":{"input":9,"output":4}}"#
private let incrementalAssistantKimi = #"{"type":"message","id":"inc-2","timestamp":"2026-11-10T20:00:00Z","message":{"role":"assistant","model":"kimi-k2","usage":{"input":11,"output":4,"reasoning":1}}}"#

extension PiCollectorTests {
    private var stateDirectory: URL {
        directory.appendingPathComponent("state", isDirectory: true)
    }

    /// Writes synthetic sessions under `<root>/<relative path>`; each file needs its own directory.
    private func makeIncrementalRoot(files: [(path: String, contents: String)]) throws -> URL {
        let root = directory.appendingPathComponent("sessions-\(UUID().uuidString)", isDirectory: true)
        for file in files {
            let url = root.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(file.contents.utf8).write(to: url)
        }
        return root
    }

    private func incrementalCollector(root: URL, timeZone: TimeZone) -> PiCollector {
        PiCollector(
            root: root, deviceID: "device-a", timeZone: timeZone,
            stateDirectory: stateDirectory, now: { PiCollectorTests.now }
        )
    }

    private func fullCollector(root: URL, timeZone: TimeZone) -> PiCollector {
        PiCollector(root: root, deviceID: "device-a", timeZone: timeZone, now: { PiCollectorTests.now })
    }

    @discardableResult
    private func collectAndCommit(_ collector: PiCollector) async throws -> CollectionBatch {
        let batch = try await collector.collect()
        for commit in batch.stateCommits { try commit() }
        return batch
    }

    /// Collects incrementally with a state commit and compares against a fresh full scan.
    @discardableResult
    private func assertMatchesFullScan(_ incremental: PiCollector, _ full: PiCollector) async throws -> CollectionBatch {
        let incrementalBatch = try await collectAndCommit(incremental)
        let fullBatch = try await full.collect()
        XCTAssertEqual(incrementalBatch.daily, fullBatch.daily)
        XCTAssertEqual(incrementalBatch.hourly, fullBatch.hourly)
        XCTAssertEqual(incrementalBatch.skippedRecords, fullBatch.skippedRecords)
        XCTAssertTrue(incrementalBatch.unavailableSourceIDs.isEmpty)
        return incrementalBatch
    }

    func testIncrementalAppendMatchesFullScan() async throws {
        let root = try makeIncrementalRoot(files: [
            ("cwd-a/a.jsonl", incrementalAssistantClaude + "\n" + incrementalModelChange + "\n"),
        ])
        let incremental = incrementalCollector(root: root, timeZone: utc)
        let full = fullCollector(root: root, timeZone: utc)
        try await assertMatchesFullScan(incremental, full)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: stateDirectory.appendingPathComponent("pi.json").path
        ))

        let file = root.appendingPathComponent("cwd-a/a.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        // A record without its trailing newline yet is the state's tail and still counts exactly once.
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(incrementalSeededUsage.utf8))
        try await assertMatchesFullScan(incremental, full)

        // Completing the tail and appending more records re-reads only from the saved offset; the
        // model-less record inherits the session model seeded from the state.
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            ("\n" + incrementalSeededUsageLater + "\n" + incrementalAssistantKimi + "\n").utf8
        ))
        let batch = try await assertMatchesFullScan(incremental, full)
        XCTAssertTrue(batch.daily.contains { $0.modelID == "test/seeded-model" && $0.eventCount == 2 })
    }

    func testSameInodeRewriteLargerIsNotTreatedAsAppend() async throws {
        let root = try makeIncrementalRoot(files: [("cwd-a/a.jsonl", incrementalAssistantClaude + "\n")])
        let incremental = incrementalCollector(root: root, timeZone: utc)
        let full = fullCollector(root: root, timeZone: utc)
        try await assertMatchesFullScan(incremental, full)

        // Truncate and rewrite in place: same inode, larger size, different leading bytes.
        let file = root.appendingPathComponent("cwd-a/a.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((incrementalAssistantKimi + "\n" + incrementalAssistantKimi.replacingOccurrences(of: "inc-2", with: "inc-3") + "\n").utf8))
        try handle.close()
        let batch = try await assertMatchesFullScan(incremental, full)
        XCTAssertFalse(batch.daily.contains { $0.rawModelID == "claude-sonnet-4-5" })
    }

    func testAppendKeepsEarlierSkippedRecords() async throws {
        let root = try makeIncrementalRoot(files: [("cwd-a/a.jsonl", incrementalAssistantClaude + "\n" + #"{"type":"usage","id":"bad","usage":"oops"}"# + "\n")])
        let incremental = incrementalCollector(root: root, timeZone: utc)
        let full = fullCollector(root: root, timeZone: utc)
        let first = try await assertMatchesFullScan(incremental, full)
        let file = root.appendingPathComponent("cwd-a/a.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((incrementalAssistantKimi + "\n").utf8))
        try handle.close()
        let second = try await assertMatchesFullScan(incremental, full)
        XCTAssertEqual(second.skippedRecords, first.skippedRecords)
    }

    func testTruncatedOrReplacedFileIsReparsed() async throws {
        let root = try makeIncrementalRoot(files: [
            ("cwd-a/a.jsonl", incrementalAssistantClaude + "\n" + incrementalAssistantKimi + "\n"),
            ("cwd-b/b.jsonl", incrementalSeededUsage + "\n"),
        ])
        let incremental = incrementalCollector(root: root, timeZone: utc)
        let full = fullCollector(root: root, timeZone: utc)
        try await assertMatchesFullScan(incremental, full)

        // Truncating to the first line drops the second entry.
        let a = root.appendingPathComponent("cwd-a/a.jsonl")
        let handle = try FileHandle(forWritingTo: a)
        try handle.truncate(atOffset: UInt64(incrementalAssistantClaude.utf8.count + 1))
        try handle.close()
        let truncated = try await assertMatchesFullScan(incremental, full)
        XCTAssertFalse(truncated.daily.contains { $0.modelID == "kimi-k2" })

        // Replacing b.jsonl under a new inode reparses it with the new bytes.
        let b = root.appendingPathComponent("cwd-b/b.jsonl")
        try FileManager.default.removeItem(at: b)
        try Data((incrementalAssistantKimi + "\n").utf8).write(to: b)
        try await assertMatchesFullScan(incremental, full)
    }

    func testDeletedFileDropsItsEvents() async throws {
        let root = try makeIncrementalRoot(files: [
            ("cwd-a/a.jsonl", incrementalAssistantClaude + "\n"),
            ("cwd-b/b.jsonl", incrementalAssistantKimi + "\n"),
        ])
        let incremental = incrementalCollector(root: root, timeZone: utc)
        let full = fullCollector(root: root, timeZone: utc)
        try await assertMatchesFullScan(incremental, full)

        try FileManager.default.removeItem(at: root.appendingPathComponent("cwd-b/b.jsonl"))
        let batch = try await assertMatchesFullScan(incremental, full)
        XCTAssertFalse(batch.daily.contains { $0.modelID == "kimi-k2" })
    }

    func testDuplicatedEntryIdAcrossFilesCountsOnceAfterIncrementalUpdate() async throws {
        let root = try makeIncrementalRoot(files: [("cwd-a/a.jsonl", incrementalAssistantClaude + "\n")])
        let incremental = incrementalCollector(root: root, timeZone: utc)
        let full = fullCollector(root: root, timeZone: utc)
        try await assertMatchesFullScan(incremental, full)

        // A fork copy in a second file adds no usage.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("cwd-b"), withIntermediateDirectories: true
        )
        try Data((incrementalAssistantClaude + "\n").utf8)
            .write(to: root.appendingPathComponent("cwd-b/b.jsonl"))
        let copied = try await assertMatchesFullScan(incremental, full)
        XCTAssertEqual(copied.daily.reduce(0) { $0 + Int($1.eventCount) }, 1)

        // Deleting the original re-counts the surviving copy, like a full scan would.
        try FileManager.default.removeItem(at: root.appendingPathComponent("cwd-a/a.jsonl"))
        let surviving = try await assertMatchesFullScan(incremental, full)
        XCTAssertEqual(surviving.daily.reduce(0) { $0 + Int($1.eventCount) }, 1)
    }

    func testNoChangesReturnsUnchangedSourceIDs() async throws {
        let root = try makeIncrementalRoot(files: [("cwd-a/a.jsonl", incrementalAssistantClaude + "\n")])
        let incremental = incrementalCollector(root: root, timeZone: utc)
        try await collectAndCommit(incremental)

        let again = try await incremental.collect()
        XCTAssertEqual(again.unchangedSourceIDs, ["pi"])
        XCTAssertTrue(again.daily.isEmpty)
        XCTAssertTrue(again.hourly.isEmpty)
        XCTAssertEqual(again.skippedRecords, 0)
        XCTAssertTrue(again.stateCommits.isEmpty)

        // A later append leaves the unchanged fast path.
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent("cwd-a/a.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((incrementalAssistantKimi + "\n").utf8))
        try handle.close()
        let after = try await collectAndCommit(incremental)
        XCTAssertTrue(after.unchangedSourceIDs.isEmpty)
        XCTAssertEqual(after.daily.count, 2)
    }

    func testTimeZoneChangeForcesFullScan() async throws {
        let root = try makeIncrementalRoot(files: [("cwd-a/a.jsonl", incrementalAssistantKimi + "\n")])
        try await collectAndCommit(incrementalCollector(root: root, timeZone: utc))

        // 20:00Z crosses to the next local day in UTC+08:00, so the state cannot be reused.
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let batch = try await assertMatchesFullScan(
            incrementalCollector(root: root, timeZone: shanghai),
            fullCollector(root: root, timeZone: shanghai)
        )
        XCTAssertTrue(batch.unchangedSourceIDs.isEmpty)
        XCTAssertEqual(batch.daily.first?.day, "2026-11-11")
        XCTAssertEqual(batch.daily.first?.timeZoneID, "Asia/Shanghai")
    }

    func testFormatVersionChangeForcesFullScan() async throws {
        let root = try makeIncrementalRoot(files: [("cwd-a/a.jsonl", incrementalAssistantClaude + "\n")])
        try await collectAndCommit(incrementalCollector(root: root, timeZone: utc))

        let stateFile = CollectorStateFile<PiFormatScanState>(directory: stateDirectory, name: "pi")
        let loaded: PiFormatScanState? = stateFile.load()
        var state = try XCTUnwrap(loaded)
        state.stamp.formatVersion += 1
        try stateFile.save(state)

        // The files are untouched, but the stamp mismatch must still produce a full scan.
        let batch = try await incrementalCollector(root: root, timeZone: utc).collect()
        XCTAssertTrue(batch.unchangedSourceIDs.isEmpty)
        let full = try await fullCollector(root: root, timeZone: utc).collect()
        XCTAssertEqual(batch.daily, full.daily)
    }

    func testStateDirectoryNilWritesNothing() async throws {
        let root = try makeIncrementalRoot(files: [("cwd-a/a.jsonl", incrementalAssistantClaude + "\n")])
        let collector = fullCollector(root: root, timeZone: utc)

        let first = try await collector.collect()
        XCTAssertTrue(first.stateCommits.isEmpty)
        XCTAssertTrue(first.unchangedSourceIDs.isEmpty)

        // nil keeps rescanning in full: no state file appears anywhere.
        let second = try await collector.collect()
        XCTAssertEqual(second.daily, first.daily)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDirectory.path))
    }
}
