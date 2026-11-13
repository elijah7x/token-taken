import XCTest
@testable import TokenTakenKit

private final class TokscaleFixtureBundleToken {}

final class TokscaleCollectorTests: XCTestCase {
    func testParsesFixtureMapsSourcesAndAggregates() throws {
        let bundle = Bundle(for: TokscaleFixtureBundleToken.self)
        let url = try XCTUnwrap(bundle.url(forResource: "tokscale-graph", withExtension: "json"))
        let records = try TokscaleCollector.parse(data: Data(contentsOf: url), clients: ["claude", "droid", "zcode"],
            deviceID: "device-a", timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        XCTAssertEqual(records.count, 4)
        XCTAssertFalse(records.contains { $0.sourceID == "zcode" })
        XCTAssertTrue(records.allSatisfy { $0.deviceID == "device-a" && $0.timeZoneID == "Asia/Shanghai" })
        XCTAssertEqual(records.map(\.sourceID), ["claude", "factory", "claude", "factory"])
        let firstClaude = records[0]
        XCTAssertEqual(firstClaude.day, "2026-11-08")
        XCTAssertEqual(firstClaude.dayInterval?.start, ISO8601DateFormatter().date(from: "2026-11-07T16:00:00Z"))
        XCTAssertEqual(firstClaude.modelID, "claude-sonnet")
        XCTAssertEqual(firstClaude.rawModelID, "claude-sonnet")
        XCTAssertEqual(firstClaude.counts, TokenCounts(input: 107, cacheRead: 22, cacheWrite: 11, output: 53, reasoning: 6))
        XCTAssertEqual(records[1].day, "2026-11-08")
        XCTAssertEqual(records[1].modelID, "droid-large")
        XCTAssertEqual(records[1].counts, TokenCounts(input: 200, cacheRead: 30, cacheWrite: 20, output: 80, reasoning: 10))
        XCTAssertEqual(records[2].day, "2026-11-09")
        XCTAssertEqual(records[2].counts, TokenCounts(input: 300, cacheRead: 50, cacheWrite: 25, output: 100, reasoning: 20))
        XCTAssertEqual(records[3].day, "2026-11-09")
        XCTAssertEqual(records[3].counts, TokenCounts(input: 400, cacheRead: 60, cacheWrite: 30, output: 150, reasoning: 15))
    }

    func testGraphRetainsRawModelAndEventCount() throws {
        let data = Data(#"{"contributions":[{"date":"2026-11-09","clients":[{"client":"claude","modelId":"Fixture-Model","messages":3,"tokens":{"input":1,"output":2,"cacheRead":3,"cacheWrite":4,"reasoning":5}}]}]}"#.utf8)
        let records = try TokscaleCollector.parse(data: data, clients: ["claude"], deviceID: "test")
        XCTAssertEqual(records.first?.rawModelID, "Fixture-Model")
        XCTAssertEqual(records.first?.modelID, "fixture-model")
        XCTAssertEqual(records.first?.eventCount, 3)
    }

    func testHourlyFixtureUsesLocalZoneAndDoesNotInventReasoningOrModels() throws {
        let bundle = Bundle(for: TokscaleFixtureBundleToken.self)
        let url = try XCTUnwrap(bundle.url(forResource: "tokscale-hourly", withExtension: "json"))
        let now = ISO8601DateFormatter().date(from: "2026-03-09T03:30:00Z")!
        let rows = try TokscaleCollector.parseHourly(data: Data(contentsOf: url), client: "droid", deviceID: "test",
            timeZone: TimeZone(identifier: "America/New_York")!, now: now)
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.allSatisfy { $0.sourceID == "factory" && $0.deviceID == "test" && !$0.reasoningKnown })
        XCTAssertTrue(rows.allSatisfy { $0.counts.reasoning == 0 })
        XCTAssertEqual(rows[0].hourStart, ISO8601DateFormatter().date(from: "2026-03-08T05:00:00Z"))
        XCTAssertEqual(rows[1].hourStart, ISO8601DateFormatter().date(from: "2026-03-08T06:00:00Z"))
        XCTAssertEqual(rows[2].hourStart, ISO8601DateFormatter().date(from: "2026-03-08T07:00:00Z"))
        XCTAssertEqual(rows.reduce(Int64(0)) { $0 + $1.eventCount }, 14)
        XCTAssertEqual(rows.reduce(Int64(0)) { $0 + $1.counts.total }, 1_600)
        let later = now.addingTimeInterval(72 * 3_600)
        XCTAssertTrue(try TokscaleCollector.parseHourly(data: Data(contentsOf: url), client: "claude", deviceID: "test",
            timeZone: TimeZone(identifier: "America/New_York")!, now: later).isEmpty)
    }

    // Droid repeats an assistant line without id dedupe in tokscale 4.21.0, so events is 2 while token totals are unchanged.
    func testGeminiAndDroidEngineOutputMatchesHandLedger() throws {
        let bundle = Bundle(for: TokscaleFixtureBundleToken.self)
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        func fixture(_ name: String) throws -> Data {
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"))
            return try Data(contentsOf: url)
        }

        let daily = try TokscaleCollector.parse(data: fixture("tokscale-gemini-droid-graph"),
            clients: ["gemini", "droid"], deviceID: "device-a", timeZone: zone)
        let expectedDaily: [(day: String, sourceID: String, modelID: String, counts: TokenCounts, events: Int64)] = [
            ("2026-11-09", "gemini", "gemini-2.5-pro",
                TokenCounts(input: 1_000, cacheRead: 400, cacheWrite: 0, output: 250, reasoning: 80), 1),
            ("2026-11-09", "gemini", "gemini-2.5-flash",
                TokenCounts(input: 600, cacheRead: 150, cacheWrite: 0, output: 120, reasoning: 40), 1),
            ("2026-11-10", "gemini", "gemini-2.5-pro",
                TokenCounts(input: 1_500, cacheRead: 500, cacheWrite: 0, output: 320, reasoning: 110), 1),
            ("2026-11-10", "gemini", "gemini-2.5-flash",
                TokenCounts(input: 800, cacheRead: 200, cacheWrite: 0, output: 180, reasoning: 60), 1),
            ("2026-11-09", "factory", "claude-sonnet-4-5",
                TokenCounts(input: 2_100, cacheRead: 900, cacheWrite: 300, output: 480, reasoning: 120), 2),
            ("2026-11-10", "factory", "claude-opus-4-5",
                TokenCounts(input: 1_600, cacheRead: 700, cacheWrite: 250, output: 350, reasoning: 90), 1),
        ]
        XCTAssertEqual(daily.count, expectedDaily.count)
        for expected in expectedDaily {
            let matches = daily.filter {
                $0.day == expected.day && $0.sourceID == expected.sourceID && $0.modelID == expected.modelID
            }
            XCTAssertEqual(matches.count, 1, "\(expected.day) \(expected.sourceID) \(expected.modelID)")
            XCTAssertEqual(matches.first?.counts, expected.counts, "\(expected.day) \(expected.modelID)")
            XCTAssertEqual(matches.first?.eventCount, expected.events, "\(expected.day) \(expected.modelID)")
            XCTAssertEqual(matches.first?.timeZoneID, "Asia/Shanghai")
        }

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-10T16:30:00Z"))
        let geminiHourly = try TokscaleCollector.parseHourly(data: fixture("tokscale-gemini-droid-hourly-gemini"),
            client: "gemini", deviceID: "device-a", timeZone: zone, now: now)
        let droidHourly = try TokscaleCollector.parseHourly(data: fixture("tokscale-gemini-droid-hourly-droid"),
            client: "droid", deviceID: "device-a", timeZone: zone, now: now)
        let expectedHourly: [(rows: [HourlyUsage], sourceID: String, hours: [String], counts: [TokenCounts], events: [Int64])] = [
            (geminiHourly, "gemini", ["2026-11-09T02:00:00Z", "2026-11-09T03:00:00Z", "2026-11-10T01:00:00Z", "2026-11-10T05:00:00Z"],
                [TokenCounts(input: 1_000, cacheRead: 400, cacheWrite: 0, output: 250),
                 TokenCounts(input: 600, cacheRead: 150, cacheWrite: 0, output: 120),
                 TokenCounts(input: 1_500, cacheRead: 500, cacheWrite: 0, output: 320),
                 TokenCounts(input: 800, cacheRead: 200, cacheWrite: 0, output: 180)],
                [1, 1, 1, 1]),
            (droidHourly, "factory", ["2026-11-09T06:00:00Z", "2026-11-10T07:00:00Z"],
                [TokenCounts(input: 2_100, cacheRead: 900, cacheWrite: 300, output: 480),
                 TokenCounts(input: 1_600, cacheRead: 700, cacheWrite: 250, output: 350)],
                [2, 1]),
        ]
        for expected in expectedHourly {
            let starts = expected.hours.compactMap { ISO8601DateFormatter().date(from: $0) }
            XCTAssertEqual(expected.rows.map(\.hourStart), starts)
            XCTAssertEqual(expected.rows.map(\.counts), expected.counts)
            XCTAssertEqual(expected.rows.map(\.eventCount), expected.events)
            XCTAssertTrue(expected.rows.allSatisfy {
                $0.sourceID == expected.sourceID && $0.deviceID == "device-a" && !$0.reasoningKnown && $0.counts.reasoning == 0
            })
        }
    }

    func testCodexGrokKimiOpencodeMapToSourcesAndFields() throws {
        let bundle = Bundle(for: TokscaleFixtureBundleToken.self)
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let url = try XCTUnwrap(bundle.url(forResource: "tokscale-four-clients-graph", withExtension: "json"))
        let clients = ["codex", "grok", "kimi", "opencode"]
        let daily = try TokscaleCollector.parse(data: Data(contentsOf: url), clients: clients,
            deviceID: "device-a", timeZone: zone)
        // The expected source ids come from the collector's sourceMap, not from the client names.
        let mappedSources = TokscaleCollector(executableURL: URL(fileURLWithPath: "/unused"),
            configDirectory: URL(fileURLWithPath: "/unused"), clients: clients, deviceID: "device-a").sourceIDs
        let expected: [(day: String, sourceID: String, modelID: String, counts: TokenCounts, events: Int64)] = [
            ("2026-11-09", "codex", "gpt-6-astra",
                TokenCounts(input: 1_000, cacheRead: 800, cacheWrite: 0, output: 400, reasoning: 250), 3),
            ("2026-11-09", "grok", "grok-4.7",
                TokenCounts(input: 500, cacheRead: 120, cacheWrite: 0, output: 180, reasoning: 0), 2),
            ("2026-11-09", "kimi", "k3.1-pro",
                TokenCounts(input: 700, cacheRead: 300, cacheWrite: 0, output: 260, reasoning: 0), 4),
            ("2026-11-09", "opencode", "claude-opus-5-5",
                TokenCounts(input: 900, cacheRead: 600, cacheWrite: 150, output: 320, reasoning: 0), 5),
            ("2026-11-10", "codex", "gpt-6-astra",
                TokenCounts(input: 1_200, cacheRead: 950, cacheWrite: 0, output: 520, reasoning: 300), 4),
            ("2026-11-10", "grok", "grok-4.7",
                TokenCounts(input: 640, cacheRead: 160, cacheWrite: 0, output: 210, reasoning: 0), 1),
            ("2026-11-10", "kimi", "k3.1-pro",
                TokenCounts(input: 880, cacheRead: 420, cacheWrite: 0, output: 300, reasoning: 0), 3),
            ("2026-11-10", "opencode", "claude-opus-5-5",
                TokenCounts(input: 1_100, cacheRead: 700, cacheWrite: 0, output: 360, reasoning: 0), 2),
        ]
        XCTAssertEqual(daily.count, expected.count)
        XCTAssertEqual(Set(daily.map(\.sourceID)), Set(mappedSources))
        for entry in expected {
            let matches = daily.filter {
                $0.day == entry.day && $0.sourceID == entry.sourceID && $0.modelID == entry.modelID
            }
            XCTAssertEqual(matches.count, 1, "\(entry.day) \(entry.sourceID) \(entry.modelID)")
            let record = try XCTUnwrap(matches.first)
            XCTAssertEqual(record.counts, entry.counts, "\(entry.day) \(entry.modelID)")
            XCTAssertEqual(record.eventCount, entry.events, "\(entry.day) \(entry.modelID)")
            XCTAssertEqual(record.rawModelID, entry.modelID, "\(entry.day) \(entry.modelID)")
            XCTAssertEqual(record.timeZoneID, "Asia/Shanghai")
            XCTAssertEqual(record.deviceID, "device-a")
        }
    }

    func testRejectsNonexistentDSTHour() throws {
        let data = Data(#"{"entries":[{"hour":"2026-03-08 02:00","input":1,"output":0,"cacheRead":0,"cacheWrite":0,"messageCount":1}]}"#.utf8)
        XCTAssertThrowsError(try TokscaleCollector.parseHourly(data: data, client: "claude", deviceID: "test",
            timeZone: TimeZone(identifier: "America/New_York")!))
    }

    func testSourceIDsExcludeNativeCollectorsAndMapDroid() {
        let collector = TokscaleCollector(executableURL: URL(fileURLWithPath: "/unused"),
            configDirectory: URL(fileURLWithPath: "/unused"), clients: ["claude", "droid", "zcode", "pi", "omp"], deviceID: "test")
        XCTAssertEqual(collector.sourceIDs, ["claude", "factory"])
        XCTAssertFalse(TokscaleCollector.defaultClients.contains("pi"))
        XCTAssertFalse(TokscaleCollector.defaultClients.contains("omp"))
        XCTAssertFalse(TokscaleCollector.defaultClients.contains("devin-cli"))
        XCTAssertFalse(TokscaleCollector.defaultClients.contains("devin-desktop"))
    }

    func testSubprocessErrorsDoNotIncludeStderrOrPaths() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let scriptURL = dir.appendingPathComponent("mock-tokscale.sh")
        let script = """
            #!/bin/sh
            echo "fatal error in /Users/secret/project/session.jsonl: private prompt text" >&2
            exit 7
            """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let collector = TokscaleCollector(
            executableURL: scriptURL,
            configDirectory: dir.appendingPathComponent("config", isDirectory: true),
            clients: ["claude"],
            deviceID: "device-a",
            isClientAvailable: { _ in true }
        )
        do {
            _ = try await collector.collect()
            XCTFail("Expected process failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "tokscale exited with status 7")
            XCTAssertFalse(error.localizedDescription.contains("/Users/"))
            XCTAssertFalse(error.localizedDescription.contains("private"))
        }
    }

    func testTimeoutKillsChildThatIgnoresSIGTERM() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let scriptURL = dir.appendingPathComponent("stubborn-tokscale.sh")
        // SIGTERM is ignored here, so only the SIGKILL escalation can end the wait.
        let script = """
            #!/bin/sh
            trap '' TERM
            while :; do sleep 1; done
            """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let collector = TokscaleCollector(
            executableURL: scriptURL,
            configDirectory: dir.appendingPathComponent("config", isDirectory: true),
            clients: ["claude"],
            deviceID: "device-a",
            timeoutSeconds: 0.5,
            isClientAvailable: { _ in true }
        )
        let started = Date.now
        do {
            _ = try await collector.collect()
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertEqual(error.localizedDescription, "tokscale timed out")
        }
        // The wait ends at the SIGKILL deadline, far before the child's own exit.
        XCTAssertLessThan(Date.now.timeIntervalSince(started), 30)
    }

    func testSingleCollectorRunsOneGraphAndReportsUnavailableClients() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let invocationsURL = dir.appendingPathComponent("invocations.log")
        let scriptURL = dir.appendingPathComponent("mock-tokscale-multi.sh")
        let script = """
            #!/bin/sh
            echo "$*" >> "\(invocationsURL.path)"
            if [ "$1" = "graph" ]; then
              out=""
              while [ $# -gt 0 ]; do
                if [ "$1" = "--output" ]; then
                  shift
                  out="$1"
                fi
                shift
              done
              printf '%s' '{"contributions":[{"date":"2026-11-09","clients":[{"client":"claude","modelId":"claude-sonnet-4-5","messages":2,"tokens":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"reasoning":0}}]}]}' > "$out"
            else
              printf '%s' '{"entries":[]}'
            fi
            """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let availability = AvailabilityProbe(available: ["claude", "codex"])
        let collector = TokscaleCollector(
            executableURL: scriptURL,
            configDirectory: dir.appendingPathComponent("config", isDirectory: true),
            clients: ["claude", "codex", "kimi"],
            deviceID: "device-a",
            isClientAvailable: { availability.isAvailable($0) }
        )
        let batch = try await collector.collect()
        XCTAssertEqual(batch.unavailableSourceIDs, ["kimi"])
        XCTAssertEqual(batch.daily.map(\.sourceID), ["claude"])
        for client in ["claude", "codex", "kimi"] {
            XCTAssertEqual(availability.count(for: client), 1)
        }

        let log = try String(contentsOf: invocationsURL, encoding: .utf8)
        let lines = log.split(separator: "\n").map(String.init)
        let graphLines = lines.filter { $0.hasPrefix("graph ") }
        let hourlyLines = lines.filter { $0.hasPrefix("hourly ") }
        XCTAssertEqual(graphLines.count, 1)
        XCTAssertTrue(graphLines.first?.contains("-c claude,codex") == true)
        XCTAssertEqual(hourlyLines.count, 2)
    }

