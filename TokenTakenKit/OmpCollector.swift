import Foundation

/// Counts oh-my-pi usage from its session JSONL trees instead of going through tokscale, which
/// reports no reasoning for this source (ADR-0003). oh-my-pi writes the pi record format and records
/// reasoning in `usage.reasoningTokens` as a breakdown inside `output`; the shared scanner subtracts
/// it from output so all five categories stay disjoint.
///
/// oh-my-pi keeps two session trees: `~/.omp/agent/sessions` (encoded cwd, with subagent transcripts
/// nested one level deeper) and `~/.omp/omp-worker-mcp/sessions` (worker MCP sessions). Both are read
/// by the same scanner under one dedupe set, because their entry ids belong to the same namespace.
///
/// The scan roots are deliberately fixed rather than read from `PI_CODING_AGENT_DIR`: oh-my-pi honors
/// the same variable as pi, so following it would scan one tree twice.
public struct OmpCollector: UsageCollector {
    public let sourceIDs = ["omp"]

    public static let defaultRoots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".omp/agent/sessions"),
            home.appendingPathComponent(".omp/omp-worker-mcp/sessions"),
        ]
    }()

    private let roots: [URL]
    private let deviceID: String
    private let timeZone: TimeZone
    /// When set, scan results are persisted here and later refreshes scan only what changed.
    private let stateDirectory: URL?
    /// Defines the upper bound (`currentHour`) for hourly buckets and future-date guards; injectable so tests can pin it.
    private let now: @Sendable () -> Date

    public init(
        deviceID: String,
        timeZone: TimeZone = .current,
        stateDirectory: URL? = nil,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.init(
            roots: Self.defaultRoots, deviceID: deviceID, timeZone: timeZone,
            stateDirectory: stateDirectory, now: now
        )
    }

    /// Scans explicit trees; used by tests and by any caller that pins the session locations.
    public init(
        roots: [URL],
        deviceID: String,
        timeZone: TimeZone = .current,
        stateDirectory: URL? = nil,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.roots = roots
        self.deviceID = deviceID
        self.timeZone = timeZone
        self.stateDirectory = stateDirectory
        self.now = now
    }

    public func collect() async throws -> CollectionBatch {
        try autoreleasepool {
            try PiFormatScan(
                roots: roots, sourceID: "omp", deviceID: deviceID, timeZone: timeZone,
                stateDirectory: stateDirectory, now: now()
            ).run()
        }
    }
}
