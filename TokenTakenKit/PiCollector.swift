import Foundation

/// Counts pi usage from its session JSONL (`~/.pi/agent/sessions/<encoded-cwd>/*.jsonl`) instead of
/// going through tokscale, which keys pi assistant usage on `message.responseId`. Short Ollama-style
/// response ids collide between different calls, so that key undercounts (ADR-0003). This collector
/// keys on the entry id plus the immutable event fields, so distinct calls that share a response id
/// are counted twice and a copied entry is counted once.
public struct PiCollector: UsageCollector {
    public let sourceIDs = ["pi"]

    private let root: URL
    private let deviceID: String
    private let timeZone: TimeZone
    /// Defines "the last 48 hours" for the hourly buckets; injectable so tests can pin it.
    private let now: @Sendable () -> Date

    public init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions"),
        deviceID: String,
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.root = root
        self.deviceID = deviceID
        self.timeZone = timeZone
        self.now = now
    }

    public func collect() async throws -> CollectionBatch {
        try autoreleasepool {
            try PiFormatScan(
                root: root, sourceID: "pi", deviceID: deviceID, timeZone: timeZone, now: now()
            ).run()
        }
    }
}

/// Scans pi-format session JSONL. pi and oh-my-pi write the same record layout, so both collectors
/// share this scanner and differ only in their scan root and source id.
///
/// Counted record types (tokscale's set, kept so pi totals stay comparable with the pinned engine):
/// - `message` with `message.role == "assistant"`: the billed reply.
/// - `message` with `message.role == "toolResult"` and a `message.usage`: the call behind a tool.
///   pi normally bills this under `tools/summaries`; a message that names its own model keeps it.
/// - `compaction`: the `/compact` summarization call, usage at the record root.
/// - `branch_summary`: the branch summarization call, usage at the record root.
/// - `usage`: standalone accounting such as cache warming; it names its billed model at the root.
///   A model-less `usage` record inherits the session's current model, like tokscale's legacy row.
///
/// `session`, `title`, `title_change`, `session_info`, `model_change`, `thinking_level_change`,
/// `custom` and other control records are skipped without counting as malformed. A `model_change`
/// record updates the session's current model so a later model-less `usage` record can be attributed.
///
/// Token categories follow `docs/contracts/statistics.md`: `input` already excludes cache tokens, and
/// both pi and oh-my-pi report reasoning inside `output` (their `totalTokens` excludes it), so
/// reasoning is subtracted from output and stored separately.
///
/// Divergences from tokscale's pi lane, all in the direction of losing no usage:
/// - Event identity never uses `message.responseId`; see `record` for the key.
/// - A usage record without a usable timestamp is placed at the file's modification time instead of
///   being dropped, and a reply that names no model falls back to the session's current model, then
///   `unknown`.
/// - A file without a `session` header is still read record by record instead of being discarded.
///
/// Daily totals cover every event; hourly buckets keep only the last 48 hours at UTC hour resolution.
struct PiFormatScan: Sendable {
    /// pi groups model-less tool, compaction, and branch-summary usage in this bucket.
    static let toolsSummariesModel = "tools/summaries"
    /// Only recent usage needs hour resolution; older events roll into the daily totals only.
    static let hourlyWindow: TimeInterval = 48 * 3_600
    /// Bounds the single buffered line; oversized records are discarded while streaming.
    static let maximumLineBytes = 64 << 20
    /// Placeholder epoch timestamps used to land usage in 1970; treated as missing.
    static let minimumTimestamp = Date(timeIntervalSince1970: 1_577_836_800)

