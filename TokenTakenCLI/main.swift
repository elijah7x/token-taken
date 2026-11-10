import Foundation
import TokenTakenKit

enum CLI {
    // Keep in step with MARKETING_VERSION in project.yml.
    static let version = "0.1.0"
    static let schemaVersion = 1

    static let usage = """
        Usage:
          token-taken summary [options]
          token-taken sources [options]
          token-taken models [options]
          token-taken devices [options]
          token-taken export [--format json|csv] [--output FILE] [options]
          token-taken --version
          token-taken --schema

        Options:
          --period day|month|year|all  Named range ending today (default: month)
          --since YYYY-MM-DD          Inclusive local start date; overrides --period
          --until YYYY-MM-DD          Inclusive local end date; overrides --period
          --tz <IANA id>              Viewer time zone (default: system)
          --source <id>               Repeatable source filter
          --model <id>                Repeatable normalized model filter
          --device <id>               Repeatable device filter
          --json                      JSON output
          --synthetic                 Read the bundled fixture instead of the store
          --local-only                Skip synced devices from iCloud Drive
        """
}

enum Command: String {
    case summary, sources, models, devices, export
}

enum ExportFormat: String {
    case json, csv
}

func writeError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func usageError(_ message: String) -> Never {
    writeError("token-taken: \(message)\n\(CLI.usage)")
    exit(2)
}

// MARK: - Options

struct Options {
    var period = Period.month
    var since: String?
    var until: String?
    var timeZone = TimeZone.current
    var sources = Set<String>()
    var models = Set<String>()
    var devices = Set<String>()
    var json = false
    var synthetic = false
    var localOnly = false
    var format: ExportFormat?
    var output: String?

    var filter: UsageFilter {
        UsageFilter(sources: sources, models: models, devices: devices, since: since, until: until)
    }
}

func parsePeriod(_ value: String) -> Period {
    switch value {
    case "day", "today": .day
    case "month": .month
    case "year": .year
    case "all": .all
    default: usageError("invalid period '\(value)'")
    }
}

func parseOptions(_ arguments: [String], command: Command) -> Options {
    var options = Options()
    var index = 0

    func takeValue(_ flag: String, _ inline: String?) -> String {
        if let inline { return inline }
        guard index < arguments.count else { usageError("\(flag) needs a value") }
        defer { index += 1 }
        return arguments[index]
    }

    func rejectInline(_ flag: String, _ inline: String?) {
        guard inline == nil else { usageError("\(flag) takes no value") }
    }

    while index < arguments.count {
        let argument = arguments[index]
        index += 1
        let flag: String
        let inline: String?
        if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
            flag = String(argument[argument.startIndex..<equals])
            inline = String(argument[argument.index(after: equals)...])
        } else {
            flag = argument
            inline = nil
        }

        switch flag {
        case "--json":
            rejectInline(flag, inline)
            options.json = true
        case "--synthetic":
            rejectInline(flag, inline)
            options.synthetic = true
        case "--local-only":
            rejectInline(flag, inline)
            options.localOnly = true
        case "--period":
            options.period = parsePeriod(takeValue(flag, inline))
        case "--since":
            options.since = takeValue(flag, inline)
        case "--until":
            options.until = takeValue(flag, inline)
        case "--tz":
            let identifier = takeValue(flag, inline)
            guard let zone = TimeZone(identifier: identifier) else { usageError("invalid time zone '\(identifier)'") }
            options.timeZone = zone
        case "--source":
            options.sources.insert(takeValue(flag, inline))
        case "--model":
            options.models.insert(takeValue(flag, inline))
        case "--device":
            options.devices.insert(takeValue(flag, inline))
        case "--format":
            guard command == .export else { usageError("--format is only valid for export") }
            let value = takeValue(flag, inline)
            guard let format = ExportFormat(rawValue: value) else { usageError("invalid format '\(value)'") }
            options.format = format
        case "--output":
            guard command == .export else { usageError("--output is only valid for export") }
            options.output = takeValue(flag, inline)
        case "--schema":
            // Bare --schema reports the version and exits; a numeric version selects that schema.
            var version = CLI.schemaVersion
            if let inline {
                guard let number = Int(inline) else { usageError("invalid schema '\(inline)'") }
                version = number
            } else if index < arguments.count, let number = Int(arguments[index]) {
                version = number
                index += 1
            } else {
                print(CLI.schemaVersion)
                exit(0)
            }
            guard version == CLI.schemaVersion else {
                usageError("unsupported schema \(version); only \(CLI.schemaVersion) is available")
            }
        default:
            usageError("unknown argument '\(argument)'")
        }
    }

    // Dates are validated after --tz so the calendar comes from the effective zone.
    for (flag, value) in [("--since", options.since), ("--until", options.until)] {
        guard let value else { continue }
        guard value.count == 10, UsageDay.date(from: value, in: options.timeZone) != nil else {
            usageError("invalid \(flag) date '\(value)', expected YYYY-MM-DD in \(options.timeZone.identifier)")
        }
    }
    if let since = options.since, let until = options.until, since > until {
        usageError("--since \(since) is after --until \(until)")
    }
    return options
}

