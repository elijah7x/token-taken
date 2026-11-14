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
    /// A launch sooner than this after the last successful collection reuses the stored numbers;
    /// re-reading every log seconds after the previous read cannot find new data.
    static let launchRefreshFreshness: TimeInterval = 15 * 60
    /// Re-read remotes caught mid-write or awaiting iCloud download without waiting for the 4-hour fallback;
    /// the early retries pick up iCloud downloads requested by the first read.
    static let remoteRetryDelays: [TimeInterval] = [10, 30, 120, 600]
    static let remoteRetryTolerance: TimeInterval = 15
    /// Opt-in hourly republication keeps the iPhone report at most one refresh cycle old (ADR-0011);
    /// it is the only periodic work beyond the 4-hour fallback and stops when the setting is off.
    static let mobileReportInterval: TimeInterval = 60 * 60
    static let mobileReportTolerance: TimeInterval = 5 * 60

    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    private(set) var health: [SourceHealth]
    private(set) var engineStatus: EngineStatus = .missing
    private(set) var remoteSnapshots: [RemoteDeviceSnapshot] = []
    private(set) var iCloudAvailable = ICloudSync.defaultRoot != nil
    private(set) var iCloudSignedIn = FileManager.default.ubiquityIdentityToken != nil
    /// Read and write failures are tracked separately so a later success of one clears only its own failure.
    private(set) var syncReadFailed = false
    private(set) var syncWriteFailed = false
    var syncFailed: Bool { syncReadFailed || syncWriteFailed }
    /// Last outcome of the "Sync to iPhone" publication, shown in Settings.
    private(set) var mobileReportStatus: MobileReportPublishStatus = .disabled

    @ObservationIgnored let store: SQLiteUsageStore
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let device: Device
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var remoteRetryTask: Task<Void, Never>?
    @ObservationIgnored private var remoteRetryAttempt = 0
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var ubiquityIdentityObserver: NSObjectProtocol?
    @ObservationIgnored private var lastUbiquityIdentityToken: (any NSCoding & NSCopying & NSObjectProtocol)?
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private let syncWorker = SyncWorker()
    @ObservationIgnored private var mobileReportTask: Task<Void, Never>?
    @ObservationIgnored private let mobileReportWorker = MobileReportWorker()
    /// Bumped by every real state change; `notifyIfChanged()` republishes once per phase of a refresh.
    @ObservationIgnored private var stateRevision = 0
    @ObservationIgnored private var notifiedRevision = 0

    init(settings: AppSettings) throws {
        self.settings = settings
        store = try SQLiteUsageStore(url: AppPaths.databaseURL)
        device = LocalDevice.current()
        let token = FileManager.default.ubiquityIdentityToken
        lastUbiquityIdentityToken = token
        iCloudSignedIn = token != nil
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
                if !self.remoteSnapshots.isEmpty {
                    self.remoteSnapshots = []
                    self.markChanged()
                }
                self.setSyncReadFailed(false)
                self.setSyncWriteFailed(false)
                self.notifyIfChanged()
            }
        }
        // Enabling account-wide collection is a user action worth a fresh read; disabling keeps the
        // account device's cached rows, which stay visible and stop being replaced.
        settings.onCursorAccountCollectionChange = { [weak self] in
            guard let self, self.settings.cursorAccountCollection else { return }
            Task { [weak self] in await self?.refresh() }
        }
        settings.onMobileReportEnabledChange = { [weak self] in
            guard let self else { return }
            if self.settings.mobileReportEnabled {
                self.startMobileReportLoop()
                Task { [weak self] in await self?.publishMobileReport() }
            } else {
                // Disabling deletes only this Mac's report; other Macs keep theirs.
                self.mobileReportTask?.cancel()
                self.mobileReportTask = nil
                Task { [weak self] in await self?.removeMobileReport() }
            }
        }
    }

    func start() {
        guard refreshTask == nil else { return }
        observeWakeIfNeeded()
        observeUbiquityIdentityIfNeeded()
        let refreshImmediately = needsLaunchRefresh
        scheduleLoop(refreshImmediately: refreshImmediately)
        // A skipped launch refresh still reads the other Macs: their rows are not this Mac's logs, and
        // leaving them unread would hide synced devices until the next collection.
        if !refreshImmediately {
            Task { [weak self] in
                await self?.readRemotes()
                // Republish too, or Settings reports the iPhone report as unpublished until the hourly loop runs.
                if self?.settings.mobileReportEnabled == true { await self?.publishMobileReport() }
            }
        }
        if settings.mobileReportEnabled { startMobileReportLoop() }
    }

    /// Fresh data is reused at launch; a failed or stale source and an old success still collect. The
    /// loop in `scheduleLoop` picks the deferred run up from `lastRefresh`.
    private var needsLaunchRefresh: Bool {
        if health.contains(where: { $0.state == .failed || $0.state == .unavailable || $0.state == .stale }) {
            return true
        }
        guard let lastRefresh else { return true }
        return Date.now.timeIntervalSince(lastRefresh) >= Self.launchRefreshFreshness
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

        setRefreshing(true)
        defer {
            setRefreshing(false)
            notifyIfChanged()
        }
        cancelRemoteRetry()
        await readRemotes()
        let collectors = makeCollectors()
        let store = store
        let device = device
        let attemptedAt = Date.now
        lastAttempt = attemptedAt
        let runner = CollectionRunner(store: store, device: device, collectors: collectors)
        let collection = Task.detached(priority: .utility) {
            let results = await runner.runAll(now: attemptedAt)
            // Return freed pages off the main actor so the menu bar app's resident memory drops
            // after collection without stalling the window.
            malloc_zone_pressure_relief(nil, 0)
            return results
        }
        // A detached task ignores the caller's cancellation unless it is told, so cancel it here and
        // drop the commit below: a cancelled refresh must not publish state nobody is waiting for.
        let results = await withTaskCancellationHandler {
            await collection.value
        } onCancel: {
            collection.cancel()
        }
        guard !Task.isCancelled else { return }

        let nextHealth = results.map { $0.markingStale() }
        if nextHealth != health {
            health = nextHealth
            markChanged()
        }
        if nextHealth.contains(where: { $0.state == .ok && ($0.lastSuccess.map({ $0 >= attemptedAt }) ?? false) }) {
            let latest = nextHealth.compactMap(\.lastSuccess).max()
            if latest != lastRefresh {
                lastRefresh = latest
                markChanged()
            }
            await scheduleSyncWrite()
        }
        // A failed collection still publishes whatever the store can read; an unreadable store keeps
        // the previous report, because publication requires reading every record first.
        await publishMobileReport()
    }

    private func readRemotes(isRetry: Bool = false) async {
        refreshICloudAvailability()
        guard settings.syncEnabled else { return }
        guard let root = ICloudSync.defaultRoot else {
            markRemotesUnavailable()
            updateRemoteRetry(isRetry: isRetry, readFailed: true)
            notifyIfChanged()
            return
        }
        let snapshots = await syncWorker.read(root: root, excludingDeviceID: device.id)
        guard settings.syncEnabled, !Task.isCancelled else { return }
        guard let snapshots else {
            markRemotesUnavailable()
            setSyncReadFailed(true)
            updateRemoteRetry(isRetry: isRetry, readFailed: true)
            notifyIfChanged()
            return
        }
        setSyncReadFailed(false)
        remoteSnapshots = RemoteDeviceSnapshot.mergingCache(snapshots, previous: remoteSnapshots)
        markChanged()
        updateRemoteRetry(isRetry: isRetry)
        notifyIfChanged()
    }

    private func updateRemoteRetry(isRetry: Bool, readFailed: Bool = false) {
        if isRetry {
            remoteRetryTask = nil
        } else {
            remoteRetryTask?.cancel()
            remoteRetryTask = nil
            remoteRetryAttempt = 0
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
                deviceID: snapshot.device.id, displayName: snapshot.device.name, lastWrite: snapshot.status.lastWrite, state: .unavailable), accounts: snapshot.accounts)
        }
        markChanged()
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
            setSyncWriteFailed(true)
            return
        }
        let health = health
        syncTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, self.settings.syncEnabled else { return }
            self.refreshICloudAvailability()
            guard let root = ICloudSync.defaultRoot else {
                self.setSyncWriteFailed(true)
                self.notifyIfChanged()
                return
            }
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
            let succeeded = await self.syncWorker.write(store: snapshot, device: self.device, root: root,
                appVersion: version, health: health)
            guard self.settings.syncEnabled else { return }
            self.setSyncWriteFailed(!succeeded)
            await self.readRemotes()
        }
    }

    // MARK: - State publication

    /// Records a real state change. Every mutation goes through here or a guarded setter, so a refresh
    /// that changes nothing stays silent.
    private func markChanged() { stateRevision &+= 1 }

    /// Publishes any pending change once. A refresh therefore notifies at most once after the remote
    /// reads and once after collection, instead of once per assignment.
    private func notifyIfChanged() {
        guard stateRevision != notifiedRevision else { return }
        notifiedRevision = stateRevision
        onChange?()
    }

    private func setRefreshing(_ value: Bool) {
        guard isRefreshing != value else { return }
        isRefreshing = value
        markChanged()
    }

    private func refreshICloudAvailability() {
        let available = ICloudSync.defaultRoot != nil
        if available != iCloudAvailable {
            iCloudAvailable = available
            markChanged()
        }
        let signedIn = FileManager.default.ubiquityIdentityToken != nil
        if signedIn != iCloudSignedIn {
            iCloudSignedIn = signedIn
            markChanged()
        }
    }

    private func setSyncReadFailed(_ value: Bool) {
        guard value != syncReadFailed else { return }
        syncReadFailed = value
        markChanged()
    }

    private func setSyncWriteFailed(_ value: Bool) {
        guard value != syncWriteFailed else { return }
        syncWriteFailed = value
        markChanged()
    }

    // MARK: - Mobile report

    /// Publishes the merged view of every device this Mac can read. Sync off means this Mac only.
    private func publishMobileReport() async {
        guard settings.mobileReportEnabled else {
            mobileReportStatus = .disabled
            return
        }
        let mergesRemotes = settings.syncEnabled
        let remotes = mergesRemotes ? remoteSnapshots.map(\.status) : []
        let store: any UsageStore = mergesRemotes
            ? MergedUsageStore(local: self.store, remote: remoteSnapshots)
            : self.store
        let device = device
        let localStatus = MobileReportBuilder.localStatus(health)
        let version = Self.appVersion
        // Reading every record and building the report is CPU work; keep it off the main actor.
        let report = await Task.detached(priority: .utility) { () -> MobileReport? in
            guard let records = try? store.records() else { return nil }
            return MobileReportBuilder.build(
                records: records,
                device: device,
                appVersion: version,
                generatedAt: .now,
                timeZone: .current,
                localStatus: localStatus,
                remotes: remotes
            )
        }.value
        guard settings.mobileReportEnabled else { return }
        guard let report else {
            mobileReportStatus = .failed("Could not read usage")
            return
        }
        mobileReportStatus = await mobileReportWorker.publish(report)
    }

    private func removeMobileReport() async {
        mobileReportStatus = await mobileReportWorker.stop(deviceId: device.id)
    }

    /// Sleep-tolerant hourly timer: it refreshes, which publishes, so the report never lags one interval.
    private func startMobileReportLoop() {
        guard mobileReportTask == nil else { return }
        mobileReportTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        for: .seconds(Self.mobileReportInterval),
                        tolerance: .seconds(Self.mobileReportTolerance)
                    )
                } catch {
                    break
                }
                guard let self, !Task.isCancelled, self.settings.mobileReportEnabled else { break }
                await self.refresh()
            }
        }
    }

    /// Marketing version and build, for example `0.1.0 (12)`.
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return marketing }
        return "\(marketing) (\(build))"
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
        // Native sources are collected whether or not the engine binary is installed.
        collectors.append(DevinCollector(deviceID: device.id, stateDirectory: state))
        collectors.append(AntigravityCollector(deviceID: device.id, stateDirectory: state))
        collectors.append(MiniMaxCodeCollector(deviceID: device.id, stateDirectory: state))
        collectors.append(DeepSeekCollector(deviceID: device.id, stateDirectory: state))
        if settings.cursorAccountCollection {
            collectors.append(CursorCollector(deviceID: device.id, stateDirectory: state))
        }
        return collectors
    }

    private struct UnavailableEngineCollector: UsageCollector {
        let sourceIDs = TokscaleCollector.defaultSourceIDs
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

    private func observeUbiquityIdentityIfNeeded() {
        guard ubiquityIdentityObserver == nil else { return }
        ubiquityIdentityObserver = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleUbiquityIdentityChange()
            }
        }
    }

    private func handleUbiquityIdentityChange() {
        refreshICloudAvailability()
        let currentToken = FileManager.default.ubiquityIdentityToken
        guard !Self.tokensEqual(currentToken, lastUbiquityIdentityToken) else {
            notifyIfChanged()
            return
        }
        lastUbiquityIdentityToken = currentToken
        // Switching Apple ID points iCloud Drive at another account, so cached remote Macs no longer belong to this user.
        remoteSnapshots = []
        markChanged()
        notifyIfChanged()
        Task { [weak self] in
            guard let self else { return }
            // Re-read first so the republished iPhone report includes the new account's Macs.
            if self.settings.syncEnabled { await self.readRemotes() }
            if self.settings.mobileReportEnabled { await self.publishMobileReport() }
        }
    }

    private static func tokensEqual(
        _ lhs: (any NSCoding & NSCopying & NSObjectProtocol)?,
        _ rhs: (any NSCoding & NSCopying & NSObjectProtocol)?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (a?, b?): a.isEqual(b)
        default: false
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

/// Keeps container resolution and report writes off the main actor.
private actor MobileReportWorker {
    /// Bumped by every stop. The actor is reentrant across the container lookup, so a publish that was
    /// waiting when the setting turned off must not recreate the file the stop just removed.
    private var generation = 0

    func publish(_ report: MobileReport) async -> MobileReportPublishStatus {
        let started = generation
        guard let container = await MobileReportPublisher.containerURL() else { return .unavailable }
        guard started == generation else { return .disabled }
        // Synchronous from here: no suspension point between the check and the write.
        return MobileReportPublisher.publish(report, into: container)
    }

    func stop(deviceId: String) async -> MobileReportPublishStatus {
        generation += 1
        return await MobileReportPublisher.stop(deviceId: deviceId)
    }
}
