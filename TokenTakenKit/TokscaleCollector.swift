import Foundation
import os

public struct TokscaleCollector: UsageCollector {
    public static let defaultClients = [
        "claude", "codex", "grok", "kimi", "opencode", "gemini", "droid",
        "dsh", "fx",
    ]

    /// Engine client id to Token Taken source id. Clients sharing a source are always collected in one engine run:
    /// tokscale deduplicates the Antigravity family by response id only across clients requested together.
    /// Devin is collected natively (ADR-0009), so it is no longer an engine client.
    private static let sourceMap = [
        "claude": "claude",
        "codex": "codex",
        "grok": "grok",
        "kimi": "kimi",
        "opencode": "opencode",
        "gemini": "gemini",
        "droid": "factory",
        "dsh": "dsh",
        "fx": "fx",
    ]

    /// Source ids the default clients produce, in client order.
    public static var defaultSourceIDs: [String] {
        var seen = Set<String>()
        return defaultClients.compactMap { sourceMap[$0] }.filter { seen.insert($0).inserted }
    }

    private let executableURL: URL
    private let configDirectory: URL
    private let clients: [String]
    private let deviceID: String
    private let timeoutSeconds: TimeInterval
    private let isClientAvailable: @Sendable (String) -> Bool
    private let stateFile: CollectorStateFile<State>?
    private let fingerprint: @Sendable (String) -> ClientFingerprint

    /// Bump when the per-client fingerprint or output mapping changes.
    static let stateFormatVersion = 3
    /// Must match engine/engine.lock.json; a new engine forces a full collection.
    static let engineVersion = "4.21.0"
    private static let logger = Logger(subsystem: "io.github.elijah7x.TokenTaken", category: "collection")

    struct ClientFingerprint: Codable, Hashable, Sendable {
        var fileCount: Int
        var totalSize: UInt64
        var latestModification: Double
        /// Order-independent hash of every file's path, size and modification time, so a same-size edit
        /// to any single file changes the fingerprint even when it is not the newest file.
        var filesHash: UInt64 = 0
    }

    struct State: Codable, Sendable {
        var stamp: CollectionStamp
        var clients: [String: ClientFingerprint]
    }

    public init(
        executableURL: URL, configDirectory: URL, clients: [String], deviceID: String, stateDirectory: URL? = nil
    ) {
        self.init(
            executableURL: executableURL,
            configDirectory: configDirectory,
            clients: clients,
            deviceID: deviceID,
            timeoutSeconds: 300,
            isClientAvailable: { Self.sourceAvailable(client: $0) },
            stateDirectory: stateDirectory
        )
    }

    init(
        executableURL: URL,
        configDirectory: URL,
        clients: [String],
        deviceID: String,
        timeoutSeconds: TimeInterval = 300,
        isClientAvailable: @escaping @Sendable (String) -> Bool = { Self.sourceAvailable(client: $0) },
        stateDirectory: URL? = nil,
        fingerprint: @escaping @Sendable (String) -> ClientFingerprint = { Self.fingerprint(client: $0) }
    ) {
        self.executableURL = executableURL
        self.configDirectory = configDirectory
        self.clients = clients
        self.deviceID = deviceID
        self.timeoutSeconds = timeoutSeconds
        self.isClientAvailable = isClientAvailable
        self.stateFile = stateDirectory.map { CollectorStateFile<State>(directory: $0, name: "tokscale") }
        self.fingerprint = fingerprint
    }

    public var sourceIDs: [String] {
        var seen = Set<String>()
        return clients.compactMap { Self.sourceMap[$0] }.filter { seen.insert($0).inserted }
    }

