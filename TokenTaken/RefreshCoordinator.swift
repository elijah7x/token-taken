import Foundation
import Observation
import TokenTakenKit

enum EngineStatus: Equatable {
    case found(path: String)
    case missing
    case invalidOverride(path: String)
}

@Observable
@MainActor
final class RefreshCoordinator {
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    private(set) var health: [SourceHealth]
    private(set) var engineStatus: EngineStatus = .missing
    private(set) var remoteSnapshots: [RemoteDeviceSnapshot] = []
    private(set) var iCloudAvailable = ICloudSync.defaultRoot != nil
    private(set) var syncFailed = false

    @ObservationIgnored let store: SQLiteUsageStore
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let device: Device
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private let syncWorker = SyncWorker()

    init(settings: AppSettings) throws {
        self.settings = settings
        store = try SQLiteUsageStore(url: AppPaths.databaseURL)
        device = LocalDevice.current()
        health = try store.health().map { $0.markingStale() }
        lastRefresh = health.compactMap(\.lastSuccess).max()
        updateEngineStatus()
        settings.onRefreshIntervalChange = { [weak self] in
            self?.restart()
        }
        settings.onSyncEnabledChange = { [weak self] in
            guard let self else { return }
            self.syncTask?.cancel()
            if self.settings.syncEnabled {
                Task { [weak self] in await self?.readRemotes() }
            } else {
                self.remoteSnapshots = []
                self.syncFailed = false
                self.onChange?()
            }
        }
    }

    func start() {
        guard refreshTask == nil else { return }
        scheduleLoop(refreshImmediately: true)
    }

    func restart() {
        guard refreshTask != nil else { return }
        scheduleLoop(refreshImmediately: false)
    }

    func updateEngineStatus() {
        let override = settings.tokscalePathOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty {
            let path = NSString(string: override).expandingTildeInPath
            let url = URL(fileURLWithPath: path)
            if let executable = TokscaleCollector.locateExecutable(override: url) {
                engineStatus = .found(path: executable.path)
            } else {
                engineStatus = .invalidOverride(path: path)
            }
        } else if let executable = TokscaleCollector.locateExecutable(override: nil) {
            engineStatus = .found(path: executable.path)
        } else {
            engineStatus = .missing
        }
    }

    func refresh() async {
        updateEngineStatus()
        guard !isRefreshing else { return }

        isRefreshing = true
        defer {
            isRefreshing = false
            onChange?()
        }
        await readRemotes()
        let collectors = makeCollectors()
        let store = store
        let device = device
        let attemptedAt = Date.now
        let runner = CollectionRunner(store: store, device: device, collectors: collectors)
        let results = await Task.detached(priority: .utility) {
            await runner.runAll(now: attemptedAt)
        }.value

        health = results.map { $0.markingStale() }
        if health.contains(where: { $0.state == .ok && ($0.lastSuccess.map({ $0 >= attemptedAt }) ?? false) }) {
            lastRefresh = health.compactMap(\.lastSuccess).max()
            await scheduleSyncWrite()
        }
    }

    private func readRemotes() async {
        iCloudAvailable = ICloudSync.defaultRoot != nil
        guard settings.syncEnabled else { return }
        guard let root = ICloudSync.defaultRoot else {
            markRemotesUnavailable()
            onChange?()
            return
        }
        let snapshots = await syncWorker.read(root: root, excludingDeviceID: device.id)
        guard settings.syncEnabled else { return }
        guard let snapshots else {
            markRemotesUnavailable()
            syncFailed = true
            onChange?()
            return
        }
        let previous = Dictionary(remoteSnapshots.map { ($0.device.id, $0) }, uniquingKeysWith: { first, _ in first })
        remoteSnapshots = snapshots.map { snapshot in
            guard snapshot.status.state != .ok, let cached = previous[snapshot.device.id] else { return snapshot }
            return RemoteDeviceSnapshot(device: cached.device, daily: cached.daily, hourly: cached.hourly, status: RemoteDeviceStatus(
                deviceID: cached.device.id, displayName: cached.device.name,
                lastWrite: snapshot.status.lastWrite ?? cached.status.lastWrite, state: snapshot.status.state))
        }
        onChange?()
    }

