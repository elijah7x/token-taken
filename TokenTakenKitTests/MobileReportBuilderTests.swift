import XCTest
@testable import TokenTakenKit

final class MobileReportBuilderTests: XCTestCase {
    private var directory: URL!
    private let device = Device(id: "device-a", name: "Desk Mac")
    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    /// 2026-11-12 17:41 local in Asia/Shanghai.
    private var now: Date { ISO8601DateFormatter().date(from: "2026-11-12T09:41:07Z")! }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func record(
        day: String,
        model: String = "model-a",
        source: String = "claude",
        input: Int64 = 0,
        output: Int64 = 0,
        uncategorized: Int64 = 0
    ) -> UsageRecord {
        UsageRecord(day: day, timeZoneID: zone.identifier, deviceID: device.id, sourceID: source,
            modelID: model, counts: TokenCounts(input: input, output: output, uncategorized: uncategorized))
    }

    private func report(_ records: [UsageRecord], remotes: [RemoteDeviceStatus] = []) -> MobileReport {
        MobileReportBuilder.build(records: records, device: device, appVersion: "0.1.0 (12)",
            generatedAt: now, timeZone: zone, remotes: remotes)
    }

    func testLast30DaysIsThirtyLocalDaysEndingToday() {
        let built = report([
            record(day: "2026-10-13", input: 1), // 30 days before today
            record(day: "2026-10-14", input: 100), // first day of the window
            record(day: "2026-11-12", input: 20), // today
        ])
        XCTAssertEqual(built.totals.last30Days.input, 120)
        XCTAssertEqual(built.totals.today.input, 20)
        XCTAssertEqual(built.totals.allTime.input, 121)
    }

    func testThisMonthStartsOnTheFirstAndStopsAtToday() {
        let built = report([
            record(day: "2026-10-31", input: 5),
            record(day: "2026-11-01", input: 7),
            record(day: "2026-11-13", input: 11), // after today
        ])
        XCTAssertEqual(built.totals.thisMonth.input, 7)
        XCTAssertEqual(built.totals.last30Days.input, 12)
        XCTAssertEqual(built.totals.allTime.input, 23)
    }

    func testMonthKeepsEightModelsPlusOther() throws {
        let records = (0..<10).map { index in
            record(day: "2026-11-05", model: "model-\(index)", input: Int64((10 - index) * 10))
        }
        let built = report(records)
        let month = try XCTUnwrap(built.months.first)
        XCTAssertEqual(month.month, "2026-11")
        XCTAssertEqual(month.models.count, 9)
        XCTAssertEqual(month.models.prefix(8).map(\.id), (0..<8).map { "model-\($0)" })
        XCTAssertEqual(month.models.map(\.total), [100, 90, 80, 70, 60, 50, 40, 30, 30])
        XCTAssertEqual(month.models.last?.id, MobileReportBuilder.otherSliceID)
        XCTAssertEqual(month.models.reduce(Int64(0)) { $0 + $1.total }, month.total)
    }

    func testEightModelsHaveNoOtherEntry() {
        let records = (0..<8).map { index in
            record(day: "2026-11-05", model: "model-\(index)", input: Int64(index + 1))
        }
        let built = report(records)
        XCTAssertEqual(built.months.first?.models.count, 8)
        XCTAssertFalse(built.months.first?.models.contains { $0.id == MobileReportBuilder.otherSliceID } ?? true)
    }

    func testTotalKeepsUncategorizedTokensOutOfTheNamedComponents() {
        let built = report([
            record(day: "2026-11-12", model: "unpriced-model", uncategorized: 40),
            record(day: "2026-11-12", input: 10, output: 5),
        ])
        XCTAssertEqual(built.totals.allTime.total, 55)
        XCTAssertEqual(built.totals.allTime.uncategorizedComponentSum, 15)
        XCTAssertEqual(built.totals.allTime.input, 10)
        XCTAssertEqual(built.totals.allTime.output, 5)
        XCTAssertEqual(built.months.first?.models.first { $0.id == "unpriced-model" }?.total, 40)
    }

    func testDaysAscendAndSkipDaysWithoutUsage() {
        let built = report([
            record(day: "2026-11-12", input: 1),
            record(day: "2026-10-14", input: 2),
            record(day: "2026-11-01", input: 3),
        ])
        XCTAssertEqual(built.days.map(\.day), ["2026-10-14", "2026-11-01", "2026-11-12"])
        XCTAssertEqual(built.days.map(\.total), [2, 3, 1])
        XCTAssertEqual(built.days.reduce(Int64(0)) { $0 + $1.total }, built.totals.allTime.total)
        XCTAssertEqual(built.months.map(\.month), ["2026-10", "2026-11"])
    }

