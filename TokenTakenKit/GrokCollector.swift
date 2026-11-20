import CoreFoundation
import Foundation
import OSLog

/// Reads Grok CLI / Grok Build session update logs natively under `$GROK_HOME/sessions`
/// (or `~/.grok/sessions/**/updates.jsonl`), along with sibling `summary.json`, `events.jsonl`,
/// and `signals.json` metadata.
///
/// `$GROK_HOME/logs/unified.jsonl` is deliberately ignored. In tokscale 4.21.0,
/// `prefer_unified_log_messages` fails to deduplicate a `shell.turn.inference_done` record in
/// `unified.jsonl` against the matching `turn_completed` record in `updates.jsonl` when
/// `message_count == 1` and the timestamps differ by a few hundred milliseconds, counting the same
/// inference twice (ADR-0014). Reading only the session `updates.jsonl` tree matches the
/// independent ledger and avoids that double count.
public struct GrokCollector: UsageCollector {
    public let sourceIDs = ["grok"]

    private static let stateFormatVersion = 1
    private static let logger = Logger(subsystem: "io.github.elijah7x.TokenTaken", category: "collection")

    private let baseDirectory: URL
    private let sessionsRoot: URL
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

    /// Pins the Grok home root, time zone, and hourly window; used by tests.
    public init(
        deviceID: String,
        home: URL,
        environment: [String: String] = [:],
        timeZone: TimeZone = .current,
        now: Date = .now,
        stateDirectory: URL? = nil
    ) {
        let base = Self.grokHome(home: home, environment: environment)
        baseDirectory = base
        sessionsRoot = base.appendingPathComponent("sessions", isDirectory: true)
        self.deviceID = deviceID
        self.timeZone = timeZone
        self.now = now
        self.stateFile = stateDirectory.map { CollectorStateFile(directory: $0, name: "grok") }
    }

