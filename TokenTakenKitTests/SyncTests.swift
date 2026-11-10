import XCTest
@testable import TokenTakenKit

final class SyncTests: XCTestCase {
    private var directory: URL!
    private let local = Device(id: "device-a", name: "Desk Mac")
    private let other = Device(id: "device-b", name: "Travel Mac")
    private var now: Date { ISO8601DateFormatter().date(from: "2026-11-09T10:30:00Z")! }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func record(device: Device, day: String = "2026-11-09", model: String = "model-a", input: Int64 = 100) -> UsageRecord {
        UsageRecord(day: day, timeZoneID: "Asia/Shanghai", deviceID: device.id, sourceID: "claude",
            modelID: model, rawModelID: "Raw-" + model,
            counts: TokenCounts(input: input, cacheRead: 20, cacheWrite: 10, output: 30, reasoning: 5, uncategorized: 7), eventCount: 3)
    }

    private func hour(device: Device, offset: Int = 0) -> HourlyUsage {
        let start = Calendar.current.dateInterval(of: .hour, for: now)!.start
        return HourlyUsage(hourStart: start.addingTimeInterval(Double(offset) * 3_600), deviceID: device.id,
            sourceID: "claude", counts: TokenCounts(input: 2, output: 3, uncategorized: 1), eventCount: 2, reasoningKnown: false)
    }

    private func store(device: Device) -> FixtureStore {
        FixtureStore(devices: [device], daily: [record(device: device)], hours: [hour(device: device)])
    }

    private func publish(_ device: Device, at date: Date? = nil) throws {
        try ICloudSync.write(local: store(device: device), device: device, root: directory,
            appVersion: "1.0", now: date ?? now)
    }

    private func read() -> [RemoteDeviceSnapshot] {
        ICloudSync.readRemote(root: directory, excludingDeviceID: local.id, now: now)
    }

    func testRoundTripPreservesBothRecordKindsAndMetadata() throws {
        try publish(other)
        let remote = try XCTUnwrap(read().first)
        XCTAssertEqual(remote.device, other)
        XCTAssertEqual(remote.daily, store(device: other).daily)
        XCTAssertEqual(remote.hourly, store(device: other).hours)
        XCTAssertEqual(remote.status.displayName, other.name)
        XCTAssertEqual(remote.status.lastWrite, now)
        XCTAssertEqual(remote.status.state, .ok)
        XCTAssertFalse(remote.hourly[0].reasoningKnown)
        XCTAssertEqual(remote.daily[0].counts.uncategorized, 7)
    }

    func testSingleWriterDoesNotTouchAnotherDeviceOrRepublishItsRows() throws {
        try publish(other)
        let backend = SyncBackend(root: directory)
        let original = try backend.read("v1/devices/device-b/device.json")
        let mixed = FixtureStore(devices: [local, other], daily: [record(device: local), record(device: other)],
            hours: [hour(device: local), hour(device: other)])
        try ICloudSync.write(local: mixed, device: local, root: directory, appVersion: "1.0", now: now)
        XCTAssertEqual(try backend.read("v1/devices/device-b/device.json"), original)
        let own = ICloudSync.readRemote(root: directory, excludingDeviceID: other.id, now: now)
        XCTAssertEqual(own.count, 1)
        XCTAssertEqual(own[0].daily.map(\.deviceID), [local.id])
        XCTAssertEqual(own[0].hourly.map(\.deviceID), [local.id])
    }

