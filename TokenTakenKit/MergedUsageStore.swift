import Foundation

public final class MergedUsageStore: UsageStore, @unchecked Sendable {
    private let local: any UsageStore
    private let remote: [RemoteDeviceSnapshot]

    public init(local: any UsageStore, remote: [RemoteDeviceSnapshot]) {
        self.local = local
        let localIDs = Set(local.devices.map(\.id))
        var seen = localIDs
        self.remote = remote.filter { seen.insert($0.device.id).inserted }
    }

    public func records() throws -> [UsageRecord] {
        try local.records() + remote.flatMap { snapshot in
            snapshot.daily.filter { $0.deviceID == snapshot.device.id }
        }
    }

    public func hourly() throws -> [HourlyUsage] {
        try local.hourly() + remote.flatMap { snapshot in
            snapshot.hourly.filter { $0.deviceID == snapshot.device.id }
        }
    }

    public var devices: [Device] {
        local.devices + remote.map(\.device)
    }
}
