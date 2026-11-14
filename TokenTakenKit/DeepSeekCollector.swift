import Foundation
import OSLog

/// DeepSeek CLI keeps one JSON session file per conversation under `~/.deepseek/sessions`. Only
/// `metadata.total_tokens` is recorded: messages carry no usage and subagents have no token records
/// of their own, so each session contributes its whole total to `uncategorized` on the local day of
/// `metadata.created_at`. Total-only data has no timing, so this collector emits no hourly rows.
public struct DeepSeekCollector: UsageCollector {
    public let sourceIDs = ["deepseek-cli"]

    private static let stateFormatVersion = 1
    private static let logger = Logger(subsystem: "io.github.elijah7x.TokenTaken", category: "collection")

    private let root: URL
    private let deviceID: String
    private let timeZone: TimeZone
    private let stateFile: CollectorStateFile<SavedState>?

    public init(deviceID: String, stateDirectory: URL? = nil) {
        self.init(
            deviceID: deviceID,
            home: FileManager.default.homeDirectoryForCurrentUser,
            stateDirectory: stateDirectory
        )
    }

    /// Pins the session root and the day time zone; used by tests.
    public init(deviceID: String, home: URL, timeZone: TimeZone = .current, stateDirectory: URL? = nil) {
        root = home.appendingPathComponent(".deepseek/sessions", isDirectory: true)
        self.deviceID = deviceID
        self.timeZone = timeZone
        self.stateFile = stateDirectory.map { CollectorStateFile(directory: $0, name: "deepseek-cli") }
    }

    public func collect() async throws -> CollectionBatch {
        let started = Date.now
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CollectorError.sourceUnavailable
        }

        let stamp = CollectionStamp(formatVersion: Self.stateFormatVersion, timeZone: timeZone, sourceIDs: sourceIDs)
        let files = try sessionFiles()
        let fingerprints = Fingerprints(files: files)
        if let stateFile, let saved = stateFile.load(), saved.stamp == stamp, saved.fingerprints == fingerprints {
            log(mode: "unchanged", since: started)
            return CollectionBatch(unchangedSourceIDs: Set(sourceIDs))
        }

        var aggregator = Aggregator(deviceID: deviceID, timeZone: timeZone)
        for file in files {
            let data: Data
            do {
                data = try Data(contentsOf: file)
            } catch {
                throw CollectorError.open("Could not read a DeepSeek CLI session file")
            }
            guard let session = try? JSONDecoder().decode(Session.self, from: data),
                  let metadata = session.metadata else {
                aggregator.skip()
                continue
            }
            aggregator.scan(metadata, fallbackID: file.lastPathComponent)
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
        Self.logger.info("source=deepseek-cli mode=\(mode, privacy: .public) duration_ms=\(duration, privacy: .public)")
    }

    private struct SavedState: Codable, Sendable {
        var stamp: CollectionStamp
        var fingerprints: Fingerprints
    }

    /// File name to metadata; a vanished file drops its key and forces a full scan.
    private struct Fingerprints: Codable, Hashable, Sendable {
        var files: [String: FileFingerprint]

        init(files: [URL]) {
            var result: [String: FileFingerprint] = [:]
            for file in files {
                guard let fingerprint = FileFingerprint(url: file) else { continue }
                result[file.lastPathComponent] = fingerprint
            }
            self.files = result
        }
    }

    /// Every `*.json` directly in the session root; subdirectories are left untouched.
    private func sessionFiles() throws -> [URL] {
        do {
            return try FileManager.default
                .contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey])
                .filter { $0.pathExtension == "json"
                    && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .sorted { $0.path < $1.path }
        } catch {
            throw CollectorError.open("Could not enumerate DeepSeek CLI sessions")
        }
    }

    private struct Key: Hashable {
        let day: String
        let modelID: String
    }

    private struct Aggregator {
        let deviceID: String
        let timeZone: TimeZone

        var daily: [Key: UsageRecord] = [:]
        var skipped = 0
        private var seen: Set<String> = []

        mutating func skip() {
            skipped += 1
        }

        mutating func scan(_ metadata: Metadata, fallbackID: String) {
            guard let total = metadata.totalTokens?.value, total > 0,
                  let createdAt = metadata.createdAt,
                  let date = DeepSeekCollector.createdDate(createdAt) else {
                skipped += 1
                return
            }
            let identity = (metadata.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard seen.insert(identity.isEmpty ? fallbackID : identity).inserted else { return }

            let rawModelID = (metadata.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let model = rawModelID.isEmpty ? "unknown" : rawModelID.lowercased()
            let day = UsageDay.string(from: date, in: timeZone)
            let key = Key(day: day, modelID: model)
            var row = daily[key] ?? UsageRecord(
                day: day, timeZoneID: timeZone.identifier, deviceID: deviceID,
                sourceID: "deepseek-cli", modelID: model, rawModelID: rawModelID.isEmpty ? "unknown" : rawModelID,
                counts: .zero
            )
            row.counts.uncategorized += total
            daily[key] = row
        }

        func batch() -> CollectionBatch {
            CollectionBatch(
                daily: daily.values.sorted {
                    if $0.day != $1.day { return $0.day < $1.day }
                    return $0.modelID < $1.modelID
                },
                skippedRecords: skipped
            )
        }
    }

    /// `created_at` is ISO 8601 with microsecond precision, which `ISO8601DateFormatter` rejects on
    /// some systems, so the fractional part is dropped and the rest reparsed as a fallback.
    static func createdDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: trimmed) { return date }
        guard let dot = trimmed.firstIndex(of: ".") else { return nil }
        let remainder = trimmed[trimmed.index(after: dot)...]
        guard let zone = remainder.firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) else { return nil }
        return plain.date(from: String(trimmed[..<dot]) + String(remainder[zone...]))
    }

    private struct Session: Decodable {
        let metadata: Metadata?

        enum CodingKeys: String, CodingKey {
            case metadata
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            metadata = try? values.decodeIfPresent(Metadata.self, forKey: .metadata)
        }
    }

    private struct Metadata: Decodable {
        let id: String?
        let model: String?
        let createdAt: String?
        let totalTokens: Number?

        enum CodingKeys: String, CodingKey {
            case id, model
            case createdAt = "created_at"
            case totalTokens = "total_tokens"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try? values.decodeIfPresent(String.self, forKey: .id)
            model = try? values.decodeIfPresent(String.self, forKey: .model)
            createdAt = try? values.decodeIfPresent(String.self, forKey: .createdAt)
            totalTokens = try? values.decodeIfPresent(Number.self, forKey: .totalTokens)
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
