import XCTest
@testable import TokenTakenKit

final class UsageExportTests: XCTestCase {
    private struct FakeStore: UsageStore {
        let daily: [UsageRecord]
        var devices: [Device] = []

        func records() throws -> [UsageRecord] { daily }
        func hourly() throws -> [HourlyUsage] { [] }
    }

    private func record(
        day: String,
        source: String = "claude",
        model: String = "claude-sonnet-4-5",
        device: String = "device-a",
        zone: String = "Asia/Shanghai",
        counts: TokenCounts = TokenCounts(input: 10, cacheRead: 20, cacheWrite: 30, output: 40, reasoning: 5, uncategorized: 1),
        events: Int64 = 3
    ) -> UsageRecord {
        UsageRecord(
            day: day, timeZoneID: zone, deviceID: device, sourceID: source,
            modelID: model, counts: counts, eventCount: events
        )
    }

    private func shanghai() -> TimeZone { TimeZone(identifier: "Asia/Shanghai")! }

    // MARK: - CSV

    func testCSVEscapesCommaQuoteAndNewline() {
        let row = ExportRow(record(
            day: "2026-11-09",
            source: "say \"hi\"",
            model: "line\nbreak",
            device: "a,b"
        ))
        let line = UsageCSV.line(row)
        XCTAssertTrue(line.contains("\"a,b\""), line)
        XCTAssertTrue(line.contains("\"say \"\"hi\"\"\""), line)
        XCTAssertTrue(line.contains("\"line\nbreak\""), line)
        XCTAssertFalse(line.contains("\r"), "fields must not leak record separators: \(line)")
    }

    func testCSVLeavesPlainFieldsUnquoted() {
        let row = ExportRow(record(day: "2026-11-09"))
        let fields = UsageCSV.fields(row)
        XCTAssertEqual(fields[0], "2026-11-09")
        XCTAssertEqual(UsageCSV.line(row), fields.joined(separator: ","))
    }

    func testCSVPrefixesFormulaLikeTextButLeavesNumericFieldsUntouched() {
        for prefix in ["=", "+", "-", "@", "\t", "\r"] {
            let row = ExportRow(record(day: "2026-11-09", source: prefix + "formula"))
            let field = UsageCSV.line(row).split(separator: ",", omittingEmptySubsequences: false)[3]
            let expected = prefix == "\r" ? "\"'\rformula\"" : "'\(prefix)formula"
            XCTAssertEqual(String(field), expected)
        }

        let counts = TokenCounts(input: -1, cacheRead: -2, cacheWrite: -3, output: -4, reasoning: -5, uncategorized: -6)
        let line = UsageCSV.line(ExportRow(record(day: "2026-11-09", counts: counts, events: -7)))
        XCTAssertTrue(line.hasSuffix(",-1,-2,-3,-4,-5,-6,-21,-7,0"), line)
    }

    func testCSVAppendsTheOneHourCacheWriteSubset() {
        let counts = TokenCounts(input: 1, cacheWrite: 10, output: 2, cacheWrite1h: 6)
        let row = ExportRow(record(day: "2026-11-09", counts: counts))
        XCTAssertEqual(row.cacheWrite, 10)
        XCTAssertEqual(row.cacheWrite1h, 6)
        XCTAssertEqual(row.total, 13)
        XCTAssertEqual(UsageCSV.columns.last, "cacheWrite1h")
        XCTAssertEqual(UsageCSV.fields(row).last, "6")
        XCTAssertEqual(UsageCSV.columns.count, UsageCSV.fields(row).count)
    }

