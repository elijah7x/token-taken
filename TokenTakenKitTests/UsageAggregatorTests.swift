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
            for period in Period.allCases {
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

    func testTokenFormat() throws {
        XCTAssertEqual(TokenFormat.short(1_240_000_000), "1.24B")
        XCTAssertEqual(TokenFormat.short(58_300_000), "58.3M")
        XCTAssertEqual(TokenFormat.short(412_500), "412.5K")
        XCTAssertEqual(TokenFormat.short(980), "980")
        XCTAssertEqual(TokenFormat.short(999_960), "1.0M")
        XCTAssertEqual(TokenFormat.usd(132.26), "$132.26")
    }
}
