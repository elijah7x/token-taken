import CryptoKit
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

    private func snapshot(_ device: Device, state: RemoteDeviceStatus.State, lastWrite: Date?, rows: Bool) -> RemoteDeviceSnapshot {
        RemoteDeviceSnapshot(device: device, daily: rows ? [record(device: device)] : [], hourly: rows ? [hour(device: device)] : [],
            status: RemoteDeviceStatus(deviceID: device.id, displayName: device.name, lastWrite: lastWrite, state: state))
    }

    func testCacheNeverKeepsAFirstLaunchPlaceholderForAPartialMac() {
        let placeholder = snapshot(Device(id: other.id, name: other.id), state: .unavailable, lastWrite: nil, rows: false)
        // Manifest read, payloads still downloading: no rows, so the placeholder must not be relabelled and kept.
        let downloading = snapshot(other, state: .unavailable, lastWrite: now, rows: false)
        let first = RemoteDeviceSnapshot.mergingCache([downloading], previous: [placeholder])
        XCTAssertEqual(first[0].device.name, other.name)
        let partial = snapshot(other, state: .partial, lastWrite: now, rows: true)
        let second = RemoteDeviceSnapshot.mergingCache([partial], previous: first)
        XCTAssertEqual(second[0].device.name, other.name)
        XCTAssertEqual(second[0].daily.count, 1)
        XCTAssertEqual(second[0].status.state, .partial)
    }

    func testCacheKeepsRowsWithTheirOwnPublicationTimeUntilANewerReadHasRows() {
        let older = now.addingTimeInterval(-3_600)
        let cached = snapshot(other, state: .ok, lastWrite: older, rows: true)
        let empty = snapshot(other, state: .unavailable, lastWrite: now, rows: false)
        let kept = RemoteDeviceSnapshot.mergingCache([empty], previous: [cached])
        XCTAssertEqual(kept[0].daily.count, 1)
        XCTAssertEqual(kept[0].status.state, .unavailable)
        XCTAssertEqual(kept[0].status.lastWrite, older)
        let fresh = RemoteDeviceSnapshot(device: other, daily: [record(device: other, input: 999)], hourly: [],
            status: RemoteDeviceStatus(deviceID: other.id, displayName: other.name, lastWrite: now, state: .partial))
        let replaced = RemoteDeviceSnapshot.mergingCache([fresh], previous: kept)
        XCTAssertEqual(replaced[0].daily.first?.counts.input, 999)
        XCTAssertEqual(replaced[0].status.lastWrite, now)
    }

    func testOkReadAlwaysReplacesTheCache() {
        let cached = snapshot(other, state: .ok, lastWrite: now, rows: true)
        let ok = snapshot(other, state: .ok, lastWrite: now.addingTimeInterval(-60), rows: false)
        let merged = RemoteDeviceSnapshot.mergingCache([ok], previous: [cached])
        XCTAssertTrue(merged[0].daily.isEmpty)
        XCTAssertEqual(merged[0].status.state, .ok)
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

    func testRoundTripPreservesTheOneHourCacheWriteSubset() throws {
        let counts = TokenCounts(input: 1, cacheRead: 2, cacheWrite: 10, output: 3, reasoning: 4,
                                 uncategorized: 5, cacheWrite1h: 6)
        let row = UsageRecord(day: "2026-11-09", timeZoneID: "Asia/Shanghai", deviceID: other.id,
            sourceID: "claude", modelID: "claude-sonnet-4-5", counts: counts, eventCount: 1)
        try ICloudSync.write(local: FixtureStore(devices: [other], daily: [row], hours: []),
            device: other, root: directory, appVersion: "1.0", now: now)
        let remote = try XCTUnwrap(read().first)
        XCTAssertEqual(remote.daily, [row])
        XCTAssertEqual(remote.daily[0].counts.cacheWrite1h, 6)
        XCTAssertEqual(remote.daily[0].counts.total, 25)
    }

    func testSnapshotWithoutTheOneHourKeyDecodesAsZero() throws {
        // A peer that predates the subset publishes no key; its whole cache write stays a 5-minute write.
        let data = try SyncSnapshot.encode(DailySyncSnapshot(records: [record(device: other)]))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"cacheWrite1h\":0"), text)
        let legacy = Data(text.replacingOccurrences(of: ",\"cacheWrite1h\":0", with: "").utf8)
        let decoded = try SyncSnapshot.decode(DailySyncSnapshot.self, from: legacy)
        XCTAssertEqual(decoded.records[0].counts.cacheWrite1h, 0)
        XCTAssertEqual(decoded.records[0].counts.cacheWrite, 10)
        XCTAssertEqual(decoded.records[0].counts.total, 172)
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

    func testStaleBoundaryAt24HoursJustOverAndFutureLastWrite() throws {
        let exactHour = Calendar.current.dateInterval(of: .hour, for: now)!.start
        let exactStore = FixtureStore(
            devices: [other],
            daily: [record(device: other)],
            hours: [HourlyUsage(
                hourStart: exactHour.addingTimeInterval(-24 * 3_600),
                deviceID: other.id,
                sourceID: "claude",
                counts: TokenCounts(input: 2, output: 3, uncategorized: 1),
                eventCount: 2,
                reasoningKnown: false
            )]
        )
        let exactly24h = now.addingTimeInterval(-86_400)
        try ICloudSync.write(local: exactStore, device: other, root: directory, appVersion: "1.0", now: exactly24h)
        let atBoundary = try XCTUnwrap(read().first)
        XCTAssertEqual(atBoundary.status.state, .ok)
        XCTAssertEqual(atBoundary.status.lastWrite, exactly24h)
        XCTAssertEqual(atBoundary.daily, [record(device: other)])

        let justOver24h = now.addingTimeInterval(-86_401)
        try ICloudSync.write(local: exactStore, device: other, root: directory, appVersion: "1.0", now: justOver24h)
        let overBoundary = try XCTUnwrap(read().first)
        XCTAssertEqual(overBoundary.status.state, .stale)
        XCTAssertEqual(overBoundary.status.lastWrite, justOver24h)
        XCTAssertEqual(overBoundary.daily, [record(device: other)])

        let futureWrite = now.addingTimeInterval(3_600)
        try publish(other, at: futureWrite)
        let inFuture = try XCTUnwrap(read().first)
        XCTAssertEqual(inFuture.status.state, .ok)
        XCTAssertEqual(inFuture.status.lastWrite, futureWrite)
        XCTAssertEqual(inFuture.daily, [record(device: other)])
    }

    func testStaleDeviceUsageStillCountedInMergedStoreTotals() throws {
        let staleHour = hour(device: other, offset: -24)
        let staleStore = FixtureStore(devices: [other], daily: [record(device: other)], hours: [staleHour])
        try ICloudSync.write(
            local: staleStore,
            device: other,
            root: directory,
            appVersion: "1.0",
            now: now.addingTimeInterval(-86_401)
        )
        let remotes = read()
        XCTAssertEqual(remotes.first?.status.state, .stale)

        let merged = MergedUsageStore(local: store(device: local), remote: remotes)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let summary = try UsageAggregator(store: merged, calendar: calendar, now: now).summary(for: .all)
        XCTAssertEqual(summary.total, record(device: local).counts + record(device: other).counts)
        XCTAssertEqual(Set(summary.byDevice.map(\.id)), Set([local.id, other.id]))
        XCTAssertEqual(Set(summary.byDevice.map(\.name)), Set([local.name, other.name]))
        XCTAssertEqual(Set(try merged.records()), Set([record(device: local), record(device: other)]))
        XCTAssertEqual(Set(try merged.hourly()), Set([hour(device: local), staleHour]))
    }

    func testTombstonedDeviceExcludedFromMergedTotalsAndBreakdown() throws {
        try publish(other)
        let backend = SyncBackend(root: directory)
        let path = "v1/devices/device-b/device.json"
        let original = try SyncSnapshot.decode(DeviceSyncSnapshot.self, from: backend.read(path))
        let tombstone = DeviceSyncSnapshot(
            device: other,
            appVersion: "1.0",
            lastWriteUTC: now,
            tombstone: true,
            files: original.files
        )
        try backend.write(SyncSnapshot.encode(tombstone), to: path)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("v1/devices/device-b/usage-2026-11.json").path
        ))

        let remotes = read()
        XCTAssertTrue(remotes.isEmpty)
        let merged = MergedUsageStore(local: store(device: local), remote: remotes)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let summary = try UsageAggregator(store: merged, calendar: calendar, now: now).summary(for: .all)
        XCTAssertEqual(summary.total, record(device: local).counts)
        XCTAssertEqual(summary.byDevice, [Breakdown(id: local.id, name: local.name, counts: record(device: local).counts)])
        XCTAssertEqual(try merged.records(), [record(device: local)])
        XCTAssertEqual(try merged.hourly(), [hour(device: local)])
        XCTAssertEqual(merged.devices, [local])
    }

    func testWriterRefusesTombstonedUnreadablePlaceholderAndUnsupportedLocalIdentity() throws {
        try publish(local)
        let backend = SyncBackend(root: directory)
        let path = "v1/devices/device-a/device.json"
        let original = try SyncSnapshot.decode(DeviceSyncSnapshot.self, from: backend.read(path))
        let tombstoned = DeviceSyncSnapshot(
            device: local,
            appVersion: "1.0",
            lastWriteUTC: now,
            tombstone: true,
            files: original.files
        )
        try backend.write(SyncSnapshot.encode(tombstoned), to: path)
        XCTAssertThrowsError(try publish(local, at: now.addingTimeInterval(60))) { error in
            guard case SyncError.tombstoned = error else {
                return XCTFail("Expected SyncError.tombstoned, got \(error)")
            }
        }
        let preserved = try SyncSnapshot.decode(DeviceSyncSnapshot.self, from: backend.read(path))
        XCTAssertTrue(preserved.tombstone)
        XCTAssertEqual(preserved.lastWriteUTC, now)

        let mismatched = DeviceSyncSnapshot(
            device: other,
            appVersion: "1.0",
            lastWriteUTC: now,
            tombstone: false,
            files: original.files
        )
        try backend.write(SyncSnapshot.encode(mismatched), to: path)
        XCTAssertThrowsError(try publish(local)) { error in
            guard case SyncError.invalidSnapshot = error else {
                return XCTFail("Expected SyncError.invalidSnapshot, got \(error)")
            }
        }

        let unsupportedJSON = """
        {"appVersion":"1.0","deviceId":"device-a","displayName":"Desk Mac","files":{},"lastWriteUTC":"2026-11-09T10:30:00Z","schemaVersion":99,"sources":[],"tombstone":false}
        """
        try backend.write(Data(unsupportedJSON.utf8), to: path)
        XCTAssertThrowsError(try publish(local)) { error in
            guard case SyncError.unsupportedSchema = error else {
                return XCTFail("Expected SyncError.unsupportedSchema, got \(error)")
            }
        }

        let identityURL = directory.appendingPathComponent(path)
        try FileManager.default.removeItem(at: identityURL)
        try backend.write(Data(), to: "v1/devices/device-a/.device.json.icloud")
        XCTAssertThrowsError(try publish(local)) { error in
            guard case SyncError.unavailable = error else {
                return XCTFail("Expected SyncError.unavailable, got \(error)")
            }
        }
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("v1/devices/device-a/.device.json.icloud")
        )

        try backend.write(SyncSnapshot.encode(original), to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: identityURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identityURL.path) }
        XCTAssertThrowsError(try publish(local)) { error in
            guard case SyncError.unavailable = error else {
                return XCTFail("Expected SyncError.unavailable, got \(error)")
            }
        }

        XCTAssertThrowsError(try publish(Device(id: ".hidden", name: "Hidden"))) { error in
            guard case SyncError.invalidSnapshot = error else {
                return XCTFail("Expected SyncError.invalidSnapshot, got \(error)")
            }
        }
    }

    func testCorruptOrMismatchedIdentityAndBothRecordKindsMissingAreUnavailable() throws {
        let backend = SyncBackend(root: directory)
        let path = "v1/devices/device-b/device.json"
        try backend.write(Data("not-json".utf8), to: path)
        let corrupt = try XCTUnwrap(read().first)
        XCTAssertEqual(corrupt.status.state, .unavailable)
        XCTAssertNil(corrupt.status.lastWrite)
        XCTAssertTrue(corrupt.daily.isEmpty)
        XCTAssertTrue(corrupt.hourly.isEmpty)

        let wrongID = DeviceSyncSnapshot(
            device: Device(id: "device-c", name: "Wrong ID"),
            appVersion: "1.0",
            lastWriteUTC: now,
            files: [:]
        )
        try backend.write(SyncSnapshot.encode(wrongID), to: path)
        let mismatched = try XCTUnwrap(read().first)
        XCTAssertEqual(mismatched.status.state, .unavailable)
        XCTAssertNil(mismatched.status.lastWrite)
        XCTAssertTrue(mismatched.daily.isEmpty)
        XCTAssertTrue(mismatched.hourly.isEmpty)

        try FileManager.default.removeItem(at: directory.appendingPathComponent(path))
        try publish(other)
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("v1/devices/device-b/usage-2026-11.json")
        )
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("v1/devices/device-b/hourly.json")
        )
        let bothMissing = try XCTUnwrap(read().first)
        XCTAssertEqual(bothMissing.status.state, .unavailable)
        XCTAssertEqual(bothMissing.status.lastWrite, now)
        XCTAssertTrue(bothMissing.daily.isEmpty)
        XCTAssertTrue(bothMissing.hourly.isEmpty)

        let unexpectedFile = DeviceSyncSnapshot(
            device: other,
            appVersion: "1.0",
            lastWriteUTC: now,
            files: ["unexpected.json": "deadbeef"]
        )
        try backend.write(SyncSnapshot.encode(unexpectedFile), to: path)
        let unexpected = try XCTUnwrap(read().first)
        XCTAssertEqual(unexpected.status.state, .unavailable)
        XCTAssertEqual(unexpected.status.lastWrite, now)
        XCTAssertTrue(unexpected.daily.isEmpty)
        XCTAssertTrue(unexpected.hourly.isEmpty)
    }

    func testMissingMonthlyFileMakesDevicePartialAndDropsAllDailyMonths() throws {
        let rows = [record(device: other, day: "2026-11-09"), record(device: other, day: "2026-10-20")]
        try ICloudSync.write(
            local: FixtureStore(devices: [other], daily: rows, hours: [hour(device: other)]),
            device: other,
            root: directory,
            appVersion: "1.0",
            now: now
        )
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("v1/devices/device-b/usage-2026-11.json")
        )
        let remote = try XCTUnwrap(read().first)
        XCTAssertEqual(remote.status.state, .partial)
        XCTAssertTrue(remote.daily.isEmpty)
        XCTAssertEqual(remote.hourly, [hour(device: other)])
    }

    func testReadRemoteExcludesLocalDeviceID() throws {
        try publish(local)
        try publish(other)
        let remotes = ICloudSync.readRemote(root: directory, excludingDeviceID: local.id, now: now)
        XCTAssertEqual(remotes.map(\.device), [other])
    }

    func testAgedOutHourlyRowsAreOmittedOnWriteAndLeaveDaySeriesGapsWithoutAffectingDailyTotals() throws {
        let oldDayRecord = record(device: other, day: "2026-11-06", input: 400)
        let todayRecord = record(device: other, day: "2026-11-09", input: 100)
        let fixture = FixtureStore(
            devices: [other],
            daily: [oldDayRecord, todayRecord],
            hours: [
                hour(device: other, offset: -72),
                hour(device: other, offset: -48),
                hour(device: other, offset: -47),
                hour(device: other, offset: 0)
            ]
        )
        try ICloudSync.write(local: fixture, device: other, root: directory, appVersion: "1.0", now: now)
        let remote = try XCTUnwrap(read().first)
        XCTAssertEqual(Set(remote.daily), Set([oldDayRecord, todayRecord]))
        XCTAssertEqual(Set(remote.hourly), Set([hour(device: other, offset: -47), hour(device: other, offset: 0)]))

        let emptyLocal = FixtureStore(devices: [local], daily: [], hours: [])
        let merged = MergedUsageStore(local: emptyLocal, remote: [remote])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let allSummary = try UsageAggregator(store: merged, calendar: calendar, now: now).summary(for: .all)
        XCTAssertEqual(allSummary.total, oldDayRecord.counts + todayRecord.counts)

        let nov6 = ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z")!
        let oldDaySummary = try UsageAggregator(store: merged, calendar: calendar, now: nov6).summary(for: .day)
        XCTAssertEqual(oldDaySummary.total, oldDayRecord.counts)
        XCTAssertEqual(oldDaySummary.series.count, 24)
        XCTAssertTrue(oldDaySummary.series.allSatisfy { !$0.isKnown && $0.total == 0 })

        let todaySummary = try UsageAggregator(store: merged, calendar: calendar, now: now).summary(for: .day)
        XCTAssertEqual(todaySummary.total, todayRecord.counts)
        let coveredPoint = try XCTUnwrap(todaySummary.series.first { $0.start == hour(device: other, offset: 0).hourStart })
        XCTAssertTrue(coveredPoint.isKnown)
        XCTAssertEqual(coveredPoint.total, hour(device: other, offset: 0).counts.total)
        let uncoveredPoint = try XCTUnwrap(todaySummary.series.first { $0.start != hour(device: other, offset: 0).hourStart })
        XCTAssertFalse(uncoveredPoint.isKnown)
    }

    func testPrivacyEncodedSnapshotsContainOnlyContractFieldsAndNoPathsOrCosts() throws {
        let health = SourceHealth(
            sourceID: "claude",
            lastAttempt: now,
            lastSuccess: now,
            recordCount: 99,
            errorMessage: "/Users/private/repo/session.jsonl parse error",
            skippedRecords: 0,
            state: .ok
        )
        try ICloudSync.write(
            local: store(device: other),
            device: other,
            root: directory,
            appVersion: "1.0",
            health: [health],
            now: now
        )
        let backend = SyncBackend(root: directory)
        let deviceData = try backend.read("v1/devices/device-b/device.json")
        let monthlyData = try backend.read("v1/devices/device-b/usage-2026-11.json")
        let hourlyData = try backend.read("v1/devices/device-b/hourly.json")

        let forbiddenSubstrings = [
            "/Users/", "session.jsonl", "errorMessage", "lastAttempt", "recordCount",
            "cost", "usd", "estimatedUSD", "price", "unpricedTokens", "prompt", "response", "project", "credential"
        ]
        for data in [deviceData, monthlyData, hourlyData] {
            let text = String(decoding: data, as: UTF8.self)
            for forbidden in forbiddenSubstrings {
                XCTAssertFalse(text.contains(forbidden), "Snapshot leaked forbidden token: \(forbidden)")
            }
        }
        let hourlyText = String(decoding: hourlyData, as: UTF8.self)
        XCTAssertFalse(hourlyText.contains("modelID"))
        XCTAssertFalse(hourlyText.contains("rawModelID"))

        let deviceJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: deviceData) as? [String: Any])
        XCTAssertEqual(
            Set(deviceJSON.keys),
            Set(["accounts", "appVersion", "deviceId", "displayName", "files", "lastWriteUTC", "schemaVersion", "sources", "tombstone"])
        )
        let sourcesJSON = try XCTUnwrap(deviceJSON["sources"] as? [[String: Any]])
        XCTAssertEqual(Set(sourcesJSON[0].keys), Set(["lastSuccess", "skippedRecords", "sourceID", "state"]))

        let monthlyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: monthlyData) as? [String: Any])
        XCTAssertEqual(Set(monthlyJSON.keys), Set(["records", "schemaVersion"]))
        let dailyRecordsJSON = try XCTUnwrap(monthlyJSON["records"] as? [[String: Any]])
        XCTAssertEqual(
            Set(dailyRecordsJSON[0].keys),
            Set(["counts", "day", "deviceID", "eventCount", "modelID", "rawModelID", "sourceID", "timeZoneID"])
        )
        let countsJSON = try XCTUnwrap(dailyRecordsJSON[0]["counts"] as? [String: Any])
        XCTAssertEqual(
            Set(countsJSON.keys),
            Set(["cacheRead", "cacheWrite", "cacheWrite1h", "input", "output", "reasoning", "uncategorized"])
        )

        let hourlyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: hourlyData) as? [String: Any])
        XCTAssertEqual(Set(hourlyJSON.keys), Set(["records", "schemaVersion"]))
        let hourlyRecordsJSON = try XCTUnwrap(hourlyJSON["records"] as? [[String: Any]])
        XCTAssertEqual(
            Set(hourlyRecordsJSON[0].keys),
            Set(["counts", "deviceID", "eventCount", "hourStart", "reasoningKnown", "sourceID"])
        )
    }

    func testRemoteSourceHealthStatesAndSkippedRecordsMakeFreshDevicePartial() throws {
        let okAtBoundary = SourceHealth(sourceID: "claude", lastSuccess: now.addingTimeInterval(-86_400), skippedRecords: 0, state: .ok)
        try ICloudSync.write(local: store(device: other), device: other, root: directory, appVersion: "1.0", health: [okAtBoundary], now: now)
        XCTAssertEqual(read().first?.status.state, .ok)

        let partialCases: [SourceHealth] = [
            SourceHealth(sourceID: "claude", lastSuccess: now, skippedRecords: 1, state: .ok),
            SourceHealth(sourceID: "claude", lastSuccess: nil, skippedRecords: 0, state: .ok),
            SourceHealth(sourceID: "claude", lastSuccess: now.addingTimeInterval(-86_401), skippedRecords: 0, state: .ok),
            SourceHealth(sourceID: "claude", lastSuccess: now, skippedRecords: 0, state: .unavailable),
            SourceHealth(sourceID: "claude", lastSuccess: now, skippedRecords: 0, state: .stale),
            SourceHealth(sourceID: "claude", lastSuccess: now, skippedRecords: 0, state: .failed)
        ]
        for source in partialCases {
            try ICloudSync.write(local: store(device: other), device: other, root: directory, appVersion: "1.0", health: [source], now: now)
            XCTAssertEqual(read().first?.status.state, .partial)
        }

        XCTAssertEqual(okAtBoundary.markingStale(now: now).state, .ok)
        XCTAssertEqual(
            SourceHealth(sourceID: "claude", lastSuccess: now.addingTimeInterval(-86_401), state: .ok).markingStale(now: now).state,
            .stale
        )
        XCTAssertEqual(SourceHealth(sourceID: "claude", lastSuccess: nil, state: .ok).markingStale(now: now).state, .stale)
        XCTAssertEqual(
            SourceHealth(sourceID: "claude", lastSuccess: nil, state: .notInstalled).markingStale(now: now).state,
            .notInstalled
        )
    }

    func testReaderRejectsInvalidPayloadInvariantsAndUnreferencedFilesAreIgnored() throws {
        try publish(other)
        let backend = SyncBackend(root: directory)
        let strayRecord = record(device: other, day: "2026-09-15", input: 500)
        try backend.write(
            SyncSnapshot.encode(DailySyncSnapshot(records: [strayRecord])),
            to: "v1/devices/device-b/usage-2026-09.json"
        )
        try backend.write(Data("temp".utf8), to: "v1/devices/device-b/.orphan.tmp")
        let withStray = try XCTUnwrap(read().first)
        XCTAssertEqual(withStray.status.state, .ok)
        XCTAssertEqual(withStray.daily, [record(device: other)])

        let updatedDaily = record(device: other, input: 250)
        let updatedHourly = HourlyUsage(
            hourStart: hour(device: other).hourStart,
            deviceID: other.id,
            sourceID: "claude",
            counts: TokenCounts(input: 9, output: 11, uncategorized: 0),
            eventCount: 4,
            reasoningKnown: true
        )
        try ICloudSync.write(
            local: FixtureStore(devices: [other], daily: [updatedDaily], hours: [updatedHourly]),
            device: other,
            root: directory,
            appVersion: "1.0",
            now: now.addingTimeInterval(30)
        )
        let replaced = try XCTUnwrap(read().first)
        XCTAssertEqual(replaced.daily, [updatedDaily])
        XCTAssertEqual(replaced.hourly, [updatedHourly])

        let duplicateDaily = FixtureStore(
            devices: [other],
            daily: [record(device: other, input: 10), record(device: other, input: 20)],
            hours: [hour(device: other)]
        )
        try ICloudSync.write(local: duplicateDaily, device: other, root: directory, appVersion: "1.0", now: now)
        let afterDuplicateDaily = try XCTUnwrap(read().first)
        XCTAssertEqual(afterDuplicateDaily.status.state, .partial)
        XCTAssertTrue(afterDuplicateDaily.daily.isEmpty)
        XCTAssertEqual(afterDuplicateDaily.hourly, [hour(device: other)])

        let duplicateHourly = FixtureStore(
            devices: [other],
            daily: [record(device: other)],
            hours: [hour(device: other), hour(device: other)]
        )
        try ICloudSync.write(local: duplicateHourly, device: other, root: directory, appVersion: "1.0", now: now)
        let afterDuplicateHourly = try XCTUnwrap(read().first)
        XCTAssertEqual(afterDuplicateHourly.status.state, .partial)
        XCTAssertEqual(afterDuplicateHourly.daily, [record(device: other)])
        XCTAssertTrue(afterDuplicateHourly.hourly.isEmpty)
    }

    func testMergedStoreIgnoresDuplicateRemoteIDsAndForeignDeviceRecordsAndUncategorizedIsUnpriced() throws {
        let foreignDevice = Device(id: "device-c", name: "Foreign Mac")
        let firstRemote = RemoteDeviceSnapshot(
            device: other,
            daily: [record(device: other, input: 100), record(device: foreignDevice, input: 999)],
            hourly: [hour(device: other), hour(device: foreignDevice)],
            status: RemoteDeviceStatus(deviceID: other.id, displayName: other.name, lastWrite: now, state: .ok)
        )
        let duplicateRemote = RemoteDeviceSnapshot(
            device: other,
            daily: [record(device: other, input: 500)],
            hourly: [],
            status: RemoteDeviceStatus(deviceID: other.id, displayName: "Duplicate", lastWrite: now, state: .ok)
        )
        let localRecord = UsageRecord(
            day: "2026-11-09",
            timeZoneID: "Asia/Shanghai",
            deviceID: local.id,
            sourceID: "claude",
            modelID: "model-a",
            counts: TokenCounts(input: 100, cacheRead: 20, cacheWrite: 10, output: 30, reasoning: 5, uncategorized: 0),
            eventCount: 1
        )
        let localOnlyStore = FixtureStore(devices: [local], daily: [localRecord], hours: [hour(device: local)])
        let merged = MergedUsageStore(local: localOnlyStore, remote: [firstRemote, duplicateRemote])
        XCTAssertEqual(merged.devices, [local, other])
        XCTAssertEqual(try merged.records(), [localRecord, record(device: other, input: 100)])
        XCTAssertEqual(try merged.hourly(), [hour(device: local), hour(device: other)])

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let localSummary = try UsageAggregator(store: localOnlyStore, calendar: calendar, now: now, priceTable: .synthetic).summary(for: .all)
        let mergedSummary = try UsageAggregator(store: merged, calendar: calendar, now: now, priceTable: .synthetic).summary(for: .all)
        XCTAssertEqual(mergedSummary.total.uncategorized, 7)
        XCTAssertEqual(mergedSummary.cost.estimatedUSD, localSummary.cost.estimatedUSD * 2, accuracy: 1e-9)
        XCTAssertEqual(mergedSummary.cost.unpricedTokens, localSummary.cost.unpricedTokens * 2 + 7)
    }

    func testBackendWritesUnderMissingRootBelowSymlinkedAncestor() throws {
        let real = directory.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let backend = SyncBackend(root: link.appendingPathComponent("Token Taken", isDirectory: true))
        try backend.write(Data("ok".utf8), to: "v1/devices/x/device.json")
        XCTAssertEqual(try backend.read("v1/devices/x/device.json"), Data("ok".utf8))
    }

    func testBackendRejectsSymlinkEscapeAndLocalDevicePersistsUUID() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.json"))

        let symlink = directory.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        let backend = SyncBackend(root: directory)
        XCTAssertThrowsError(try backend.read("escape/secret.json")) { error in
            guard case SyncError.invalidSnapshot = error else {
                return XCTFail("Expected SyncError.invalidSnapshot, got \(error)")
            }
        }
        XCTAssertThrowsError(try backend.write(Data("out".utf8), to: "escape/out.json")) { error in
            guard case SyncError.invalidSnapshot = error else {
                return XCTFail("Expected SyncError.invalidSnapshot, got \(error)")
            }
        }

        let supportDir = directory.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let suiteName = "TokenTakenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(LocalDevice.storedID(supportDirectory: supportDir))
        let created = LocalDevice.current(defaults: defaults, supportDirectory: supportDir)
        XCTAssertNotNil(UUID(uuidString: created.id))
        XCTAssertEqual(LocalDevice.storedID(supportDirectory: supportDir), created.id)
        XCTAssertEqual(LocalDevice.current(defaults: defaults, supportDirectory: supportDir).id, created.id)
    }

    func testWriterRejectsFutureIdentitySchemaBeforeDecodingV1Fields() throws {
        let backend = SyncBackend(root: directory)
        try backend.write(Data(#"{"schemaVersion":99}"#.utf8), to: "v1/devices/device-a/device.json")
        XCTAssertThrowsError(try publish(local)) { error in
            guard case SyncError.unsupportedSchema = error else {
                return XCTFail("Expected SyncError.unsupportedSchema, got \(error)")
            }
        }
    }

    func testReaderDropsHourlyRowsOutsideWriterWindowWithoutMakingDevicePartial() throws {
        try publish(other)
        // A writer in a half-hour zone (e.g. UTC+5:30) starts its current hour at :30 UTC; it must survive.
        let halfHour = HourlyUsage(hourStart: now, deviceID: other.id, sourceID: "claude",
            counts: TokenCounts(input: 2, output: 3, uncategorized: 1), eventCount: 2, reasoningKnown: false)
        let backend = SyncBackend(root: directory)
        let rows = [
            hour(device: other, offset: -48),
            hour(device: other, offset: -47),
            hour(device: other),
            halfHour,
            hour(device: other, offset: 1),
        ]
        let hourlyData = try SyncSnapshot.encode(HourlySyncSnapshot(records: rows))
        try backend.write(hourlyData, to: "v1/devices/device-b/hourly.json")

        let metadataPath = "v1/devices/device-b/device.json"
        let metadata = try SyncSnapshot.decode(DeviceSyncSnapshot.self, from: backend.read(metadataPath))
        var files = metadata.files
        files["hourly.json"] = SHA256.hash(data: hourlyData).map { String(format: "%02x", $0) }.joined()
        let updated = DeviceSyncSnapshot(
            device: other,
            appVersion: metadata.appVersion,
            lastWriteUTC: metadata.lastWriteUTC,
            tombstone: metadata.tombstone,
            files: files,
            sources: metadata.sources
        )
        try backend.write(SyncSnapshot.encode(updated), to: metadataPath)

        let remote = try XCTUnwrap(read().first)
        XCTAssertEqual(Set(remote.hourly), Set([hour(device: other, offset: -47), hour(device: other), halfHour]))
        XCTAssertEqual(remote.daily, [record(device: other)])
        XCTAssertEqual(remote.status.state, .ok)
    }

    func testLocalDeviceReplacesInvalidDefaultsUUID() throws {
        let supportDir = directory.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let suiteName = "TokenTakenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("not-a-uuid", forKey: "deviceID")

        let created = LocalDevice.current(defaults: defaults, supportDirectory: supportDir)
        XCTAssertNotNil(UUID(uuidString: created.id))
        XCTAssertNotEqual(created.id, "not-a-uuid")
        XCTAssertEqual(defaults.string(forKey: "deviceID"), created.id)
        XCTAssertEqual(LocalDevice.storedID(supportDirectory: supportDir), created.id)
    }

    func testSyncRootEnvironmentOverride() throws {
        let manager = FileManager.default
        let key = "TOKEN_TAKEN_SYNC_ROOT"
        let root = directory.appendingPathComponent("sync", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(ICloudSync.root(environment: [key: root.path], fileManager: manager), root)

        let missing = directory.appendingPathComponent("missing", isDirectory: true)
        XCTAssertNil(ICloudSync.root(environment: [key: missing.path], fileManager: manager))
        XCTAssertFalse(manager.fileExists(atPath: missing.path))

        let drive = manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDirectory: ObjCBool = false
        let expected = manager.fileExists(atPath: drive.path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? drive.appendingPathComponent("Token Taken", isDirectory: true)
            : nil
        XCTAssertEqual(ICloudSync.root(environment: [:], fileManager: manager), expected)
        XCTAssertEqual(ICloudSync.root(environment: [key: ""], fileManager: manager), expected)
    }

    func testReaderAcceptsHourlyRowsWithinClockSkewTolerance() throws {
        try publish(other)
        let withinSkew = HourlyUsage(
            hourStart: now.addingTimeInterval(300),
            deviceID: other.id,
            sourceID: "claude",
            counts: TokenCounts(input: 4, output: 5, uncategorized: 1),
            eventCount: 1,
            reasoningKnown: false
        )
        let beyondSkew = HourlyUsage(
            hourStart: now.addingTimeInterval(301),
            deviceID: other.id,
            sourceID: "claude",
            counts: TokenCounts(input: 8, output: 9, uncategorized: 1),
            eventCount: 1,
            reasoningKnown: false
        )
        let backend = SyncBackend(root: directory)
        let rows = [hour(device: other), withinSkew, beyondSkew]
        let hourlyData = try SyncSnapshot.encode(HourlySyncSnapshot(records: rows))
        try backend.write(hourlyData, to: "v1/devices/device-b/hourly.json")

        let metadataPath = "v1/devices/device-b/device.json"
        let metadata = try SyncSnapshot.decode(DeviceSyncSnapshot.self, from: backend.read(metadataPath))
        var files = metadata.files
        files["hourly.json"] = SHA256.hash(data: hourlyData).map { String(format: "%02x", $0) }.joined()
        let updated = DeviceSyncSnapshot(
            device: other,
            appVersion: metadata.appVersion,
            lastWriteUTC: metadata.lastWriteUTC,
            tombstone: metadata.tombstone,
            files: files,
            sources: metadata.sources
        )
        try backend.write(SyncSnapshot.encode(updated), to: metadataPath)

        let remote = try XCTUnwrap(read().first)
        XCTAssertEqual(Set(remote.hourly), Set([hour(device: other), withinSkew]))
        XCTAssertEqual(remote.status.state, .ok)
    }

    func testUnknownSourceHealthStateDecodesAsFailedWithoutDroppingRemoteDevice() throws {
        let decoded = try JSONDecoder().decode(SourceHealth.State.self, from: Data(#""futureState""#.utf8))
        XCTAssertEqual(decoded, .failed)
        XCTAssertEqual(String(data: try JSONEncoder().encode(SourceHealth.State.failed), encoding: .utf8), #""failed""#)

        try ICloudSync.write(
            local: store(device: other),
            device: other,
            root: directory,
            appVersion: "1.0",
            health: [SourceHealth(sourceID: "claude", lastSuccess: now, state: .ok)],
            now: now
        )
        let backend = SyncBackend(root: directory)
        let metadataPath = "v1/devices/device-b/device.json"
        let original = String(decoding: try backend.read(metadataPath), as: UTF8.self)
        XCTAssertTrue(original.contains(#""state":"ok""#))
        let future = original.replacingOccurrences(of: #""state":"ok""#, with: #""state":"rateLimited""#)
        try backend.write(Data(future.utf8), to: metadataPath)

        let remote = try XCTUnwrap(read().first)
        XCTAssertEqual(remote.status.state, .partial)
        XCTAssertEqual(remote.status.displayName, other.name)
        XCTAssertEqual(remote.status.lastWrite, now)
        XCTAssertEqual(remote.daily, [record(device: other)])
        XCTAssertEqual(remote.hourly, [hour(device: other)])
    }
}

private struct FixtureStore: UsageStore {
    let devices: [Device]
    let daily: [UsageRecord]
    let hours: [HourlyUsage]
    func records() -> [UsageRecord] { daily }
    func hourly() -> [HourlyUsage] { hours }
}
