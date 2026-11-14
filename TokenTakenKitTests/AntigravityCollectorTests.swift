import XCTest
import SQLite3
@testable import TokenTakenKit

final class AntigravityCollectorTests: XCTestCase {
    /// Pinned so the 48-hour hourly window is deterministic.
    static let now = ISO8601DateFormatter().date(from: "2026-11-11T06:00:00Z")!
    private let utc = TimeZone(identifier: "UTC")!

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

    /// SQLite copies bound bytes immediately instead of keeping a pointer into a temporary buffer.
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Protobuf encoding

    private func varint(_ value: UInt64) -> [UInt8] {
        var result: [UInt8] = []
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            result.append(byte)
        } while remaining != 0
        return result
    }

    private func field(_ number: Int, varint value: UInt64) -> [UInt8] {
        varint(UInt64(number) << 3) + varint(value)
    }

    private func field(_ number: Int, bytes: [UInt8]) -> [UInt8] {
        varint((UInt64(number) << 3) | 2) + varint(UInt64(bytes.count)) + bytes
    }

    private func field(_ number: Int, text: String) -> [UInt8] {
        field(number, bytes: Array(text.utf8))
    }

    /// `{#1: seconds, #2: nanos}`.
    private func timestamp(milliseconds: Int64) -> [UInt8] {
        let seconds = milliseconds / 1_000
        let nanos = (milliseconds % 1_000) * 1_000_000
        return field(1, varint: UInt64(bitPattern: seconds)) + field(2, varint: UInt64(nanos))
    }

    // MARK: - Row encoding

    private struct Row {
        var responseID: String? = nil
        var model: String? = nil
        var label: String? = nil
        var fixedPrompt: UInt64 = 1_132
        var input: UInt64 = 0
        var cacheRead: UInt64 = 0
        /// `chatModel.#3`, the stored total output; never counted.
        var totalOutput: UInt64? = nil
        var output: UInt64 = 0
        var reasoning: UInt64 = 0
        /// `chatModel.#9.#4` explicit per-turn Timestamp in epoch ms.
        var explicit: Int64? = nil
    }

    private func blob(_ row: Row) -> [UInt8] {
        var usage: [UInt8] = []
        if row.fixedPrompt != 0 { usage += field(1, varint: row.fixedPrompt) }
        if row.input != 0 { usage += field(2, varint: row.input) }
        if let totalOutput = row.totalOutput, totalOutput != 0 { usage += field(3, varint: totalOutput) }
        if row.cacheRead != 0 { usage += field(5, varint: row.cacheRead) }
        if row.output != 0 { usage += field(9, varint: row.output) }
        if row.reasoning != 0 { usage += field(10, varint: row.reasoning) }
        if let responseID = row.responseID { usage += field(11, text: responseID) }

        var chat = field(4, bytes: usage)
        if let explicit = row.explicit { chat += field(9, bytes: field(4, bytes: timestamp(milliseconds: explicit))) }
        if let model = row.model { chat += field(19, text: model) }
        if let label = row.label { chat += field(21, text: label) }
        return field(1, bytes: chat)
    }

    private struct Step {
        var milliseconds: Int64
        var responseID: String? = nil
        var index: UInt64? = nil
    }

    // MARK: - Synthetic databases

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let error = message.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(message)
            throw TestError.sqlite(error)
        }
    }

    private func insertGenerationRows(_ db: OpaquePointer, rows: [[UInt8]], startingAt offset: Int64 = 0) throws {
        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO gen_metadata VALUES (?1, ?2, 0);", -1, &insert, nil) == SQLITE_OK,
              let insert else { throw TestError.sqlite("Could not prepare insert") }
        defer { sqlite3_finalize(insert) }
        for (index, row) in rows.enumerated() {
            sqlite3_reset(insert)
            sqlite3_bind_int64(insert, 1, offset + Int64(index))
            _ = row.withUnsafeBytes { sqlite3_bind_blob(insert, 2, $0.baseAddress, Int32(row.count), transient) }
            guard sqlite3_step(insert) == SQLITE_DONE else { throw TestError.sqlite("Could not insert row") }
        }
    }

    private func writeDatabase(
        at url: URL,
        rows: [[UInt8]],
        anchor: Int64? = nil,
        steps: [Step] = [],
        includeMetadataTable: Bool = true,
        walMode: Bool = false
    ) throws {
        try? FileManager.default.removeItem(at: url)
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let db = handle else {
            throw TestError.sqlite("Could not create synthetic database")
        }
        defer { sqlite3_close(db) }
        if walMode {
            try execute(db, "PRAGMA journal_mode=WAL;")
        }
        try execute(db, "CREATE TABLE gen_metadata (idx INTEGER, data BLOB, size INTEGER);")
        if includeMetadataTable {
            try execute(db, "CREATE TABLE trajectory_metadata_blob (id TEXT, data BLOB);")
        }
        try execute(db, "CREATE TABLE steps (idx INTEGER, step_type INTEGER, metadata BLOB);")

        try insertGenerationRows(db, rows: rows)

        if let anchor {
            let data = field(2, bytes: timestamp(milliseconds: anchor))
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "INSERT INTO trajectory_metadata_blob VALUES ('main', ?1);", -1, &statement, nil
            ) == SQLITE_OK, let statement else { throw TestError.sqlite("Could not prepare metadata insert") }
            defer { sqlite3_finalize(statement) }
            _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(data.count), transient) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw TestError.sqlite("Could not insert metadata") }
        }

        for (offset, step) in steps.enumerated() {
            var metadata = field(1, bytes: timestamp(milliseconds: step.milliseconds))
            if let responseID = step.responseID { metadata += field(9, bytes: field(11, text: responseID)) }
            if let index = step.index { metadata += field(20, bytes: field(3, varint: index)) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "INSERT INTO steps VALUES (?1, 15, ?2);", -1, &statement, nil
            ) == SQLITE_OK, let statement else { throw TestError.sqlite("Could not prepare step insert") }
            sqlite3_bind_int64(statement, 1, Int64(offset))
            _ = metadata.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(metadata.count), transient) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw TestError.sqlite("Could not insert step") }
            sqlite3_finalize(statement)
        }
    }

    // MARK: - Helpers

    private func milliseconds(_ value: String) -> Int64 {
        Int64(ISO8601DateFormatter().date(from: value)!.timeIntervalSince1970 * 1_000)
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func makeHome() throws -> URL {
        let home = directory.appendingPathComponent("home", isDirectory: true)
        try makeDirectory(home)
        return home
    }

    private func cliRoot(_ home: URL) -> URL {
        home.appendingPathComponent(".gemini/antigravity-cli/conversations", isDirectory: true)
    }

    private func extensionRoot(_ home: URL) -> URL {
        home.appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true)
    }

    private func collector(
        home: URL,
        environment: [String: String] = [:],
        timeZone: TimeZone? = nil,
        stateDirectory: URL? = nil
    ) -> AntigravityCollector {
        AntigravityCollector(
            home: home,
            environment: environment,
            deviceID: "device-a",
            timeZone: timeZone ?? utc,
            now: Self.now,
            stateDirectory: stateDirectory
        )
    }

    // MARK: - Tests

    func testCountsNewInputOnlyAndKeepsReasoningSeparate() async throws {
        let home = try makeHome()
        try makeDirectory(cliRoot(home))
        let start = milliseconds("2026-11-10T10:00:00Z")
        try writeDatabase(at: cliRoot(home).appendingPathComponent("conv-a.db"), rows: [
            blob(Row(
                responseID: "resp-1", model: "gemini-4-argon", label: "Gemini 4 Argon",
                fixedPrompt: 1_417, input: 500, cacheRead: 40, totalOutput: 340,
                output: 300, reasoning: 40, explicit: start
            )),
        ])

        let batch = try await collector(home: home).collect()

        XCTAssertEqual(batch.skippedRecords, 0)
        XCTAssertEqual(batch.daily.count, 1)
        let record = try XCTUnwrap(batch.daily.first)
        XCTAssertEqual(record.day, "2026-11-10")
        XCTAssertEqual(record.timeZoneID, utc.identifier)
        XCTAssertEqual(record.sourceID, "antigravity")
        XCTAssertEqual(record.modelID, "gemini-4-argon")
        XCTAssertEqual(record.rawModelID, "gemini-4-argon")
        XCTAssertEqual(record.eventCount, 1)
        XCTAssertEqual(record.counts.input, 500, "usage #1 must not be counted as input, and #2 is already uncached")
        XCTAssertEqual(record.counts.cacheRead, 40)
        XCTAssertEqual(record.counts.cacheWrite, 0)
        XCTAssertEqual(record.counts.output, 300)
        XCTAssertEqual(record.counts.reasoning, 40)
        XCTAssertEqual(record.counts.total, 880)

        XCTAssertEqual(batch.hourly.count, 1)
        let hourly = try XCTUnwrap(batch.hourly.first)
        XCTAssertEqual(hourly.hourStart, Date(timeIntervalSince1970: Double(start) / 1_000))
        XCTAssertEqual(hourly.eventCount, 1)
        XCTAssertEqual(hourly.counts.input, 500)
        XCTAssertTrue(hourly.reasoningKnown)
    }

    func testDeduplicatesResponseIdAcrossClientRoots() async throws {
        let home = try makeHome()
        try makeDirectory(cliRoot(home))
        try makeDirectory(extensionRoot(home))
        let stamp = milliseconds("2026-11-10T10:00:00Z")
        // The CLI database deliberately sorts last by name: the root order decides the winner, not the file name.
        try writeDatabase(at: cliRoot(home).appendingPathComponent("z-conv.db"), rows: [
            blob(Row(responseID: "shared", model: "gemini-4-carbon", input: 100, output: 10, explicit: stamp)),
        ])
        try writeDatabase(at: extensionRoot(home).appendingPathComponent("a-conv.db"), rows: [
            blob(Row(responseID: "shared", model: "gemini-4-carbon", input: 900, output: 90, explicit: stamp)),
            blob(Row(responseID: "ext-only", model: "gemini-4-carbon", input: 50, explicit: stamp)),
        ])

        let batch = try await collector(home: home).collect()

        let record = try XCTUnwrap(batch.daily.first)
        XCTAssertEqual(batch.daily.count, 1)
        XCTAssertEqual(record.counts.input, 150)
        XCTAssertEqual(record.counts.output, 10)
        XCTAssertEqual(record.eventCount, 2)
    }

    func testCountsRowWithoutResponseIdOnce() async throws {
        let home = try makeHome()
        try makeDirectory(cliRoot(home))
        let stamp = milliseconds("2026-11-10T10:00:00Z")
        try writeDatabase(at: cliRoot(home).appendingPathComponent("conv.db"), rows: [
            blob(Row(responseID: nil, model: "gemini-4-argon", input: 70, explicit: stamp)),
            blob(Row(responseID: "  ", model: "gemini-4-argon", input: 30, explicit: stamp)),
        ])

        let batch = try await collector(home: home).collect()

        let record = try XCTUnwrap(batch.daily.first)
        XCTAssertEqual(record.counts.input, 100)
        XCTAssertEqual(record.eventCount, 2)
        XCTAssertEqual(batch.skippedRecords, 0)
    }

    func testModelRecoveredFromSiblingDisplayLabel() async throws {
        let home = try makeHome()
        try makeDirectory(cliRoot(home))
        try writeDatabase(at: cliRoot(home).appendingPathComponent("conv.db"), rows: [
            blob(Row(
                responseID: "resp-1", model: "gemini-4-argon", label: "Gemini 4 Argon",
                input: 10, explicit: milliseconds("2026-11-09T10:00:00Z")
            )),
            blob(Row(
                responseID: "resp-2", model: "gemini-default", label: "Gemini 4 Argon",
                input: 20, explicit: milliseconds("2026-11-10T10:00:00Z")
            )),
        ])

        let batch = try await collector(home: home).collect()

        XCTAssertEqual(batch.daily.map(\.modelID), ["gemini-4-argon", "gemini-4-argon"])
        XCTAssertEqual(batch.daily.map(\.day), ["2026-11-09", "2026-11-10"])
    }

    func testModelFallsBackToSoleModelThenUnknown() async throws {
        let home = try makeHome()
        try makeDirectory(cliRoot(home))
        try writeDatabase(at: cliRoot(home).appendingPathComponent("sole.db"), rows: [
            blob(Row(
                responseID: "resp-1", model: "gemini-4-carbon", label: "Gemini 4 Carbon",
                input: 10, explicit: milliseconds("2026-11-10T10:00:00Z")
            )),
            blob(Row(
                responseID: "resp-2", model: nil, label: nil,
                input: 20, explicit: milliseconds("2026-11-10T10:00:00Z")
            )),
        ])
        try writeDatabase(at: cliRoot(home).appendingPathComponent("routing.db"), rows: [
            blob(Row(
                responseID: "resp-3", model: "gemini-default", label: "Gemini 9.9 Mystery",
                input: 30, explicit: milliseconds("2026-11-08T10:00:00Z")
            )),
        ])

        let batch = try await collector(home: home).collect()

        let carbon = try XCTUnwrap(batch.daily.first { $0.day == "2026-11-10" })
        XCTAssertEqual(carbon.modelID, "gemini-4-carbon")
        XCTAssertEqual(carbon.eventCount, 2)
        let unknown = try XCTUnwrap(batch.daily.first { $0.day == "2026-11-08" })
        XCTAssertEqual(unknown.modelID, "unknown")
    }

    func testTimestampPrecedence() async throws {
        let home = try makeHome()
        try makeDirectory(cliRoot(home))
        let explicit = milliseconds("2026-11-10T03:00:00Z")
        let byResponse = milliseconds("2026-11-09T03:00:00Z")
        let byIndex = milliseconds("2026-11-08T03:00:00Z")
        let anchor = milliseconds("2026-11-07T03:00:00Z")
        let modified = milliseconds("2026-11-06T12:00:00Z")

        try writeDatabase(
            at: cliRoot(home).appendingPathComponent("precedence.db"),
            rows: [
                blob(Row(responseID: "resp-1", model: "gemini-4-argon", input: 10, explicit: explicit)),
                blob(Row(responseID: "resp-2", model: "gemini-4-argon", input: 20)),
                blob(Row(responseID: "resp-3", model: "gemini-4-argon", input: 30)),
                blob(Row(responseID: "resp-4", model: "gemini-4-argon", input: 40)),
            ],
            anchor: anchor,
            steps: [
                Step(milliseconds: byResponse, responseID: "resp-2", index: 99),
                Step(milliseconds: byIndex, responseID: "step-id-3", index: 2),
            ]
        )

        let mtimeURL = cliRoot(home).appendingPathComponent("mtime.db")
        try writeDatabase(at: mtimeURL, rows: [
            blob(Row(responseID: "resp-m", model: "gemini-4-argon", input: 50)),
        ], anchor: nil)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: Double(modified) / 1_000)],
            ofItemAtPath: mtimeURL.path
        )

        let batch = try await collector(home: home).collect()

        XCTAssertEqual(batch.daily.map(\.day), [
            "2026-11-06", "2026-11-07", "2026-11-08", "2026-11-09", "2026-11-10",
        ])
        XCTAssertEqual(batch.daily.map(\.modelID), Array(repeating: "gemini-4-argon", count: 5))
    }

    func testSkipsZeroUsageAndUndecodableRows() async throws {
        let home = try makeHome()
        try makeDirectory(cliRoot(home))
        let stamp = milliseconds("2026-11-10T10:00:00Z")
        try writeDatabase(at: cliRoot(home).appendingPathComponent("conv.db"), rows: [
            // Only the fixed prompt (#1) and a responseId: nothing counted.
            blob(Row(responseID: "zero", model: "gemini-4-argon", input: 0, output: 0, explicit: stamp)),
            // Not a protobuf message at all.
            [0xFF, 0xFF, 0xFF, 0xFF],
            blob(Row(responseID: "resp-1", model: "gemini-4-argon", input: 10, explicit: stamp)),
        ])

        let batch = try await collector(home: home).collect()

        let record = try XCTUnwrap(batch.daily.first)
        XCTAssertEqual(record.eventCount, 1)
        XCTAssertEqual(record.counts.input, 10)
        XCTAssertEqual(batch.skippedRecords, 1)
    }

    func testZeroUsageAloneLeavesNoPartialRead() async throws {
        let home = try makeHome()
        try makeDirectory(cliRoot(home))
        try writeDatabase(at: cliRoot(home).appendingPathComponent("conv.db"), rows: [
            blob(Row(responseID: "zero", model: "gemini-4-argon", explicit: milliseconds("2026-11-10T10:00:00Z"))),
        ])

        let batch = try await collector(home: home).collect()

        XCTAssertTrue(batch.daily.isEmpty)
        XCTAssertTrue(batch.hourly.isEmpty)
        XCTAssertEqual(batch.skippedRecords, 0)
    }

    func testSkipsDatabaseWithoutGenerationTable() async throws {
        let home = try makeHome()
        try makeDirectory(cliRoot(home))
        let url = cliRoot(home).appendingPathComponent("other.db")
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let db = handle else {
            return XCTFail("Could not create synthetic database")
        }
        defer { sqlite3_close(db) }
        try execute(db, "CREATE TABLE unrelated (value TEXT);")

        let batch = try await collector(home: home).collect()

        XCTAssertTrue(batch.daily.isEmpty)
        XCTAssertEqual(batch.skippedRecords, 0)
    }

    func testUnchangedFingerprintSkipsRecollection() async throws {
        let home = try makeHome()
        try makeDirectory(cliRoot(home))
        let stateDirectory = directory.appendingPathComponent("state", isDirectory: true)
        let url = cliRoot(home).appendingPathComponent("conv.db")
        try writeDatabase(at: url, rows: [
            blob(Row(responseID: "resp-1", model: "gemini-4-argon", input: 10, explicit: milliseconds("2026-11-10T10:00:00Z"))),
        ])

        let first = try await collector(home: home, stateDirectory: stateDirectory).collect()
        XCTAssertEqual(first.daily.count, 1)
        XCTAssertFalse(first.stateCommits.isEmpty)
        for commit in first.stateCommits { try commit() }

        let second = try await collector(home: home, stateDirectory: stateDirectory).collect()
        XCTAssertEqual(second.unchangedSourceIDs, ["antigravity"])
        XCTAssertTrue(second.daily.isEmpty)
        XCTAssertTrue(second.hourly.isEmpty)

        // A changed time zone invalidates the state like a rewritten database does.
        let shifted = TimeZone(secondsFromGMT: 8 * 3_600)!
        let third = try await collector(home: home, timeZone: shifted, stateDirectory: stateDirectory).collect()
        XCTAssertTrue(third.unchangedSourceIDs.isEmpty)
        XCTAssertEqual(third.daily.count, 1)

        for commit in third.stateCommits { try commit() }
        try writeDatabase(at: url, rows: [
            blob(Row(responseID: "resp-1", model: "gemini-4-argon", input: 10, explicit: milliseconds("2026-11-10T10:00:00Z"))),
            blob(Row(responseID: "resp-2", model: "gemini-4-argon", input: 20, explicit: milliseconds("2026-11-10T10:00:00Z"))),
        ])
        let fourth = try await collector(home: home, timeZone: shifted, stateDirectory: stateDirectory).collect()
        XCTAssertTrue(fourth.unchangedSourceIDs.isEmpty)
        let record = try XCTUnwrap(fourth.daily.first)
        XCTAssertEqual(record.eventCount, 2)
    }

    func testUnavailableWhenNeitherRootExists() async throws {
        let home = try makeHome()

        do {
            _ = try await collector(home: home).collect()
            XCTFail("Expected sourceUnavailable")
        } catch CollectorError.sourceUnavailable {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHonoursGeminiCliHome() async throws {
        let home = try makeHome()
        let alternate = directory.appendingPathComponent("gemini-home", isDirectory: true)
        let root = alternate.appendingPathComponent("antigravity-cli/conversations", isDirectory: true)
        try makeDirectory(root)
        try writeDatabase(at: root.appendingPathComponent("conv.db"), rows: [
            blob(Row(responseID: "resp-1", model: "gemini-4-argon", input: 10, explicit: milliseconds("2026-11-10T10:00:00Z"))),
        ])

        let batch = try await collector(home: home, environment: ["GEMINI_CLI_HOME": alternate.path]).collect()

        XCTAssertEqual(batch.daily.count, 1)
        XCTAssertEqual(batch.daily.first?.counts.input, 10)
    }

    func testReadsClosedWalDatabaseWithoutSidecars() async throws {
        let home = try makeHome()
        try makeDirectory(cliRoot(home))
        let url = cliRoot(home).appendingPathComponent("closed-wal.db")
        let stamp = milliseconds("2026-11-10T10:00:00Z")
        try writeDatabase(
            at: url,
            rows: [
                blob(Row(
                    responseID: "resp-wal-1", model: "gemini-4-argon",
                    input: 120, cacheRead: 30, output: 80, reasoning: 20, explicit: stamp
                )),
            ],
            walMode: true
        )
        // Apple's SQLite keeps WAL sidecars after close; the client removes them, so the fixture does too.
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))
        let header = try Data(contentsOf: url)
        XCTAssertGreaterThanOrEqual(header.count, 20)
        XCTAssertEqual(header[18], 2)
        XCTAssertEqual(header[19], 2)

        let batch = try await collector(home: home).collect()

        XCTAssertEqual(batch.skippedRecords, 0)
        XCTAssertEqual(batch.daily.count, 1)
        let record = try XCTUnwrap(batch.daily.first)
        XCTAssertEqual(record.eventCount, 1)
        XCTAssertEqual(record.counts.input, 120)
        XCTAssertEqual(record.counts.cacheRead, 30)
        XCTAssertEqual(record.counts.output, 80)
        XCTAssertEqual(record.counts.reasoning, 20)
        XCTAssertEqual(record.counts.total, 250)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))
    }

    func testReadsWalDatabaseWithUncheckpointedWal() async throws {
        let home = try makeHome()
        try makeDirectory(cliRoot(home))
        let staging = directory.appendingPathComponent("staging.db")
        let destination = cliRoot(home).appendingPathComponent("uncheckpointed.db")
        let stamp = milliseconds("2026-11-10T10:00:00Z")

        do {
            var handle: OpaquePointer?
            guard sqlite3_open(staging.path, &handle) == SQLITE_OK, let db = handle else {
                throw TestError.sqlite("Could not create staging WAL database")
            }
            defer { sqlite3_close(db) }
            try execute(db, "PRAGMA journal_mode=WAL;")
            try execute(db, "PRAGMA wal_autocheckpoint=0;")
            try execute(db, "CREATE TABLE gen_metadata (idx INTEGER, data BLOB, size INTEGER);")
            try execute(db, "CREATE TABLE trajectory_metadata_blob (id TEXT, data BLOB);")
            try execute(db, "CREATE TABLE steps (idx INTEGER, step_type INTEGER, metadata BLOB);")
            try insertGenerationRows(db, rows: [
                blob(Row(responseID: "resp-main", model: "gemini-4-argon", input: 100, output: 10, explicit: stamp)),
            ])
            try execute(db, "PRAGMA wal_checkpoint(TRUNCATE);")
            // With autocheckpoint disabled, this row lives only in -wal until checkpointed.
            try insertGenerationRows(db, rows: [
                blob(Row(responseID: "resp-wal", model: "gemini-4-argon", input: 250, output: 40, explicit: stamp)),
            ], startingAt: 1)

            try FileManager.default.copyItem(at: staging, to: destination)
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: staging.path + "-wal"),
                to: URL(fileURLWithPath: destination.path + "-wal")
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + "-shm"))

        let batch = try await collector(home: home).collect()

        XCTAssertEqual(batch.skippedRecords, 0)
        XCTAssertEqual(batch.daily.count, 1)
        let record = try XCTUnwrap(batch.daily.first)
        XCTAssertEqual(record.eventCount, 2)
        XCTAssertEqual(record.counts.input, 350)
        XCTAssertEqual(record.counts.output, 50)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + "-shm"))
    }

    func testUnreadableDatabaseIsPartialReadNotSkipped() async throws {
        let home = try makeHome()
        try makeDirectory(cliRoot(home))
        let corruptURL = cliRoot(home).appendingPathComponent("corrupt.db")
        try Data("not a sqlite database".utf8).write(to: corruptURL)
        let stateDirectory = directory.appendingPathComponent("state", isDirectory: true)

        let batch = try await collector(home: home, stateDirectory: stateDirectory).collect()

        XCTAssertTrue(batch.daily.isEmpty)
        XCTAssertEqual(batch.skippedRecords, 1)
        // No fingerprint is saved, so the next refresh retries the unreadable database.
        XCTAssertTrue(batch.stateCommits.isEmpty)
    }

    func testStateFromBeforeFixIsIgnored() async throws {
        struct LegacyFile: Codable, Sendable {
            var client: String
            var database: FileFingerprint
            var wal: FileFingerprint?
        }
        struct LegacyState: Codable, Sendable {
            var stamp: CollectionStamp
            var files: [LegacyFile]
        }

        let home = try makeHome()
        try makeDirectory(cliRoot(home))
        let stateDirectory = directory.appendingPathComponent("state", isDirectory: true)
        let url = cliRoot(home).appendingPathComponent("conv.db")
        try writeDatabase(
            at: url,
            rows: [
                blob(Row(responseID: "resp-1", model: "gemini-4-argon", input: 42, explicit: milliseconds("2026-11-10T10:00:00Z"))),
            ],
            walMode: true
        )

        let fingerprint = try XCTUnwrap(FileFingerprint(url: url))
        let legacyState = LegacyState(
            stamp: CollectionStamp(formatVersion: 1, timeZone: utc),
            files: [LegacyFile(client: "cli", database: fingerprint, wal: nil)]
        )
        try CollectorStateFile<LegacyState>(directory: stateDirectory, name: "antigravity").save(legacyState)

        let first = try await collector(home: home, stateDirectory: stateDirectory).collect()
        XCTAssertTrue(first.unchangedSourceIDs.isEmpty)
        XCTAssertEqual(first.daily.count, 1)
        XCTAssertEqual(first.daily.first?.counts.input, 42)
        for commit in first.stateCommits { try commit() }

        let second = try await collector(home: home, stateDirectory: stateDirectory).collect()
        XCTAssertEqual(second.unchangedSourceIDs, ["antigravity"])
    }
}
