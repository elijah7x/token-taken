import CoreFoundation
import Foundation
import OSLog

/// Reads Gemini CLI interactive sessions (`$GEMINI_CLI_HOME/tmp` or `~/.gemini/tmp`) and
/// tokscale headless Gemini captures (`$TOKSCALE_HEADLESS_DIR/gemini` or
/// `~/.config/tokscale/headless/gemini`, `~/Library/Application Support/tokscale/headless/gemini`)
/// natively.
///
/// Native collection fixes three tokscale 4.21.0 issues for `gemini`:
/// - Headless JSONL/JSON files that contain both per-turn token events and a trailing `stats` /
///   `result.stats` summary were counted twice; summaries are now ignored whenever a file (or any
///   file for the same session) has direct per-turn events.
/// - Cache-inclusive `input` / `prompt` counters without a `total` field fell back to cache-exclusive
///   handling and double-counted cached tokens; Gemini prompt counters now default to cache-inclusive
///   unless `cached > 0` and either `rawInput < cached` or `total` equals the sum of all five
///   disjoint counters.
/// - Hourly buckets now record `thoughts` as `reasoning` with `reasoningKnown = true`.
///
/// Antigravity directories under `~/.gemini` are never read here; `AntigravityCollector` owns them.
public struct GeminiCollector: UsageCollector {
    public let sourceIDs = ["gemini"]

    private static let stateFormatVersion = 1
    private static let logger = Logger(subsystem: "io.github.elijah7x.TokenTaken", category: "collection")

    private let sessionRoot: URL
    private let headlessRoots: [URL]
    private let deviceID: String
    private let timeZone: TimeZone
    private let now: Date
    private let stateFile: CollectorStateFile<SavedState>?

    public init(deviceID: String, stateDirectory: URL? = nil) {
        self.init(
            deviceID: deviceID,
            home: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment,
            stateDirectory: stateDirectory
        )
    }

    /// Pins the Gemini home/headless roots, time zone, and hourly window; used by tests.
    public init(
        deviceID: String,
        home: URL,
        environment: [String: String] = [:],
        timeZone: TimeZone = .current,
        now: Date = .now,
        stateDirectory: URL? = nil
    ) {
        self.sessionRoot = Self.resolveSessionRoot(home: home, environment: environment)
        self.headlessRoots = Self.resolveHeadlessRoots(home: home, environment: environment)
        self.deviceID = deviceID
        self.timeZone = timeZone
        self.now = now
        self.stateFile = stateDirectory.map { CollectorStateFile(directory: $0, name: "gemini") }
    }

    static func resolveSessionRoot(home: URL, environment: [String: String]) -> URL {
        let override = environment["GEMINI_CLI_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("tmp", isDirectory: true)
        }
        return home.appendingPathComponent(".gemini/tmp", isDirectory: true)
    }