// MARK: - JSON (docs/contracts/cli.md)

struct Envelope<Payload: Encodable>: Encodable {
    let schemaVersion = CLI.schemaVersion
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
    let input, cacheRead, cacheWrite, output, reasoning, uncategorized, total: Int64

    init(_ c: TokenCounts) {
        input = c.input
        cacheRead = c.cacheRead
        cacheWrite = c.cacheWrite
        output = c.output
        reasoning = c.reasoning
        uncategorized = c.uncategorized
        total = c.total
    }
}

struct Group: Encodable {
    let id, name: String
    let input, cacheRead, cacheWrite, output, reasoning, uncategorized, total: Int64

    init(_ b: Breakdown) {
        id = b.id
        name = b.name
        input = b.counts.input
        cacheRead = b.counts.cacheRead
        cacheWrite = b.counts.cacheWrite
        output = b.counts.output
        reasoning = b.counts.reasoning
        uncategorized = b.counts.uncategorized
        total = b.counts.total
    }
}

struct Cost: Encodable {
    let estimatedUSD: Double
    let priceTableVersion: String
    let unpricedTokens: Int64
}

struct SummaryData: Encodable {
    /// Null when a custom --since/--until range overrides --period.
    let period: String?
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
    let skippedRecords: Int
    let state: String
    let error: String?
}

struct ModelsData: Encodable {
    let models: [ModelEntry]
}

struct ModelEntry: Encodable {
    let id: String
    let rawModelIDs: [String]
    let input, cacheRead, cacheWrite, output, reasoning, uncategorized, total: Int64
}

struct DevicesData: Encodable {
    let devices: [DeviceEntry]
}

struct DeviceEntry: Encodable {
    let id: String
    let name: String
    let local: Bool
    let lastWrite: String?
    let state: String?
    let total: Int64
}

struct ExportData: Encodable {
    let rows: [ExportRow]
}

struct Warning: Encodable {
    let code: String
    let message: String
}

// MARK: - Store selection

struct StoreSelection {
    let store: any UsageStore
    let now: Date
    let priceTable: PriceTable
    let health: [SourceHealth]
    let remote: [RemoteDeviceSnapshot]
    let warnings: [Warning]
}

func rfc3339(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
}

func sourceWarnings(_ health: [SourceHealth]) -> [Warning] {
    health.sorted { $0.sourceID < $1.sourceID }.flatMap { entry -> [Warning] in
        var warnings: [Warning] = []
        let error = entry.errorMessage.map { ": \($0)" } ?? ""
        switch entry.state {
        case .failed:
            warnings.append(Warning(code: "source-failed", message: "\(entry.sourceID): collection failed\(error)"))
        case .unavailable:
            warnings.append(Warning(code: "source-unavailable", message: "\(entry.sourceID): source unavailable\(error)"))
        case .stale:
            warnings.append(Warning(code: "source-stale", message: "\(entry.sourceID): no successful collection since \(entry.lastSuccess.map(rfc3339) ?? "never")"))
        case .ok, .notInstalled:
            break
        }
        if entry.skippedRecords > 0 {
            warnings.append(Warning(code: "partial-data", message: "\(entry.sourceID): \(entry.skippedRecords) skipped records"))
        }
        return warnings
    }
}

