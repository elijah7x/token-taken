import Foundation
import TokenTakenKit

enum CLI {
    // Keep in step with MARKETING_VERSION in project.yml.
    static let version = "0.1.0"

    static let usage = """
        Usage:
          token-taken summary [--period day|month|year|all] [--json] [--synthetic]
          token-taken sources [--json] [--synthetic]
          token-taken --version
        """
}

func writeError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func usageError(_ message: String) -> Never {
    writeError("token-taken: \(message)\n\(CLI.usage)")
    exit(2)
}

// MARK: - JSON (docs/contracts/cli.md)

struct Envelope<Payload: Encodable>: Encodable {
    let schemaVersion = 1
    let generatedAt: String
    let timeZone: String
    let range: DateRange
    let data: Payload
    let warnings: [Warning]
}

struct DateRange: Encodable {
    let from: String?
    let to: String?
}

struct Counts: Encodable {
    let input, cacheRead, cacheWrite, output, reasoning, total: Int64

    init(_ c: TokenCounts) {
        input = c.input
        cacheRead = c.cacheRead
        cacheWrite = c.cacheWrite
        output = c.output
        reasoning = c.reasoning
        total = c.total
    }
}

struct Group: Encodable {
    let id, name: String
    let input, cacheRead, cacheWrite, output, reasoning, total: Int64

    init(_ b: Breakdown) {
        id = b.id
        name = b.name
        input = b.counts.input
        cacheRead = b.counts.cacheRead
        cacheWrite = b.counts.cacheWrite
        output = b.counts.output
        reasoning = b.counts.reasoning
        total = b.counts.total
    }
}

struct Cost: Encodable {
    let estimatedUSD: Double
    let priceTableVersion: String
    let unpricedTokens: Int64
}

struct SummaryData: Encodable {
    let period: String
    let total: Counts
    let bySource: [Group]
    let byModel: [Group]
    let byDevice: [Group]
    let cost: Cost
}

struct SourcesData: Encodable {
    let sources: [SourceStatus]
}

struct SourceStatus: Encodable {
    let id: String
    let lastSuccess: String?
    let records: Int
    let error: String?
}

struct Warning: Encodable {
    let code: String
    let message: String
}

struct StoreSelection {
    let store: any UsageStore
    let now: Date
    let health: [SourceHealth]
    let warnings: [Warning]
}

func selectStore(synthetic: Bool) -> StoreSelection {
    if synthetic {
        return StoreSelection(
            store: SyntheticUsageStore(),
            now: SyntheticUsageStore.defaultToday,
            health: [],
            warnings: [Warning(code: "synthetic-data", message: "synthetic fixture data, not real usage")]
        )
    }

    guard FileManager.default.fileExists(atPath: AppPaths.databaseURL.path) else {
        writeError("no data yet: open Token Taken once")
        exit(3)
    }
    do {
        let store = try SQLiteUsageStore(url: AppPaths.databaseURL, readOnly: true)
        return StoreSelection(store: store, now: .now, health: store.health(), warnings: [])
    } catch {
        writeError("token-taken: could not open usage store")
        exit(1)
    }
}

func rfc3339(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
        writeError("token-taken: could not encode JSON")
        exit(1)
    }
    print(text)
}

// MARK: - Commands

func parsePeriod(_ value: String) -> Period {
    switch value {
    case "day", "today": .day
    case "month": .month
    case "year": .year
    case "all": .all
    default: usageError("invalid period '\(value)'")
    }
}