    static func resolveHeadlessRoots(home: URL, environment: [String: String]) -> [URL] {
        let override = environment["TOKSCALE_HEADLESS_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !override.isEmpty {
            return [URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("gemini", isDirectory: true)]
        }
        return [
            home.appendingPathComponent(".config/tokscale/headless/gemini", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/tokscale/headless/gemini", isDirectory: true),
        ]
    }

    public func collect() async throws -> CollectionBatch {
        let started = Date.now
        let sessionRootExists = Self.directoryExists(at: sessionRoot)
        let existingHeadlessRoots = headlessRoots.filter { Self.directoryExists(at: $0) }
        guard sessionRootExists || !existingHeadlessRoots.isEmpty else {
            throw CollectorError.sourceUnavailable
        }

        let stamp = CollectionStamp(formatVersion: Self.stateFormatVersion, timeZone: timeZone, sourceIDs: sourceIDs)
        let files = try discoverFiles(sessionRootExists: sessionRootExists, headlessRoots: existingHeadlessRoots)
        let fingerprints = Fingerprints(files: files)
        if let stateFile, let saved = stateFile.load(), saved.stamp == stamp, saved.fingerprints == fingerprints {
            log(mode: "unchanged", since: started)
            return CollectionBatch(unchangedSourceIDs: Set(sourceIDs))
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let maxDate = now.addingTimeInterval(86_400)

        var parsedFiles: [ParsedFile] = []
        parsedFiles.reserveCapacity(files.count)
        for file in files {
            let data: Data
            do {
                data = try Data(contentsOf: file)
            } catch {
                throw CollectorError.open("Could not read a Gemini session file")
            }
            let parsed = Self.parseFile(url: file, data: data, maxDate: maxDate)
            parsedFiles.append(parsed)
        }

        var aggregator = Aggregator(
            deviceID: deviceID,
            timeZone: timeZone,
            calendar: calendar,
            currentHour: currentHour,
            maxDate: maxDate
        )
        Self.deduplicateAndAggregate(parsedFiles: parsedFiles, into: &aggregator)

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
        Self.logger.info("source=gemini mode=\(mode, privacy: .public) duration_ms=\(duration, privacy: .public)")
    }

    private static func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Incremental state

    private struct SavedState: Codable, Sendable {
        var stamp: CollectionStamp
        var fingerprints: Fingerprints
    }

    private struct Fingerprints: Codable, Hashable, Sendable {
        var files: [String: FileFingerprint]

        init(files: [URL]) {
            var result: [String: FileFingerprint] = [:]
            for file in files {
                guard let fingerprint = FileFingerprint(url: file) else { continue }
                result[file.path] = fingerprint
            }
            self.files = result
        }
    }

    // MARK: - File discovery

    private func discoverFiles(sessionRootExists: Bool, headlessRoots: [URL]) throws -> [URL] {
        var discovered: [URL] = []
        var seenPaths: Set<String> = []

        func appendIfUnique(_ url: URL) {
            let standardized = url.standardizedFileURL.path
            if seenPaths.insert(standardized).inserted {
                discovered.append(url)
            }
        }

        if sessionRootExists {
            for url in try enumerateRegularFiles(under: sessionRoot, errorMessage: "Could not enumerate Gemini sessions") {
                if Self.isAcceptedSessionFile(url, under: sessionRoot) {
                    appendIfUnique(url)
                }
            }
        }

        for root in headlessRoots {
            for url in try enumerateRegularFiles(under: root, errorMessage: "Could not enumerate Gemini headless logs") {
                let ext = url.pathExtension.lowercased()
                if ext == "jsonl" || ext == "json" {
                    appendIfUnique(url)
                }
            }
        }

        return discovered.sorted { $0.path < $1.path }
    }

    private func enumerateRegularFiles(under root: URL, errorMessage: String) throws -> [URL] {
        var files: [URL] = []
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CollectorError.open(errorMessage)
        }
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(url)
            }
        }
        if let enumerationError { throw enumerationError }
        return files
    }

    private static func isAcceptedSessionFile(_ url: URL, under root: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "jsonl" {
            return true
        }
        guard ext == "json" else {
            return false
        }
        if url.lastPathComponent.hasPrefix("session-") {
            return true
        }
        guard let components = relativeComponents(of: url, under: root) else {
            return false
        }
        return components.count == 3
            && !components[0].isEmpty
            && components[1] == "chats"
            && !components[2].isEmpty
    }

    private static func relativeComponents(of url: URL, under root: URL) -> [String]? {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
                .split(separator: "/")
                .map(String.init)
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedFile = url.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        if resolvedFile.hasPrefix(resolvedPrefix) {
            return String(resolvedFile.dropFirst(resolvedPrefix.count))
                .split(separator: "/")
                .map(String.init)
        }
        return nil
    }

    // MARK: - Parsed intermediate model

    private struct TurnEvent {
        var sessionID: String?
        var id: String?
        var timestampMs: Int64
        var rawModelID: String
        var counts: TokenCounts
        var calls: Int64
    }

    private struct SummaryRow {
        var timestampMs: Int64
        var rawModelID: String
        var counts: TokenCounts
        var calls: Int64
    }

    private struct SummarySession {
        var sessionID: String?
        var rows: [SummaryRow]

        var totalTokens: Int64 {
            rows.reduce(0) { $0 + $1.counts.total }
        }
    }

    private struct PendingSummary {
        var stats: [String: Any]
        var container: [String: Any]
        var outerTimestamp: TimestampResolution = .absent
        var sessionID: String?
        var model: String?
    }

    private struct ParsedFile {
        var turnEvents: [TurnEvent] = []
        var summarySessions: [SummarySession] = []
        var skippedRecords: Int = 0
    }

    private enum TokenParseResult {
        case counts(TokenCounts)
        case zero
        case invalid
    }

    private enum TimestampResolution {
        case resolved(Int64)
        case absent
        case invalid
    }

    private enum IntFieldResult {
        case absent
        case valid(Int64)
        case invalid

        var value: Int64? {
            if case .valid(let v) = self { return v }
            return nil
        }
    }

    // MARK: - File parsing

    private static func parseFile(url: URL, data: Data, maxDate: Date) -> ParsedFile {
        let fileMtimeMs = modificationMilliseconds(of: url)
        let payload = stripBOM(data[...])
        let trimmedPayload = trimASCIIWhitespace(payload)
        guard !trimmedPayload.isEmpty else {
            return ParsedFile()
        }

        if url.pathExtension.lowercased() == "jsonl" {
            return parseJSONL(payload: payload, fileMtimeMs: fileMtimeMs, maxDate: maxDate)
        }
        return parseJSONDocument(payload: trimmedPayload, fileMtimeMs: fileMtimeMs, maxDate: maxDate)
    }

    private static func parseJSONDocument(payload: Data, fileMtimeMs: Int64, maxDate: Date) -> ParsedFile {
        var result = ParsedFile()
        guard let jsonObject = try? JSONSerialization.jsonObject(with: payload) else {
            result.skippedRecords += 1
            return result
        }

        if let objects = jsonObject as? [Any] {
            parseEventSequence(objects, fileMtimeMs: fileMtimeMs, maxDate: maxDate, into: &result)
            return result
        }

        guard let doc = jsonObject as? [String: Any] else {
            return result
        }

        let resultObj = doc["result"] as? [String: Any]
        let docSessionID = firstTrimmedString(in: doc, keys: ["sessionId", "session_id"])
            ?? resultObj.flatMap { firstTrimmedString(in: $0, keys: ["sessionId", "session_id"]) }
        let docModel = firstTrimmedString(in: doc, keys: ["model", "model_id", "modelId"])
            ?? resultObj.flatMap { firstTrimmedString(in: $0, keys: ["model", "model_id", "modelId"]) }
        let docTimestamp = resolveTimestamp(
            in: doc,
            keys: ["timestamp", "ts", "lastUpdated", "last_updated", "startTime", "start_time", "createdAt", "created_at"]
        )

        var turnIndexByID: [String: Int] = [:]

        if let messages = doc["messages"] as? [Any] {
            for element in messages {
                guard let msg = element as? [String: Any] else { continue }
                ingestTurnIfApplicable(
                    msg,
                    defaultSessionID: docSessionID,
                    defaultModel: docModel,
                    fallbackTimestamp: docTimestamp,
                    fileMtimeMs: fileMtimeMs,
                    maxDate: maxDate,
                    turnEvents: &result.turnEvents,
                    turnIndexByID: &turnIndexByID,
                    skippedRecords: &result.skippedRecords
                )
            }
        } else {
            // Single JSON object might itself be a direct per-turn token event.
            ingestTurnIfApplicable(
                doc,
                defaultSessionID: docSessionID,
                defaultModel: docModel,
                fallbackTimestamp: .absent,
                fileMtimeMs: fileMtimeMs,
                maxDate: maxDate,
                turnEvents: &result.turnEvents,
                turnIndexByID: &turnIndexByID,
                skippedRecords: &result.skippedRecords
            )
        }

        // CRITICAL: ignore stats / result.stats whenever this file yielded any per-turn token event.
        if result.turnEvents.isEmpty {
            if let stats = doc["stats"] as? [String: Any] {
                let pending = PendingSummary(stats: stats, container: doc, sessionID: docSessionID, model: docModel)
                if let summary = parseSummary(pending, fallbackTimestamp: .absent, fileMtimeMs: fileMtimeMs, maxDate: maxDate, skippedRecords: &result.skippedRecords) {
                    result.summarySessions.append(summary)
                }
            } else if let resultObj, let stats = resultObj["stats"] as? [String: Any] {
                let pending = PendingSummary(stats: stats, container: resultObj, sessionID: docSessionID, model: docModel)
                if let summary = parseSummary(pending, fallbackTimestamp: docTimestamp, fileMtimeMs: fileMtimeMs, maxDate: maxDate, skippedRecords: &result.skippedRecords) {
                    result.summarySessions.append(summary)
                }
            }
        }

        return result
    }

    private static func parseJSONL(payload: Data, fileMtimeMs: Int64, maxDate: Date) -> ParsedFile {
        var result = ParsedFile()
        var objects: [Any] = []
        for rawLine in payload.split(separator: 0x0A) {
            let trimmed = trimASCIIWhitespace(rawLine)
            guard !trimmed.isEmpty else { continue }
            let clean = stripBOM(trimmed)
            guard let jsonObject = try? JSONSerialization.jsonObject(with: clean) else {
                result.skippedRecords += 1
                continue
            }
            objects.append(jsonObject)
        }
        parseEventSequence(objects, fileMtimeMs: fileMtimeMs, maxDate: maxDate, into: &result)
        return result
    }

    private static func parseEventSequence(
        _ objects: [Any],
        fileMtimeMs: Int64,
        maxDate: Date,
        into result: inout ParsedFile
    ) {
        var fileSessionID: String?
        var fileModel: String?
        var initTimestamp: TimestampResolution = .absent
        var turnIndexByID: [String: Int] = [:]
        var pendingSummaries: [PendingSummary] = []

        for element in objects {
            guard let line = element as? [String: Any] else { continue }

            let resultObj = line["result"] as? [String: Any]
            let lineSessionID = firstTrimmedString(in: line, keys: ["session_id", "sessionId"])
                ?? resultObj.flatMap { firstTrimmedString(in: $0, keys: ["session_id", "sessionId"]) }
            let lineModel = firstTrimmedString(in: line, keys: ["model", "model_id", "modelId"])
                ?? resultObj.flatMap { firstTrimmedString(in: $0, keys: ["model", "model_id", "modelId"]) }
            let lineType = trimmedString(line["type"])?.lowercased()

            if lineType == "init" {
                if let lineSessionID { fileSessionID = lineSessionID }
                if let lineModel { fileModel = lineModel }
                let ts = resolveTimestamp(in: line, keys: ["timestamp", "ts", "createdAt", "created_at"])
                if case .resolved = ts {
                    initTimestamp = ts
                }
                continue
            }

            if fileSessionID == nil, let lineSessionID {
                fileSessionID = lineSessionID
            }
            if fileModel == nil, let lineModel {
                fileModel = lineModel
            }

            if isTurnEventCandidate(line) {
                ingestTurnIfApplicable(
                    line,
                    defaultSessionID: fileSessionID,
                    defaultModel: fileModel,
                    fallbackTimestamp: initTimestamp,
                    fileMtimeMs: fileMtimeMs,
                    maxDate: maxDate,
                    turnEvents: &result.turnEvents,
                    turnIndexByID: &turnIndexByID,
                    skippedRecords: &result.skippedRecords
                )
                continue
            }

            if let stats = line["stats"] as? [String: Any] {
                pendingSummaries.append(PendingSummary(
                    stats: stats,
                    container: line,
                    sessionID: lineSessionID ?? fileSessionID,
                    model: lineModel ?? fileModel
                ))
            } else if let resultObj, let stats = resultObj["stats"] as? [String: Any] {
                let lineTimestamp = resolveTimestamp(
                    in: line,
                    keys: ["timestamp", "ts", "lastUpdated", "last_updated", "startTime", "start_time", "createdAt", "created_at"]
                )
                pendingSummaries.append(PendingSummary(
                    stats: stats,
                    container: resultObj,
                    outerTimestamp: lineTimestamp,
                    sessionID: lineSessionID ?? fileSessionID,
                    model: lineModel ?? fileModel
                ))
            }
        }

        // Backfill sessionID discovered on a later line (for example on a trailing `result` event)
        // so cross-file suppression still recognizes that this session has per-turn events.
        if !result.turnEvents.isEmpty {
            if let fileSessionID {
                for index in result.turnEvents.indices where result.turnEvents[index].sessionID == nil {
                    result.turnEvents[index].sessionID = fileSessionID
                }
            }
            // CRITICAL: ignore all stats / result.stats summaries whenever per-turn events exist.
            return
        }

        var summaryIndexBySessionID: [String: Int] = [:]
        for var pending in pendingSummaries {
            if pending.sessionID == nil { pending.sessionID = fileSessionID }
            if pending.model == nil { pending.model = fileModel }
            guard let summary = parseSummary(
                pending,
                fallbackTimestamp: initTimestamp,
                fileMtimeMs: fileMtimeMs,
                maxDate: maxDate,
                skippedRecords: &result.skippedRecords
            ) else { continue }
            if let sid = summary.sessionID, !sid.isEmpty {
                if let existing = summaryIndexBySessionID[sid] {
                    result.summarySessions[existing] = summary
                } else {
                    summaryIndexBySessionID[sid] = result.summarySessions.count
                    result.summarySessions.append(summary)
                }
            } else {
                result.summarySessions.append(summary)
            }
        }
    }

    private static func isTurnEventCandidate(_ dict: [String: Any]) -> Bool {
        if trimmedString(dict["type"])?.lowercased() == "gemini" {
            return true
        }
        return dict["tokens"] is [String: Any]
    }

    private static func ingestTurnIfApplicable(
        _ dict: [String: Any],
        defaultSessionID: String?,
        defaultModel: String?,
        fallbackTimestamp: TimestampResolution,
        fileMtimeMs: Int64,
        maxDate: Date,
        turnEvents: inout [TurnEvent],
        turnIndexByID: inout [String: Int],
        skippedRecords: inout Int
    ) {
        guard isTurnEventCandidate(dict) else { return }

        let tokenContainer = (dict["tokens"] as? [String: Any])
            ?? (dict["usage"] as? [String: Any])
            ?? (dict["usageMetadata"] as? [String: Any])
            ?? dict

        let counts: TokenCounts
        switch parseTokens(from: tokenContainer) {
        case .counts(let parsed):
            counts = parsed
        case .zero:
            return
        case .invalid:
            skippedRecords += 1
            return
        }

        guard let timestampMs = resolveEventTimestamp(
            primary: resolveTimestamp(in: dict, keys: ["timestamp", "ts", "createdAt", "created_at"]),
            fallback: fallbackTimestamp,
            fileMtimeMs: fileMtimeMs,
            maxDate: maxDate
        ) else {
            skippedRecords += 1
            return
        }

        let sessionID = firstTrimmedString(in: dict, keys: ["session_id", "sessionId"]) ?? defaultSessionID
        let id = firstTrimmedString(in: dict, keys: ["id", "message_id", "messageId"])
        let model = firstTrimmedString(in: dict, keys: ["model", "model_id", "modelId"]) ?? defaultModel ?? "unknown"

        let event = TurnEvent(
            sessionID: sessionID,
            id: id,
            timestampMs: timestampMs,
            rawModelID: model,
            counts: counts,
            calls: 1
        )

        if let id, !id.isEmpty {
            if let existingIndex = turnIndexByID[id] {
                turnEvents[existingIndex] = event
            } else {
                turnIndexByID[id] = turnEvents.count
                turnEvents.append(event)
            }
        } else {
            turnEvents.append(event)
        }
    }

    private static func parseSummary(
        _ pending: PendingSummary,
        fallbackTimestamp: TimestampResolution,
        fileMtimeMs: Int64,
        maxDate: Date,
        skippedRecords: inout Int
    ) -> SummarySession? {
        let stats = pending.stats
        let containerTimestamp = resolveTimestamp(
            in: pending.container,
            keys: ["timestamp", "ts", "lastUpdated", "last_updated", "startTime", "start_time", "createdAt", "created_at"]
        )
        let statsTimestamp = resolveTimestamp(
            in: stats,
            keys: ["timestamp", "ts", "lastUpdated", "last_updated", "startTime", "start_time", "createdAt", "created_at"]
        )
        let baseTimestamp: TimestampResolution = switch statsTimestamp {
        case .absent:
            switch containerTimestamp {
            case .absent:
                switch pending.outerTimestamp {
                case .absent: fallbackTimestamp
                default: pending.outerTimestamp
                }
            default: containerTimestamp
            }
        default: statsTimestamp
        }

        var rows: [SummaryRow] = []

        if let modelsDict = stats["models"] as? [String: Any], !modelsDict.isEmpty {
            for modelName in modelsDict.keys.sorted() {
                guard let entry = modelsDict[modelName] as? [String: Any] else { continue }
                let tokenContainer = (entry["tokens"] as? [String: Any]) ?? entry
                let counts: TokenCounts
                switch parseTokens(from: tokenContainer) {
                case .counts(let parsed):
                    counts = parsed
                case .zero:
                    continue
                case .invalid:
                    skippedRecords += 1
                    continue
                }

                let entryTimestamp = resolveTimestamp(in: entry, keys: ["timestamp", "ts", "createdAt", "created_at"])
                let effectivePrimary: TimestampResolution = switch entryTimestamp {
                case .absent: baseTimestamp
                default: entryTimestamp
                }
                guard let timestampMs = resolveEventTimestamp(
                    primary: effectivePrimary,
                    fallback: .absent,
                    fileMtimeMs: fileMtimeMs,
                    maxDate: maxDate
                ) else {
                    skippedRecords += 1
                    continue
                }

                let resolvedModel = nonEmpty(modelName) ?? pending.model ?? "unknown"
                let calls = extractRequestCount(from: entry) ?? 1
                rows.append(SummaryRow(
                    timestampMs: timestampMs,
                    rawModelID: resolvedModel,
                    counts: counts,
                    calls: calls
                ))
            }
        } else {
            let tokenContainer = (stats["tokens"] as? [String: Any]) ?? stats
            switch parseTokens(from: tokenContainer) {
            case .counts(let counts):
                guard let timestampMs = resolveEventTimestamp(
                    primary: baseTimestamp,
                    fallback: .absent,
                    fileMtimeMs: fileMtimeMs,
                    maxDate: maxDate
                ) else {
                    skippedRecords += 1
                    return nil
                }
                let resolvedModel = firstTrimmedString(in: stats, keys: ["model", "model_id", "modelId"])
                    ?? pending.model
                    ?? "unknown"
                let calls = extractRequestCount(from: stats) ?? 1
                rows.append(SummaryRow(
                    timestampMs: timestampMs,
                    rawModelID: resolvedModel,
                    counts: counts,
                    calls: calls
                ))
            case .zero:
                break
            case .invalid:
                skippedRecords += 1
            }
        }

        guard !rows.isEmpty else { return nil }
        return SummarySession(sessionID: pending.sessionID, rows: rows)
    }

    private static func extractRequestCount(from dict: [String: Any]) -> Int64? {
        if let api = dict["api"] as? [String: Any],
           case .valid(let count) = firstInteger(in: api, keys: ["totalRequests", "total_requests", "requests"]),
           count > 0 {
            return count
        }
        if case .valid(let count) = firstInteger(in: dict, keys: ["totalRequests", "total_requests", "requests"]),
           count > 0 {
            return count
        }
        return nil
    }

    // MARK: - Token extraction & inclusive-input normalization

    private static func parseTokens(from dict: [String: Any]) -> TokenParseResult {
        let rawInputField = firstInteger(in: dict, keys: ["input", "prompt", "input_tokens", "prompt_tokens", "promptTokenCount"])
        let outputField = firstInteger(in: dict, keys: ["output", "candidates", "output_tokens", "completion_tokens", "candidatesTokenCount"])
        let cachedField = firstInteger(in: dict, keys: ["cached", "cached_tokens", "cachedContentTokenCount"])
        let thoughtsField = firstInteger(in: dict, keys: ["thoughts", "reasoning", "thoughts_tokens"])
        let toolField = firstInteger(in: dict, keys: ["tool", "tool_tokens"])
        let totalField = firstInteger(in: dict, keys: ["total", "totalTokenCount", "total_tokens"])

        for field in [rawInputField, outputField, cachedField, thoughtsField, toolField, totalField] {
            if case .invalid = field {
                return .invalid
            }
        }

        let rawInput = rawInputField.value ?? 0
        let output = outputField.value ?? 0
        let cached = cachedField.value ?? 0
        let thoughts = thoughtsField.value ?? 0
        let tool = toolField.value ?? 0
        let total = totalField.value

        if rawInput == 0 && output == 0 && cached == 0 && thoughts == 0 && tool == 0 {
            return .zero
        }

        let isExclusive = cached > 0 && (
            rawInput < cached
                || (total != nil && total == rawInput + cached + output + thoughts + tool)
        )
        let uncachedInput = isExclusive ? rawInput : max(rawInput - cached, 0)
        return .counts(TokenCounts(
            input: uncachedInput + tool,
            cacheRead: cached,
            cacheWrite: 0,
            output: output,
            reasoning: thoughts
        ))
    }

    // MARK: - Cross-file deduplication

    private static func deduplicateAndAggregate(parsedFiles: [ParsedFile], into aggregator: inout Aggregator) {
        var sessionsWithTurns: Set<String> = []
        for file in parsedFiles {
            for _ in 0..<file.skippedRecords {
                aggregator.skip()
            }
            for event in file.turnEvents {
                if let sid = event.sessionID, !sid.isEmpty {
                    sessionsWithTurns.insert(sid)
                }
            }
        }

        var finalTurns: [TurnEvent] = []
        var turnIndexByGlobalKey: [String: Int] = [:]
        for file in parsedFiles {
            for event in file.turnEvents {
                if let id = event.id, !id.isEmpty {
                    let key = "\(event.sessionID ?? "")\u{0}\(id)"
                    if let existingIndex = turnIndexByGlobalKey[key] {
                        if event.counts.total >= finalTurns[existingIndex].counts.total {
                            finalTurns[existingIndex] = event
                        }
                    } else {
                        turnIndexByGlobalKey[key] = finalTurns.count
                        finalTurns.append(event)
                    }
                } else {
                    finalTurns.append(event)
                }
            }
        }

        var finalSummaries: [SummarySession] = []
        var summaryIndexBySessionID: [String: Int] = [:]
        for file in parsedFiles {
            for summary in file.summarySessions {
                if let sid = summary.sessionID, !sid.isEmpty {
                    if sessionsWithTurns.contains(sid) {
                        continue
                    }
                    if let existingIndex = summaryIndexBySessionID[sid] {
                        if summary.totalTokens >= finalSummaries[existingIndex].totalTokens {
                            finalSummaries[existingIndex] = summary
                        }
                    } else {
                        summaryIndexBySessionID[sid] = finalSummaries.count
                        finalSummaries.append(summary)
                    }
                } else {
                    finalSummaries.append(summary)
                }
            }
        }

        for event in finalTurns {
            aggregator.record(
                timestamp: event.timestampMs,
                rawModelID: event.rawModelID,
                counts: event.counts,
                calls: event.calls
            )
        }

        for summary in finalSummaries {
            for row in summary.rows {
                aggregator.record(
                    timestamp: row.timestampMs,
                    rawModelID: row.rawModelID,
                    counts: row.counts,
                    calls: row.calls
                )
            }
        }
    }

    // MARK: - JSON, integer, and timestamp helpers

    /// Largest counter accepted from a log; rejecting larger values keeps sums from overflowing Int64.
    private static let maxCounter: Int64 = 1 << 50

    private static func firstInteger(in dict: [String: Any], keys: [String]) -> IntFieldResult {
        for key in keys {
            guard let raw = dict[key], !(raw is NSNull) else { continue }
            guard let parsed = parseIntegerValue(raw) else { continue }
            switch parsed {
            case .valid(let v):
                return .valid(v)
            case .invalid:
                return .invalid
            case .absent:
                continue
            }
        }
        return .absent
    }

    private static func parseIntegerValue(_ value: Any) -> IntFieldResult? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            if !CFNumberIsFloatType(number) {
                let i = number.int64Value
                if number.doubleValue >= 0 && i < 0 {
                    return .invalid
                }
                if i < 0 || i > maxCounter {
                    return .invalid
                }
                return .valid(i)
            }
            let d = number.doubleValue
            guard d.isFinite, d.rounded(.towardZero) == d else { return nil }
            if d < 0 || d > Double(maxCounter) {
                return .invalid
            }
            return .valid(Int64(d))
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let i = Int64(trimmed) else { return nil }
            if i < 0 || i > maxCounter {
                return .invalid
            }
            return .valid(i)
        }
        return nil
    }

    private static func stripBOM(_ slice: Data) -> Data {
        slice.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(slice.dropFirst(3)) : Data(slice)
    }

    private static func trimASCIIWhitespace(_ slice: Data) -> Data {
        var trimmed = slice.drop { $0 == 0x20 || $0 == 0x0D || $0 == 0x09 || $0 == 0x0A }
        while let last = trimmed.last, last == 0x20 || last == 0x0D || last == 0x09 || last == 0x0A {
            trimmed = trimmed.dropLast()
        }
        return Data(trimmed)
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstTrimmedString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let s = trimmedString(dict[key]) {
                return s
            }
        }
        return nil
    }

    private static func modificationMilliseconds(of url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else {
            return 0
        }
        return Int64((modified.timeIntervalSince1970 * 1_000).rounded())
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

    private static func resolveTimestamp(in dict: [String: Any], keys: [String]) -> TimestampResolution {
        for key in keys {
            guard let raw = dict[key], !(raw is NSNull) else { continue }
            if let ms = parseTimestamp(raw) {
                return .resolved(ms)
            }
            return .invalid
        }
        return .absent
    }

    private static func resolveEventTimestamp(
        primary: TimestampResolution,
        fallback: TimestampResolution,
        fileMtimeMs: Int64,
        maxDate: Date
    ) -> Int64? {
        let resolvedMs: Int64
        switch primary {
        case .resolved(let ms):
            resolvedMs = ms
        case .invalid:
            return nil
        case .absent:
            switch fallback {
            case .resolved(let ms):
                resolvedMs = ms
            case .invalid:
                return nil
            case .absent:
                resolvedMs = fileMtimeMs
            }
        }
        guard resolvedMs > 0 else { return nil }
        let date = Date(timeIntervalSince1970: Double(resolvedMs) / 1_000)
        guard date <= maxDate else { return nil }
        return resolvedMs
    }

    private static func parseTimestamp(_ value: Any) -> Int64? {
        let numeric: Double?
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            numeric = number.doubleValue
        } else if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let parsed = Double(trimmed) {
                numeric = parsed
            } else {
                return isoMilliseconds(trimmed)
            }
        } else {
            return nil
        }
        guard let v = numeric, v.isFinite, v > 0, v < 9.2e18 else { return nil }
        return v < 1e12 ? Int64((v * 1_000).rounded()) : Int64(v.rounded())
    }

    private static func isoMilliseconds(_ raw: String) -> Int64? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasSuffix("z") {
            text = String(text.dropLast()) + "Z"
        }
        if text.count > 10 {
            let sepIdx = text.index(text.startIndex, offsetBy: 10)
            if text[sepIdx] == " " || text[sepIdx] == "t" {
                text.replaceSubrange(sepIdx...sepIdx, with: "T")
            }
        }
        if let date = fractionalFormatter.date(from: text) ?? plainFormatter.date(from: text) {
            return Int64((date.timeIntervalSince1970 * 1_000).rounded())
        }
        guard let dot = text.firstIndex(of: ".") else { return nil }
        let remainder = text[text.index(after: dot)...]
        guard let zone = remainder.firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) else { return nil }
        let fracDigits = remainder[..<zone]
        guard !fracDigits.isEmpty, fracDigits.allSatisfy(\.isASCII), fracDigits.allSatisfy(\.isNumber) else {
            return nil
        }
        guard let baseDate = plainFormatter.date(from: String(text[..<dot]) + String(remainder[zone...])),
              let frac = Double("0." + fracDigits) else {
            return nil
        }
        return Int64(((baseDate.timeIntervalSince1970 + frac) * 1_000).rounded())
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
        let maxDate: Date

        var daily: [Key: UsageRecord] = [:]
        var hourly: [Date: HourlyUsage] = [:]
        var skipped = 0

        mutating func skip() {
            skipped += 1
        }

        mutating func record(timestamp: Int64, rawModelID: String, counts: TokenCounts, calls: Int64) {
            guard timestamp > 0 else {
                skipped += 1
                return
            }
            let date = Date(timeIntervalSince1970: Double(timestamp) / 1_000)
            guard date <= maxDate,
                  let hour = calendar.dateInterval(of: .hour, for: date)?.start else {
                skipped += 1
                return
            }
            let trimmedModel = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedRaw = trimmedModel.isEmpty ? "unknown" : trimmedModel
            let model = resolvedRaw.lowercased()

            let day = UsageDay.string(from: date, in: timeZone)
            let dailyKey = Key(day: day, modelID: model)
            var row = daily[dailyKey] ?? UsageRecord(
                day: day,
                timeZoneID: timeZone.identifier,
                deviceID: deviceID,
                sourceID: "gemini",
                modelID: model,
                rawModelID: resolvedRaw,
                counts: .zero
            )
            row.rawModelID = min(row.rawModelID, resolvedRaw)
            row.counts += counts
            row.eventCount += calls
            daily[dailyKey] = row

            guard hour <= currentHour else { return }
            var hourRow = hourly[hour] ?? HourlyUsage(
                hourStart: hour,
                deviceID: deviceID,
                sourceID: "gemini",
                counts: .zero,
                eventCount: 0,
                reasoningKnown: true
            )
            hourRow.counts += counts
            hourRow.eventCount += calls
            hourRow.reasoningKnown = true
            hourly[hour] = hourRow
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
}
