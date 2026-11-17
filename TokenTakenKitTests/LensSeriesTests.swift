import XCTest
@testable import TokenTakenKit

final class LensSeriesTests: XCTestCase {
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

    func testBucketsMatchSummarySeriesAcrossPeriodsAndZones() throws {
        for zone in ["UTC", "Asia/Shanghai", "America/Los_Angeles"] {
            let agg = aggregator(zone)
            for period in Period.allCases {
                let summary = try agg.summary(for: period)
                let buckets = try agg.lensBuckets(for: period)
                let context = "\(zone) \(period)"
                XCTAssertEqual(buckets.count, summary.series.count, context)
                for (bucket, point) in zip(buckets, summary.series) {
                    XCTAssertEqual(bucket.id, point.id, context)
                    XCTAssertEqual(bucket.start, point.start, context)
                    XCTAssertLessThan(bucket.start, bucket.end, context)
                    XCTAssertEqual(bucket.label, point.label, context)
                    XCTAssertEqual(bucket.isFuture, point.isFuture, context)
                    XCTAssertEqual(bucket.isKnown, point.isKnown, context)
                    XCTAssertEqual(bucket.total, bucket.counts.total, context)
                    XCTAssertEqual(bucket.total, point.total, context)
                    XCTAssertEqual(bucket.bySource.mapValues(\.total), point.bySource, context)
                }
                for index in 0..<max(0, buckets.count - 1) {
                    XCTAssertEqual(buckets[index].end, buckets[index + 1].start, context)
                }
            }
        }

        // 23-hour spring-forward DST day in America/New_York.
        let viewer = calendar("America/New_York")
        let now = ISO8601DateFormatter().date(from: "2026-03-09T03:30:00Z")!
        let bundle = Bundle(for: LensSeriesTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "tokscale-hourly", withExtension: "json"))
        let hourly = try TokscaleCollector.parseHourly(
            data: Data(contentsOf: url),
            client: "claude",
            deviceID: "test",
            timeZone: viewer.timeZone,
            now: now
        )
        let record = UsageRecord(
            day: "2026-03-08",
            timeZoneID: viewer.timeZone.identifier,
            deviceID: "test",
            sourceID: "claude",
            modelID: "fixture",
            counts: TokenCounts(input: 1_000, cacheRead: 300, cacheWrite: 100, output: 200, reasoning: 100)
        )
        let dstAggregator = UsageAggregator(
            store: LensFixtureStore(daily: [record], hours: hourly),
            calendar: viewer,
            now: now
        )
        let dstSummary = try dstAggregator.summary(for: .day)
        let dstBuckets = try dstAggregator.lensBuckets(for: .day)
        XCTAssertEqual(dstBuckets.count, 23)
        XCTAssertEqual(dstBuckets.map(\.start), dstSummary.series.map(\.start))
        XCTAssertEqual(dstBuckets.map(\.label), dstSummary.series.map(\.label))
        XCTAssertEqual(dstBuckets.map(\.isFuture), dstSummary.series.map(\.isFuture))
        XCTAssertEqual(dstBuckets.map(\.isKnown), dstSummary.series.map(\.isKnown))
    }

    func testNonFutureBucketsMatchSummaryTotalsAndCosts() throws {
        for zone in ["UTC", "Asia/Shanghai", "America/Los_Angeles"] {
            let agg = aggregator(zone)
            for period in [Period.week, .month] {
                let summary = try agg.summary(for: period)
                let buckets = try agg.lensBuckets(for: period)
                let context = "\(zone) \(period)"

                let active = buckets.filter { !$0.isFuture }
                let countsSum = active.reduce(TokenCounts.zero) { $0 + $1.counts }
                XCTAssertEqual(countsSum, summary.total, context)

                var usd = 0.0
                var unpriced: Int64 = 0
                for bucket in active {
                    let cost = try XCTUnwrap(bucket.cost, "\(context) bucket \(bucket.id)")
                    usd += cost.estimatedUSD
                    unpriced += cost.unpricedTokens
                    XCTAssertEqual(cost.priceTableVersion, summary.cost.priceTableVersion, context)
                    XCTAssertEqual(bucket.bySource.values.reduce(TokenCounts.zero) { $0 + $1 }, bucket.counts, context)
                    XCTAssertEqual(bucket.byModel.values.reduce(TokenCounts.zero) { $0 + $1 }, bucket.counts, context)
                    XCTAssertEqual(bucket.byDevice.values.reduce(TokenCounts.zero) { $0 + $1 }, bucket.counts, context)
                }
                XCTAssertEqual(usd, summary.cost.estimatedUSD, accuracy: 1e-6, context)
                XCTAssertEqual(unpriced, summary.cost.unpricedTokens, context)

                let fullSlice = agg.lensSlice(buckets, range: 0...(buckets.count - 1), period: period)
                XCTAssertEqual(fullSlice.counts, summary.total, context)
                XCTAssertEqual(fullSlice.bySource, summary.bySource, context)
                XCTAssertEqual(fullSlice.byModel, summary.byModel, context)
                XCTAssertEqual(fullSlice.byDevice, summary.byDevice, context)
                XCTAssertTrue(fullSlice.hasModelDetail, context)
                let sliceCost = try XCTUnwrap(fullSlice.cost, context)
                XCTAssertEqual(sliceCost.estimatedUSD, summary.cost.estimatedUSD, accuracy: 1e-6, context)
                XCTAssertEqual(sliceCost.unpricedTokens, summary.cost.unpricedTokens, context)
                XCTAssertEqual(sliceCost.priceTableVersion, summary.cost.priceTableVersion, context)
            }
        }
    }

    func testDayPeriodOmitsModelDetailAndCost() throws {
        let agg = aggregator("UTC")
        let buckets = try agg.lensBuckets(for: .day)
        XCTAssertEqual(buckets.count, 24)
        for bucket in buckets {
            XCTAssertTrue(bucket.byModel.isEmpty)
            XCTAssertNil(bucket.cost)
        }

        let slice = agg.lensSlice(buckets, range: 0...23, period: .day)
        XCTAssertFalse(slice.hasModelDetail)
        XCTAssertTrue(slice.byModel.isEmpty)
        XCTAssertNil(slice.cost)
        XCTAssertGreaterThan(slice.counts.total, 0)
        XCTAssertEqual(sum(slice.bySource), slice.counts)
        XCTAssertEqual(sum(slice.byDevice), slice.counts)

        // Explicit zero hourly coverage rows establish `isKnown` without polluting slice breakdowns.
        let viewer = calendar("UTC")
        let dayStart = ISO8601DateFormatter().date(from: "2026-11-09T00:00:00Z")!
        let now = dayStart.addingTimeInterval(10 * 3_600 + 1_800)
        let hour8 = dayStart.addingTimeInterval(8 * 3_600)
        let fixture = LensFixtureStore(
            devices: [Device(id: "mac-1", name: "Desk Studio")],
            daily: [
                UsageRecord(
                    day: "2026-11-09",
                    timeZoneID: "UTC",
                    deviceID: "mac-1",
                    sourceID: "claude",
                    modelID: "claude-opus-5-5",
                    counts: TokenCounts(input: 120, output: 30)
                ),
                UsageRecord(
                    day: "2026-11-09",
                    timeZoneID: "UTC",
                    deviceID: "mac-1",
                    sourceID: "codex",
                    modelID: "gpt-6.1",
                    counts: TokenCounts(input: 50)
                ),
            ],
            hours: [
                HourlyUsage(
                    hourStart: hour8,
                    deviceID: "mac-1",
                    sourceID: "claude",
                    counts: TokenCounts(input: 120, output: 30),
                    eventCount: 2,
                    reasoningKnown: false
                ),
                HourlyUsage(
                    hourStart: hour8,
                    deviceID: "mac-1",
                    sourceID: "codex",
                    counts: .zero,
                    eventCount: 0,
                    reasoningKnown: false
                ),
            ]
        )
        let dayAgg = UsageAggregator(store: fixture, calendar: viewer, now: now)
        let dayBuckets = try dayAgg.lensBuckets(for: .day)
        XCTAssertTrue(dayBuckets[8].isKnown)
        XCTAssertTrue(dayBuckets[8].byModel.isEmpty)
        XCTAssertNil(dayBuckets[8].cost)

        let hour8Slice = dayAgg.lensSlice(dayBuckets, range: 8...8, period: .day)
        XCTAssertFalse(hour8Slice.hasModelDetail)
        XCTAssertTrue(hour8Slice.byModel.isEmpty)
        XCTAssertNil(hour8Slice.cost)
        XCTAssertEqual(hour8Slice.bySource, [
            Breakdown(id: "claude", name: "Claude Code", counts: TokenCounts(input: 120, output: 30)),
        ])
        XCTAssertEqual(hour8Slice.byDevice, [
            Breakdown(id: "mac-1", name: "Desk Studio", counts: TokenCounts(input: 120, output: 30)),
        ])
    }

    func testLensSliceSummationSortingClampingAndFutureSkipping() throws {
        var viewer = calendar("Asia/Shanghai")
        viewer.locale = Locale(identifier: "en_US_POSIX")
        viewer.firstWeekday = 1

        let devices = [
            Device(id: "dev-a", name: "Studio Mac"),
            Device(id: "dev-b", name: "Travel Air"),
        ]
        let prices = PriceTable(version: "fixture-v1", rates: [
            "model-fast": .init(input: 2, cacheRead: 0.2, cacheWrite: 0, output: 10),
            "model-deep": .init(input: 5, cacheRead: 0.5, cacheWrite: 1, output: 20),
        ])
        let fixture = LensFixtureStore(
            devices: devices,
            daily: [
                // Mon 2026-11-09 (bucket 0): 1.5M tokens, $15.00
                UsageRecord(
                    day: "2026-11-09",
                    timeZoneID: viewer.timeZone.identifier,
                    deviceID: "dev-a",
                    sourceID: "claude",
                    modelID: "model-deep",
                    counts: TokenCounts(input: 1_000_000, output: 500_000)
                ),
                // Tue 2026-11-10 (bucket 1): 3.0M tokens ($14.00) + 0.4M unpriced tokens
                UsageRecord(
                    day: "2026-11-10",
                    timeZoneID: viewer.timeZone.identifier,
                    deviceID: "dev-b",
                    sourceID: "codex",
                    modelID: "model-fast",
                    counts: TokenCounts(input: 2_000_000, output: 1_000_000)
                ),
                UsageRecord(
                    day: "2026-11-10",
                    timeZoneID: viewer.timeZone.identifier,
                    deviceID: "dev-a",
                    sourceID: "kimi",
                    modelID: "model-unpriced",
                    counts: TokenCounts(input: 400_000)
                ),
                // Wed 2026-11-11 (bucket 2): 0.6M tokens, $3.00
                UsageRecord(
                    day: "2026-11-11",
                    timeZoneID: viewer.timeZone.identifier,
                    deviceID: "dev-b",
                    sourceID: "claude",
                    modelID: "model-deep",
                    counts: TokenCounts(input: 600_000)
                ),
            ]
        )

        // Wednesday 2026-11-11 12:00: buckets 0..2 (Mon..Wed) are active; buckets 3..6 (Thu..Sun) are future.
        let wednesdayNow = UsageDay.date(from: "2026-11-11", in: viewer.timeZone)!.addingTimeInterval(12 * 3_600)
        let agg = UsageAggregator(store: fixture, calendar: viewer, now: wednesdayNow, priceTable: prices)
        let buckets = try agg.lensBuckets(for: .week)
        XCTAssertEqual(buckets.count, 7)
        XCTAssertEqual(buckets.map(\.isFuture), [false, false, false, true, true, true, true])

        // Sub-range Tue..Wed (1...2): sums counts, resolves names, sorts descending by total.
        let subSlice = agg.lensSlice(buckets, range: 1...2, period: .week)
        XCTAssertEqual(subSlice.range, 1...2)
        XCTAssertEqual(subSlice.start, buckets[1].start)
        XCTAssertEqual(subSlice.end, buckets[2].end)
        XCTAssertEqual(subSlice.counts, TokenCounts(input: 3_000_000, output: 1_000_000))
        XCTAssertTrue(subSlice.hasModelDetail)
        XCTAssertEqual(subSlice.bySource, [
            Breakdown(id: "codex", name: "Codex", counts: TokenCounts(input: 2_000_000, output: 1_000_000)),
            Breakdown(id: "claude", name: "Claude Code", counts: TokenCounts(input: 600_000)),
            Breakdown(id: "kimi", name: "Kimi Code", counts: TokenCounts(input: 400_000)),
        ])
        XCTAssertEqual(subSlice.byModel, [
            Breakdown(id: "model-fast", name: "model-fast", counts: TokenCounts(input: 2_000_000, output: 1_000_000)),
            Breakdown(id: "model-deep", name: "model-deep", counts: TokenCounts(input: 600_000)),
            Breakdown(id: "model-unpriced", name: "model-unpriced", counts: TokenCounts(input: 400_000)),
        ])
        XCTAssertEqual(subSlice.byDevice, [
            Breakdown(id: "dev-b", name: "Travel Air", counts: TokenCounts(input: 2_600_000, output: 1_000_000)),
            Breakdown(id: "dev-a", name: "Studio Mac", counts: TokenCounts(input: 400_000)),
        ])
        let subCost = try XCTUnwrap(subSlice.cost)
        XCTAssertEqual(subCost.estimatedUSD, 17.0, accuracy: 1e-9)
        XCTAssertEqual(subCost.unpricedTokens, 400_000)
        XCTAssertEqual(subCost.priceTableVersion, "fixture-v1")

        // Out-of-bounds range is clamped to 0...6 and future buckets are skipped even if populated.
        var syntheticFuture = buckets
        syntheticFuture[4] = LensBucket(
            id: 4,
            start: buckets[4].start,
            end: buckets[4].end,
            label: buckets[4].label,
            counts: TokenCounts(input: 9_000_000),
            bySource: ["grok": TokenCounts(input: 9_000_000)],
            byModel: ["grok-5": TokenCounts(input: 9_000_000)],
            byDevice: ["dev-a": TokenCounts(input: 9_000_000)],
            cost: CostEstimate(estimatedUSD: 999, unpricedTokens: 0, priceTableVersion: "fixture-v1"),
            isFuture: true
        )
        let clampedSlice = agg.lensSlice(syntheticFuture, range: -5...99, period: .week)
        XCTAssertEqual(clampedSlice.range, 0...6)
        XCTAssertEqual(clampedSlice.start, buckets[0].start)
        XCTAssertEqual(clampedSlice.end, buckets[2].end)
        XCTAssertEqual(clampedSlice.counts, TokenCounts(input: 4_000_000, output: 1_500_000))
        XCTAssertFalse(clampedSlice.bySource.contains { $0.id == "grok" })
        let clampedCost = try XCTUnwrap(clampedSlice.cost)
        XCTAssertEqual(clampedCost.estimatedUSD, 32.0, accuracy: 1e-9)
        XCTAssertEqual(clampedCost.unpricedTokens, 400_000)
        XCTAssertEqual(clampedCost.priceTableVersion, "fixture-v1")

        // Ranges completely outside either bound clamp cleanly without crashing.
        let leftClamped = agg.lensSlice(buckets, range: -10 ... -2, period: .week)
        XCTAssertEqual(leftClamped.range, 0...0)
        XCTAssertEqual(leftClamped.counts, buckets[0].counts)

        let rightClamped = agg.lensSlice(buckets, range: 20...30, period: .week)
        XCTAssertEqual(rightClamped.range, 6...6)
        XCTAssertEqual(rightClamped.counts, .zero)
        XCTAssertTrue(rightClamped.bySource.isEmpty)
        XCTAssertTrue(rightClamped.byModel.isEmpty)
        XCTAssertTrue(rightClamped.byDevice.isEmpty)

        // Any nil cost among non-future buckets in the interval makes the whole slice cost nil.
        var missingCost = buckets
        missingCost[1] = LensBucket(
            id: 1,
            start: buckets[1].start,
            end: buckets[1].end,
            label: buckets[1].label,
            counts: buckets[1].counts,
            bySource: buckets[1].bySource,
            byModel: buckets[1].byModel,
            byDevice: buckets[1].byDevice,
            cost: nil,
            isFuture: false
        )
        XCTAssertNil(agg.lensSlice(missingCost, range: 0...2, period: .week).cost)
    }

    func testPreloadedRowsServeLensWithoutExtraStoreReads() throws {
        let counting = LensCountingStore(devices: store.devices, daily: store.records(), hours: store.hourly())
        let rows = try UsageAggregator.preload(counting)
        let agg = UsageAggregator(
            store: counting,
            rows: rows,
            calendar: calendar("UTC"),
            now: SyntheticUsageStore.defaultToday
        )
        _ = try agg.summary(for: .month)
        _ = try agg.summary(for: .day)
        let monthBuckets = try agg.lensBuckets(for: .month)
        let dayBuckets = try agg.lensBuckets(for: .day)
        _ = agg.lensSlice(monthBuckets, range: 0...5, period: .month)
        _ = agg.lensSlice(dayBuckets, range: 0...5, period: .day)
        XCTAssertEqual(counting.recordReads, 1)
        XCTAssertEqual(counting.hourReads, 1)
    }
}

private struct LensFixtureStore: UsageStore {
    var devices: [Device] = []
    var daily: [UsageRecord]
    var hours: [HourlyUsage] = []
    func records() -> [UsageRecord] { daily }
    func hourly() -> [HourlyUsage] { hours }
}

private final class LensCountingStore: UsageStore, @unchecked Sendable {
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
