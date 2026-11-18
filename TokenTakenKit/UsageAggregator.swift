import Foundation

public struct UsageAggregator: Sendable {
    /// Store contents read once, so several summaries share one scan of the database.
    public struct Rows: Sendable {
        public let records: [UsageRecord]
        public let hourly: [HourlyUsage]
        public let devices: [Device]

        public init(records: [UsageRecord], hourly: [HourlyUsage], devices: [Device]) {
            self.records = records
            self.hourly = hourly
            self.devices = devices
        }
    }

    private let store: any UsageStore
    /// Nil when the summaries should read the store themselves.
    private let rows: Rows?
    private let calendar: Calendar
    private let now: Date
    private let priceTable: PriceTable

    public static var defaultCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.locale = .current
        calendar.firstWeekday = Calendar.current.firstWeekday
        return calendar
    }

    public init(
        store: any UsageStore, rows: Rows? = nil, calendar: Calendar = UsageAggregator.defaultCalendar, now: Date = .now,
        priceTable: PriceTable? = nil
    ) {
        self.store = store
        self.rows = rows
        self.calendar = calendar
        self.now = now
        self.priceTable = priceTable ?? (store is SyntheticUsageStore ? .synthetic : .bundled)
    }

    /// Reads the store once for `init(store:rows:)`; building several summaries then costs one read.
    public static func preload(_ store: any UsageStore) throws -> Rows {
        Rows(records: try store.records(), hourly: try store.hourly(), devices: store.devices)
    }

    /// Ranges run from the period start through the end of today in `calendar`'s time zone.
    public func summary(for period: Period) throws -> UsageSummary {
        let window = try periodWindow(for: period)

        var total = TokenCounts.zero
        var sources: [String: TokenCounts] = [:]
        var models: [String: TokenCounts] = [:]
        var deviceTotals: [String: TokenCounts] = [:]
        var usd = 0.0
        var unpriced: Int64 = 0
        for entry in window.entries {
            let record = entry.record
            total += record.counts
            sources[record.sourceID, default: .zero] += record.counts
            models[record.modelID, default: .zero] += record.counts
            deviceTotals[record.deviceID, default: .zero] += record.counts
            let estimate = priceTable.estimate(model: record.modelID, counts: record.counts)
            usd += estimate.usd
            unpriced += estimate.unpricedTokens
        }

        let devices = rows?.devices ?? store.devices
        let breakdowns = Self.resolvedBreakdowns(
            sources: sources,
            models: models,
            devices: deviceTotals,
            deviceList: devices
        )
        return UsageSummary(
            period: period,
            start: window.start,
            end: window.end,
            total: total,
            bySource: breakdowns.bySource,
            byModel: breakdowns.byModel,
            byDevice: breakdowns.byDevice,
            series: try series(for: period, start: window.start, today: window.today, entries: window.entries),
            cost: CostEstimate(estimatedUSD: usd, unpricedTokens: unpriced, priceTableVersion: priceTable.version),
            devices: devices
        )
    }

    public func lensBuckets(for period: Period) throws -> [LensBucket] {
        let window = try periodWindow(for: period)
        if period == .day {
            return try hourlyLensBuckets(dayStart: window.start, entries: window.entries)
        }
        let spec = dailyBucketSpec(for: period, start: window.start, today: window.today)
        return dailyLensBuckets(from: partitionDaily(spec: spec, entries: window.entries))
    }

    public func lensSlice(_ buckets: [LensBucket], range: ClosedRange<Int>, period: Period) -> LensSlice {
        Self.lensSlice(
            buckets,
            range: range,
            period: period,
            devices: rows?.devices ?? store.devices,
            emptyDate: now
        )
    }

    public static func lensSlice(
        _ buckets: [LensBucket],
        range: ClosedRange<Int>,
        period: Period,
        devices: [Device]
    ) -> LensSlice {
        lensSlice(buckets, range: range, period: period, devices: devices, emptyDate: .now)
    }

    /// One point per day for the last `lastDays` days, ending today.
    public func dailyTotals(lastDays: Int) throws -> [SeriesPoint] {
        guard lastDays > 0 else { return [] }
        let calendar = self.calendar
        let today = calendar.startOfDay(for: now)
        let starts = (0..<lastDays).map { addDays($0 - lastDays + 1, to: today) }
        let first = starts[0]
        let indexByStart = Dictionary(starts.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let spec = DailyBucketSpec(
            starts: starts,
            end: addDays(1, to: today),
            index: { indexByStart[$0] ?? -1 },
            label: { String(calendar.component(.day, from: $0)) },
            isFuture: { _ in false }
        )
        let entries = try localizedEntries().filter { $0.day >= first && $0.day <= today }
        return seriesPoints(from: partitionDaily(spec: spec, entries: entries))
    }

    // MARK: - Series & Buckets

    private struct PeriodWindow {
        let start: Date
        let end: Date
        let today: Date
        let entries: [Entry]
    }

    private struct DailyBucketSpec {
        let starts: [Date]
        let end: Date
        let index: (Date) -> Int
        let label: (Date) -> String
        let isFuture: (Date) -> Bool

        func bucketEnd(at i: Int) -> Date {
            i + 1 < starts.count ? starts[i + 1] : end
        }
    }

    private struct PartitionedBucket<Row> {
        let id: Int
        let start: Date
        let end: Date
        let label: String
        let isFuture: Bool
        let isKnown: Bool
        let rows: [Row]
    }

    private func periodWindow(for period: Period) throws -> PeriodWindow {
        let entries = try localizedEntries()
        let today = calendar.startOfDay(for: now)
        let end = addDays(1, to: today)
        let start: Date = switch period {
        case .day: today
        case .week: weekCalendar.dateInterval(of: .weekOfYear, for: now)!.start
        case .month: calendar.dateInterval(of: .month, for: now)!.start
        case .year: calendar.dateInterval(of: .year, for: now)!.start
        case .all: entries.lazy.filter { $0.day < end }.map(\.day).min() ?? today
        }
        return PeriodWindow(
            start: start,
            end: end,
            today: today,
            entries: entries.filter { $0.day >= start && $0.day < end }
        )
    }

    private func series(for period: Period, start: Date, today: Date, entries: [Entry]) throws -> [SeriesPoint] {
        if period == .day {
            return try hourlySeries(dayStart: start, entries: entries)
        }
        let spec = dailyBucketSpec(for: period, start: start, today: today)
        return seriesPoints(from: partitionDaily(spec: spec, entries: entries))
    }

    private func dailyBucketSpec(for period: Period, start: Date, today: Date) -> DailyBucketSpec {
        let calendar = self.calendar
        let now = self.now
        switch period {
        case .day:
            preconditionFailure("Day buckets use hourly partitioning")
        case .week:
            let starts = (0..<7).map { addDays($0, to: start) }
            let indexByStart = Dictionary(starts.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            let symbols = calendar.shortWeekdaySymbols
            return DailyBucketSpec(
                starts: starts,
                end: addDays(7, to: start),
                index: { indexByStart[$0] ?? -1 },
                label: { symbols[calendar.component(.weekday, from: $0) - 1] },
                isFuture: { $0 > today }
            )
        case .month:
            let monthEnd = calendar.dateInterval(of: .month, for: start)!.end
            var starts: [Date] = []
            var offset = 0
            while true {
                let day = addDays(offset, to: start)
                guard day < monthEnd else { break }
                starts.append(day)
                offset += 1
            }
            return DailyBucketSpec(
                starts: starts,
                end: monthEnd,
                index: { calendar.component(.day, from: $0) - 1 },
                label: { String(calendar.component(.day, from: $0)) },
                isFuture: { $0 > today }
            )
        case .year:
            let starts = (0..<12).map { calendar.startOfDay(for: calendar.date(byAdding: .month, value: $0, to: start)!) }
            let yearEnd = calendar.startOfDay(for: calendar.date(byAdding: .month, value: 12, to: start)!)
            return DailyBucketSpec(
                starts: starts,
                end: yearEnd,
                index: { calendar.component(.month, from: $0) - 1 },
                label: { String(calendar.component(.month, from: $0)) },
                isFuture: { $0 > now }
            )
        case .all:
            let firstMonth = calendar.dateInterval(of: .month, for: start)!.start
            let lastMonth = calendar.dateInterval(of: .month, for: now)!.start
            var starts: [Date] = []
            var offset = 0
            var month = firstMonth
            while month <= lastMonth {
                starts.append(month)
                offset += 1
                month = calendar.startOfDay(for: calendar.date(byAdding: .month, value: offset, to: firstMonth)!)
            }
            return DailyBucketSpec(
                starts: starts,
                end: month,
                index: { calendar.dateComponents([.month], from: firstMonth, to: calendar.dateInterval(of: .month, for: $0)!.start).month ?? -1 },
                label: { String(calendar.component(.month, from: $0)) },
                isFuture: { _ in false }
            )
        }
    }

    private func partitionDaily(spec: DailyBucketSpec, entries: [Entry]) -> [PartitionedBucket<UsageRecord>] {
        var grouped = [[UsageRecord]](repeating: [], count: spec.starts.count)
        for entry in entries {
            let i = spec.index(entry.day)
            guard grouped.indices.contains(i) else { continue }
            grouped[i].append(entry.record)
        }
        return spec.starts.indices.map { i in
            let bucketStart = spec.starts[i]
            return PartitionedBucket(
                id: i,
                start: bucketStart,
                end: spec.bucketEnd(at: i),
                label: spec.label(bucketStart),
                isFuture: spec.isFuture(bucketStart),
                isKnown: true,
                rows: grouped[i]
            )
        }
    }

    private func seriesPoints(from buckets: [PartitionedBucket<UsageRecord>]) -> [SeriesPoint] {
        buckets.map { bucket in
            var total: Int64 = 0
            var bySource: [String: Int64] = [:]
            for record in bucket.rows {
                let tokens = record.counts.total
                total += tokens
                bySource[record.sourceID, default: 0] += tokens
            }
            return SeriesPoint(
                id: bucket.id,
                start: bucket.start,
                label: bucket.label,
                total: total,
                bySource: bySource,
                isFuture: bucket.isFuture,
                isKnown: bucket.isKnown
            )
        }
    }

    private func dailyLensBuckets(from buckets: [PartitionedBucket<UsageRecord>]) -> [LensBucket] {
        buckets.map { bucket in
            var counts = TokenCounts.zero
            var bySource: [String: TokenCounts] = [:]
            var byModel: [String: TokenCounts] = [:]
            var byDevice: [String: TokenCounts] = [:]
            var usd = 0.0
            var unpriced: Int64 = 0
            for record in bucket.rows {
                counts += record.counts
                bySource[record.sourceID, default: .zero] += record.counts
                byModel[record.modelID, default: .zero] += record.counts
                byDevice[record.deviceID, default: .zero] += record.counts
                let estimate = priceTable.estimate(model: record.modelID, counts: record.counts)
                usd += estimate.usd
                unpriced += estimate.unpricedTokens
            }
            return LensBucket(
                id: bucket.id,
                start: bucket.start,
                end: bucket.end,
                label: bucket.label,
                counts: counts,
                bySource: bySource,
                byModel: byModel,
                byDevice: byDevice,
                cost: CostEstimate(estimatedUSD: usd, unpricedTokens: unpriced, priceTableVersion: priceTable.version),
                isFuture: bucket.isFuture,
                isKnown: bucket.isKnown
            )
        }
    }

    private func partitionHourly(dayStart: Date, entries: [Entry]) throws -> [PartitionedBucket<HourlyUsage>] {
        let end = addDays(1, to: dayStart)
        var starts: [Date] = []
        var hour = dayStart
        while hour < end {
            starts.append(hour)
            hour = calendar.date(byAdding: .hour, value: 1, to: hour)!
        }
        let hourRows: [HourlyUsage]
        if let rows { hourRows = rows.hourly } else { hourRows = try store.hourly() }
        let inDay = hourRows.filter { $0.hourStart >= dayStart && $0.hourStart < end }
        let grouped = Dictionary(grouping: inDay) { calendar.dateInterval(of: .hour, for: $0.hourStart)!.start }
        let expected = Set(entries.map { $0.record.deviceID + "\u{0}" + $0.record.sourceID })
        return starts.enumerated().map { index, start in
            let bucket = grouped[start] ?? []
            let covered = Set(bucket.map { $0.deviceID + "\u{0}" + $0.sourceID })
            let bucketEnd = index + 1 < starts.count ? starts[index + 1] : end
            return PartitionedBucket(
                id: index,
                start: start,
                end: bucketEnd,
                label: String(calendar.component(.hour, from: start)),
                isFuture: start > now,
                isKnown: !bucket.isEmpty && expected.isSubset(of: covered),
                rows: bucket
            )
        }
    }

    private func hourlySeries(dayStart: Date, entries: [Entry]) throws -> [SeriesPoint] {
        try partitionHourly(dayStart: dayStart, entries: entries).map { bucket in
            var bySource: [String: Int64] = [:]
            for row in bucket.rows { bySource[row.sourceID, default: 0] += row.counts.total }
            return SeriesPoint(
                id: bucket.id,
                start: bucket.start,
                label: bucket.label,
                total: bySource.values.reduce(0, +),
                bySource: bySource,
                isFuture: bucket.isFuture,
                isKnown: bucket.isKnown
            )
        }
    }

    private func hourlyLensBuckets(dayStart: Date, entries: [Entry]) throws -> [LensBucket] {
        try partitionHourly(dayStart: dayStart, entries: entries).map { bucket in
            var counts = TokenCounts.zero
            var bySource: [String: TokenCounts] = [:]
            var byDevice: [String: TokenCounts] = [:]
            for row in bucket.rows {
                counts += row.counts
                bySource[row.sourceID, default: .zero] += row.counts
                byDevice[row.deviceID, default: .zero] += row.counts
            }
            return LensBucket(
                id: bucket.id,
                start: bucket.start,
                end: bucket.end,
                label: bucket.label,
                counts: counts,
                bySource: bySource,
                byModel: [:],
                byDevice: byDevice,
                cost: nil,
                isFuture: bucket.isFuture,
                isKnown: bucket.isKnown,
                reasoningKnown: !bucket.rows.isEmpty && bucket.rows.allSatisfy(\.reasoningKnown)
            )
        }
    }

    // MARK: - Helpers

    private static func lensSlice(
        _ buckets: [LensBucket],
        range: ClosedRange<Int>,
        period: Period,
        devices: [Device],
        emptyDate: Date
    ) -> LensSlice {
        let hasModelDetail = period != .day
        guard !buckets.isEmpty else {
            return LensSlice(
                range: 0...0,
                start: emptyDate,
                end: emptyDate,
                counts: .zero,
                bySource: [],
                byModel: [],
                byDevice: [],
                cost: nil,
                hasModelDetail: hasModelDetail
            )
        }

        let lastIndex = buckets.count - 1
        let lower = min(max(range.lowerBound, 0), lastIndex)
        let upper = min(max(range.upperBound, 0), lastIndex)
        let clamped = lower...upper
        let window = buckets[clamped]
        let active = window.filter { !$0.isFuture }

        let sliceStart = active.first?.start ?? buckets[lower].start
        let sliceEnd = active.last?.end ?? buckets[upper].end

        var counts = TokenCounts.zero
        var sources: [String: TokenCounts] = [:]
        var models: [String: TokenCounts] = [:]
        var deviceTotals: [String: TokenCounts] = [:]

        for bucket in active {
            counts += bucket.counts
            for (id, value) in bucket.bySource {
                sources[id, default: .zero] += value
            }
            if hasModelDetail {
                for (id, value) in bucket.byModel {
                    models[id, default: .zero] += value
                }
            }
            for (id, value) in bucket.byDevice {
                deviceTotals[id, default: .zero] += value
            }
        }

        let cost: CostEstimate?
        if active.isEmpty {
            if !hasModelDetail || window.contains(where: { $0.cost == nil }) {
                cost = nil
            } else if let firstCost = buckets[lower].cost {
                cost = CostEstimate(estimatedUSD: 0, unpricedTokens: 0, priceTableVersion: firstCost.priceTableVersion)
            } else {
                cost = nil
            }
        } else if active.contains(where: { $0.cost == nil }) {
            cost = nil
        } else {
            var usd = 0.0
            var unpriced: Int64 = 0
            for bucket in active {
                if let bucketCost = bucket.cost {
                    usd += bucketCost.estimatedUSD
                    unpriced += bucketCost.unpricedTokens
                }
            }
            cost = CostEstimate(
                estimatedUSD: usd,
                unpricedTokens: unpriced,
                priceTableVersion: active[0].cost!.priceTableVersion
            )
        }

        let breakdowns = resolvedBreakdowns(
            sources: sources,
            models: hasModelDetail ? models : [:],
            devices: deviceTotals,
            deviceList: devices,
            excludeZero: true
        )

        return LensSlice(
            range: clamped,
            start: sliceStart,
            end: sliceEnd,
            counts: counts,
            bySource: breakdowns.bySource,
            byModel: breakdowns.byModel,
            byDevice: breakdowns.byDevice,
            cost: cost,
            hasModelDetail: hasModelDetail,
            isKnown: active.allSatisfy(\.isKnown),
            reasoningKnown: active.allSatisfy(\.reasoningKnown)
        )
    }

    private struct Entry {
        let day: Date
        let record: UsageRecord
    }

    /// Preserve the collecting device's date label; cross-zone daily re-bucketing is not possible (ADR-0005).
    private func localizedEntries() throws -> [Entry] {
        var cache: [String: Date] = [:]
        var records: [UsageRecord]
        if let rows { records = rows.records } else { records = try store.records() }
        return try records.map { record in
            if let day = cache[record.day] { return Entry(day: day, record: record) }
            guard let day = UsageDay.date(from: record.day, in: calendar.timeZone) else {
                throw StoreError.sql("Invalid usage day")
            }
            cache[record.day] = day
            return Entry(day: day, record: record)
        }
    }

    private var weekCalendar: Calendar {
        var weekCalendar = calendar
        weekCalendar.firstWeekday = 2
        return weekCalendar
    }

    private func addDays(_ days: Int, to date: Date) -> Date {
        calendar.startOfDay(for: calendar.date(byAdding: .day, value: days, to: date)!)
    }

    private static func resolvedBreakdowns(
        sources: [String: TokenCounts],
        models: [String: TokenCounts],
        devices deviceTotals: [String: TokenCounts],
        deviceList: [Device],
        excludeZero: Bool = false
    ) -> (bySource: [Breakdown], byModel: [Breakdown], byDevice: [Breakdown]) {
        let deviceNames = Dictionary(deviceList.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return (
            bySource: breakdowns(sources, excludeZero: excludeZero) { SourceCatalog.info(for: $0).name },
            byModel: breakdowns(models, excludeZero: excludeZero) { $0 },
            byDevice: breakdowns(deviceTotals, excludeZero: excludeZero) { deviceNames[$0] ?? $0 }
        )
    }

    private static func breakdowns(
        _ groups: [String: TokenCounts],
        excludeZero: Bool = false,
        name: (String) -> String
    ) -> [Breakdown] {
        groups
            .filter { !excludeZero || $0.value.total > 0 }
            .map { Breakdown(id: $0.key, name: name($0.key), counts: $0.value) }
            .sorted { $0.counts.total != $1.counts.total ? $0.counts.total > $1.counts.total : $0.id < $1.id }
    }
}
