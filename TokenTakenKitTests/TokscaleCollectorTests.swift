import XCTest
@testable import TokenTakenKit

private final class TokscaleFixtureBundleToken {}

final class TokscaleCollectorTests: XCTestCase {
    private func day(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: "\(value)T00:00:00Z")!
    }

    func testParsesFixtureMapsSourcesAndAggregates() throws {
        let bundle = Bundle(for: TokscaleFixtureBundleToken.self)
        let url = try XCTUnwrap(bundle.url(forResource: "tokscale-graph", withExtension: "json"))
        let records = try TokscaleCollector.parse(
            data: Data(contentsOf: url),
            clients: ["claude", "droid", "zcode"],
            deviceID: "device-a"
        )

        XCTAssertEqual(records.count, 4)
        XCTAssertFalse(records.contains { $0.sourceID == "zcode" })
        XCTAssertTrue(records.allSatisfy { $0.deviceID == "device-a" })
        XCTAssertEqual(records.map(\.sourceID), ["claude", "factory", "claude", "factory"])

        let firstClaude = records[0]
        XCTAssertEqual(firstClaude.day, day("2026-11-08"))
        XCTAssertEqual(firstClaude.modelID, "claude-sonnet")
        XCTAssertEqual(firstClaude.counts, TokenCounts(input: 107, cacheRead: 22, cacheWrite: 11, output: 53, reasoning: 6))

        let firstFactory = records[1]
        XCTAssertEqual(firstFactory.day, day("2026-11-08"))
        XCTAssertEqual(firstFactory.modelID, "droid-large")
        XCTAssertEqual(firstFactory.counts, TokenCounts(input: 200, cacheRead: 30, cacheWrite: 20, output: 80, reasoning: 10))

        XCTAssertEqual(records[2].day, day("2026-11-09"))
        XCTAssertEqual(records[2].counts, TokenCounts(input: 300, cacheRead: 50, cacheWrite: 25, output: 100, reasoning: 20))
        XCTAssertEqual(records[3].day, day("2026-11-09"))
        XCTAssertEqual(records[3].counts, TokenCounts(input: 400, cacheRead: 60, cacheWrite: 30, output: 150, reasoning: 15))
    }

    func testSourceIDsExcludeZcodeAndMapDroid() {
        let collector = TokscaleCollector(
            executableURL: URL(fileURLWithPath: "/unused"),
            configDirectory: URL(fileURLWithPath: "/unused"),
            clients: ["claude", "droid", "zcode"],
            deviceID: "device-a"
        )
        XCTAssertEqual(collector.sourceIDs, ["claude", "factory"])
    }
}