    /// Every counted record has a literal `"usage"` key, while model changes and assistant replies
    /// must also be decoded when they only advance model state. Session headers retain their existing
    /// validation. The quoted markers are independent of whitespace around JSON colons; a marker in
    /// content merely causes a minimal decode, and `content` itself is never decoded.
    private static let decodeMarkers = [
        Data(#""usage""#.utf8),
        Data(#""model_change""#.utf8),
        Data(#""assistant""#.utf8),
        Data(#""session""#.utf8),
    ]

    let root: URL
    let sourceID: String
    let deviceID: String
    let timeZone: TimeZone
    let now: Date

    func run() throws -> CollectionBatch {
        let files = try sessionFiles()
        var totals = Totals(sourceID: sourceID, deviceID: deviceID, timeZone: timeZone, now: now)

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        for file in files {
            try autoreleasepool {
                let modificationDate = Self.modificationDate(of: file) ?? now
                var state = FileState()
                try Self.forEachLine(in: file, onLine: { line in
                    autoreleasepool {
                        totals.scan(
                            line: line,
                            state: &state,
                            fallbackDate: modificationDate,
                            fractional: fractional,
                            plain: plain
                        )
                    }
                }, onOverlongLine: {
                    totals.skippedRecords += 1
                })
            }
        }

        return totals.batch()
    }

    private func sessionFiles() throws -> [URL] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw CollectorError.sourceUnavailable
        }
        guard isDirectory.boolValue else {
            throw CollectorError.invalidOutput("\(sourceID) session root is not a directory")
        }
        var enumerationError: Error?
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CollectorError.open("Could not enumerate \(sourceID) sessions")
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            autoreleasepool {
                guard url.pathExtension == "jsonl" else { return }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return }
                files.append(url)
            }
        }
        if let enumerationError {
            throw enumerationError
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private struct FileState {
        var isFirstLine = true
        /// The session's currently selected model, used only to attribute a model-less `usage` record.
        var currentModel: String?
    }

    private struct DailyKey: Hashable {
        let day: String
        let modelID: String
    }

    private struct DailyTotals {
        var rawModelID: String
        var counts = TokenCounts.zero
        var eventCount: Int64 = 0
    }

    private struct HourlyTotals {
        var counts = TokenCounts.zero
        var eventCount: Int64 = 0
        var reasoningKnown = true
    }

    private struct DedupKey: Hashable {
        var a: UInt64 = 0xcbf2_9ce4_8422_2325
        var b: UInt64 = 0x8422_2325_cbf2_9ce4

        mutating func combine(_ string: String) {
            for byte in string.utf8 {
                a = (a ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
                b = (b &* 0x0000_0100_0000_01b3) ^ UInt64(byte)
            }
            a = (a ^ 0x7c) &* 0x0000_0100_0000_01b3
            b = (b &* 0x0000_0100_0000_01b3) ^ 0x7c
        }

        mutating func combine(_ value: Int64) {
            var bits = UInt64(bitPattern: value)
            for _ in 0..<8 {
                let byte = UInt8(truncatingIfNeeded: bits)
                a = (a ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
                b = (b &* 0x0000_0100_0000_01b3) ^ UInt64(byte)
                bits >>= 8
            }
            a = (a ^ 0x7c) &* 0x0000_0100_0000_01b3
            b = (b &* 0x0000_0100_0000_01b3) ^ 0x7c
        }
    }

    private struct ScanRecord: Decodable {
        let type: String?
        let id: String?
        let timestamp: String?
        let model: String?
        let modelId: String?
        let responseId: String?
        let message: ScanMessage?
        let usage: ScanUsage?

        enum CodingKeys: String, CodingKey {
            case type, id, timestamp, model, modelId, responseId, message, usage
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            type = try values.decodeIfPresent(String.self, forKey: .type)
            id = try? values.decodeIfPresent(String.self, forKey: .id)
            timestamp = try? values.decodeIfPresent(String.self, forKey: .timestamp)
            model = try? values.decodeIfPresent(String.self, forKey: .model)
            modelId = try? values.decodeIfPresent(String.self, forKey: .modelId)
            responseId = try? values.decodeIfPresent(String.self, forKey: .responseId)
            message = try? values.decodeIfPresent(ScanMessage.self, forKey: .message)
            usage = try? values.decodeIfPresent(ScanUsage.self, forKey: .usage)
        }
    }

    private struct ScanMessage: Decodable {
        let role: String?
        let model: String?
        let responseId: String?
        let timestamp: JSONInteger?
        let usage: ScanUsage?

        enum CodingKeys: String, CodingKey {
            case role, model, responseId, timestamp, usage
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            role = try? values.decodeIfPresent(String.self, forKey: .role)
            model = try? values.decodeIfPresent(String.self, forKey: .model)
            responseId = try? values.decodeIfPresent(String.self, forKey: .responseId)
            timestamp = try? values.decodeIfPresent(JSONInteger.self, forKey: .timestamp)
            usage = try? values.decodeIfPresent(ScanUsage.self, forKey: .usage)
        }
    }

    private struct ScanUsage: Decodable {
        let input: JSONInteger?
        let cacheRead: JSONInteger?
        let cacheWrite: JSONInteger?
        let output: JSONInteger?
        let reasoningTokens: JSONInteger?
        let reasoning: JSONInteger?

        enum CodingKeys: String, CodingKey {
            case input, cacheRead, cacheWrite, output, reasoningTokens, reasoning
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            input = try? values.decodeIfPresent(JSONInteger.self, forKey: .input)
            cacheRead = try? values.decodeIfPresent(JSONInteger.self, forKey: .cacheRead)
            cacheWrite = try? values.decodeIfPresent(JSONInteger.self, forKey: .cacheWrite)
            output = try? values.decodeIfPresent(JSONInteger.self, forKey: .output)
            reasoningTokens = try? values.decodeIfPresent(JSONInteger.self, forKey: .reasoningTokens)
            reasoning = try? values.decodeIfPresent(JSONInteger.self, forKey: .reasoning)
        }
    }

    private struct JSONInteger: Decodable {
        let value: Int64?

        init(from decoder: Decoder) throws {
            let values = try decoder.singleValueContainer()
            guard let number = try? values.decode(Double.self), number.isFinite else {
                value = nil
                return
            }
            let rounded = number.rounded(.towardZero)
            guard rounded >= Double(Int64.min), rounded < 0x1p63 else {
                value = nil
                return
            }
            value = Int64(rounded)
        }
    }

    /// Projects large records onto the fields in ScanRecord, leaving bulky content out of JSONDecoder's
    /// input. The original line remains available for the id-less dedup fingerprint.
    private struct LargeLineProjector {
        private enum Mode {
            case record, message, usage
        }

        private enum Action {
            case string, number, object(Mode)
        }

        private enum Failure: Error {
            case invalid
        }

        private struct StringToken {
            let range: Range<Data.Index>
            let hasEscapes: Bool
        }

        let bytes: Data
        var index: Data.Index

        init(bytes: Data) {
            self.bytes = bytes
            index = bytes.startIndex
        }

        mutating func project() -> Data? {
            do {
                var output = Data()
                output.reserveCapacity(min(bytes.count, 64 << 10))
                skipWhitespace()
                guard peek == 0x7B else { return nil }
                try projectObject(mode: .record, into: &output)
                skipWhitespace()
                guard index == bytes.endIndex else { return nil }
                return output
            } catch {
                return nil
            }
        }

        private var peek: UInt8? {
            index < bytes.endIndex ? bytes[index] : nil
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard peek == byte else { return false }
            index += 1
            return true
        }

        private mutating func require(_ byte: UInt8) throws {
            guard consume(byte) else { throw Failure.invalid }
        }

        private mutating func skipWhitespace() {
            while let byte = peek, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                index += 1
            }
        }

        private mutating func projectObject(mode: Mode, into output: inout Data) throws {
            try require(0x7B)
            output.append(0x7B)
            skipWhitespace()
            if consume(0x7D) {
                output.append(0x7D)
                return
            }

            var emitted = false
            while true {
                let key = try parseString()
                // An escaped spelling could name a projected field; use the original line instead.
                guard !key.hasEscapes else { throw Failure.invalid }
                skipWhitespace()
                try require(0x3A)
                skipWhitespace()

                if let action = action(for: key, mode: mode) {
                    if emitted { output.append(0x2C) }
                    output.append(contentsOf: bytes[key.range])
                    output.append(0x3A)
                    switch action {
                    case .string:
                        if peek == 0x22 {
                            let value = try parseString()
                            output.append(contentsOf: bytes[value.range])
                        } else {
                            try skipValue()
                            output.append(contentsOf: "null".utf8)
                        }
                    case .number:
                        if let byte = peek, byte == 0x2D || (0x30...0x39).contains(byte) {
                            let value = try parseNumber()
                            output.append(contentsOf: bytes[value])
                        } else {
                            try skipValue()
                            output.append(contentsOf: "null".utf8)
                        }
                    case .object(let nestedMode):
                        if peek == 0x7B {
                            try projectObject(mode: nestedMode, into: &output)
                        } else {
                            try skipValue()
                            output.append(contentsOf: "null".utf8)
                        }
                    }
                    emitted = true
                } else {
                    try skipValue()
                }

                skipWhitespace()
                if consume(0x2C) {
                    skipWhitespace()
                    continue
                }
                try require(0x7D)
                output.append(0x7D)
                return
            }
        }

        private func action(for key: StringToken, mode: Mode) -> Action? {
            switch mode {
            case .record:
                if keyEquals("message", key) { return .object(.message) }
                if keyEquals("usage", key) { return .object(.usage) }
                if keyEquals("type", key) || keyEquals("id", key) || keyEquals("timestamp", key)
                    || keyEquals("model", key) || keyEquals("modelId", key) || keyEquals("responseId", key) {
                    return .string
                }
            case .message:
                if keyEquals("usage", key) { return .object(.usage) }
                if keyEquals("timestamp", key) { return .number }
                if keyEquals("role", key) || keyEquals("model", key) || keyEquals("responseId", key) {
                    return .string
                }
            case .usage:
                if keyEquals("input", key) || keyEquals("cacheRead", key) || keyEquals("cacheWrite", key)
                    || keyEquals("output", key) || keyEquals("reasoningTokens", key) || keyEquals("reasoning", key) {
                    return .number
                }
            }
            return nil
        }

        private func keyEquals(_ literal: String, _ key: StringToken) -> Bool {
            guard key.range.count == literal.utf8.count + 2 else { return false }
            var position = key.range.lowerBound + 1
            for expected in literal.utf8 {
                guard bytes[position] == expected else { return false }
                position += 1
            }
            return true
        }

        private mutating func skipValue(depth: Int = 0) throws {
            guard depth < 512, let byte = peek else { throw Failure.invalid }
            switch byte {
            case 0x7B:
                try skipObject(depth: depth)
            case 0x5B:
                try skipArray(depth: depth)
            case 0x22:
                _ = try parseString()
            case 0x74:
                try consumeLiteral("true")
            case 0x66:
                try consumeLiteral("false")
            case 0x6E:
                try consumeLiteral("null")
            case 0x2D, 0x30...0x39:
                _ = try parseNumber()
            default:
                throw Failure.invalid
            }
        }

        private mutating func skipObject(depth: Int) throws {
            try require(0x7B)
            skipWhitespace()
            if consume(0x7D) { return }
            while true {
                _ = try parseString()
                skipWhitespace()
                try require(0x3A)
                skipWhitespace()
                try skipValue(depth: depth + 1)
                skipWhitespace()
                if consume(0x2C) {
                    skipWhitespace()
                    continue
                }
                try require(0x7D)
                return
            }
        }

        private mutating func skipArray(depth: Int) throws {
            try require(0x5B)
            skipWhitespace()
            if consume(0x5D) { return }
            while true {
                try skipValue(depth: depth + 1)
                skipWhitespace()
                if consume(0x2C) {
                    skipWhitespace()
                    continue
                }
                try require(0x5D)
                return
            }
        }

        private mutating func consumeLiteral(_ literal: String) throws {
            for expected in literal.utf8 {
                guard peek == expected else { throw Failure.invalid }
                index += 1
            }
        }

        private mutating func parseNumber() throws -> Range<Data.Index> {
            let start = index
            _ = consume(0x2D)
            guard let byte = peek else { throw Failure.invalid }
            if byte == 0x30 {
                index += 1
            } else if (0x31...0x39).contains(byte) {
                index += 1
                while let next = peek, (0x30...0x39).contains(next) { index += 1 }
            } else {
                throw Failure.invalid
            }
            if consume(0x2E) {
                guard let next = peek, (0x30...0x39).contains(next) else { throw Failure.invalid }
                index += 1
                while let next = peek, (0x30...0x39).contains(next) { index += 1 }
            }
            if let next = peek, next == 0x65 || next == 0x45 {
                index += 1
                if let sign = peek, sign == 0x2B || sign == 0x2D { index += 1 }
                guard let digit = peek, (0x30...0x39).contains(digit) else { throw Failure.invalid }
                index += 1
                while let digit = peek, (0x30...0x39).contains(digit) { index += 1 }
            }
            return start..<index
        }

        private mutating func parseString() throws -> StringToken {
            let start = index
            try require(0x22)
            var hasEscapes = false
            while let byte = peek {
                switch byte {
                case 0x22:
                    index += 1
                    return StringToken(range: start..<index, hasEscapes: hasEscapes)
                case 0x5C:
                    hasEscapes = true
                    index += 1
                    guard let escaped = peek else { throw Failure.invalid }
                    switch escaped {
                    case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                        index += 1
                    case 0x75:
                        index += 1
                        let first = try readHexQuad()
                        if (0xD800...0xDBFF).contains(first) {
                            try require(0x5C)
                            try require(0x75)
                            let second = try readHexQuad()
                            guard (0xDC00...0xDFFF).contains(second) else { throw Failure.invalid }
                        } else {
                            guard !(0xDC00...0xDFFF).contains(first) else { throw Failure.invalid }
                        }
                    default:
                        throw Failure.invalid
                    }
                case 0x00...0x1F:
                    throw Failure.invalid
                case 0x20...0x7F:
                    index += 1
                default:
                    try consumeUTF8()
                }
            }
            throw Failure.invalid
        }

        private mutating func readHexQuad() throws -> UInt16 {
            var value: UInt16 = 0
            for _ in 0..<4 {
                guard let byte = peek, let digit = hexValue(byte) else { throw Failure.invalid }
                value = (value << 4) | UInt16(digit)
                index += 1
            }
            return value
        }

        private func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: return byte - 0x30
            case 0x41...0x46: return byte - 0x41 + 10
            case 0x61...0x66: return byte - 0x61 + 10
            default: return nil
            }
        }

        private mutating func consumeUTF8() throws {
            guard let first = peek else { throw Failure.invalid }
            let length: Int
            let secondRange: ClosedRange<UInt8>
            switch first {
            case 0xC2...0xDF: length = 2; secondRange = 0x80...0xBF
            case 0xE0: length = 3; secondRange = 0xA0...0xBF
            case 0xE1...0xEC: length = 3; secondRange = 0x80...0xBF
            case 0xED: length = 3; secondRange = 0x80...0x9F
            case 0xEE...0xEF: length = 3; secondRange = 0x80...0xBF
            case 0xF0: length = 4; secondRange = 0x90...0xBF
            case 0xF1...0xF3: length = 4; secondRange = 0x80...0xBF
            case 0xF4: length = 4; secondRange = 0x80...0x8F
            default: throw Failure.invalid
            }
            guard index + length <= bytes.endIndex, secondRange.contains(bytes[index + 1]) else {
                throw Failure.invalid
            }
            for offset in 2..<length {
                guard (0x80...0xBF).contains(bytes[index + offset]) else { throw Failure.invalid }
            }
            index += length
        }
    }

    private struct Totals {
        let sourceID: String
        let deviceID: String
        let timeZone: TimeZone
        let now: Date

        var daily: [DailyKey: DailyTotals] = [:]
        var hourly: [Date: HourlyTotals] = [:]
        var skippedRecords = 0
        var seen: Set<DedupKey> = []

        mutating func scan(
            line rawLine: Data,
            state: inout FileState,
            fallbackDate: Date,
            fractional: ISO8601DateFormatter,
            plain: ISO8601DateFormatter
        ) {
            var line = rawLine
            if state.isFirstLine {
                state.isFirstLine = false
                // A byte-order mark decodes cleanly but breaks the first record's parse.
                if line.starts(with: [0xEF, 0xBB, 0xBF]) { line = line.dropFirst(3) }
            }
            let trimmed = line.drop { $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }
            guard !trimmed.isEmpty else { return }
            guard trimmed.first == 0x7B else {
                skippedRecords += 1
                return
            }
            guard PiFormatScan.decodeMarkers.contains(where: { trimmed.range(of: $0) != nil }) else { return }

            let decodeLine: Data
            if trimmed.count > (64 << 10) {
                var projector = LargeLineProjector(bytes: trimmed)
                decodeLine = projector.project() ?? trimmed
            } else {
                decodeLine = trimmed
            }
            guard let object = try? JSONDecoder().decode(ScanRecord.self, from: decodeLine),
                  let type = object.type else {
                skippedRecords += 1
                return
            }

            switch type {
            case "model_change":
                if let model = Self.text(object.modelId) { state.currentModel = model }
            case "message":
                guard let message = object.message else { return }
                let role = Self.text(message.role)
                let loggedModel = Self.text(message.model)
                if role == "assistant" {
                    // Only a reply (or a `model_change`) advances the session's selected model.
                    if let loggedModel { state.currentModel = loggedModel }
                }
                guard let usage = message.usage else { return }
                let model: String?
                switch role {
                case "assistant": model = loggedModel ?? state.currentModel
                case "toolResult": model = loggedModel ?? PiFormatScan.toolsSummariesModel
                default: return
                }
                record(
                    object: object, type: type, model: model, usage: usage, messageTimestamp: message.timestamp,
                    line: rawLine, fallbackDate: fallbackDate, fractional: fractional, plain: plain
                )
            case "compaction", "branch_summary":
                guard let usage = object.usage else { return }
                record(
                    object: object, type: type, model: Self.text(object.model) ?? PiFormatScan.toolsSummariesModel,
                    usage: usage, messageTimestamp: nil, line: rawLine, fallbackDate: fallbackDate,
                    fractional: fractional, plain: plain
                )
            case "usage":
                guard let usage = object.usage else { return }
                record(
                    object: object, type: type, model: Self.text(object.model) ?? state.currentModel,
                    usage: usage, messageTimestamp: nil, line: rawLine, fallbackDate: fallbackDate,
                    fractional: fractional, plain: plain
                )
            default:
                // Every other record type carries no billable usage.
                return
            }
        }

        private mutating func record(
            object: ScanRecord,
            type: String,
            model: String?,
            usage: ScanUsage,
            messageTimestamp: JSONInteger?,
            line: Data,
            fallbackDate: Date,
            fractional: ISO8601DateFormatter,
            plain: ISO8601DateFormatter
        ) {
            guard let (counts, reasoningKnown) = Self.tokenCounts(from: usage) else {
                skippedRecords += 1
                return
            }
            guard counts.total > 0 else { return }
            let sourceDate = Self.sourceEventDate(
                messageTimestamp: messageTimestamp,
                recorded: object.timestamp,
                fractional: fractional,
                plain: plain
            )
            let date = sourceDate ?? fallbackDate

            let rawModelID = model ?? "unknown"
            let modelID = rawModelID.lowercased()

            // Identity is session-independent and never the response id alone: fork/branch copies repeat
            // the entry id and the usage in a new file and must collapse, while two calls that share
            // a short response id differ in entry id, timestamp, or counts and must both count.
            let identifier = Self.text(object.id).map { "\(type):\($0)" }
                ?? "\(type):line:\(Self.fingerprint(line))"
            let timestampIdentity = sourceDate.map {
                String(Int64(($0.timeIntervalSince1970 * 1_000).rounded()))
            } ?? "missing"
            var key = DedupKey()
            key.combine(identifier)
            key.combine(timestampIdentity)
            key.combine(rawModelID)
            key.combine(counts.input)
            key.combine(counts.cacheRead)
            key.combine(counts.cacheWrite)
            key.combine(counts.output)
            key.combine(counts.reasoning)
            if let responseID = Self.text(object.message?.responseId) ?? Self.text(object.responseId) {
                key.combine(responseID)
            }
            guard seen.insert(key).inserted else { return }

            let day = UsageDay.string(from: date, in: timeZone)
            let dailyKey = DailyKey(day: day, modelID: modelID)
            var dailyTotals = daily[dailyKey] ?? DailyTotals(rawModelID: rawModelID)
            dailyTotals.counts += counts
            dailyTotals.eventCount += 1
            daily[dailyKey] = dailyTotals

            let hourStart = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3_600).rounded(.down) * 3_600)
            guard hourStart >= now.addingTimeInterval(-PiFormatScan.hourlyWindow), hourStart <= now else { return }
            var hourlyTotals = hourly[hourStart] ?? HourlyTotals()
            hourlyTotals.counts += counts
            hourlyTotals.eventCount += 1
            // A bucket is reasoning-known only when every event in it reported a valid reasoning split.
            hourlyTotals.reasoningKnown = hourlyTotals.reasoningKnown && reasoningKnown
            hourly[hourStart] = hourlyTotals
        }

