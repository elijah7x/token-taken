import XCTest
@testable import TokenTakenKit

final class UsageAggregatorTests: XCTestCase {
    private let store = SyntheticUsageStore()

    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func aggregator(_ zone: String) -> UsageAggregator {
        UsageAggregator(store: store, calendar: calendar(zone), now: SyntheticUsageStore.defaultToday)
    }

    private func sum(_ groups: [Breakdown]) -> TokenCounts {
        groups.reduce(.zero) { $0 + $1.counts }
    }

    func testBreakdownsSumToTotalForEveryPeriod() throws {
        for zone in ["UTC", "Asia/Shanghai", "America/Los_Angeles"] {
            for period in Period.allCases {
                let summary = try aggregator(zone).summary(for: period)
                XCTAssertGreaterThan(summary.total.total, 0, "\(zone) \(period)")
                XCTAssertEqual(sum(summary.bySource), summary.total, "\(zone) \(period) bySource")
                XCTAssertEqual(sum(summary.byModel), summary.total, "\(zone) \(period) byModel")
                XCTAssertEqual(sum(summary.byDevice), summary.total, "\(zone) \(period) byDevice")
            }
        }
    }

    func testSeriesSumsToPeriodTotal() throws {
        for zone in ["UTC", "Asia/Shanghai"] {
            for period in Period.allCases where period != .day {
                let summary = try aggregator(zone).summary(for: period)
                let seriesTotal = summary.series.reduce(Int64(0)) { $0 + $1.total }
                XCTAssertEqual(seriesTotal, summary.total.total, "\(zone) \(period)")
                for point in summary.series {
                    XCTAssertEqual(point.bySource.values.reduce(0, +), point.total, "\(zone) \(period) point \(point.id)")
                    if point.isFuture { XCTAssertEqual(point.total, 0) }
                }
            }
        }
    }

    func testSeriesShapes() throws {
        let aggregator = aggregator("UTC")
        XCTAssertEqual(try aggregator.summary(for: .day).series.count, 24)
        XCTAssertEqual(try aggregator.summary(for: .month).series.count, 30)
        XCTAssertEqual(try aggregator.summary(for: .year).series.map(\.label), (1...12).map(String.init))
        XCTAssertEqual(try aggregator.dailyTotals(lastDays: 7).count, 7)
    }

    func testBreakdownsAreSortedDescending() throws {
        let summary = try aggregator("UTC").summary(for: .all)
        for groups in [summary.bySource, summary.byModel, summary.byDevice] {
            XCTAssertEqual(groups.map(\.counts.total), groups.map(\.counts.total).sorted(by: >))
        }
    }

    func testTotalIsCategorySum() throws {
        let counts = TokenCounts(input: 1, cacheRead: 20, cacheWrite: 300, output: 4_000, reasoning: 50_000)
        XCTAssertEqual(counts.total, TokenCategory.allCases.reduce(Int64(0)) { $0 + counts[$1] })
        XCTAssertEqual(counts.total, 54_321)
        for record in store.records() {
            XCTAssertEqual(record.counts.total, TokenCategory.allCases.reduce(Int64(0)) { $0 + record.counts[$1] })
        }
    }

    func testSameSeedGivesIdenticalData() throws {
        XCTAssertEqual(SyntheticUsageStore(seed: 7).records(), SyntheticUsageStore(seed: 7).records())
        XCTAssertEqual(SyntheticUsageStore().records(), store.records())
        XCTAssertNotEqual(SyntheticUsageStore(seed: 7).records(), SyntheticUsageStore(seed: 8).records())
    }

    func testKimiTokensAreUnpriced() throws {
        let summary = try aggregator("UTC").summary(for: .all)
        let kimi = summary.byModel.first { $0.id == "kimi-k3.1-pro" }
        XCTAssertNotNil(kimi)
        XCTAssertGreaterThan(summary.cost.unpricedTokens, 0)
        XCTAssertEqual(summary.cost.unpricedTokens, kimi?.counts.total)
        XCTAssertGreaterThan(summary.cost.estimatedUSD, 0)
        XCTAssertEqual(summary.cost.priceTableVersion, "synthetic-2026-11")
    }

    func testLocalDayLabelAndIntervalDoNotUseUTC() throws {
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        let instant = ISO8601DateFormatter().date(from: "2026-11-08T20:00:00Z")!
        XCTAssertEqual(UsageDay.string(from: instant, in: zone), "2026-11-09")
        XCTAssertEqual(UsageDay.string(from: instant, in: TimeZone(identifier: "UTC")!), "2026-11-08")
        let record = UsageRecord(day: "2026-11-09", timeZoneID: zone.identifier, deviceID: "test", sourceID: "claude",
            modelID: "fixture", counts: TokenCounts(input: 100))
        XCTAssertEqual(record.dayInterval?.start, ISO8601DateFormatter().date(from: "2026-11-08T16:00:00Z"))
        let store = GranularityStore(daily: [record])
        for viewerZone in ["UTC", "Asia/Shanghai", "America/Los_Angeles"] {
            let viewer = calendar(viewerZone)
            let now = UsageDay.date(from: "2026-11-09", in: viewer.timeZone)!.addingTimeInterval(12 * 3_600)
            let summary = try UsageAggregator(store: store, calendar: viewer, now: now).summary(for: .day)
            XCTAssertEqual(summary.total.input, 100, viewerZone)
        }
    }

