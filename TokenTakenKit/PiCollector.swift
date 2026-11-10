import CoreFoundation
import Foundation

/// Counts pi usage from its session JSONL (`~/.pi/agent/sessions/<encoded-cwd>/*.jsonl`) instead of
/// going through tokscale, which keys pi assistant usage on `message.responseId`. Short Ollama-style
/// response ids collide between different calls, so that key undercounts (ADR-0003). This collector
/// keys on the entry id plus the immutable event fields, so distinct calls that share a response id
/// are counted twice and a copied entry is counted once.
public struct PiCollector: UsageCollector {
    public let sourceIDs = ["pi"]

    private let root: URL
    private let deviceID: String
    private let timeZone: TimeZone
    /// Defines "the last 48 hours" for the hourly buckets; injectable so tests can pin it.
    private let now: @Sendable () -> Date

    public init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions"),
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
        try PiFormatScan(
            root: root, sourceID: "pi", deviceID: deviceID, timeZone: timeZone, now: now()
        ).run()
    }
}

/// Scans pi-format session JSONL. pi and oh-my-pi write the same record layout, so both collectors
/// share this scanner and differ only in their scan root and source id.
///
/// Counted record types (tokscale's set, kept so pi totals stay comparable with the pinned engine):
/// - `message` with `message.role == "assistant"`: the billed reply.
/// - `message` with `message.role == "toolResult"` and a `message.usage`: the call behind a tool.
///   pi normally bills this under `tools/summaries`; a message that names its own model keeps it.
/// - `compaction`: the `/compact` summarization call, usage at the record root.
/// - `branch_summary`: the branch summarization call, usage at the record root.
/// - `usage`: standalone accounting such as cache warming; it names its billed model at the root.
///   A model-less `usage` record inherits the session's current model, like tokscale's legacy row.
///
/// `session`, `title`, `title_change`, `session_info`, `model_change`, `thinking_level_change`,
/// `custom` and other control records are skipped without counting as malformed. A `model_change`
/// record updates the session's current model so a later model-less `usage` record can be attributed.
///
/// Token categories follow `docs/contracts/statistics.md`: `input` already excludes cache tokens, and
/// both pi and oh-my-pi report reasoning inside `output` (their `totalTokens` excludes it), so
/// reasoning is subtracted from output and stored separately.
///
/// Divergences from tokscale's pi lane, all in the direction of losing no usage:
/// - Event identity never uses `message.responseId`; see `record` for the key.
/// - A usage record without a usable timestamp is placed at the file's modification time instead of
///   being dropped, and a reply that names no model falls back to the session's current model, then
///   `unknown`.
/// - A file without a `session` header is still read record by record instead of being discarded.
///
/// Daily totals cover every event; hourly buckets keep only the last 48 hours at UTC hour resolution.
struct PiFormatScan: Sendable {
    /// pi groups model-less tool, compaction, and branch-summary usage in this bucket.
    static let toolsSummariesModel = "tools/summaries"
    /// Only recent usage needs hour resolution; older events roll into the daily totals only.
    static let hourlyWindow: TimeInterval = 48 * 3_600
    /// Tool results can be enormous and cannot carry usage, so an over-long line is dropped instead
    /// of buffered whole. Same ceiling as TokenTracker's collector.
    static let maximumLineBytes = 64 << 20
    /// Placeholder epoch timestamps used to land usage in 1970; treated as missing.
    static let minimumTimestamp = Date(timeIntervalSince1970: 1_577_836_800)

    let root: URL
    let sourceID: String
    let deviceID: String
    let timeZone: TimeZone
    let now: Date

    func run() throws -> CollectionBatch {
        let files = try sessionFiles()
        var totals = Totals(sourceID: sourceID, deviceID: deviceID, timeZone: timeZone, now: now)

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        for file in files {
            let modificationDate = Self.modificationDate(of: file) ?? now
            var state = FileState()
            try Self.forEachLine(in: file, onLine: { line in
                totals.scan(
                    line: line,
                    state: &state,
                    fallbackDate: modificationDate,
                    fractional: fractional,
                    plain: plain
                )
            }, onOverlongLine: {
                totals.skippedRecords += 1
            })
        }

        return totals.batch()
    }

