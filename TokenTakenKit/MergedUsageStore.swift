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
        let accounts = try resolvedAccounts()
        let accountIDs = Set(accounts.map(\.deviceID))
        var rows = try local.records().filter { !accountIDs.contains($0.deviceID) }
        rows += accounts.flatMap(\.daily)
        rows += remote.flatMap { snapshot in
            snapshot.daily.filter { $0.deviceID == snapshot.device.id }
        }
        return rows
    }

    public func hourly() throws -> [HourlyUsage] {
        let accounts = try resolvedAccounts()
        let accountIDs = Set(accounts.map(\.deviceID))
        var rows = try local.hourly().filter { !accountIDs.contains($0.deviceID) }
        rows += accounts.flatMap(\.hourly)
        rows += remote.flatMap { snapshot in
            snapshot.hourly.filter { $0.deviceID == snapshot.device.id }
        }
        return rows
    }

    public var devices: [Device] {
        var result = local.devices
        var seen = Set(result.map(\.id))
        var accountDevices: [String: Device] = [:]
        for snapshot in remote {
            if seen.insert(snapshot.device.id).inserted { result.append(snapshot.device) }
            guard snapshot.status.state != .unavailable else { continue }
            for publication in snapshot.accounts where !seen.contains(publication.device.id) {
                accountDevices[publication.device.id] = accountDevices[publication.device.id] ?? publication.device
            }
        }
        result.append(contentsOf: accountDevices.keys.sorted().compactMap { accountDevices[$0] })
        return result
    }

    /// One candidate is the local store's rows for the account; every usable peer publication is
    /// another. Account history has a single authority, so exactly one publication is counted.
    private struct AccountCandidate {
        let deviceID: String
        /// Nil for the local store, which wins ties over peers.
        let publisherID: String?
        let collectedAt: Date
        let daily: [UsageRecord]
        let hourly: [HourlyUsage]

        var isLocal: Bool { publisherID == nil }
    }

    private func resolvedAccounts() throws -> [AccountCandidate] {
        let localRows = try local.records()
        let localHours = try local.hourly()
        let accountIDs = Set(local.devices.filter { $0.kind == .account }.map(\.id))
            .union(localRows.map(\.deviceID).filter(AccountDeviceID.isAccount))
            .union(localHours.map(\.deviceID).filter(AccountDeviceID.isAccount))
            .union(remote.flatMap { $0.accounts.map(\.device.id) })
        guard !accountIDs.isEmpty else { return [] }

        let health: [SourceHealth]
        if let store = local as? SQLiteUsageStore, let values = try? store.health() {
            health = values
        } else {
            health = []
        }
        let collectedAt = SourceCatalog.accountSourceIDs
            .compactMap { id in health.first { $0.sourceID == id }?.lastSuccess }
            .max()

        var chosen: [AccountCandidate] = []
        for id in accountIDs.sorted() {
            var candidates: [AccountCandidate] = []
            let daily = localRows.filter { $0.deviceID == id }
            let hourly = localHours.filter { $0.deviceID == id }
            if !daily.isEmpty || !hourly.isEmpty {
                // A store without health rows publishes nothing, so its own rows date as unknown and
                // lose to any usable peer publication.
                candidates.append(AccountCandidate(deviceID: id, publisherID: nil,
                    collectedAt: collectedAt ?? .distantPast, daily: daily, hourly: hourly))
            }
            for snapshot in remote where snapshot.status.state != .unavailable {
                for publication in snapshot.accounts where publication.device.id == id {
                    candidates.append(AccountCandidate(deviceID: id, publisherID: publication.publisherID,
                        collectedAt: publication.collectedAt, daily: publication.daily, hourly: publication.hourly))
                }
            }
            if let winner = candidates.max(by: Self.loses) { chosen.append(winner) }
        }
        return chosen
    }

    /// Latest collection wins; on a tie the local store wins, then the lowest publisher ID.
    private static func loses(_ lhs: AccountCandidate, _ rhs: AccountCandidate) -> Bool {
        if lhs.collectedAt != rhs.collectedAt { return lhs.collectedAt < rhs.collectedAt }
        if lhs.isLocal != rhs.isLocal { return !lhs.isLocal }
        return (lhs.publisherID ?? "") > (rhs.publisherID ?? "")
    }
}
