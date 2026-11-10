import Foundation

/// ADR-0003's pi entry-id deduplication and oh-my-pi reasoningTokens adaptations remain separate adapter work.
public struct TokscaleCollector: UsageCollector {
    public static let defaultClients = ["claude", "codex", "grok", "kimi", "omp", "opencode", "pi", "gemini", "droid"]

    private static let sourceMap = [
        "claude": "claude",
        "codex": "codex",
        "grok": "grok",
        "kimi": "kimi",
        "omp": "omp",
        "opencode": "opencode",
        "pi": "pi",
        "gemini": "gemini",
        "droid": "factory",
    ]

    private let executableURL: URL
    private let configDirectory: URL
    private let clients: [String]
    private let deviceID: String

    public init(executableURL: URL, configDirectory: URL, clients: [String], deviceID: String) {
        self.executableURL = executableURL
        self.configDirectory = configDirectory
        self.clients = clients
        self.deviceID = deviceID
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

    public func collect() async throws -> [UsageRecord] {
        try ensureSettings()
        return try Self.parse(data: await run(), clients: clients, deviceID: deviceID)
    }

    static func parse(data: Data, clients: [String], deviceID: String) throws -> [UsageRecord] {
        let graph = try JSONDecoder().decode(Graph.self, from: data)
        let requested = Set(clients)
        var totals: [Key: TokenCounts] = [:]
        for contribution in graph.contributions {
            guard let day = UsageDay.date(from: contribution.date) else {
                throw CollectorError.invalidOutput("tokscale returned an invalid contribution date")
            }
            for usage in contribution.clients {
                guard requested.contains(usage.client), let sourceID = sourceMap[usage.client] else { continue }
                let key = Key(day: day, sourceID: sourceID, modelID: usage.modelId)
                totals[key, default: .zero] += usage.tokens
            }
        }
        return totals.map { key, counts in
            UsageRecord(day: key.day, deviceID: deviceID, sourceID: key.sourceID, modelID: key.modelID, counts: counts)
        }.sorted {
            if $0.day != $1.day { return $0.day < $1.day }
            if $0.sourceID != $1.sourceID { return $0.sourceID < $1.sourceID }
            return $0.modelID < $1.modelID
        }
    }

    private func ensureSettings() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let settingsURL = configDirectory.appendingPathComponent("settings.json")
        guard !manager.fileExists(atPath: settingsURL.path) else { return }
        try Data(#"{"scanner":{"bucketTimezone":"UTC"}}"#.utf8).write(to: settingsURL, options: .atomic)
    }

    private func run() async throws -> Data {
        let manager = FileManager.default
        let temporaryDirectory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let outputURL = temporaryDirectory.appendingPathComponent("graph.json")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr.txt")
        guard manager.createFile(atPath: stderrURL.path, contents: nil) else {
            throw CollectorError.process("Could not create tokscale stderr output")
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "graph", "-c", clients.joined(separator: ","), "--offline", "--no-spinner",
            "--output", outputURL.path,
        ]
        var environment = ["TOKSCALE_CONFIG_DIR": configDirectory.path]
        for key in ["HOME", "PATH"] {
            if let value = ProcessInfo.processInfo.environment[key] { environment[key] = value }
        }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        process.standardError = stderrHandle
        let sendableProcess = SendableProcess(value: process, stderrHandle: stderrHandle)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            DispatchQueue.global(qos: .utility).async {
                let process = sendableProcess.value
                defer {
                    try? sendableProcess.stderrHandle.close()
                    try? FileManager.default.removeItem(at: temporaryDirectory)
                }
                do {
                    try process.run()
                    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                    timer.schedule(deadline: .now() + 300)
                    timer.setEventHandler {
                        if sendableProcess.value.isRunning { sendableProcess.value.terminate() }
                    }
                    timer.resume()
                    process.waitUntilExit()
                    timer.cancel()
                    guard process.terminationStatus == 0 else {
                        let stderr = (try? Data(contentsOf: stderrURL)) ?? Data()
                        let message = String(decoding: stderr.prefix(2_048), as: UTF8.self)
                        throw CollectorError.process("tokscale exited with status \(process.terminationStatus): \(message)")
                    }
                    continuation.resume(returning: try Data(contentsOf: outputURL))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private struct SendableProcess: @unchecked Sendable {
        let value: Process
        let stderrHandle: FileHandle
    }

    private struct Key: Hashable {
        let day: Date
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
    }
}