        func batch() -> CollectionBatch {
            let dailyRecords = daily.map { key, totals in
                UsageRecord(
                    day: key.day,
                    timeZoneID: timeZone.identifier,
                    deviceID: deviceID,
                    sourceID: sourceID,
                    modelID: key.modelID,
                    rawModelID: totals.rawModelID,
                    counts: totals.counts,
                    eventCount: totals.eventCount
                )
            }.sorted {
                if $0.day != $1.day { return $0.day < $1.day }
                return $0.modelID < $1.modelID
            }
            let hourlyRecords = hourly.map { start, totals in
                HourlyUsage(
                    hourStart: start,
                    deviceID: deviceID,
                    sourceID: sourceID,
                    counts: totals.counts,
                    eventCount: totals.eventCount,
                    reasoningKnown: totals.reasoningKnown
                )
            }.sorted { $0.hourStart < $1.hourStart }
            return CollectionBatch(daily: dailyRecords, hourly: hourlyRecords, skippedRecords: skippedRecords)
        }

        /// Splits reasoning out of output. pi and oh-my-pi both report reasoning as a breakdown of
        /// `output` and print a `totalTokens` that excludes it, so adding it again would double count.
        static func tokenCounts(from usage: ScanUsage) -> (TokenCounts, Bool)? {
            let input = usage.input?.value ?? 0
            let cacheRead = usage.cacheRead?.value ?? 0
            let cacheWrite = usage.cacheWrite?.value ?? 0
            let rawOutput = usage.output?.value ?? 0
            let reportedReasoning = usage.reasoningTokens?.value ?? usage.reasoning?.value
            guard input >= 0, cacheRead >= 0, cacheWrite >= 0, rawOutput >= 0, (reportedReasoning ?? 0) >= 0 else {
                return nil
            }
            let reasoning: Int64
            let reasoningKnown: Bool
            if let reportedReasoning, reportedReasoning <= rawOutput {
                reasoning = reportedReasoning
                reasoningKnown = true
            } else {
                reasoning = 0
                reasoningKnown = false
            }
            let counts = TokenCounts(
                input: input,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                output: rawOutput - reasoning,
                reasoning: reasoning
            )
            return (counts, reasoningKnown)
        }

