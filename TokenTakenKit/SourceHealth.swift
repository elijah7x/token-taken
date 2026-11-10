import Foundation

public struct SourceHealth: Codable, Sendable, Hashable, Identifiable {
    public let sourceID: String
    public var id: String { sourceID }
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var recordCount: Int
    public var errorMessage: String?

    public init(
        sourceID: String,
        lastAttempt: Date? = nil,
        lastSuccess: Date? = nil,
        recordCount: Int = 0,
        errorMessage: String? = nil
    ) {
        self.sourceID = sourceID
        self.lastAttempt = lastAttempt
        self.lastSuccess = lastSuccess
        self.recordCount = recordCount
        self.errorMessage = errorMessage
    }
}
