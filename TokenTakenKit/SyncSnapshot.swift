import Foundation

public struct SyncSourceHealth: Codable, Sendable {
    public let sourceID: String
    public let lastSuccess: Date?
    public let state: SourceHealth.State
    public let skippedRecords: Int

    public init(_ health: SourceHealth) {
        sourceID = health.sourceID
        lastSuccess = health.lastSuccess
        state = health.state
        skippedRecords = health.skippedRecords
    }
}

/// Account-level usage published by a Mac on behalf of an account device it collected.
/// The publishing Mac is still the only writer of its own folder; the account rows travel as an
/// additional record kind inside that folder.
public struct AccountPublication: Codable, Sendable, Equatable {
    /// Account device ID, `account-<source>-<32 lowercase hex>`.
    public let deviceId: String
    public let displayName: String
    /// Always `account`. Readers reject any other value.
    public let kind: String
    /// Account-scoped sources this publication covers.
    public let sources: [String]
    /// Latest successful collection of those sources; dates the whole publication for the merge.
    public let collectedAtUTC: Date
    /// SHA-256 of the exact bytes of every account record-kind file in this publication.
    public let files: [String: String]

    public init(deviceId: String, displayName: String, kind: String = "account",
                sources: [String], collectedAtUTC: Date, files: [String: String]) {
        self.deviceId = deviceId
        self.displayName = displayName
        self.kind = kind
        self.sources = sources.sorted()
        self.collectedAtUTC = collectedAtUTC
        self.files = files
    }
}

public struct DeviceSyncSnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let deviceId: String
    public let displayName: String
    public let appVersion: String
    public let lastWriteUTC: Date
    public let tombstone: Bool
    /// SHA-256 of the exact bytes of every published record-kind file.
    public let files: [String: String]
    public let sources: [SyncSourceHealth]
    public let accounts: [AccountPublication]

    public init(device: Device, appVersion: String, lastWriteUTC: Date, tombstone: Bool = false,
                files: [String: String], sources: [SyncSourceHealth] = [], accounts: [AccountPublication] = []) {
        schemaVersion = 1
        deviceId = device.id
        displayName = device.name
        self.appVersion = appVersion
        self.lastWriteUTC = lastWriteUTC
        self.tombstone = tombstone
        self.files = files
        self.sources = sources.sorted { $0.sourceID < $1.sourceID }
        self.accounts = accounts.sorted { $0.deviceId < $1.deviceId }
    }

    // `accounts` is additive: manifests written before account publications existed decode as empty.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, deviceId, displayName, appVersion, lastWriteUTC, tombstone, files, sources, accounts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        displayName = try container.decode(String.self, forKey: .displayName)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        lastWriteUTC = try container.decode(Date.self, forKey: .lastWriteUTC)
        tombstone = try container.decode(Bool.self, forKey: .tombstone)
        files = try container.decode([String: String].self, forKey: .files)
        sources = try container.decodeIfPresent([SyncSourceHealth].self, forKey: .sources) ?? []
        accounts = try container.decodeIfPresent([AccountPublication].self, forKey: .accounts) ?? []
    }
}

public struct DailySyncSnapshot: Codable, Sendable {
    public let schemaVersion: Int
    /// `counts` carries the optional `cacheWrite1h` subset key. An absent key decodes as zero and a peer
    /// that does not know it ignores it, so no `schemaVersion` bump is needed for that addition.
    public let records: [UsageRecord]

    public init(records: [UsageRecord]) {
        schemaVersion = 1
        self.records = records.sorted { SyncSnapshot.dailyKey($0).lexicographicallyPrecedes(SyncSnapshot.dailyKey($1)) }
    }
}

public struct HourlySyncSnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let records: [HourlyUsage]

    public init(records: [HourlyUsage]) {
        schemaVersion = 1
        self.records = records.sorted {
            if $0.hourStart != $1.hourStart { return $0.hourStart < $1.hourStart }
            return [$0.deviceID, $0.sourceID].lexicographicallyPrecedes([$1.deviceID, $1.sourceID])
        }
    }
}

