import CryptoKit
import XCTest
@testable import TokenTakenKit

final class AccountSyncTests: XCTestCase {
    private var directory: URL!
    private let publisher = Device(id: "device-a", name: "Desk Mac")
    private let otherPublisher = Device(id: "device-b", name: "Travel Mac")
    private let account = Device(
        id: "account-cursor-0123456789abcdef0123456789abcdef",
        name: "Cursor (account)",
        kind: .account
    )
    private var accountID: String { account.id }
    private var shortID: String { String(account.id.suffix(32)) }
    private var now: Date { ISO8601DateFormatter().date(from: "2026-11-09T10:30:00Z")! }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Fixtures

    private func record(
        deviceID: String, source: String = "cursor", day: String = "2026-11-09",
        zone: String = "UTC", input: Int64 = 100
    ) -> UsageRecord {
        UsageRecord(day: day, timeZoneID: zone, deviceID: deviceID, sourceID: source,
            modelID: "model-a", rawModelID: "Raw-model-a",
            counts: TokenCounts(input: input, cacheRead: 20, cacheWrite: 10, output: 30, reasoning: 0, uncategorized: 5),
            eventCount: 3)
    }

    private func hour(deviceID: String, source: String = "cursor", offset: Int = 0) -> HourlyUsage {
        let start = Calendar.current.dateInterval(of: .hour, for: now)!.start
        return HourlyUsage(hourStart: start.addingTimeInterval(Double(offset) * 3_600), deviceID: deviceID,
            sourceID: source, counts: TokenCounts(input: 2, output: 3, uncategorized: 1), eventCount: 2,
            reasoningKnown: false)
    }

    private func snapshot(
        _ device: Device, daily: [UsageRecord] = [], hourly: [HourlyUsage] = [],
        state: RemoteDeviceStatus.State = .ok, accounts: [RemoteAccountPublication] = []
    ) -> RemoteDeviceSnapshot {
        RemoteDeviceSnapshot(
            device: device, daily: daily, hourly: hourly,
            status: RemoteDeviceStatus(deviceID: device.id, displayName: device.name, lastWrite: now, state: state),
            accounts: accounts
        )
    }

    private func publication(
        publisherID: String, collectedAt: Date, daily: [UsageRecord], hourly: [HourlyUsage]
    ) -> RemoteAccountPublication {
        RemoteAccountPublication(device: account, publisherID: publisherID, collectedAt: collectedAt,
            daily: daily, hourly: hourly)
    }

    private func publish(
        daily: [UsageRecord], hourly: [HourlyUsage], devices: [Device]? = nil,
        health: [SourceHealth], at date: Date? = nil
    ) throws {
        let store = AccountFixtureStore(
            devices: devices ?? [publisher, account], daily: daily, hours: hourly
        )
        try ICloudSync.write(local: store, device: publisher, root: directory, appVersion: "1.0",
            health: health, now: date ?? now)
    }

    private func read() -> [RemoteDeviceSnapshot] {
        ICloudSync.readRemote(root: directory, excludingDeviceID: "device-z", now: now)
    }

    private func identityPath(_ deviceID: String) -> String { "v1/devices/\(deviceID)/device.json" }

    private func accountFile(_ name: String) -> URL {
        directory.appendingPathComponent("v1/devices/\(publisher.id)/\(name)")
    }

    // MARK: - Publication round trip

