import Foundation

/// Pure construction of the v1 mobile report from the merged daily records the app already shows.
/// Contract: `docs/contracts/mobile-report.md`. No file access, no pricing, no paths.
public enum MobileReportBuilder {
    /// The contract caps the monthly model breakdown at eight named models plus `other`.
    public static let topModelCount = 8
    /// Reserved slice id; never a real model id.
    public static let otherSliceID = "other"

    /// Builds one report.
    ///
    /// - Parameters:
    ///   - records: every readable daily record across all readable devices, already merged.
    ///   - device: this Mac's sync identity; its id becomes the report filename.
    ///   - generatedAt: publication instant; truncated to whole seconds because v1 dates are second-precision.
    ///   - timeZone: generating Mac's zone. All calendar windows and the `YYYY-MM-DD`/`YYYY-MM` labels are local to it.
    ///   - localStatus: this Mac's own coverage state, normally `ok`.
    ///   - remotes: status of every other Mac read through sync.
    public static func build(
        records: [UsageRecord],
        device: Device,
        appVersion: String,
        generatedAt: Date,
        timeZone: TimeZone,
        localStatus: MobileReport.Coverage.Status = .ok,
        remotes: [RemoteDeviceStatus] = []
    ) -> MobileReport {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let generated = wholeSecond(generatedAt)
        let today = calendar.startOfDay(for: generated)
        let todayEnd = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        // 30 local days ending today, inclusive.
        let last30Start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let monthStart = calendar.dateInterval(of: .month, for: generated)?.start ?? today

        var todayCounts = TokenCounts.zero
        var last30Counts = TokenCounts.zero
        var monthCounts = TokenCounts.zero
        var allTimeCounts = TokenCounts.zero
        var dayTotals: [String: Int64] = [:]
        var monthTotals: [String: Int64] = [:]
        var monthSources: [String: [String: Int64]] = [:]
        var monthModels: [String: [String: Int64]] = [:]

        for record in records {
            let counts = record.counts
            let tokens = counts.total
            allTimeCounts += counts
            if let day = UsageDay.date(from: record.day, in: timeZone) {
                if day == today { todayCounts += counts }
                if day >= last30Start, day < todayEnd { last30Counts += counts }
                if day >= monthStart, day < todayEnd { monthCounts += counts }
            }
            dayTotals[record.day, default: 0] += tokens
            let month = String(record.day.prefix(7))
            monthTotals[month, default: 0] += tokens
            monthSources[month, default: [:]][record.sourceID, default: 0] += tokens
            monthModels[month, default: [:]][record.modelID, default: 0] += tokens
        }

        let days = dayTotals
            .filter { $0.value != 0 }
            .map { MobileReport.Day(day: $0.key, total: $0.value) }
            .sorted { $0.day < $1.day }

        let months = monthTotals
            .filter { $0.value != 0 }
            .map { month, total in
                MobileReport.Month(
                    month: month,
                    total: total,
                    sources: slices(monthSources[month] ?? [:]),
                    models: topModels(monthModels[month] ?? [:])
                )
            }
            .sorted { $0.month < $1.month }

        let sources = Set(monthSources.values.flatMap { $0.keys })
            .sorted()
            .map { MobileReport.Source(id: $0, displayName: SourceCatalog.info(for: $0).name) }

        return MobileReport(
            generatedAt: generated,
            generator: .init(deviceId: device.id, displayName: device.name, appVersion: appVersion),
            timeZoneID: timeZone.identifier,
            coverage: .init(devices: coverage(device: device, generatedAt: generated,
                localStatus: localStatus, remotes: remotes)),
            totals: .init(
                today: summary(todayCounts),
                last30Days: summary(last30Counts),
                thisMonth: summary(monthCounts),
                allTime: summary(allTimeCounts)
            ),
            days: days,
            months: months,
            sources: sources
        )
    }

    /// This Mac's coverage state from its own collection health, matching the sync reader's rule.
    public static func localStatus(_ health: [SourceHealth]) -> MobileReport.Coverage.Status {
        health.contains { entry in
            (entry.state != .ok && entry.state != .notInstalled) || entry.skippedRecords > 0
        } ? .partial : .ok
    }

    // MARK: - Parts

    private static func coverage(
        device: Device,
        generatedAt: Date,
        localStatus: MobileReport.Coverage.Status,
        remotes: [RemoteDeviceStatus]
    ) -> [MobileReport.Coverage.Device] {
        let local = MobileReport.Coverage.Device(
            displayName: device.name, lastWriteUTC: generatedAt, status: localStatus)
        let others = remotes.compactMap { remote -> MobileReport.Coverage.Device? in
            // v1 `lastWriteUTC` is a required date, so a device with no readable identity is left out
            // instead of publishing a fabricated timestamp.
            guard let lastWrite = remote.lastWrite else { return nil }
            return .init(
                displayName: remote.displayName,
                lastWriteUTC: wholeSecond(lastWrite),
                status: .init(remote.state)
            )
        }.sorted {
            $0.displayName != $1.displayName
                ? $0.displayName < $1.displayName
                : $0.lastWriteUTC < $1.lastWriteUTC
        }
        return [local] + others
    }

    private static func slices(_ totals: [String: Int64]) -> [MobileReport.Slice] {
        totals
            .filter { $0.value != 0 }
            .map { MobileReport.Slice(id: $0.key, total: $0.value) }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.id < $1.id }
    }

    /// Eight largest models, descending, plus one `other` entry when more than eight exist.
    private static func topModels(_ totals: [String: Int64]) -> [MobileReport.Slice] {
        let sorted = totals
            .filter { $0.value != 0 }
            .map { MobileReport.Slice(id: $0.key, total: $0.value) }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.id < $1.id }
        guard sorted.count > topModelCount else { return sorted }
        let rest = sorted.dropFirst(topModelCount).reduce(Int64(0)) { $0 + $1.total }
        return Array(sorted.prefix(topModelCount)) + [MobileReport.Slice(id: otherSliceID, total: rest)]
    }

    private static func summary(_ counts: TokenCounts) -> MobileReport.TokenSummary {
        // `total` keeps uncategorized tokens: it is not the sum of the five named components.
        MobileReport.TokenSummary(
            total: counts.total,
            input: counts.input,
            output: counts.output,
            cacheRead: counts.cacheRead,
            cacheWrite: counts.cacheWrite,
            reasoning: counts.reasoning
        )
    }

    private static func wholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}

extension MobileReport.Coverage.Status {
    /// The sync reader publishes the same four states.
    public init(_ state: RemoteDeviceStatus.State) {
        switch state {
        case .ok: self = .ok
        case .stale: self = .stale
        case .partial: self = .partial
        case .unavailable: self = .unavailable
        }
    }
}
