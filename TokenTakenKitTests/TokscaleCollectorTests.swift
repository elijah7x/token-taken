import XCTest
@testable import TokenTakenKit

private final class TokscaleFixtureBundleToken {}

final class TokscaleCollectorTests: XCTestCase {
    func testParsesFixtureMapsSourcesAndAggregates() throws {
        let bundle = Bundle(for: TokscaleFixtureBundleToken.self)
        let url = try XCTUnwrap(bundle.url(forResource: "tokscale-graph", withExtension: "json"))
        let records = try TokscaleCollector.parse(data: Data(contentsOf: url), clients: ["claude", "droid", "zcode"],
            deviceID: "device-a", timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        XCTAssertEqual(records.count, 4)
        XCTAssertFalse(records.contains { $0.sourceID == "zcode" })
        XCTAssertTrue(records.allSatisfy { $0.deviceID == "device-a" && $0.timeZoneID == "Asia/Shanghai" })
        XCTAssertEqual(records.map(\.sourceID), ["claude", "factory", "claude", "factory"])
        let firstClaude = records[0]
        XCTAssertEqual(firstClaude.day, "2026-11-08")
        XCTAssertEqual(firstClaude.dayInterval?.start, ISO8601DateFormatter().date(from: "2026-11-07T16:00:00Z"))
        XCTAssertEqual(firstClaude.modelID, "claude-sonnet")
        XCTAssertEqual(firstClaude.rawModelID, "claude-sonnet")
        XCTAssertEqual(firstClaude.counts, TokenCounts(input: 107, cacheRead: 22, cacheWrite: 11, output: 53, reasoning: 6))
        XCTAssertEqual(records[1].day, "2026-11-08")
        XCTAssertEqual(records[1].modelID, "droid-large")
        XCTAssertEqual(records[1].counts, TokenCounts(input: 200, cacheRead: 30, cacheWrite: 20, output: 80, reasoning: 10))
        XCTAssertEqual(records[2].day, "2026-11-09")
        XCTAssertEqual(records[2].counts, TokenCounts(input: 300, cacheRead: 50, cacheWrite: 25, output: 100, reasoning: 20))
        XCTAssertEqual(records[3].day, "2026-11-09")
        XCTAssertEqual(records[3].counts, TokenCounts(input: 400, cacheRead: 60, cacheWrite: 30, output: 150, reasoning: 15))
    }

    func testGraphRetainsRawModelAndEventCount() throws {
        let data = Data(#"{"contributions":[{"date":"2026-11-09","clients":[{"client":"claude","modelId":"Fixture-Model","messages":3,"tokens":{"input":1,"output":2,"cacheRead":3,"cacheWrite":4,"reasoning":5}}]}]}"#.utf8)
        let records = try TokscaleCollector.parse(data: data, clients: ["claude"], deviceID: "test")
        XCTAssertEqual(records.first?.rawModelID, "Fixture-Model")
        XCTAssertEqual(records.first?.modelID, "fixture-model")
        XCTAssertEqual(records.first?.eventCount, 3)
    }

    func testHourlyFixtureUsesLocalZoneAndDoesNotInventReasoningOrModels() throws {
        let bundle = Bundle(for: TokscaleFixtureBundleToken.self)
        let url = try XCTUnwrap(bundle.url(forResource: "tokscale-hourly", withExtension: "json"))
        let now = ISO8601DateFormatter().date(from: "2026-03-09T03:30:00Z")!
        let rows = try TokscaleCollector.parseHourly(data: Data(contentsOf: url), client: "droid", deviceID: "test",
            timeZone: TimeZone(identifier: "America/New_York")!, now: now)
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.allSatisfy { $0.sourceID == "factory" && $0.deviceID == "test" && !$0.reasoningKnown })
        XCTAssertTrue(rows.allSatisfy { $0.counts.reasoning == 0 })
        XCTAssertEqual(rows[0].hourStart, ISO8601DateFormatter().date(from: "2026-03-08T05:00:00Z"))
        XCTAssertEqual(rows[1].hourStart, ISO8601DateFormatter().date(from: "2026-03-08T06:00:00Z"))
        XCTAssertEqual(rows[2].hourStart, ISO8601DateFormatter().date(from: "2026-03-08T07:00:00Z"))
        XCTAssertEqual(rows.reduce(Int64(0)) { $0 + $1.eventCount }, 14)
        XCTAssertEqual(rows.reduce(Int64(0)) { $0 + $1.counts.total }, 1_600)
        let later = now.addingTimeInterval(72 * 3_600)
        XCTAssertTrue(try TokscaleCollector.parseHourly(data: Data(contentsOf: url), client: "claude", deviceID: "test",
            timeZone: TimeZone(identifier: "America/New_York")!, now: later).isEmpty)
    }

    func testRejectsNonexistentDSTHour() throws {
        let data = Data(#"{"entries":[{"hour":"2026-03-08 02:00","input":1,"output":0,"cacheRead":0,"cacheWrite":0,"messageCount":1}]}"#.utf8)
        XCTAssertThrowsError(try TokscaleCollector.parseHourly(data: data, client: "claude", deviceID: "test",
            timeZone: TimeZone(identifier: "America/New_York")!))
    }

    func testSourceIDsExcludeNativeCollectorsAndMapDroid() {
        let collector = TokscaleCollector(executableURL: URL(fileURLWithPath: "/unused"),
            configDirectory: URL(fileURLWithPath: "/unused"), clients: ["claude", "droid", "zcode", "pi", "omp"], deviceID: "test")
        XCTAssertEqual(collector.sourceIDs, ["claude", "factory"])
        XCTAssertFalse(TokscaleCollector.defaultClients.contains("pi"))
        XCTAssertFalse(TokscaleCollector.defaultClients.contains("omp"))
    }

    func testSubprocessErrorsDoNotIncludeStderrOrPaths() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let scriptURL = dir.appendingPathComponent("mock-tokscale.sh")
        let script = """
            #!/bin/sh
            echo "fatal error in /Users/secret/project/session.jsonl: private prompt text" >&2
            exit 7
            """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let collector = TokscaleCollector(
            executableURL: scriptURL,
            configDirectory: dir.appendingPathComponent("config", isDirectory: true),
            clients: ["claude"],
            deviceID: "device-a",
            isClientAvailable: { _ in true }
        )
        do {
            _ = try await collector.collect()
            XCTFail("Expected process failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "tokscale exited with status 7")
            XCTAssertFalse(error.localizedDescription.contains("/Users/"))
            XCTAssertFalse(error.localizedDescription.contains("private"))
        }
    }

    func testSingleCollectorRunsOneGraphAndReportsUnavailableClients() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let invocationsURL = dir.appendingPathComponent("invocations.log")
        let scriptURL = dir.appendingPathComponent("mock-tokscale-multi.sh")
        let script = """
            #!/bin/sh
            echo "$*" >> "\(invocationsURL.path)"
            if [ "$1" = "graph" ]; then
              out=""
              while [ $# -gt 0 ]; do
                if [ "$1" = "--output" ]; then
                  shift
                  out="$1"
                fi
                shift
              done
              printf '%s' '{"contributions":[{"date":"2026-11-09","clients":[{"client":"claude","modelId":"claude-sonnet-4-5","messages":2,"tokens":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"reasoning":0}}]}]}' > "$out"
            else
              printf '%s' '{"entries":[]}'
            fi
            """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let availability = AvailabilityProbe(available: ["claude", "codex"])
        let collector = TokscaleCollector(
            executableURL: scriptURL,
            configDirectory: dir.appendingPathComponent("config", isDirectory: true),
            clients: ["claude", "codex", "kimi"],
            deviceID: "device-a",
            isClientAvailable: { availability.isAvailable($0) }
        )
        let batch = try await collector.collect()
        XCTAssertEqual(batch.unavailableSourceIDs, ["kimi"])
        XCTAssertEqual(batch.daily.map(\.sourceID), ["claude"])
        for client in ["claude", "codex", "kimi"] {
            XCTAssertEqual(availability.count(for: client), 1)
        }

        let log = try String(contentsOf: invocationsURL, encoding: .utf8)
        let lines = log.split(separator: "\n").map(String.init)
        let graphLines = lines.filter { $0.hasPrefix("graph ") }
        let hourlyLines = lines.filter { $0.hasPrefix("hourly ") }
        XCTAssertEqual(graphLines.count, 1)
        XCTAssertTrue(graphLines.first?.contains("-c claude,codex") == true)
        XCTAssertEqual(hourlyLines.count, 2)
    }

    func testHourlyFailureIsLimitedToOneClientAndPreservesItsCache() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let scriptURL = dir.appendingPathComponent("mock-tokscale-hourly-failure.sh")
        let script = """
            #!/bin/sh
            if [ "$1" = "graph" ]; then
              out=""
              while [ $# -gt 0 ]; do
                if [ "$1" = "--output" ]; then
                  shift
                  out="$1"
                fi
                shift
              done
              printf '%s' '{"contributions":[{"date":"2026-11-09","clients":[{"client":"claude","modelId":"claude-sonnet","messages":1,"tokens":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"reasoning":0}},{"client":"codex","modelId":"gpt-5","messages":1,"tokens":{"input":20,"output":6,"cacheRead":0,"cacheWrite":0,"reasoning":0}}]}]}' > "$out"
            elif [ "$1" = "hourly" ] && [ "$4" = "codex" ]; then
              exit 7
            else
              printf '%s' '{"entries":[]}'
            fi
            """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let now = ISO8601DateFormatter().date(from: "2026-11-09T10:30:00Z")!
        let device = Device(id: "device-a", name: "Test Mac")
        let store = try SQLiteUsageStore(url: dir.appendingPathComponent("usage.sqlite"))
        let cachedDaily = UsageRecord(
            day: "2026-11-08", timeZoneID: "UTC", deviceID: device.id, sourceID: "codex",
            modelID: "cached", counts: TokenCounts(input: 1)
        )
        let cachedHourly = HourlyUsage(
            hourStart: now.addingTimeInterval(-1_800), deviceID: device.id, sourceID: "codex",
            counts: TokenCounts(input: 2), eventCount: 1, reasoningKnown: false
        )
        try store.replace(
            batch: CollectionBatch(daily: [cachedDaily], hourly: [cachedHourly]),
            sourceID: "codex", deviceID: device.id
        )
        let lastSuccess = now.addingTimeInterval(-60)
        try store.record(health: SourceHealth(sourceID: "codex", lastSuccess: lastSuccess, recordCount: 1))

        let collector = TokscaleCollector(
            executableURL: scriptURL,
            configDirectory: dir.appendingPathComponent("config", isDirectory: true),
            clients: ["claude", "codex"],
            deviceID: device.id,
            isClientAvailable: { _ in true }
        )
        let results = await CollectionRunner(store: store, device: device, collectors: [collector]).runAll(now: now)
        let bySource = Dictionary(uniqueKeysWithValues: results.map { ($0.sourceID, $0) })
        XCTAssertEqual(bySource["claude"]?.state, .ok)
        XCTAssertEqual(bySource["codex"]?.state, .failed)
        XCTAssertEqual(bySource["codex"]?.lastSuccess, lastSuccess)
        XCTAssertEqual(bySource["codex"]?.errorMessage, "tokscale exited with status 7")
        XCTAssertEqual(try store.records().filter { $0.sourceID == "codex" }, [cachedDaily])
        XCTAssertEqual(try store.hourly().filter { $0.sourceID == "codex" }, [cachedHourly])
        XCTAssertEqual(try store.records().first { $0.sourceID == "claude" }?.modelID, "claude-sonnet")
    }

