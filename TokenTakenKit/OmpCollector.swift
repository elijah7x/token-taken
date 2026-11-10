import Foundation

/// Counts oh-my-pi usage from its session JSONL (`~/.omp/agent/sessions/<encoded-cwd>/*.jsonl`, plus
/// the subagent transcripts nested one level deeper) instead of going through tokscale, which reports
/// no reasoning for this source (ADR-0003). oh-my-pi writes the pi record format and records reasoning
/// in `usage.reasoningTokens` as a breakdown inside `output`; the shared scanner subtracts it from
/// output so all five categories stay disjoint.
///
/// The scan root is deliberately fixed rather than read from `PI_CODING_AGENT_DIR`: oh-my-pi honors
/// the same variable as pi, so following it would scan one tree twice.
public struct OmpCollector: UsageCollector {
    public let sourceIDs = ["omp"]

    private let root: URL
    private let deviceID: String
    private let timeZone: TimeZone
    /// Defines "the last 48 hours" for the hourly buckets; injectable so tests can pin it.
    private let now: @Sendable () -> Date

    public init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".omp/agent/sessions"),
        deviceID: String,
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.root = root
        self.deviceID = deviceID
        self.timeZone = timeZone
        self.now = now
    }

    public func collect() async throws -> CollectionBatch {
        try autoreleasepool {
            try PiFormatScan(
                root: root, sourceID: "omp", deviceID: deviceID, timeZone: timeZone, now: now()
            ).run()
        }
    }
}