    public static func locateExecutable(override: URL?) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tokscale"),
        ]
        let architectures = ["arm64"]
        for root in [
            home.appendingPathComponent(".npm-global/lib/node_modules"),
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules"),
            URL(fileURLWithPath: "/usr/local/lib/node_modules"),
        ] {
            for architecture in architectures {
                candidates.append(root.appendingPathComponent(
                    "tokscale/node_modules/@tokscale/cli-darwin-\(architecture)/bin/tokscale"
                ))
            }
        }
        // An explicit override is authoritative: never silently run a different engine.
        if let override {
            return FileManager.default.isExecutableFile(atPath: override.path) ? override : nil
        }
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    public func collect() async throws -> CollectionBatch {
        let zone = TimeZone.current
        let now = Date.now
        let mappedClients = clients.filter { Self.sourceMap[$0] != nil }
        let availability = mappedClients.map { ($0, isClientAvailable($0)) }
        let availableClients = availability.filter { $0.1 }.map { $0.0 }
        let availableSourceIDs = Set(availableClients.compactMap { Self.sourceMap[$0] })
        // A source is unavailable only when none of its clients is installed.
        let unavailableSourceIDs = Set(mappedClients.compactMap { Self.sourceMap[$0] }).subtracting(availableSourceIDs)
        guard !availableClients.isEmpty else {
            throw CollectorError.sourceUnavailable
        }
        let started = ContinuousClock.now
        // Fingerprints are taken before tokscale starts, so logs written during collection trigger a re-run next time.
        let stamp = CollectionStamp(formatVersion: Self.stateFormatVersion, engineVersion: Self.engineVersion, timeZone: zone)
        let fingerprints = stateFile == nil ? [:] : Dictionary(uniqueKeysWithValues: availableClients.map { ($0, fingerprint($0)) })
        let previous = stateFile?.load().flatMap { $0.stamp == stamp ? $0.clients : nil } ?? [:]
        // A change in any client re-collects every client of its source, so engine-side dedup stays intact.
        let changedSourceIDs = Set(availableClients.filter { previous[$0] == nil || previous[$0] != fingerprints[$0] }
            .compactMap { Self.sourceMap[$0] })
        let changedClients = availableClients.filter { Self.sourceMap[$0].map(changedSourceIDs.contains) ?? false }
        let unchangedSourceIDs = availableSourceIDs.subtracting(changedSourceIDs)
        let stateFile = stateFile
        func commit(_ succeeded: [String]) -> [@Sendable () throws -> Void] {
            guard let stateFile else { return [] }
            var clients = previous.filter { availableClients.contains($0.key) }
            for client in succeeded { clients[client] = fingerprints[client] }
            let state = State(stamp: stamp, clients: clients)
            return [{ try stateFile.save(state) }]
        }
        guard !changedClients.isEmpty else {
            Self.logger.info("source=tokscale changed=none unchanged=\(unchangedSourceIDs.count, privacy: .public) duration_ms=\(Self.milliseconds(since: started), privacy: .public)")
            return CollectionBatch(
                unavailableSourceIDs: unavailableSourceIDs, unchangedSourceIDs: unchangedSourceIDs, stateCommits: commit([])
            )
        }
        let batch = try await collect(clients: changedClients, zone: zone, now: now)
        let succeeded = changedClients.filter { client in
            guard let sourceID = Self.sourceMap[client] else { return false }
            return batch.failedSourceIDs[sourceID] == nil
                && (batch.daily.contains { $0.sourceID == sourceID } || batch.hourly.contains { $0.sourceID == sourceID })
        }
        Self.logger.info("source=tokscale changed=\(changedClients.joined(separator: ","), privacy: .public) unchanged=\(unchangedSourceIDs.count, privacy: .public) duration_ms=\(Self.milliseconds(since: started), privacy: .public)")
        return CollectionBatch(
            daily: batch.daily,
            hourly: batch.hourly,
            unavailableSourceIDs: unavailableSourceIDs,
            failedSourceIDs: batch.failedSourceIDs,
            unchangedSourceIDs: unchangedSourceIDs,
            stateCommits: commit(succeeded)
        )
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let elapsed = ContinuousClock.now - start
        return elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000
    }

    private func collect(clients availableClients: [String], zone: TimeZone, now: Date) async throws -> CollectionBatch {
        try ensureSettings(timeZone: zone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let since = UsageDay.string(from: calendar.date(byAdding: .day, value: -2, to: now)!, in: zone)
        async let graphData = run(arguments: ["graph", "-c", availableClients.joined(separator: ",")], timeZone: zone, graph: true)
        // One hourly run per source, with all of its clients, so the engine deduplicates within the source.
        var sourceGroups: [[String]] = []
        var groupIndex: [String: Int] = [:]
        for client in availableClients {
            guard let sourceID = Self.sourceMap[client] else { continue }
            if let index = groupIndex[sourceID] {
                sourceGroups[index].append(client)
            } else {
                groupIndex[sourceID] = sourceGroups.count
                sourceGroups.append([client])
            }
        }
        let maxConcurrent = 3
        let hourly = await withTaskGroup(of: (clients: [String], rows: [HourlyUsage], errorMessage: String?).self) { group in
            var iterator = sourceGroups.makeIterator()
            for _ in 0..<min(maxConcurrent, sourceGroups.count) {
                if let clients = iterator.next() {
                    group.addTask { await hourlyOutcome(clients: clients, since: since, timeZone: zone, now: now) }
                }
            }
            var rows: [HourlyUsage] = []
            var failedSourceIDs: [String: String] = [:]
            while let result = await group.next() {
                rows += result.rows
                if let message = result.errorMessage, let sourceID = result.clients.first.flatMap({ Self.sourceMap[$0] }) {
                    failedSourceIDs[sourceID] = message
                }
                if let clients = iterator.next() {
                    group.addTask { await hourlyOutcome(clients: clients, since: since, timeZone: zone, now: now) }
                }
            }
            return (rows: rows, failedSourceIDs: failedSourceIDs)
        }
        let daily = try await Self.parse(data: graphData, clients: availableClients, deviceID: deviceID, timeZone: zone)
        return CollectionBatch(daily: daily, hourly: hourly.rows, failedSourceIDs: hourly.failedSourceIDs)
    }

    /// `clients` all map to one source.
    private func hourlyOutcome(
        clients: [String],
        since: String,
        timeZone: TimeZone,
        now: Date
    ) async -> (clients: [String], rows: [HourlyUsage], errorMessage: String?) {
        do {
            let data = try await run(arguments: ["hourly", "--json", "-c", clients.joined(separator: ","), "--since", since],
                                     timeZone: timeZone)
            let rows = try Self.parseHourly(data: data, client: clients[0], deviceID: deviceID, timeZone: timeZone, now: now)
            return (clients, rows, nil)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return (clients, [], CollectionRunner.sanitizeErrorMessage(message))
        }
    }

    static func parse(data: Data, clients: [String], deviceID: String, timeZone: TimeZone = .current) throws -> [UsageRecord] {
        let graph: Graph
        do {
            graph = try JSONDecoder().decode(Graph.self, from: data)
        } catch {
            throw CollectorError.invalidOutput("tokscale output was invalid")
        }
        let requested = Set(clients)
        var totals: [Key: TokenCounts] = [:]
        var events: [Key: Int64] = [:]
        var rawModels: [Key: String] = [:]
        for contribution in graph.contributions {
            guard UsageDay.date(from: contribution.date, in: timeZone) != nil else {
                throw CollectorError.invalidOutput("tokscale output was invalid")
            }
            for usage in contribution.clients {
                guard requested.contains(usage.client), let sourceID = sourceMap[usage.client] else { continue }
                let model = usage.modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !model.isEmpty, (usage.messages ?? 0) >= 0 else { throw CollectorError.invalidOutput("tokscale output was invalid") }
                let key = Key(day: contribution.date, sourceID: sourceID, modelID: model)
                rawModels[key] = min(rawModels[key] ?? usage.modelId, usage.modelId)
                guard Self.valid(usage.tokens) else { throw CollectorError.invalidOutput("tokscale output was invalid") }
                totals[key, default: .zero] += usage.tokens
                events[key, default: 0] += usage.messages ?? 0
            }
        }
        return totals.map { key, counts in
            UsageRecord(day: key.day, timeZoneID: timeZone.identifier, deviceID: deviceID, sourceID: key.sourceID,
                        modelID: key.modelID, rawModelID: rawModels[key], counts: counts, eventCount: events[key, default: 0])
        }.sorted {
            if $0.day != $1.day { return $0.day < $1.day }
            if $0.sourceID != $1.sourceID { return $0.sourceID < $1.sourceID }
            return $0.modelID < $1.modelID
        }
    }

    static func parseHourly(data: Data, client: String, deviceID: String, timeZone: TimeZone, now: Date = .now) throws -> [HourlyUsage] {
        guard let sourceID = sourceMap[client] else { throw CollectorError.invalidOutput("tokscale output was invalid") }
        let report: HourlyReport
        do {
            report = try JSONDecoder().decode(HourlyReport.self, from: data)
        } catch {
            throw CollectorError.invalidOutput("tokscale output was invalid")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.isLenient = false
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let currentHour = calendar.dateInterval(of: .hour, for: now)!.start
        let cutoff = currentHour.addingTimeInterval(-47 * 3_600)
        var totals: [Date: HourlyUsage] = [:]
        for entry in report.entries {
            guard let hour = formatter.date(from: entry.hour), formatter.string(from: hour) == entry.hour,
                  entry.hour.hasSuffix(":00"), entry.messageCount >= 0 else {
                throw CollectorError.invalidOutput("tokscale output was invalid")
            }
            let counts = TokenCounts(input: entry.input, cacheRead: entry.cacheRead, cacheWrite: entry.cacheWrite, output: entry.output)
            guard valid(counts) else { throw CollectorError.invalidOutput("tokscale output was invalid") }
            guard hour >= cutoff, hour <= currentHour else { continue }
            var row = totals[hour] ?? HourlyUsage(hourStart: hour, deviceID: deviceID, sourceID: sourceID, counts: .zero, eventCount: 0, reasoningKnown: false)
            row.counts += counts
            row.eventCount += entry.messageCount
            totals[hour] = row
        }
        return totals.values.sorted { $0.hourStart < $1.hourStart }
    }

    private static func valid(_ counts: TokenCounts) -> Bool {
        TokenCategory.allCases.allSatisfy { counts[$0] >= 0 } && counts.uncategorized >= 0
    }

    // Paths and environment overrides follow tokscale-core/src/clients.rs.
    private static func sourceAvailable(client: String) -> Bool {
        roots(client: client).contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Metadata-only walk of everything tokscale reads for a client; file contents are never opened.
    static func fingerprint(client: String) -> ClientFingerprint {
        var result = ClientFingerprint(fileCount: 0, totalSize: 0, latestModification: 0)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        func add(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return }
            result.fileCount += 1
            result.totalSize += UInt64(values.fileSize ?? 0)
            result.latestModification = max(result.latestModification,
                values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            func mix(_ value: UInt64) { for shift in stride(from: 0, to: 64, by: 8) { hash = (hash ^ ((value >> UInt64(shift)) & 0xff)) &* 0x100_0000_01b3 } }
            for byte in url.path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
            mix(UInt64(values.fileSize ?? 0))
            mix((values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0).bitPattern)
            result.filesHash &+= hash
        }
        for root in roots(client: client) + extraFingerprintRoots(client: client) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { continue }
                for case let url as URL in enumerator { add(url) }
            } else {
                // SQLite sources change through their write-ahead log first.
                for suffix in ["", "-wal", "-shm"] { add(URL(fileURLWithPath: root.path + suffix)) }
            }
        }
        return result
    }

    /// Secondary inputs tokscale 4.21.0 also reads (scanner.rs); they decide change detection, not availability.
    private static func extraFingerprintRoots(client: String) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        switch client {
        case "grok":
            let base = environment["GROK_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".grok")
            return [base.appendingPathComponent("logs/unified.jsonl")]
        case "kimi":
            return [home.appendingPathComponent(
                "Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/sessions")]
        case "devin-desktop":
            // The desktop parser resolves sessions through the CLI database; its own fingerprint is the CLI's.
            return roots(client: "devin-cli")
        case "codex":
            if let path = environment["TOKSCALE_HEADLESS_DIR"], !path.isEmpty { return [URL(fileURLWithPath: path)] }
            return [home.appendingPathComponent(".config/tokscale/headless"),
                    home.appendingPathComponent("Library/Application Support/tokscale/headless")]
        default: return []
        }
    }

    private static func roots(client: String) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        func root(_ variable: String, _ fallback: String) -> URL {
            if let path = environment[variable], !path.isEmpty { return URL(fileURLWithPath: path) }
            return home.appendingPathComponent(fallback)
        }
        switch client {
        case "claude": return [root("CLAUDE_CONFIG_DIR", ".claude").appendingPathComponent("projects")]
        case "codex":
            let base = root("CODEX_HOME", ".codex")
            return [base.appendingPathComponent("sessions"), base.appendingPathComponent("archived_sessions")]
        case "grok": return [root("GROK_HOME", ".grok").appendingPathComponent("sessions")]
        case "kimi":
            // Kimi CLI and Kimi Code (`KIMI_CODE_HOME`, default ~/.kimi-code) share the engine's kimi client.
            return [home.appendingPathComponent(".kimi/sessions"),
                    root("KIMI_CODE_HOME", ".kimi-code").appendingPathComponent("sessions")]
        case "gemini": return [root("GEMINI_CLI_HOME", ".gemini").appendingPathComponent("tmp")]
        case "droid": return [home.appendingPathComponent(".factory/sessions")]
        case "opencode":
            let base = root("XDG_DATA_HOME", ".local/share").appendingPathComponent("opencode")
            return [base.appendingPathComponent("storage/message"), base.appendingPathComponent("opencode.db")]
        // A single SQLite file is fingerprinted by the size and mtime of the file and its -wal/-shm siblings only;
        // Devin's database can exceed 1 GB and is never opened here.
        case "devin-cli": return [root("XDG_DATA_HOME", ".local/share").appendingPathComponent("devin/cli/sessions.db")]
        case "devin-desktop":
            return [home.appendingPathComponent("Library/Application Support/Devin/User/acp-events"),
                    home.appendingPathComponent(".config/Devin/User/acp-events"),
                    home.appendingPathComponent(".config/devin/User/acp-events")]
        case "antigravity-cli":
            return [root("GEMINI_CLI_HOME", ".gemini").appendingPathComponent("antigravity-cli/conversations")]
        case "antigravity-extension": return [home.appendingPathComponent(".gemini/antigravity/conversations")]
        case "dsh": return [root("DSH_HOME", ".dsh").appendingPathComponent("sessions")]
        case "fx": return [home.appendingPathComponent(".fx/sessions")]
        default: return []
        }
    }

    private func ensureSettings(timeZone: TimeZone) throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            let settingsURL = configDirectory.appendingPathComponent("settings.json")
            let settings = ["scanner": ["bucketTimezone": timeZone.identifier]]
            try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL, options: .atomic)
        } catch {
            throw CollectorError.open("Could not write tokscale settings")
        }
    }

    private func run(arguments: [String], timeZone: TimeZone, graph: Bool = false) async throws -> Data {
        let manager = FileManager.default
        let temporaryDirectory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try manager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            throw CollectorError.process("Could not create tokscale output")
        }
        let outputURL = temporaryDirectory.appendingPathComponent("output.json")

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments + ["--offline", "--no-spinner"] + (graph ? ["--output", outputURL.path] : [])
        var environment = ["TOKSCALE_CONFIG_DIR": configDirectory.path, "TZ": timeZone.identifier]
        for key in ["HOME", "PATH", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "GROK_HOME", "GEMINI_CLI_HOME", "XDG_DATA_HOME",
                    "KIMI_CODE_HOME", "DSH_HOME"] {
            if let value = ProcessInfo.processInfo.environment[key] { environment[key] = value }
        }
        process.environment = environment
        guard manager.createFile(atPath: outputURL.path, contents: nil),
              let stdoutHandle = try? FileHandle(forWritingTo: outputURL) else {
            try? manager.removeItem(at: temporaryDirectory)
            throw CollectorError.process("Could not create tokscale output")
        }
        process.standardOutput = graph ? FileHandle.nullDevice : stdoutHandle
        process.standardError = FileHandle.nullDevice
        let sendableProcess = SendableProcess(value: process, stdoutHandle: stdoutHandle)
        let timeoutSeconds = timeoutSeconds

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            DispatchQueue.global(qos: .utility).async {
                let process = sendableProcess.value
                defer {
                    try? sendableProcess.stdoutHandle.close()
                    try? FileManager.default.removeItem(at: temporaryDirectory)
                }
                do {
                    do {
                        try process.run()
                    } catch {
                        throw CollectorError.process("Could not run tokscale")
                    }
                    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                    timer.schedule(deadline: .now() + timeoutSeconds)
                    timer.setEventHandler {
                        sendableProcess.markTimedOut()
                        if sendableProcess.value.isRunning { sendableProcess.value.terminate() }
                    }
                    timer.resume()
                    process.waitUntilExit()
                    timer.cancel()
                    if sendableProcess.didTimeOut {
                        throw CollectorError.process("tokscale timed out")
                    }
                    guard process.terminationStatus == 0 else {
                        throw CollectorError.process("tokscale exited with status \(process.terminationStatus)")
                    }
                    guard let output = try? Data(contentsOf: outputURL) else {
                        throw CollectorError.invalidOutput("tokscale output was invalid")
                    }
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private final class SendableProcess: @unchecked Sendable {
        let value: Process
        let stdoutHandle: FileHandle
        private let lock = NSLock()
        private var timedOut = false

        init(value: Process, stdoutHandle: FileHandle) {
            self.value = value
            self.stdoutHandle = stdoutHandle
        }

        var didTimeOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return timedOut
        }

        func markTimedOut() {
            lock.lock()
            timedOut = true
            lock.unlock()
        }
    }

    private struct Key: Hashable {
        let day: String
        let sourceID: String
        let modelID: String
    }

    private struct Graph: Decodable {
        let contributions: [Contribution]
    }

    private struct Contribution: Decodable {
        let date: String
        let clients: [ClientUsage]
    }

    private struct ClientUsage: Decodable {
        let client: String
        let modelId: String
        let tokens: TokenCounts
        let messages: Int64?
    }

    private struct HourlyReport: Decodable {
        let entries: [HourlyEntry]
    }

    private struct HourlyEntry: Decodable {
        let hour: String
        let input: Int64
        let output: Int64
        let cacheRead: Int64
        let cacheWrite: Int64
        let messageCount: Int64
    }
}