    func testCSVDocumentHasHeaderAndCRLFTerminators() {
        let rows = [
            ExportRow(record(day: "2026-11-08")),
            ExportRow(record(day: "2026-11-09")),
        ]
        let document = UsageCSV.document(rows)
        let lines = document.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], UsageCSV.header)
        XCTAssertEqual(lines.count, 4, "header, two rows, and a trailing empty component")
        XCTAssertEqual(lines[3], "")
        XCTAssertEqual(UsageCSV.columns.count, UsageCSV.fields(rows[0]).count)
    }

    // MARK: - Rows

    func testExportRowTotalsAndEventCount() {
        let counts = TokenCounts(input: 1, cacheRead: 2, cacheWrite: 3, output: 4, reasoning: 5, uncategorized: 6)
        let row = ExportRow(record(day: "2026-11-09", counts: counts, events: 9))
        XCTAssertEqual(row.total, 21)
        XCTAssertEqual(row.uncategorized, 6)
        XCTAssertEqual(row.eventCount, 9)
        XCTAssertEqual(row.timeZoneID, "Asia/Shanghai")
        XCTAssertEqual(row.rawModelID, "claude-sonnet-4-5")
    }

    func testRowsAreFilteredAndSorted() throws {
        let store = FakeStore(daily: [
            record(day: "2026-11-09", source: "claude", device: "device-b"),
            record(day: "2026-11-08", source: "codex", device: "device-a"),
            record(day: "2026-11-09", source: "codex", model: "gpt-5", device: "device-a"),
        ])

        let all = try UsageExport.rows(from: store, filter: UsageFilter(), timeZone: shanghai())
        XCTAssertEqual(all.map(\.day), ["2026-11-08", "2026-11-09", "2026-11-09"])

        let codex = try UsageExport.rows(from: store, filter: UsageFilter(sources: ["codex"]), timeZone: shanghai())
        XCTAssertEqual(codex.count, 2)
        XCTAssertTrue(codex.allSatisfy { $0.sourceID == "codex" })

        let gpt = try UsageExport.rows(from: store, filter: UsageFilter(models: ["gpt-5"]), timeZone: shanghai())
        XCTAssertEqual(gpt.map(\.modelID), ["gpt-5"])

        let deviceA = try UsageExport.rows(from: store, filter: UsageFilter(devices: ["device-a", "device-b"]), timeZone: shanghai())
        XCTAssertEqual(deviceA.count, 3)

        let ranged = try UsageExport.rows(from: store, filter: UsageFilter(since: "2026-11-09"), timeZone: shanghai())
        XCTAssertEqual(ranged.count, 2)
        XCTAssertTrue(ranged.allSatisfy { $0.day == "2026-11-09" })
    }

    // MARK: - Filters before aggregation

    func testFilteredStoreExcludesRowsBeforeAggregation() throws {
        let store = FakeStore(daily: [
            record(day: "2026-11-09", source: "claude", device: "device-a"),
            record(day: "2026-11-09", source: "codex", device: "device-b"),
        ], devices: [Device(id: "device-a", name: "A"), Device(id: "device-b", name: "B")])

        let result = try UsageExport.summary(
            from: store, period: .all, filter: UsageFilter(sources: ["claude"]),
            timeZone: shanghai(), priceTable: .synthetic,
            now: SyntheticUsageStore.defaultToday
        )
        XCTAssertEqual(result.summary.total, TokenCounts(input: 10, cacheRead: 20, cacheWrite: 30, output: 40, reasoning: 5, uncategorized: 1))
        XCTAssertEqual(result.summary.bySource.map(\.id), ["claude"])
        XCTAssertEqual(result.summary.byDevice.map(\.id), ["device-a"])
    }

    func testFilteredStoreLimitsDevices() {
        let store = FakeStore(daily: [], devices: [Device(id: "device-a", name: "A"), Device(id: "device-b", name: "B")])
        let filtered = FilteredUsageStore(store: store, filter: UsageFilter(devices: ["device-b"]))
        XCTAssertEqual(filtered.devices.map(\.id), ["device-b"])
        XCTAssertEqual(FilteredUsageStore(store: store, filter: UsageFilter()).devices.count, 2)
    }

    // MARK: - Custom range in a non-UTC zone

    func testSinceUntilUseLocalDayLabelsInViewerZone() throws {
        let store = FakeStore(daily: [
            record(day: "2026-11-01"),
            record(day: "2026-11-02"),
            record(day: "2026-11-03"),
            record(day: "2026-11-04"),
        ])
        let zone = shanghai()
        let filter = UsageFilter(since: "2026-11-02", until: "2026-11-03")
        let result = try UsageExport.summary(
            from: store, period: .month, filter: filter, timeZone: zone,
            priceTable: .synthetic, now: SyntheticUsageStore.defaultToday
        )

        XCTAssertEqual(result.from, "2026-11-02")
        XCTAssertEqual(result.to, "2026-11-03")
        // Two Shanghai days times the fixture row total (106 tokens).
        XCTAssertEqual(result.summary.total, TokenCounts(
            input: 20, cacheRead: 40, cacheWrite: 60, output: 80, reasoning: 10, uncategorized: 2
        ))
        XCTAssertEqual(UsageDay.string(from: result.summary.start, in: zone), "2026-11-02")
        XCTAssertEqual(UsageDay.string(from: result.summary.end, in: zone), "2026-11-04")
    }

    func testSinceWithoutUntilIncludesAllLaterDates() throws {
        let store = FakeStore(daily: [
            record(day: "2026-11-08"),
            record(day: "2026-11-09"),
            record(day: "2026-11-11"),
        ])
        let zone = shanghai()
        let now = SyntheticUsageStore.defaultToday
        let result = try UsageExport.summary(
            from: store, period: .month, filter: UsageFilter(since: "2026-11-09"), timeZone: zone,
            priceTable: .synthetic, now: now
        )
        XCTAssertEqual(result.from, "2026-11-09")
        XCTAssertNil(result.to)
        XCTAssertEqual(result.summary.total, TokenCounts(
            input: 20, cacheRead: 40, cacheWrite: 60, output: 80, reasoning: 10, uncategorized: 2
        ))
        XCTAssertEqual(UsageDay.string(from: result.summary.end, in: zone), "2026-11-12")
    }

    func testDayLabelsBoundExportRowsToTheNamedPeriod() {
        let zone = shanghai()
        let now = SyntheticUsageStore.defaultToday
        XCTAssertEqual(UsageExport.dayLabels(for: .day, timeZone: zone, now: now).since, "2026-11-09")
        XCTAssertEqual(UsageExport.dayLabels(for: .week, timeZone: zone, now: now).since, "2026-11-09")
        XCTAssertEqual(UsageExport.dayLabels(for: .month, timeZone: zone, now: now).since, "2026-11-01")
        XCTAssertEqual(UsageExport.dayLabels(for: .year, timeZone: zone, now: now).since, "2026-01-01")
        XCTAssertEqual(UsageExport.dayLabels(for: .all, timeZone: zone, now: now).until, "2026-11-09")
        XCTAssertNil(UsageExport.dayLabels(for: .all, timeZone: zone, now: now).since)

        let sunday = UsageDay.date(from: "2026-11-08", in: zone)!.addingTimeInterval(12 * 3_600)
        XCTAssertEqual(UsageExport.dayLabels(for: .week, timeZone: zone, now: sunday).since, "2026-11-02")
        XCTAssertEqual(UsageExport.dayLabels(for: .week, timeZone: zone, now: sunday).until, "2026-11-08")
    }

    func testNamedPeriodStillUsesAggregatorBoundaries() throws {
        let store = FakeStore(daily: [
            record(day: "2026-11-08"),
            record(day: "2026-11-09"),
            record(day: "2026-11-10"),
        ])
        let zone = shanghai()
        let result = try UsageExport.summary(
            from: store, period: .day, filter: UsageFilter(), timeZone: zone,
            priceTable: .synthetic, now: SyntheticUsageStore.defaultToday
        )
        XCTAssertEqual(result.from, "2026-11-09")
        XCTAssertEqual(result.to, "2026-11-09")
        XCTAssertEqual(result.summary.total, TokenCounts(
            input: 10, cacheRead: 20, cacheWrite: 30, output: 40, reasoning: 5, uncategorized: 1
        ))
    }

    func testSummaryWithFutureUntilIncludesCrossZoneTomorrowRow() throws {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        let now = UsageDay.date(from: "2026-11-09", in: zone)!.addingTimeInterval(20 * 3_600)
        let todayRow = record(day: "2026-11-09", model: "claude-sonnet-4-5", device: "device-a", zone: zone.identifier)
        let tomorrowRow = record(day: "2026-11-10", model: "gpt-5", device: "device-b", zone: "Asia/Shanghai")
        let store = FakeStore(
            daily: [todayRow, tomorrowRow],
            devices: [Device(id: "device-a", name: "A"), Device(id: "device-b", name: "B")]
        )

        let filter = UsageFilter(until: "2026-11-10")
        let result = try UsageExport.summary(
            from: store, period: .all, filter: filter, timeZone: zone,
            priceTable: .synthetic, now: now
        )
        let rows = try UsageExport.rows(from: store, filter: filter, timeZone: zone)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(result.to, "2026-11-10")
        XCTAssertEqual(UsageDay.string(from: result.summary.end, in: zone), "2026-11-11")
        XCTAssertEqual(result.summary.total, TokenCounts(
            input: 20, cacheRead: 40, cacheWrite: 60, output: 80, reasoning: 10, uncategorized: 2
        ))
        XCTAssertEqual(Set(result.summary.byModel.map(\.id)), Set(["claude-sonnet-4-5", "gpt-5"]))
        XCTAssertEqual(Set(result.summary.byDevice.map(\.id)), Set(["device-a", "device-b"]))

        let futureOnly = try UsageExport.summary(
            from: store, period: .all, filter: UsageFilter(since: "2026-11-10", until: "2026-11-10"),
            timeZone: zone, priceTable: .synthetic, now: now
        )
        XCTAssertEqual(futureOnly.summary.total, tomorrowRow.counts)
        XCTAssertEqual(futureOnly.summary.byModel.map(\.id), ["gpt-5"])
        XCTAssertEqual(futureOnly.summary.byDevice.map(\.id), ["device-b"])
    }
}
