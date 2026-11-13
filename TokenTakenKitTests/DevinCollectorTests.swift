import XCTest
import SQLite3
@testable import TokenTakenKit

final class DevinCollectorTests: XCTestCase {
    private var directory: URL!
    private var home: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        home = directory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private enum TestError: Error {
        case sqlite(String)
    }

    private func seconds(_ value: String) -> Int64 {
        Int64(ISO8601DateFormatter().date(from: value)!.timeIntervalSince1970)
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let error = message.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(message)
            throw TestError.sqlite(error)
        }
    }

    private func quoted(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private struct Session {
        let id: String
        let title: String?
        let model: String?
    }

    private struct Row {
        let rowID: Int64
        let session: String
        let createdAt: Int64
        let message: String
    }

    private func chatMessage(
        role: String = "assistant",
        requestID: String? = nil,
        generationModel: String? = nil,
        numTokens: Int? = nil,
        startedGenerationAt: String? = nil,
        createdAt: String? = nil,
        input: Int? = nil,
        output: Int? = nil,
        cacheRead: Int? = nil,
        cacheWrite: Int? = nil
    ) -> String {
        var metadata: [String: Any] = [:]
        if let requestID { metadata["request_id"] = requestID }
        if let generationModel { metadata["generation_model"] = generationModel }
        if let numTokens { metadata["num_tokens"] = numTokens }
        if let startedGenerationAt { metadata["started_generation_at"] = startedGenerationAt }
        if let createdAt { metadata["created_at"] = createdAt }
        var metrics: [String: Any] = [:]
        if let input { metrics["input_tokens"] = input }
        if let output { metrics["output_tokens"] = output }
        if let cacheRead { metrics["cache_read_tokens"] = cacheRead }
        if let cacheWrite { metrics["cache_creation_tokens"] = cacheWrite }
        if !metrics.isEmpty { metadata["metrics"] = metrics }
        var message: [String: Any] = ["role": role, "content": "synthetic content"]
        if !metadata.isEmpty { message["metadata"] = metadata }
        let data = try! JSONSerialization.data(withJSONObject: message)
        return String(decoding: data, as: UTF8.self)
    }

    private var cliDatabaseURL: URL {
        home.appendingPathComponent(".local/share/devin/cli/sessions.db")
    }

    private var eventsDirectory: URL {
        home.appendingPathComponent("Library/Application Support/Devin/User/acp-events", isDirectory: true)
    }

    @discardableResult
    private func makeDatabase(sessions: [Session], rows: [Row]) throws -> URL {
        let url = cliDatabaseURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let db = handle else {
            throw TestError.sqlite("Could not create synthetic database")
        }
        defer { sqlite3_close(db) }
        try execute(db, "CREATE TABLE sessions (id TEXT, title TEXT, model TEXT);")
        try execute(db, """
            CREATE TABLE message_nodes (
                row_id INTEGER PRIMARY KEY,
                session_id TEXT,
                chat_message TEXT,
                created_at INTEGER
            );
            """)
        for session in sessions {
            try execute(db, """
                INSERT INTO sessions VALUES (\(quoted(session.id)), \(quoted(session.title)), \(quoted(session.model)));
                """)
        }
        for row in rows {
            try execute(db, """
                INSERT INTO message_nodes VALUES (\(row.rowID), \(quoted(row.session)), \(quoted(row.message)), \(row.createdAt));
                """)
        }
        return url
    }

    private func collector(
        timeZone: TimeZone = TimeZone(identifier: "UTC")!,
        now: Date = .now,
        stateDirectory: URL? = nil
    ) -> DevinCollector {
        DevinCollector(
            home: home, environment: [:], deviceID: "device-a",
            timeZone: timeZone, now: now, stateDirectory: stateDirectory
        )
    }

    func testDeduplicatesRequestIDsAndIgnoresNonAssistantRows() async throws {
        let request = chatMessage(
            requestID: "request-1", generationModel: "swe-2",
            startedGenerationAt: "2026-01-02T10:00:00.000Z",
            input: 100, output: 10, cacheRead: 50, cacheWrite: 20
        )
        let duplicate = chatMessage(
            requestID: "request-1", generationModel: "swe-2",
            startedGenerationAt: "2026-01-02T11:00:00.000Z",
            input: 999, output: 999
        )
        try makeDatabase(
            sessions: [Session(id: "session-a", title: nil, model: "swe-2")],
            rows: [
                Row(rowID: 1, session: "session-a", createdAt: seconds("2026-01-03T00:00:00Z"), message: request),
                Row(rowID: 2, session: "session-a", createdAt: seconds("2026-01-03T00:10:00Z"), message: duplicate),
                Row(rowID: 3, session: "session-a", createdAt: seconds("2026-01-03T00:20:00Z"),
                    message: chatMessage(role: "user", input: 500)),
            ]
        )

        let batch = try await collector().collect()
        XCTAssertEqual(batch.daily.count, 1)
        let record = try XCTUnwrap(batch.daily.first)
        XCTAssertEqual(record.sourceID, "devin")
        XCTAssertEqual(record.day, "2026-01-02")
        XCTAssertEqual(record.modelID, "swe-2")
        XCTAssertEqual(record.counts, TokenCounts(input: 100, cacheRead: 50, cacheWrite: 20, output: 10))
        XCTAssertEqual(record.eventCount, 1)
        XCTAssertEqual(batch.skippedRecords, 0)
    }

    func testFallsBackToNumTokensAndDropsZeroUsageRows() async throws {
        try makeDatabase(
            sessions: [Session(id: "session-a", title: nil, model: "swe-2")],
            rows: [
                Row(rowID: 1, session: "session-a", createdAt: seconds("2026-01-02T09:00:00Z"),
                    message: chatMessage(
                        requestID: "total-only", generationModel: "swe-2",
                        numTokens: 42, startedGenerationAt: "2026-01-02T10:00:00.000Z",
                        input: 0, output: 0, cacheRead: 0, cacheWrite: 0
                    )),
                Row(rowID: 2, session: "session-a", createdAt: seconds("2026-01-02T09:10:00Z"),
                    message: chatMessage(
                        requestID: "zero", generationModel: "swe-2",
                        numTokens: 0, startedGenerationAt: "2026-01-02T10:10:00.000Z"
                    )),
                Row(rowID: 3, session: "session-a", createdAt: seconds("2026-01-02T09:20:00Z"),
                    message: chatMessage(
                        requestID: "zero-metrics", generationModel: "swe-2",
                        startedGenerationAt: "2026-01-02T10:20:00.000Z",
                        input: 0, output: 0
                    )),
            ]
        )

        let batch = try await collector().collect()
        XCTAssertEqual(batch.daily.count, 1)
        let record = try XCTUnwrap(batch.daily.first)
        XCTAssertEqual(record.counts, TokenCounts(output: 42))
        XCTAssertEqual(record.eventCount, 1)
        XCTAssertEqual(batch.skippedRecords, 0)
    }

    func testModelResolutionSkipsRoutingSessionsAndUnparseableRows() async throws {
        try makeDatabase(
            sessions: [
                Session(id: "session-routing", title: nil, model: "adaptive"),
                Session(id: "session-model", title: nil, model: "gpt-5-6-sol-medium"),
            ],
            rows: [
                Row(rowID: 1, session: "session-routing", createdAt: seconds("2026-01-02T09:00:00Z"),
                    message: chatMessage(
                        requestID: "routing", startedGenerationAt: "2026-01-02T09:00:00.000Z", input: 10
                    )),
                Row(rowID: 2, session: "session-model", createdAt: seconds("2026-01-02T09:10:00Z"),
                    message: chatMessage(
                        requestID: "session-model", startedGenerationAt: "2026-01-02T09:10:00.000Z", input: 10
                    )),
                Row(rowID: 3, session: "session-model", createdAt: seconds("2026-01-02T09:20:00Z"),
                    message: chatMessage(
                        requestID: "own-model", generationModel: "swe-2-high",
                        startedGenerationAt: "2026-01-02T09:20:00.000Z", input: 5
                    )),
                Row(rowID: 4, session: "session-model", createdAt: seconds("2026-01-02T09:30:00Z"),
                    message: "not json"),
            ]
        )

        let batch = try await collector().collect()
        XCTAssertEqual(batch.daily.map(\.modelID), ["gpt-5-6-sol-medium", "swe-2-high"])
        XCTAssertEqual(batch.daily.map(\.counts), [TokenCounts(input: 10), TokenCounts(input: 5)])
        XCTAssertEqual(batch.skippedRecords, 2)
    }

    func testDatesTurnsByRequestStampNotRowWriteTime() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-01-02T12:30:00Z")!
        try makeDatabase(
            sessions: [Session(id: "session-a", title: nil, model: "swe-2")],
            rows: [
                // The row lands two days after the request.
                Row(rowID: 1, session: "session-a", createdAt: seconds("2026-01-03T12:00:00Z"),
                    message: chatMessage(
                        requestID: "request-time", generationModel: "swe-2",
                        startedGenerationAt: "2026-01-01T23:50:00.000Z",
                        createdAt: "2026-01-01T23:52:00.000Z", input: 10
                    )),
                // No request stamp: the message's own creation stamp is next.
                Row(rowID: 2, session: "session-a", createdAt: seconds("2026-01-03T12:30:00Z"),
                    message: chatMessage(
                        requestID: "message-time", generationModel: "swe-2",
                        createdAt: "2026-01-02T05:00:00.000Z", input: 20
                    )),
                // Neither: the row write time is the last resort.
                Row(rowID: 3, session: "session-a", createdAt: seconds("2026-01-02T06:00:00Z"),
                    message: chatMessage(requestID: "row-time", generationModel: "swe-2", input: 30)),
            ]
        )

        let batch = try await collector(now: now).collect()
        XCTAssertEqual(batch.daily.map(\.day), ["2026-01-01", "2026-01-02"])
        XCTAssertEqual(batch.daily.map(\.counts), [TokenCounts(input: 10), TokenCounts(input: 50)])
        XCTAssertEqual(batch.hourly.map(\.hourStart), [
            ISO8601DateFormatter().date(from: "2026-01-01T23:00:00Z")!,
            ISO8601DateFormatter().date(from: "2026-01-02T05:00:00Z")!,
            ISO8601DateFormatter().date(from: "2026-01-02T06:00:00Z")!,
        ])
        XCTAssertEqual(batch.hourly.reduce(Int64(0)) { $0 + $1.eventCount }, 3)
        XCTAssertFalse(batch.hourly.contains { $0.reasoningKnown })
    }

    func testDesktopACPUsageAggregatesAndSuppressesCLISessions() async throws {
        try makeDatabase(
            sessions: [Session(id: "session-cli", title: "Fix the flaky test", model: "swe-2")],
            rows: [
                Row(rowID: 1, session: "session-cli", createdAt: seconds("2026-01-02T10:00:00Z"),
                    message: chatMessage(
                        requestID: "cli-request", generationModel: "swe-2",
                        startedGenerationAt: "2026-01-02T10:00:00.000Z", input: 100
                    )),
            ]
        )
        try FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)

        let suppressed = [
            #"{"notification":{"sessionUpdate":"session_info_update","title":"Fix the flaky test"}}"#,
            #"{"notification":{"sessionUpdate":"usage_update","_meta":{"cognition.ai/inputTokens":500,"cognition.ai/cachedReadTokens":200,"cognition.ai/outputTokens":60}}}"#,
        ].joined(separator: "\n")
        try Data(suppressed.utf8).write(to: eventsDirectory.appendingPathComponent("session-cli.ndjson"))

        // Cumulative usage: input and caches overwrite, output adds.
        let desktop = [
            #"{"notification":{"sessionUpdate":"usage_update","_meta":{"cognition.ai/inputTokens":100,"cognition.ai/cachedReadTokens":40,"cognition.ai/cachedWriteTokens":0,"cognition.ai/outputTokens":30,"cognition.ai/model":"swe-2-desktop"},"content":{"metadata":{"created_at":"2026-01-05T10:15:00.000Z"}}}}"#,
            #"{"notification":{"sessionUpdate":"usage_update","_meta":{"cognition.ai/inputTokens":150,"cognition.ai/outputTokens":20},"content":{"metadata":{"created_at":"2026-01-05T10:20:00.000Z"}}}}"#,
        ].joined(separator: "\n")
        try Data(desktop.utf8).write(to: eventsDirectory.appendingPathComponent("desktop-b.ndjson"))

        let batch = try await collector().collect()
        XCTAssertEqual(batch.daily.map(\.day), ["2026-01-02", "2026-01-05"])
        XCTAssertEqual(batch.daily.map(\.modelID), ["swe-2", "swe-2-desktop"])
        XCTAssertEqual(batch.daily.last?.counts, TokenCounts(input: 110, cacheRead: 40, output: 50))
        XCTAssertEqual(batch.skippedRecords, 0)
    }

    func testUnchangedFingerprintSkipsWork() async throws {
        try makeDatabase(
            sessions: [Session(id: "session-a", title: nil, model: "swe-2")],
            rows: [
                Row(rowID: 1, session: "session-a", createdAt: seconds("2026-01-02T10:00:00Z"),
                    message: chatMessage(
                        requestID: "request-1", generationModel: "swe-2",
                        startedGenerationAt: "2026-01-02T10:00:00.000Z", input: 100
                    )),
            ]
        )
        let state = directory.appendingPathComponent("collector-state", isDirectory: true)
        let first = try await collector(stateDirectory: state).collect()
        XCTAssertEqual(first.daily.count, 1)
        XCTAssertEqual(first.stateCommits.count, 1)
        for commit in first.stateCommits { try commit() }

        let second = try await collector(stateDirectory: state).collect()
        XCTAssertEqual(second.unchangedSourceIDs, ["devin"])
        XCTAssertTrue(second.daily.isEmpty && second.hourly.isEmpty)
        XCTAssertTrue(second.stateCommits.isEmpty)
    }

    func testSharedMemoryIndexDoesNotTriggerRescan() async throws {
        try makeDatabase(
            sessions: [Session(id: "session-a", title: nil, model: "swe-2")],
            rows: [
                Row(rowID: 1, session: "session-a", createdAt: seconds("2026-01-02T10:00:00Z"),
                    message: chatMessage(
                        requestID: "request-1", generationModel: "swe-2",
                        startedGenerationAt: "2026-01-02T10:00:00.000Z", input: 100
                    )),
            ]
        )
        let state = directory.appendingPathComponent("collector-state", isDirectory: true)
        let first = try await collector(stateDirectory: state).collect()
        XCTAssertEqual(first.daily.count, 1)
        for commit in first.stateCommits { try commit() }

        // Opening the database rewrites only the shared-memory index, never the content.
        let shm = URL(fileURLWithPath: cliDatabaseURL.path + "-shm")
        try Data(count: 4_096).write(to: shm)
        let afterSharedMemory = try await collector(stateDirectory: state).collect()
        XCTAssertEqual(afterSharedMemory.unchangedSourceIDs, ["devin"])
        XCTAssertTrue(afterSharedMemory.daily.isEmpty && afterSharedMemory.hourly.isEmpty)

        // A real change to the database still rescans; the stray index file must not disturb SQLite.
        try? FileManager.default.removeItem(at: shm)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(60)],
            ofItemAtPath: cliDatabaseURL.path)
        let afterChange = try await collector(stateDirectory: state).collect()
        XCTAssertTrue(afterChange.unchangedSourceIDs.isEmpty)
        XCTAssertEqual(afterChange.daily.count, 1)
    }

    func testMissingSourceThrowsUnavailable() async throws {
        do {
            _ = try await collector().collect()
            XCTFail("A source with neither a CLI database nor Desktop events must be unavailable")
        } catch CollectorError.sourceUnavailable {
        }
    }
}
