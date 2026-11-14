import Foundation
import OSLog
import SQLite3

/// Antigravity CLI (`~/.gemini/antigravity-cli/conversations/*.db`) and IDE extension
/// (`~/.gemini/antigravity/conversations/*.db`) usage, read natively.
///
/// Each conversation is one SQLite database whose `gen_metadata` rows hold the IDE's `GeneratorMetadata`
/// protobuf. Field numbers were decoded from real databases and cross-checked in
/// `docs/decisions/0009-native-devin-antigravity.md`: `chatModel.#4` is the usage block (`#2` newly processed
/// input, `#5` cache read, `#9` output, `#10` reasoning, `#11` responseId, `#3` stored total output that equals
/// `#9 + #10`), and `chatModel.#19` / `#21` are the response model and display label.
///
/// `usage.#1` is deliberately not counted as input. It is a model-sized constant (nine distinct values over 93
/// conversations), it is mirrored verbatim at `chatModel.#3`, and the client's own per-step transcript sums to
/// `#2` alone, so it is prompt-template mass rather than billed input.
public struct AntigravityCollector: UsageCollector {
    public let sourceIDs = ["antigravity"]

    private static let sourceID = "antigravity"
    // Bump to 2 so state saved before the closed-WAL fix misses `saved.stamp == stamp` and re-reads all DBs once.
    private static let stateFormatVersion = 2
    private static let logger = Logger(subsystem: "io.github.elijah7x.TokenTaken", category: "collection")

    private let roots: [Root]
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

    /// Test seam: `home`, `environment` and the clock replace the values the production initializer reads.
    public init(
        home: URL,
        environment: [String: String],
        deviceID: String,
        timeZone: TimeZone = .current,
        now: Date = .now,
        stateDirectory: URL? = nil
    ) {
        let geminiHome = environment["GEMINI_CLI_HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        } ?? home.appendingPathComponent(".gemini", isDirectory: true)
        // The CLI directory is read first so its row wins whenever both clients hold the same response ID.
        roots = [
            Root(client: "cli", directory: geminiHome.appendingPathComponent("antigravity-cli/conversations", isDirectory: true)),
            Root(client: "extension", directory: home.appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true)),
        ]
        self.deviceID = deviceID
        self.timeZone = timeZone
        self.now = now
        self.stateFile = stateDirectory.map { CollectorStateFile(directory: $0, name: AntigravityCollector.sourceID) }
    }

    public func collect() async throws -> CollectionBatch {
        let started = Date.now
        let manager = FileManager.default

        var files: [DatabaseFile] = []
        var available = false
        for root in roots {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: root.directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            available = true
            let names = (try? manager.contentsOfDirectory(atPath: root.directory.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".db") {
                files.append(DatabaseFile(client: root.client, url: root.directory.appendingPathComponent(name)))
            }
        }
        guard available else { throw CollectorError.sourceUnavailable }

        let stamp = CollectionStamp(formatVersion: Self.stateFormatVersion, timeZone: timeZone, sourceIDs: sourceIDs)
        // Fingerprint before the read: a write that lands while reading must trigger a re-collect next time.
        let fingerprints = Self.fingerprints(files)
        if let stateFile, !fingerprints.isEmpty, let saved = stateFile.load(),
           saved.stamp == stamp, saved.files == fingerprints {
            log(mode: "unchanged", since: started)
            return CollectionBatch(unchangedSourceIDs: Set(sourceIDs))
        }

        let temporaryDirectory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporaryDirectory) }

        var aggregator = Aggregator(deviceID: deviceID, timeZone: timeZone, now: now)
        var unreadableDatabases = 0
        for file in files {
            let conversation: Conversation?
            do {
                conversation = try read(file, temporaryDirectory: temporaryDirectory)
            } catch {
                // A database that cannot be read is a partial read; count it so hourly coverage stays unknown.
                aggregator.skipUnreadableDatabase()
                unreadableDatabases += 1
                Self.logger.error("source=antigravity unreadable_database")
                continue
            }
            guard let conversation else {
                // No `gen_metadata` table: not an Antigravity generation database.
                Self.logger.info("source=antigravity skipped_database")
                continue
            }
            aggregator.record(conversation, stem: file.url.deletingPathExtension().lastPathComponent)
        }