func sourceTableState(_ state: SourceHealth.State) -> String {
    switch state {
    case .ok: "ok"
    case .unavailable: "unavailable"
    case .notInstalled: "not installed"
    case .failed: "failed"
    case .stale: "stale"
    }
}

/// Spelled without naming the nested state enum so this file only depends on the documented cases.
func deviceStateLabel(_ status: RemoteDeviceStatus) -> String {
    switch status.state {
    case .stale: "stale"
    case .partial: "partial"
    case .unavailable: "unavailable"
    default: "ok"
    }
}

func deviceWarnings(_ remote: [RemoteDeviceSnapshot]) -> [Warning] {
    remote
        .map(\.status)
        .sorted { $0.deviceID < $1.deviceID }
        .compactMap { status -> Warning? in
            let code: String? = switch status.state {
            case .stale: "device-stale"
            case .partial: "device-partial"
            case .unavailable: "device-unavailable"
            default: nil
            }
            guard let code else { return nil }
            let label = deviceStateLabel(status)
            let lastWrite = status.lastWrite.map { ", last write \(rfc3339($0))" } ?? ""
            return Warning(code: code, message: "\(status.displayName) (\(status.deviceID)): \(label)\(lastWrite)")
        }
}

/// The app writes this Mac's device id to the shared support folder; the CLI only reads it. Before the
/// app's first launch there is no local snapshot to exclude, so the local store's own device wins.
func localDeviceID(store: any UsageStore) -> String {
    if let id = LocalDevice.storedID() { return id }
    let records = (try? store.records()) ?? []
    var counts: [String: Int] = [:]
    for record in records { counts[record.deviceID, default: 0] += 1 }
    return counts.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).first?.key ?? ""
}

func selectStore(_ options: Options) -> StoreSelection {
    if options.synthetic {
        return StoreSelection(
            store: SyntheticUsageStore(),
            now: SyntheticUsageStore.defaultToday,
            priceTable: .synthetic,
            health: [],
            remote: [],
            warnings: [Warning(code: "synthetic-data", message: "synthetic fixture data, not real usage")]
        )
    }

    guard FileManager.default.fileExists(atPath: AppPaths.databaseURL.path) else {
        writeError("no data yet: open Token Taken once")
        exit(3)
    }
    do {
        let now = Date.now
        let local = try SQLiteUsageStore(url: AppPaths.databaseURL, readOnly: true)
        let health = try local.health().map { $0.markingStale(now: now) }
        var remote: [RemoteDeviceSnapshot] = []
        var merged = false
        if !options.localOnly,
           let root = ICloudSync.defaultRoot,
           FileManager.default.fileExists(atPath: root.appendingPathComponent("v1/devices", isDirectory: true).path) {
            remote = ICloudSync.readRemote(root: root, excludingDeviceID: localDeviceID(store: local))
            merged = true
        }
        let store: any UsageStore
        if merged {
            store = MergedUsageStore(local: local, remote: remote)
        } else {
            store = local
        }
        return StoreSelection(
            store: store, now: now, priceTable: .bundled, health: health, remote: remote,
            warnings: sourceWarnings(health) + deviceWarnings(remote)
        )
    } catch {
        writeError("token-taken: could not open usage store")
        exit(1)
    }
}

// MARK: - Output

func write(_ text: String, to path: String?) {
    guard let path else {
        FileHandle.standardOutput.write(Data(text.utf8))
        return
    }
    do {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
        writeError("token-taken: could not write \(path)")
        exit(1)
    }
}

func printJSON<T: Encodable>(_ value: T, to path: String? = nil) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
        writeError("token-taken: could not encode JSON")
        exit(1)
    }
    write(text + "\n", to: path)
}

/// Table mode carries warnings on stderr so stdout stays clean for pipes.
func warnToStderr(_ warnings: [Warning]) {
    for warning in warnings {
        writeError("warning [\(warning.code)]: \(warning.message)")
    }
}

