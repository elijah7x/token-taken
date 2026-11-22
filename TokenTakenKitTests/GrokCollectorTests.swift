import XCTest
@testable import TokenTakenKit

final class GrokCollectorTests: XCTestCase {
    private var directory: URL!
    private var home: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        home = directory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private let utc = TimeZone(identifier: "UTC")!

    private func writeSession(
        _ sessionID: String,
        under root: URL? = nil,
        updates: [String],
        summary: [String: Any]? = nil,
        events: [String]? = nil,
        signals: [String: Any]? = nil
    ) throws -> URL {
        let base = root ?? home.appendingPathComponent(".grok", isDirectory: true)
        let sessionDir = base.appendingPathComponent("sessions/\(sessionID)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let updatesURL = sessionDir.appendingPathComponent("updates.jsonl")
        let body = updates.isEmpty ? "" : updates.joined(separator: "\n") + "\n"
        try Data(body.utf8).write(to: updatesURL)
        if let summary {
            let data = try JSONSerialization.data(withJSONObject: summary)
            try data.write(to: sessionDir.appendingPathComponent("summary.json"))
        }
        if let events {
            let text = events.isEmpty ? "" : events.joined(separator: "\n") + "\n"
            try Data(text.utf8).write(to: sessionDir.appendingPathComponent("events.jsonl"))
        }
        if let signals {
            let data = try JSONSerialization.data(withJSONObject: signals)
            try data.write(to: sessionDir.appendingPathComponent("signals.json"))
        }
        return updatesURL
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func turnCompletedLine(
        promptID: String? = nil,
        modelID: String? = nil,
        timestampMs: Int64? = nil,
        usage: [String: Any]
    ) throws -> String {
        var update: [String: Any] = [
            "sessionUpdate": "turn_completed",
            "usage": usage,
        ]
        if let promptID { update["promptId"] = promptID }
        if let modelID { update["_meta"] = ["modelId": modelID] }
        var params: [String: Any] = ["update": update]
        if let timestampMs { params["_meta"] = ["agentTimestampMs": timestampMs] }
        return try jsonLine(["params": params])
    }

    private func collector(
        home: URL? = nil,
        environment: [String: String] = [:],
        timeZone: TimeZone? = nil,
        now: Date = ISO8601DateFormatter().date(from: "2026-11-19T12:00:00Z")!,
        stateDirectory: URL? = nil
    ) -> GrokCollector {
        GrokCollector(
            deviceID: "device-a",
            home: home ?? self.home,
            environment: environment,
            timeZone: timeZone ?? utc,
            now: now,
            stateDirectory: stateDirectory
        )
    }

    private func ms(_ iso: String) -> Int64 {
        Int64((ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 * 1_000).rounded())
    }

    func testNormalTurnCountingAndCategorySplitExcludesCacheReadFromInput() async throws {
        // Inclusive counters: totalTokens == inputTokens + outputTokens (or omitted),
        // so cacheRead is subtracted from input and reasoning is subtracted from output.
        let inclusiveTurn = try turnCompletedLine(
            promptID: "prompt-inclusive",
            modelID: "Grok-4.7",
            timestampMs: ms("2026-11-19T10:00:00Z"),
            usage: [
                "inputTokens": 1_000,
                "cachedReadTokens": 400,
                "cachedWriteTokens": 50,
                "outputTokens": 300,
                "reasoningTokens": 80,
                "totalTokens": 1_300,
                "modelCalls": 2,
            ]
        )
        // Exclusive counters: totalTokens != inputTokens + outputTokens, so raw values are kept.
        let exclusiveTurn = try turnCompletedLine(
            promptID: "prompt-exclusive",
            modelID: "grok-4.7",
            timestampMs: ms("2026-11-19T11:00:00Z"),
            usage: [
                "input_tokens": 500,
                "cache_read_input_tokens": 200,
                "cache_creation_input_tokens": 25,
                "output_tokens": 120,
                "thoughtTokens": 30,
                "total_tokens": 875,
                "modelUsage": [
                    "grok-4.7": ["modelCalls": 3],
                ],
            ]
        )
        _ = try writeSession("session-normal", updates: [inclusiveTurn, exclusiveTurn])

        let batch = try await collector().collect()

        XCTAssertEqual(batch.skippedRecords, 0)
        XCTAssertEqual(batch.daily.count, 1)
        let record = try XCTUnwrap(batch.daily.first)
        XCTAssertEqual(record.sourceID, "grok")
        XCTAssertEqual(record.deviceID, "device-a")
        XCTAssertEqual(record.day, "2026-11-19")
        XCTAssertEqual(record.modelID, "grok-4.7")
        XCTAssertEqual(record.rawModelID, "Grok-4.7")
        XCTAssertEqual(
            record.counts,
            TokenCounts(input: 1_100, cacheRead: 600, cacheWrite: 75, output: 340, reasoning: 110)
        )
        XCTAssertEqual(record.eventCount, 5)

        XCTAssertEqual(batch.hourly.count, 2)
        XCTAssertTrue(batch.hourly.allSatisfy { $0.reasoningKnown && $0.sourceID == "grok" })
        XCTAssertEqual(batch.hourly.map(\.eventCount), [2, 3])
    }

    func testRetransmittedPromptIDIsDedupedKeepingLargerTotal() async throws {
        let first = try turnCompletedLine(
            promptID: "prompt-dup",
            modelID: "grok-4.7",
            timestampMs: ms("2026-11-19T09:00:00Z"),
            usage: ["inputTokens": 100, "cachedReadTokens": 20, "outputTokens": 30]
        )
        let retransmission = try turnCompletedLine(
            promptID: "prompt-dup",
            modelID: "grok-4.7",
            timestampMs: ms("2026-11-19T09:01:00Z"),
            usage: ["inputTokens": 250, "cachedReadTokens": 50, "outputTokens": 70, "modelCalls": 2]
        )
        // A smaller stale retransmission must not overwrite the larger one.
        let smaller = try turnCompletedLine(
            promptID: "prompt-dup",
            modelID: "grok-4.7",
            timestampMs: ms("2026-11-19T09:02:00Z"),
            usage: ["inputTokens": 90, "outputTokens": 10]
        )
        _ = try writeSession("session-dup", updates: [first, retransmission, smaller])

        let batch = try await collector().collect()

        XCTAssertEqual(batch.daily.count, 1)
        let record = try XCTUnwrap(batch.daily.first)
        XCTAssertEqual(record.counts, TokenCounts(input: 200, cacheRead: 50, output: 70))
        XCTAssertEqual(record.eventCount, 2)
    }

    func testUnifiedLogWithMatchingInferenceDoneDoesNotDoubleCount() async throws {
        let base = home.appendingPathComponent(".grok", isDirectory: true)
        let turnMs = ms("2026-11-19T10:30:00Z")
        let updateLine = try turnCompletedLine(
            promptID: "prompt-1",
            modelID: "grok-code-fast",
            timestampMs: turnMs,
            usage: ["inputTokens": 800, "cachedReadTokens": 300, "outputTokens": 150, "reasoningTokens": 40]
        )
        _ = try writeSession("session-regression", under: base, updates: [updateLine])

        // Write a unified.jsonl containing shell.turn.inference_done 398 ms apart for the same turn.
        let logsDir = base.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let unifiedRecord = try jsonLine([
            "event": "shell.turn.inference_done",
            "sessionId": "session-regression",
            "ts": turnMs - 398,
            "model": "grok-code-fast",
            "usage": ["inputTokens": 800, "cachedReadTokens": 300, "outputTokens": 150, "reasoningTokens": 40],
        ])
        try Data((unifiedRecord + "\n").utf8).write(to: logsDir.appendingPathComponent("unified.jsonl"))

        let batch = try await collector().collect()

        XCTAssertEqual(batch.daily.count, 1)
        let record = try XCTUnwrap(batch.daily.first)
        XCTAssertEqual(record.counts, TokenCounts(input: 500, cacheRead: 300, output: 110, reasoning: 40))
        XCTAssertEqual(record.eventCount, 1)
    }

    func testModelResolutionFallbacksAndSignalsReconciliation() async throws {
        // 1. Model from summary.json when updates have none.
        let summaryTurn = try turnCompletedLine(
            promptID: "p-summary",
            timestampMs: ms("2026-11-19T08:00:00Z"),
            usage: ["inputTokens": 100, "outputTokens": 20]
        )
        _ = try writeSession(
            "session-summary",
            updates: [summaryTurn],
            summary: ["current_model_id": "grok-summary-model"]
        )

        // 2. Model from events.jsonl when summary.json is absent.
        let eventsTurn = try turnCompletedLine(
            promptID: "p-events",
            timestampMs: ms("2026-11-19T08:10:00Z"),
            usage: ["inputTokens": 200, "outputTokens": 30]
        )
        _ = try writeSession(
            "session-events",
            updates: [eventsTurn],
            events: [try jsonLine(["model_id": "grok-events-model", "ts": "2026-11-19T08:05:00Z"])]
        )

        // 3. Model from single-entry usage.modelUsage when no metadata or line model exists.
        let modelUsageTurn = try turnCompletedLine(
            promptID: "p-mu",
            timestampMs: ms("2026-11-19T08:20:00Z"),
            usage: [
                "inputTokens": 300,
                "outputTokens": 40,
                "modelUsage": ["grok-mu-model": ["modelCalls": 1]],
            ]
        )
        _ = try writeSession("session-mu", updates: [modelUsageTurn])

        // 4. Fallback totalTokens turn + signals.json compaction reconciliation + grok-unknown fallback.
        let chunk = try jsonLine([
            "params": [
                "update": ["sessionUpdate": "user_message_chunk"],
                "_meta": ["agentTimestampMs": ms("2026-11-19T09:00:00Z")],
            ],
        ])
        let deltaLine = try jsonLine([
            "params": [
                "_meta": ["agentTimestampMs": ms("2026-11-19T09:05:00Z"), "totalTokens": 250],
            ],
        ])
        _ = try writeSession(
            "session-fallback",
            updates: [chunk, deltaLine],
            signals: [
                "primaryModelId": "grok-signals-model",
                "totalTokensBeforeCompaction": 400,
                "totalTokens": 250,
            ]
        )

        let batch = try await collector().collect()
        let byModel = Dictionary(uniqueKeysWithValues: batch.daily.map { ($0.modelID, $0) })
        XCTAssertEqual(byModel["grok-summary-model"]?.counts, TokenCounts(input: 100, output: 20))
        XCTAssertEqual(byModel["grok-events-model"]?.counts, TokenCounts(input: 200, output: 30))
        XCTAssertEqual(byModel["grok-mu-model"]?.counts, TokenCounts(input: 300, output: 40))
        // signals.json's primaryModelId is the session's metadata model when summary/events name none, so both the
        // turn delta (250) and the compaction reconciliation extra (650 - 250 = 400) go to grok-signals-model.
        XCTAssertNil(byModel["grok-unknown"])
        XCTAssertEqual(byModel["grok-signals-model"]?.counts, TokenCounts(input: 650))
    }

    func testLocalDayAttributionAcrossMidnightAndHourlyWindow() async throws {
        // 2026-11-19T16:30:00Z is 2026-11-20 00:30 in Asia/Shanghai (+08:00),
        // while 2026-11-19T15:30:00Z is 2026-11-19 23:30 in Asia/Shanghai.
        let beforeMidnight = try turnCompletedLine(
            promptID: "p-before",
            modelID: "grok-4.7",
            timestampMs: ms("2026-11-19T15:30:00Z"),
            usage: ["inputTokens": 100, "outputTokens": 10]
        )
        let afterMidnight = try turnCompletedLine(
            promptID: "p-after",
            modelID: "grok-4.7",
            timestampMs: ms("2026-11-19T16:30:00Z"),
            usage: ["inputTokens": 200, "outputTokens": 20]
        )
        // Older than 48h: included in both daily and hourly history.
        let oldTurn = try turnCompletedLine(
            promptID: "p-old",
            modelID: "grok-4.7",
            timestampMs: ms("2026-11-15T10:00:00Z"),
            usage: ["inputTokens": 50, "outputTokens": 5]
        )
        _ = try writeSession("session-tz", updates: [beforeMidnight, afterMidnight, oldTurn])

        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        let now = ISO8601DateFormatter().date(from: "2026-11-19T17:00:00Z")!
        let batch = try await collector(timeZone: shanghai, now: now).collect()

        XCTAssertEqual(batch.daily.map(\.day), ["2026-11-15", "2026-11-19", "2026-11-20"])
        XCTAssertTrue(batch.daily.allSatisfy { $0.timeZoneID == "Asia/Shanghai" })
        XCTAssertEqual(batch.daily.map(\.counts), [
            TokenCounts(input: 50, output: 5),
            TokenCounts(input: 100, output: 10),
            TokenCounts(input: 200, output: 20),
        ])

        XCTAssertEqual(batch.hourly.map(\.hourStart), [
            ISO8601DateFormatter().date(from: "2026-11-15T10:00:00Z")!,
            ISO8601DateFormatter().date(from: "2026-11-19T15:00:00Z")!,
            ISO8601DateFormatter().date(from: "2026-11-19T16:00:00Z")!,
        ])
    }

    func testMalformedLinesAreCountedAsSkippedWithoutDroppingValidTurns() async throws {
        let valid = try turnCompletedLine(
            promptID: "p-valid",
            modelID: "grok-4.7",
            timestampMs: ms("2026-11-19T10:00:00Z"),
            usage: ["inputTokens": 75, "outputTokens": 15]
        )
        _ = try writeSession("session-bad", updates: [
            "{not valid json",
            "",
            "[1, 2, 3]",
            "   \t",
            valid,
            "{truncated",
        ])

        let batch = try await collector().collect()

        XCTAssertEqual(batch.skippedRecords, 2)
        XCTAssertEqual(batch.daily.count, 1)
        XCTAssertEqual(batch.daily.first?.counts, TokenCounts(input: 75, output: 15))
    }

    func testMissingDirectoryThrowsSourceUnavailableAndGrokHomeOverridesDefault() async throws {
        let missing = directory.appendingPathComponent("missing-home", isDirectory: true)
        do {
            _ = try await collector(home: missing).collect()
            XCTFail("Expected CollectorError.sourceUnavailable when ~/.grok is missing")
        } catch CollectorError.sourceUnavailable {
        }

        let overrideRoot = directory.appendingPathComponent("custom-grok-home", isDirectory: true)
        let line = try turnCompletedLine(
            promptID: "p-override",
            modelID: "grok-4.7",
            timestampMs: ms("2026-11-19T10:00:00Z"),
            usage: ["inputTokens": 120, "outputTokens": 30]
        )
        _ = try writeSession("session-override", under: overrideRoot, updates: [line])

        let batch = try await collector(
            home: missing,
            environment: ["GROK_HOME": overrideRoot.path]
        ).collect()
        XCTAssertEqual(batch.daily.count, 1)
        XCTAssertEqual(batch.daily.first?.counts, TokenCounts(input: 120, output: 30))
    }

    func testSecondCollectWithoutChangesSkipsWorkAndSiblingChangeInvalidates() async throws {
        let turn = try turnCompletedLine(
            promptID: "p-state",
            timestampMs: ms("2026-11-19T10:00:00Z"),
            usage: ["inputTokens": 40, "outputTokens": 10]
        )
        let updatesURL = try writeSession("session-state", updates: [turn])
        let stateDir = directory.appendingPathComponent("collector-state", isDirectory: true)
        let subject = collector(stateDirectory: stateDir)

        let first = try await subject.collect()
        XCTAssertEqual(first.daily.first?.modelID, "grok-unknown")
        for commit in first.stateCommits { try commit() }

        let second = try await subject.collect()
        XCTAssertEqual(second.unchangedSourceIDs, ["grok"])
        XCTAssertTrue(second.daily.isEmpty && second.hourly.isEmpty)

        // Adding a sibling summary.json must invalidate the fingerprint and re-read.
        let summaryURL = updatesURL.deletingLastPathComponent().appendingPathComponent("summary.json")
        let summaryData = try JSONSerialization.data(withJSONObject: ["model_id": "grok-4.7"])
        try summaryData.write(to: summaryURL)

        let third = try await subject.collect()
        XCTAssertTrue(third.unchangedSourceIDs.isEmpty)
        XCTAssertEqual(third.daily.first?.modelID, "grok-4.7")
    }

    func testOversizedCountersAreIgnoredWithoutOverflow() async throws {
        let huge = try turnCompletedLine(
            promptID: "p-huge",
            modelID: "grok-4.7",
            timestampMs: ms("2026-11-19T10:00:00Z"),
            usage: ["inputTokens": Int64.max, "outputTokens": 1, "totalTokens": Int64.max]
        )
        let normal = try turnCompletedLine(
            promptID: "p-normal",
            modelID: "grok-4.7",
            timestampMs: ms("2026-11-19T10:05:00Z"),
            usage: ["inputTokens": 100, "outputTokens": 10]
        )
        _ = try writeSession("session-huge", updates: [huge, normal])

        let batch = try await collector().collect()
        let total = batch.daily.reduce(Int64(0)) { $0 + $1.counts.total }
        XCTAssertLessThan(total, 1 << 50)
        // The out-of-range field is dropped on its own; the row's valid output (1) still counts.
        let row = batch.daily.first(where: { $0.modelID == "grok-4.7" })
        XCTAssertEqual(row?.counts.input, 100)
        XCTAssertEqual(row?.counts.output, 11)
    }

    func testCumulativeOnlyHoursHaveUnknownReasoning() async throws {
        let chunk = try jsonLine([
            "params": [
                "update": ["sessionUpdate": "user_message_chunk"],
                "_meta": ["agentTimestampMs": ms("2026-11-19T09:00:00Z")],
            ],
        ])
        let total = try jsonLine([
            "params": ["_meta": ["agentTimestampMs": ms("2026-11-19T09:05:00Z"), "totalTokens": 500]],
        ])
        _ = try writeSession("session-cumulative", updates: [chunk, total], summary: ["current_model_id": "grok-4.7"])

        let batch = try await collector().collect()
        XCTAssertEqual(batch.hourly.count, 1)
        XCTAssertEqual(batch.hourly.first?.counts.input, 500)
        XCTAssertEqual(batch.hourly.first?.reasoningKnown, false)
    }
}