    static func grokHome(home: URL, environment: [String: String]) -> URL {
        let homeOverride = environment["GROK_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return homeOverride.isEmpty
            ? home.appendingPathComponent(".grok", isDirectory: true)
            : URL(fileURLWithPath: homeOverride, isDirectory: true)
    }

    public func collect() async throws -> CollectionBatch {
        let started = Date.now
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: baseDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CollectorError.sourceUnavailable
        }

        let stamp = CollectionStamp(formatVersion: Self.stateFormatVersion, timeZone: timeZone, sourceIDs: sourceIDs)
        let files = try sessionFiles()
        let fingerprints = Fingerprints(files: files, root: sessionsRoot)
        if let stateFile, let saved = stateFile.load(), saved.stamp == stamp, saved.fingerprints == fingerprints {
            log(mode: "unchanged", since: started)
            return CollectionBatch(unchangedSourceIDs: Set(sourceIDs))
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        var aggregator = Aggregator(
            deviceID: deviceID,
            timeZone: timeZone,
            calendar: calendar,
            currentHour: currentHour,
            cutoff: currentHour.addingTimeInterval(-47 * 3_600),
            maxDate: now.addingTimeInterval(86_400)
        )

        for file in files {
            let data: Data
            do {
                data = try Data(contentsOf: file)
            } catch {
                throw CollectorError.open("Could not read a Grok session file")
            }
            Self.parseSessionUpdates(file: file, data: data, into: &aggregator)
        }

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
        Self.logger.info("source=grok mode=\(mode, privacy: .public) duration_ms=\(duration, privacy: .public)")
    }

    private struct SavedState: Codable, Sendable {
        var stamp: CollectionStamp
        var fingerprints: Fingerprints
    }

    /// Root-relative path to file metadata for every `updates.jsonl` and its sibling metadata files.
    private struct Fingerprints: Codable, Hashable, Sendable {
        var files: [String: FileFingerprint]

        init(files: [URL], root: URL) {
            var result: [String: FileFingerprint] = [:]
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            func record(_ url: URL) {
                guard let fingerprint = FileFingerprint(url: url) else { return }
                let key = url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
                result[key] = fingerprint
            }
            for file in files {
                record(file)
                let dir = file.deletingLastPathComponent()
                for sibling in ["summary.json", "events.jsonl", "signals.json"] {
                    record(dir.appendingPathComponent(sibling))
                }
            }
            self.files = result
        }
    }

    /// Every `updates.jsonl` under `$GROK_HOME/sessions`.
    private func sessionFiles() throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessionsRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }
        var files: [URL] = []
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CollectorError.open("Could not enumerate Grok sessions")
        }
        for case let url as URL in enumerator where url.lastPathComponent == "updates.jsonl" {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(url)
            }
        }
        if let enumerationError { throw enumerationError }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: - Session parsing (ledger.py parity)

    private struct SessionMetadata {
        var model: String?
        var ms: Int64
        var signals: [String: Any]?
    }

    private struct ParsedRow {
        var ms: Int64
        var model: String
        var counts: TokenCounts
        var calls: Int64
    }

    private struct Turn {
        var base: Int64
        var max: Int64
        var ms: Int64
        var model: String
    }

    private static func parseSessionUpdates(file: URL, data: Data, into aggregator: inout Aggregator) {
        let meta = loadMetadata(for: file)
        var current = nonEmpty(meta.model) ?? "grok-unknown"
        var lastTotal: Int64?
        var lastTotalMs = meta.ms
        var turn: Turn?
        var fallback: [ParsedRow] = []
        var usageRows: [ParsedRow] = []
        var promptIndex: [String: Int] = [:]

        func close(_ t: Turn) {
            let delta = t.max - t.base
            if delta > 0 {
                let model = t.model.isEmpty ? "grok-unknown" : t.model
                fallback.append(ParsedRow(ms: t.ms, model: model, counts: TokenCounts(input: delta), calls: 1))
            }
        }

        let payload = stripBOM(data[...])
        for rawLine in payload.split(separator: 0x0A) {
            var trimmed = rawLine.drop { $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }
            while let last = trimmed.last, last == 0x20 || last == 0x0D || last == 0x09 {
                trimmed = trimmed.dropLast()
            }
            guard !trimmed.isEmpty else { continue }
            let clean = stripBOM(trimmed)
            guard let jsonObject = try? JSONSerialization.jsonObject(with: clean) else {
                aggregator.skip()
                continue
            }
            guard let value = jsonObject as? [String: Any] else {
                continue
            }

            if let model = first(in: value, paths: [
                ["params", "update", "_meta", "modelId"],
                ["params", "_meta", "modelId"],
                ["params", "modelId"],
                ["model_id"],
                ["modelId"],
                ["model"],
            ], transform: trimmedText) {
                current = model
                if turn != nil && turn?.model == "grok-unknown" {
                    turn?.model = current
                }
            }

            let ms = first(in: value, paths: [
                ["params", "_meta", "agentTimestampMs"],
                ["params", "update", "_meta", "agentTimestampMs"],
                ["params", "timestamp"],
                ["timestamp"],
                ["ts"],
            ], transform: grokTimestamp) ?? meta.ms

            if string(at: ["params", "update", "sessionUpdate"], in: value) == "user_message_chunk" {
                if let existingTurn = turn {
                    close(existingTurn)
                }
                turn = Turn(base: lastTotal ?? 0, max: lastTotal ?? 0, ms: ms, model: current)
            }

            if let parsed = parseUsage(value) {
                var rowModel = current
                if rowModel == "grok-unknown" {
                    let singleModelUsageKey: String? = if let mu = parsed.modelUsage, mu.count == 1 {
                        nonEmpty(mu.keys.first)
                    } else {
                        nil
                    }
                    rowModel = singleModelUsageKey ?? nonEmpty(meta.model) ?? "grok-unknown"
                }
                let prompt = first(in: value, paths: [
                    ["params", "update", "promptId"],
                    ["params", "update", "prompt_id"],
                    ["params", "_meta", "promptId"],
                    ["params", "_meta", "prompt_id"],
                ], transform: trimmedText)
                let row = ParsedRow(ms: ms, model: rowModel, counts: parsed.counts, calls: parsed.calls)
                if let prompt, let existingIndex = promptIndex[prompt] {
                    if row.counts.total >= usageRows[existingIndex].counts.total {
                        usageRows[existingIndex] = row
                    }
                } else {
                    if let prompt {
                        promptIndex[prompt] = usageRows.count
                    }
                    usageRows.append(row)
                }
            }

            guard let total = first(in: value, paths: [
                ["params", "_meta", "totalTokens"],
                ["params", "update", "_meta", "totalTokens"],
                ["params", "update", "totalTokens"],
                ["params", "totalTokens"],
                ["usage", "totalTokens"],
                ["totalTokens"],
            ], transform: asInt), total >= 0 else {
                continue
            }
            if let lastTotal, total < lastTotal {
                continue
            }
            if let lastTotal, total == lastTotal {
                lastTotalMs = ms
                continue
            }
            if let lastTotal, turn == nil {
                turn = Turn(base: lastTotal, max: lastTotal, ms: ms, model: current)
            }
            if turn != nil, total > turn!.max {
                turn!.max = total
                turn!.ms = ms
            }
            lastTotalMs = ms
            lastTotal = total
        }

        if let existingTurn = turn {
            close(existingTurn)
        }
        if fallback.isEmpty && usageRows.isEmpty, let lastTotal, lastTotal > 0 {
            let model = current.isEmpty ? "grok-unknown" : current
            fallback.append(ParsedRow(ms: lastTotalMs, model: model, counts: TokenCounts(input: lastTotal), calls: 1))
        }

        let rowsToEmit: [ParsedRow]
        if usageRows.isEmpty {
            if let signals = meta.signals {
                let before = nonNegativeInt(signals["totalTokensBeforeCompaction"])
                let tot = nonNegativeInt(signals["totalTokens"])
                let effective = signals.keys.contains("contextTokensUsed")
                    ? max(tot, before + nonNegativeInt(signals["contextTokensUsed"]))
                    : (before + tot)
                let fallbackSum = fallback.reduce(Int64(0)) { $0 + $1.counts.input }
                let extra = effective - fallbackSum
                if effective > 0 && extra > 0 {
                    let sigMs = fallback.map(\.ms).max() ?? meta.ms
                    let sigModel = nonEmpty(signalsModel(signals)) ?? nonEmpty(meta.model) ?? current
                    fallback.append(ParsedRow(ms: sigMs, model: sigModel, counts: TokenCounts(input: extra), calls: 1))
                }
            }
            rowsToEmit = fallback
        } else {
            let latest = usageRows.map(\.ms).max()!
            rowsToEmit = usageRows + fallback.filter { $0.ms > latest }
        }

        for row in rowsToEmit {
            aggregator.record(timestamp: row.ms, rawModelID: row.model, counts: row.counts, calls: row.calls)
        }
    }

    private static func loadMetadata(for updatesURL: URL) -> SessionMetadata {
        let directory = updatesURL.deletingLastPathComponent()
        var meta = SessionMetadata(model: nil, ms: modificationMilliseconds(of: updatesURL), signals: nil)

        func loadJSON(_ name: String) -> [String: Any]? {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return nil
            }
            return obj
        }

        if let summary = loadJSON("summary.json") {
            for key in ["current_model_id", "model_id"] {
                if let candidate = summary[key] as? String {
                    meta.model = candidate
                    break
                }
            }
            if let ts = grokTimestamp(summary["updated_at"]) ?? grokTimestamp(summary["created_at"]) {
                meta.ms = ts
            }
        }

        let eventsURL = directory.appendingPathComponent("events.jsonl")
        if let eventsData = try? Data(contentsOf: eventsURL) {
            let lines = eventsData.split(separator: 0x0A, omittingEmptySubsequences: false).prefix(500)
            for rawLine in lines {
                guard !rawLine.isEmpty,
                      let obj = (try? JSONSerialization.jsonObject(with: rawLine)) as? [String: Any] else {
                    continue
                }
                if meta.model == nil, let modelID = obj["model_id"] as? String {
                    meta.model = modelID
                }
                if let ts = grokTimestamp(obj["ts"]) {
                    meta.ms = ts
                }
                if meta.model != nil {
                    break
                }
            }
        }

        if let signals = loadJSON("signals.json") {
            if meta.model == nil {
                meta.model = signalsModel(signals)
            }
            meta.signals = signals
        }

        return meta
    }

    private static func signalsModel(_ signals: [String: Any]) -> String? {
        if let primary = signals["primaryModelId"] as? String {
            return primary
        }
        if let models = signals["modelsUsed"] as? [Any], let first = models.first as? String {
            return first
        }
        return nil
    }

    private static func parseUsage(_ value: [String: Any]) -> (counts: TokenCounts, calls: Int64, modelUsage: [String: Any]?)? {
        if let kind = string(at: ["params", "update", "sessionUpdate"], in: value), kind != "turn_completed" {
            return nil
        }
        guard let usage = dictionary(at: ["params", "update", "usage"], in: value) else {
            return nil
        }

        func pick(_ keys: String...) -> Int64 {
            for key in keys {
                if let v = asInt(usage[key]) {
                    return max(v, 0)
                }
            }
            return 0
        }

        let rawIn = pick("inputTokens", "input_tokens", "promptTokens")
        let rawOut = pick("outputTokens", "output_tokens", "completionTokens")
        let cr = pick("cachedReadTokens", "cacheReadTokens", "cache_read_input_tokens")
        let cw = pick("cachedWriteTokens", "cacheWriteTokens", "cacheCreationTokens", "cache_creation_input_tokens")
        let reasoning = pick("reasoningTokens", "thoughtTokens", "thinkingTokens")
        if rawIn == 0 && rawOut == 0 && cr == 0 && cw == 0 && reasoning == 0 {
            return nil
        }

        let reportedRaw: Int64?
        if let totalTokens = usage["totalTokens"], !(totalTokens is NSNull) {
            reportedRaw = asInt(totalTokens)
        } else {
            reportedRaw = asInt(usage["total_tokens"])
        }
        let reported = reportedRaw.map { max($0, 0) }
        let inclusive = reported == nil || reported == rawIn + rawOut
        let input = inclusive ? max(rawIn - cr, 0) : rawIn
        let output = inclusive ? max(rawOut - reasoning, 0) : rawOut
        let counts = TokenCounts(input: input, cacheRead: cr, cacheWrite: cw, output: output, reasoning: reasoning)

        var calls: Int64?
        for key in ["modelCalls", "model_calls", "modelCallCount"] {
            if let v = asInt(usage[key]) {
                calls = v > 0 ? v : nil
                break
            }
        }
        let modelUsage = usage["modelUsage"] as? [String: Any]
        if calls == nil, let modelUsage, !modelUsage.isEmpty {
            var total: Int64 = 0
            var valid = true
            for entryAny in modelUsage.values {
                guard let entry = entryAny as? [String: Any] else {
                    valid = false
                    break
                }
                var v: Int64?
                for key in ["modelCalls", "model_calls", "modelCallCount"] {
                    v = asInt(entry[key])
                    if v != nil { break }
                }
                guard let found = v, found > 0 else {
                    valid = false
                    break
                }
                total += found
            }
            if valid && total > 0 {
                calls = total
            }
        }

        return (counts, calls ?? 1, modelUsage)
    }

    // MARK: - JSON & timestamp helpers

    private static func stripBOM(_ slice: Data) -> Data {
        slice.starts(with: [0xEF, 0xBB, 0xBF]) ? slice.dropFirst(3) : slice
    }

    private static func modificationMilliseconds(of url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else {
            return 0
        }
        return Int64(modified.timeIntervalSince1970 * 1_000)
    }

    private static func value(at path: [String], in root: [String: Any]) -> Any? {
        var current: Any = root
        for key in path {
            guard let dict = current as? [String: Any], let next = dict[key] else {
                return nil
            }
            current = next
        }
        return current
    }

    private static func dictionary(at path: [String], in root: [String: Any]) -> [String: Any]? {
        value(at: path, in: root) as? [String: Any]
    }

    private static func string(at path: [String], in root: [String: Any]) -> String? {
        value(at: path, in: root) as? String
    }

    private static func first<T>(in root: [String: Any], paths: [[String]], transform: (Any?) -> T?) -> T? {
        for path in paths {
            if let result = transform(value(at: path, in: root)) {
                return result
            }
        }
        return nil
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func trimmedText(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func asInt(_ value: Any?) -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            if !CFNumberIsFloatType(number) {
                let i = number.int64Value
                return (number.doubleValue >= 0 && i < 0) ? nil : i
            }
            let d = number.doubleValue
            guard d.isFinite, abs(d) < 9.2e18 else { return nil }
            return Int64(d)
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let i = Int64(trimmed) { return i }
            if let d = Double(trimmed), d.isFinite, abs(d) < 9.2e18 {
                return Int64(d)
            }
            return nil
        }
        return nil
    }

    private static func nonNegativeInt(_ value: Any?) -> Int64 {
        guard let v = asInt(value) else { return 0 }
        return max(v, 0)
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

    private static func grokTimestamp(_ value: Any?) -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
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
        return v < 1e12 ? Int64(v * 1_000) : Int64(v)
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
        let cutoff: Date
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
                sourceID: "grok",
                modelID: model,
                rawModelID: resolvedRaw,
                counts: .zero
            )
            row.rawModelID = min(row.rawModelID, resolvedRaw)
            row.counts += counts
            row.eventCount += calls
            daily[dailyKey] = row

            guard hour >= cutoff, hour <= currentHour else { return }
            var hourRow = hourly[hour] ?? HourlyUsage(
                hourStart: hour,
                deviceID: deviceID,
                sourceID: "grok",
                counts: .zero,
                eventCount: 0,
                reasoningKnown: true
            )
            hourRow.counts += counts
            hourRow.eventCount += calls
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