        static func sourceEventDate(
            messageTimestamp: JSONInteger?,
            recorded: String?,
            fractional: ISO8601DateFormatter,
            plain: ISO8601DateFormatter
        ) -> Date? {
            // An assistant message's own timestamp is the request start; the entry timestamp is
            // when the record was persisted, so the message timestamp wins when it is usable.
            if let milliseconds = messageTimestamp?.value, milliseconds > 0 {
                let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
                if date >= PiFormatScan.minimumTimestamp { return date }
            }
            if let recorded,
               let date = fractional.date(from: recorded) ?? plain.date(from: recorded),
               date >= PiFormatScan.minimumTimestamp {
                return date
            }
            return nil
        }

        private static func text(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // Keep session state and returned model names independent of the decoder's line storage.
            return String(decoding: trimmed.utf8, as: UTF8.self)
        }

        /// Stable content fingerprint for a record that carries no entry id.
        private static func fingerprint(_ line: Data) -> String {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in line {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01b3
            }
            return String(hash, radix: 16)
        }
    }

    /// Splits a JSONL file into lines without loading it whole, reusing one line buffer.
    private static func forEachLine(
        in url: URL,
        onLine: (Data) -> Void,
        onOverlongLine: () -> Void
    ) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }

        let newline = UInt8(ascii: "\n")
        var pending = Data()
        var discardingOverlongLine = false

        while true {
            let chunk = try autoreleasepool { try file.read(upToCount: 1 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            var rest = chunk[...]
            while let index = rest.firstIndex(of: newline) {
                if !discardingOverlongLine {
                    let segment = rest[rest.startIndex..<index]
                    if pending.count + segment.count > maximumLineBytes {
                        onOverlongLine()
                    } else {
                        pending.append(contentsOf: segment)
                        onLine(pending)
                    }
                }
                discardingOverlongLine = false
                pending.removeAll(keepingCapacity: pending.count <= (64 << 10))
                rest = rest[rest.index(after: index)...]
            }
            guard !discardingOverlongLine else { continue }
            if pending.count + rest.count > maximumLineBytes {
                pending.removeAll(keepingCapacity: false)
                discardingOverlongLine = true
                onOverlongLine()
            } else {
                pending.append(contentsOf: rest)
            }
        }
        if !pending.isEmpty, !discardingOverlongLine {
            onLine(pending)
        }
    }
}
