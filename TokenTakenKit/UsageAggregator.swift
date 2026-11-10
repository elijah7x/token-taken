import Foundation

public struct UsageAggregator: Sendable {
    private let store: any UsageStore
    private let calendar: Calendar
    private let now: Date
    private let priceTable = PriceTable.synthetic

    public init(store: any UsageStore, calendar: Calendar = .current, now: Date = .now) {
        self.store = store
        self.calendar = calendar
        self.now = now
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
            if let cost = priceTable.cost(model: record.modelID, counts: record.counts) {
                usd += cost
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
            series: series(for: period, start: start, today: today, entries: inRange),
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

    private func series(for period: Period, start: Date, today: Date, entries: [Entry]) -> [SeriesPoint] {
        switch period {
        case .day:
            return hourlySeries(dayStart: start, entries: entries)
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

    /// Relative activity per local hour. Records are daily, so a day's total is spread over this fixed curve.
    private static let hourlyActivity: [Int64] = [
        10, 6, 3, 2, 2, 3, 6, 12, 22, 34, 42, 44, 32, 36, 46, 48, 46, 42, 34, 30, 34, 32, 24, 16,
    ]

    private func hourlySeries(dayStart: Date, entries: [Entry]) -> [SeriesPoint] {
        let starts = (0..<24).map { calendar.date(byAdding: .hour, value: $0, to: dayStart)! }
        // Only elapsed hours receive usage, so the series still sums to the day total.
        let active = starts.indices.filter { starts[$0] <= now }
        let lastActive = active.last ?? 0
        let weightSum = active.reduce(Int64(0)) { $0 + Self.hourlyActivity[$1] }

        var dayBySource: [String: Int64] = [:]
        for entry in entries {
            dayBySource[entry.record.sourceID, default: 0] += entry.record.counts.total
        }

        var bySource = [[String: Int64]](repeating: [:], count: 24)
        for (source, tokens) in dayBySource {
            var assigned: Int64 = 0
            for hour in active {
                let share = weightSum > 0 ? tokens * Self.hourlyActivity[hour] / weightSum : 0
                bySource[hour][source] = share
                assigned += share
            }
            bySource[lastActive][source, default: 0] += tokens - assigned
        }

        return starts.indices.map { hour in
            SeriesPoint(
                id: hour,
                start: starts[hour],
                label: String(hour),
                total: bySource[hour].values.reduce(0, +),
                bySource: bySource[hour],
                isFuture: starts[hour] > now
            )
        }
    }

    // MARK: - Helpers

    private struct Entry {
        let day: Date
        let record: UsageRecord
    }

    /// Records carry UTC days. Each is placed on the viewer's calendar day with the same date, a deliberate
    /// simplification until hourly UTC buckets exist (see the sync contract).
    private func localizedEntries() throws -> [Entry] {
        var cache: [Date: Date] = [:]
        return try store.records().map { record in
            if let day = cache[record.day] { return Entry(day: day, record: record) }
            let date = Calendar.utcGregorian.dateComponents([.year, .month, .day], from: record.day)
            let day = calendar.date(from: date).map { calendar.startOfDay(for: $0) } ?? record.day
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
