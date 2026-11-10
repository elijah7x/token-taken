import Foundation

public struct TokscaleCollector: UsageCollector {
    public static let defaultClients = ["claude", "codex", "grok", "kimi", "opencode", "gemini", "droid"]

    private static let sourceMap = [
        "claude": "claude",
        "codex": "codex",
        "grok": "grok",
        "kimi": "kimi",
        "opencode": "opencode",
        "gemini": "gemini",
        "droid": "factory",
    ]

    private let executableURL: URL
    private let configDirectory: URL
    private let clients: [String]
    private let deviceID: String
    private let timeoutSeconds: TimeInterval
    private let isClientAvailable: @Sendable (String) -> Bool

    public init(executableURL: URL, configDirectory: URL, clients: [String], deviceID: String) {
        self.init(
            executableURL: executableURL,
            configDirectory: configDirectory,
            clients: clients,
            deviceID: deviceID,
            timeoutSeconds: 300,
            isClientAvailable: { Self.sourceAvailable(client: $0) }
        )
    }

    init(
        executableURL: URL,
        configDirectory: URL,
        clients: [String],
        deviceID: String,
        timeoutSeconds: TimeInterval = 300,
        isClientAvailable: @escaping @Sendable (String) -> Bool = { Self.sourceAvailable(client: $0) }
    ) {
        self.executableURL = executableURL
        self.configDirectory = configDirectory
        self.clients = clients
        self.deviceID = deviceID
        self.timeoutSeconds = timeoutSeconds
        self.isClientAvailable = isClientAvailable
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
        #if arch(arm64)
        let architectures = ["arm64", "x64"]
        #else
        let architectures = ["x64", "arm64"]
        #endif
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
        let unavailableSourceIDs = Set(
            availability.filter { !$0.1 }.compactMap { Self.sourceMap[$0.0] }
        )
        guard !availableClients.isEmpty else {
            throw CollectorError.sourceUnavailable
        }
        try ensureSettings(timeZone: zone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let since = UsageDay.string(from: calendar.date(byAdding: .day, value: -2, to: now)!, in: zone)
        async let graphData = run(arguments: ["graph", "-c", availableClients.joined(separator: ",")], timeZone: zone, graph: true)
        let maxConcurrent = 3
        let hourly = await withTaskGroup(of: (client: String, rows: [HourlyUsage], errorMessage: String?).self) { group in
            var iterator = availableClients.makeIterator()
            for _ in 0..<min(maxConcurrent, availableClients.count) {
                if let client = iterator.next() {
                    group.addTask { await hourlyOutcome(client: client, since: since, timeZone: zone, now: now) }
                }
            }
            var rows: [HourlyUsage] = []
            var failedSourceIDs: [String: String] = [:]
            while let result = await group.next() {
                rows += result.rows
                if let message = result.errorMessage, let sourceID = Self.sourceMap[result.client] {
                    failedSourceIDs[sourceID] = message
                }
                if let client = iterator.next() {
                    group.addTask { await hourlyOutcome(client: client, since: since, timeZone: zone, now: now) }
                }
            }
            return (rows: rows, failedSourceIDs: failedSourceIDs)
        }
        let daily = try await Self.parse(data: graphData, clients: availableClients, deviceID: deviceID, timeZone: zone)
        return CollectionBatch(
            daily: daily,
            hourly: hourly.rows,
            unavailableSourceIDs: unavailableSourceIDs,
            failedSourceIDs: hourly.failedSourceIDs
        )
    }

    private func hourlyOutcome(
        client: String,
        since: String,
        timeZone: TimeZone,
        now: Date
    ) async -> (client: String, rows: [HourlyUsage], errorMessage: String?) {
        do {
            let data = try await run(arguments: ["hourly", "--json", "-c", client, "--since", since], timeZone: timeZone)
            let rows = try Self.parseHourly(data: data, client: client, deviceID: deviceID, timeZone: timeZone, now: now)
            return (client, rows, nil)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return (client, [], CollectionRunner.sanitizeErrorMessage(message))
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
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        func root(_ variable: String, _ fallback: String) -> URL {
            if let path = environment[variable], !path.isEmpty { return URL(fileURLWithPath: path) }
            return home.appendingPathComponent(fallback)
        }
        let paths: [URL]
        switch client {
        case "claude": paths = [root("CLAUDE_CONFIG_DIR", ".claude").appendingPathComponent("projects")]
        case "codex":
            let base = root("CODEX_HOME", ".codex")
            paths = [base.appendingPathComponent("sessions"), base.appendingPathComponent("archived_sessions")]
        case "grok": paths = [root("GROK_HOME", ".grok").appendingPathComponent("sessions")]
        case "kimi": paths = [home.appendingPathComponent(".kimi/sessions")]
        case "gemini": paths = [root("GEMINI_CLI_HOME", ".gemini").appendingPathComponent("tmp")]
        case "droid": paths = [home.appendingPathComponent(".factory/sessions")]
        case "opencode":
            let base = root("XDG_DATA_HOME", ".local/share").appendingPathComponent("opencode")
            paths = [base.appendingPathComponent("storage/message"), base.appendingPathComponent("opencode.db")]
        default: return false
        }
        return paths.contains { FileManager.default.fileExists(atPath: $0.path) }
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
        for key in ["HOME", "PATH", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "GROK_HOME", "GEMINI_CLI_HOME", "XDG_DATA_HOME"] {
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