func runSummary(_ arguments: [String]) -> Never {
    var period = Period.month
    var json = false
    var synthetic = false
    var remaining = arguments[...]
    while let argument = remaining.popFirst() {
        switch argument {
        case "--json":
            json = true
        case "--synthetic":
            synthetic = true
        case "--period":
            guard let value = remaining.popFirst() else { usageError("--period needs a value") }
            period = parsePeriod(value)
        case let flag where flag.hasPrefix("--period="):
            period = parsePeriod(String(flag.dropFirst("--period=".count)))
        default:
            usageError("unknown argument '\(argument)'")
        }
    }

    let selection = selectStore(synthetic: synthetic)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let aggregator = UsageAggregator(store: selection.store, calendar: calendar, now: selection.now)
    let summary: UsageSummary
    do {
        summary = try aggregator.summary(for: period)
    } catch {
        writeError("token-taken: could not read usage store")
        exit(1)
    }

    let dayFormatter = DateFormatter()
    dayFormatter.locale = Locale(identifier: "en_US_POSIX")
    dayFormatter.calendar = calendar
    dayFormatter.timeZone = calendar.timeZone
    dayFormatter.dateFormat = "yyyy-MM-dd"
    let from = dayFormatter.string(from: summary.start)
    let lastDay = calendar.date(byAdding: .day, value: -1, to: summary.end) ?? summary.start
    let to = dayFormatter.string(from: lastDay)

    if json {
        let envelope = Envelope(
            generatedAt: rfc3339(.now),
            timeZone: calendar.timeZone.identifier,
            range: DateRange(from: from, to: to),
            data: SummaryData(
                period: period.rawValue,
                total: Counts(summary.total),
                bySource: summary.bySource.map(Group.init),
                byModel: summary.byModel.map(Group.init),
                byDevice: summary.byDevice.map(Group.init),
                cost: Cost(
                    estimatedUSD: (summary.cost.estimatedUSD * 100).rounded() / 100,
                    priceTableVersion: summary.cost.priceTableVersion,
                    unpricedTokens: summary.cost.unpricedTokens
                )
            ),
            warnings: selection.warnings
        )
        printJSON(envelope)
        exit(0)
    }

    func row(_ label: String, _ value: String, indent: Int = 2) -> String {
        let name = String(repeating: " ", count: indent) + label
        let gap = max(1, 28 - name.count - value.count)
        return name + String(repeating: " ", count: gap) + value
    }

    var lines = ["Token Taken \(period.rawValue)  \(from) to \(to)  (\(calendar.timeZone.identifier))", ""]
    lines.append(row("Total", TokenFormat.short(summary.total.total), indent: 0))
    for category in TokenCategory.allCases {
        lines.append(row(category.rawValue, TokenFormat.short(summary.total[category])))
    }
    for (title, groups) in [("By source", summary.bySource), ("By model", summary.byModel), ("By device", summary.byDevice)] {
        lines.append("")
        lines.append(title)
        lines += groups.map { row($0.name, TokenFormat.short($0.counts.total)) }
    }
    lines.append("")
    lines.append(row("Estimated cost", TokenFormat.usd(summary.cost.estimatedUSD), indent: 0))
    lines.append("  estimate, not a bill; price table \(summary.cost.priceTableVersion)")
    if summary.cost.unpricedTokens > 0 {
        lines.append("  \(TokenFormat.short(summary.cost.unpricedTokens)) tokens unpriced")
    }
    for warning in selection.warnings {
        lines.append("")
        lines.append("Warning: \(warning.message)")
    }
    print(lines.joined(separator: "\n"))
    exit(0)
}

func runSources(_ arguments: [String]) -> Never {
    var json = false
    var synthetic = false
    for argument in arguments {
        switch argument {
        case "--json": json = true
        case "--synthetic": synthetic = true
        default: usageError("unknown argument '\(argument)'")
        }
    }

    let selection = selectStore(synthetic: synthetic)
    let statuses = selection.health.sorted { $0.sourceID < $1.sourceID }.map { health in
        SourceStatus(
            id: health.sourceID,
            lastSuccess: health.lastSuccess.map(rfc3339),
            records: health.recordCount,
            error: health.errorMessage
        )
    }
    if json {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let envelope = Envelope(
            generatedAt: rfc3339(.now),
            timeZone: calendar.timeZone.identifier,
            range: DateRange(from: nil, to: nil),
            data: SourcesData(sources: statuses),
            warnings: selection.warnings
        )
        printJSON(envelope)
    } else {
        if statuses.isEmpty {
            print("No source health recorded")
        } else {
            for status in statuses {
                print("\(status.id)  last success: \(status.lastSuccess ?? "never")  records: \(status.records)  error: \(status.error ?? "none")")
            }
        }
        for warning in selection.warnings {
            print("Warning: \(warning.message)")
        }
    }
    exit(0)
}

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "--version":
    guard arguments.count == 1 else { usageError("--version takes no arguments") }
    print("token-taken \(CLI.version)")
case "--help", "-h", "help":
    print(CLI.usage)
case "summary":
    runSummary(Array(arguments.dropFirst()))
case "sources":
    runSources(Array(arguments.dropFirst()))
case let command?:
    usageError("unknown command '\(command)'")
case nil:
    usageError("missing command")
}