func alignedRow(_ cells: [String], widths: [Int]) -> String {
    cells.enumerated().map { index, cell in
        guard index < cells.count - 1 else { return cell }
        let target = widths[index] + 2
        // Never truncate: a long label keeps its text and pushes the value out instead.
        guard cell.count < target else { return cell + "  " }
        return cell.padding(toLength: target, withPad: " ", startingAt: 0)
    }.joined()
}

func table(_ headers: [String], _ rows: [[String]]) -> [String] {
    let widths = headers.indices.map { column in
        max(headers[column].count, rows.map { $0[column].count }.max() ?? 0)
    }
    let divider = widths.map { String(repeating: "-", count: $0) }
    return [alignedRow(headers, widths: widths), alignedRow(divider, widths: widths)]
        + rows.map { alignedRow($0, widths: widths) }
}

func calendar(in timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
}

func effectiveRange(_ result: ExportedSummary, timeZone: TimeZone) -> (from: String, to: String) {
    let viewerCalendar = calendar(in: timeZone)
    let from = result.from ?? UsageDay.string(from: result.summary.start, in: timeZone)
    let lastDay = viewerCalendar.date(byAdding: .day, value: -1, to: result.summary.end) ?? result.summary.start
    return (from, result.to ?? UsageDay.string(from: lastDay, in: timeZone))
}

/// Range filters for commands that select daily records directly; a custom range wins over --period.
func rangeFilter(_ options: Options, now: Date) -> UsageFilter {
    var filter = options.filter
    guard !filter.hasDateRange else { return filter }
    let bounds = UsageExport.dayLabels(for: options.period, timeZone: options.timeZone, now: now)
    filter.since = bounds.since
    filter.until = bounds.until
    return filter
}

// MARK: - Commands

