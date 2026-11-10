import Foundation

public struct UsageAggregator: Sendable {
    private let store: any UsageStore
    private let calendar: Calendar
    private let now: Date
    private let priceTable: PriceTable

    public init(store: any UsageStore, calendar: Calendar = .current, now: Date = .now, priceTable: PriceTable? = nil) {
        self.store = store
        self.calendar = calendar
        self.now = now
        self.priceTable = priceTable ?? (store is SyntheticUsageStore ? .synthetic : .bundled)
    }

    /// Ranges run from the period start through the end of today in `calendar`'s time zone.
    public func summary(for period: Period) throws -> UsageSummary {
        let entries = try localizedEntries()
        let today = calendar.startOfDay(for: now)
        let end = addDays(1, to: today)
        let start: Date = switch period {
        case .day: today
        case .month: calendar.dateInterval(of: .month, for: now)!.start
        case .year: calendar.dateInterval(of: .year, for: now)!.start
        case .all: entries.map(\.day).min() ?? today
        }
        let inRange = entries.filter { $0.day >= start && $0.day < end }

        var total = TokenCounts.zero
        var sources: [String: TokenCounts] = [:]
        var models: [String: TokenCounts] = [:]
        var deviceTotals: [String: TokenCounts] = [:]
        var usd = 0.0
        var unpriced: Int64 = 0
        for entry in inRange {
            let record = entry.record
            total += record.counts
            sources[record.sourceID, default: .zero] += record.counts
            models[record.modelID, default: .zero] += record.counts
            deviceTotals[record.deviceID, default: .zero] += record.counts
            var categorized = record.counts
            categorized.uncategorized = 0
            if let cost = priceTable.cost(model: record.modelID, counts: categorized) {
                usd += cost
                unpriced += record.counts.uncategorized
            } else {
                unpriced += record.counts.total
            }
        }

        let devices = store.devices
        let deviceNames = Dictionary(devices.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return UsageSummary(
            period: period,
            start: start,
            end: end,
            total: total,
            bySource: Self.breakdowns(sources) { SourceCatalog.info(for: $0).name },
            byModel: Self.breakdowns(models) { $0 },
            byDevice: Self.breakdowns(deviceTotals) { deviceNames[$0] ?? $0 },
            series: try series(for: period, start: start, today: today, entries: inRange),
            cost: CostEstimate(estimatedUSD: usd, unpricedTokens: unpriced, priceTableVersion: priceTable.version),
            devices: devices
        )
    }

    /// One point per day for the last `lastDays` days, ending today.
    public func dailyTotals(lastDays: Int) throws -> [SeriesPoint] {
        guard lastDays > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        let starts = (0..<lastDays).map { addDays($0 - lastDays + 1, to: today) }
        let first = starts[0]
        return points(
            starts: starts,
            entries: try localizedEntries().filter { $0.day >= first && $0.day <= today },
            index: { calendar.dateComponents([.day], from: first, to: $0).day ?? -1 },
            label: { String(calendar.component(.day, from: $0)) },
            isFuture: { _ in false }
        )
    }

    // MARK: - Series

    private func series(for period: Period, start: Date, today: Date, entries: [Entry]) throws -> [SeriesPoint] {
        switch period {
        case .day:
            return try hourlySeries(dayStart: start, entries: entries)
        case .month:
            let monthEnd = calendar.dateInterval(of: .month, for: start)!.end
            var starts: [Date] = []
            var day = start
            while day < monthEnd {
                starts.append(day)
                day = addDays(1, to: day)
            }
            return points(
                starts: starts,
                entries: entries,
                index: { calendar.component(.day, from: $0) - 1 },
                label: { String(calendar.component(.day, from: $0)) },
                isFuture: { $0 > today }
            )
        case .year:
            let starts = (0..<12).map { calendar.date(byAdding: .month, value: $0, to: start)! }
            return points(
                starts: starts,
                entries: entries,
                index: { calendar.component(.month, from: $0) - 1 },
                label: { String(calendar.component(.month, from: $0)) },
                isFuture: { $0 > now }
            )
        case .all:
            let firstMonth = calendar.dateInterval(of: .month, for: start)!.start
            let lastMonth = calendar.dateInterval(of: .month, for: now)!.start
            var starts: [Date] = []
            var month = firstMonth
            while month <= lastMonth {
                starts.append(month)
                month = calendar.date(byAdding: .month, value: 1, to: month)!
            }
            return points(
                starts: starts,
                entries: entries,
                index: { calendar.dateComponents([.month], from: firstMonth, to: calendar.dateInterval(of: .month, for: $0)!.start).month ?? -1 },
                label: { String(calendar.component(.month, from: $0)) },
                isFuture: { _ in false }
            )
        }
    }

    private func points(
        starts: [Date],
        entries: [Entry],
        index: (Date) -> Int,
        label: (Date) -> String,
        isFuture: (Date) -> Bool
    ) -> [SeriesPoint] {
        var totals = [Int64](repeating: 0, count: starts.count)
        var bySource = [[String: Int64]](repeating: [:], count: starts.count)
        for entry in entries {
            let i = index(entry.day)
            guard starts.indices.contains(i) else { continue }
            let tokens = entry.record.counts.total
            totals[i] += tokens
            bySource[i][entry.record.sourceID, default: 0] += tokens
        }
        return starts.indices.map { i in
            SeriesPoint(id: i, start: starts[i], label: label(starts[i]), total: totals[i], bySource: bySource[i], isFuture: isFuture(starts[i]))
        }
    }

    private func hourlySeries(dayStart: Date, entries: [Entry]) throws -> [SeriesPoint] {
        let end = addDays(1, to: dayStart)
        var starts: [Date] = []
        var hour = dayStart
        while hour < end {
            starts.append(hour)
            hour = calendar.date(byAdding: .hour, value: 1, to: hour)!
        }
        let rows = try store.hourly().filter { $0.hourStart >= dayStart && $0.hourStart < end }
        let grouped = Dictionary(grouping: rows) { calendar.dateInterval(of: .hour, for: $0.hourStart)!.start }
        let expected = Set(entries.map { $0.record.deviceID + "\u{0}" + $0.record.sourceID })
        return starts.enumerated().map { index, start in
            let bucket = grouped[start] ?? []
            var bySource: [String: Int64] = [:]
            for row in bucket { bySource[row.sourceID, default: 0] += row.counts.total }
            let covered = Set(bucket.map { $0.deviceID + "\u{0}" + $0.sourceID })
            return SeriesPoint(id: index, start: start, label: String(calendar.component(.hour, from: start)),
                total: bySource.values.reduce(0, +), bySource: bySource, isFuture: start > now,
                isKnown: !bucket.isEmpty && expected.isSubset(of: covered))
        }
    }

    // MARK: - Helpers

    private struct Entry {
        let day: Date
        let record: UsageRecord
    }

    /// Preserve the collecting device's date label; cross-zone daily re-bucketing is not possible (ADR-0005).
    private func localizedEntries() throws -> [Entry] {
        var cache: [String: Date] = [:]
        return try store.records().map { record in
            if let day = cache[record.day] { return Entry(day: day, record: record) }
            guard let day = UsageDay.date(from: record.day, in: calendar.timeZone) else {
                throw StoreError.sql("Invalid usage day")
            }
            cache[record.day] = day
            return Entry(day: day, record: record)
        }
    }

    private func addDays(_ days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: date)!
    }

    private static func breakdowns(_ groups: [String: TokenCounts], name: (String) -> String) -> [Breakdown] {
        groups
            .map { Breakdown(id: $0.key, name: name($0.key), counts: $0.value) }
            .sorted { $0.counts.total != $1.counts.total ? $0.counts.total > $1.counts.total : $0.id < $1.id }
    }
}
