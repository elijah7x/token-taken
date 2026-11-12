import Foundation

public enum TokenCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case input, cacheRead, cacheWrite, output, reasoning

    public var id: String { rawValue }
}

public struct TokenCounts: Hashable, Codable, Sendable {
    public var input: Int64
    public var cacheRead: Int64
    public var cacheWrite: Int64
    public var output: Int64
    public var reasoning: Int64
    public var uncategorized: Int64
    /// Anthropic 1-hour cache writes, a SUBSET of `cacheWrite` rather than a sixth category:
    /// `0 <= cacheWrite1h <= cacheWrite`. It is billed at its own rate, contributes nothing to `total`,
    /// and defaults to zero in initialization and older Codable data, where the whole cache write is
    /// treated as a 5-minute write.
    public var cacheWrite1h: Int64

    public init(input: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0, output: Int64 = 0, reasoning: Int64 = 0, uncategorized: Int64 = 0, cacheWrite1h: Int64 = 0) {
        self.input = input
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.output = output
        self.reasoning = reasoning
        self.uncategorized = uncategorized
        self.cacheWrite1h = cacheWrite1h
    }

    private enum CodingKeys: String, CodingKey {
        case input, cacheRead, cacheWrite, output, reasoning, uncategorized, cacheWrite1h
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        input = try values.decode(Int64.self, forKey: .input)
        cacheRead = try values.decode(Int64.self, forKey: .cacheRead)
        cacheWrite = try values.decode(Int64.self, forKey: .cacheWrite)
        output = try values.decode(Int64.self, forKey: .output)
        reasoning = try values.decode(Int64.self, forKey: .reasoning)
        uncategorized = try values.decodeIfPresent(Int64.self, forKey: .uncategorized) ?? 0
        cacheWrite1h = try values.decodeIfPresent(Int64.self, forKey: .cacheWrite1h) ?? 0
    }

    /// Sum of the disjoint categories. `cacheWrite1h` is a subset of `cacheWrite`, never an addend.
    public var total: Int64 { input + cacheRead + cacheWrite + output + reasoning + uncategorized }

    public subscript(_ category: TokenCategory) -> Int64 {
        get {
            switch category {
            case .input: input
            case .cacheRead: cacheRead
            case .cacheWrite: cacheWrite
            case .output: output
            case .reasoning: reasoning
            }
        }
        set {
            switch category {
            case .input: input = newValue
            case .cacheRead: cacheRead = newValue
            case .cacheWrite: cacheWrite = newValue
            case .output: output = newValue
            case .reasoning: reasoning = newValue
            }
        }
    }

    public static let zero = TokenCounts()

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            output: lhs.output + rhs.output,
            reasoning: lhs.reasoning + rhs.reasoning,
            uncategorized: lhs.uncategorized + rhs.uncategorized,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h
        )
    }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs = lhs + rhs
    }
}

public struct UsageRecord: Hashable, Codable, Sendable {
    public var day: String
    public var timeZoneID: String
    public var deviceID: String
    public var sourceID: String
    public var modelID: String
    public var rawModelID: String
    public var counts: TokenCounts
    public var eventCount: Int64

    public init(day: String, timeZoneID: String, deviceID: String, sourceID: String, modelID: String, rawModelID: String? = nil, counts: TokenCounts, eventCount: Int64 = 0) {
        self.day = day
        self.timeZoneID = timeZoneID
        self.deviceID = deviceID
        self.sourceID = sourceID
        self.modelID = modelID
        self.rawModelID = rawModelID ?? modelID
        self.counts = counts
        self.eventCount = eventCount
    }

    public var dayInterval: DateInterval? {
        guard let zone = TimeZone(identifier: timeZoneID),
              let start = UsageDay.date(from: day, in: zone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.dateInterval(of: .day, for: start)
    }
}

public struct HourlyUsage: Hashable, Codable, Sendable {
    public var hourStart: Date
    public var deviceID: String
    public var sourceID: String
    public var counts: TokenCounts
    public var eventCount: Int64
    public var reasoningKnown: Bool