    func testAccountPublicationRoundTripsInsideThePublishersOwnFolder() throws {
        let macDay = record(deviceID: publisher.id, source: "claude")
        let cursorDay = record(deviceID: accountID)
        let macHour = hour(deviceID: publisher.id, source: "claude")
        let cursorHour = hour(deviceID: accountID, offset: -1)
        let success = now.addingTimeInterval(-600)
        let health = [SourceHealth(sourceID: "cursor", lastSuccess: success, state: .ok)]
        try publish(daily: [macDay, cursorDay], hourly: [macHour, cursorHour], health: health)

        let backend = SyncBackend(root: directory)
        let manifest = try SyncSnapshot.decode(
            DeviceSyncSnapshot.self, from: backend.read(identityPath(publisher.id))
        )
        XCTAssertEqual(Set(manifest.files.keys), Set(["hourly.json", "usage-2026-11.json"]))
        XCTAssertEqual(manifest.accounts.count, 1)
        let published = try XCTUnwrap(manifest.accounts.first)
        XCTAssertEqual(published.deviceId, accountID)
        XCTAssertEqual(published.displayName, account.name)
        XCTAssertEqual(published.kind, "account")
        XCTAssertEqual(published.sources, ["cursor"])
        XCTAssertEqual(published.collectedAtUTC, success)
        XCTAssertEqual(Set(published.files.keys), Set([
            "account-\(shortID)-hourly.json",
            "account-\(shortID)-usage-2026-11.json"
        ]))

        let remote = try XCTUnwrap(read().first)
        XCTAssertEqual(remote.device, publisher)
        XCTAssertEqual(remote.daily, [macDay])
        XCTAssertEqual(remote.hourly, [macHour])
        XCTAssertEqual(remote.status.state, .ok)
        XCTAssertEqual(remote.accounts.count, 1)
        let publication = try XCTUnwrap(remote.accounts.first)
        XCTAssertEqual(publication.device, account)
        XCTAssertEqual(publication.publisherID, publisher.id)
        XCTAssertEqual(publication.collectedAt, success)
        XCTAssertEqual(publication.daily, [cursorDay])
        XCTAssertEqual(publication.hourly, [cursorHour])
    }

