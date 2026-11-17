import Foundation

public struct LensBucket: Hashable, Sendable, Identifiable {
    /// Index of the bucket within its series.
    public let id: Int
    public let start: Date
    /// Exclusive.
    public let end: Date
    public let label: String
    public let counts: TokenCounts
    public var total: Int64 { counts.total }
    public let bySource: [String: TokenCounts]
    public let byModel: [String: TokenCounts]
    public let byDevice: [String: TokenCounts]
    public let cost: CostEstimate?
    public let isFuture: Bool
    /// False when hourly coverage is missing for any contributing daily device/source.
    public let isKnown: Bool
    /// False when any contributing hourly row could not report reasoning tokens, so its reasoning count is unknown, not zero.
    public let reasoningKnown: Bool

    public init(
        id: Int,
        start: Date,
        end: Date,
        label: String,
        counts: TokenCounts,
        bySource: [String: TokenCounts],
        byModel: [String: TokenCounts],
        byDevice: [String: TokenCounts],
        cost: CostEstimate?,
        isFuture: Bool,
        isKnown: Bool = true,
        reasoningKnown: Bool = true
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.label = label
        self.counts = counts
        self.bySource = bySource
        self.byModel = byModel
        self.byDevice = byDevice
        self.cost = cost
        self.isFuture = isFuture
        self.isKnown = isKnown
        self.reasoningKnown = reasoningKnown
    }
}

public struct LensSlice: Sendable {
    public let range: ClosedRange<Int>
    public let start: Date
    /// Exclusive.
    public let end: Date
    public let counts: TokenCounts
    public let bySource: [Breakdown]
    public let byModel: [Breakdown]
    public let byDevice: [Breakdown]
    public let cost: CostEstimate?
    public let hasModelDetail: Bool
    /// False when any elapsed bucket in the slice lacks full coverage; a zero total is then unknown, not measured.
    public let isKnown: Bool
    /// False when any elapsed bucket in the slice has unknown reasoning counts.
    public let reasoningKnown: Bool

    public init(
        range: ClosedRange<Int>,
        start: Date,
        end: Date,
        counts: TokenCounts,
        bySource: [Breakdown],
        byModel: [Breakdown],
        byDevice: [Breakdown],
        cost: CostEstimate?,
        hasModelDetail: Bool,
        isKnown: Bool = true,
        reasoningKnown: Bool = true
    ) {
        self.range = range
        self.start = start
        self.end = end
        self.counts = counts
        self.bySource = bySource
        self.byModel = byModel
        self.byDevice = byDevice
        self.cost = cost
        self.hasModelDetail = hasModelDetail
        self.isKnown = isKnown
        self.reasoningKnown = reasoningKnown
    }
}