        var batch = aggregator.batch()
        // Save the fingerprint only when every database was read and none changed during the read; otherwise an
        // unchanged fingerprint would stop the next run from retrying the databases this one could not read.
        if let stateFile, unreadableDatabases == 0, Self.fingerprints(files) == fingerprints {
            let saved = SavedState(stamp: stamp, files: fingerprints)
            batch.stateCommits = [{ try stateFile.save(saved) }]
        }
        log(mode: "full", since: started)
        return batch
    }

    private func log(mode: String, since started: Date) {
        let duration = Int((Date.now.timeIntervalSince(started) * 1_000).rounded())
        Self.logger.info("source=antigravity mode=\(mode, privacy: .public) duration_ms=\(duration, privacy: .public)")
    }

    // MARK: - Reading one conversation

    private func read(_ file: DatabaseFile, temporaryDirectory: URL) throws -> Conversation? {
        let modified = Self.modifiedMilliseconds(file.url)
        return try SQLiteSnapshotReader.withReadableDatabase(
            at: file.url, temporaryDirectory: temporaryDirectory
        ) { db -> Conversation? in
            guard let rows = try generationRows(db) else { return nil }
            // The session created-at dates the conversation as a whole; an unreadable mtime degrades to `now`,
            // which is the only stamp left when neither decodes.
            let sessionStamp = sessionCreated(at: db) ?? modified
                ?? Int64((now.timeIntervalSince1970 * 1_000).rounded())
            return Conversation(rows: rows, sessionStamp: sessionStamp, steps: stepTimestamps(db))
        }
    }

    /// `nil` when the database has no `gen_metadata` table at all, i.e. it is not a generation database.
    private func generationRows(_ db: OpaquePointer) throws -> [Generation]? {
        guard try SQLiteSnapshotReader.tableExists(db, "gen_metadata") else { return nil }
        let statement = try SQLiteSnapshotReader.prepare(db, "SELECT idx, data FROM gen_metadata ORDER BY idx;")
        defer { sqlite3_finalize(statement) }
        var rows: [Generation] = []
        while true {
            let result = sqlite3_step(statement)
            guard result != SQLITE_DONE else { break }
            guard result == SQLITE_ROW else { throw SQLiteSnapshotReader.lastError(db) }
            guard let data = Self.blob(statement, 1) else { continue }
            let index = sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 0)
            rows.append(Generation(index: index, data: data))
        }
        return rows
    }

    /// `trajectory_metadata_blob` row `id='main'`, field `#2`, as epoch ms. Older databases have a single row and
    /// no `id` column, so an unfiltered read is the fallback.
    private func sessionCreated(at db: OpaquePointer) -> Int64? {
        let queries = [
            "SELECT data FROM trajectory_metadata_blob WHERE id = 'main' LIMIT 1;",
            "SELECT data FROM trajectory_metadata_blob LIMIT 1;",
        ]
        for query in queries {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else { continue }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let blob = Self.blob(statement, 0),
                  let created = ProtoMessage(blob).message(2).flatMap(ProtoMessage.milliseconds),
                  created > 0 else { continue }
            return created
        }
        return nil
    }

    /// Per-turn timestamps from `steps` (`step_type = 15`): `metadata.#1` is the Timestamp, `#9.#11` the
    /// responseId and `#20.#3` the generation index. The 24-character step id rarely equals the 20-character
    /// usage id on current builds, so the index join carries most rows; an exact-match-only id join can miss
    /// but never mis-date.
    private func stepTimestamps(_ db: OpaquePointer) -> StepTimestamps {
        var stamps = StepTimestamps()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT metadata FROM steps WHERE step_type = 15 AND metadata IS NOT NULL;", -1, &statement, nil
        ) == SQLITE_OK, let statement else { return stamps }
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else { break }
            guard let blob = Self.blob(statement, 0) else { continue }
            let metadata = ProtoMessage(blob)
            guard let stamp = metadata.message(1).flatMap(ProtoMessage.milliseconds), stamp > 0 else { continue }
            if let response = metadata.message(9)?.text(11) {
                stamps.byResponse[response] = stamp
            }
            if let index = metadata.message(20)?.varint(3) {
                stamps.byIndex[Int64(bitPattern: index)] = stamp
            }
        }
        return stamps
    }

    private static func blob(_ statement: OpaquePointer, _ index: Int32) -> [UInt8]? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0 else { return nil }
        return Array(UnsafeRawBufferPointer(start: bytes, count: count))
    }

    private static func modifiedMilliseconds(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return Int64((modified.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func count(_ value: UInt64?) -> Int64 {
        guard let value else { return 0 }
        return value >= UInt64(Int64.max) ? Int64.max : Int64(value)
    }

    private static func isRoutingLabel(_ model: String) -> Bool {
        model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "gemini-default"
    }

    // MARK: - State

    private struct SavedState: Codable, Hashable, Sendable {
        var stamp: CollectionStamp
        var files: [FingerprintedFile]
    }

    /// Path-free fingerprint entry: the client and the metadata of the `.db` and its `-wal`.
    private struct FingerprintedFile: Codable, Hashable, Sendable {
        var client: String
        var database: FileFingerprint
        var wal: FileFingerprint?
    }

    private static func fingerprints(_ files: [DatabaseFile]) -> [FingerprintedFile] {
        files.compactMap { file in
            guard let database = FileFingerprint(url: file.url) else { return nil }
            return FingerprintedFile(client: file.client, database: database, wal: FileFingerprint(url: file.walURL))
        }
    }

    private struct Root {
        let client: String
        let directory: URL
    }

    private struct DatabaseFile {
        let client: String
        let url: URL

        var walURL: URL { URL(fileURLWithPath: url.path + "-wal") }
    }

    private struct Generation {
        let index: Int64?
        let data: [UInt8]
    }

    private struct Conversation {
        let rows: [Generation]
        let sessionStamp: Int64
        let steps: StepTimestamps
    }

    private struct StepTimestamps {
        var byResponse: [String: Int64] = [:]
        var byIndex: [Int64: Int64] = [:]
    }

    /// Model attribution recovered from the whole conversation, for rows whose own `#19` is missing or is the
    /// `gemini-default` routing label. The display label is only a join key inside one file; the value returned is
    /// always a `#19` seen in that same file.
    private struct SessionModels {
        var byDisplay: [String: String] = [:]
        var sole: String?

        init(blobs: [[UInt8]]) {
            var resolved: [String: String] = [:]
            var ambiguous: Set<String> = []
            var distinct: Set<String> = []
            var unresolvedLabels: [String] = []
            for blob in blobs {
                guard let chat = ProtoMessage(blob).message(1) else { continue }
                let label = chat.text(21)
                guard let model = chat.text(19), !AntigravityCollector.isRoutingLabel(model) else {
                    if let label { unresolvedLabels.append(label) }
                    continue
                }
                distinct.insert(model)
                guard let label, !ambiguous.contains(label) else { continue }
                if let existing = resolved[label] {
                    if existing != model, !Self.sameAlias(existing, model) {
                        resolved[label] = nil
                        ambiguous.insert(label)
                    }
                } else {
                    resolved[label] = model
                }
            }
            byDisplay = resolved
            // One model for the file also requires every unidentified label to be resolved by another row: a model
            // switch the file never names must not inherit this id.
            sole = distinct.count == 1 && unresolvedLabels.allSatisfy { resolved[$0] != nil } ? distinct.first : nil
        }

        /// Antigravity writes `gemini-pro-default` and `gemini-pro-agent` under one display label for the same
        /// priced model, which is not a real ambiguity. Any other disagreement drops the label.
        private static func sameAlias(_ first: String, _ second: String) -> Bool {
            Set([first.lowercased(), second.lowercased()]) == ["gemini-pro-default", "gemini-pro-agent"]
        }
    }

    // MARK: - Aggregation

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
        private var anonymousRows = 0

        init(deviceID: String, timeZone: TimeZone, now: Date) {
            self.deviceID = deviceID
            self.timeZone = timeZone
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            self.calendar = calendar
            let currentHour = calendar.dateInterval(of: .hour, for: now)!.start
            self.currentHour = currentHour
            cutoff = currentHour.addingTimeInterval(-47 * 3_600)
        }

        mutating func skipUnreadableDatabase() {
            skipped += 1
        }

        mutating func record(_ conversation: Conversation, stem: String) {
            let models = SessionModels(blobs: conversation.rows.map(\.data))
            for row in conversation.rows {
                record(row, stem: stem, conversation: conversation, models: models)
            }
        }

        private mutating func record(
            _ row: Generation, stem: String, conversation: Conversation, models: SessionModels
        ) {
            guard let chat = ProtoMessage(row.data).message(1) else {
                skipped += 1
                return
            }
            // A generation without a usage block records no usage; it is not an undecodable row.
            guard let usage = chat.message(4) else { return }
            // `usage.#1` is deliberately never read here: see the type's documentation.
            let counts = TokenCounts(
                input: AntigravityCollector.count(usage.varint(2)),
                cacheRead: AntigravityCollector.count(usage.varint(5)),
                cacheWrite: 0,
                output: AntigravityCollector.count(usage.varint(9)),
                reasoning: AntigravityCollector.count(usage.varint(10))
            )
            guard counts.total != 0 else { return }

            let responseID = usage.text(11)
            let identity: String
            if let responseID {
                identity = responseID
            } else if let index = row.index {
                identity = "\(stem):\(index)"
            } else {
                anonymousRows += 1
                identity = "\(stem):row-\(anonymousRows)"
            }
            guard let timestamp = turnTimestamp(
                chat: chat, responseID: responseID, index: row.index, conversation: conversation
            ) else {
                skipped += 1
                return
            }
            // Deduplicate across every database of this run (CLI first): a conversation copied between the two
            // client stores must be counted once.
            guard seen.insert(identity).inserted else { return }

            let model = resolvedModel(chat: chat, models: models)
            let date = Date(timeIntervalSince1970: Double(timestamp) / 1_000)
            let day = UsageDay.string(from: date, in: timeZone)
            let key = Key(day: day, modelID: model)
            var record = daily[key] ?? UsageRecord(
                day: day, timeZoneID: timeZone.identifier, deviceID: deviceID,
                sourceID: AntigravityCollector.sourceID, modelID: model, rawModelID: model, counts: .zero
            )
            record.counts += counts
            record.eventCount += 1
            daily[key] = record

            let hour = calendar.dateInterval(of: .hour, for: date)!.start
            guard hour >= cutoff, hour <= currentHour else { return }
            var hourlyRow = hourly[hour] ?? HourlyUsage(
                hourStart: hour, deviceID: deviceID, sourceID: AntigravityCollector.sourceID,
                counts: .zero, eventCount: 0, reasoningKnown: true
            )
            hourlyRow.counts += counts
            hourlyRow.eventCount += 1
            hourly[hour] = hourlyRow
        }

        /// `chatModel.#9.#4` explicit Timestamp, then `steps` by responseId, then by generation index, then the
        /// session created-at, then the file mtime. The inferred `#9.#10` reading tokscale also attempts is not
        /// used: it is an unconfirmed layout, and a wrong stamp silently corrupts day buckets.
        private func turnTimestamp(
            chat: ProtoMessage, responseID: String?, index: Int64?, conversation: Conversation
        ) -> Int64? {
            if let explicit = chat.message(9)?.message(4).flatMap(ProtoMessage.milliseconds), explicit > 0 {
                return explicit
            }
            if let responseID, let stamp = conversation.steps.byResponse[responseID] {
                return stamp
            }
            if let index, let stamp = conversation.steps.byIndex[index] {
                return stamp
            }
            return conversation.sessionStamp > 0 ? conversation.sessionStamp : nil
        }

        private func resolvedModel(chat: ProtoMessage, models: SessionModels) -> String {
            let responseModel = chat.text(19)
            if let responseModel, !AntigravityCollector.isRoutingLabel(responseModel) {
                return Self.normalized(responseModel)
            }
            if let label = chat.text(21), let sibling = models.byDisplay[label] {
                return Self.normalized(sibling)
            }
            if let sole = models.sole {
                return Self.normalized(sole)
            }
            return "unknown"
        }

        /// Raw ids are kept lowercase and unaliased; the price table resolves aliases.
        private static func normalized(_ model: String) -> String {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed.isEmpty ? "unknown" : trimmed
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

        struct Key: Hashable {
            let day: String
            let modelID: String
        }
    }
}

/// Minimal protobuf wire reader: varint and length-delimited values are kept, fixed32/fixed64 and group fields
/// are skipped, and a malformed buffer ends the field list instead of trapping.
private struct ProtoMessage {
    private let bytes: [UInt8]
    private let fields: [Field]

    private struct Field {
        let number: Int
        let wire: Int
        let value: UInt64
        let range: Range<Int>?
    }

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        fields = Self.decode(bytes)
    }

    func varint(_ number: Int) -> UInt64? {
        fields.first { $0.number == number && $0.wire == 0 }?.value
    }

    func message(_ number: Int) -> ProtoMessage? {
        guard let range = fields.first(where: { $0.number == number && $0.wire == 2 })?.range else { return nil }
        return ProtoMessage(Array(bytes[range]))
    }

    /// Length-delimited field as trimmed UTF-8; empty or invalid values are absent.
    func text(_ number: Int) -> String? {
        guard let range = fields.first(where: { $0.number == number && $0.wire == 2 })?.range,
              let value = String(bytes: bytes[range], encoding: .utf8) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `{#1: seconds, #2: nanos}` as epoch milliseconds.
    static func milliseconds(_ message: ProtoMessage) -> Int64? {
        guard let seconds = message.varint(1) else { return nil }
        let nanos = message.varint(2) ?? 0
        guard nanos <= 999_999_999 else { return nil }
        let (scaled, scaledOverflow) = Int64(bitPattern: seconds).multipliedReportingOverflow(by: 1_000)
        guard !scaledOverflow else { return nil }
        let (result, addedOverflow) = scaled.addingReportingOverflow(Int64(nanos / 1_000_000))
        return addedOverflow ? nil : result
    }

    private static func decode(_ bytes: [UInt8]) -> [Field] {
        var fields: [Field] = []
        var position = 0
        while position < bytes.count {
            guard let tag = scalar(bytes, &position) else { return fields }
            let rawNumber = tag >> 3
            // Protobuf's field numbers stop at 2^29 - 1; anything above is a malformed tag, not a field.
            guard rawNumber > 0, rawNumber <= 5_368_870_911 else { return fields }
            let number = Int(rawNumber)
            let wire = Int(tag & 0x07)
            switch wire {
            case 0:
                guard let value = scalar(bytes, &position) else { return fields }
                fields.append(Field(number: number, wire: wire, value: value, range: nil))
            case 2:
                guard let length = scalar(bytes, &position), length <= UInt64(bytes.count - position) else {
                    return fields
                }
                let end = position + Int(length)
                fields.append(Field(number: number, wire: wire, value: 0, range: position..<end))
                position = end
            case 1:
                guard position + 8 <= bytes.count else { return fields }
                position += 8
            case 5:
                guard position + 4 <= bytes.count else { return fields }
                position += 4
            default:
                return fields
            }
        }
        return fields
    }

    private static func scalar(_ bytes: [UInt8], _ position: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while position < bytes.count {
            let byte = bytes[position]
            position += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
            guard shift < 64 else { return nil }
        }
        return nil
    }
}