/// Account device IDs are `account-<source>-<32 lowercase hex>`; the trailing hex names its files.
enum AccountDeviceID {
    static func shortID(_ deviceID: String) -> String? {
        guard deviceID.range(
            of: #"^account-[a-z0-9]+(-[a-z0-9]+)*-[0-9a-f]{32}$"#,
            options: .regularExpression
        ) != nil else { return nil }
        return String(deviceID.suffix(32))
    }

    static func isAccount(_ deviceID: String) -> Bool { shortID(deviceID) != nil }
}

public enum SyncSnapshot {
    public static func encode<T: Encodable>(_ snapshot: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    static func dailyKey(_ record: UsageRecord) -> [String] {
        [record.day, record.deviceID, record.sourceID, record.modelID]
    }
}

public struct RemoteDeviceStatus: Sendable {
    public let deviceID: String
    public let displayName: String
    public let lastWrite: Date?
    public let state: State

    public enum State: String, Sendable {
        case ok, stale, partial, unavailable
    }

    public init(deviceID: String, displayName: String, lastWrite: Date?, state: State) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.lastWrite = lastWrite
        self.state = state
    }
}

/// One Mac's publication of account-level usage. The same account appears once per publishing Mac;
/// the merge keeps exactly one of those publications.
public struct RemoteAccountPublication: Sendable {
    public let device: Device
    /// Device folder ID of the publishing Mac.
    public let publisherID: String
    public let collectedAt: Date
    public let daily: [UsageRecord]
    public let hourly: [HourlyUsage]

    public init(device: Device, publisherID: String, collectedAt: Date,
                daily: [UsageRecord], hourly: [HourlyUsage]) {
        self.device = device
        self.publisherID = publisherID
        self.collectedAt = collectedAt
        self.daily = daily
        self.hourly = hourly
    }
}

public struct RemoteDeviceSnapshot: Sendable {
    public let device: Device
    public let daily: [UsageRecord]
    public let hourly: [HourlyUsage]
    public let status: RemoteDeviceStatus
    /// Account publications this Mac published on behalf of the accounts it collected.
    public let accounts: [RemoteAccountPublication]

    public init(device: Device, daily: [UsageRecord], hourly: [HourlyUsage], status: RemoteDeviceStatus,
                accounts: [RemoteAccountPublication] = []) {
        self.device = device
        self.daily = daily
        self.hourly = hourly
        self.status = status
        self.accounts = accounts
    }

    /// Merges a fresh read with the previous in-memory snapshots.
    public static func mergingCache(_ snapshots: [RemoteDeviceSnapshot], previous: [RemoteDeviceSnapshot]) -> [RemoteDeviceSnapshot] {
        let previous = Dictionary(previous.map { ($0.device.id, $0) }, uniquingKeysWith: { first, _ in first })
        return snapshots.map { snapshot in
            // A stale snapshot still carries its newest data; fall back to the cache only when this read got none.
            // A cached snapshot with no rows (a first-launch placeholder) is never kept, or a permanently
            // partial Mac would stay unknown until relaunch.
            guard snapshot.status.state == .unavailable || snapshot.status.state == .partial,
                  let cached = previous[snapshot.device.id],
                  !cached.daily.isEmpty || !cached.hourly.isEmpty,
                  (cached.status.lastWrite ?? .distantPast) >= (snapshot.status.lastWrite ?? .distantPast) || snapshot.daily.isEmpty
            else { return snapshot }
            // Keep the last write of the publication the cached rows came from, so a later read of that
            // publication is compared against the data's real origin.
            return RemoteDeviceSnapshot(device: cached.device, daily: cached.daily, hourly: cached.hourly, status: RemoteDeviceStatus(
                deviceID: cached.device.id, displayName: cached.device.name,
                lastWrite: cached.status.lastWrite, state: snapshot.status.state), accounts: cached.accounts)
        }
    }
}