    private func sessionFiles() throws -> [URL] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw CollectorError.sourceUnavailable
        }
        guard isDirectory.boolValue else {
            throw CollectorError.invalidOutput("\(sourceID) session root is not a directory: \(root.path)")
        }
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private struct FileState {
        var isFirstLine = true
        /// The session's currently selected model, used only to attribute a model-less `usage` record.
        var currentModel: String?
    }

    private struct DailyKey: Hashable {
        let day: String
        let modelID: String
    }

    private struct DailyTotals {
        var rawModelID: String
        var counts = TokenCounts.zero
        var eventCount: Int64 = 0
    }

    private struct HourlyTotals {
        var counts = TokenCounts.zero
        var eventCount: Int64 = 0
        var reasoningKnown = true
    }

    private struct Totals {
        let sourceID: String
        let deviceID: String
        let timeZone: TimeZone
        let now: Date

        var daily: [DailyKey: DailyTotals] = [:]
        var hourly: [Date: HourlyTotals] = [:]
        var skippedRecords = 0
        var seen: Set<String> = []

        mutating func scan(
            line rawLine: Data,
            state: inout FileState,
            fallbackDate: Date,
            fractional: ISO8601DateFormatter,
            plain: ISO8601DateFormatter
        ) {
            var line = rawLine
            if state.isFirstLine {
                state.isFirstLine = false
                // A byte-order mark decodes cleanly but breaks the first record's parse.
                if line.starts(with: [0xEF, 0xBB, 0xBF]) { line = line.dropFirst(3) }
            }
            let trimmed = line.drop { $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }
            guard !trimmed.isEmpty else { return }

            guard let object = (try? JSONSerialization.jsonObject(with: trimmed)) as? [String: Any],
                  let type = object["type"] as? String else {
                skippedRecords += 1
                return
            }

            switch type {
            case "model_change":
                if let model = Self.text(object["modelId"]) { state.currentModel = model }
            case "message":
                guard let message = object["message"] as? [String: Any] else { return }
                let role = Self.text(message["role"])
                let loggedModel = Self.text(message["model"])
                if role == "assistant" {
                    // Only a reply (or a `model_change`) advances the session's selected model.
                    if let loggedModel { state.currentModel = loggedModel }
                }
                guard let usage = message["usage"] as? [String: Any] else { return }
                let model: String?
                switch role {
                case "assistant": model = loggedModel ?? state.currentModel
                case "toolResult": model = loggedModel ?? PiFormatScan.toolsSummariesModel
                default: return
                }
                record(
                    object: object, type: type, model: model, usage: usage, messageTimestamp: message["timestamp"],
                    line: rawLine, fallbackDate: fallbackDate, fractional: fractional, plain: plain
                )
            case "compaction", "branch_summary":
                guard let usage = object["usage"] as? [String: Any] else { return }
                record(
                    object: object, type: type, model: Self.text(object["model"]) ?? PiFormatScan.toolsSummariesModel,
                    usage: usage, messageTimestamp: nil, line: rawLine, fallbackDate: fallbackDate,
                    fractional: fractional, plain: plain
                )
            case "usage":
                guard let usage = object["usage"] as? [String: Any] else { return }
                record(
                    object: object, type: type, model: Self.text(object["model"]) ?? state.currentModel,
                    usage: usage, messageTimestamp: nil, line: rawLine, fallbackDate: fallbackDate,
                    fractional: fractional, plain: plain
                )
            default:
                // Every other record type carries no billable usage.
                return
            }
        }

        private mutating func record(
            object: [String: Any],
            type: String,
            model: String?,
            usage: [String: Any],
            messageTimestamp: Any?,
            line: Data,
            fallbackDate: Date,
            fractional: ISO8601DateFormatter,
            plain: ISO8601DateFormatter
        ) {
            let (counts, reasoningReported) = Self.tokenCounts(from: usage)
            guard counts.total > 0 else { return }
            let date = Self.eventDate(
                messageTimestamp: messageTimestamp,
                recorded: object["timestamp"],
                fallback: fallbackDate,
                fractional: fractional,
                plain: plain
            )

            let rawModelID = model ?? "unknown"
            let modelID = rawModelID.lowercased()

            // Identity is session-independent and never the response id: fork/branch copies repeat
            // the entry id and the usage in a new file and must collapse, while two calls that share
            // a short response id differ in entry id, timestamp, or counts and must both count.
            let identifier = Self.text(object["id"]).map { "\(type):\($0)" }
                ?? "\(type):line:\(Self.fingerprint(line))"
            let key = [
                identifier,
                String(Int64((date.timeIntervalSince1970 * 1_000).rounded())),
                rawModelID,
                String(counts.input), String(counts.cacheRead), String(counts.cacheWrite),
                String(counts.output), String(counts.reasoning),
            ].joined(separator: "|")
            guard seen.insert(key).inserted else { return }

            let day = UsageDay.string(from: date, in: timeZone)
            let dailyKey = DailyKey(day: day, modelID: modelID)
            var dailyTotals = daily[dailyKey] ?? DailyTotals(rawModelID: rawModelID)
            dailyTotals.counts += counts
            dailyTotals.eventCount += 1
            daily[dailyKey] = dailyTotals

            let hourStart = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3_600).rounded(.down) * 3_600)
            guard hourStart >= now.addingTimeInterval(-PiFormatScan.hourlyWindow), hourStart <= now else { return }
            var hourlyTotals = hourly[hourStart] ?? HourlyTotals()
            hourlyTotals.counts += counts
            hourlyTotals.eventCount += 1
            // A bucket is reasoning-known only when every event in it reported reasoning.
            hourlyTotals.reasoningKnown = hourlyTotals.reasoningKnown && reasoningReported
            hourly[hourStart] = hourlyTotals
        }

        func batch() -> CollectionBatch {
            let dailyRecords = daily.map { key, totals in
                UsageRecord(
                    day: key.day,
                    timeZoneID: timeZone.identifier,
                    deviceID: deviceID,
                    sourceID: sourceID,
                    modelID: key.modelID,
                    rawModelID: totals.rawModelID,
                    counts: totals.counts,
                    eventCount: totals.eventCount
                )
            }.sorted {
                if $0.day != $1.day { return $0.day < $1.day }
                return $0.modelID < $1.modelID
            }
            let hourlyRecords = hourly.map { start, totals in
                HourlyUsage(
                    hourStart: start,
                    deviceID: deviceID,
                    sourceID: sourceID,
                    counts: totals.counts,
                    eventCount: totals.eventCount,
                    reasoningKnown: totals.reasoningKnown
                )
            }.sorted { $0.hourStart < $1.hourStart }
            return CollectionBatch(daily: dailyRecords, hourly: hourlyRecords, skippedRecords: skippedRecords)
        }

        /// Splits reasoning out of output. pi and oh-my-pi both report reasoning as a breakdown of
        /// `output` and print a `totalTokens` that excludes it, so adding it again would double count.
        static func tokenCounts(from usage: [String: Any]) -> (TokenCounts, Bool) {
            let rawOutput = max(0, integer(usage["output"]) ?? 0)
            let reportedReasoning = integer(usage["reasoningTokens"]) ?? integer(usage["reasoning"])
            let reasoning = min(rawOutput, max(0, reportedReasoning ?? 0))
            let counts = TokenCounts(
                input: max(0, integer(usage["input"]) ?? 0),
                cacheRead: max(0, integer(usage["cacheRead"]) ?? 0),
                cacheWrite: max(0, integer(usage["cacheWrite"]) ?? 0),
                output: rawOutput - reasoning,
                reasoning: reasoning
            )
            return (counts, reportedReasoning != nil)
        }

        static func eventDate(
            messageTimestamp: Any?,
            recorded: Any?,
            fallback: Date,
            fractional: ISO8601DateFormatter,
            plain: ISO8601DateFormatter
        ) -> Date {
            // An assistant message's own timestamp is the request start; the entry timestamp is
            // when the record was persisted, so the message timestamp wins when it is usable.
            if let milliseconds = integer(messageTimestamp), milliseconds > 0 {
                let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
                if date >= PiFormatScan.minimumTimestamp { return date }
            }
            if let text = recorded as? String,
               let date = fractional.date(from: text) ?? plain.date(from: text),
               date >= PiFormatScan.minimumTimestamp {
                return date
            }
            // A record without a usable timestamp still bills tokens; the file's modification time
            // is the best available placement.
            return fallback
        }

        private static func text(_ value: Any?) -> String? {
            guard let value = value as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        /// A JSON number, excluding booleans (which bridge to `NSNumber` too).
        private static func integer(_ value: Any?) -> Int64? {
            guard let value, let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return nil
            }
            let double = number.doubleValue
            guard double.isFinite else { return nil }
            return Int64(double.rounded(.towardZero))
        }

        /// Stable content fingerprint for a record that carries no entry id.
        private static func fingerprint(_ line: Data) -> String {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in line {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01b3
            }
            return String(hash, radix: 16)
        }
    }

    /// Splits a JSONL file into lines without loading it whole.
    private static func forEachLine(
        in url: URL,
        onLine: (Data) -> Void,
        onOverlongLine: () -> Void
    ) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }

        let newline = UInt8(ascii: "\n")
        var pending = Data()
        var discardingOverlongLine = false

        while let chunk = try file.read(upToCount: 262_144), !chunk.isEmpty {
            var rest = chunk[...]
            while let index = rest.firstIndex(of: newline) {
                if !discardingOverlongLine {
                    pending.append(contentsOf: rest[rest.startIndex..<index])
                    onLine(pending)
                }
                discardingOverlongLine = false
                pending.removeAll(keepingCapacity: true)
                rest = rest[rest.index(after: index)...]
            }
            guard !discardingOverlongLine else { continue }
            if pending.count + rest.count > maximumLineBytes {
                pending.removeAll(keepingCapacity: true)
                discardingOverlongLine = true
                onOverlongLine()
            } else {
                pending.append(contentsOf: rest)
            }
        }
        if !pending.isEmpty, !discardingOverlongLine {
            onLine(pending)
        }
    }
}
