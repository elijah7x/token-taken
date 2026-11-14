import Foundation
import SQLite3

/// Reads client SQLite databases without ever creating sidecar files beside them.
enum SQLiteSnapshotReader {
    /// Opens `url` read-only and verifies readability with a `sqlite_master` probe.
    ///
    /// Closed WAL databases lose their `-wal` and `-shm` sidecars, so `SQLITE_OPEN_READONLY`
    /// succeeds on open and fails only on the first prepare. Conversely, an orphaned `-wal`
    /// without `-shm` causes SQLite to create `-shm` beside the client's file even in read-only
    /// mode. In both cases, this falls back to copying the database and any existing sidecars
    /// into a fresh UUID path under `temporaryDirectory`, opening the copy read-write, and always
    /// cleaning up the copy afterwards.
    static func withReadableDatabase<T>(
        at url: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        let manager = FileManager.default
        // A `-wal` without its `-shm` would make a read-only open create `-shm` beside the client's file.
        let orphanedWal = manager.fileExists(atPath: url.path + "-wal")
            && !manager.fileExists(atPath: url.path + "-shm")
        if !orphanedWal, let handle = openReadOnlyIfReadable(url) {
            defer { sqlite3_close(handle) }
            return try body(handle)
        }

        let stagingDirectory = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try manager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        } catch {
            throw CollectorError.open("Could not create temporary directory for SQLite snapshot")
        }
        defer { try? manager.removeItem(at: stagingDirectory) }

        let copyURL = stagingDirectory.appendingPathComponent("snapshot.db")
        defer { removeWithSidecars(copyURL) }
        do {
            try copyWithSidecars(url, to: copyURL)
        } catch {
            throw CollectorError.open("Could not copy SQLite database for reading")
        }

        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(copyURL.path, &handle, SQLITE_OPEN_READWRITE, nil)
        guard openResult == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open SQLite database"
            if let handle { sqlite3_close(handle) }
            throw CollectorError.open(message)
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 5_000)

        guard probe(handle) else {
            throw CollectorError.open(String(cString: sqlite3_errmsg(handle)))
        }
        return try body(handle)
    }

    static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError(db)
        }
        return statement
    }

    static func tableExists(_ db: OpaquePointer, _ name: String) throws -> Bool {
        let statement = try prepare(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        let bound = name.withCString { pointer in
            sqlite3_bind_text(statement, 1, pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard bound == SQLITE_OK else {
            throw lastError(db)
        }
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return false }
        if step == SQLITE_ROW { return true }
        throw lastError(db)
    }

    static func lastError(_ db: OpaquePointer) -> CollectorError {
        .sql(String(cString: sqlite3_errmsg(db)))
    }

    private static func openReadOnlyIfReadable(_ url: URL) -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        sqlite3_busy_timeout(handle, 5_000)
        guard probe(handle) else {
            sqlite3_close(handle)
            return nil
        }
        return handle
    }

    private static func probe(_ db: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master;", -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func copyWithSidecars(_ url: URL, to destination: URL) throws {
        let manager = FileManager.default
        try manager.copyItem(at: url, to: destination)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            guard manager.fileExists(atPath: sidecar.path) else { continue }
            try manager.copyItem(at: sidecar, to: URL(fileURLWithPath: destination.path + suffix))
        }
    }

    private static func removeWithSidecars(_ url: URL) {
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? manager.removeItem(atPath: url.path + suffix)
        }
    }
}