func runSummary(_ arguments: [String]) -> Never {
    let options = parseOptions(arguments, command: .summary)
    let selection = selectStore(options)
    let filter = options.filter
    let result: ExportedSummary
    do {
        result = try UsageExport.summary(
            from: selection.store, period: options.period, filter: filter,
            timeZone: options.timeZone, priceTable: selection.priceTable, now: selection.now
        )
    } catch {
        writeError("token-taken: could not read usage store")
        exit(1)
    }

    let summary = result.summary
    let periodLabel = filter.hasDateRange ? "custom" : options.period.rawValue
    if options.json {
        printJSON(Envelope(
            generatedAt: rfc3339(.now),
            timeZone: options.timeZone.identifier,
            range: DateRange(from: result.from, to: result.to),
            data: SummaryData(
                period: filter.hasDateRange ? nil : options.period.rawValue,
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
        ))
        exit(0)
    }

    let (from, to) = effectiveRange(result, timeZone: options.timeZone)
    var lines = ["Token Taken \(periodLabel)  \(from) to \(to)  (\(options.timeZone.identifier))", ""]
    lines.append(alignedRow(["Total", TokenFormat.short(summary.total.total)], widths: [28, 0]))
    for category in TokenCategory.allCases {
        lines.append(alignedRow([category.rawValue, TokenFormat.short(summary.total[category])], widths: [28, 0]))
    }
    if summary.total.uncategorized > 0 {
        lines.append(alignedRow(["uncategorized", TokenFormat.short(summary.total.uncategorized)], widths: [28, 0]))
    }
    for (title, groups) in [("By source", summary.bySource), ("By model", summary.byModel), ("By device", summary.byDevice)] {
        guard !groups.isEmpty else { continue }
        lines.append("")
        lines.append(title)
        let width = groups.map(\.name.count).max() ?? 0
        lines += groups.map { alignedRow([$0.name, TokenFormat.short($0.counts.total)], widths: [width, 0]) }
    }
    lines.append("")
    lines.append(alignedRow(["Estimated cost", TokenFormat.usd(summary.cost.estimatedUSD)], widths: [28, 0]))
    lines.append("  estimate, not a bill; price table \(summary.cost.priceTableVersion)")
    if summary.cost.unpricedTokens > 0 {
        lines.append("  \(TokenFormat.short(summary.cost.unpricedTokens)) tokens unpriced")
    }
    write(lines.joined(separator: "\n") + "\n", to: nil)
    warnToStderr(selection.warnings)
    exit(0)
}

func runSources(_ arguments: [String]) -> Never {
    let options = parseOptions(arguments, command: .sources)
    let selection = selectStore(options)
    let filteredHealth = selection.health
        .filter { options.sources.isEmpty || options.sources.contains($0.sourceID) }
        .sorted { $0.sourceID < $1.sourceID }
    let statuses = filteredHealth.map { health in
        SourceStatus(
            id: health.sourceID,
            lastSuccess: health.lastSuccess.map(rfc3339),
            records: health.recordCount,
            skippedRecords: health.skippedRecords,
            state: health.state.rawValue,
            error: health.errorMessage
        )
    }

    if options.json {
        printJSON(Envelope(
            generatedAt: rfc3339(.now),
            timeZone: options.timeZone.identifier,
            range: DateRange(from: nil, to: nil),
            data: SourcesData(sources: statuses),
            warnings: selection.warnings
        ))
        exit(0)
    }

    if filteredHealth.isEmpty {
        write("No source health recorded\n", to: nil)
    } else {
        let rows = filteredHealth.map {
            [
                $0.sourceID,
                sourceTableState($0.state),
                $0.lastSuccess.map(rfc3339) ?? "never",
                String($0.recordCount),
                String($0.skippedRecords),
                $0.errorMessage ?? "none",
            ]
        }
        let lines = table(["source", "state", "last success", "records", "skipped", "error"], rows)
        write(lines.joined(separator: "\n") + "\n", to: nil)
    }
    warnToStderr(selection.warnings)
    exit(0)
}

func modelEntries(store: any UsageStore, filter: UsageFilter, timeZone: TimeZone) throws -> [ModelEntry] {
    struct Grouping {
        var rawModelIDs = Set<String>()
        var counts = TokenCounts.zero
    }
    let records = try FilteredUsageStore(store: store, filter: filter, timeZone: timeZone).records()
    var groups: [String: Grouping] = [:]
    for record in records {
        var grouping = groups[record.modelID] ?? Grouping()
        grouping.rawModelIDs.insert(record.rawModelID)
        grouping.counts += record.counts
        groups[record.modelID] = grouping
    }
    return groups.map { id, grouping in
        ModelEntry(
            id: id, rawModelIDs: grouping.rawModelIDs.sorted(),
            input: grouping.counts.input, cacheRead: grouping.counts.cacheRead,
            cacheWrite: grouping.counts.cacheWrite, output: grouping.counts.output,
            reasoning: grouping.counts.reasoning, uncategorized: grouping.counts.uncategorized,
            total: grouping.counts.total
        )
    }
    .sorted { $0.total != $1.total ? $0.total > $1.total : $0.id < $1.id }
}

func runModels(_ arguments: [String]) -> Never {
    let options = parseOptions(arguments, command: .models)
    let selection = selectStore(options)
    let filter = rangeFilter(options, now: selection.now)
    let entries: [ModelEntry]
    do {
        entries = try modelEntries(store: selection.store, filter: filter, timeZone: options.timeZone)
    } catch {
        writeError("token-taken: could not read usage store")
        exit(1)
    }

    if options.json {
        printJSON(Envelope(
            generatedAt: rfc3339(.now),
            timeZone: options.timeZone.identifier,
            range: DateRange(from: filter.since, to: filter.until),
            data: ModelsData(models: entries),
            warnings: selection.warnings
        ))
        exit(0)
    }

    if entries.isEmpty {
        write("No usage models recorded\n", to: nil)
    } else {
        let rows = entries.map { [$0.id, $0.rawModelIDs.joined(separator: ", "), TokenFormat.short($0.total)] }
        let lines = table(["model", "raw ids", "total"], rows)
        write(lines.joined(separator: "\n") + "\n", to: nil)
    }
    warnToStderr(selection.warnings)
    exit(0)
}

func deviceEntries(store: any UsageStore, remote: [RemoteDeviceSnapshot], filter: UsageFilter, timeZone: TimeZone) throws -> [DeviceEntry] {
    let records = try FilteredUsageStore(store: store, filter: filter, timeZone: timeZone).records()
    var totals: [String: Int64] = [:]
    for record in records { totals[record.deviceID, default: 0] += record.counts.total }

    var statuses: [String: RemoteDeviceStatus] = [:]
    for snapshot in remote { statuses[snapshot.status.deviceID] = snapshot.status }
    var names: [String: String] = [:]
    for device in store.devices { names[device.id] = device.name }
    for (id, status) in statuses { names[id] = names[id] ?? status.displayName }

    let ids = Set(names.keys).union(totals.keys).union(statuses.keys)
    return ids.map { id in
        let status = statuses[id]
        return DeviceEntry(
            id: id, name: names[id] ?? id, local: status == nil,
            lastWrite: status?.lastWrite.map(rfc3339),
            state: status.map { deviceStateLabel($0) },
            total: totals[id] ?? 0
        )
    }
    .sorted { $0.total != $1.total ? $0.total > $1.total : $0.id < $1.id }
}

func runDevices(_ arguments: [String]) -> Never {
    let options = parseOptions(arguments, command: .devices)
    let selection = selectStore(options)
    let filter = rangeFilter(options, now: selection.now)
    let entries: [DeviceEntry]
    do {
        entries = try deviceEntries(
            store: selection.store, remote: selection.remote,
            filter: filter, timeZone: options.timeZone
        )
    } catch {
        writeError("token-taken: could not read usage store")
        exit(1)
    }

    if options.json {
        printJSON(Envelope(
            generatedAt: rfc3339(.now),
            timeZone: options.timeZone.identifier,
            range: DateRange(from: filter.since, to: filter.until),
            data: DevicesData(devices: entries),
            warnings: selection.warnings
        ))
        exit(0)
    }

    if entries.isEmpty {
        write("No devices recorded\n", to: nil)
    } else {
        let rows = entries.map {
            [$0.id, $0.name, $0.local ? "local" : "synced", $0.state ?? "-", $0.lastWrite ?? "-", TokenFormat.short($0.total)]
        }
        let lines = table(["device", "name", "kind", "state", "last write", "total"], rows)
        write(lines.joined(separator: "\n") + "\n", to: nil)
    }
    warnToStderr(selection.warnings)
    exit(0)
}

func runExport(_ arguments: [String]) -> Never {
    let options = parseOptions(arguments, command: .export)
    let selection = selectStore(options)
    let filter = rangeFilter(options, now: selection.now)
    let rows: [ExportRow]
    do {
        rows = try UsageExport.rows(from: selection.store, filter: filter, timeZone: options.timeZone)
    } catch {
        writeError("token-taken: could not read usage store")
        exit(1)
    }

    // An explicit --format csv wins over --json; JSON formatting must not override a CSV request.
    switch options.format ?? .json {
    case .csv:
        write(UsageCSV.document(rows), to: options.output)
        // A CSV file cannot carry warnings, so they always go to stderr.
        warnToStderr(selection.warnings)
    case .json:
        printJSON(Envelope(
            generatedAt: rfc3339(.now),
            timeZone: options.timeZone.identifier,
            range: DateRange(from: filter.since, to: filter.until),
            data: ExportData(rows: rows),
            warnings: selection.warnings
        ), to: options.output)
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
case "--schema":
    if arguments.count > 1 {
        guard let number = Int(arguments[1]), arguments.count == 2 else {
            usageError("--schema takes at most one version")
        }
        guard number == CLI.schemaVersion else {
            usageError("unsupported schema \(number); only \(CLI.schemaVersion) is available")
        }
    }
    print(CLI.schemaVersion)
case "summary":
    runSummary(Array(arguments.dropFirst()))
case "sources":
    runSources(Array(arguments.dropFirst()))
case "models":
    runModels(Array(arguments.dropFirst()))
case "devices":
    runDevices(Array(arguments.dropFirst()))
case "export":
    runExport(Array(arguments.dropFirst()))
case let command?:
    usageError("unknown command '\(command)'")
case nil:
    usageError("missing command")
}
