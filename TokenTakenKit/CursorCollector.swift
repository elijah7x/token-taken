import CryptoKit
import Foundation
import OSLog
import SQLite3

/// Counts this Cursor account's usage from Cursor's own export CSV (ADR-0010). The usage is account-scoped, not
/// machine-scoped: it is stored under a synthetic `account-cursor-<hash>` device, so two Macs signed in to the same
/// account report the same rows instead of one account's usage twice.
///
/// Cursor has no local usage log; only the login state is read locally. The session token stays in memory: it never
/// reaches an error message, the store, the sync payload or a log line.
public struct CursorCollector: UsageCollector {
    public let sourceIDs = ["cursor"]

    static let exportURL = URL(string: "https://cursor.com/api/dashboard/export-usage-events-csv?strategy=tokens")!
    private static let logger = Logger(subsystem: "io.github.elijah7x.TokenTaken", category: "collection")

    private let home: URL
    private let timeZone: TimeZone
    private let now: Date
    private let fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// `deviceID` and `stateDirectory` are accepted so the runner builds every native collector the same way.
    /// Cursor rows belong to the account device and each refresh re-reads the whole export, so neither is used:
    /// there is no incremental state whose absence would force a full scan.
    public init(
        deviceID: String,
        stateDirectory: URL?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fetch: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = CursorCollector.liveFetch
    ) {
        self.init(home: home, timeZone: .current, now: .now, fetch: fetch)
    }

    /// Pins the local time zone and the hourly window; used by tests.
    init(
        home: URL,
        timeZone: TimeZone,
        now: Date,
        fetch: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) {
        self.home = home
        self.timeZone = timeZone
        self.now = now
        self.fetch = fetch
    }

    public func collect() async throws -> CollectionBatch {
        let started = Date.now
        let token = try sessionToken()
        guard let identifier = identity(token: token) else {
            throw CollectorError.invalidOutput("Cursor account identity unavailable")
        }
        let accountDevice = Self.accountDevice(identifier: identifier)

        let (data, response) = try await fetch(Self.request(identifier: identifier, token: token))
        switch response.statusCode {
        case 200:
            break
        case 401, 403:
            throw CollectorError.invalidOutput("Cursor session expired; sign in to Cursor again")
        case let status:
            throw CollectorError.invalidOutput("Cursor usage export failed (HTTP \(status))")
        }

        let export = try Self.parse(data)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        var aggregator = Aggregator(
            deviceID: accountDevice.id, timeZone: timeZone, calendar: calendar,
            currentHour: currentHour, cutoff: currentHour.addingTimeInterval(-47 * 3_600),
            maxDate: now.addingTimeInterval(86_400)
        )
        aggregator.add(export.rows)
        var batch = aggregator.batch()
        batch.accountDevice = accountDevice
        batch.skippedRecords = export.skipped + aggregator.skipped
        // A complete export is authoritative: every day it reports is adopted exactly (smaller values too). A
        // partial or empty export must leave stored history alone, so it is not authoritative.
        if batch.skippedRecords == 0, !export.rows.isEmpty {
            batch.authoritativeSourceIDs = Set(sourceIDs)
        }
        log(detail: "export rows=\(export.rows.count) skipped=\(batch.skippedRecords)", since: started)
        return batch
    }

    private func log(detail: String, since started: Date) {
        let duration = Int((Date.now.timeIntervalSince(started) * 1_000).rounded())
        Self.logger.info("source=cursor \(detail, privacy: .public) duration_ms=\(duration, privacy: .public)")
    }

    // MARK: - Login state

    /// Reads Cursor's access token directly from its live VS Code state database via `SQLiteSnapshotReader`,
    /// falling back to a private copy only when direct read-only access or WAL sidecars cannot be opened.
    private func sessionToken() throws -> String {
        let manager = FileManager.default
        let databaseURL = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard manager.fileExists(atPath: databaseURL.path) else { throw CollectorError.sourceUnavailable }

        return try SQLiteSnapshotReader.withReadableDatabase(
            at: databaseURL,
            temporaryDirectory: manager.temporaryDirectory
        ) { db in
            try Self.readToken(from: db)
        }
    }

