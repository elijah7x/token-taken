import Foundation
import OSLog
import SQLite3

public struct ZcodeCollector: UsageCollector {
    public let sourceIDs = ["zcode"]

    private static let stateFormatVersion = 1
    private static let logger = Logger(subsystem: "io.github.elijah7x.TokenTaken", category: "collection")

    private let databaseURL: URL
    private let deviceID: String
    private let timeZone: TimeZone
    private let now: Date
    private let stateFile: CollectorStateFile<SavedState>?

    public init(
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/cli/db/db.sqlite"),
        deviceID: String,
        timeZone: TimeZone = .current,
        now: Date = .now,
        stateDirectory: URL? = nil
    ) {
        self.databaseURL = databaseURL
        self.deviceID = deviceID
        self.timeZone = timeZone
        self.now = now
        self.stateFile = stateDirectory.map { CollectorStateFile(directory: $0, name: "zcode") }
    }

    public func collect() async throws -> CollectionBatch {
        let started = Date.now
        let manager = FileManager.default
        guard manager.fileExists(atPath: databaseURL.path) else { throw CollectorError.sourceUnavailable }

        let stamp = CollectionStamp(formatVersion: Self.stateFormatVersion, timeZone: timeZone)
        // Fingerprint before the snapshot: a write that lands during the backup must trigger a re-collect next time.
        let fingerprints = Fingerprints(databaseURL: databaseURL)
        if let stateFile, fingerprints.database != nil, let saved = stateFile.load(),
           saved.stamp == stamp, saved.fingerprints == fingerprints {
            log(mode: "unchanged", since: started)
            return CollectionBatch(unchangedSourceIDs: Set(sourceIDs))
        }

        // SQLite documents immutable=1 as unsafe while another process can write, so read a temporary snapshot.
        // Source: https://www.sqlite.org/c3ref/open.html#uri-filenames
        let temporaryDirectory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporaryDirectory) }
        let copyURL = temporaryDirectory.appendingPathComponent("db.sqlite")
        try backupDatabase(from: databaseURL, to: copyURL)

        var handle: OpaquePointer?
        let result = sqlite3_open_v2(copyURL.path, &handle, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open the Zcode database"
            if let handle { sqlite3_close(handle) }
            throw CollectorError.open(message)
        }
        defer { sqlite3_close(handle) }

        let boundary = try nativeBoundary(db: handle)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let currentHour = calendar.dateInterval(of: .hour, for: now)!.start
        let cutoff = currentHour.addingTimeInterval(-47 * 3_600)
        var aggregator = Aggregator(
            deviceID: deviceID, timeZone: timeZone, calendar: calendar,
            currentHour: currentHour, cutoff: cutoff
        )
        try collectNative(db: handle, into: &aggregator)
        try collectLegacy(db: handle, boundary: boundary, into: &aggregator)
        guard manager.fileExists(atPath: databaseURL.path) else { throw CollectorError.sourceUnavailable }
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
        Self.logger.info("source=zcode mode=\(mode, privacy: .public) duration_ms=\(duration, privacy: .public)")
    }

    private struct SavedState: Codable, Sendable {
        var stamp: CollectionStamp
        var fingerprints: Fingerprints
    }

    private struct Fingerprints: Codable, Hashable, Sendable {
        var database: FileFingerprint?
        var wal: FileFingerprint?
        var shm: FileFingerprint?

        init(databaseURL: URL) {
            database = FileFingerprint(url: databaseURL)
            wal = FileFingerprint(url: URL(fileURLWithPath: databaseURL.path + "-wal"))
            shm = FileFingerprint(url: URL(fileURLWithPath: databaseURL.path + "-shm"))
        }
    }

    private func backupDatabase(from sourceURL: URL, to destinationURL: URL) throws {
        var source: OpaquePointer?
        let openSource = sqlite3_open_v2(sourceURL.path, &source, SQLITE_OPEN_READONLY, nil)
        guard openSource == SQLITE_OK, let source else {
            let message = source.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open the Zcode database"
            if let source { sqlite3_close(source) }
            throw CollectorError.open(message)
        }
        defer { sqlite3_close(source) }
        sqlite3_busy_timeout(source, 5_000)

        var destination: OpaquePointer?
        let openDestination = sqlite3_open_v2(
            destinationURL.path,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        guard openDestination == SQLITE_OK, let destination else {
            let message = destination.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not create temporary Zcode snapshot"
            if let destination { sqlite3_close(destination) }
            throw CollectorError.open(message)
        }
        defer { sqlite3_close(destination) }

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw lastError(destination)
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw CollectorError.sql("Could not back up the Zcode database")
        }
        // The copy inherits WAL mode from the live file; a read-only open of a WAL database without its
        // -wal/-shm files fails, so convert the private copy to a rollback journal.
        guard sqlite3_exec(destination, "PRAGMA journal_mode=DELETE;", nil, nil, nil) == SQLITE_OK else {
            throw lastError(destination)
        }
    }

    private static let nativeBaseCondition = """
        status = 'completed'
        AND model_id IS NOT NULL AND model_id <> ''
        AND instr(lower(COALESCE(provider_id, '')), 'anthropic') = 0
        AND instr(lower(COALESCE(provider_id, '')), 'openai') = 0
        AND instr(lower(COALESCE(provider_id, '')), 'google') = 0
        """

    private static let nativeBoundaryCondition = """
        \(nativeBaseCondition)
        AND typeof(started_at) = 'integer' AND started_at > 0
        AND COALESCE(input_tokens, 0) >= 0 AND COALESCE(output_tokens, 0) >= 0
        AND COALESCE(reasoning_tokens, 0) >= 0 AND COALESCE(cache_read_input_tokens, 0) >= 0
        AND COALESCE(cache_creation_input_tokens, 0) >= 0
        AND (
            COALESCE(input_tokens, 0) > 0 OR COALESCE(output_tokens, 0) > 0
            OR COALESCE(reasoning_tokens, 0) > 0 OR COALESCE(cache_read_input_tokens, 0) > 0
            OR COALESCE(cache_creation_input_tokens, 0) > 0
        )
        """

    private static let nativeScanCondition = """
        \(nativeBaseCondition)
        AND (
            COALESCE(input_tokens, 0) <> 0 OR COALESCE(output_tokens, 0) <> 0
            OR COALESCE(reasoning_tokens, 0) <> 0 OR COALESCE(cache_read_input_tokens, 0) <> 0
            OR COALESCE(cache_creation_input_tokens, 0) <> 0
        )
        """

    private func nativeBoundary(db: OpaquePointer) throws -> Int64? {
        let statement = try prepare(db, "SELECT MIN(started_at) FROM model_usage WHERE \(Self.nativeBoundaryCondition);")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError(db) }
        return sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 0)
    }

    private func collectNative(db: OpaquePointer, into aggregator: inout Aggregator) throws {
        let statement = try prepare(db, """
            SELECT started_at, model_id, input_tokens, output_tokens, reasoning_tokens,
                   cache_read_input_tokens, cache_creation_input_tokens
            FROM model_usage WHERE \(Self.nativeScanCondition);
            """)
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            guard result != SQLITE_DONE else { break }
            guard result == SQLITE_ROW else { throw lastError(db) }
            aggregator.record(
                timestamp: sqlite3_column_int64(statement, 0),
                modelID: text(statement, 1),
                usage: normalized(
                    input: sqlite3_column_int64(statement, 2),
                    output: sqlite3_column_int64(statement, 3),
                    reasoning: sqlite3_column_int64(statement, 4),
                    cacheRead: sqlite3_column_int64(statement, 5),
                    cacheWrite: sqlite3_column_int64(statement, 6)
                )
            )
        }
    }

    private func collectLegacy(db: OpaquePointer, boundary: Int64?, into aggregator: inout Aggregator) throws {
        let statement = try prepare(db, """
            SELECT session_id, time_created, rowid,
                   COALESCE(json_extract(data, '$.time.created'), 0),
                   COALESCE(json_extract(data, '$.time.completed'), 0),
                   COALESCE(json_extract(data, '$.tokens.input'), 0),
                   COALESCE(json_extract(data, '$.tokens.output'), 0),
                   COALESCE(json_extract(data, '$.tokens.reasoning'), 0),
                   COALESCE(json_extract(data, '$.tokens.cache.read'), 0),
                   COALESCE(json_extract(data, '$.tokens.cache.write'), 0),
                   COALESCE(json_extract(data, '$.modelID'), json_extract(data, '$.modelId'), json_extract(data, '$.model.id')),
                   COALESCE(json_extract(data, '$.providerID'), json_extract(data, '$.model.providerID'), json_extract(data, '$.providerId'))
            FROM message
            WHERE json_extract(data, '$.role') = 'assistant'
              AND (?1 IS NULL OR time_updated < ?1)
              AND (
                  COALESCE(json_extract(data, '$.tokens.input'), 0) <> 0
                  OR COALESCE(json_extract(data, '$.tokens.output'), 0) <> 0
                  OR COALESCE(json_extract(data, '$.tokens.reasoning'), 0) <> 0
                  OR COALESCE(json_extract(data, '$.tokens.cache.read'), 0) <> 0
                  OR COALESCE(json_extract(data, '$.tokens.cache.write'), 0) <> 0
              )
            ORDER BY time_created, rowid;
            """)
        defer { sqlite3_finalize(statement) }
        if let boundary {
            sqlite3_bind_int64(statement, 1, boundary)
        } else {
            sqlite3_bind_null(statement, 1)
        }

        var groups: [Fingerprint: [LegacyRow]] = [:]
        while true {
            let result = sqlite3_step(statement)
            guard result != SQLITE_DONE else { break }
            guard result == SQLITE_ROW else { throw lastError(db) }
            let provider = text(statement, 11).lowercased()
            guard !provider.contains("anthropic"), !provider.contains("openai"), !provider.contains("google") else {
                continue
            }
            let input = sqlite3_column_int64(statement, 5)
            let output = sqlite3_column_int64(statement, 6)
            let reasoning = sqlite3_column_int64(statement, 7)
            let cacheRead = sqlite3_column_int64(statement, 8)
            let cacheWrite = sqlite3_column_int64(statement, 9)
            let row = LegacyRow(
                sessionID: text(statement, 0),
                timeCreated: sqlite3_column_int64(statement, 1),
                rowID: sqlite3_column_int64(statement, 2),
                created: sqlite3_column_int64(statement, 3),
                completed: sqlite3_column_int64(statement, 4),
                input: input,
                output: output,
                reasoning: reasoning,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                usage: normalized(
                    input: input, output: output, reasoning: reasoning,
                    cacheRead: cacheRead, cacheWrite: cacheWrite
                ),
                modelID: text(statement, 10),
                provider: text(statement, 11)
            )
            groups[row.fingerprint, default: []].append(row)
        }

        for rows in groups.values {
            let retained: [LegacyRow]
            if Set(rows.map(\.sessionID)).count > 1,
               let earliest = rows.min(by: {
                   if $0.timeCreated != $1.timeCreated { return $0.timeCreated < $1.timeCreated }
                   return $0.rowID < $1.rowID
               }) {
                retained = rows.filter { $0.sessionID == earliest.sessionID }
            } else {
                retained = rows
            }
            for row in retained {
                let timestamp = row.completed == 0 ? row.created : row.completed
                aggregator.record(timestamp: timestamp, modelID: row.modelID, usage: row.usage)
            }
        }
    }

    private func normalized(
        input: Int64, output: Int64, reasoning: Int64, cacheRead: Int64, cacheWrite: Int64
    ) -> NormalizedUsage? {
        guard input >= 0, output >= 0, reasoning >= 0, cacheRead >= 0, cacheWrite >= 0 else {
            return nil
        }
        let validSplit = reasoning <= output
        return NormalizedUsage(
            counts: TokenCounts(
                input: max(0, input - cacheRead - cacheWrite),
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                output: validSplit ? output - reasoning : output,
                reasoning: validSplit ? reasoning : 0
            ),
            reasoningKnown: validSplit
        )
    }

    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError(db)
        }
        return statement
    }

    private func lastError(_ db: OpaquePointer) -> CollectorError {
        .sql(String(cString: sqlite3_errmsg(db)))
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private struct Key: Hashable {
        let day: String
        let modelID: String
    }

    private struct NormalizedUsage: Hashable {
        let counts: TokenCounts
        let reasoningKnown: Bool
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

        mutating func record(timestamp: Int64, modelID rawModelID: String, usage: NormalizedUsage?) {
            guard timestamp > 0, !rawModelID.isEmpty, let usage else {
                skipped += 1
                return
            }
            let model = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !model.isEmpty, TokenCategory.allCases.allSatisfy({ usage.counts[$0] >= 0 }) else {
                skipped += 1
                return
            }
            let date = Date(timeIntervalSince1970: Double(timestamp) / 1_000)
            let day = UsageDay.string(from: date, in: timeZone)
            let key = Key(day: day, modelID: model)
            var record = daily[key] ?? UsageRecord(
                day: day, timeZoneID: timeZone.identifier, deviceID: deviceID,
                sourceID: "zcode", modelID: model, rawModelID: rawModelID, counts: .zero
            )
            record.rawModelID = min(record.rawModelID, rawModelID)
            record.counts += usage.counts
            record.eventCount += 1
            daily[key] = record
            let hour = calendar.dateInterval(of: .hour, for: date)!.start
            if hour >= cutoff, hour <= currentHour {
                var row = hourly[hour] ?? HourlyUsage(
                    hourStart: hour, deviceID: deviceID, sourceID: "zcode",
                    counts: .zero, eventCount: 0, reasoningKnown: true
                )
                row.counts += usage.counts
                row.eventCount += 1
                row.reasoningKnown = row.reasoningKnown && usage.reasoningKnown
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

    private struct LegacyRow {
        let sessionID: String
        let timeCreated: Int64
        let rowID: Int64
        let created: Int64
        let completed: Int64
        let input: Int64
        let output: Int64
        let reasoning: Int64
        let cacheRead: Int64
        let cacheWrite: Int64
        let usage: NormalizedUsage?
        let modelID: String
        let provider: String

        var fingerprint: Fingerprint {
            Fingerprint(
                created: created, completed: completed, input: input, output: output,
                reasoning: reasoning, cacheRead: cacheRead, cacheWrite: cacheWrite,
                modelID: modelID, provider: provider
            )
        }
    }

    private struct Fingerprint: Hashable {
        let created: Int64
        let completed: Int64
        let input: Int64
        let output: Int64
        let reasoning: Int64
        let cacheRead: Int64
        let cacheWrite: Int64
        let modelID: String
        let provider: String
    }
}
