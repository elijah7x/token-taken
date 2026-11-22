import CoreFoundation
import Foundation
import OSLog
import SQLite3

/// Counts Devin usage from the CLI session database and the Desktop ACP event log instead of going
/// through tokscale (ADR-0009). The engine dates a CLI turn by its row write time minus the recorded
/// duration, which moves 302M tokens onto the wrong local day on this machine; a turn is billed at
/// `metadata.started_generation_at`. Token categories, dedupe, non-assistant drops and model
/// resolution stay identical to the engine's Devin parser so totals match apart from the day label.
///
/// CLI rows are 1.2 GB of prompts and responses, so the query streams row by row and only the
/// metadata fields below are decoded; no message text is retained or logged.
public struct DevinCollector: UsageCollector {
    public let sourceIDs = ["devin"]

    /// Bumped whenever the persisted state layout or the counting rules change.
    private static let stateFormatVersion = 1
    private static let logger = Logger(subsystem: "io.github.elijah7x.TokenTaken", category: "collection")

    private let databaseURL: URL
    private let eventsDirectory: URL
    private let deviceID: String
    private let timeZone: TimeZone
    private let now: Date
    private let stateFile: CollectorStateFile<SavedState>?

    public init(deviceID: String, stateDirectory: URL? = nil) {
        self.init(
            home: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment,
            deviceID: deviceID,
            stateDirectory: stateDirectory
        )
    }

    /// Explicit locations for tests and for any caller that pins them.
    init(
        home: URL,
        environment: [String: String],
        deviceID: String,
        timeZone: TimeZone = .current,
        now: Date = .now,
        stateDirectory: URL? = nil
    ) {
        let dataRoot: URL = if let path = environment["XDG_DATA_HOME"], !path.isEmpty {
            URL(fileURLWithPath: path)
        } else {
            home.appendingPathComponent(".local/share")
        }
        databaseURL = dataRoot.appendingPathComponent("devin/cli/sessions.db")
        eventsDirectory = home.appendingPathComponent("Library/Application Support/Devin/User/acp-events")
        self.deviceID = deviceID
        self.timeZone = timeZone
        self.now = now
        self.stateFile = stateDirectory.map { CollectorStateFile(directory: $0, name: "devin") }
    }

    public func collect() async throws -> CollectionBatch {
        try autoreleasepool { try scan() }
    }

