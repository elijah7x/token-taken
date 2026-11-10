import Foundation

public struct CollectionBatch: Sendable {
    public var daily: [UsageRecord]
    public var hourly: [HourlyUsage]
    public var skippedRecords: Int
    public var unavailableSourceIDs: Set<String>
    /// Sources whose collection failed in this batch (sourceID to a path-free message); their cache is kept.
    public var failedSourceIDs: [String: String]

    public init(
        daily: [UsageRecord] = [],
        hourly: [HourlyUsage] = [],
        skippedRecords: Int = 0,
        unavailableSourceIDs: Set<String> = [],
        failedSourceIDs: [String: String] = [:]
    ) {
        self.daily = daily
        self.hourly = hourly
        self.skippedRecords = skippedRecords
        self.unavailableSourceIDs = unavailableSourceIDs
        self.failedSourceIDs = failedSourceIDs
    }
}

public protocol UsageCollector: Sendable {
    var sourceIDs: [String] { get }
    func collect() async throws -> CollectionBatch
}

public enum CollectorError: LocalizedError, Sendable {
    case sourceUnavailable
    case process(String)
    case invalidOutput(String)
    case open(String)
    case sql(String)

    public var errorDescription: String? {
        switch self {
        case .sourceUnavailable: "Source data is unavailable"
        case .process(let message), .invalidOutput(let message), .open(let message), .sql(let message):
            CollectionRunner.sanitizeErrorMessage(message)
        }
    }
}

public enum UsageDay {
    public static func date(from string: String, in timeZone: TimeZone = .current) -> Date? {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, string.count == 10,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              Self.string(from: date, in: timeZone) == string else { return nil }
        return calendar.startOfDay(for: date)
    }

    public static func string(from date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}
