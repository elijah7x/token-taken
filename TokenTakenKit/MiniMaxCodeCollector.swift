import Foundation
import OSLog

/// MiniMax Code writes one JSONL transcript per session under `$MINIMAX_HOME/v2/sessions`
/// (or `~/.minimax/v2/sessions/<YYYY>/<MM>/<DD>/<session>/messages.jsonl`). Per-call usage is nested
/// in `message.usage`; the sibling `message.usage.cost` object is always zero and is never a cost
/// source, so this collector only reads the four token counters.
///
/// Identity is `message_id`, which is stable across sessions and rescans, so a message copied into
/// another transcript counts once.
public struct MiniMaxCodeCollector: UsageCollector {
    public let sourceIDs = ["mcode"]

    private static let stateFormatVersion = 1
    private static let logger = Logger(subsystem: "io.github.elijah7x.TokenTaken", category: "collection")

    private let root: URL
    private let deviceID: String
    private let timeZone: TimeZone
    private let now: Date
    private let stateFile: CollectorStateFile<SavedState>?

    public init(deviceID: String, stateDirectory: URL? = nil) {
        self.init(
            deviceID: deviceID,
            home: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment,
            stateDirectory: stateDirectory
        )
    }

    /// Pins the session root and the hourly window; used by tests.
    public init(
        deviceID: String,
        home: URL,
        environment: [String: String] = [:],
        timeZone: TimeZone = .current,
        now: Date = .now,
        stateDirectory: URL? = nil
    ) {
        root = Self.sessionRoot(home: home, environment: environment)
        self.deviceID = deviceID
        self.timeZone = timeZone
        self.now = now
        self.stateFile = stateDirectory.map { CollectorStateFile(directory: $0, name: "mcode") }
    }

