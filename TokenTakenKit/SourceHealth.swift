import Foundation

public struct SourceHealth: Codable, Sendable, Hashable, Identifiable {
    public enum State: String, Codable, Sendable {
        case ok, unavailable, failed, stale
    }

    public let sourceID: String
    public var id: String { sourceID }
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var recordCount: Int
    public var errorMessage: String?
    public var skippedRecords: Int
    public var state: State

    public init(
        sourceID: String,
        lastAttempt: Date? = nil,
        lastSuccess: Date? = nil,
        recordCount: Int = 0,
        errorMessage: String? = nil,
        skippedRecords: Int = 0,
        state: State = .ok
    ) {
        self.sourceID = sourceID
        self.lastAttempt = lastAttempt
        self.lastSuccess = lastSuccess
        self.recordCount = recordCount
        self.errorMessage = errorMessage
        self.skippedRecords = skippedRecords
        self.state = state
    }

    public func markingStale(now: Date = .now, after interval: TimeInterval = 24 * 60 * 60) -> SourceHealth {
        var result = self
        if state == .ok, lastSuccess.map({ now.timeIntervalSince($0) > interval }) ?? true {
            result.state = .stale
        }
        return result
    }
}
