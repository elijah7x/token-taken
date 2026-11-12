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

    public init(device: Device, appVersion: String, lastWriteUTC: Date, tombstone: Bool = false,
                files: [String: String], sources: [SyncSourceHealth] = []) {
        schemaVersion = 1
        deviceId = device.id
        displayName = device.name
        self.appVersion = appVersion
        self.lastWriteUTC = lastWriteUTC
        self.tombstone = tombstone
        self.files = files
        self.sources = sources.sorted { $0.sourceID < $1.sourceID }
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

public struct RemoteDeviceSnapshot: Sendable {
    public let device: Device
    public let daily: [UsageRecord]
    public let hourly: [HourlyUsage]
    public let status: RemoteDeviceStatus

    public init(device: Device, daily: [UsageRecord], hourly: [HourlyUsage], status: RemoteDeviceStatus) {
        self.device = device
        self.daily = daily
        self.hourly = hourly
        self.status = status
    }
}