    func testSourcesCarryCatalogDisplayNamesAndAscend() {
        let built = report([
            record(day: "2026-11-12", source: "pi", input: 3),
            record(day: "2026-11-12", source: "claude", input: 1),
        ])
        XCTAssertEqual(built.sources.map(\.id), ["claude", "pi"])
        XCTAssertEqual(built.sources.map(\.displayName), ["Claude Code", "pi"])
        XCTAssertEqual(built.months.first?.sources.map(\.id), ["pi", "claude"])
    }

    func testCoverageListsThisMacAndReadableRemotesByName() {
        let remote = RemoteDeviceStatus(deviceID: "device-b", displayName: "Alpha Mac",
            lastWrite: now.addingTimeInterval(-86_500), state: .stale)
        let unknown = RemoteDeviceStatus(deviceID: "device-c", displayName: "device-c", lastWrite: nil, state: .unavailable)
        let built = report([record(day: "2026-11-12", input: 1)], remotes: [remote, unknown])
        XCTAssertEqual(built.coverage.devices.map(\.displayName), ["Alpha Mac", "Desk Mac"])
        XCTAssertEqual(built.coverage.devices.map(\.status), [.stale, .ok])
        XCTAssertEqual(built.generator.deviceId, device.id)
        XCTAssertEqual(built.timeZoneID, zone.identifier)
        XCTAssertEqual(built.schemaVersion, 1)
        XCTAssertEqual(built.kind, "token-taken.mobile-report")
    }

    func testEncodeThenDecodeRoundTrips() throws {
        let built = report([
            record(day: "2026-11-12", model: "model-a", input: 128, output: 64, uncategorized: 8),
            record(day: "2026-10-20", model: "model-b", source: "codex", input: 9),
        ])
        let encoded = try MobileReport.makeEncoder().encode(built)
        XCTAssertEqual(try MobileReport.decode(encoded), built)

        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("\"generatedAt\":\"2026-11-12T09:41:07Z\""))
        XCTAssertTrue(text.contains("\"kind\":\"token-taken.mobile-report\""))
        XCTAssertFalse(text.lowercased().contains("cost"))
        XCTAssertFalse(text.contains("/Users/"))
    }

    func testDecodeRejectsAnotherSchemaVersion() throws {
        let built = report([record(day: "2026-11-12", input: 1)])
        var text = try XCTUnwrap(String(data: try MobileReport.makeEncoder().encode(built), encoding: .utf8))
        text = text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
        XCTAssertThrowsError(try MobileReport.decode(Data(text.utf8))) { error in
            XCTAssertEqual(error as? MobileReportError, .unsupportedSchemaVersion(2))
        }
    }

    func testPublisherWritesThenRemovesOnlyThisMacsReport() throws {
        let mine = report([record(day: "2026-11-12", input: 7)])
        let other = MobileReportBuilder.build(
            records: [], device: Device(id: "device-b", name: "Travel Mac"),
            appVersion: "0.1.0 (12)", generatedAt: now, timeZone: zone)
        try MobileReportPublisher.write(mine, into: directory)
        try MobileReportPublisher.write(other, into: directory)

        let expected = directory.appendingPathComponent("Documents/mobile/v1/report-device-a.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
        XCTAssertEqual(try MobileReport.decode(Data(contentsOf: expected)), mine)

        try MobileReportPublisher.remove(deviceId: device.id, from: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expected.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Documents/mobile/v1/report-device-b.json").path))
    }

    func testPublisherRefusesUnsafeDeviceId() {
        XCTAssertThrowsError(try MobileReportPublisher.fileURL(deviceId: "../escape", in: directory))
        XCTAssertEqual(MobileReportPublisher.directory(in: directory).lastPathComponent, "v1")
    }

    func testContainerOverrideUsesAnExistingDirectory() async {
        let resolved = await MobileReportPublisher.containerURL(
            environment: [MobileReportPublisher.rootEnvironmentKey: directory.path])
        XCTAssertEqual(resolved?.resolvingSymlinksInPath().path, directory.resolvingSymlinksInPath().path)
        let missing = await MobileReportPublisher.containerURL(
            environment: [MobileReportPublisher.rootEnvironmentKey: directory.appendingPathComponent("absent").path])
        XCTAssertNil(missing)
    }

    func testPublishWithSettingOffDoesNothing() async {
        let status = await MobileReportPublisher.publish(
            report([record(day: "2026-11-12", input: 1)]), enabled: false,
            environment: [MobileReportPublisher.rootEnvironmentKey: directory.path])
        XCTAssertEqual(status, .disabled)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Documents/mobile/v1").path))
    }
}

private extension MobileReport.TokenSummary {
    /// Sum of the five named components; `total` may exceed it by uncategorized tokens.
    var uncategorizedComponentSum: Int64 { input + output + cacheRead + cacheWrite + reasoning }
}