    func testDSTDayUses23RealHourlyBucketsAndPreservesReasoningDifference() throws {
        let viewer = calendar("America/New_York")
        let now = ISO8601DateFormatter().date(from: "2026-03-09T03:30:00Z")!
        let bundle = Bundle(for: UsageAggregatorTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "tokscale-hourly", withExtension: "json"))
        let hourly = try TokscaleCollector.parseHourly(data: Data(contentsOf: url), client: "claude", deviceID: "test",
            timeZone: viewer.timeZone, now: now)
        let record = UsageRecord(day: "2026-03-08", timeZoneID: viewer.timeZone.identifier, deviceID: "test", sourceID: "claude",
            modelID: "fixture", counts: TokenCounts(input: 1_000, cacheRead: 300, cacheWrite: 100, output: 200, reasoning: 100))
        XCTAssertEqual(record.dayInterval?.duration, 23 * 3_600)
        let summary = try UsageAggregator(store: GranularityStore(daily: [record], hours: hourly), calendar: viewer, now: now).summary(for: .day)
        XCTAssertEqual(summary.series.count, 23)
        XCTAssertFalse(summary.series.map(\.label).contains("2"))
        XCTAssertEqual(summary.series.first?.start, ISO8601DateFormatter().date(from: "2026-03-08T05:00:00Z"))
        XCTAssertEqual(summary.series.reduce(Int64(0)) { $0 + $1.total }, 1_600)
        XCTAssertEqual(summary.total.total, 1_700)
        XCTAssertEqual(summary.series.first?.total, 160)
        XCTAssertEqual(summary.series.filter(\.isKnown).count, 4)
        XCTAssertTrue(summary.series.filter { !$0.isKnown }.allSatisfy { $0.bySource.isEmpty })
    }

    func testHourlyRowsAreConvertedToViewerHoursWithoutSpreadingDailyTotals() throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-09T09:30:00Z")!
        let row = HourlyUsage(hourStart: now.addingTimeInterval(-1_800), deviceID: "test", sourceID: "claude",
            counts: TokenCounts(input: 9), eventCount: 1, reasoningKnown: false)
        let daily = UsageRecord(day: "2026-11-09", timeZoneID: "Asia/Shanghai", deviceID: "test", sourceID: "claude",
            modelID: "fixture", counts: TokenCounts(input: 99))
        let summary = try UsageAggregator(store: GranularityStore(daily: [daily], hours: [row]), calendar: calendar("Asia/Shanghai"), now: now).summary(for: .day)
        XCTAssertEqual(summary.total.total, 99)
        XCTAssertEqual(summary.series.filter { $0.total > 0 }.map(\.label), ["17"])
        XCTAssertEqual(summary.series.reduce(Int64(0)) { $0 + $1.total }, 9)
        XCTAssertEqual(summary.series.filter(\.isKnown).count, 1)
    }

    func testUncategorizedAddsToTotalButNotCategoriesOrPrice() throws {
        let counts = TokenCounts(input: 1_000_000, uncategorized: 42)
        XCTAssertEqual(counts.total, 1_000_042)
        XCTAssertEqual((counts + TokenCounts(uncategorized: 8)).uncategorized, 50)
        XCTAssertEqual(TokenCategory.allCases.count, 5)
        let legacy = Data(#"{"input":1,"cacheRead":2,"cacheWrite":3,"output":4,"reasoning":5}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(TokenCounts.self, from: legacy).uncategorized, 0)
        XCTAssertEqual(try JSONDecoder().decode(TokenCounts.self, from: JSONEncoder().encode(counts)), counts)
        let daily = UsageRecord(day: "2026-11-09", timeZoneID: "UTC", deviceID: "test", sourceID: "codex", modelID: "fixture", counts: counts)
        let price = PriceTable(version: "fixture", rates: ["fixture": .init(input: 2, cacheRead: 0, cacheWrite: 0, output: 3)])
        let summary = try UsageAggregator(store: GranularityStore(daily: [daily]), calendar: calendar("UTC"), now: SyntheticUsageStore.defaultToday, priceTable: price).summary(for: .day)
        XCTAssertEqual(summary.cost.estimatedUSD, 2)
        XCTAssertEqual(summary.cost.unpricedTokens, 42)
    }

    func testTokenFormat() throws {
        XCTAssertEqual(TokenFormat.short(1_240_000_000), "1.24B")
        XCTAssertEqual(TokenFormat.short(58_300_000), "58.3M")
        XCTAssertEqual(TokenFormat.short(412_500), "412.5K")
        XCTAssertEqual(TokenFormat.short(980), "980")
        XCTAssertEqual(TokenFormat.short(999_960), "1.0M")
        XCTAssertEqual(TokenFormat.usd(132.26), "$132.26")
    }
}

private struct GranularityStore: UsageStore {
    let devices: [Device] = []
    var daily: [UsageRecord]
    var hours: [HourlyUsage] = []
    func records() -> [UsageRecord] { daily }
    func hourly() -> [HourlyUsage] { hours }
}
