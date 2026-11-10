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
}