    public init(hourStart: Date, deviceID: String, sourceID: String, counts: TokenCounts, eventCount: Int64, reasoningKnown: Bool) {
        self.hourStart = hourStart
        self.deviceID = deviceID
        self.sourceID = sourceID
        self.counts = counts
        self.eventCount = eventCount
        self.reasoningKnown = reasoningKnown
    }
}

/// A device is either this Mac or other Macs (`mac`) or one account whose usage Cursor reports centrally
/// (`account`). Account devices are not hardware: several Macs signed in to the same account store the same
/// rows under the same account device id.
public enum DeviceKind: String, Codable, Sendable, Hashable {
    case mac, account
}

public struct Device: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let kind: DeviceKind

    public init(id: String, name: String, kind: DeviceKind = .mac) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind
    }

    /// Snapshots and caches written before schema 5 have no `kind`; every device they held was a Mac.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decodeIfPresent(DeviceKind.self, forKey: .kind) ?? .mac
    }
}

public enum Period: String, CaseIterable, Codable, Sendable, Identifiable {
    case day, week, month, year, all

    public var id: String { rawValue }
}

/// One group of a breakdown. Lists of breakdowns are sorted by `counts.total`, descending.
public struct Breakdown: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let counts: TokenCounts

    public init(id: String, name: String, counts: TokenCounts) {
        self.id = id
        self.name = name
        self.counts = counts
    }
}

public struct SeriesPoint: Hashable, Sendable, Identifiable {
    /// Index of the bucket within its series.
    public let id: Int
    public let start: Date
    public let label: String
    public let total: Int64
    public let bySource: [String: Int64]
    public let isFuture: Bool
    /// False when hourly coverage is missing for any contributing daily device/source.
    public let isKnown: Bool

    public init(id: Int, start: Date, label: String, total: Int64, bySource: [String: Int64], isFuture: Bool, isKnown: Bool = true) {
        self.id = id
        self.start = start
        self.label = label
        self.total = total
        self.bySource = bySource
        self.isFuture = isFuture
        self.isKnown = isKnown
    }
}

public struct CostEstimate: Hashable, Sendable {
    /// Covers priced tokens only; positive `unpricedTokens` means the estimate is incomplete.
    public let estimatedUSD: Double
    public let unpricedTokens: Int64
    public let priceTableVersion: String

    public init(estimatedUSD: Double, unpricedTokens: Int64, priceTableVersion: String) {
        self.estimatedUSD = estimatedUSD
        self.unpricedTokens = unpricedTokens
        self.priceTableVersion = priceTableVersion
    }
}

public struct UsageSummary: Sendable {
    public let period: Period
    public let start: Date
    /// Exclusive.
    public let end: Date
    public let total: TokenCounts
    public let bySource: [Breakdown]
    public let byModel: [Breakdown]
    public let byDevice: [Breakdown]
    public let series: [SeriesPoint]
    public let cost: CostEstimate
    public let devices: [Device]

    public init(
        period: Period, start: Date, end: Date, total: TokenCounts,
        bySource: [Breakdown], byModel: [Breakdown], byDevice: [Breakdown],
        series: [SeriesPoint], cost: CostEstimate, devices: [Device]
    ) {
        self.period = period
        self.start = start
        self.end = end
        self.total = total
        self.bySource = bySource
        self.byModel = byModel
        self.byDevice = byDevice
        self.series = series
        self.cost = cost
        self.devices = devices
    }
}

public protocol UsageStore: Sendable {
    /// Throws rather than returning partial data, so callers never report incomplete totals as complete.
    func records() throws -> [UsageRecord]
    func hourly() throws -> [HourlyUsage]
    var devices: [Device] { get }
}

extension Calendar {
    static let utcGregorian: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