    func testSourceWithoutOutcomeKeepsItsCache() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = ISO8601DateFormatter().date(from: "2026-11-09T10:30:00Z")!
        let device = Device(id: "device-a", name: "Test Mac")
        let store = try SQLiteUsageStore(url: dir.appendingPathComponent("usage.sqlite"))
        let cachedDaily = UsageRecord(
            day: "2026-11-08", timeZoneID: "UTC", deviceID: device.id, sourceID: "codex",
            modelID: "cached", counts: TokenCounts(input: 1)
        )
        let cachedHourly = HourlyUsage(
            hourStart: now.addingTimeInterval(-1_800), deviceID: device.id, sourceID: "codex",
            counts: TokenCounts(input: 2), eventCount: 1, reasoningKnown: false
        )
        try store.replace(
            batch: CollectionBatch(daily: [cachedDaily], hourly: [cachedHourly]),
            sourceID: "codex", deviceID: device.id
        )
        let fresh = UsageRecord(
            day: "2026-11-09", timeZoneID: "UTC", deviceID: device.id, sourceID: "claude",
            modelID: "fresh", counts: TokenCounts(input: 3)
        )
        let collector = BatchCollector(
            sourceIDs: ["claude", "codex"],
            batch: CollectionBatch(daily: [fresh])
        )
        let results = await CollectionRunner(store: store, device: device, collectors: [collector]).runAll(now: now)
        XCTAssertEqual(results.first { $0.sourceID == "codex" }?.state, .failed)
        XCTAssertEqual(try store.records().filter { $0.sourceID == "codex" }, [cachedDaily])
        XCTAssertEqual(try store.hourly().filter { $0.sourceID == "codex" }, [cachedHourly])
        XCTAssertEqual(try store.records().filter { $0.sourceID == "claude" }, [fresh])
    }
}

private final class AvailabilityProbe: @unchecked Sendable {
    private let available: Set<String>
    private var counts: [String: Int] = [:]
    private let lock = NSLock()

    init(available: Set<String>) {
        self.available = available
    }

    func isAvailable(_ client: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        counts[client, default: 0] += 1
        return available.contains(client)
    }

    func count(for client: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[client, default: 0]
    }
}

private struct BatchCollector: UsageCollector {
    let sourceIDs: [String]
    let batch: CollectionBatch

    func collect() async throws -> CollectionBatch { batch }
}
