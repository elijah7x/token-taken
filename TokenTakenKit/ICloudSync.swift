import CryptoKit
import Foundation

public enum SyncError: Error, Sendable {
    case unavailable
    case invalidSnapshot
    case unsupportedSchema
    case tombstoned
}

public struct SyncBackend: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root.standardizedFileURL }

    public func list(_ path: String = "") throws -> [URL] {
        let url = try resolve(path)
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func read(_ path: String, requestDownloads: Bool = true) throws -> Data {
        let url = try resolve(path)
        let manager = FileManager.default
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        if !manager.fileExists(atPath: url.path), manager.fileExists(atPath: placeholder.path) {
            if requestDownloads { try? manager.startDownloadingUbiquitousItem(at: url) }
            throw SyncError.unavailable
        }
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .isRegularFileKey])
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current {
            if requestDownloads { try? manager.startDownloadingUbiquitousItem(at: url) }
            throw SyncError.unavailable
        }
        guard values.isRegularFile == true, manager.isReadableFile(atPath: url.path) else { throw SyncError.unavailable }
        var coordinationError: NSError?
        var result: Result<Data, any Error> = .failure(SyncError.unavailable)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    public func write(_ data: Data, to path: String) throws {
        let url = try resolve(path)
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var result: Result<Void, any Error> = .failure(SyncError.unavailable)
        // The accessor is synchronous; use its URL and propagate both accessor and coordination failures.
        NSFileCoordinator().coordinate(writingItemAt: url, options: [.forReplacing], error: &coordinationError) { coordinatedURL in
            result = Result {
                let temporary = coordinatedURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
                defer { try? manager.removeItem(at: temporary) }
                try data.write(to: temporary, options: [.withoutOverwriting])
                if manager.fileExists(atPath: coordinatedURL.path) {
                    _ = try manager.replaceItemAt(coordinatedURL, withItemAt: temporary)
                } else {
                    try manager.moveItem(at: temporary, to: coordinatedURL)
                }
            }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    private func resolve(_ path: String) throws -> URL {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw SyncError.invalidSnapshot }
        let url = root.appendingPathComponent(path).standardizedFileURL
        let base = Self.canonical(root).path
        let resolved = Self.canonical(url).path
        guard resolved == base || resolved.hasPrefix(base + "/") else { throw SyncError.invalidSnapshot }
        return url
    }

    // resolvingSymlinksInPath leaves a path untouched when its last component does not exist yet,
    // so resolve the deepest existing ancestor to catch a symlinked folder before a new file is written.
    private static func canonical(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        return missing.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
    }
}

public enum ICloudSync {
    public static var defaultRoot: URL? {
        root(environment: ProcessInfo.processInfo.environment, fileManager: .default)
    }

