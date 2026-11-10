import Foundation

/// Query filters shared by every CLI command. Empty sets mean "no restriction".
public struct UsageFilter: Sendable, Equatable {
    public var sources: Set<String>
    public var models: Set<String>
    public var devices: Set<String>
    /// Inclusive `YYYY-MM-DD` label bounds in the viewer's calendar.
    public var since: String?
    public var until: String?

    public init(sources: Set<String> = [], models: Set<String> = [], devices: Set<String> = [], since: String? = nil, until: String? = nil) {
        self.sources = sources
        self.models = models
        self.devices = devices
        self.since = since
        self.until = until
    }

    public var isEmpty: Bool {
        sources.isEmpty && models.isEmpty && devices.isEmpty && since == nil && until == nil
    }

    public var hasDateRange: Bool { since != nil || until != nil }

    /// Date bounds compare the record's own calendar-date label, not a converted instant.
    public func matches(_ record: UsageRecord) -> Bool {
        if !sources.isEmpty, !sources.contains(record.sourceID) { return false }
        if !models.isEmpty, !models.contains(record.modelID) { return false }
        if !devices.isEmpty, !devices.contains(record.deviceID) { return false }
        if let since, record.day < since { return false }
        if let until, record.day > until { return false }
        return true
    }
}

/// Applies `UsageFilter` before aggregation so totals never include filtered-out rows.
/// Hourly rows carry no model dimension; model filters only affect daily records.
public struct FilteredUsageStore: UsageStore {
    public let base: any UsageStore
    public let filter: UsageFilter
    public let timeZone: TimeZone

    public init(store: any UsageStore, filter: UsageFilter, timeZone: TimeZone = .current) {
        self.base = store
        self.filter = filter
        self.timeZone = timeZone
    }

    public func records() throws -> [UsageRecord] {
        guard !filter.isEmpty else { return try base.records() }
        return try base.records().filter(filter.matches)
    }

    public func hourly() throws -> [HourlyUsage] {
        guard !filter.isEmpty else { return try base.hourly() }
        return try base.hourly().filter { row in
            if !filter.sources.isEmpty, !filter.sources.contains(row.sourceID) { return false }
            if !filter.devices.isEmpty, !filter.devices.contains(row.deviceID) { return false }
            let day = UsageDay.string(from: row.hourStart, in: timeZone)
            if let since = filter.since, day < since { return false }
            if let until = filter.until, day > until { return false }
            return true
        }
    }

    public var devices: [Device] {
        guard !filter.devices.isEmpty else { return base.devices }
        return base.devices.filter { filter.devices.contains($0.id) }
    }
}

/// One exported daily record. Column order is fixed by `UsageCSV.columns`.
public struct ExportRow: Encodable, Sendable, Equatable {
    public let day: String
    public let timeZoneID: String
    public let deviceID: String
    public let sourceID: String
    public let modelID: String
    public let rawModelID: String
    public let input: Int64
    public let cacheRead: Int64
    public let cacheWrite: Int64
    public let output: Int64
    public let reasoning: Int64
    public let uncategorized: Int64
    public let total: Int64
    public let eventCount: Int64

    public init(_ record: UsageRecord) {
        day = record.day
        timeZoneID = record.timeZoneID
        deviceID = record.deviceID
        sourceID = record.sourceID
        modelID = record.modelID
        rawModelID = record.rawModelID
        input = record.counts.input
        cacheRead = record.counts.cacheRead
        cacheWrite = record.counts.cacheWrite
        output = record.counts.output
        reasoning = record.counts.reasoning
        uncategorized = record.counts.uncategorized
        total = record.counts.total
        eventCount = record.eventCount
    }
}

/// RFC 4180 CSV output for `export --format csv`.
public enum UsageCSV {
    public static let columns = [
        "day", "timeZoneID", "deviceID", "sourceID", "modelID", "rawModelID",
        "input", "cacheRead", "cacheWrite", "output", "reasoning", "uncategorized", "total", "eventCount",
    ]

    public static let header = columns.joined(separator: ",")