    func testUnchangedAccountFilesAreNotRewritten() throws {
        let health = [SourceHealth(sourceID: "cursor", lastSuccess: now, state: .ok)]
        try publish(daily: [record(deviceID: accountID)], hourly: [hour(deviceID: accountID)], health: health)
        let month = accountFile("account-\(shortID)-usage-2026-11.json")
        let oldDate = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: month.path)
        try publish(daily: [record(deviceID: accountID)], hourly: [hour(deviceID: accountID)],
            health: health, at: now.addingTimeInterval(60))
        let attributes = try FileManager.default.attributesOfItem(atPath: month.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, oldDate)
        XCTAssertEqual(read().first?.accounts.first?.collectedAt, now)
    }

    func testAccountWithoutSuccessfulCollectionIsNotPublished() throws {
        let macDay = record(deviceID: publisher.id, source: "claude")
        try publish(daily: [macDay, record(deviceID: accountID)], hourly: [], health: [])
        let remote = try XCTUnwrap(read().first)
        XCTAssertTrue(remote.accounts.isEmpty)
        XCTAssertEqual(remote.daily, [macDay])
        XCTAssertEqual(remote.status.state, .ok)
    }

    func testWithdrawnAccountFilesStayOnDiskButLeaveTheManifest() throws {
        let health = [SourceHealth(sourceID: "cursor", lastSuccess: now, state: .ok)]
        let macDay = record(deviceID: publisher.id, source: "claude")
        try publish(daily: [macDay, record(deviceID: accountID)], hourly: [hour(deviceID: accountID)], health: health)
        XCTAssertEqual(read().first?.accounts.count, 1)

        try publish(daily: [macDay], hourly: [], health: health, at: now.addingTimeInterval(60))
        let remote = try XCTUnwrap(read().first)
        XCTAssertTrue(remote.accounts.isEmpty)
        XCTAssertEqual(remote.daily, [macDay])
        // Unreferenced files are ignored by readers, not deleted by the single writer.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: accountFile("account-\(shortID)-usage-2026-11.json").path
        ))
    }

    // MARK: - Reader compatibility

    func testManifestWithoutAccountsDecodesAsEmpty() throws {
        let json = #"{"appVersion":"1.0","deviceId":"device-a","displayName":"Desk Mac","files":{},"lastWriteUTC":"2026-11-09T10:30:00Z","schemaVersion":1,"sources":[],"tombstone":false}"#
        let decoded = try SyncSnapshot.decode(DeviceSyncSnapshot.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.accounts.isEmpty)
        let roundTrip = try SyncSnapshot.decode(
            DeviceSyncSnapshot.self, from: SyncSnapshot.encode(decoded)
        )
        XCTAssertTrue(roundTrip.accounts.isEmpty)
    }

    func testTopLevelFilesWhitelistRejectsAccountNamesAndIgnoresUnreferencedFiles() throws {
        let health = [SourceHealth(sourceID: "cursor", lastSuccess: now, state: .ok)]
        let macDay = record(deviceID: publisher.id, source: "claude")
        try publish(daily: [macDay, record(deviceID: accountID)], hourly: [hour(deviceID: accountID)], health: health)

        let backend = SyncBackend(root: directory)
        let stray = record(deviceID: accountID, day: "2026-09-01", input: 999)
        try backend.write(
            SyncSnapshot.encode(DailySyncSnapshot(records: [stray])),
            to: "v1/devices/\(publisher.id)/account-\(shortID)-usage-2026-09.json"
        )
        let withStray = try XCTUnwrap(read().first)
        XCTAssertEqual(withStray.daily, [macDay])
        XCTAssertEqual(withStray.accounts.first?.daily, [record(deviceID: accountID)])

        let path = identityPath(publisher.id)
        let manifest = try SyncSnapshot.decode(DeviceSyncSnapshot.self, from: backend.read(path))
        let listedAsMacFile = DeviceSyncSnapshot(
            device: publisher, appVersion: manifest.appVersion, lastWriteUTC: manifest.lastWriteUTC,
            files: ["account-\(shortID)-hourly.json": "deadbeef"], sources: manifest.sources,
            accounts: manifest.accounts
        )
        try backend.write(SyncSnapshot.encode(listedAsMacFile), to: path)
        let rejected = try XCTUnwrap(read().first)
        XCTAssertEqual(rejected.status.state, .unavailable)
        XCTAssertTrue(rejected.daily.isEmpty)
        XCTAssertTrue(rejected.accounts.isEmpty)
    }

    func testCorruptedAccountFileOmitsThePublicationAndKeepsMacRows() throws {
        let health = [SourceHealth(sourceID: "cursor", lastSuccess: now, state: .ok)]
        let macDay = record(deviceID: publisher.id, source: "claude")
        let macHour = hour(deviceID: publisher.id, source: "claude")
        try publish(daily: [macDay, record(deviceID: accountID)], hourly: [macHour, hour(deviceID: accountID)], health: health)

        try Data("corrupted".utf8).write(to: accountFile("account-\(shortID)-usage-2026-11.json"))
        let corrupted = try XCTUnwrap(read().first)
        XCTAssertTrue(corrupted.accounts.isEmpty)
        XCTAssertEqual(corrupted.daily, [macDay])
        XCTAssertEqual(corrupted.hourly, [macHour])
        XCTAssertEqual(corrupted.status.state, .ok)
    }

    func testUndownloadedAccountFileOmitsThePublication() throws {
        let health = [SourceHealth(sourceID: "cursor", lastSuccess: now, state: .ok)]
        try publish(daily: [record(deviceID: accountID)], hourly: [hour(deviceID: accountID)], health: health)
        let name = "account-\(shortID)-hourly.json"
        try FileManager.default.removeItem(at: accountFile(name))
        try SyncBackend(root: directory).write(Data(), to: "v1/devices/\(publisher.id)/.\(name).icloud")
        let remote = try XCTUnwrap(read().first)
        XCTAssertTrue(remote.accounts.isEmpty)
        XCTAssertEqual(remote.status.state, .ok)

        let noDownload = ICloudSync.readRemote(
            root: directory, excludingDeviceID: "device-z", now: now, requestDownloads: false
        )
        XCTAssertTrue(noDownload.first?.accounts.isEmpty ?? false)
    }

    // MARK: - Merge

    func testMergeCountsTheAccountOnceAndPrefersTheNewerPublicationAcrossZones() throws {
        let older = publication(
            publisherID: otherPublisher.id, collectedAt: now.addingTimeInterval(-3_600),
            daily: [record(deviceID: accountID, zone: "Asia/Shanghai", input: 10)],
            hourly: [hour(deviceID: accountID, offset: -2)]
        )
        let newer = publication(
            publisherID: publisher.id, collectedAt: now,
            daily: [record(deviceID: accountID, zone: "UTC", input: 90)],
            hourly: [hour(deviceID: accountID, offset: -1)]
        )
        let merged = MergedUsageStore(
            local: AccountFixtureStore(devices: [], daily: [], hours: []),
            remote: [
                snapshot(otherPublisher, accounts: [older]),
                snapshot(publisher, accounts: [newer])
            ]
        )
        XCTAssertEqual(try merged.records(), [record(deviceID: accountID, zone: "UTC", input: 90)])
        XCTAssertEqual(try merged.hourly(), [hour(deviceID: accountID, offset: -1)])
    }

    func testMergeTieGoesToTheLowestPublisherIDRegardlessOfOrder() throws {
        let thirdPublisher = Device(id: "device-c", name: "Studio Mac")
        let fromB = publication(publisherID: otherPublisher.id, collectedAt: now,
            daily: [record(deviceID: accountID, input: 11)], hourly: [])
        let fromC = publication(publisherID: thirdPublisher.id, collectedAt: now,
            daily: [record(deviceID: accountID, input: 22)], hourly: [])
        let merged = MergedUsageStore(
            local: AccountFixtureStore(devices: [], daily: [], hours: []),
            remote: [snapshot(thirdPublisher, accounts: [fromC]), snapshot(otherPublisher, accounts: [fromB])]
        )
        XCTAssertEqual(try merged.records(), [record(deviceID: accountID, input: 11)])
    }

    func testRemotePublicationReplacesLocallyCollectedAccountRows() throws {
        let store = try sqliteStore(lastSuccess: now.addingTimeInterval(-3_600))
        let remote = publication(publisherID: otherPublisher.id, collectedAt: now,
            daily: [record(deviceID: accountID, input: 77)], hourly: [hour(deviceID: accountID, offset: -1)])
        let merged = MergedUsageStore(local: store, remote: [snapshot(otherPublisher, accounts: [remote])])
        XCTAssertEqual(try merged.records().filter { $0.deviceID == accountID },
            [record(deviceID: accountID, input: 77)])
        XCTAssertEqual(try merged.hourly().filter { $0.deviceID == accountID }, [hour(deviceID: accountID, offset: -1)])
    }

    func testLocalAccountRowsWinWhenLocalCollectionIsNewestOrTied() throws {
        let store = try sqliteStore(lastSuccess: now)
        let stalePeer = publication(publisherID: otherPublisher.id, collectedAt: now.addingTimeInterval(-60),
            daily: [record(deviceID: accountID, input: 77)], hourly: [])
        let tiedPeer = publication(publisherID: otherPublisher.id, collectedAt: now,
            daily: [record(deviceID: accountID, input: 88)], hourly: [])
        let merged = MergedUsageStore(local: store, remote: [snapshot(otherPublisher, accounts: [stalePeer, tiedPeer])])
        XCTAssertEqual(try merged.records().filter { $0.deviceID == accountID },
            [record(deviceID: accountID, input: 42)])
    }

    func testMacRowsStaySummedWhileTheAccountCountsOnce() throws {
        let localMacDay = record(deviceID: publisher.id, source: "claude", input: 1)
        let localStore = AccountFixtureStore(
            devices: [publisher, account], daily: [localMacDay, record(deviceID: accountID, input: 5)],
            hours: [hour(deviceID: accountID, offset: -3)]
        )
        let peerMacDay = record(deviceID: otherPublisher.id, source: "claude", input: 2)
        let peerAccount = publication(publisherID: otherPublisher.id, collectedAt: now.addingTimeInterval(600),
            daily: [record(deviceID: accountID, input: 9)], hourly: [hour(deviceID: accountID, offset: -1)])
        let merged = MergedUsageStore(local: localStore, remote: [
            snapshot(otherPublisher, daily: [peerMacDay], accounts: [peerAccount])
        ])
        XCTAssertEqual(Set(try merged.records()), Set([
            localMacDay, peerMacDay, record(deviceID: accountID, input: 9)
        ]))
        XCTAssertEqual(Set(try merged.hourly()), Set([hour(deviceID: accountID, offset: -1)]))
    }

    func testMergedDevicesListEachAccountOnce() throws {
        let store = try sqliteStore(lastSuccess: now)
        let merged = MergedUsageStore(local: store, remote: [
            snapshot(otherPublisher, accounts: [
                publication(publisherID: otherPublisher.id, collectedAt: now,
                    daily: [record(deviceID: accountID)], hourly: [])
            ]),
            snapshot(publisher, accounts: [
                publication(publisherID: publisher.id, collectedAt: now.addingTimeInterval(-60),
                    daily: [record(deviceID: accountID)], hourly: [])
            ])
        ])
        let ids = merged.devices.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertEqual(ids.filter { $0 == accountID }.count, 1)
        XCTAssertEqual(merged.devices.first { $0.id == accountID }?.kind, .account)
        XCTAssertEqual(merged.devices.first { $0.id == accountID }?.name, account.name)
    }

    func testUnavailablePeerPublicationIsIgnoredAndDoesNotEraseLocalAccountRows() throws {
        let store = try sqliteStore(lastSuccess: now.addingTimeInterval(-3_600))
        let merged = MergedUsageStore(local: store, remote: [
            snapshot(otherPublisher, state: .unavailable, accounts: [
                publication(publisherID: otherPublisher.id, collectedAt: now.addingTimeInterval(600),
                    daily: [record(deviceID: accountID, input: 99)], hourly: [])
            ])
        ])
        XCTAssertEqual(try merged.records().filter { $0.deviceID == accountID },
            [record(deviceID: accountID, input: 42)])
    }

    func testMergedStoreReadsTheLocalStoreOncePerCall() throws {
        let local = CountingAccountStore(
            devices: [publisher, account],
            daily: [record(deviceID: publisher.id, source: "claude"), record(deviceID: accountID)],
            hours: [hour(deviceID: accountID, offset: -1)]
        )
        let merged = MergedUsageStore(local: local, remote: [
            snapshot(otherPublisher, accounts: [
                publication(publisherID: otherPublisher.id, collectedAt: now,
                    daily: [record(deviceID: accountID, input: 77)], hourly: [hour(deviceID: accountID, offset: -2)])
            ])
        ])
        XCTAssertEqual(Set(try merged.records()), Set([
            record(deviceID: publisher.id, source: "claude"), record(deviceID: accountID, input: 77)
        ]))
        XCTAssertEqual([local.recordReads, local.hourReads], [1, 1])
        XCTAssertEqual(try merged.hourly(), [hour(deviceID: accountID, offset: -2)])
        XCTAssertEqual([local.recordReads, local.hourReads], [2, 2])
    }

    // MARK: - Helpers

    private func sqliteStore(lastSuccess: Date) throws -> SQLiteUsageStore {
        let store = try SQLiteUsageStore(url: directory.appendingPathComponent("usage.sqlite"))
        let mac = Device(id: "device-local", name: "Local Mac")
        try store.upsert(device: mac)
        try store.upsert(device: account)
        let macDay = record(deviceID: mac.id, source: "claude", input: 1)
        try store.replace(batch: CollectionBatch(daily: [macDay], hourly: []), sourceID: "claude", deviceID: mac.id)
        let accountDay = record(deviceID: accountID, input: 42)
        let accountHour = hour(deviceID: accountID, offset: -2)
        try store.replace(batch: CollectionBatch(daily: [accountDay], hourly: [accountHour]),
            sourceID: "cursor", deviceID: accountID)
        try store.record(health: SourceHealth(sourceID: "cursor", lastSuccess: lastSuccess, state: .ok))
        return store
    }
}

private struct AccountFixtureStore: UsageStore {
    let devices: [Device]
    let daily: [UsageRecord]
    let hours: [HourlyUsage]
    func records() -> [UsageRecord] { daily }
    func hourly() -> [HourlyUsage] { hours }
}

/// Counts store reads so a test can prove a merge reads the local store once per call.
private final class CountingAccountStore: UsageStore, @unchecked Sendable {
    let devices: [Device]
    private let daily: [UsageRecord]
    private let hours: [HourlyUsage]
    private(set) var recordReads = 0
    private(set) var hourReads = 0

    init(devices: [Device], daily: [UsageRecord], hours: [HourlyUsage]) {
        self.devices = devices
        self.daily = daily
        self.hours = hours
    }

    func records() -> [UsageRecord] {
        recordReads += 1
        return daily
    }

    func hourly() -> [HourlyUsage] {
        hourReads += 1
        return hours
    }
}
