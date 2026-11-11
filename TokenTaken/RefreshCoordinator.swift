import AppKit
import Darwin
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
    /// Refresh is manual-first to keep background cost near zero (owner decision 2026-11-10);
    /// a 4-hour fallback only keeps long-running sessions from going stale.
    static let fallbackRefreshInterval: TimeInterval = 4 * 60 * 60
    static let fallbackRefreshTolerance: TimeInterval = 15 * 60
    /// Re-read remotes caught mid-write or awaiting iCloud download without waiting for the 4-hour fallback.
    static let remoteRetryDelays: [TimeInterval] = [120, 600]
    static let remoteRetryTolerance: TimeInterval = 15

    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    private(set) var health: [SourceHealth]
    private(set) var engineStatus: EngineStatus = .missing
    private(set) var remoteSnapshots: [RemoteDeviceSnapshot] = []
    private(set) var iCloudAvailable = ICloudSync.defaultRoot != nil
    /// Read and write failures are tracked separately so a later success of one clears only its own failure.
    private(set) var syncReadFailed = false
    private(set) var syncWriteFailed = false
    var syncFailed: Bool { syncReadFailed || syncWriteFailed }

    @ObservationIgnored let store: SQLiteUsageStore
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let device: Device
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var remoteRetryTask: Task<Void, Never>?
    @ObservationIgnored private var remoteRetryAttempt = 0
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private let syncWorker = SyncWorker()

    init(settings: AppSettings) throws {
        self.settings = settings
        store = try SQLiteUsageStore(url: AppPaths.databaseURL)
        device = LocalDevice.current()
        health = try store.health().map { $0.markingStale() }
        lastRefresh = health.compactMap(\.lastSuccess).max()
        updateEngineStatus()
        settings.onSyncEnabledChange = { [weak self] in
            guard let self else { return }
            self.syncTask?.cancel()
            self.cancelRemoteRetry()
            if self.settings.syncEnabled {
                Task { [weak self] in await self?.readRemotes() }
            } else {
                self.remoteSnapshots = []
                self.syncReadFailed = false; self.syncWriteFailed = false
                self.onChange?()
            }
        }
    }

    func start() {
        guard refreshTask == nil else { return }
        observeWakeIfNeeded()
        scheduleLoop(refreshImmediately: true)
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
        cancelRemoteRetry()
        await readRemotes()
        let collectors = makeCollectors()
        let store = store
        let device = device
        let attemptedAt = Date.now
        lastAttempt = attemptedAt
        let runner = CollectionRunner(store: store, device: device, collectors: collectors)
        let results = await Task.detached(priority: .utility) {
            await runner.runAll(now: attemptedAt)
        }.value
        // Return freed pages so the menu bar app's resident memory drops after collection.
        malloc_zone_pressure_relief(nil, 0)

        health = results.map { $0.markingStale() }
        if health.contains(where: { $0.state == .ok && ($0.lastSuccess.map({ $0 >= attemptedAt }) ?? false) }) {
            lastRefresh = health.compactMap(\.lastSuccess).max()
            await scheduleSyncWrite()
        }
    }

    private func readRemotes(isRetry: Bool = false) async {
        iCloudAvailable = ICloudSync.defaultRoot != nil
        guard settings.syncEnabled else { return }
        guard let root = ICloudSync.defaultRoot else {
            markRemotesUnavailable()
            updateRemoteRetry(isRetry: isRetry, readFailed: true)
            onChange?()
            return
        }
        let snapshots = await syncWorker.read(root: root, excludingDeviceID: device.id)
        guard settings.syncEnabled, !Task.isCancelled else { return }
        guard let snapshots else {
            markRemotesUnavailable()
            syncReadFailed = true
            updateRemoteRetry(isRetry: isRetry, readFailed: true)
            onChange?()
            return
        }
        syncReadFailed = false
        let previous = Dictionary(remoteSnapshots.map { ($0.device.id, $0) }, uniquingKeysWith: { first, _ in first })
        remoteSnapshots = snapshots.map { snapshot in
            // A stale snapshot still carries its newest data; fall back to the cache only when this read got none.
            guard snapshot.status.state == .unavailable || snapshot.status.state == .partial,
                  let cached = previous[snapshot.device.id],
                  (cached.status.lastWrite ?? .distantPast) >= (snapshot.status.lastWrite ?? .distantPast) || snapshot.daily.isEmpty
            else { return snapshot }
            return RemoteDeviceSnapshot(device: cached.device, daily: cached.daily, hourly: cached.hourly, status: RemoteDeviceStatus(
                deviceID: cached.device.id, displayName: cached.device.name,
                lastWrite: snapshot.status.lastWrite ?? cached.status.lastWrite, state: snapshot.status.state))
        }
        updateRemoteRetry(isRetry: isRetry)
        onChange?()
    }

    private func updateRemoteRetry(isRetry: Bool, readFailed: Bool = false) {
        if isRetry {
            remoteRetryTask = nil
        } else {
            remoteRetryTask?.cancel()
            remoteRetryTask = nil
        }
        // A failed root or folder read must retry even before any remote Mac has been cached.
        let needsRetry = readFailed || remoteSnapshots.contains {
            $0.status.state == .unavailable || $0.status.state == .partial
        }
        guard needsRetry, settings.syncEnabled else {
            remoteRetryAttempt = 0
            return
        }
        if isRetry {
            remoteRetryAttempt += 1
        }
        guard remoteRetryAttempt < Self.remoteRetryDelays.count else { return }
        let delay = Self.remoteRetryDelays[remoteRetryAttempt]
        remoteRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: .seconds(delay),
                    tolerance: .seconds(Self.remoteRetryTolerance)
                )
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.settings.syncEnabled else { return }
            await self.readRemotes(isRetry: true)
        }
    }

    private func cancelRemoteRetry() {
        remoteRetryTask?.cancel()
        remoteRetryTask = nil
        remoteRetryAttempt = 0
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
            syncWriteFailed = true
            return
        }
        let health = health
        syncTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, self.settings.syncEnabled else { return }
            self.iCloudAvailable = ICloudSync.defaultRoot != nil
            guard let root = ICloudSync.defaultRoot else {
                self.syncWriteFailed = true
                self.onChange?()
                return
            }
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
            let succeeded = await self.syncWorker.write(store: snapshot, device: self.device, root: root,
                appVersion: version, health: health)
            guard self.settings.syncEnabled else { return }
            self.syncWriteFailed = !succeeded
            await self.readRemotes()
        }
    }

    private func makeCollectors() -> [any UsageCollector] {
        var collectors: [any UsageCollector] = []
        let state = CollectorStateFile<CollectionStamp>.defaultDirectory
        if case .found(let path) = engineStatus {
            collectors.append(TokscaleCollector(
                executableURL: URL(fileURLWithPath: path),
                configDirectory: AppPaths.tokscaleConfigDirectory,
                clients: TokscaleCollector.defaultClients,
                deviceID: device.id,
                stateDirectory: state
            ))
        } else {
            collectors.append(UnavailableEngineCollector())
        }
        collectors.append(ZcodeCollector(deviceID: device.id, stateDirectory: state))
        collectors.append(PiCollector(deviceID: device.id, stateDirectory: state))
        collectors.append(OmpCollector(deviceID: device.id, stateDirectory: state))
        return collectors
    }

    private struct UnavailableEngineCollector: UsageCollector {
        let sourceIDs = TokscaleCollector.defaultClients.map { $0 == "droid" ? "factory" : $0 }
        func collect() async throws -> CollectionBatch { throw CollectorError.sourceUnavailable }
    }

    private func observeWakeIfNeeded() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWake()
            }
        }
    }

    private func handleWake() {
        guard !isRefreshing else { return }
        if let reference = lastRefresh ?? lastAttempt,
           Date.now.timeIntervalSince(reference) > Self.fallbackRefreshInterval {
            scheduleLoop(refreshImmediately: true)
        }
    }

    private func scheduleLoop(refreshImmediately: Bool) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            if refreshImmediately, !self.isRefreshing {
                await self.refresh()
            }
            while !Task.isCancelled {
                let delay: TimeInterval
                if let lastRefresh = self.lastRefresh {
                    let remaining = Self.fallbackRefreshInterval - Date.now.timeIntervalSince(lastRefresh)
                    delay = remaining > 0 ? remaining : Self.fallbackRefreshInterval
                } else {
                    delay = Self.fallbackRefreshInterval
                }
                do {
                    try await Task.sleep(
                        for: .seconds(delay),
                        tolerance: .seconds(Self.fallbackRefreshTolerance)
                    )
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                guard !self.isRefreshing else { continue }
                if let lastRefresh = self.lastRefresh,
                   Date.now.timeIntervalSince(lastRefresh) < Self.fallbackRefreshInterval {
                    continue
                }
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
        return ICloudSync.readRemote(root: root, excludingDeviceID: excludingDeviceID, requestDownloads: true)
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
