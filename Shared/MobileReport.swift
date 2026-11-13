import Foundation

/// Report v1 for the iPhone app.
/// Contract: `docs/contracts/mobile-report.md`. This file is compiled into both TokenTakenKit and
/// the iOS app, so it stays Foundation-only and every member the writer or reader touches is public.
public enum MobileReportError: Error, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
    case unexpectedKind(String)
    case malformedDate(String)
}

/// The report a Mac writes to iCloud, decoded read-only on the phone.
/// Contract: `docs/contracts/mobile-report.md` (schema v1).
public struct MobileReport: Codable, Sendable, Equatable {
    public static let reportKind = "token-taken.mobile-report"
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let kind: String
    public let generatedAt: Date
    public let generator: Generator
    public let timeZoneID: String
    public let coverage: Coverage
    public let totals: Totals
    public let days: [Day]
    public let months: [Month]
    public let sources: [Source]

    public init(
        schemaVersion: Int = MobileReport.currentSchemaVersion,
        kind: String = MobileReport.reportKind,
        generatedAt: Date,
        generator: Generator,
        timeZoneID: String,
        coverage: Coverage,
        totals: Totals,
        days: [Day],
        months: [Month],
        sources: [Source]
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.generatedAt = generatedAt
        self.generator = generator
        self.timeZoneID = timeZoneID
        self.coverage = coverage
        self.totals = totals
        self.days = days
        self.months = months
        self.sources = sources
    }

    public struct Generator: Codable, Sendable, Equatable {
        public let deviceId: String
        public let displayName: String
        public let appVersion: String

        public init(deviceId: String, displayName: String, appVersion: String) {
            self.deviceId = deviceId
            self.displayName = displayName
            self.appVersion = appVersion
        }
    }

    public struct Coverage: Codable, Sendable, Equatable {
        public let devices: [Device]

        public init(devices: [Device]) {
            self.devices = devices
        }

        public struct Device: Codable, Sendable, Equatable {
            public let displayName: String
            public let lastWriteUTC: Date
            public let status: Status

            public init(displayName: String, lastWriteUTC: Date, status: Status) {
                self.displayName = displayName
                self.lastWriteUTC = lastWriteUTC
                self.status = status
            }
        }

        public enum Status: String, Codable, Sendable, Equatable {
            case ok
            case stale
            case partial
            case unavailable

            public init(from decoder: any Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                // A newer Mac build may add a status; treat it as partial instead of failing the whole read.
                self = Status(rawValue: raw) ?? .partial
            }
        }
    }

    public struct Totals: Codable, Sendable, Equatable {
        public let today: TokenSummary
        public let last30Days: TokenSummary
        public let thisMonth: TokenSummary
        public let allTime: TokenSummary

        public init(today: TokenSummary, last30Days: TokenSummary, thisMonth: TokenSummary, allTime: TokenSummary) {
            self.today = today
            self.last30Days = last30Days
            self.thisMonth = thisMonth
            self.allTime = allTime
        }
    }

    public struct TokenSummary: Codable, Sendable, Equatable {
        public let total: Int64
        public let input: Int64
        public let output: Int64
        public let cacheRead: Int64
        public let cacheWrite: Int64
        public let reasoning: Int64

        public init(total: Int64, input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64, reasoning: Int64) {
            self.total = total
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.reasoning = reasoning
        }
    }

    public struct Day: Codable, Sendable, Equatable {
        public let day: String
        public let total: Int64

        public init(day: String, total: Int64) {
            self.day = day
            self.total = total
        }
    }

    public struct Month: Codable, Sendable, Equatable {
        public let month: String
        public let total: Int64
        public let sources: [Slice]
        public let models: [Slice]

        public init(month: String, total: Int64, sources: [Slice], models: [Slice]) {
            self.month = month
            self.total = total
            self.sources = sources
            self.models = models
        }
    }

    public struct Slice: Codable, Sendable, Equatable {
        public let id: String
        public let total: Int64

        public init(id: String, total: Int64) {
            self.id = id
            self.total = total
        }
    }

    public struct Source: Codable, Sendable, Equatable {
        public let id: String
        public let displayName: String

        public init(id: String, displayName: String) {
            self.id = id
            self.displayName = displayName
        }
    }
}

extension MobileReport {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw MobileReportError.unsupportedSchemaVersion(schemaVersion)
        }
        let kind = try container.decode(String.self, forKey: .kind)
        guard kind == Self.reportKind else {
            throw MobileReportError.unexpectedKind(kind)
        }
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        self.generator = try container.decode(Generator.self, forKey: .generator)
        self.timeZoneID = try container.decode(String.self, forKey: .timeZoneID)
        self.coverage = try container.decode(Coverage.self, forKey: .coverage)
        self.totals = try container.decode(Totals.self, forKey: .totals)
        self.days = try container.decode([Day].self, forKey: .days)
        self.months = try container.decode([Month].self, forKey: .months)
        self.sources = try container.decode([Source].self, forKey: .sources)
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        // Mac builds may write fractional seconds; accept both spellings.
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = ISO8601Text.parse(text) else {
                throw MobileReportError.malformedDate(text)
            }
            return date
        }
        return decoder
    }

    public static func decode(_ data: Data) throws -> MobileReport {
        try makeDecoder().decode(MobileReport.self, from: data)
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // ISO 8601 UTC with second precision, ending in `Z`, exactly as the contract requires.
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public enum ISO8601Text {
    public static func parse(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}

extension MobileReport {
    /// The calendar month containing `generatedAt` in the generator's zone, matching `totals.thisMonth`;
    /// nil when that month has no usage, never an older month's breakdown.
    public var currentMonth: Month? {
        let key = String(Self.dayKey(generatedAt, zone: reportTimeZone).prefix(7))
        return months.first { $0.month == key }
    }

    public var last12Months: [Month] {
        Array(months.sorted { $0.month < $1.month }.suffix(12))
    }

    /// First and last `YYYY-MM-DD` covered by `totals.last30Days`: the 30 local days ending on the day of
    /// `generatedAt`. `days` lists only active days, so it cannot supply the endpoints.
    public var last30DayRange: (start: String, end: String)? {
        let zone = reportTimeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let start = calendar.date(byAdding: .day, value: -29, to: generatedAt) else { return nil }
        return (Self.dayKey(start, zone: zone), Self.dayKey(generatedAt, zone: zone))
    }

    private var reportTimeZone: TimeZone {
        TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 0)!
    }

    private static func dayKey(_ date: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public func displayName(forSource id: String) -> String {
        sources.first { $0.id == id }?.displayName ?? id
    }
}