    func testStateSkipsUnchangedClientsAndRerunsOnlyChangedOnes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let invocationsURL = dir.appendingPathComponent("invocations.log")
        let scriptURL = dir.appendingPathComponent("mock-tokscale-state.sh")
        let script = """
            #!/bin/sh
            echo "$*" >> "\(invocationsURL.path)"
            if [ "$1" = "graph" ]; then
              out=""
              while [ $# -gt 0 ]; do
                if [ "$1" = "--output" ]; then shift; out="$1"; fi
                shift
              done
              printf '%s' '{"contributions":[{"date":"2026-11-09","clients":[{"client":"claude","modelId":"m","messages":1,"tokens":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"reasoning":0}},{"client":"codex","modelId":"m","messages":1,"tokens":{"input":2,"output":1,"cacheRead":0,"cacheWrite":0,"reasoning":0}}]}]}' > "$out"
            else
              printf '%s' '{"entries":[]}'
            fi
            """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let sizes = FingerprintBox()
        func makeCollector() -> TokscaleCollector {
            TokscaleCollector(
                executableURL: scriptURL,
                configDirectory: dir.appendingPathComponent("config", isDirectory: true),
                clients: ["claude", "codex"],
                deviceID: "device-a",
                isClientAvailable: { _ in true },
                stateDirectory: dir.appendingPathComponent("state", isDirectory: true),
                fingerprint: { sizes.fingerprint(for: $0) }
            )
        }
        func invocations() throws -> [String] {
            guard FileManager.default.fileExists(atPath: invocationsURL.path) else { return [] }
            return try String(contentsOf: invocationsURL, encoding: .utf8).split(separator: "\n").map(String.init)
        }