    private func scan() throws -> CollectionBatch {
        let started = Date.now
        let manager = FileManager.default
        let hasDatabase = manager.fileExists(atPath: databaseURL.path)
        let hasEvents = manager.fileExists(atPath: eventsDirectory.path)
        guard hasDatabase || hasEvents else { throw CollectorError.sourceUnavailable }

        let stamp = CollectionStamp(formatVersion: Self.stateFormatVersion, timeZone: timeZone, sourceIDs: sourceIDs)
        // Fingerprint before reading: a write that lands during the scan must trigger a full scan next time.
        let eventsSnapshot = Self.eventsFingerprint(eventsDirectory)
        let fingerprints = Fingerprints(databaseURL: databaseURL, events: eventsSnapshot.fingerprint)
        if let stateFile, !eventsSnapshot.hadError, fingerprints.hasInput, let saved = stateFile.load(),
           saved.stamp == stamp, saved.fingerprints == fingerprints {
            log(mode: "unchanged", since: started)
            return CollectionBatch(unchangedSourceIDs: Set(sourceIDs))
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        var aggregator = Aggregator(
            deviceID: deviceID, timeZone: timeZone, calendar: calendar,
            currentHour: currentHour,
            maxDate: now.addingTimeInterval(86_400)
        )
        var seen: Set<String> = []
        var cliSessions: Set<String> = []
        var titles: [String: TitleMatch] = [:]
        var hasReadFailure = eventsSnapshot.hadError

        if hasDatabase {
            try collectCLI(into: &aggregator, seen: &seen, sessions: &cliSessions, titles: &titles)
        }
        if hasEvents {
            let desktopFailed = collectDesktop(
                titles: titles,
                cliSessions: cliSessions,
                into: &aggregator,
                fingerprintFailed: eventsSnapshot.hadError
            )
            if desktopFailed { hasReadFailure = true }
        } else if eventsSnapshot.hadError {
            aggregator.skipped += 1
        }

        var batch = aggregator.batch()
        if let stateFile, !hasReadFailure {
            let saved = SavedState(stamp: stamp, fingerprints: fingerprints)
            batch.stateCommits = [{ try stateFile.save(saved) }]
        }
        log(mode: "full", since: started)
        return batch
    }

    private func log(mode: String, since started: Date) {
        let duration = Int((Date.now.timeIntervalSince(started) * 1_000).rounded())
        Self.logger.info("source=devin mode=\(mode, privacy: .public) duration_ms=\(duration, privacy: .public)")
    }

    private struct SavedState: Codable, Sendable {
        var stamp: CollectionStamp
        var fingerprints: Fingerprints
    }

    private struct Fingerprints: Codable, Hashable, Sendable {
        var database: FileFingerprint?
        var wal: FileFingerprint?
        var events: EventsFingerprint

        init(databaseURL: URL, events: EventsFingerprint) {
            database = FileFingerprint(url: databaseURL)
            wal = FileFingerprint(url: URL(fileURLWithPath: databaseURL.path + "-wal"))
            // `-shm` is the shared-memory index over the WAL, not content: any process opening the database
            // rewrites it, so watching it would rescan the whole 1 GB database without a real change.
            self.events = events
        }

        /// Without an input file an "unchanged" answer would hide a source that disappeared.
        var hasInput: Bool { database != nil || events.fileCount > 0 }
    }

    private struct EventsFingerprint: Codable, Hashable, Sendable {
        var fileCount: Int
        var totalSize: UInt64
        var latestModification: Double
        /// Order-independent hash of every event file's path, size and modification time.
        var filesHash: UInt64

        static let empty = EventsFingerprint(
            fileCount: 0, totalSize: 0, latestModification: 0, filesHash: 0
        )
    }

    private static func eventsFingerprint(_ directory: URL) -> (fingerprint: EventsFingerprint, hadError: Bool) {
        var result = EventsFingerprint.empty
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return (result, false) }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var hadError = false
        guard let enumerator = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            errorHandler: { _, _ in
                hadError = true
                return true
            }
        ) else {
            return (result, true)
        }
        for case let url as URL in enumerator {
            guard url.pathExtension == "ndjson" else { continue }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch {
                hadError = true
                continue
            }
            guard values.isRegularFile == true else { continue }
            let size = UInt64(values.fileSize ?? 0)
            let modified = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            result.fileCount += 1
            result.totalSize += size
            result.latestModification = max(result.latestModification, modified)
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in url.path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
            hash = (hash ^ size) &* 0x100_0000_01b3
            hash = (hash ^ modified.bitPattern) &* 0x100_0000_01b3
            result.filesHash &+= hash
        }
        return (result, hadError)
    }

    // MARK: - Devin CLI

    private func collectCLI(
        into aggregator: inout Aggregator,
        seen: inout Set<String>,
        sessions: inout Set<String>,
        titles: inout [String: TitleMatch]
    ) throws {
        try SQLiteSnapshotReader.withReadableDatabase(
            at: databaseURL,
            temporaryDirectory: FileManager.default.temporaryDirectory
        ) { db in
            guard try SQLiteSnapshotReader.tableExists(db, "sessions") else {
                // A database without its sessions table cannot be read, and must not look like an empty source.
                throw CollectorError.sql("Devin database has no sessions table")
            }
            titles = try titleLookup(db)
            guard try SQLiteSnapshotReader.tableExists(db, "message_nodes") else { return }

            let statement = try SQLiteSnapshotReader.prepare(db, """
                SELECT m.row_id, m.session_id, m.chat_message, m.created_at, s.model
                FROM message_nodes m JOIN sessions s ON m.session_id = s.id
                ORDER BY m.row_id;
                """)
            defer { sqlite3_finalize(statement) }
            while true {
                let step = sqlite3_step(statement)
                guard step != SQLITE_DONE else { break }
                guard step == SQLITE_ROW else { throw SQLiteSnapshotReader.lastError(db) }
                switch Self.parseCLI(
                    rowID: sqlite3_column_int64(statement, 0),
                    sessionID: text(statement, 1),
                    chatMessage: text(statement, 2),
                    rowCreatedAt: sqlite3_column_int64(statement, 3),
                    sessionModel: text(statement, 4)
                ) {
                case .counted(let row):
                    // Lowest row_id wins, which is also the earliest write, so a duplicate never moves a turn.
                    guard seen.insert(row.key).inserted else { continue }
                    sessions.insert(row.sessionID)
                    aggregator.record(timestamp: row.timestamp, modelID: row.modelID, counts: row.counts)
                case .ignored:
                    continue
                case .skipped:
                    aggregator.skipped += 1
                }
            }
        }
    }

    /// `title -> CLI session`, used only to suppress Desktop usage the CLI already counted.
    /// An ambiguous title resolves to no session.
    private func titleLookup(_ db: OpaquePointer) throws -> [String: TitleMatch] {
        let statement = try SQLiteSnapshotReader.prepare(db, """
            SELECT id, title, model FROM sessions
            WHERE title IS NOT NULL AND TRIM(title) != '';
            """)
        defer { sqlite3_finalize(statement) }
        var lookup: [String: TitleMatch] = [:]
        while true {
            let step = sqlite3_step(statement)
            guard step != SQLITE_DONE else { break }
            guard step == SQLITE_ROW else { throw SQLiteSnapshotReader.lastError(db) }
            let sessionID = text(statement, 0)
            guard let title = Self.trimmed(text(statement, 1)) else { continue }
            if let existing = lookup[title] {
                switch existing {
                case .matched(let known, _):
                    if known != sessionID { lookup[title] = .ambiguous }
                case .ambiguous:
                    continue
                }
            } else {
                lookup[title] = .matched(sessionID: sessionID, model: Self.trimmed(text(statement, 2)))
            }
        }
        return lookup
    }

    private enum ParsedRow {
        case counted(CliRow)
        /// Not an assistant turn, or a turn that carried no usage at all.
        case ignored
        /// Assistant usage that could not be dated or attributed, counted as a skipped record.
        case skipped
    }

    private struct CliRow {
        let key: String
        let sessionID: String
        let timestamp: Int64
        let modelID: String
        let counts: TokenCounts
    }

    private static func parseCLI(
        rowID: Int64,
        sessionID: String,
        chatMessage: String,
        rowCreatedAt: Int64,
        sessionModel: String
    ) -> ParsedRow {
        guard let data = chatMessage.data(using: .utf8),
              let message = try? JSONDecoder().decode(ChatMessage.self, from: data) else {
            return .skipped
        }
        guard message.role == "assistant" else { return .ignored }
        let metadata = message.metadata
        // A fused session id is never a model, and `adaptive` is a router, not a model.
        guard let model = trimmed(metadata?.generationModel) ?? trimmed(sessionModel),
              model.lowercased() != "adaptive" else {
            return .skipped
        }

        let metrics = metadata?.metrics
        // `response_dimensions` is deliberately unread: it equals input + cache_creation, so counting it
        // would double every cache-write turn.
        let input = max(metrics?.inputTokens?.value ?? 0, 0)
        let cacheRead = max(metrics?.cacheReadTokens?.value ?? 0, 0)
        let cacheWrite = max(metrics?.cacheCreationTokens?.value ?? 0, 0)
        var output = max(metrics?.outputTokens?.value ?? 0, 0)
        if input + cacheRead + cacheWrite + output == 0 {
            // Rows written before the provider reported categories carry only a total, which the
            // engine (and this collector) reads as output.
            guard let total = metadata?.numTokens?.value, total > 0 else { return .ignored }
            output = total
        }

        guard let timestamp = turnTimestamp(metadata: metadata, rowCreatedAt: rowCreatedAt) else {
            return .skipped
        }
        let requestID = trimmed(metadata?.requestID)
        let key = requestID.map { "devin-cli:\(sessionID):request:\($0)" }
            ?? "devin-cli:\(sessionID):row:\(rowID)"
        return .counted(CliRow(
            key: key,
            sessionID: sessionID,
            timestamp: timestamp,
            modelID: model,
            counts: TokenCounts(input: input, cacheRead: cacheRead, cacheWrite: cacheWrite, output: output)
        ))
    }

    /// The request instant is the billed event. `metadata.created_at` is stamped mid-generation and
    /// `message_nodes.created_at` is the row write time, a median 32 minutes later.
    private static func turnTimestamp(metadata: Metadata?, rowCreatedAt: Int64) -> Int64? {
        if let value = metadata?.startedGenerationAt, let ms = milliseconds(value), ms > 0 { return ms }
        if let value = metadata?.createdAt, let ms = milliseconds(value), ms > 0 { return ms }
        guard rowCreatedAt > 0 else { return nil }
        if rowCreatedAt >= 1_000_000_000_000 { return rowCreatedAt }
        let (ms, overflow) = rowCreatedAt.multipliedReportingOverflow(by: 1_000)
        return overflow ? nil : ms
    }

    // MARK: - Devin Desktop

    private struct DesktopFileResult {
        var records: [DesktopRecord] = []
        var skipped = 0
        var readFailed = false
    }

    private struct DesktopRecord {
        let sessionID: String
        let timestamp: Int64
        let modelID: String
        let counts: TokenCounts
    }

    /// `cognition.ai/*` usage updates are cumulative across the file: input and the caches overwrite,
    /// output adds.
    private struct DesktopUsage {
        var input: Int64 = 0
        var cacheRead: Int64 = 0
        var cacheWrite: Int64 = 0
        var output: Int64 = 0
        var model: String?
        var timestamp: Int64?
    }

    private enum TitleMatch {
        case matched(sessionID: String, model: String?)
        case ambiguous
    }

    /// Desktop usage whose title resolves to a session the CLI already counted is dropped. No Mac has
    /// written `acp-events/` yet, so this path is covered by fixtures only.
    private func collectDesktop(
        titles: [String: TitleMatch],
        cliSessions: Set<String>,
        into aggregator: inout Aggregator,
        fingerprintFailed: Bool
    ) -> Bool {
        let scan = Self.eventFiles(in: eventsDirectory)
        var hadFailure = scan.hadError || fingerprintFailed
        if hadFailure {
            aggregator.skipped += 1
        }
        for file in scan.files {
            let result = desktopRecords(file: file, titles: titles)
            aggregator.skipped += result.skipped
            if result.readFailed { hadFailure = true }
            for record in result.records where !cliSessions.contains(record.sessionID) {
                aggregator.record(timestamp: record.timestamp, modelID: record.modelID, counts: record.counts)
            }
        }
        return hadFailure
    }

    private static func eventFiles(in directory: URL) -> (files: [URL], hadError: Bool) {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        var hadError = false
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            errorHandler: { _, _ in
                hadError = true
                return true
            }
        ) else {
            return ([], true)
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "ndjson" else { continue }
            let isRegularFile: Bool
            do {
                isRegularFile = try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            } catch {
                hadError = true
                continue
            }
            guard isRegularFile else { continue }
            files.append(url)
        }
        return (files.sorted { $0.path < $1.path }, hadError)
    }

    private func desktopRecords(file: URL, titles: [String: TitleMatch]) -> DesktopFileResult {
        var result = DesktopFileResult()
        let fallback = Self.modificationMilliseconds(of: file)
        let fileSession = file.deletingPathExtension().lastPathComponent
        var title: String?
        var acp: DesktopUsage?
        var legacy: [DesktopRecord] = []
        do {
            try Self.forEachLine(at: file) { line in
                let trimmedLine = line.drop { $0 == 0x20 || $0 == 0x0D || $0 == 0x09 || $0 == 0x0A }
                guard !trimmedLine.isEmpty else { return }
                guard let entry = Self.jsonObject(Data(trimmedLine)) else {
                    result.skipped += 1
                    return
                }
                guard let notification = entry["notification"] as? [String: Any] else { return }
                let update = notification["sessionUpdate"] as? String
                if update == "session_info_update" {
                    if let value = Self.trimmed(notification["title"] as? String) { title = value }
                    return
                }
                if update == "usage_update", let fields = Self.usageFields(notification) {
                    var usage = acp ?? DesktopUsage()
                    usage.input = fields["input"] ?? usage.input
                    usage.cacheRead = fields["cache_read"] ?? usage.cacheRead
                    usage.cacheWrite = fields["cache_write"] ?? usage.cacheWrite
                    usage.output += fields["output"] ?? 0
                    if usage.model == nil { usage.model = Self.desktopModel(notification) }
                    if let timestamp = Self.desktopTimestamp(notification) { usage.timestamp = timestamp }
                    acp = usage
                    return
                }
                guard let usage = Self.legacyUsage(notification) else { return }
                let counts = TokenCounts(
                    input: max(Self.integer(usage["input_tokens"]) ?? 0, 0),
                    cacheRead: max(Self.integer(usage["cache_read_tokens"]) ?? 0, 0),
                    cacheWrite: max(Self.integer(usage["cache_creation_tokens"]) ?? 0, 0),
                    output: max(Self.integer(usage["output_tokens"]) ?? 0, 0)
                )
                guard counts.total > 0 else { return }
                let identity = Self.desktopIdentity(
                    titles: titles, fileSession: fileSession, title: title,
                    hint: Self.desktopModel(notification)
                )
                legacy.append(DesktopRecord(
                    sessionID: identity.sessionID,
                    timestamp: Self.desktopTimestamp(notification) ?? fallback,
                    modelID: identity.model,
                    counts: counts
                ))
            }
        } catch {
            result.skipped += 1
            result.readFailed = true
            return result
        }

        if let acp {
            // A cumulative input already includes the cached prefix.
            let counts = TokenCounts(
                input: max(acp.input - acp.cacheRead, 0),
                cacheRead: acp.cacheRead,
                cacheWrite: acp.cacheWrite,
                output: acp.output
            )
            guard counts.total > 0 else { return result }
            let identity = Self.desktopIdentity(
                titles: titles, fileSession: fileSession, title: title, hint: acp.model
            )
            result.records = [DesktopRecord(
                sessionID: identity.sessionID,
                timestamp: acp.timestamp ?? fallback,
                modelID: identity.model,
                counts: counts
            )]
            return result
        }
        result.records = legacy
        return result
    }

    private static func desktopIdentity(
        titles: [String: TitleMatch],
        fileSession: String,
        title: String?,
        hint: String?
    ) -> (sessionID: String, model: String) {
        var sessionID = fileSession
        var resolved: String?
        if let title, let match = titles[title], case .matched(let matchedID, let matchedModel) = match {
            sessionID = matchedID
            resolved = matchedModel
        }
        let model = trimmed(resolved) ?? trimmed(hint)
        guard let model, model.lowercased() != "adaptive" else { return (sessionID, "devin") }
        return (sessionID, model)
    }

    private static func usageFields(_ notification: [String: Any]) -> [String: Int64]? {
        guard let meta = notification["_meta"] as? [String: Any] else { return nil }
        var fields: [String: Int64] = [:]
        for (name, key) in [
            ("input", "cognition.ai/inputTokens"),
            ("cache_read", "cognition.ai/cachedReadTokens"),
            ("cache_write", "cognition.ai/cachedWriteTokens"),
            ("output", "cognition.ai/outputTokens"),
        ] {
            guard let value = integer(meta[key]) else { continue }
            fields[name] = max(value, 0)
        }
        return fields.isEmpty ? nil : fields
    }

    private static func desktopModel(_ notification: [String: Any]) -> String? {
        for keys in [
            ["content", "metadata", "generation_model"],
            ["metadata", "generation_model"],
            ["_meta", "cognition.ai/model"],
        ] {
            if let text = trimmed(value(notification, keys) as? String) { return text }
        }
        return nil
    }

    private static func desktopTimestamp(_ notification: [String: Any]) -> Int64? {
        for keys in [["content", "metadata", "created_at"], ["metadata", "created_at"], ["created_at"], ["timestamp"]] {
            if let text = value(notification, keys) as? String, let ms = parseTimestampString(text) { return ms }
        }
        return nil
    }

    private static func legacyUsage(_ notification: [String: Any]) -> [String: Any]? {
        for keys in [
            ["content", "metadata", "metrics"],
            ["metadata", "metrics"],
            ["metrics"],
            ["content", "metadata"],
            ["metadata"],
        ] {
            if let usage = value(notification, keys) as? [String: Any] { return usage }
        }
        return nil
    }

    private static func value(_ object: [String: Any], _ keys: [String]) -> Any? {
        var current: Any? = object
        for key in keys {
            guard let dictionary = current as? [String: Any] else { return nil }
            current = dictionary[key]
        }
        return current
    }

    private static func integer(_ raw: Any?) -> Int64? {
        guard let value = raw else { return nil }
        switch value {
        case let number as NSNumber:
            // JSON booleans bridge to NSNumber; they are not counts.
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let double = number.doubleValue
            guard double.isFinite, abs(double) < 9.2e18 else { return nil }
            return Int64(double.rounded(.towardZero))
        case let text as String:
            return LenientInteger(parsing: text).value
        default:
            return nil
        }
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        return try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
    }

    /// Streams a file's lines so a large event log is never held in memory.
    private static func forEachLine(at url: URL, _ body: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            pending.append(chunk)
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 0x0A) {
                try body(Data(pending[start..<newline]))
                start = pending.index(after: newline)
            }
            pending.removeSubrange(pending.startIndex..<start)
        }
        if !pending.isEmpty { try body(pending) }
    }

    private static func modificationMilliseconds(of url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return 0 }
        return Int64((modified.timeIntervalSince1970 * 1_000).rounded())
    }

    // MARK: - JSON field types

    private struct ChatMessage: Decodable {
        let role: String?
        let metadata: Metadata?

        enum CodingKeys: String, CodingKey { case role, metadata }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            role = try? values.decodeIfPresent(String.self, forKey: .role)
            metadata = try? values.decodeIfPresent(Metadata.self, forKey: .metadata)
        }
    }

    private struct Metadata: Decodable {
        let requestID: String?
        let generationModel: String?
        let numTokens: LenientInteger?
        let startedGenerationAt: TimestampValue?
        let createdAt: TimestampValue?
        let metrics: Metrics?

        enum CodingKeys: String, CodingKey {
            case requestID = "request_id"
            case generationModel = "generation_model"
            case numTokens = "num_tokens"
            case startedGenerationAt = "started_generation_at"
            case createdAt = "created_at"
            case metrics
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            requestID = try? values.decodeIfPresent(String.self, forKey: .requestID)
            generationModel = try? values.decodeIfPresent(String.self, forKey: .generationModel)
            numTokens = try? values.decodeIfPresent(LenientInteger.self, forKey: .numTokens)
            startedGenerationAt = try? values.decodeIfPresent(TimestampValue.self, forKey: .startedGenerationAt)
            createdAt = try? values.decodeIfPresent(TimestampValue.self, forKey: .createdAt)
            metrics = try? values.decodeIfPresent(Metrics.self, forKey: .metrics)
        }
    }

    private struct Metrics: Decodable {
        let inputTokens: LenientInteger?
        let outputTokens: LenientInteger?
        let cacheReadTokens: LenientInteger?
        let cacheCreationTokens: LenientInteger?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadTokens = "cache_read_tokens"
            case cacheCreationTokens = "cache_creation_tokens"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            inputTokens = try? values.decodeIfPresent(LenientInteger.self, forKey: .inputTokens)
            outputTokens = try? values.decodeIfPresent(LenientInteger.self, forKey: .outputTokens)
            cacheReadTokens = try? values.decodeIfPresent(LenientInteger.self, forKey: .cacheReadTokens)
            cacheCreationTokens = try? values.decodeIfPresent(LenientInteger.self, forKey: .cacheCreationTokens)
        }
    }

    /// A JSON number or numeric string; booleans and non-finite values are not counts.
    private struct LenientInteger: Decodable {
        let value: Int64?

        init(parsing text: String) {
            value = Self.parse(text)
        }

        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let number = try? single.decode(Double.self), number.isFinite, abs(number) < 9.2e18 {
                value = Int64(number.rounded(.towardZero))
            } else if let text = try? single.decode(String.self) {
                value = Self.parse(text)
            } else {
                value = nil
            }
        }

        private static func parse(_ text: String) -> Int64? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let value = Int64(trimmed) { return value }
            guard let number = Double(trimmed), number.isFinite, abs(number) < 9.2e18 else { return nil }
            return Int64(number.rounded(.towardZero))
        }
    }

    private struct TimestampValue: Decodable {
        let string: String?
        let number: Double?

        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let text = try? single.decode(String.self) {
                string = text
                number = nil
            } else if let value = try? single.decode(Double.self) {
                string = nil
                number = value
            } else {
                string = nil
                number = nil
            }
        }
    }

    // MARK: - Time parsing

    // `ISO8601DateFormatter` is documented as thread-safe, so collectors running in parallel may share it.
    private nonisolated(unsafe) static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// ISO-8601 with an offset, else a bare epoch in seconds or milliseconds.
    private static func parseTimestampString(_ value: String) -> Int64? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let date = fractionalFormatter.date(from: text) ?? plainFormatter.date(from: text) {
            return Int64((date.timeIntervalSince1970 * 1_000).rounded())
        }
        guard let numeric = Int64(text), numeric > 0 else { return nil }
        return numeric >= 1_000_000_000_000 ? numeric : numeric * 1_000
    }

    private static func milliseconds(_ value: TimestampValue) -> Int64? {
        if let text = value.string { return parseTimestampString(text) }
        guard let number = value.number, number.isFinite, number > 0, number < 9.2e18 else { return nil }
        let rounded = Int64(number.rounded())
        return rounded >= 1_000_000_000_000 ? rounded : rounded * 1_000
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Aggregation

    private struct Key: Hashable {
        let day: String
        let modelID: String
    }

    private struct Aggregator {
        let deviceID: String
        let timeZone: TimeZone
        let calendar: Calendar
        let currentHour: Date
        let maxDate: Date

        var daily: [Key: UsageRecord] = [:]
        var hourly: [Date: HourlyUsage] = [:]
        var skipped = 0

        mutating func record(timestamp: Int64, modelID rawModelID: String, counts: TokenCounts) {
            guard timestamp > 0 else {
                skipped += 1
                return
            }
            let model = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !model.isEmpty else {
                skipped += 1
                return
            }
            let date = Date(timeIntervalSince1970: Double(timestamp) / 1_000)
            guard date <= maxDate,
                  let hour = calendar.dateInterval(of: .hour, for: date)?.start else {
                skipped += 1
                return
            }
            let day = UsageDay.string(from: date, in: timeZone)
            let key = Key(day: day, modelID: model)
            var record = daily[key] ?? UsageRecord(
                day: day, timeZoneID: timeZone.identifier, deviceID: deviceID,
                sourceID: "devin", modelID: model, rawModelID: rawModelID, counts: .zero
            )
            record.rawModelID = min(record.rawModelID, rawModelID)
            record.counts += counts
            record.eventCount += 1
            daily[key] = record
            if hour <= currentHour {
                var row = hourly[hour] ?? HourlyUsage(
                    hourStart: hour, deviceID: deviceID, sourceID: "devin",
                    counts: .zero, eventCount: 0, reasoningKnown: false
                )
                row.counts += counts
                row.eventCount += 1
                hourly[hour] = row
            }
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
    }

    // MARK: - SQLite helpers

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }
}