    func testDeterministicEncodingAndUnchangedMonthNotRewritten() throws {
        let first = record(device: other, model: "a")
        let second = record(device: other, model: "b")
        XCTAssertEqual(try SyncSnapshot.encode(DailySyncSnapshot(records: [first, second])),
            try SyncSnapshot.encode(DailySyncSnapshot(records: [second, first])))
        try publish(other)
        let month = directory.appendingPathComponent("v1/devices/device-b/usage-2026-11.json")
        let oldDate = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: month.path)
        try publish(other, at: now.addingTimeInterval(60))
        let attributes = try FileManager.default.attributesOfItem(atPath: month.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, oldDate)
        XCTAssertEqual(read().first?.status.lastWrite, now.addingTimeInterval(60))
    }

    func testPlaceholderIdentityIsUnavailableNotAnEmptySuccessfulMac() throws {
        let backend = SyncBackend(root: directory)
        try backend.write(Data(), to: "v1/devices/device-b/.device.json.icloud")
        let remote = try XCTUnwrap(read().first)
        XCTAssertEqual(remote.status.state, .unavailable)
        XCTAssertNil(remote.status.lastWrite)
        XCTAssertTrue(remote.daily.isEmpty)
    }

    func testMissingOrUnreadableMonthIsPartialAndNeverMixedWithOtherMonths() throws {
        let rows = [record(device: other), record(device: other, day: "2026-10-20")]
        try ICloudSync.write(local: FixtureStore(devices: [other], daily: rows, hours: [hour(device: other)]),
            device: other, root: directory, appVersion: "1.0", now: now)
        let month = directory.appendingPathComponent("v1/devices/device-b/usage-2026-11.json")
        try FileManager.default.removeItem(at: month)
        try FileManager.default.createDirectory(at: month, withIntermediateDirectories: false)
        let remote = try XCTUnwrap(read().first)
        XCTAssertEqual(remote.status.state, .partial)
        XCTAssertTrue(remote.daily.isEmpty)
        XCTAssertEqual(remote.hourly, [hour(device: other)])
    }

    func testUnreadableIdentityIsUnavailable() throws {
        try publish(other)
        let identity = directory.appendingPathComponent("v1/devices/device-b/device.json")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: identity.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identity.path) }
        XCTAssertEqual(read().first?.status.state, .unavailable)
        XCTAssertTrue(try XCTUnwrap(read().first).daily.isEmpty)
    }

    func testMissingHourlySnapshotDoesNotEraseDailyHistory() throws {
        try publish(other)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("v1/devices/device-b/hourly.json"))
        let remote = try XCTUnwrap(read().first)
        XCTAssertEqual(remote.status.state, .partial)
        XCTAssertEqual(remote.daily, [record(device: other)])
        XCTAssertTrue(remote.hourly.isEmpty)
    }

    func testEvictedMonthRequestsDownloadAndIsPartial() throws {
        try publish(other)
        let backend = SyncBackend(root: directory)
        let month = directory.appendingPathComponent("v1/devices/device-b/usage-2026-11.json")
        try FileManager.default.removeItem(at: month)
        try backend.write(Data(), to: "v1/devices/device-b/.usage-2026-11.json.icloud")
        XCTAssertEqual(read().first?.status.state, .partial)
        XCTAssertTrue(try XCTUnwrap(read().first).daily.isEmpty)
    }

    func testNoDownloadReadLeavesEvictedMonthUnavailable() throws {
        try publish(other)
        let backend = SyncBackend(root: directory)
        let month = directory.appendingPathComponent("v1/devices/device-b/usage-2026-11.json")
        try FileManager.default.removeItem(at: month)
        try backend.write(Data(), to: "v1/devices/device-b/.usage-2026-11.json.icloud")
        let remote = try XCTUnwrap(ICloudSync.readRemote(
            root: directory,
            excludingDeviceID: local.id,
            now: now,
            requestDownloads: false
        ).first)
        XCTAssertEqual(remote.status.state, .partial)
        XCTAssertTrue(remote.daily.isEmpty)
        XCTAssertEqual(remote.hourly, [hour(device: other)])
    }

    func testNotInstalledRemoteSourceDoesNotMakeDevicePartial() throws {
        let health = SourceHealth(sourceID: "codex", state: .notInstalled)
        try ICloudSync.write(
            local: store(device: other), device: other, root: directory,
            appVersion: "1.0", health: [health], now: now
        )
        XCTAssertEqual(read().first?.status.state, .ok)
    }

    func testTombstonedDeviceExcludedAndNotImplicitlyRevivedByWriter() throws {
        try publish(other)
        let backend = SyncBackend(root: directory)
        let path = "v1/devices/device-b/device.json"
        let original = try SyncSnapshot.decode(DeviceSyncSnapshot.self, from: backend.read(path))
        let tombstone = DeviceSyncSnapshot(device: other, appVersion: "1.0", lastWriteUTC: now,
            tombstone: true, files: original.files)
        try backend.write(SyncSnapshot.encode(tombstone), to: path)
        XCTAssertTrue(read().isEmpty)
        XCTAssertThrowsError(try publish(other))
        XCTAssertTrue(read().isEmpty)
    }

    func testStaleAfter24HoursKeepsUsage() throws {
        try publish(other, at: now.addingTimeInterval(-86_401))
        let remote = try XCTUnwrap(read().first)
        XCTAssertEqual(remote.status.state, .stale)
        XCTAssertEqual(remote.daily, [record(device: other)])
    }

    func testUnknownSchemaSkippedForIdentityAndRecordKinds() throws {
        let backend = SyncBackend(root: directory)
        try backend.write(Data(#"{"schemaVersion":99}"#.utf8), to: "v1/devices/device-b/device.json")
        XCTAssertTrue(read().isEmpty)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("v1/devices/device-b/device.json"))
        try publish(other)
        try backend.write(Data(#"{"schemaVersion":99}"#.utf8), to: "v1/devices/device-b/hourly.json")
        XCTAssertTrue(read().isEmpty)
    }

    func testIncompletePublicationDoesNotMixGenerations() throws {
        try publish(other)
        let changed = record(device: other, input: 999)
        let backend = SyncBackend(root: directory)
        try backend.write(SyncSnapshot.encode(DailySyncSnapshot(records: [changed])),
            to: "v1/devices/device-b/usage-2026-11.json")
        let remote = try XCTUnwrap(read().first)
        XCTAssertEqual(remote.status.state, .partial)
        XCTAssertTrue(remote.daily.isEmpty)
        XCTAssertEqual(remote.hourly, [hour(device: other)])
    }

    func testManifestStopsRemovedMonthFromReappearing() throws {
        try publish(other)
        let empty = FixtureStore(devices: [other], daily: [], hours: [])
        try ICloudSync.write(local: empty, device: other, root: directory, appVersion: "1.0", now: now)
        let remote = try XCTUnwrap(read().first)
        XCTAssertTrue(remote.daily.isEmpty)
        XCTAssertTrue(remote.hourly.isEmpty)
        XCTAssertEqual(remote.status.state, .ok)
    }

    func testWriterLimitsHourlyWindowAndNeverPublishesPrivateHealthErrors() throws {
        let fixture = FixtureStore(devices: [other], daily: [record(device: other)],
            hours: [hour(device: other), hour(device: other, offset: -47), hour(device: other, offset: -48), hour(device: other, offset: 1)])
        let health = SourceHealth(sourceID: "claude", lastSuccess: now, errorMessage: "private synthetic diagnostic", state: .failed)
        try ICloudSync.write(local: fixture, device: other, root: directory, appVersion: "1.0", health: [health], now: now)
        let remote = try XCTUnwrap(read().first)
        XCTAssertEqual(Set(remote.hourly), Set([hour(device: other), hour(device: other, offset: -47)]))
        XCTAssertEqual(remote.status.state, .partial)
        let data = try SyncBackend(root: directory).read("v1/devices/device-b/device.json")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private synthetic diagnostic"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("errorMessage"))
    }

    func testMergedTotalsAndDeviceNamesWithoutCrossDeviceDeduplication() throws {
        try publish(other)
        let localStore = store(device: local)
        let sameID = RemoteDeviceSnapshot(device: local, daily: [record(device: local)], hourly: [],
            status: RemoteDeviceStatus(deviceID: local.id, displayName: local.name, lastWrite: now, state: .ok))
        let merged = MergedUsageStore(local: localStore, remote: read() + [sameID])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let summary = try UsageAggregator(store: merged, calendar: calendar, now: now).summary(for: .all)
        XCTAssertEqual(summary.total, record(device: local).counts + record(device: other).counts)
        XCTAssertEqual(Set(summary.byDevice.map(\.name)), Set([local.name, other.name]))
        XCTAssertEqual(try merged.records().count, 2)
        XCTAssertEqual(try merged.hourly().count, 2)
        XCTAssertEqual(Set(merged.devices), Set([local, other]))
    }

    func testBackendRejectsEscapingPaths() throws {
        let backend = SyncBackend(root: directory)
        XCTAssertThrowsError(try backend.write(Data(), to: "../outside.json"))
        XCTAssertThrowsError(try backend.read("/outside.json"))
    }
}

private struct FixtureStore: UsageStore {
    let devices: [Device]
    let daily: [UsageRecord]
    let hours: [HourlyUsage]
    func records() -> [UsageRecord] { daily }
    func hourly() -> [HourlyUsage] { hours }
}
