import XCTest
import SQLite3
@testable import TokenTakenKit

final class ZcodeCollectorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private enum TestError: Error {
        case sqlite(String)
    }

    private func milliseconds(_ value: String) -> Int64 {
        Int64(ISO8601DateFormatter().date(from: value)!.timeIntervalSince1970 * 1_000)
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let error = message.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(message)
            throw TestError.sqlite(error)
        }
    }

    private func insertMessage(
        db: OpaquePointer,
        session: String,
        created: Int64,
        updated: Int64,
        completed: Int64,
        input: Int,
        output: Int,
        reasoning: Int,
        cacheRead: Int,
        cacheWrite: Int,
        model: String,
        provider: String
    ) throws {
        let object: [String: Any] = [
            "role": "assistant",
            "time": ["created": created, "completed": completed],
            "tokens": [
                "input": input,
                "output": output,
                "reasoning": reasoning,
                "cache": ["read": cacheRead, "write": cacheWrite],
            ],
            "modelID": model,
            "providerID": provider,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "'", with: "''")
        try execute(db, """
            INSERT INTO message (session_id, time_created, time_updated, data)
            VALUES ('\(session)', \(created), \(updated), '\(json)');
            """)
    }

    private func makeDatabase() throws -> URL {
        let url = directory.appendingPathComponent("db.sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let db = handle else {
            throw TestError.sqlite("Could not create synthetic database")
        }
        defer { sqlite3_close(db) }
        try execute(db, """
            CREATE TABLE model_usage (
                status TEXT,
                started_at INTEGER,
                model_id TEXT,
                provider_id TEXT,
                input_tokens INTEGER,
                output_tokens INTEGER,
                reasoning_tokens INTEGER,
                cache_read_input_tokens INTEGER,
                cache_creation_input_tokens INTEGER
            );
            CREATE TABLE message (
                session_id TEXT,
                time_created INTEGER,
                time_updated INTEGER,
                data TEXT
            );
            """)

        let boundary = milliseconds("2026-01-03T00:00:00Z")
        try execute(db, """
            INSERT INTO model_usage VALUES (
                'completed', \(boundary), 'glm-native', 'zai', 1000, 200, 50, 300, 100
            );
            """)

        try insertMessage(
            db: db,
            session: "session-a",
            created: milliseconds("2026-01-01T10:00:00Z"),
            updated: boundary - 3_000,
            completed: milliseconds("2026-01-01T13:00:00Z"),
            input: 500, output: 120, reasoning: 20, cacheRead: 100, cacheWrite: 50,
            model: "glm-legacy", provider: "zai"
        )

        let duplicateCreated = milliseconds("2026-01-02T10:00:00Z")
        let duplicateCompleted = milliseconds("2026-01-02T11:00:00Z")
        for session in ["session-a", "session-b"] {
            try insertMessage(
                db: db,
                session: session,
                created: duplicateCreated,
                updated: boundary - 2_000,
                completed: duplicateCompleted,
                input: 300, output: 90, reasoning: 10, cacheRead: 50, cacheWrite: 30,
                model: "glm-copy", provider: "zai"
            )
        }

        try insertMessage(
            db: db,
            session: "session-after",
            created: boundary + 1_000,
            updated: boundary + 1_000,
            completed: milliseconds("2026-01-04T00:00:00Z"),
            input: 9000, output: 900, reasoning: 90, cacheRead: 900, cacheWrite: 90,
            model: "glm-after", provider: "zai"
        )
        try insertMessage(
            db: db,
            session: "session-anthropic",
            created: milliseconds("2026-01-01T08:00:00Z"),
            updated: boundary - 4_000,
            completed: milliseconds("2026-01-01T09:00:00Z"),
            input: 8000, output: 800, reasoning: 80, cacheRead: 800, cacheWrite: 80,
            model: "claude-copy", provider: "builtin:anthropic"
        )
        return url
    }

    func testCollectsNativeAndLegacyWithBoundaryDeduplicationAndNormalization() async throws {
        let collector = ZcodeCollector(databaseURL: try makeDatabase(), deviceID: "device-a", timeZone: TimeZone(identifier: "UTC")!)
        let batch = try await collector.collect()
        let records = batch.daily
        XCTAssertEqual(records.count, 3)
        XCTAssertTrue(records.allSatisfy { $0.deviceID == "device-a" && $0.sourceID == "zcode" })

        XCTAssertEqual(records[0].day, "2026-01-01")
        XCTAssertEqual(records[0].modelID, "glm-legacy")
        XCTAssertEqual(records[0].counts, TokenCounts(input: 350, cacheRead: 100, cacheWrite: 50, output: 100, reasoning: 20))

        XCTAssertEqual(records[1].day, "2026-01-02")
        XCTAssertEqual(records[1].modelID, "glm-copy")
        XCTAssertEqual(records[1].counts, TokenCounts(input: 220, cacheRead: 50, cacheWrite: 30, output: 80, reasoning: 10))

        XCTAssertEqual(records[2].day, "2026-01-03")
        XCTAssertEqual(records[2].modelID, "glm-native")
        XCTAssertEqual(records[2].counts, TokenCounts(input: 600, cacheRead: 300, cacheWrite: 100, output: 150, reasoning: 50))
    }

    func testLocalDaysAndRealHourlyTimestamps() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-01-03T00:30:00Z")!
        let collector = ZcodeCollector(databaseURL: try makeDatabase(), deviceID: "device-a",
            timeZone: TimeZone(identifier: "America/Los_Angeles")!, now: now)
        let batch = try await collector.collect()
        XCTAssertEqual(batch.daily.map(\.day), ["2026-01-01", "2026-01-02", "2026-01-02"])
        XCTAssertTrue(batch.daily.allSatisfy { $0.timeZoneID == "America/Los_Angeles" && $0.rawModelID == $0.modelID && $0.eventCount == 1 })
        XCTAssertEqual(batch.hourly.count, 3)
        XCTAssertEqual(batch.hourly.last?.hourStart, ISO8601DateFormatter().date(from: "2026-01-03T00:00:00Z"))
        XCTAssertTrue(batch.hourly.allSatisfy(\.reasoningKnown))
        XCTAssertEqual(batch.hourly.reduce(.zero) { $0 + $1.counts }, batch.daily.reduce(.zero) { $0 + $1.counts })
        XCTAssertEqual(batch.hourly.reduce(Int64(0)) { $0 + $1.eventCount }, 3)
        XCTAssertEqual(batch.skippedRecords, 0)
    }

    func testMissingDatabaseThrowsUnavailable() async throws {
        let collector = ZcodeCollector(
            databaseURL: directory.appendingPathComponent("missing.sqlite"),
            deviceID: "device-a"
        )
        do {
            _ = try await collector.collect()
            XCTFail("Missing data must not replace the cached rows with empty data")
        } catch CollectorError.sourceUnavailable {
        }
    }

    private func stateDirectory() -> URL {
        directory.appendingPathComponent("collector-state", isDirectory: true)
    }

    private func commitFullCollect(_ collector: ZcodeCollector) async throws {
        let batch = try await collector.collect()
        XCTAssertFalse(batch.daily.isEmpty)
        for commit in batch.stateCommits { try commit() }
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(120)], ofItemAtPath: url.path
        )
    }

    func testSecondCollectWithoutChangesSkipsWork() async throws {
        let collector = ZcodeCollector(
            databaseURL: try makeDatabase(), deviceID: "device-a",
            timeZone: TimeZone(identifier: "UTC")!, stateDirectory: stateDirectory()
        )
        let first = try await collector.collect()
        XCTAssertEqual(first.daily.count, 3)
        XCTAssertEqual(first.stateCommits.count, 1)
        for commit in first.stateCommits { try commit() }

        let second = try await collector.collect()
        XCTAssertEqual(second.unchangedSourceIDs, ["zcode"])
        XCTAssertTrue(second.daily.isEmpty && second.hourly.isEmpty)
        XCTAssertTrue(second.stateCommits.isEmpty)
    }

    func testTouchingDatabaseForcesFullCollection() async throws {
        let url = try makeDatabase()
        let collector = ZcodeCollector(
            databaseURL: url, deviceID: "device-a",
            timeZone: TimeZone(identifier: "UTC")!, stateDirectory: stateDirectory()
        )
        try await commitFullCollect(collector)
        try touch(url)

        let batch = try await collector.collect()
        XCTAssertTrue(batch.unchangedSourceIDs.isEmpty)
        XCTAssertEqual(batch.daily.count, 3)
        XCTAssertEqual(batch.stateCommits.count, 1)
    }

    func testTouchingWALForcesFullCollection() async throws {
        let url = try makeDatabase()
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
        let liveDB = try XCTUnwrap(writer)
        defer { sqlite3_close(liveDB) }
        try execute(liveDB, "PRAGMA journal_mode=WAL;")
        try execute(liveDB, """
            INSERT INTO model_usage VALUES (
                'completed', \(milliseconds("2026-01-03T03:00:00Z")), 'glm-wal-state', 'zai', 10, 5, 0, 0, 0
            );
            """)
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: walURL.path))

        // Keep the writer open so the WAL file survives the first collection.
        let collector = ZcodeCollector(
            databaseURL: url, deviceID: "device-a",
            timeZone: TimeZone(identifier: "UTC")!, stateDirectory: stateDirectory()
        )
        try await commitFullCollect(collector)
        try touch(walURL)

        let batch = try await collector.collect()
        XCTAssertTrue(batch.unchangedSourceIDs.isEmpty)
        XCTAssertNotNil(batch.daily.first { $0.modelID == "glm-wal-state" })
    }

    func testTimeZoneChangeForcesFullCollection() async throws {
        let url = try makeDatabase()
        let state = stateDirectory()
        try await commitFullCollect(ZcodeCollector(
            databaseURL: url, deviceID: "device-a",
            timeZone: TimeZone(identifier: "UTC")!, stateDirectory: state
        ))

        let collector = ZcodeCollector(
            databaseURL: url, deviceID: "device-a",
            timeZone: TimeZone(identifier: "America/Los_Angeles")!, stateDirectory: state
        )
        let batch = try await collector.collect()
        XCTAssertTrue(batch.unchangedSourceIDs.isEmpty)
        XCTAssertFalse(batch.daily.isEmpty)
        XCTAssertEqual(batch.daily.first?.timeZoneID, "America/Los_Angeles")
    }

    func testNilStateDirectoryWritesNothing() async throws {
        let collector = ZcodeCollector(
            databaseURL: try makeDatabase(), deviceID: "device-a", timeZone: TimeZone(identifier: "UTC")!
        )
        let first = try await collector.collect()
        XCTAssertFalse(first.daily.isEmpty)
        XCTAssertTrue(first.stateCommits.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["db.sqlite"])

        let second = try await collector.collect()
        XCTAssertTrue(second.unchangedSourceIDs.isEmpty)
        XCTAssertEqual(second.daily.count, 3)
    }

    func testInvalidReasoningSplitAndNegativeCounters() async throws {
        let url = try makeDatabase()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        let tsSplit = milliseconds("2026-01-03T01:00:00Z")
        let tsNegative = milliseconds("2026-01-03T01:10:00Z")
        try execute(db, """
            INSERT INTO model_usage VALUES (
                'completed', \(tsSplit), 'glm-split', 'zai', 100, 30, 80, 0, 0
            );
            INSERT INTO model_usage VALUES (
                'completed', \(tsNegative), 'glm-neg', 'zai', -10, 30, 5, 0, 0
            );
            """)
        sqlite3_close(db)

        let now = ISO8601DateFormatter().date(from: "2026-01-03T02:00:00Z")!
        let collector = ZcodeCollector(
            databaseURL: url,
            deviceID: "device-a",
            timeZone: TimeZone(identifier: "UTC")!,
            now: now
        )
        let batch = try await collector.collect()
        XCTAssertEqual(batch.skippedRecords, 1)
        XCTAssertNil(batch.daily.first { $0.modelID == "glm-neg" })

        let splitRecord = try XCTUnwrap(batch.daily.first { $0.modelID == "glm-split" })
        XCTAssertEqual(splitRecord.counts, TokenCounts(input: 100, output: 30, reasoning: 0))

        let splitHour = ISO8601DateFormatter().date(from: "2026-01-03T01:00:00Z")!
        let hourlyBucket = try XCTUnwrap(batch.hourly.first { $0.hourStart == splitHour })
        XCTAssertEqual(hourlyBucket.counts, TokenCounts(input: 100, output: 30, reasoning: 0))
        XCTAssertFalse(hourlyBucket.reasoningKnown)
    }

    func testReadsLiveWALWithOpenWriterAndThrowsWhenOpenFails() async throws {
        let url = try makeDatabase()
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
        let liveDB = try XCTUnwrap(writer)
        try execute(liveDB, "PRAGMA journal_mode=WAL;")
        let walTimestamp = milliseconds("2026-01-03T02:00:00Z")
        try execute(liveDB, """
            INSERT INTO model_usage VALUES (
                'completed', \(walTimestamp), 'glm-wal', 'zai', 50, 20, 5, 0, 0
            );
            """)
        // Keep the writer connection open while collecting so the read sees committed WAL rows.
        let collector = ZcodeCollector(
            databaseURL: url,
            deviceID: "device-a",
            timeZone: TimeZone(identifier: "UTC")!
        )
        let batch = try await collector.collect()
        sqlite3_close(liveDB)
        XCTAssertNotNil(batch.daily.first { $0.modelID == "glm-wal" })

        let corruptURL = directory.appendingPathComponent("corrupt.sqlite")
        try Data("not a sqlite database".utf8).write(to: corruptURL)
        let failingCollector = ZcodeCollector(
            databaseURL: corruptURL,
            deviceID: "device-a",
            timeZone: TimeZone(identifier: "UTC")!
        )
        do {
            _ = try await failingCollector.collect()
            XCTFail("Expected corrupt database open to throw")
        } catch {
        }
    }

    func testReadsClosedWALDatabaseWithoutSidecars() async throws {
        let url = try makeDatabase()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        try execute(db, "PRAGMA journal_mode=WAL;")
        try execute(db, "PRAGMA wal_checkpoint(TRUNCATE);")
        sqlite3_close(db)

        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))
        let header = try Data(contentsOf: url)
        XCTAssertGreaterThanOrEqual(header.count, 20)
        XCTAssertEqual(header[18], 2)
        XCTAssertEqual(header[19], 2)

        let collector = ZcodeCollector(
            databaseURL: url,
            deviceID: "device-a",
            timeZone: TimeZone(identifier: "UTC")!
        )
        let batch = try await collector.collect()

        XCTAssertEqual(batch.daily.count, 3)
        XCTAssertEqual(batch.daily[0].counts, TokenCounts(input: 350, cacheRead: 100, cacheWrite: 50, output: 100, reasoning: 20))
        XCTAssertEqual(batch.daily[1].counts, TokenCounts(input: 220, cacheRead: 50, cacheWrite: 30, output: 80, reasoning: 10))
        XCTAssertEqual(batch.daily[2].counts, TokenCounts(input: 600, cacheRead: 300, cacheWrite: 100, output: 150, reasoning: 50))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))
    }

    func testSchemaFailureThrowsInsteadOfReturningEmpty() async throws {
        let url = directory.appendingPathComponent("missing-schema.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        try execute(db, "CREATE TABLE unrelated (id INTEGER);")
        sqlite3_close(db)

        let collector = ZcodeCollector(
            databaseURL: url,
            deviceID: "device-a",
            timeZone: TimeZone(identifier: "UTC")!
        )
        do {
            _ = try await collector.collect()
            XCTFail("Missing schema tables must throw")
        } catch CollectorError.sql {
        }
    }

    func testInvalidNativeTimestampsDoNotBoundLegacyHistory() async throws {
        let url = try makeDatabase()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        try execute(db, """
            INSERT INTO model_usage VALUES (
                'completed', 0, 'glm-zero', 'zai', 10, 5, 0, 0, 0
            );
            INSERT INTO model_usage VALUES (
                'completed', -1, 'glm-negative', 'zai', 10, 5, 0, 0, 0
            );
            INSERT INTO model_usage VALUES (
                'completed', 'invalid', 'glm-invalid', 'zai', 10, 5, 0, 0, 0
            );
            """)
        sqlite3_close(db)

        let collector = ZcodeCollector(
            databaseURL: url,
            deviceID: "device-a",
            timeZone: TimeZone(identifier: "UTC")!
        )
        let batch = try await collector.collect()
        XCTAssertEqual(batch.daily.count, 3)
        XCTAssertNotNil(batch.daily.first { $0.modelID == "glm-legacy" })
        XCTAssertNotNil(batch.daily.first { $0.modelID == "glm-copy" })
        XCTAssertNotNil(batch.daily.first { $0.modelID == "glm-native" })
        XCTAssertNil(batch.daily.first { $0.modelID == "glm-after" })
        XCTAssertEqual(batch.skippedRecords, 3)
    }

    func testLegacyInvalidJSONRowIsSkippedWithoutFailing() async throws {
        let url = try makeDatabase()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        let beforeBoundary = milliseconds("2026-01-03T00:00:00Z") - 1_000
        try execute(db, """
            INSERT INTO message (session_id, time_created, time_updated, data)
            VALUES ('session-bad-json', \(beforeBoundary), \(beforeBoundary), '{not-valid-json');
            """)
        sqlite3_close(db)

        let collector = ZcodeCollector(
            databaseURL: url,
            deviceID: "device-a",
            timeZone: TimeZone(identifier: "UTC")!
        )
        let batch = try await collector.collect()

        XCTAssertEqual(batch.daily.count, 3)
        XCTAssertEqual(batch.skippedRecords, 1)
    }

    func testISOStartedAtInNativeTableIsSkipped() async throws {
        let url = try makeDatabase()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        try execute(db, """
            INSERT INTO model_usage VALUES (
                'completed', '2026-01-03T00:00:00Z', 'glm-iso', 'zai', 10, 5, 0, 0, 0
            );
            """)
        sqlite3_close(db)

        let collector = ZcodeCollector(
            databaseURL: url,
            deviceID: "device-a",
            timeZone: TimeZone(identifier: "UTC")!
        )
        let batch = try await collector.collect()

        XCTAssertEqual(batch.daily.count, 3)
        XCTAssertNil(batch.daily.first { $0.modelID == "glm-iso" })
        XCTAssertNil(batch.daily.first { $0.day == "1970-01-01" })
        XCTAssertEqual(batch.skippedRecords, 1)
    }

    func testFutureTimestampIsSkipped() async throws {
        let url = try makeDatabase()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        let future = milliseconds("2026-01-05T00:00:00Z")
        try execute(db, """
            INSERT INTO model_usage VALUES (
                'completed', \(future), 'glm-future', 'zai', 10, 5, 0, 0, 0
            );
            """)
        sqlite3_close(db)

        let now = ISO8601DateFormatter().date(from: "2026-01-03T02:00:00Z")!
        let collector = ZcodeCollector(
            databaseURL: url,
            deviceID: "device-a",
            timeZone: TimeZone(identifier: "UTC")!,
            now: now
        )
        let batch = try await collector.collect()

        XCTAssertNil(batch.daily.first { $0.modelID == "glm-future" })
        XCTAssertEqual(batch.skippedRecords, 1)
    }
}
