import XCTest
@testable import TokenTakenKit

final class GeminiCollectorTests: XCTestCase {
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

    private func collector(
        home: URL? = nil,
        environment: [String: String] = [:],
        timeZone: TimeZone? = nil,
        now: Date = ISO8601DateFormatter().date(from: "2026-11-19T12:00:00Z")!,
        stateDirectory: URL? = nil
    ) -> GeminiCollector {
        GeminiCollector(
            deviceID: "device-a",
            home: home ?? self.home,
            environment: environment,
            timeZone: timeZone ?? utc,
            now: now,
            stateDirectory: stateDirectory
        )
    }

    private func writeText(_ text: String, to url: URL, modified: Date? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    private func writeLines(_ lines: [String], to url: URL, modified: Date? = nil) throws {
        let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try writeText(body, to: url, modified: modified)
    }

    private var defaultSessionRoot: URL {
        home.appendingPathComponent(".gemini/tmp", isDirectory: true)
    }

    private var defaultHeadlessRoot: URL {
        home.appendingPathComponent(".config/tokscale/headless/gemini", isDirectory: true)
    }

    func testInclusiveAndExclusiveInputNormalizationAndToolReasoningSplit() async throws {
        let sessionURL = defaultSessionRoot
            .appendingPathComponent("proj-a/chats/session-2026-11-19.json")
        try writeText(#"""
        {
          "sessionId": "sess-norm",
          "messages": [
            {
              "id": "m1",
              "type": "gemini",
              "timestamp": "2026-11-19T10:00:00.250Z",
              "model": "Gemini-2.5-Pro",
              "tokens": {
                "input": 1000,
                "cached": 400,
                "output": 200,
                "thoughts": 50,
                "tool": 30,
                "total": 1280
              }
            },
            {
              "id": "m2",
              "type": "gemini",
              "timestamp": "2026-11-19T10:15:00Z",
              "model": "gemini-2.5-pro",
              "tokens": {
                "prompt": 500,
                "cached_tokens": 300,
                "candidates": 100,
                "reasoning": 20,
                "tool_tokens": 10
              }
            },
            {
              "id": "m3",
              "type": "gemini",
              "timestamp": "2026-11-19T11:00:00Z",
              "model": "gemini-2.5-pro",
              "tokens": {
                "input_tokens": 600,
                "cached": 400,
                "output_tokens": 150,
                "thoughts_tokens": 25,
                "tool": 5,
                "total_tokens": 1180
              }
            },
            {
              "id": "m4",
              "type": "gemini",
              "timestamp": "2026-11-19T11:30:00Z",
              "model": "gemini-2.5-pro",
              "tokens": {
                "promptTokenCount": 80,
                "cachedContentTokenCount": 320,
                "candidatesTokenCount": 40
              }
            },
            {
              "id": "m5",
              "type": "user",
              "timestamp": "2026-11-19T11:35:00Z",
              "content": "hello"
            },
            {
              "id": "m6",
              "type": "gemini",
              "timestamp": "2026-11-19T11:36:00Z",
              "model": "gemini-2.5-pro",
              "tokens": {
                "input": 0,
                "output": 0,
                "cached": 0,
                "thoughts": 0,
                "tool": 0
              }
            }
          ]
        }
        """#, to: sessionURL)

        let batch = try await collector().collect()

        XCTAssertEqual(batch.skippedRecords, 0)
        XCTAssertEqual(batch.daily.count, 1)
        let record = try XCTUnwrap(batch.daily.first)
        XCTAssertEqual(record.sourceID, "gemini")
        XCTAssertEqual(record.deviceID, "device-a")
        XCTAssertEqual(record.day, "2026-11-19")
        XCTAssertEqual(record.modelID, "gemini-2.5-pro")
        XCTAssertEqual(record.rawModelID, "Gemini-2.5-Pro")
        // m1: in=630, cr=400, out=200, r=50
        // m2: in=210, cr=300, out=100, r=20
        // m3: in=605, cr=400, out=150, r=25
        // m4: in=80,  cr=320, out=40,  r=0
        XCTAssertEqual(
            record.counts,
            TokenCounts(input: 1_525, cacheRead: 1_420, cacheWrite: 0, output: 490, reasoning: 95)
        )
        XCTAssertEqual(record.eventCount, 4)

        XCTAssertEqual(batch.hourly.count, 2)
        XCTAssertTrue(batch.hourly.allSatisfy { $0.reasoningKnown && $0.sourceID == "gemini" })
        XCTAssertEqual(batch.hourly[0].counts, TokenCounts(input: 840, cacheRead: 700, output: 300, reasoning: 70))
        XCTAssertEqual(batch.hourly[1].counts, TokenCounts(input: 685, cacheRead: 720, output: 190, reasoning: 25))
    }

    func testHeadlessJSONLIgnoresTrailingStatsWhenPerTurnEventsExistAndDedupsWithinFile() async throws {
        let headlessURL = defaultHeadlessRoot.appendingPathComponent("run-1.jsonl")
        try writeLines([
            #"{"type":"init","timestamp":"2026-11-19T09:00:00Z","session_id":"sess-headless-1","model":"gemini-2.5-flash"}"#,
            #"{"type":"gemini","id":"turn-1","timestamp":"2026-11-19T09:00:05Z","tokens":{"input":100,"cached":20,"output":10,"thoughts":5}}"#,
            #"{"type":"gemini","id":"turn-1","timestamp":"2026-11-19T09:00:10Z","tokens":{"input":200,"cached":50,"output":40,"thoughts":15}}"#,
            #"{"type":"result","timestamp":"2026-11-19T09:00:15Z","stats":{"input":150,"cached":50,"output_tokens":40,"thoughts":15,"total_tokens":255}}"#,
        ], to: headlessURL)

        let batch = try await collector().collect()

        XCTAssertEqual(batch.skippedRecords, 0)
        XCTAssertEqual(batch.daily.count, 1)
        let record = try XCTUnwrap(batch.daily.first)
        XCTAssertEqual(record.modelID, "gemini-2.5-flash")
        XCTAssertEqual(record.counts, TokenCounts(input: 150, cacheRead: 50, output: 40, reasoning: 15))
        XCTAssertEqual(record.eventCount, 1)
    }

    func testSummaryOnlyHeadlessSupportsModelsMapAndDirectStatsWithMtimeFallback() async throws {
        let mtime = ISO8601DateFormatter().date(from: "2026-11-19T08:30:00Z")!
        let modelsSummaryURL = defaultHeadlessRoot.appendingPathComponent("summary-models.json")
        try writeText(#"""
        {
          "session_id": "sess-models",
          "stats": {
            "models": {
              "gemini-2.5-pro": {
                "api": { "totalRequests": 3 },
                "tokens": {
                  "input": 1000,
                  "cached": 400,
                  "candidates": 200,
                  "thoughts": 50,
                  "tool": 10,
                  "total": 1260
                }
              },
              "gemini-2.5-flash": {
                "api": { "totalRequests": 2 },
                "tokens": {
                  "prompt": 300,
                  "candidates": 50,
                  "total": 350
                }
              }
            }
          }
        }
        """#, to: modelsSummaryURL, modified: mtime)

        let directSummaryURL = defaultHeadlessRoot.appendingPathComponent("summary-direct.jsonl")
        try writeLines([
            #"{"type":"init","timestamp":"2026-11-19T10:00:00Z","session_id":"sess-direct","model":"gemini-2.5-flash"}"#,
            #"{"type":"result","timestamp":"2026-11-19T10:05:00Z","stats":{"input":600,"cached":400,"output_tokens":200,"total_tokens":1200}}"#,
        ], to: directSummaryURL)

        let wrappedSummaryURL = defaultHeadlessRoot.appendingPathComponent("summary-wrapped.jsonl")
        try writeLines([
            #"{"type":"init","session_id":"sess-wrapped","model":"gemini-2.5-flash"}"#,
            #"{"type":"result","timestamp":"2026-11-19T11:05:00Z","result":{"stats":{"input_tokens":100,"output_tokens":20}}}"#,
        ], to: wrappedSummaryURL)

        // Note: sessionRoot does not exist, verifying headless-only availability works.
        let batch = try await collector().collect()
        let byModel = Dictionary(uniqueKeysWithValues: batch.daily.map { ($0.modelID, $0) })

        XCTAssertEqual(batch.skippedRecords, 0)
        XCTAssertEqual(byModel["gemini-2.5-pro"]?.counts, TokenCounts(input: 610, cacheRead: 400, output: 200, reasoning: 50))
        XCTAssertEqual(byModel["gemini-2.5-pro"]?.eventCount, 3)
        // flash = 300/50 (2 calls) + 600/400/200 (1 call) + 100/20 (1 call)
        XCTAssertEqual(byModel["gemini-2.5-flash"]?.counts, TokenCounts(input: 1_000, cacheRead: 400, output: 270))
        XCTAssertEqual(byModel["gemini-2.5-flash"]?.eventCount, 4)

        XCTAssertEqual(batch.hourly.map(\.hourStart), [
            ISO8601DateFormatter().date(from: "2026-11-19T08:00:00Z")!,
            ISO8601DateFormatter().date(from: "2026-11-19T10:00:00Z")!,
            ISO8601DateFormatter().date(from: "2026-11-19T11:00:00Z")!,
        ])
    }

    func testCrossFileDeduplicationSuppressesSummariesAndKeepsLargestTurnCollision() async throws {
        // 1. Session with turns in sessionRoot suppresses summary-only copy in headless root.
        let sessionURL = defaultSessionRoot.appendingPathComponent("proj/chats/custom.json")
        try writeText(#"""
        {
          "sessionId": "sess-shared",
          "messages": [
            {
              "id": "turn-a",
              "type": "gemini",
              "timestamp": "2026-11-19T10:00:00Z",
              "model": "gemini-2.5-pro",
              "tokens": { "input": 400, "cached": 100, "output": 50 }
            }
          ]
        }
        """#, to: sessionURL)

        let headlessSummaryURL = defaultHeadlessRoot.appendingPathComponent("00-early-summary.json")
        try writeText(#"""
        {
          "session_id": "sess-shared",
          "result": {
            "stats": {
              "models": {
                "gemini-2.5-pro": {
                  "api": { "totalRequests": 1 },
                  "tokens": { "input": 400, "cached": 100, "output": 50 }
                }
              }
            }
          }
        }
        """#, to: headlessSummaryURL, modified: ISO8601DateFormatter().date(from: "2026-11-19T10:01:00Z")!)

        // 2. Duplicate ID-bearing turn across two files keeps the entry with the largest total tokens.
        let turnCopyURL = defaultSessionRoot.appendingPathComponent("proj/chats/session-copy.json")
        try writeText(#"""
        {
          "sessionId": "sess-shared",
          "messages": [
            {
              "id": "turn-a",
              "type": "gemini",
              "timestamp": "2026-11-19T10:00:00Z",
              "model": "gemini-2.5-pro",
              "tokens": { "input": 600, "cached": 100, "output": 80 }
            }
          ]
        }
        """#, to: turnCopyURL)

        // 3. Summary-only session appearing in two headless files deduplicates by sessionID.
        let summaryOnly1 = defaultHeadlessRoot.appendingPathComponent("sum-only-1.json")
        let summaryOnly2 = defaultHeadlessRoot.appendingPathComponent("sum-only-2.json")
        let summaryTime = ISO8601DateFormatter().date(from: "2026-11-19T11:00:00Z")!
        let summaryBody = #"""
        {
          "session_id": "sess-summary-only",
          "stats": {
            "models": {
              "gemini-2.5-flash": {
                "api": { "totalRequests": 2 },
                "tokens": { "input": 250, "output": 50 }
              }
            }
          }
        }
        """#
        try writeText(summaryBody, to: summaryOnly1, modified: summaryTime)
        try writeText(summaryBody, to: summaryOnly2, modified: summaryTime)

        let batch = try await collector().collect()
        let byModel = Dictionary(uniqueKeysWithValues: batch.daily.map { ($0.modelID, $0) })

        XCTAssertEqual(byModel["gemini-2.5-pro"]?.counts, TokenCounts(input: 500, cacheRead: 100, output: 80))
        XCTAssertEqual(byModel["gemini-2.5-pro"]?.eventCount, 1)
        XCTAssertEqual(byModel["gemini-2.5-flash"]?.counts, TokenCounts(input: 250, output: 50))
        XCTAssertEqual(byModel["gemini-2.5-flash"]?.eventCount, 2)
    }

    func testFileDiscoveryFilteringAndAntigravityIsolation() async throws {
        try writeText(#"""
        {"sessionId":"s1","messages":[{"id":"m1","type":"gemini","timestamp":"2026-11-19T09:00:00Z","model":"gemini-2.5-pro","tokens":{"input":100,"output":10}}]}
        """#, to: defaultSessionRoot.appendingPathComponent("session-root.json"))

        try writeText(#"""
        {"sessionId":"s2","messages":[{"id":"m2","type":"gemini","timestamp":"2026-11-19T09:05:00Z","model":"gemini-2.5-pro","tokens":{"input":200,"output":20}}]}
        """#, to: defaultSessionRoot.appendingPathComponent("proj-x/chats/arbitrary.json"))

        try writeLines([
            #"{"type":"gemini","id":"m3","session_id":"s3","timestamp":"2026-11-19T09:10:00Z","model":"gemini-2.5-pro","tokens":{"input":300,"output":30}}"#,
        ], to: defaultSessionRoot.appendingPathComponent("proj-x/nested/trace.jsonl"))

        // Rejected under sessionRoot: non-session JSON outside <proj>/chats/<file>.json
        try writeText(#"""
        {"sessionId":"s-ignored-1","messages":[{"id":"x1","type":"gemini","timestamp":"2026-11-19T09:15:00Z","model":"gemini-2.5-pro","tokens":{"input":9999,"output":999}}]}
        """#, to: defaultSessionRoot.appendingPathComponent("proj-x/logs.json"))

        try writeText(#"""
        {"sessionId":"s-ignored-2","messages":[{"id":"x2","type":"gemini","timestamp":"2026-11-19T09:20:00Z","model":"gemini-2.5-pro","tokens":{"input":9999,"output":999}}]}
        """#, to: defaultSessionRoot.appendingPathComponent("proj-x/chats/too-deep/session.json"))

        // Antigravity directories under ~/.gemini must never be touched
        try writeText(#"""
        {"sessionId":"s-ag","messages":[{"id":"ag1","type":"gemini","timestamp":"2026-11-19T09:25:00Z","model":"gemini-2.5-pro","tokens":{"input":50000,"output":5000}}]}
        """#, to: home.appendingPathComponent(".gemini/antigravity/conversations/session-ag.json"))

        let batch = try await collector().collect()
        XCTAssertEqual(batch.daily.count, 1)
        XCTAssertEqual(batch.daily.first?.counts, TokenCounts(input: 600, output: 60))
        XCTAssertEqual(batch.daily.first?.eventCount, 3)
    }

    func testValidationSkipsNegativeCountsInvalidAndFutureTimestamps() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-19T12:00:00Z")!
        let epochSec = Int64(ISO8601DateFormatter().date(from: "2026-11-19T10:00:00Z")!.timeIntervalSince1970)
        let epochMs = Int64(ISO8601DateFormatter().date(from: "2026-11-19T11:00:00Z")!.timeIntervalSince1970 * 1_000)

        let url = defaultSessionRoot.appendingPathComponent("proj/trace.jsonl")
        try writeLines([
            "{broken json",
            #"{"type":"gemini","id":"bad-neg","timestamp":"2026-11-19T10:00:00Z","model":"gemini-2.5-pro","tokens":{"input":-5,"output":10}}"#,
            #"{"type":"gemini","id":"bad-ts","timestamp":"not-a-timestamp","model":"gemini-2.5-pro","tokens":{"input":100,"output":10}}"#,
            #"{"type":"gemini","id":"future-ts","timestamp":"2026-11-21T00:00:00Z","model":"gemini-2.5-pro","tokens":{"input":100,"output":10}}"#,
            #"{"type":"gemini","id":"ok-sec","timestamp":\#(epochSec),"model":"gemini-2.5-pro","tokens":{"input":100,"output":20}}"#,
            #"{"type":"gemini","id":"ok-ms","timestamp":\#(epochMs),"model":"gemini-2.5-pro","tokens":{"input":50,"output":10}}"#,
        ], to: url)

        let batch = try await collector(now: now).collect()
        XCTAssertEqual(batch.skippedRecords, 4)
        XCTAssertEqual(batch.daily.count, 1)
        XCTAssertEqual(batch.daily.first?.counts, TokenCounts(input: 150, output: 30))
        XCTAssertEqual(batch.daily.first?.eventCount, 2)
    }

    func testSourceUnavailableEnvironmentOverridesAndIncrementalCaching() async throws {
        let missingHome = directory.appendingPathComponent("missing-home", isDirectory: true)
        do {
            _ = try await collector(home: missingHome).collect()
            XCTFail("Expected CollectorError.sourceUnavailable when no Gemini directories exist")
        } catch CollectorError.sourceUnavailable {
        }

        let customGeminiHome = directory.appendingPathComponent("custom-gemini", isDirectory: true)
        let customHeadlessDir = directory.appendingPathComponent("custom-headless", isDirectory: true)
        let sessionFile = customGeminiHome.appendingPathComponent("tmp/session-1.json")
        try writeText(#"""
        {"sessionId":"s-env","messages":[{"id":"e1","type":"gemini","timestamp":"2026-11-19T10:00:00Z","model":"gemini-2.5-pro","tokens":{"input":120,"output":30}}]}
        """#, to: sessionFile)

        let stateDir = directory.appendingPathComponent("collector-state", isDirectory: true)
        let env = [
            "GEMINI_CLI_HOME": customGeminiHome.path,
            "TOKSCALE_HEADLESS_DIR": customHeadlessDir.path,
        ]
        let subject = collector(home: missingHome, environment: env, stateDirectory: stateDir)

        let first = try await subject.collect()
        XCTAssertEqual(first.daily.first?.counts, TokenCounts(input: 120, output: 30))
        for commit in first.stateCommits { try commit() }

        let second = try await subject.collect()
        XCTAssertEqual(second.unchangedSourceIDs, ["gemini"])
        XCTAssertTrue(second.daily.isEmpty && second.hourly.isEmpty)

        // Adding a headless file under TOKSCALE_HEADLESS_DIR/gemini invalidates state.
        let headlessFile = customHeadlessDir.appendingPathComponent("gemini/h1.json")
        try writeText(#"""
        {
          "session_id": "s-headless-new",
          "stats": {
            "models": {
              "gemini-2.5-flash": {
                "api": { "totalRequests": 1 },
                "tokens": { "input": 80, "output": 20 }
              }
            }
          }
        }
        """#, to: headlessFile, modified: ISO8601DateFormatter().date(from: "2026-11-19T11:00:00Z")!)

        let third = try await subject.collect()
        XCTAssertTrue(third.unchangedSourceIDs.isEmpty)
        XCTAssertEqual(third.daily.count, 2)
    }

    func testLocalDayAttributionAcrossMidnightAndCurrentHourCap() async throws {
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        let now = ISO8601DateFormatter().date(from: "2026-11-19T16:30:00Z")!
        try writeText(#"""
        {
          "sessionId": "s-tz",
          "messages": [
            {
              "id": "tz1",
              "type": "gemini",
              "timestamp": "2026-11-19T15:30:00Z",
              "model": "gemini-2.5-pro",
              "tokens": { "input": 100, "output": 10 }
            },
            {
              "id": "tz2",
              "type": "gemini",
              "timestamp": "2026-11-19T16:15:00Z",
              "model": "gemini-2.5-pro",
              "tokens": { "input": 200, "output": 20 }
            },
            {
              "id": "tz3",
              "type": "gemini",
              "timestamp": "2026-11-19T17:15:00Z",
              "model": "gemini-2.5-pro",
              "tokens": { "input": 300, "output": 30 }
            }
          ]
        }
        """#, to: defaultSessionRoot.appendingPathComponent("session-tz.json"))

        let batch = try await collector(timeZone: shanghai, now: now).collect()
        XCTAssertEqual(batch.daily.map(\.day), ["2026-11-19", "2026-11-20"])
        XCTAssertEqual(batch.daily[0].counts, TokenCounts(input: 100, output: 10))
        XCTAssertEqual(batch.daily[1].counts, TokenCounts(input: 500, output: 50))
        XCTAssertEqual(batch.hourly.map(\.hourStart), [
            ISO8601DateFormatter().date(from: "2026-11-19T15:00:00Z")!,
            ISO8601DateFormatter().date(from: "2026-11-19T16:00:00Z")!,
        ])
        XCTAssertTrue(batch.hourly.allSatisfy(\.reasoningKnown))
    }
}