    private func markRemotesUnavailable() {
        remoteSnapshots = remoteSnapshots.map { snapshot in
            RemoteDeviceSnapshot(device: snapshot.device, daily: snapshot.daily, hourly: snapshot.hourly, status: RemoteDeviceStatus(
                deviceID: snapshot.device.id, displayName: snapshot.device.name, lastWrite: snapshot.status.lastWrite, state: .unavailable))
        }
    }

    private func scheduleSyncWrite() async {
        guard settings.syncEnabled else { return }
        syncTask?.cancel()
        let store = store
        let publication = await Task.detached(priority: .utility) {
            Result { try SyncPublicationStore(store: store) }
        }.value
        guard settings.syncEnabled else { return }
        guard case .success(let snapshot) = publication else {
            syncFailed = true
            return
        }
        let health = health
        syncTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, self.settings.syncEnabled else { return }
            self.iCloudAvailable = ICloudSync.defaultRoot != nil
            guard let root = ICloudSync.defaultRoot else {
                self.syncFailed = true
                self.onChange?()
                return
            }
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
            let succeeded = await self.syncWorker.write(store: snapshot, device: self.device, root: root,
                appVersion: version, health: health)
            guard self.settings.syncEnabled else { return }
            self.syncFailed = !succeeded
            await self.readRemotes()
        }
    }

    private func makeCollectors() -> [any UsageCollector] {
        var collectors: [any UsageCollector] = []
        if case .found(let path) = engineStatus {
            for client in TokscaleCollector.defaultClients {
                collectors.append(TokscaleCollector(
                    executableURL: URL(fileURLWithPath: path),
                    configDirectory: AppPaths.tokscaleConfigDirectory,
                    clients: [client],
                    deviceID: device.id
                ))
            }
        } else {
            collectors.append(UnavailableEngineCollector())
        }
        collectors.append(ZcodeCollector(deviceID: device.id))
        collectors.append(PiCollector(deviceID: device.id))
        collectors.append(OmpCollector(deviceID: device.id))
        return collectors
    }

    private struct UnavailableEngineCollector: UsageCollector {
        let sourceIDs = TokscaleCollector.defaultClients.map { $0 == "droid" ? "factory" : $0 }
        func collect() async throws -> CollectionBatch { throw CollectorError.sourceUnavailable }
    }

    private func scheduleLoop(refreshImmediately: Bool) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            if refreshImmediately {
                await self.refresh()
            }
            while !Task.isCancelled {
                let interval = self.settings.refreshIntervalMinutes
                guard interval > 0 else { break }
                do {
                    try await Task.sleep(for: .seconds(interval * 60))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                guard interval == self.settings.refreshIntervalMinutes else { continue }
                await self.refresh()
            }
        }
    }
}

private struct SyncPublicationStore: UsageStore {
    let devices: [Device]
    private let dailyRows: [UsageRecord]
    private let hourlyRows: [HourlyUsage]

    init(store: any UsageStore) throws {
        devices = store.devices
        dailyRows = try store.records()
        hourlyRows = try store.hourly()
    }

    func records() -> [UsageRecord] { dailyRows }
    func hourly() -> [HourlyUsage] { hourlyRows }
}

private actor SyncWorker {
    func read(root: URL, excludingDeviceID: String) -> [RemoteDeviceSnapshot]? {
        let devices = root.appendingPathComponent("v1/devices", isDirectory: true)
        if FileManager.default.fileExists(atPath: devices.path) {
            guard (try? SyncBackend(root: root).list("v1/devices")) != nil else { return nil }
        }
        return ICloudSync.readRemote(root: root, excludingDeviceID: excludingDeviceID)
    }

    func write(store: any UsageStore, device: Device, root: URL, appVersion: String, health: [SourceHealth]) -> Bool {
        do {
            try ICloudSync.write(local: store, device: device, root: root, appVersion: appVersion, health: health)
            return true
        } catch {
            return false
        }
    }
}
