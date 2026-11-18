import SQLite3
import XCTest
@testable import TokenTakenKit

final class CursorCollectorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private let utc = TimeZone(identifier: "UTC")!
    private let now = ISO8601DateFormatter().date(from: "2026-11-09T12:30:00Z")!
    private let identifier = "user_synthetic_1"

    private enum TestError: Error {
        case sqlite(String)
        case missingRequest
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let error = message.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(message)
            throw TestError.sqlite(error)
        }
    }

    private var stateDatabaseURL: URL {
        directory.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// Builds Cursor's `state.vscdb` shape in a temporary home. The token is synthetic, never a real credential.
    private func makeStateDatabase(token: String) throws {
        let url = stateDatabaseURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let db = handle else {
            throw TestError.sqlite("Could not create a synthetic Cursor state database")
        }
        defer { sqlite3_close(db) }
        try execute(db, "CREATE TABLE IF NOT EXISTS ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/accessToken', ?);", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw TestError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let bound = token.withCString { pointer in
            sqlite3_bind_text(statement, 1, pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard bound == SQLITE_OK else { throw TestError.sqlite(String(cString: sqlite3_errmsg(db))) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw TestError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    private func writeCLIConfig(_ object: [String: Any]) throws {
        let root = directory.appendingPathComponent(".cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: root.appendingPathComponent("cli-config.json"))
    }

    private final class CapturedRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: URLRequest?

        var request: URLRequest? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private func respond(
        _ body: String,
        status: Int = 200,
        captured: CapturedRequest? = nil
    ) -> @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
        { request in
            captured?.request = request
            let response = HTTPURLResponse(
                url: CursorCollector.exportURL, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (Data(body.utf8), response)
        }
    }

    private func collector(
        fetch: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) -> CursorCollector {
        CursorCollector(home: directory, timeZone: utc, now: now, fetch: fetch)
    }

    /// Reordered columns, a quoted model name, a cache-write row, a degenerate zero row and a row outside the
    /// hourly window. `Total Tokens` carries a wrong number on purpose: it is never counted.
    private var export: String {
        """
        Cost,Total Tokens,Date,Model,Output Tokens,Cache Read,Input (w/o Cache Write),Input (w/ Cache Write)\r
        0.10,999,2026-11-09T10:15:00.521Z,"Claude 4.5, Sonnet",30,20,50,80\r
        0.02,12,2026-11-09T10:45:00.000Z,composer-1,7,5,12,10\r
        0,0,2026-11-09T10:50:00.000Z,auto,0,0,0,0\r
        0,0,2026-11-09T10:55:00.000Z,,0,0,0,0\r
        0.05,9,2026-10-01T05:00:00.000Z,old-model,4,3,2,2\r
        """
    }

    func testCountsRowsAndStoresThemUnderOneAccountDevice() async throws {
        try makeStateDatabase(token: "synthetic-session-token-value")
        try writeCLIConfig(["authInfo": ["userId": identifier]])
        let captured = CapturedRequest()

        let batch = try await collector(fetch: respond(export, captured: captured)).collect()

        let device = try XCTUnwrap(batch.accountDevice)
        XCTAssertEqual(device.kind, .account)
        XCTAssertEqual(device.name, "Cursor")
        XCTAssertEqual(device.id, CursorCollector.accountID(identifier: identifier))
        XCTAssertTrue(device.id.hasPrefix("account-cursor-"))
        XCTAssertEqual(device.id.count, "account-cursor-".count + 32)
        XCTAssertEqual(batch.authoritativeSourceIDs, ["cursor"])
        XCTAssertEqual(batch.skippedRecords, 0)
        XCTAssertTrue(batch.daily.allSatisfy { $0.deviceID == device.id && $0.sourceID == "cursor" })
        XCTAssertTrue(batch.daily.allSatisfy { $0.timeZoneID == utc.identifier })

        let daily = Dictionary(uniqueKeysWithValues: batch.daily.map { ($0.day + "|" + $0.modelID, $0) })
        XCTAssertEqual(batch.daily.count, 4)
        // The two cache-write columns give the cache write; the wrong `Total Tokens` cell is ignored.
        let claude = try XCTUnwrap(daily["2026-11-09|claude 4.5, sonnet"])
        XCTAssertEqual(claude.rawModelID, "Claude 4.5, Sonnet")
        XCTAssertEqual(claude.counts, TokenCounts(input: 50, cacheRead: 20, cacheWrite: 30, output: 30))
        XCTAssertEqual(claude.eventCount, 1)
        // A cache-write total below the input total cannot produce a negative write.
        let composer = try XCTUnwrap(daily["2026-11-09|composer-1"])
        XCTAssertEqual(composer.counts, TokenCounts(input: 12, cacheRead: 5, cacheWrite: 0, output: 7))
        // A model with no tokens is one request that happened to be free, not a row to drop.
        let auto = try XCTUnwrap(daily["2026-11-09|auto"])
        XCTAssertEqual(auto.counts, .zero)
        XCTAssertEqual(auto.eventCount, 1)
        XCTAssertEqual(try XCTUnwrap(daily["2026-10-01|old-model"]).counts, TokenCounts(input: 2, cacheRead: 3, cacheWrite: 0, output: 4))

        // Only the last 48 hours get hourly rows; older days stay daily-only.
        XCTAssertEqual(batch.hourly.count, 1)
        let hour = try XCTUnwrap(batch.hourly.first)
        XCTAssertEqual(hour.hourStart, ISO8601DateFormatter().date(from: "2026-11-09T10:00:00Z"))
        XCTAssertEqual(hour.deviceID, device.id)
        XCTAssertEqual(hour.counts, claude.counts + composer.counts)
        XCTAssertEqual(hour.eventCount, 3)
        XCTAssertTrue(hour.reasoningKnown)

        let request = try XCTUnwrap(captured.request)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "*/*")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://www.cursor.com/settings")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"),
            "WorkosCursorSessionToken=user_synthetic_1%3A%3Asynthetic-session-token-value")
        XCTAssertEqual(request.timeoutInterval, 90)
    }

    func testAccountIDIsStableAndDistinct() {
        XCTAssertEqual(CursorCollector.accountID(identifier: "user_a"), CursorCollector.accountID(identifier: "user_a"))
        XCTAssertNotEqual(CursorCollector.accountID(identifier: "user_a"), CursorCollector.accountID(identifier: "user_b"))
        XCTAssertEqual(CursorCollector.accountID(identifier: "user_a"), "account-cursor-10b9e7b4b52b0976545513032a2ed3f4")
    }

    func testSubjectNormalization() {
        XCTAssertEqual(CursorCollector.normalizeSubject("auth0|user_2abc"), "user_2abc")
        XCTAssertEqual(CursorCollector.normalizeSubject("google-oauth2|1234"), "google-oauth2|1234")
        XCTAssertEqual(CursorCollector.normalizeSubject(" github|99 "), "github|99")
        XCTAssertEqual(CursorCollector.normalizeSubject("plain"), "plain")
    }

    func testIdentityFallsBackToTheTokenSubject() async throws {
        let payload = Data(#"{"sub":"auth0|user_from_jwt","exp":1}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try makeStateDatabase(token: "header.\(payload).signature")

        let batch = try await collector(fetch: respond(export)).collect()

        XCTAssertEqual(batch.accountDevice?.id, CursorCollector.accountID(identifier: "user_from_jwt"))
    }

    func testAuthIdIsNormalizedWhenUserIdIsAbsent() async throws {
        try makeStateDatabase(token: "synthetic-session-token-value")
        try writeCLIConfig(["authInfo": ["authId": "auth0|user_from_auth_id"]])

        let batch = try await collector(fetch: respond(export)).collect()

        XCTAssertEqual(batch.accountDevice?.id, CursorCollector.accountID(identifier: "user_from_auth_id"))
    }

    func testMissingIdentityFailsInsteadOfInventingOne() async throws {
        try makeStateDatabase(token: "synthetic-session-token-value")

        do {
            _ = try await collector(fetch: respond(export)).collect()
            XCTFail("A collector without an account identity must fail")
        } catch let error as CollectorError {
            guard case .invalidOutput(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "Cursor account identity unavailable")
        }
    }

    func testExpiredSessionMessageCarriesNoToken() async throws {
        try makeStateDatabase(token: "synthetic-session-token-value")
        try writeCLIConfig(["authInfo": ["userId": identifier]])

        for status in [401, 403] {
            do {
                _ = try await collector(fetch: respond("", status: status)).collect()
                XCTFail("HTTP \(status) must fail")
            } catch let error as CollectorError {
                guard case .invalidOutput(let message) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(message, "Cursor session expired; sign in to Cursor again")
                XCTAssertFalse(message.contains("synthetic-session-token-value"))
            }
        }
    }

    func testOtherHTTPStatusFails() async throws {
        try makeStateDatabase(token: "synthetic-session-token-value")
        try writeCLIConfig(["authInfo": ["userId": identifier]])

        do {
            _ = try await collector(fetch: respond("", status: 500)).collect()
            XCTFail("HTTP 500 must fail")
        } catch let error as CollectorError {
            guard case .invalidOutput(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "Cursor usage export failed (HTTP 500)")
        }
    }

    func testMissingColumnThrowsInsteadOfProducingRows() async throws {
        try makeStateDatabase(token: "synthetic-session-token-value")
        try writeCLIConfig(["authInfo": ["userId": identifier]])
        let body = """
            Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Output Tokens
            2026-11-09T10:15:00.521Z,composer-1,80,50,30
            """

        do {
            _ = try await collector(fetch: respond(body)).collect()
            XCTFail("A missing required column must fail")
        } catch let error as CollectorError {
            guard case .invalidOutput(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "Cursor usage export is missing required columns")
        }
    }

    func testUnparsableRowIsSkippedAndLosesAuthority() async throws {
        try makeStateDatabase(token: "synthetic-session-token-value")
        try writeCLIConfig(["authInfo": ["userId": identifier]])
        let body = """
            Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens
            2026-11-09T10:15:00.521Z,composer-1,80,50,20,30
            not-a-date,composer-1,80,50,20,30
            """

        let batch = try await collector(fetch: respond(body)).collect()

        XCTAssertEqual(batch.skippedRecords, 1)
        XCTAssertEqual(batch.daily.count, 1)
        // An incomplete parse must never adopt its days exactly.
        XCTAssertEqual(batch.authoritativeSourceIDs, [])
    }

    func testEmptyExportIsHealthyButNotAuthoritative() async throws {
        try makeStateDatabase(token: "synthetic-session-token-value")
        try writeCLIConfig(["authInfo": ["userId": identifier]])
        let body = "Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens\n"

        let batch = try await collector(fetch: respond(body)).collect()

        XCTAssertTrue(batch.daily.isEmpty)
        XCTAssertTrue(batch.hourly.isEmpty)
        XCTAssertEqual(batch.authoritativeSourceIDs, [])
        XCTAssertEqual(batch.accountDevice?.id, CursorCollector.accountID(identifier: identifier))
    }

    func testMissingCursorStateIsUnavailable() async throws {
        do {
            _ = try await collector(fetch: respond(export)).collect()
            XCTFail("A missing Cursor state database must be unavailable")
        } catch let error as CollectorError {
            guard case .sourceUnavailable = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testEncryptedPlaceholderIsUnavailable() async throws {
        try makeStateDatabase(token: "cursor-safe-storage:synthetic-placeholder")

        do {
            _ = try await collector(fetch: respond(export)).collect()
            XCTFail("An encrypted placeholder must be unavailable")
        } catch let error as CollectorError {
            guard case .sourceUnavailable = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testReadsTokenFromLiveWALDatabaseWithOpenWriter() async throws {
        let url = stateDatabaseURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
        let liveDB = try XCTUnwrap(writer)
        defer {
            _ = sqlite3_exec(liveDB, "ROLLBACK;", nil, nil, nil)
            sqlite3_close(liveDB)
        }
        try execute(liveDB, "PRAGMA journal_mode=WAL;")
        try execute(liveDB, "PRAGMA wal_autocheckpoint=0;")
        try execute(liveDB, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);")
        try execute(liveDB, "INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/accessToken', 'synthetic-wal-session-token');")
        // Hold an uncommitted write open during collection so `collect()` reads against a live WAL writer.
        try execute(liveDB, "BEGIN IMMEDIATE;")
        try execute(liveDB, "INSERT INTO ItemTable (key, value) VALUES ('cursor/concurrentWrite', 'in-progress');")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-wal"))

        try writeCLIConfig(["authInfo": ["userId": identifier]])
        let captured = CapturedRequest()
        let batch = try await collector(fetch: respond(export, captured: captured)).collect()

        let request = try XCTUnwrap(captured.request)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Cookie"),
            "WorkosCursorSessionToken=user_synthetic_1%3A%3Asynthetic-wal-session-token"
        )
        XCTAssertEqual(batch.daily.count, 4)
    }

    func testReadsTokenFromClosedWALDatabaseWithoutSidecars() async throws {
        let url = stateDatabaseURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        try execute(db, "PRAGMA journal_mode=WAL;")
        try execute(db, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);")
        try execute(db, "INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/accessToken', 'synthetic-closed-wal-token');")
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

        try writeCLIConfig(["authInfo": ["userId": identifier]])
        let captured = CapturedRequest()
        let batch = try await collector(fetch: respond(export, captured: captured)).collect()

        let request = try XCTUnwrap(captured.request)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Cookie"),
            "WorkosCursorSessionToken=user_synthetic_1%3A%3Asynthetic-closed-wal-token"
        )
        XCTAssertEqual(batch.daily.count, 4)
        XCTAssertEqual(
            batch.daily.reduce(.zero) { $0 + $1.counts },
            TokenCounts(input: 64, cacheRead: 28, cacheWrite: 30, output: 41)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))
    }

    func testMissingItemTableThrowsSQLErrorInsteadOfUnavailable() async throws {
        let url = stateDatabaseURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        try execute(db, "CREATE TABLE OtherTable (key TEXT);")
        sqlite3_close(db)

        do {
            _ = try await collector(fetch: respond(export)).collect()
            XCTFail("Missing ItemTable must fail loudly")
        } catch let error as CollectorError {
            guard case .sql = error else { return XCTFail("Expected CollectorError.sql, got \(error)") }
        }
    }

    func testCSVParserHandlesQuotedCommasQuotesAndNewlines() {
        let text = "a,\"b,c\",\"d\"\"e\",\"f\ng\"\r\n1,2,3,4\n"
        let records = CursorCollector.csvRecords(text)
        XCTAssertEqual(records, [["a", "b,c", "d\"e", "f\ng"], ["1", "2", "3", "4"]])
    }

    func testRedirectPolicyFollowsOneCursorHopOnly() {
        let policy = CursorRedirectPolicy()
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: CursorCollector.exportURL)
        let response = HTTPURLResponse(url: CursorCollector.exportURL, statusCode: 302, httpVersion: nil, headerFields: nil)!

        final class Decision: @unchecked Sendable {
            var followed = false
        }
        var decisions: [Bool] = []
        for target in ["https://cursor.com/a", "https://www.cursor.com/b", "https://cursor.com/c"] {
            let decision = Decision()
            policy.urlSession(
                session, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: target)!)
            ) { decision.followed = $0 != nil }
            decisions.append(decision.followed)
        }
        XCTAssertEqual(decisions, [true, false, false])
        XCTAssertFalse(CursorRedirectPolicy.allows(URL(string: "http://cursor.com/a")))
        XCTAssertFalse(CursorRedirectPolicy.allows(URL(string: "http://www.cursor.com/a")))
        XCTAssertFalse(CursorRedirectPolicy.allows(URL(string: "https://cursor.com:8443/a")))
        XCTAssertTrue(CursorRedirectPolicy.allows(URL(string: "https://cursor.com:443/a")))
        XCTAssertFalse(CursorRedirectPolicy.allows(URL(string: "https://example.com/settings")))
        XCTAssertFalse(CursorRedirectPolicy.allows(nil))

        let httpDecision = Decision()
        CursorRedirectPolicy().urlSession(
            session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "http://cursor.com/a")!)
        ) { httpDecision.followed = $0 != nil }
        XCTAssertFalse(httpDecision.followed)
    }

    func testJWTSubjectIsPreferredOverCLIConfigAndUserIdIsNormalized() async throws {
        let payload = Data(#"{"sub":"auth0|user_from_jwt","exp":1}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = "header.\(payload).signature"
        try makeStateDatabase(token: jwt)
        try writeCLIConfig(["authInfo": ["userId": "user_from_cli"]])

        let captured = CapturedRequest()
        let batch = try await collector(fetch: respond(export, captured: captured)).collect()

        XCTAssertEqual(batch.accountDevice?.id, CursorCollector.accountID(identifier: "user_from_jwt"))
        XCTAssertEqual(
            captured.request?.value(forHTTPHeaderField: "Cookie"),
            "WorkosCursorSessionToken=user_from_jwt%3A%3A\(jwt)"
        )

        try makeStateDatabase(token: "synthetic-session-token-value")
        try writeCLIConfig(["authInfo": ["userId": "auth0|user_from_cli"]])

        let fallbackBatch = try await collector(fetch: respond(export)).collect()
        XCTAssertEqual(fallbackBatch.accountDevice?.id, CursorCollector.accountID(identifier: "user_from_cli"))
    }

    func testFutureDateRowIsSkippedAndLosesAuthority() async throws {
        try makeStateDatabase(token: "synthetic-session-token-value")
        try writeCLIConfig(["authInfo": ["userId": identifier]])
        let body = """
            Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens
            2026-11-11T00:00:00.000Z,composer-1,80,50,20,30
            """

        let batch = try await collector(fetch: respond(body)).collect()

        XCTAssertTrue(batch.daily.isEmpty)
        XCTAssertEqual(batch.skippedRecords, 1)
        XCTAssertEqual(batch.authoritativeSourceIDs, [])
    }
}
