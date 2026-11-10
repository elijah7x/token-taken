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

    private func day(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: "\(value)T00:00:00Z")!
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
        let collector = ZcodeCollector(databaseURL: try makeDatabase(), deviceID: "device-a")
        let records = try await collector.collect()
        XCTAssertEqual(records.count, 3)
        XCTAssertTrue(records.allSatisfy { $0.deviceID == "device-a" && $0.sourceID == "zcode" })

        XCTAssertEqual(records[0].day, day("2026-01-01"))
        XCTAssertEqual(records[0].modelID, "glm-legacy")
        XCTAssertEqual(records[0].counts, TokenCounts(input: 350, cacheRead: 100, cacheWrite: 50, output: 100, reasoning: 20))

        XCTAssertEqual(records[1].day, day("2026-01-02"))
        XCTAssertEqual(records[1].modelID, "glm-copy")
        XCTAssertEqual(records[1].counts, TokenCounts(input: 220, cacheRead: 50, cacheWrite: 30, output: 80, reasoning: 10))

        XCTAssertEqual(records[2].day, day("2026-01-03"))
        XCTAssertEqual(records[2].modelID, "glm-native")
        XCTAssertEqual(records[2].counts, TokenCounts(input: 600, cacheRead: 300, cacheWrite: 100, output: 150, reasoning: 50))
    }

    func testMissingDatabaseReturnsEmpty() async throws {
        let collector = ZcodeCollector(
            databaseURL: directory.appendingPathComponent("missing.sqlite"),
            deviceID: "device-a"
        )
        let records = try await collector.collect()
        XCTAssertEqual(records, [])
    }
}
