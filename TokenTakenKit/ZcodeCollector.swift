import Foundation
import SQLite3

public struct ZcodeCollector: UsageCollector {
    public let sourceIDs = ["zcode"]

    private let databaseURL: URL
    private let deviceID: String

    public init(
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/cli/db/db.sqlite"),
        deviceID: String
    ) {
        self.databaseURL = databaseURL
        self.deviceID = deviceID
    }

    public func collect() async throws -> [UsageRecord] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: databaseURL.path) else { return [] }

        // SQLite documents immutable=1 as unsafe while another process can write, so read a temporary snapshot.
        // Source: https://www.sqlite.org/c3ref/open.html#uri-filenames
        let temporaryDirectory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporaryDirectory) }
        let copyURL = temporaryDirectory.appendingPathComponent("db.sqlite")
        try manager.copyItem(at: databaseURL, to: copyURL)
        for suffix in ["-wal", "-shm"] {
            let source = URL(fileURLWithPath: databaseURL.path + suffix)
            if manager.fileExists(atPath: source.path) {
                try manager.copyItem(at: source, to: URL(fileURLWithPath: copyURL.path + suffix))
            }
        }

        var components = URLComponents()
        components.scheme = "file"
        components.path = copyURL.path
        components.queryItems = [
            URLQueryItem(name: "mode", value: "ro"),
            URLQueryItem(name: "immutable", value: "1"),
        ]
        guard let uri = components.string else { throw CollectorError.open("Could not open the Zcode database") }
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open the Zcode database"
            if let handle { sqlite3_close(handle) }
            throw CollectorError.open(message)
        }
        defer { sqlite3_close(handle) }

        let boundary = try nativeBoundary(db: handle)
        var totals: [Key: TokenCounts] = [:]
        try collectNative(db: handle, into: &totals)
        try collectLegacy(db: handle, boundary: boundary, into: &totals)
        return totals.map { key, counts in
            UsageRecord(day: key.day, deviceID: deviceID, sourceID: "zcode", modelID: key.modelID, counts: counts)
        }.sorted {
            if $0.day != $1.day { return $0.day < $1.day }
            return $0.modelID < $1.modelID
        }
    }

    private static let nativeCondition = """
        status = 'completed'
        AND model_id IS NOT NULL AND model_id <> ''
        AND instr(lower(COALESCE(provider_id, '')), 'anthropic') = 0
        AND instr(lower(COALESCE(provider_id, '')), 'openai') = 0
        AND instr(lower(COALESCE(provider_id, '')), 'google') = 0
        AND (
            COALESCE(input_tokens, 0) > 0 OR COALESCE(output_tokens, 0) > 0
            OR COALESCE(reasoning_tokens, 0) > 0 OR COALESCE(cache_read_input_tokens, 0) > 0
            OR COALESCE(cache_creation_input_tokens, 0) > 0
        )
        """

    private func nativeBoundary(db: OpaquePointer) throws -> Int64? {
        let statement = try prepare(db, "SELECT MIN(started_at) FROM model_usage WHERE \(Self.nativeCondition);")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError(db) }
        return sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 0)
    }

    private func collectNative(db: OpaquePointer, into totals: inout [Key: TokenCounts]) throws {
        let statement = try prepare(db, """
            SELECT started_at, model_id, input_tokens, output_tokens, reasoning_tokens,
                   cache_read_input_tokens, cache_creation_input_tokens
            FROM model_usage WHERE \(Self.nativeCondition);
            """)
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            guard result != SQLITE_DONE else { break }
            guard result == SQLITE_ROW else { throw lastError(db) }
            guard let day = UsageDay.date(milliseconds: sqlite3_column_int64(statement, 0)) else { continue }
            let counts = normalized(
                input: sqlite3_column_int64(statement, 2),
                output: sqlite3_column_int64(statement, 3),
                reasoning: sqlite3_column_int64(statement, 4),
                cacheRead: sqlite3_column_int64(statement, 5),
                cacheWrite: sqlite3_column_int64(statement, 6)
            )
            let key = Key(day: day, modelID: text(statement, 1))
            totals[key, default: .zero] += counts
        }
    }

    private func collectLegacy(db: OpaquePointer, boundary: Int64?, into totals: inout [Key: TokenCounts]) throws {
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
                  COALESCE(json_extract(data, '$.tokens.input'), 0) > 0
                  OR COALESCE(json_extract(data, '$.tokens.output'), 0) > 0
                  OR COALESCE(json_extract(data, '$.tokens.reasoning'), 0) > 0
                  OR COALESCE(json_extract(data, '$.tokens.cache.read'), 0) > 0
                  OR COALESCE(json_extract(data, '$.tokens.cache.write'), 0) > 0
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
            let counts = normalized(
                input: sqlite3_column_int64(statement, 5),
                output: sqlite3_column_int64(statement, 6),
                reasoning: sqlite3_column_int64(statement, 7),
                cacheRead: sqlite3_column_int64(statement, 8),
                cacheWrite: sqlite3_column_int64(statement, 9)
            )
            let row = LegacyRow(
                sessionID: text(statement, 0),
                timeCreated: sqlite3_column_int64(statement, 1),
                rowID: sqlite3_column_int64(statement, 2),
                created: sqlite3_column_int64(statement, 3),
                completed: sqlite3_column_int64(statement, 4),
                counts: counts,
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
                guard let day = UsageDay.date(milliseconds: timestamp) else { continue }
                totals[Key(day: day, modelID: row.modelID), default: .zero] += row.counts
            }
        }
    }

    private func normalized(input: Int64, output: Int64, reasoning: Int64, cacheRead: Int64, cacheWrite: Int64) -> TokenCounts {
        TokenCounts(
            input: max(0, input - cacheRead - cacheWrite),
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            output: max(0, output - reasoning),
            reasoning: reasoning
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
        let day: Date
        let modelID: String
    }

    private struct LegacyRow {
        let sessionID: String
        let timeCreated: Int64
        let rowID: Int64
        let created: Int64
        let completed: Int64
        let counts: TokenCounts
        let modelID: String
        let provider: String

        var fingerprint: Fingerprint {
            Fingerprint(
                created: created, completed: completed, counts: counts,
                modelID: modelID, provider: provider
            )
        }
    }

    private struct Fingerprint: Hashable {
        let created: Int64
        let completed: Int64
        let counts: TokenCounts
        let modelID: String
        let provider: String
    }
}