    /// Quotes or escapes a field only when it contains a comma, quote, CR, or LF.
    public static func escaped(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func fields(_ row: ExportRow) -> [String] {
        [
            row.day, row.timeZoneID, row.deviceID, row.sourceID, row.modelID, row.rawModelID,
            String(row.input), String(row.cacheRead), String(row.cacheWrite), String(row.output),
            String(row.reasoning), String(row.uncategorized), String(row.total), String(row.eventCount),
        ]
    }

    public static func line(_ row: ExportRow) -> String {
        fields(row).map(escaped).joined(separator: ",")
    }

    /// Header plus one line per row, each terminated by CRLF as RFC 4180 requires.
    public static func document(_ rows: [ExportRow]) -> String {
        ([header] + rows.map(line)).map { $0 + "\r\n" }.joined()
    }
}

/// Aggregate plus the effective inclusive date labels reported in the JSON envelope.
public struct ExportedSummary: Sendable {
    public let summary: UsageSummary
    public let from: String?
    public let to: String?

    public init(summary: UsageSummary, from: String?, to: String?) {
        self.summary = summary
        self.from = from
        self.to = to
    }
}

public enum UsageExport {
    /// Inclusive day labels for a named period, matching `UsageAggregator`'s boundaries:
    /// period start through today in the viewer's zone, with a nil lower bound for all time.
    public static func dayLabels(for period: Period, timeZone: TimeZone, now: Date = .now) -> (since: String?, until: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        let start: Date?
        switch period {
        case .day: start = today
        case .month: start = calendar.dateInterval(of: .month, for: now)?.start
        case .year: start = calendar.dateInterval(of: .year, for: now)?.start
        case .all: start = nil
        }
        return (start.map { UsageDay.string(from: $0, in: timeZone) }, UsageDay.string(from: today, in: timeZone))
    }

    /// Daily records after filtering, in a stable order so exports are reproducible.
    public static func rows(from store: any UsageStore, filter: UsageFilter, timeZone: TimeZone = .current) throws -> [ExportRow] {
        let filtered = FilteredUsageStore(store: store, filter: filter, timeZone: timeZone)
        return try filtered.records()
            .map(ExportRow.init)
            .sorted {
                ($0.day, $0.deviceID, $0.sourceID, $0.modelID, $0.rawModelID)
                    < ($1.day, $1.deviceID, $1.sourceID, $1.modelID, $1.rawModelID)
            }
    }

    /// Period summaries use `UsageAggregator` unchanged. `--since`/`--until` have no aggregator
    /// API, so a custom range sums the filtered daily records with the all-time path instead.
    public static func summary(
        from store: any UsageStore,
        period: Period,
        filter: UsageFilter,
        timeZone: TimeZone,
        priceTable: PriceTable,
        now: Date = .now
    ) throws -> ExportedSummary {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let filtered = FilteredUsageStore(store: store, filter: filter, timeZone: timeZone)
        let aggregator = UsageAggregator(store: filtered, calendar: calendar, now: now, priceTable: priceTable)

        guard filter.hasDateRange else {
            let summary = try aggregator.summary(for: period)
            // All-time has no lower bound, so its start date is not an effective range endpoint.
            return ExportedSummary(
                summary: summary,
                from: period == .all ? nil : UsageDay.string(from: summary.start, in: timeZone),
                to: UsageDay.string(from: calendar.date(byAdding: .day, value: -1, to: summary.end) ?? summary.start, in: timeZone)
            )
        }

        let all = try aggregator.summary(for: .all)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let start = filter.since.flatMap { UsageDay.date(from: $0, in: timeZone) } ?? all.start
        // `until` is inclusive, so the aggregator's exclusive end is the following day.
        let end = filter.until.flatMap { UsageDay.date(from: $0, in: timeZone) }
            .flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } ?? tomorrow
        let summary = UsageSummary(
            period: .all, start: min(start, end), end: end, total: all.total,
            bySource: all.bySource, byModel: all.byModel, byDevice: all.byDevice,
            series: all.series, cost: all.cost, devices: all.devices
        )
        return ExportedSummary(summary: summary, from: filter.since, to: filter.until)
    }
}