    private static func readToken(from db: OpaquePointer) throws -> String {
        let statement = try SQLiteSnapshotReader.prepare(
            db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken';"
        )
        defer { sqlite3_finalize(statement) }

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let value = sqlite3_column_text(statement, 0) else { throw CollectorError.sourceUnavailable }
            let token = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
            // `cursor-safe-storage:` means Cursor encrypted the value; its key lives in the keychain and is not read.
            guard token.count >= 10, !token.hasPrefix("cursor-safe-storage:") else {
                throw CollectorError.sourceUnavailable
            }
            return token
        case SQLITE_DONE:
            throw CollectorError.sourceUnavailable
        default:
            throw SQLiteSnapshotReader.lastError(db)
        }
    }

    /// Cursor's own account id, preferring the active session token's `sub` claim and falling back to
    /// `cli-config.json`. Host names and random ids are never substitutes: either would split one account
    /// into several devices.
    private func identity(token: String) -> String? {
        if let subject = Self.jwtSubject(token) {
            return Self.normalizeSubject(subject)
        }
        let url = home.appendingPathComponent(".cursor/cli-config.json")
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let authInfo = object["authInfo"] as? [String: Any] {
            if let userId = Self.text(authInfo["userId"]) { return Self.normalizeSubject(userId) }
            if let authId = Self.text(authInfo["authId"]) { return Self.normalizeSubject(authId) }
        }
        return nil
    }

    private static func text(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    /// `auth0|user_X` carries the account subject after the provider prefix; other providers' subjects already
    /// include their prefix and are kept as they are.
    static func normalizeSubject(_ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(of: "|"), String(trimmed[..<separator]) == "auth0" else { return trimmed }
        let normalized = trimmed[trimmed.index(after: separator)...]
        return normalized.isEmpty ? trimmed : String(normalized)
    }

    /// The JWT payload is decoded in memory only, to name the account when `cli-config.json` has no identity.
    static func jwtSubject(_ token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return text(object["sub"])
    }

    /// The account's device. The domain separator keeps these hashes from being confused with any other use, and
    /// 32 hex characters leave no room for an accidental collision while staying short enough for a path component.
    static func accountDevice(identifier: String) -> Device {
        Device(id: accountID(identifier: identifier), name: "Cursor", kind: .account)
    }

    static func accountID(identifier: String) -> String {
        let digest = SHA256.hash(data: Data("token-taken/account/v1|cursor|\(identifier)".utf8))
        return "account-cursor-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Request

    static func request(identifier: String, token: String) -> URLRequest {
        var request = URLRequest(url: exportURL, timeoutInterval: 90)
        request.httpMethod = "GET"
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("WorkosCursorSessionToken=\(identifier)%3A%3A\(token)", forHTTPHeaderField: "Cookie")
        request.setValue("https://www.cursor.com/settings", forHTTPHeaderField: "Referer")
        return request
    }

    public static func liveFetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let delegate = CursorRedirectPolicy()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CollectorError.invalidOutput("Cursor usage export returned an unexpected response")
        }
        return (data, http)
    }

    // MARK: - CSV

    struct Export {
        var rows: [Row] = []
        var skipped = 0
    }

    struct Row {
        let date: Date
        let model: String
        let counts: TokenCounts
    }

    /// Parses the export by header name, because Cursor has reordered these columns before. A missing required
    /// column throws instead of producing rows, so half an export can never overwrite stored history.
    static func parse(_ data: Data) throws -> Export {
        guard var text = String(data: data, encoding: .utf8) else {
            throw CollectorError.invalidOutput("Cursor usage export is not UTF-8 text")
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst(1) }
        let records = csvRecords(text)
        guard let header = records.first else {
            throw CollectorError.invalidOutput("Cursor usage export is missing required columns")
        }
        var columns: [String: Int] = [:]
        for (index, name) in header.enumerated() {
            columns[name.trimmingCharacters(in: .whitespacesAndNewlines)] = index
        }
        guard let dateColumn = columns["Date"],
              let modelColumn = columns["Model"],
              let withCacheWriteColumn = columns["Input (w/ Cache Write)"],
              let withoutCacheWriteColumn = columns["Input (w/o Cache Write)"],
              let cacheReadColumn = columns["Cache Read"],
              let outputColumn = columns["Output Tokens"] else {
            throw CollectorError.invalidOutput("Cursor usage export is missing required columns")
        }

        var export = Export()
        for record in records.dropFirst() {
            // A blank line is not a record.
            guard record.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            guard let date = cell(record, dateColumn).flatMap(Self.date(from:)),
                  let model = cell(record, modelColumn),
                  let withCacheWrite = cell(record, withCacheWriteColumn).flatMap(Self.tokenCount(_:)),
                  let withoutCacheWrite = cell(record, withoutCacheWriteColumn).flatMap(Self.tokenCount(_:)),
                  let cacheRead = cell(record, cacheReadColumn).flatMap(Self.tokenCount(_:)),
                  let output = cell(record, outputColumn).flatMap(Self.tokenCount(_:)) else {
                export.skipped += 1
                continue
            }
            let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            // A row with no model and no tokens carries nothing; a row with a model and no tokens is one request
            // that happened to be free.
            let counts = TokenCounts(
                input: withoutCacheWrite,
                cacheRead: cacheRead,
                cacheWrite: max(0, withCacheWrite - withoutCacheWrite),
                output: output
            )
            if counts.total == 0, trimmedModel.isEmpty { continue }
            export.rows.append(Row(date: date, model: trimmedModel, counts: counts))
        }
        return export
    }

    private static func cell(_ record: [String], _ index: Int) -> String? {
        index < record.count ? record[index] : nil
    }

    /// An empty cell counts as zero; a negative or non-numeric one makes the row unparsable.
    private static func tokenCount(_ value: String) -> Int64? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return 0 }
        let plain = text.replacingOccurrences(of: ",", with: "")
        if let count = Int64(plain) { return count >= 0 ? count : nil }
        guard let number = Double(plain), number.isFinite, number >= 0, number < 0x1p63 else { return nil }
        return Int64(number.rounded(.towardZero))
    }

    /// `Date` is an ISO-8601 UTC instant with fractional seconds; the plain form is accepted rather than dropping
    /// a whole day over a formatting variant.
    static func date(from value: String) -> Date? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return fractionalFormatter.date(from: text) ?? plainFormatter.date(from: text)
    }

    // `ISO8601DateFormatter` is documented as thread-safe, so collectors running in parallel may share it.
    private nonisolated(unsafe) static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// RFC 4180 records: comma-separated fields, `"` quoting with `""` escapes, and newlines allowed inside a
    /// quoted field.
    static func csvRecords(_ text: String) -> [[String]] {
        // Unicode scalars, not Characters: "\r\n" is one Character, so a CRLF row break would never match "\n".
        let characters = Array(text.unicodeScalars)
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var quoted = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.unicodeScalars.append("\"")
                        index += 2
                        continue
                    }
                    quoted = false
                } else {
                    field.unicodeScalars.append(character)
                }
                index += 1
                continue
            }
            switch character {
            case "\"":
                quoted = true
            case ",":
                record.append(field)
                field = ""
            case "\r":
                break
            case "\n":
                record.append(field)
                records.append(record)
                record = []
                field = ""
            default:
                field.unicodeScalars.append(character)
            }
            index += 1
        }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }

    // MARK: - Aggregation

    private struct Key: Hashable {
        let day: String
        let modelID: String
    }

    private struct Aggregator {
        let deviceID: String
        let timeZone: TimeZone
        let calendar: Calendar
        let currentHour: Date
        let cutoff: Date
        let maxDate: Date

        var daily: [Key: UsageRecord] = [:]
        var hourly: [Date: HourlyUsage] = [:]
        var skipped = 0

        mutating func add(_ rows: [Row]) {
            for row in rows {
                guard row.date <= maxDate,
                      let hour = calendar.dateInterval(of: .hour, for: row.date)?.start else {
                    skipped += 1
                    continue
                }
                let rawModelID = row.model.isEmpty ? "unknown" : row.model
                let model = rawModelID.lowercased()
                let day = UsageDay.string(from: row.date, in: timeZone)
                let key = Key(day: day, modelID: model)
                var record = daily[key] ?? UsageRecord(
                    day: day, timeZoneID: timeZone.identifier, deviceID: deviceID,
                    sourceID: "cursor", modelID: model, rawModelID: rawModelID, counts: .zero
                )
                record.counts += row.counts
                record.eventCount += 1
                daily[key] = record

                guard hour >= cutoff, hour <= currentHour else { continue }
                var hourRow = hourly[hour] ?? HourlyUsage(
                    hourStart: hour, deviceID: deviceID, sourceID: "cursor",
                    counts: .zero, eventCount: 0, reasoningKnown: true
                )
                hourRow.counts += row.counts
                hourRow.eventCount += 1
                hourly[hour] = hourRow
            }
        }

        func batch() -> CollectionBatch {
            CollectionBatch(
                daily: daily.values.sorted {
                    if $0.day != $1.day { return $0.day < $1.day }
                    return $0.modelID < $1.modelID
                },
                hourly: hourly.values.sorted { $0.hourStart < $1.hourStart }
            )
        }
    }
}

/// The export URL redirects to a signed location, and the redirect still carries the session cookie, so it may
/// follow exactly one hop and only to Cursor's own site over HTTPS.
final class CursorRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var followedRedirect = false

    static func allows(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return host == "cursor.com" || host == "www.cursor.com"
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        lock.lock()
        let allowed = !followedRedirect && Self.allows(request.url)
        if allowed { followedRedirect = true }
        lock.unlock()
        completionHandler(allowed ? request : nil)
    }
}
