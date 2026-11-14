import SQLite3
import XCTest
@testable import TokenTakenKit

final class SQLiteSnapshotReaderTests: XCTestCase {
    private var directory: URL!
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        temporaryDirectory = directory.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private enum TestError: Error {
        case sqlite(String)
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let error = message.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(message)
            throw TestError.sqlite(error)
        }
    }

    private func readLabels(from db: OpaquePointer) throws -> [String] {
        let statement = try SQLiteSnapshotReader.prepare(db, "SELECT label FROM items ORDER BY id;")
        defer { sqlite3_finalize(statement) }
        var labels: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw SQLiteSnapshotReader.lastError(db) }
            if let text = sqlite3_column_text(statement, 0) {
                labels.append(String(cString: text))
            }
        }
        return labels
    }

    func testReadsNormalRollbackJournalDatabase() throws {
        let url = directory.appendingPathComponent("rollback.db")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        try execute(db, "CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT);")
        try execute(db, "INSERT INTO items VALUES (1, 'alpha'), (2, 'beta');")
        sqlite3_close(db)

        let labels = try SQLiteSnapshotReader.withReadableDatabase(at: url, temporaryDirectory: temporaryDirectory) { db in
            XCTAssertTrue(try SQLiteSnapshotReader.tableExists(db, "items"))
            return try readLabels(from: db)
        }

        XCTAssertEqual(labels, ["alpha", "beta"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path), [])
    }

    func testReadsClosedWALDatabaseWithoutSidecars() throws {
        let url = directory.appendingPathComponent("closed-wal.db")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        try execute(db, "PRAGMA journal_mode=WAL;")
        try execute(db, "CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT);")
        try execute(db, "INSERT INTO items VALUES (1, 'closed-wal-row');")
        sqlite3_close(db)

        // Apple's SQLite keeps WAL sidecars after close; delete them to reproduce a client-cleaned WAL DB.
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))
        let header = try Data(contentsOf: url)
        XCTAssertGreaterThanOrEqual(header.count, 20)
        XCTAssertEqual(header[18], 2)
        XCTAssertEqual(header[19], 2)

        let labels = try SQLiteSnapshotReader.withReadableDatabase(at: url, temporaryDirectory: temporaryDirectory) { db in
            try readLabels(from: db)
        }

        XCTAssertEqual(labels, ["closed-wal-row"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path), [])
    }

    func testReadsOrphanedWALDatabaseWithoutCreatingShm() throws {
        let staging = directory.appendingPathComponent("staging.db")
        let orphaned = directory.appendingPathComponent("orphaned.db")

        do {
            var handle: OpaquePointer?
            XCTAssertEqual(sqlite3_open(staging.path, &handle), SQLITE_OK)
            let db = try XCTUnwrap(handle)
            defer { sqlite3_close(db) }
            try execute(db, "PRAGMA journal_mode=WAL;")
            try execute(db, "PRAGMA wal_autocheckpoint=0;")
            try execute(db, "CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT);")
            try execute(db, "INSERT INTO items VALUES (1, 'main-row');")
            try execute(db, "PRAGMA wal_checkpoint(TRUNCATE);")
            // With autocheckpoint disabled, this row exists only in `-wal` until checkpointed.
            try execute(db, "INSERT INTO items VALUES (2, 'wal-only-row');")

            try FileManager.default.copyItem(at: staging, to: orphaned)
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: staging.path + "-wal"),
                to: URL(fileURLWithPath: orphaned.path + "-wal")
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: orphaned.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphaned.path + "-shm"))

        let labels = try SQLiteSnapshotReader.withReadableDatabase(at: orphaned, temporaryDirectory: temporaryDirectory) { db in
            try readLabels(from: db)
        }

        XCTAssertEqual(labels, ["main-row", "wal-only-row"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphaned.path + "-shm"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path), [])
    }

    func testGarbageFileThrowsCollectorError() throws {
        let corrupt = directory.appendingPathComponent("corrupt.db")
        try Data("not a sqlite database".utf8).write(to: corrupt)

        XCTAssertThrowsError(
            try SQLiteSnapshotReader.withReadableDatabase(at: corrupt, temporaryDirectory: temporaryDirectory) { _ in }
        ) { error in
            XCTAssertTrue(error is CollectorError)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path), [])
    }

    func testTableExistsReturnsFalseWhenAbsentAndThrowsOnUnreadableDatabase() throws {
        let valid = directory.appendingPathComponent("valid.db")
        var validHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(valid.path, &validHandle), SQLITE_OK)
        let validDB = try XCTUnwrap(validHandle)
        try execute(validDB, "CREATE TABLE present (id INTEGER);")
        sqlite3_close(validDB)

        try SQLiteSnapshotReader.withReadableDatabase(at: valid, temporaryDirectory: temporaryDirectory) { db in
            XCTAssertTrue(try SQLiteSnapshotReader.tableExists(db, "present"))
            XCTAssertFalse(try SQLiteSnapshotReader.tableExists(db, "missing_table"))
        }

        let corrupt = directory.appendingPathComponent("unreadable.db")
        try Data("not a sqlite database".utf8).write(to: corrupt)
        var rawHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(corrupt.path, &rawHandle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let unreadableDB = try XCTUnwrap(rawHandle)
        defer { sqlite3_close(unreadableDB) }

        XCTAssertThrowsError(try SQLiteSnapshotReader.tableExists(unreadableDB, "present")) { error in
            guard case CollectorError.sql = error else {
                return XCTFail("Expected CollectorError.sql, got \(error)")
            }
        }
    }
}
