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

    func testPreloadedRowsGiveTheSameSummariesAsReadingTheStore() throws {
        for zone in ["UTC", "Asia/Shanghai", "America/Los_Angeles"] {
            let plain = aggregator(zone)
            let rows = try UsageAggregator.preload(store)
            let preloaded = UsageAggregator(store: store, rows: rows, calendar: calendar(zone),
                now: SyntheticUsageStore.defaultToday)
            for period in Period.allCases {
                assertSame(try preloaded.summary(for: period), try plain.summary(for: period), "\(zone) \(period)")
            }
            XCTAssertEqual(try preloaded.dailyTotals(lastDays: 7), try plain.dailyTotals(lastDays: 7), zone)
        }
    }

    func testPreloadedRowsAreReadOnceForSeveralSummaries() throws {
        let counting = CountingUsageStore(devices: store.devices, daily: store.records(), hours: try store.hourly())
        let aggregator = UsageAggregator(store: counting, rows: try UsageAggregator.preload(counting),
            calendar: calendar("UTC"), now: SyntheticUsageStore.defaultToday)
        XCTAssertEqual(try aggregator.summary(for: .month).total.total, try self.aggregator("UTC").summary(for: .month).total.total)
        _ = try aggregator.summary(for: .day)
        _ = try aggregator.dailyTotals(lastDays: 7)
        XCTAssertEqual(counting.recordReads, 1)
        XCTAssertEqual(counting.hourReads, 1)
    }

    private func assertSame(_ lhs: UsageSummary, _ rhs: UsageSummary, _ message: String) {
        XCTAssertEqual(lhs.period, rhs.period, message)
        XCTAssertEqual(lhs.start, rhs.start, message)
        XCTAssertEqual(lhs.end, rhs.end, message)
        XCTAssertEqual(lhs.total, rhs.total, message)
        XCTAssertEqual(lhs.bySource, rhs.bySource, message)
        XCTAssertEqual(lhs.byModel, rhs.byModel, message)
        XCTAssertEqual(lhs.byDevice, rhs.byDevice, message)
        XCTAssertEqual(lhs.series, rhs.series, message)
        XCTAssertEqual(lhs.cost, rhs.cost, message)
        XCTAssertEqual(lhs.devices, rhs.devices, message)
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
        XCTAssertEqual(try aggregator.summary(for: .week).series.count, 7)
        XCTAssertEqual(try aggregator.summary(for: .month).series.count, 30)
        XCTAssertEqual(try aggregator.summary(for: .year).series.map(\.label), (1...12).map(String.init))
        XCTAssertEqual(try aggregator.dailyTotals(lastDays: 7).count, 7)
    }

    func testWeekStartsOnMondayAndBuildsSevenDailyBuckets() throws {
        var viewer = calendar("Asia/Shanghai")
        viewer.locale = Locale(identifier: "en_US_POSIX")
        viewer.firstWeekday = 1 // Sunday-first calendar must still use Monday week start.

        let store = GranularityStore(daily: [
            UsageRecord(day: "2026-11-01", timeZoneID: viewer.timeZone.identifier, deviceID: "test", sourceID: "claude",
                modelID: "fixture", counts: TokenCounts(input: 5)),
            UsageRecord(day: "2026-11-02", timeZoneID: viewer.timeZone.identifier, deviceID: "test", sourceID: "claude",
                modelID: "fixture", counts: TokenCounts(input: 10)),
            UsageRecord(day: "2026-11-08", timeZoneID: viewer.timeZone.identifier, deviceID: "test", sourceID: "claude",
                modelID: "fixture", counts: TokenCounts(input: 20)),
            UsageRecord(day: "2026-11-09", timeZoneID: viewer.timeZone.identifier, deviceID: "test", sourceID: "claude",
                modelID: "fixture", counts: TokenCounts(input: 30)),
            UsageRecord(day: "2026-11-11", timeZoneID: viewer.timeZone.identifier, deviceID: "test", sourceID: "claude",
                modelID: "fixture", counts: TokenCounts(input: 40)),
        ])

        // Monday 2026-11-09: week starts that day; Tue..Sun are future.
        let mondayNow = UsageDay.date(from: "2026-11-09", in: viewer.timeZone)!.addingTimeInterval(12 * 3_600)
        let onMonday = try UsageAggregator(store: store, calendar: viewer, now: mondayNow).summary(for: .week)
        XCTAssertEqual(UsageDay.string(from: onMonday.start, in: viewer.timeZone), "2026-11-09")
        XCTAssertEqual(UsageDay.string(from: onMonday.end, in: viewer.timeZone), "2026-11-10")
        XCTAssertEqual(onMonday.total.total, 30)
        XCTAssertEqual(onMonday.series.map(\.label), ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
        XCTAssertEqual(onMonday.series.map(\.isFuture), [false, true, true, true, true, true, true])
        XCTAssertEqual(onMonday.series.map(\.total), [30, 0, 0, 0, 0, 0, 0])

        // Sunday 2026-11-08: week starts on the previous Monday (6 days earlier, 2026-11-02).
        let sundayNow = UsageDay.date(from: "2026-11-08", in: viewer.timeZone)!.addingTimeInterval(18 * 3_600)
        let onSunday = try UsageAggregator(store: store, calendar: viewer, now: sundayNow).summary(for: .week)
        XCTAssertEqual(UsageDay.string(from: onSunday.start, in: viewer.timeZone), "2026-11-02")
        XCTAssertEqual(UsageDay.string(from: onSunday.end, in: viewer.timeZone), "2026-11-09")
        XCTAssertEqual(viewer.dateComponents([.day], from: onSunday.start, to: viewer.startOfDay(for: sundayNow)).day, 6)
        XCTAssertEqual(onSunday.total.total, 30)
        XCTAssertEqual(onSunday.series.map(\.isFuture), [false, false, false, false, false, false, false])
        XCTAssertEqual(onSunday.series.map(\.total), [10, 0, 0, 0, 0, 0, 20])
    }

    func testWeekAcrossMonthBoundary() throws {
        var viewer = calendar("Asia/Shanghai")
        viewer.locale = Locale(identifier: "en_US_POSIX")
        viewer.firstWeekday = 1

        let store = GranularityStore(daily: [
            UsageRecord(day: "2026-11-29", timeZoneID: viewer.timeZone.identifier, deviceID: "test", sourceID: "claude",
                modelID: "fixture", counts: TokenCounts(input: 7)),
            UsageRecord(day: "2026-11-30", timeZoneID: viewer.timeZone.identifier, deviceID: "test", sourceID: "claude",
                modelID: "fixture", counts: TokenCounts(input: 100)),
            UsageRecord(day: "2026-12-01", timeZoneID: viewer.timeZone.identifier, deviceID: "test", sourceID: "claude",
                modelID: "fixture", counts: TokenCounts(input: 200)),
            UsageRecord(day: "2026-12-02", timeZoneID: viewer.timeZone.identifier, deviceID: "test", sourceID: "claude",
                modelID: "fixture", counts: TokenCounts(input: 300)),
        ])

        // Wednesday 2026-12-02: week starts on Monday 2026-11-30 across the Nov/Dec boundary.
        let wednesdayNow = UsageDay.date(from: "2026-12-02", in: viewer.timeZone)!.addingTimeInterval(10 * 3_600)
        let summary = try UsageAggregator(store: store, calendar: viewer, now: wednesdayNow).summary(for: .week)
        XCTAssertEqual(UsageDay.string(from: summary.start, in: viewer.timeZone), "2026-11-30")
        XCTAssertEqual(UsageDay.string(from: summary.end, in: viewer.timeZone), "2026-12-03")
        XCTAssertEqual(summary.total.total, 600)
        XCTAssertEqual(summary.series.map(\.label), ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
        XCTAssertEqual(summary.series.map(\.total), [100, 200, 300, 0, 0, 0, 0])
        XCTAssertEqual(summary.series.map(\.isFuture), [false, false, false, true, true, true, true])
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

    func testPartialCategoryPricingPreservesPricedEstimate() throws {
        let counts = TokenCounts(input: 1_000_000, cacheWrite: 500, output: 2_000_000)
        let daily = UsageRecord(day: "2026-11-09", timeZoneID: "UTC", deviceID: "test", sourceID: "gemini",
            modelID: "gemini-3.7-flash", counts: counts)
        let summary = try UsageAggregator(store: GranularityStore(daily: [daily]), calendar: calendar("UTC"),
            now: SyntheticUsageStore.defaultToday, priceTable: .bundled).summary(for: .day)
        XCTAssertEqual(summary.cost.estimatedUSD, 0.75 + 2 * 3.75, accuracy: 1e-9)
        XCTAssertEqual(summary.cost.unpricedTokens, 500)
        XCTAssertEqual(summary.cost.priceTableVersion, "tokscale-4.21.0-2026-11-10+alias-v3")
    }

    func testTokenFormat() throws {
        XCTAssertEqual(TokenFormat.short(1_240_000_000), "1.24B")
        XCTAssertEqual(TokenFormat.short(58_300_000), "58.3M")
        XCTAssertEqual(TokenFormat.short(412_500), "412.5K")
        XCTAssertEqual(TokenFormat.short(980), "980")
        XCTAssertEqual(TokenFormat.short(999_960), "1.0M")
        XCTAssertEqual(TokenFormat.usd(132.26), "$132.26")
    }

    func testDefaultCalendarIsGregorianWithCurrentZoneLocaleAndFirstWeekday() {
        let defaultCalendar = UsageAggregator.defaultCalendar
        XCTAssertEqual(defaultCalendar.identifier, .gregorian)
        XCTAssertEqual(defaultCalendar.timeZone, .current)
        XCTAssertEqual(defaultCalendar.locale, .current)
        XCTAssertEqual(defaultCalendar.firstWeekday, Calendar.current.firstWeekday)
    }

    func testHavanaMidnightDSTMonthBucketsDoNotDriftOrMarkTodayFuture() throws {
        let viewer = calendar("America/Havana")
        let store = GranularityStore(daily: [
            UsageRecord(day: "2026-03-07", timeZoneID: viewer.timeZone.identifier, deviceID: "test", sourceID: "claude",
                modelID: "fixture", counts: TokenCounts(input: 10)),
            UsageRecord(day: "2026-03-08", timeZoneID: viewer.timeZone.identifier, deviceID: "test", sourceID: "claude",
                modelID: "fixture", counts: TokenCounts(input: 20)),
            UsageRecord(day: "2026-03-09", timeZoneID: viewer.timeZone.identifier, deviceID: "test", sourceID: "claude",
                modelID: "fixture", counts: TokenCounts(input: 30)),
            UsageRecord(day: "2026-03-10", timeZoneID: viewer.timeZone.identifier, deviceID: "test", sourceID: "claude",
                modelID: "fixture", counts: TokenCounts(input: 40)),
        ])

        let march10 = UsageDay.date(from: "2026-03-10", in: viewer.timeZone)!.addingTimeInterval(12 * 3_600)
        let agg = UsageAggregator(store: store, calendar: viewer, now: march10)
        let summary = try agg.summary(for: .month)
        let buckets = try agg.lensBuckets(for: .month)

        XCTAssertEqual(summary.series.count, 31)
        XCTAssertEqual(buckets.count, 31)
        XCTAssertFalse(summary.series[9].isFuture)
        XCTAssertFalse(buckets[9].isFuture)
        XCTAssertTrue(summary.series[10].isFuture)
        XCTAssertTrue(buckets[10].isFuture)
        XCTAssertEqual(summary.total.input, 100)
        XCTAssertEqual(agg.lensSlice(buckets, range: 0...30, period: .month).counts, summary.total)
        for dayIndex in 8..<31 {
            XCTAssertEqual(viewer.component(.hour, from: buckets[dayIndex].start), 0)
            let expectedDay = UsageDay.date(from: String(format: "2026-03-%02d", dayIndex + 1), in: viewer.timeZone)
            XCTAssertEqual(buckets[dayIndex].start, expectedDay)
        }

        let march8 = UsageDay.date(from: "2026-03-08", in: viewer.timeZone)!.addingTimeInterval(12 * 3_600)
        let onDST = UsageAggregator(store: store, calendar: viewer, now: march8)
        let dstMonth = try onDST.summary(for: .month)
        XCTAssertEqual(dstMonth.end, UsageDay.date(from: "2026-03-09", in: viewer.timeZone))
        XCTAssertEqual(dstMonth.total.input, 30)
        XCTAssertFalse(dstMonth.series[7].isFuture)
        XCTAssertTrue(dstMonth.series[8].isFuture)
        XCTAssertEqual(try onDST.summary(for: .day).series.count, 23)
    }

    func testFutureOnlyDataForAllPeriodProducesValidNonEmptyWindow() throws {
        let viewer = calendar("America/Los_Angeles")
        let now = UsageDay.date(from: "2026-11-09", in: viewer.timeZone)!.addingTimeInterval(12 * 3_600)
        let store = GranularityStore(daily: [
            UsageRecord(day: "2026-12-05", timeZoneID: "Asia/Shanghai", deviceID: "test", sourceID: "claude",
                modelID: "fixture", counts: TokenCounts(input: 50)),
        ])
        let agg = UsageAggregator(store: store, calendar: viewer, now: now)
        let summary = try agg.summary(for: .all)
        let buckets = try agg.lensBuckets(for: .all)

        XCTAssertLessThan(summary.start, summary.end)
        XCTAssertEqual(summary.start, viewer.startOfDay(for: now))
        XCTAssertEqual(summary.total, .zero)
        XCTAssertEqual(summary.series.count, 1)
        XCTAssertEqual(summary.series.first?.label, "11")
        XCTAssertEqual(buckets.count, 1)
    }

    func testEmptyHourlyBucketMarksReasoningKnownFalse() throws {
        let viewer = calendar("UTC")
        let dayStart = UsageDay.date(from: "2026-11-09", in: viewer.timeZone)!
        let now = dayStart.addingTimeInterval(10 * 3_600 + 1_800)
        let row = HourlyUsage(hourStart: dayStart.addingTimeInterval(8 * 3_600), deviceID: "test", sourceID: "claude",
            counts: TokenCounts(input: 10, reasoning: 2), eventCount: 1, reasoningKnown: true)
        let daily = UsageRecord(day: "2026-11-09", timeZoneID: "UTC", deviceID: "test", sourceID: "claude",
            modelID: "fixture", counts: TokenCounts(input: 10, reasoning: 2))
        let agg = UsageAggregator(store: GranularityStore(daily: [daily], hours: [row]), calendar: viewer, now: now)
        let buckets = try agg.lensBuckets(for: .day)

        XCTAssertEqual(buckets.count, 24)
        XCTAssertTrue(buckets[8].isKnown)
        XCTAssertTrue(buckets[8].reasoningKnown)
        XCTAssertFalse(buckets[7].isKnown)
        XCTAssertFalse(buckets[7].reasoningKnown)
        XCTAssertFalse(agg.lensSlice(buckets, range: 7...7, period: .day).reasoningKnown)
    }

    func testTokenCountsCacheHitRateAndNilRules() throws {
        XCTAssertNil(TokenCounts.zero.cacheHitRate)
        XCTAssertNil(TokenCounts(output: 500, reasoning: 200).cacheHitRate)
        XCTAssertEqual(
            try XCTUnwrap(TokenCounts(input: 200, cacheRead: 600, cacheWrite: 200, output: 999).cacheHitRate),
            0.6,
            accuracy: 1e-9
        )
        // Boundary: uncategorized == prompt (100 * 2 == 100 + 100) still yields a rate; strictly greater yields nil.
        XCTAssertEqual(
            try XCTUnwrap(TokenCounts(input: 50, cacheRead: 50, uncategorized: 100).cacheHitRate),
            0.5,
            accuracy: 1e-9
        )
        XCTAssertNil(TokenCounts(input: 50, cacheRead: 50, uncategorized: 101).cacheHitRate)
    }

    func testBreakdownCacheSavingsPopulatedForModelsOnly() throws {
        let viewer = calendar("UTC")
        let now = UsageDay.date(from: "2026-11-09", in: viewer.timeZone)!.addingTimeInterval(12 * 3_600)
        let prices = PriceTable(version: "fixture", rates: [
            "priced-model": .init(input: 4, cacheRead: 0.4, cacheWrite: 5, output: 16),
        ])
        let store = GranularityStore(daily: [
            UsageRecord(
                day: "2026-11-09",
                timeZoneID: "UTC",
                deviceID: "dev-1",
                sourceID: "claude",
                modelID: "priced-model",
                counts: TokenCounts(input: 100_000, cacheRead: 1_000_000, cacheWrite: 200_000, output: 50_000)
            ),
            UsageRecord(
                day: "2026-11-09",
                timeZoneID: "UTC",
                deviceID: "dev-1",
                sourceID: "claude",
                modelID: "unpriced-model",
                counts: TokenCounts(input: 10_000, cacheRead: 500_000)
            ),
        ])
        let agg = UsageAggregator(store: store, calendar: viewer, now: now, priceTable: prices)
        let summary = try agg.summary(for: .month)
        XCTAssertEqual(
            try XCTUnwrap(summary.byModel.first { $0.id == "priced-model" }?.cacheSavingsUSD),
            3.6,
            accuracy: 1e-9
        )
        XCTAssertNil(summary.byModel.first { $0.id == "unpriced-model" }?.cacheSavingsUSD)
        XCTAssertTrue(summary.bySource.allSatisfy { $0.cacheSavingsUSD == nil })
        XCTAssertTrue(summary.byDevice.allSatisfy { $0.cacheSavingsUSD == nil })

        let buckets = try agg.lensBuckets(for: .month)
        let slice = agg.lensSlice(buckets, range: 0...(buckets.count - 1), period: .month)
        XCTAssertEqual(
            try XCTUnwrap(slice.byModel.first { $0.id == "priced-model" }?.cacheSavingsUSD),
            3.6,
            accuracy: 1e-9
        )
        XCTAssertNil(slice.byModel.first { $0.id == "unpriced-model" }?.cacheSavingsUSD)
        XCTAssertTrue(slice.bySource.allSatisfy { $0.cacheSavingsUSD == nil })
        XCTAssertTrue(slice.byDevice.allSatisfy { $0.cacheSavingsUSD == nil })
    }
}

private struct GranularityStore: UsageStore {
    let devices: [Device] = []
    var daily: [UsageRecord]
    var hours: [HourlyUsage] = []
    func records() -> [UsageRecord] { daily }
    func hourly() -> [HourlyUsage] { hours }
}

/// Counts store reads so a test can prove a preloaded refresh scans the store once.
private final class CountingUsageStore: UsageStore, @unchecked Sendable {
    let devices: [Device]
    private let daily: [UsageRecord]
    private let hours: [HourlyUsage]
    private(set) var recordReads = 0
    private(set) var hourReads = 0

    init(devices: [Device], daily: [UsageRecord], hours: [HourlyUsage]) {
        self.devices = devices
        self.daily = daily
        self.hours = hours
    }

    func records() -> [UsageRecord] {
        recordReads += 1
        return daily
    }

    func hourly() -> [HourlyUsage] {
        hourReads += 1
        return hours
    }
}