    static func sessionRoot(home: URL, environment: [String: String]) -> URL {
        let homeOverride = environment["MINIMAX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = homeOverride.isEmpty
            ? home.appendingPathComponent(".minimax", isDirectory: true)
            : URL(fileURLWithPath: homeOverride)
        return base.appendingPathComponent("v2/sessions", isDirectory: true)
    }

    public func collect() async throws -> CollectionBatch {
        let started = Date.now
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CollectorError.sourceUnavailable
        }

        let stamp = CollectionStamp(formatVersion: Self.stateFormatVersion, timeZone: timeZone)
        let files = try sessionFiles()
        let fingerprints = Fingerprints(files: files, root: root)
        if let stateFile, let saved = stateFile.load(), saved.stamp == stamp, saved.fingerprints == fingerprints {
            log(mode: "unchanged", since: started)
            return CollectionBatch(unchangedSourceIDs: Set(sourceIDs))
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let currentHour = calendar.dateInterval(of: .hour, for: now)!.start
        var aggregator = Aggregator(
            deviceID: deviceID, timeZone: timeZone, calendar: calendar,
            currentHour: currentHour, cutoff: currentHour.addingTimeInterval(-47 * 3_600)
        )

        for file in files {
            let data: Data
            do {
                data = try Data(contentsOf: file)
            } catch {
                throw CollectorError.open("Could not read a MiniMax Code session file")
            }
            for line in data.split(separator: 0x0A) {
                let trimmed = line.drop { $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }
                guard !trimmed.isEmpty else { continue }
                let record = trimmed.first == 0x7B
                    ? (try? JSONDecoder().decode(Record.self, from: Data(trimmed)))
                    : nil
                guard let record else {
                    aggregator.skip()
                    continue
                }
                aggregator.scan(record, line: Data(trimmed))
            }
        }

        var batch = aggregator.batch()
        if let stateFile {
            let saved = SavedState(stamp: stamp, fingerprints: fingerprints)
            batch.stateCommits = [{ try stateFile.save(saved) }]
        }
        log(mode: "full", since: started)
        return batch
    }

    private func log(mode: String, since started: Date) {
        let duration = Int((Date.now.timeIntervalSince(started) * 1_000).rounded())
        Self.logger.info("source=mcode mode=\(mode, privacy: .public) duration_ms=\(duration, privacy: .public)")
    }

    private struct SavedState: Codable, Sendable {
        var stamp: CollectionStamp
        var fingerprints: Fingerprints
    }

    /// Root-relative path to file metadata; a vanished file drops its key and forces a full scan.
    private struct Fingerprints: Codable, Hashable, Sendable {
        var files: [String: FileFingerprint]

        init(files: [URL], root: URL) {
            var result: [String: FileFingerprint] = [:]
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            for file in files {
                guard let fingerprint = FileFingerprint(url: file) else { continue }
                result[file.path.hasPrefix(prefix) ? String(file.path.dropFirst(prefix.count)) : file.path] = fingerprint
            }
            self.files = result
        }
    }

    /// Every `messages.jsonl` below the session root. A root that cannot be enumerated throws rather
    /// than reporting an empty source.
    private func sessionFiles() throws -> [URL] {
        var files: [URL] = []
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CollectorError.open("Could not enumerate MiniMax Code sessions")
        }
        for case let url as URL in enumerator where url.lastPathComponent == "messages.jsonl" {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(url)
            }
        }
        if let enumerationError { throw enumerationError }
        return files.sorted { $0.path < $1.path }
    }

    private struct Key: Hashable {
        let day: String
        let modelID: String
    }

    private struct Aggregator {
        let deviceID: String
        let timeZone: TimeZone
        let calendar: Calendar
        let currentHour: Date
        let cutoff: Date

        var daily: [Key: UsageRecord] = [:]
        var hourly: [Date: HourlyUsage] = [:]
        var skipped = 0
        private var seen: Set<String> = []

        mutating func skip() {
            skipped += 1
        }

        mutating func scan(_ record: Record, line: Data) {
            guard let message = record.message,
                  message.role == "assistant",
                  let usage = message.usage else { return }
            // A usage object with no counter at all (for example only the always-zero `cost`) has
            // nothing to count; one with some but not all valid counters is malformed.
            let counters = [usage.input, usage.cacheRead, usage.cacheWrite, usage.output]
            guard counters.contains(where: { $0 != nil }) else { return }
            guard let input = usage.input?.value, let cacheRead = usage.cacheRead?.value,
                  let cacheWrite = usage.cacheWrite?.value, let output = usage.output?.value else {
                skipped += 1
                return
            }
            guard input + cacheRead + cacheWrite + output > 0 else { return }
            guard let timestamp = message.timestamp?.value, timestamp > 0 else {
                skipped += 1
                return
            }

            let identity = (record.messageID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let key = identity.isEmpty ? "line:" + Self.fingerprint(line) : identity
            guard seen.insert(key).inserted else { return }

            let rawModelID = (message.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let model = rawModelID.isEmpty ? "unknown" : rawModelID.lowercased()
            let counts = TokenCounts(input: input, cacheRead: cacheRead, cacheWrite: cacheWrite, output: output)
            let date = Date(timeIntervalSince1970: Double(timestamp) / 1_000)

            let day = UsageDay.string(from: date, in: timeZone)
            let dailyKey = Key(day: day, modelID: model)
            var row = daily[dailyKey] ?? UsageRecord(
                day: day, timeZoneID: timeZone.identifier, deviceID: deviceID,
                sourceID: "mcode", modelID: model, rawModelID: rawModelID.isEmpty ? "unknown" : rawModelID,
                counts: .zero
            )
            row.counts += counts
            row.eventCount += 1
            daily[dailyKey] = row

            let hour = calendar.dateInterval(of: .hour, for: date)!.start
            guard hour >= cutoff, hour <= currentHour else { return }
            var hourRow = hourly[hour] ?? HourlyUsage(
                hourStart: hour, deviceID: deviceID, sourceID: "mcode",
                counts: .zero, eventCount: 0, reasoningKnown: true
            )
            hourRow.counts += counts
            hourRow.eventCount += 1
            hourly[hour] = hourRow
        }

        func batch() -> CollectionBatch {
            CollectionBatch(
                daily: daily.values.sorted {
                    if $0.day != $1.day { return $0.day < $1.day }
                    return $0.modelID < $1.modelID
                },
                hourly: hourly.values.sorted { $0.hourStart < $1.hourStart },
                skippedRecords: skipped
            )
        }

        /// Stable content fingerprint for a message that carries no `message_id`.
        private static func fingerprint(_ line: Data) -> String {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in line {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01b3
            }
            return String(hash, radix: 16)
        }
    }

    private struct Record: Decodable {
        let messageID: String?
        let message: Message?

        enum CodingKeys: String, CodingKey {
            case messageID = "message_id"
            case message
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            messageID = try? values.decodeIfPresent(String.self, forKey: .messageID)
            message = try? values.decodeIfPresent(Message.self, forKey: .message)
        }
    }

    private struct Message: Decodable {
        let role: String?
        let model: String?
        let timestamp: Number?
        let usage: Usage?

        enum CodingKeys: String, CodingKey {
            case role, model, timestamp, usage
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            role = try? values.decodeIfPresent(String.self, forKey: .role)
            model = try? values.decodeIfPresent(String.self, forKey: .model)
            timestamp = try? values.decodeIfPresent(Number.self, forKey: .timestamp)
            usage = try? values.decodeIfPresent(Usage.self, forKey: .usage)
        }
    }

    /// Only the four counters; `cost` and `totalTokens` are deliberately not decoded.
    private struct Usage: Decodable {
        let input: Number?
        let cacheRead: Number?
        let cacheWrite: Number?
        let output: Number?

        enum CodingKeys: String, CodingKey {
            case input, cacheRead, cacheWrite, output
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            input = try? values.decodeIfPresent(Number.self, forKey: .input)
            cacheRead = try? values.decodeIfPresent(Number.self, forKey: .cacheRead)
            cacheWrite = try? values.decodeIfPresent(Number.self, forKey: .cacheWrite)
            output = try? values.decodeIfPresent(Number.self, forKey: .output)
        }
    }

    /// A JSON number as a whole token count; `value` is nil when it is not a finite non-negative number.
    private struct Number: Decodable {
        let value: Int64?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            guard let number = try? container.decode(Double.self), number.isFinite,
                  number >= 0, number < 0x1p63 else {
                value = nil
                return
            }
            value = Int64(number.rounded(.towardZero))
        }
    }
}
