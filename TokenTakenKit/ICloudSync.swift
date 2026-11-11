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
        let base = root.resolvingSymlinksInPath().path
        // resolvingSymlinksInPath leaves a path untouched when its last component does not exist yet,
        // so resolve the deepest existing ancestor to catch a symlinked folder before a new file is written.
        var existing = url
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        let resolved = missing.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
        guard resolved == base || resolved.hasPrefix(base + "/") else { throw SyncError.invalidSnapshot }
        return url
    }
}

public enum ICloudSync {
    public static var defaultRoot: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: drive.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return drive.appendingPathComponent("Token Taken", isDirectory: true)
    }

    public static func write(local: any UsageStore, device: Device, root: URL, appVersion: String,
                             health: [SourceHealth] = [], now: Date = .now) throws {
        guard validDeviceID(device.id) else { throw SyncError.invalidSnapshot }
        let backend = SyncBackend(root: root)
        let folder = "v1/devices/\(device.id)"
        let metadataPath = folder + "/device.json"
        if let data = try? backend.read(metadataPath) {
            let previous = try SyncSnapshot.decode(DeviceSyncSnapshot.self, from: data)
            guard previous.schemaVersion == 1 else { throw SyncError.unsupportedSchema }
            guard previous.deviceId == device.id else { throw SyncError.invalidSnapshot }
            guard !previous.tombstone else { throw SyncError.tombstoned }
        } else if FileManager.default.fileExists(atPath: root.appendingPathComponent(folder).path) {
            // Do not overwrite an evicted or unreadable identity, which may contain a tombstone.
            let entries = try backend.list(folder)
            if entries.contains(where: { ["device.json", ".device.json.icloud"].contains($0.lastPathComponent) }) {
                throw SyncError.unavailable
            }
        }
        let daily = try local.records().filter { $0.deviceID == device.id }
        guard daily.allSatisfy({ $0.dayInterval != nil }) else { throw SyncError.invalidSnapshot }
        let currentHour = Calendar.current.dateInterval(of: .hour, for: now)!.start
        let cutoff = currentHour.addingTimeInterval(-47 * 3_600)
        let hourly = try local.hourly().filter {
            $0.deviceID == device.id && $0.hourStart >= cutoff && $0.hourStart <= currentHour
        }
        var payloads: [String: Data] = [:]
        for (month, records) in Dictionary(grouping: daily, by: { String($0.day.prefix(7)) }) {
            payloads["usage-\(month).json"] = try SyncSnapshot.encode(DailySyncSnapshot(records: records))
        }
        payloads["hourly.json"] = try SyncSnapshot.encode(HourlySyncSnapshot(records: hourly))
        var files: [String: String] = [:]
        for name in payloads.keys.sorted() {
            let data = payloads[name]!
            files[name] = digest(data)
            let path = folder + "/" + name
            if (try? backend.read(path)) != data { try backend.write(data, to: path) }
        }
        let metadata = DeviceSyncSnapshot(device: device, appVersion: appVersion, lastWriteUTC: now,
            files: files, sources: health.map(SyncSourceHealth.init))
        try backend.write(SyncSnapshot.encode(metadata), to: metadataPath)
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
                        hourly = snapshot.records
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
                status: RemoteDeviceStatus(deviceID: id, displayName: device.name, lastWrite: metadata.lastWriteUTC, state: state))
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

    private static func schemaVersion(_ data: Data) throws -> Int {
        struct Header: Decodable { let schemaVersion: Int }
        return try JSONDecoder().decode(Header.self, from: data).schemaVersion
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