        let first = try await makeCollector().collect()
        XCTAssertTrue(first.unchangedSourceIDs.isEmpty)
        // Nothing is remembered until the runner commits a successful store.
        let uncommitted = try await makeCollector().collect()
        XCTAssertTrue(uncommitted.unchangedSourceIDs.isEmpty)
        for commit in uncommitted.stateCommits { try commit() }
        try FileManager.default.removeItem(at: invocationsURL)

        let unchanged = try await makeCollector().collect()
        XCTAssertEqual(unchanged.unchangedSourceIDs, ["claude", "codex"])
        XCTAssertTrue(unchanged.daily.isEmpty)
        XCTAssertEqual(try invocations(), [])

        sizes.bump("codex")
        let changed = try await makeCollector().collect()
        XCTAssertEqual(changed.unchangedSourceIDs, ["claude"])
        let lines = try invocations()
        XCTAssertEqual(lines.filter { $0.hasPrefix("graph ") }.count, 1)
        XCTAssertTrue(lines.contains { $0.hasPrefix("graph -c codex ") })
        XCTAssertEqual(lines.filter { $0.hasPrefix("hourly ") }.map { $0.contains("-c codex") }, [true])
    }

    func testHourlyFailureIsLimitedToOneClientAndPreservesItsCache() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let scriptURL = dir.appendingPathComponent("mock-tokscale-hourly-failure.sh")
        let script = """
            #!/bin/sh
            if [ "$1" = "graph" ]; then
              out=""
              while [ $# -gt 0 ]; do
                if [ "$1" = "--output" ]; then
                  shift
                  out="$1"
                fi
                shift
              done
              printf '%s' '{"contributions":[{"date":"2026-11-09","clients":[{"client":"claude","modelId":"claude-sonnet","messages":1,"tokens":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"reasoning":0}},{"client":"codex","modelId":"gpt-5","messages":1,"tokens":{"input":20,"output":6,"cacheRead":0,"cacheWrite":0,"reasoning":0}}]}]}' > "$out"
            elif [ "$1" = "hourly" ] && [ "$4" = "codex" ]; then
              exit 7
            else
              printf '%s' '{"entries":[]}'
            fi
            """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let now = ISO8601DateFormatter().date(from: "2026-11-09T10:30:00Z")!
        let device = Device(id: "device-a", name: "Test Mac")
        let store = try SQLiteUsageStore(url: dir.appendingPathComponent("usage.sqlite"))
        let cachedDaily = UsageRecord(
            day: "2026-11-08", timeZoneID: "UTC", deviceID: device.id, sourceID: "codex",
            modelID: "cached", counts: TokenCounts(input: 1)
        )
        let cachedHourly = HourlyUsage(
            hourStart: now.addingTimeInterval(-1_800), deviceID: device.id, sourceID: "codex",
            counts: TokenCounts(input: 2), eventCount: 1, reasoningKnown: false
        )
        try store.replace(
            batch: CollectionBatch(daily: [cachedDaily], hourly: [cachedHourly]),
            sourceID: "codex", deviceID: device.id
        )
        let lastSuccess = now.addingTimeInterval(-60)
        try store.record(health: SourceHealth(sourceID: "codex", lastSuccess: lastSuccess, recordCount: 1))

        let collector = TokscaleCollector(
            executableURL: scriptURL,
            configDirectory: dir.appendingPathComponent("config", isDirectory: true),
            clients: ["claude", "codex"],
            deviceID: device.id,
            isClientAvailable: { _ in true }
        )
        let results = await CollectionRunner(store: store, device: device, collectors: [collector]).runAll(now: now)
        let bySource = Dictionary(uniqueKeysWithValues: results.map { ($0.sourceID, $0) })
        XCTAssertEqual(bySource["claude"]?.state, .ok)
        XCTAssertEqual(bySource["codex"]?.state, .failed)
        XCTAssertEqual(bySource["codex"]?.lastSuccess, lastSuccess)
        XCTAssertEqual(bySource["codex"]?.errorMessage, "tokscale exited with status 7")
        XCTAssertEqual(try store.records().filter { $0.sourceID == "codex" }, [cachedDaily])
        XCTAssertEqual(try store.hourly().filter { $0.sourceID == "codex" }, [cachedHourly])
        XCTAssertEqual(try store.records().first { $0.sourceID == "claude" }?.modelID, "claude-sonnet")
    }

    func testSourceWithoutOutcomeKeepsItsCache() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = ISO8601DateFormatter().date(from: "2026-11-09T10:30:00Z")!
        let device = Device(id: "device-a", name: "Test Mac")
        let store = try SQLiteUsageStore(url: dir.appendingPathComponent("usage.sqlite"))
        let cachedDaily = UsageRecord(
            day: "2026-11-08", timeZoneID: "UTC", deviceID: device.id, sourceID: "codex",
            modelID: "cached", counts: TokenCounts(input: 1)
        )
        let cachedHourly = HourlyUsage(
            hourStart: now.addingTimeInterval(-1_800), deviceID: device.id, sourceID: "codex",
            counts: TokenCounts(input: 2), eventCount: 1, reasoningKnown: false
        )
        try store.replace(
            batch: CollectionBatch(daily: [cachedDaily], hourly: [cachedHourly]),
            sourceID: "codex", deviceID: device.id
        )
        let fresh = UsageRecord(
            day: "2026-11-09", timeZoneID: "UTC", deviceID: device.id, sourceID: "claude",
            modelID: "fresh", counts: TokenCounts(input: 3)
        )
        let collector = BatchCollector(
            sourceIDs: ["claude", "codex"],
            batch: CollectionBatch(daily: [fresh])
        )
        let results = await CollectionRunner(store: store, device: device, collectors: [collector]).runAll(now: now)
        XCTAssertEqual(results.first { $0.sourceID == "codex" }?.state, .failed)
        XCTAssertEqual(try store.records().filter { $0.sourceID == "codex" }, [cachedDaily])
        XCTAssertEqual(try store.hourly().filter { $0.sourceID == "codex" }, [cachedHourly])
        XCTAssertEqual(try store.records().filter { $0.sourceID == "claude" }, [fresh])
    }

    func testNewClientsMapToMergedSourcesAndFields() throws {
        let bundle = Bundle(for: TokscaleFixtureBundleToken.self)
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        func fixture(_ name: String) throws -> Data {
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"))
            return try Data(contentsOf: url)
        }
        let clients = ["dsh", "fx"]
        let daily = try TokscaleCollector.parse(data: fixture("tokscale-new-clients-graph"), clients: clients,
            deviceID: "device-a", timeZone: zone)
        let mappedSources = TokscaleCollector(executableURL: URL(fileURLWithPath: "/unused"),
            configDirectory: URL(fileURLWithPath: "/unused"), clients: clients, deviceID: "device-a").sourceIDs
        XCTAssertEqual(mappedSources, ["dsh", "fx"])
        XCTAssertEqual(Set(daily.map(\.sourceID)), Set(mappedSources))
        // Devin and Antigravity are native (ADR-0009); their engine rows are ignored here.
        let expected: [(day: String, sourceID: String, modelID: String, counts: TokenCounts, events: Int64)] = [
            ("2026-11-09", "dsh", "deepseek-v4",
                TokenCounts(input: 700, cacheRead: 500, cacheWrite: 0, output: 220, reasoning: 60), 2),
            ("2026-11-09", "fx", "gpt-6-astra",
                TokenCounts(input: 500, cacheRead: 250, cacheWrite: 0, output: 160, reasoning: 30), 1),
            ("2026-11-10", "dsh", "deepseek-v4",
                TokenCounts(input: 800, cacheRead: 600, cacheWrite: 0, output: 260, reasoning: 70), 3),
            ("2026-11-10", "fx", "gpt-6-astra",
                TokenCounts(input: 650, cacheRead: 300, cacheWrite: 0, output: 180, reasoning: 40), 2),
        ]
        XCTAssertEqual(daily.count, expected.count)
        for entry in expected {
            let matches = daily.filter {
                $0.day == entry.day && $0.sourceID == entry.sourceID && $0.modelID == entry.modelID
            }
            XCTAssertEqual(matches.count, 1, "\(entry.day) \(entry.sourceID) \(entry.modelID)")
            XCTAssertEqual(matches.first?.counts, entry.counts, "\(entry.day) \(entry.modelID)")
            XCTAssertEqual(matches.first?.eventCount, entry.events, "\(entry.day) \(entry.modelID)")
        }

        XCTAssertEqual(TokscaleCollector.defaultSourceIDs.suffix(2), ["dsh", "fx"])
    }

    func testFingerprintCoversKimiCodeSessionsAndSQLiteSiblings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func withEnvironment(_ name: String, _ value: String, _ body: () throws -> Void) rethrows {
            let previous = ProcessInfo.processInfo.environment[name]
            setenv(name, value, 1)
            defer { if let previous { setenv(name, previous, 1) } else { unsetenv(name) } }
            try body()
        }

        let kimiCode = dir.appendingPathComponent("kimi-code", isDirectory: true)
        let session = kimiCode.appendingPathComponent("sessions/synthetic-session", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let wire = session.appendingPathComponent("wire.jsonl")
        try Data("{}\n".utf8).write(to: wire)
        try withEnvironment("KIMI_CODE_HOME", kimiCode.path) {
            let before = TokscaleCollector.fingerprint(client: "kimi")
            XCTAssertGreaterThanOrEqual(before.fileCount, 1)
            try Data("{}\n{}\n".utf8).write(to: wire)
            let after = TokscaleCollector.fingerprint(client: "kimi")
            XCTAssertNotEqual(before, after)
            XCTAssertEqual(after.totalSize - before.totalSize, 3)
        }

        let data = dir.appendingPathComponent("data", isDirectory: true)
        let devin = data.appendingPathComponent("devin/cli", isDirectory: true)
        try FileManager.default.createDirectory(at: devin, withIntermediateDirectories: true)
        try Data(count: 64).write(to: devin.appendingPathComponent("sessions.db"))
        try withEnvironment("XDG_DATA_HOME", data.path) {
            let before = TokscaleCollector.fingerprint(client: "devin-cli")
            XCTAssertEqual(before.fileCount, 1)
            XCTAssertEqual(before.totalSize, 64)
            // SQLite writes land in the write-ahead log first.
            try Data(count: 16).write(to: devin.appendingPathComponent("sessions.db-wal"))
            let after = TokscaleCollector.fingerprint(client: "devin-cli")
            XCTAssertEqual(after.fileCount, 2)
            XCTAssertEqual(after.totalSize, 80)
        }
    }
}

private final class AvailabilityProbe: @unchecked Sendable {
    private let available: Set<String>
    private var counts: [String: Int] = [:]
    private let lock = NSLock()

    init(available: Set<String>) {
        self.available = available
    }

    func isAvailable(_ client: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        counts[client, default: 0] += 1
        return available.contains(client)
    }

    func count(for client: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[client, default: 0]
    }
}

private struct BatchCollector: UsageCollector {
    let sourceIDs: [String]
    let batch: CollectionBatch

    func collect() async throws -> CollectionBatch { batch }
}

private final class FingerprintBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [String: UInt64] = [:]

    func fingerprint(for client: String) -> TokscaleCollector.ClientFingerprint {
        lock.withLock { TokscaleCollector.ClientFingerprint(fileCount: 1, totalSize: sizes[client, default: 1], latestModification: 0) }
    }

    func bump(_ client: String) {
        lock.withLock { sizes[client, default: 1] += 1 }
    }
}