    static func root(environment: [String: String], fileManager: FileManager) -> URL? {
        if let override = environment["TOKEN_TAKEN_SYNC_ROOT"], !override.isEmpty {
            guard override.hasPrefix("/") else { return nil }
            let url = URL(fileURLWithPath: override, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return url
        }
        let drive = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: drive.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return drive.appendingPathComponent("Token Taken", isDirectory: true)
    }

    public static func write(local: any UsageStore, device: Device, root: URL, appVersion: String,
                             health: [SourceHealth] = [], now: Date = .now) throws {
        guard validDeviceID(device.id) else { throw SyncError.invalidSnapshot }
        let backend = SyncBackend(root: root)
        let folder = "v1/devices/\(device.id)"
        let metadataPath = folder + "/device.json"
        if let data = try? backend.read(metadataPath) {
            guard try schemaVersion(data) == 1 else { throw SyncError.unsupportedSchema }
            let previous = try SyncSnapshot.decode(DeviceSyncSnapshot.self, from: data)
            guard previous.deviceId == device.id else { throw SyncError.invalidSnapshot }
            guard !previous.tombstone else { throw SyncError.tombstoned }
        } else if FileManager.default.fileExists(atPath: root.appendingPathComponent(folder).path) {
            // Do not overwrite an evicted or unreadable identity, which may contain a tombstone.
            let entries = try backend.list(folder)
            if entries.contains(where: { ["device.json", ".device.json.icloud"].contains($0.lastPathComponent) }) {
                throw SyncError.unavailable
            }
        }
        let allDaily = try local.records()
        let allHourly = try local.hourly()
        let daily = allDaily.filter { $0.deviceID == device.id }
        guard daily.allSatisfy({ $0.dayInterval != nil }) else { throw SyncError.invalidSnapshot }
        let window = hourlyWindow(now: now)
        let hourly = allHourly.filter {
            $0.deviceID == device.id && window.contains($0.hourStart)
        }
        var payloads: [String: Data] = [:]
        for (month, records) in Dictionary(grouping: daily, by: { String($0.day.prefix(7)) }) {
            payloads["usage-\(month).json"] = try SyncSnapshot.encode(DailySyncSnapshot(records: records))
        }
        payloads["hourly.json"] = try SyncSnapshot.encode(HourlySyncSnapshot(records: hourly))
        let files = try publish(payloads, folder: folder, backend: backend)
        let accounts = try accountPublications(
            devices: local.devices, daily: allDaily, hourly: allHourly, window: window,
            health: health, folder: folder, backend: backend
        )
        let metadata = DeviceSyncSnapshot(device: device, appVersion: appVersion, lastWriteUTC: now,
            files: files, sources: health.map(SyncSourceHealth.init), accounts: accounts)
        try backend.write(SyncSnapshot.encode(metadata), to: metadataPath)
    }

    /// Publishes account rows this Mac collected, inside its own folder: the device folder keeps exactly
    /// one writer, and readers pick one publication per account device ID.
    private static func accountPublications(
        devices: [Device], daily: [UsageRecord], hourly: [HourlyUsage], window: ClosedRange<Date>,
        health: [SourceHealth], folder: String, backend: SyncBackend
    ) throws -> [AccountPublication] {
        var accounts: [AccountPublication] = []
        for account in devices where account.kind == .account {
            guard let shortID = AccountDeviceID.shortID(account.id) else { continue }
            let rows = daily.filter {
                $0.deviceID == account.id && SourceCatalog.accountSourceIDs.contains($0.sourceID)
            }
            let hours = hourly.filter {
                $0.deviceID == account.id && SourceCatalog.accountSourceIDs.contains($0.sourceID)
                    && window.contains($0.hourStart)
            }
            guard !rows.isEmpty || !hours.isEmpty else { continue }
            guard rows.allSatisfy({ $0.dayInterval != nil }) else { throw SyncError.invalidSnapshot }
            let sources = Set(rows.map(\.sourceID)).union(hours.map(\.sourceID)).sorted()
            // The newest success dates the whole publication. Without one, publish nothing rather than
            // an empty history that could displace a peer's usable publication.
            guard let collectedAt = sources
                .compactMap({ id in health.first { $0.sourceID == id }?.lastSuccess })
                .max()
            else { continue }
            var payloads: [String: Data] = [:]
            for (month, records) in Dictionary(grouping: rows, by: { String($0.day.prefix(7)) }) {
                payloads["account-\(shortID)-usage-\(month).json"] = try SyncSnapshot.encode(
                    DailySyncSnapshot(records: records)
                )
            }
            payloads["account-\(shortID)-hourly.json"] = try SyncSnapshot.encode(HourlySyncSnapshot(records: hours))
            accounts.append(AccountPublication(
                deviceId: account.id, displayName: account.name, sources: sources, collectedAtUTC: collectedAt,
                files: try publish(payloads, folder: folder, backend: backend)
            ))
        }
        return accounts
    }

    private static func publish(_ payloads: [String: Data], folder: String, backend: SyncBackend) throws -> [String: String] {
        var files: [String: String] = [:]
        for name in payloads.keys.sorted() {
            let data = payloads[name]!
            files[name] = digest(data)
            let path = folder + "/" + name
            if (try? backend.read(path)) != data { try backend.write(data, to: path) }
        }
        return files
    }

    public static func readRemote(
        root: URL,
        excludingDeviceID: String,
        requestDownloads: Bool = true
    ) -> [RemoteDeviceSnapshot] {
        readRemote(root: root, excludingDeviceID: excludingDeviceID, now: .now, requestDownloads: requestDownloads)
    }

    public static func readRemote(
        root: URL,
        excludingDeviceID: String,
        now: Date,
        requestDownloads: Bool = true
    ) -> [RemoteDeviceSnapshot] {
        let backend = SyncBackend(root: root)
        guard let folders = try? backend.list("v1/devices") else { return [] }
        return folders.compactMap { folder in
            let id = folder.lastPathComponent
            guard validDeviceID(id), id != excludingDeviceID,
                  (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let path = "v1/devices/\(id)"
            let metadata: DeviceSyncSnapshot
            do {
                let data = try backend.read(path + "/device.json", requestDownloads: requestDownloads)
                guard try schemaVersion(data) == 1 else { return nil }
                metadata = try SyncSnapshot.decode(DeviceSyncSnapshot.self, from: data)
                guard metadata.deviceId == id else { throw SyncError.invalidSnapshot }
                guard !metadata.tombstone else { return nil }
            } catch {
                // The manifest names the payloads, so requesting them together avoids a second retry round on a fresh Mac.
                if requestDownloads { requestFolderDownloads(folder) }
                return unavailable(device: Device(id: id, name: id))
            }
            let device = Device(id: id, name: metadata.displayName)
            var daily: [UsageRecord] = []
            var hourly: [HourlyUsage] = []
            var dailyAvailable = true
            var hourlyAvailable = false
            var unsupported = false
            for (name, hash) in metadata.files.sorted(by: { $0.key < $1.key }) {
                guard name == "hourly.json" || validMonthFile(name) else {
                    return unavailable(device: device, lastWrite: metadata.lastWriteUTC)
                }
                do {
                    let data = try backend.read(path + "/" + name, requestDownloads: requestDownloads)
                    guard try schemaVersion(data) == 1 else { unsupported = true; continue }
                    guard digest(data) == hash else { throw SyncError.invalidSnapshot }
                    if name == "hourly.json" {
                        let snapshot = try SyncSnapshot.decode(HourlySyncSnapshot.self, from: data)
                        guard snapshot.records.allSatisfy({ $0.deviceID == id }),
                              Set(snapshot.records.map { "\($0.sourceID)\u{0}\($0.hourStart.timeIntervalSince1970)" }).count == snapshot.records.count else {
                            throw SyncError.invalidSnapshot
                        }
                        // Use absolute age: the writer's hours may start at a fractional offset (e.g. :30 UTC)
                        // that the reader's own hour rounding would wrongly cut off.
                        let oldest = now.addingTimeInterval(-48 * 3_600)
                        hourly = snapshot.records.filter { $0.hourStart > oldest && $0.hourStart <= now }
                        hourlyAvailable = true
                    } else {
                        let snapshot = try SyncSnapshot.decode(DailySyncSnapshot.self, from: data)
                        let month = String(name.dropFirst(6).prefix(7))
                        guard snapshot.records.allSatisfy({ $0.deviceID == id && $0.dayInterval != nil && $0.day.hasPrefix(month + "-") }),
                              Set(snapshot.records.map { SyncSnapshot.dailyKey($0) }).count == snapshot.records.count else {
                            throw SyncError.invalidSnapshot
                        }
                        daily.append(contentsOf: snapshot.records)
                    }
                } catch {
                    if name == "hourly.json" { hourlyAvailable = false }
                    else { dailyAvailable = false }
                }
            }
            guard !unsupported else { return nil }
            // Daily history is one record-kind snapshot: never mix months from different publications.
            if !dailyAvailable { daily = [] }
            let stale = now.timeIntervalSince(metadata.lastWriteUTC) > 86_400
            let sourcePartial = metadata.sources.contains {
                $0.state != .notInstalled
                    && ($0.state != .ok || $0.skippedRecords > 0 || ($0.lastSuccess.map { now.timeIntervalSince($0) > 86_400 } ?? true))
            }
            let state: RemoteDeviceStatus.State
            if !dailyAvailable && !hourlyAvailable { state = .unavailable }
            else if stale { state = .stale }
            else if !dailyAvailable || !hourlyAvailable || sourcePartial { state = .partial }
            else { state = .ok }
            return RemoteDeviceSnapshot(device: device, daily: daily, hourly: hourly,
                status: RemoteDeviceStatus(deviceID: id, displayName: device.name, lastWrite: metadata.lastWriteUTC, state: state),
                accounts: accountPublications(metadata.accounts, publisherID: id, path: path, backend: backend,
                    now: now, requestDownloads: requestDownloads))
        }
    }

    /// One unusable file drops the whole publication: account history is a single authority, so a
    /// partial read is unavailable data, never a smaller history. Mac rows are unaffected.
    private static func accountPublications(
        _ published: [AccountPublication], publisherID: String, path: String, backend: SyncBackend,
        now: Date, requestDownloads: Bool
    ) -> [RemoteAccountPublication] {
        let oldest = now.addingTimeInterval(-48 * 3_600)
        return published.compactMap { publication -> RemoteAccountPublication? in
            guard publication.kind == "account",
                  let shortID = AccountDeviceID.shortID(publication.deviceId),
                  !publication.files.isEmpty,
                  !publication.sources.isEmpty,
                  publication.sources.allSatisfy({ SourceCatalog.accountSourceIDs.contains($0) })
            else { return nil }
            let sources = Set(publication.sources)
            var daily: [UsageRecord] = []
            var hourly: [HourlyUsage] = []
            for (name, hash) in publication.files.sorted(by: { $0.key < $1.key }) {
                let month = accountMonth(name, shortID: shortID)
                guard month != nil || name == "account-\(shortID)-hourly.json" else { return nil }
                do {
                    let data = try backend.read(path + "/" + name, requestDownloads: requestDownloads)
                    guard try schemaVersion(data) == 1, digest(data) == hash else { return nil }
                    if let month {
                        let snapshot = try SyncSnapshot.decode(DailySyncSnapshot.self, from: data)
                        guard snapshot.records.allSatisfy({
                            $0.deviceID == publication.deviceId && sources.contains($0.sourceID)
                                && $0.dayInterval != nil && $0.day.hasPrefix(month + "-")
                        }),
                              Set(snapshot.records.map { SyncSnapshot.dailyKey($0) }).count == snapshot.records.count
                        else { return nil }
                        daily.append(contentsOf: snapshot.records)
                    } else {
                        let snapshot = try SyncSnapshot.decode(HourlySyncSnapshot.self, from: data)
                        guard snapshot.records.allSatisfy({
                            $0.deviceID == publication.deviceId && sources.contains($0.sourceID)
                        }),
                              Set(snapshot.records.map { "\($0.sourceID)\u{0}\($0.hourStart.timeIntervalSince1970)" }).count
                                == snapshot.records.count
                        else { return nil }
                        hourly = snapshot.records.filter { $0.hourStart > oldest && $0.hourStart <= now }
                    }
                } catch {
                    return nil
                }
            }
            return RemoteAccountPublication(
                device: Device(id: publication.deviceId, name: publication.displayName, kind: .account),
                publisherID: publisherID, collectedAt: publication.collectedAtUTC, daily: daily, hourly: hourly)
        }
    }

    private static func accountMonth(_ name: String, shortID: String) -> String? {
        let prefix = "account-\(shortID)-usage-"
        guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return nil }
        let month = String(name.dropFirst(prefix.count).dropLast(".json".count))
        guard month.range(of: #"^[0-9]{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil else { return nil }
        return month
    }

    private static func requestFolderDownloads(_ folder: URL) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let entries = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: []) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                let realName = String(name.dropFirst().dropLast(".icloud".count))
                guard !realName.isEmpty else { continue }
                try? manager.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(realName))
            } else if let values = try? entry.resourceValues(forKeys: Set(keys)),
                      values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current {
                // Evicted files on current macOS keep their name (dataless) instead of a `.icloud` placeholder.
                try? manager.startDownloadingUbiquitousItem(at: entry)
            }
        }
    }

    private static func unavailable(device: Device, lastWrite: Date? = nil) -> RemoteDeviceSnapshot {
        RemoteDeviceSnapshot(device: device, daily: [], hourly: [], status: RemoteDeviceStatus(
            deviceID: device.id, displayName: device.name, lastWrite: lastWrite, state: .unavailable))
    }

    private static func validDeviceID(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." && !id.contains("/") && !id.contains("\\") && !id.hasPrefix(".")
    }

    private static func validMonthFile(_ name: String) -> Bool {
        name.range(of: #"^usage-[0-9]{4}-(0[1-9]|1[0-2])\.json$"#, options: .regularExpression) != nil
    }

    private static func hourlyWindow(now: Date) -> ClosedRange<Date> {
        let currentHour = Calendar.current.dateInterval(of: .hour, for: now)!.start
        let cutoff = currentHour.addingTimeInterval(-47 * 3_600)
        return cutoff...currentHour
    }

    private static func schemaVersion(_ data: Data) throws -> Int {
        struct Header: Decodable { let schemaVersion: Int }
        return try JSONDecoder().decode(Header.self, from: data).schemaVersion
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
