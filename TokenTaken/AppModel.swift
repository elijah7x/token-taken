import Foundation
import Observation
import SwiftUI
import TokenTakenKit

@Observable
@MainActor
final class AppModel {
    var period: Period {
        get { selectedPeriod }
        set {
            guard newValue != selectedPeriod else { return }
            selectedPeriod = newValue
            refresh()
        }
    }

    private(set) var summary: UsageSummary
    private(set) var todaySummary: UsageSummary
    private(set) var lensBuckets: [LensBucket] = []
    private var cachedLensBuckets: [Period: [LensBucket]] = [:]
    private(set) var storageError: String?
    /// Set when the last read failed; the previous numbers stay on screen instead of partial ones.
    private(set) var readError: String?

    struct DataIssues {
        let failed: Int
        let unavailable: Int
        let stale: Int
        let skippedRecords: Int
        /// Other Macs whose synced data is stale, partial or unavailable; not counted as sources.
        let unavailableDevices: Int
        let partialDevices: Int
        let staleDevices: Int
        var devices: Int { unavailableDevices + partialDevices + staleDevices }
        let isPartial: Bool
        var count: Int { failed + unavailable + stale }

        var remoteIssueNote: LocalizedStringKey? {
            let nonZeroKinds = (unavailableDevices > 0 ? 1 : 0)
                + (partialDevices > 0 ? 1 : 0)
                + (staleDevices > 0 ? 1 : 0)
            guard nonZeroKinds > 0 else { return nil }
            if nonZeroKinds > 1 {
                return "\(devices) Macs incomplete"
            }
            if unavailableDevices > 0 {
                return unavailableDevices == 1 ? "1 Mac unavailable" : "\(unavailableDevices) Macs unavailable"
            }
            if partialDevices > 0 {
                return partialDevices == 1 ? "1 Mac has partial data" : "\(partialDevices) Macs have partial data"
            }
            return staleDevices == 1 ? "1 Mac is stale" : "\(staleDevices) Macs are stale"
        }
    }

    var remoteDevices: [RemoteDeviceStatus] {
        guard settings?.syncEnabled == true else { return [] }
        return refreshCoordinator?.remoteSnapshots.map(\.status) ?? []
    }

    /// `account` devices stand for one account across every Mac that published it, not for a Mac.
    func deviceKind(for deviceID: String) -> DeviceKind {
        if let device = refreshCoordinator?.remoteSnapshots.first(where: { $0.device.id == deviceID })?.device {
            return device.kind
        }
        if let device = summary.devices.first(where: { $0.id == deviceID }) {
            return device.kind
        }
        return .mac
    }

    var dataIssues: DataIssues {
        dataIssues(now: .now)
    }

    func dataIssues(now: Date) -> DataIssues {
        let health = refreshCoordinator?.health.map { $0.markingStale(now: now) } ?? []
        var failed = 0
        var unavailable = 0
        var stale = 0
        for entry in health {
            switch entry.state {
            case .failed: failed += 1
            case .unavailable: unavailable += 1
            case .stale: stale += 1
            case .ok, .notInstalled: break
            }
        }
        var unavailableDevices = 0
        var partialDevices = 0
        var staleDevices = 0
        for remote in remoteDevices where deviceKind(for: remote.deviceID) == .mac {
            switch remote.effectiveState(now: now) {
            case .unavailable: unavailableDevices += 1
            case .partial: partialDevices += 1
            case .stale: staleDevices += 1
            case .ok: break
            }
        }
        let devices = unavailableDevices + partialDevices + staleDevices
        let skipped = health.reduce(0) { $0 + $1.skippedRecords }
        return DataIssues(
            failed: failed,
            unavailable: unavailable,
            stale: stale,
            skippedRecords: skipped,
            unavailableDevices: unavailableDevices,
            partialDevices: partialDevices,
            staleDevices: staleDevices,
            isPartial: failed + unavailable + stale + devices > 0 || skipped > 0 || storageError != nil || readError != nil
                || (settings?.syncEnabled == true && (refreshCoordinator?.syncFailed == true || refreshCoordinator?.iCloudAvailable == false))
        )
    }

    var hasEngineIssue: Bool {
        guard let refreshCoordinator else { return false }
        if case .found = refreshCoordinator.engineStatus { return false }
        return true
    }

    /// Computed when data loads, never from a view body: checking the store reads every record.
    private(set) var isEmpty = true

    /// Timestamp of the most recent completed scan or successful refresh, shared across status views.
    var lastUpdated: Date? {
        refreshCoordinator?.lastCompletedScan ?? refreshCoordinator?.lastRefresh
    }

    var statusText: LocalizedStringKey {
        if storageError != nil || readError != nil {
            return "Storage unavailable"
        }
        guard let refreshCoordinator else {
            return "Not updated yet"
        }
        if refreshCoordinator.isRefreshing {
            return "Updating…"
        }
        switch refreshCoordinator.engineStatus {
        case .found:
            break
        case .missing:
            return "Collection engine not found"
        case .invalidOverride:
            return "Invalid engine override"
        }
        if let lastScan = lastUpdated {
            // Collection finishes a moment after the view samples `.now`; never phrase it as future time.
            if Date.now.timeIntervalSince(lastScan) < 60 { return "Updated · just now" }
            let relative = Self.relativeFormatter.localizedString(for: lastScan, relativeTo: .now)
            return "Updated · \(relative)"
        }
        return "Not updated yet"
    }

    private var selectedPeriod: Period
    @ObservationIgnored private let settings: AppSettings?
    @ObservationIgnored private let fixedStore: (any UsageStore)?
    @ObservationIgnored private let realStore: SQLiteUsageStore?
    @ObservationIgnored private let emptyStore: EmptyUsageStore
    @ObservationIgnored private weak var refreshCoordinator: RefreshCoordinator?
    @ObservationIgnored private var refreshGeneration: UInt64 = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(store: any UsageStore = SyntheticUsageStore(), period: Period = .month) {
        settings = nil
        fixedStore = store
        realStore = nil
        emptyStore = EmptyUsageStore()
        storageError = nil
        selectedPeriod = period
        let loaded = Self.load(store, period: period)
        (summary, todaySummary, readError) = (loaded.snapshot.summary, loaded.snapshot.today, loaded.error)
        lensBuckets = loaded.snapshot.lensBuckets
        cachedLensBuckets = loaded.snapshot.lensBucketsByPeriod
        isEmpty = loaded.snapshot.isEmpty
    }

    init(settings: AppSettings, store: SQLiteUsageStore?, period: Period = .month, storageError: String? = nil) {
        self.settings = settings
        fixedStore = nil
        realStore = store
        let emptyStore = EmptyUsageStore()
        self.emptyStore = emptyStore
        self.storageError = storageError
        selectedPeriod = period
        let initialStore: any UsageStore
        if let store {
            initialStore = store
        } else {
            initialStore = emptyStore
        }
        let loaded = Self.load(initialStore, period: period)
        (summary, todaySummary, readError) = (loaded.snapshot.summary, loaded.snapshot.today, loaded.error)
        lensBuckets = loaded.snapshot.lensBuckets
        cachedLensBuckets = loaded.snapshot.lensBucketsByPeriod
        isEmpty = loaded.snapshot.isEmpty
    }

    /// The store is read once per refresh; emptiness is judged from those same rows.
    nonisolated private static func storeIsEmpty(records: [UsageRecord], summary: UsageSummary) -> Bool {
        guard summary.total.total == 0 else { return false }
        return records.isEmpty
    }

    func attach(to refreshCoordinator: RefreshCoordinator) {
        self.refreshCoordinator = refreshCoordinator
    }

    func lensBuckets(for period: Period) -> [LensBucket] {
        if period == selectedPeriod {
            return lensBuckets
        }
        return cachedLensBuckets[period] ?? []
    }

    func lensSlice(_ range: ClosedRange<Int>) -> LensSlice {
        UsageAggregator.lensSlice(lensBuckets, range: range, period: selectedPeriod, devices: summary.devices)
    }

    func refresh() {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        let store = store
        let period = selectedPeriod
        refreshTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Self.computeSnapshot(store, period: period) }
            }.value
            guard let self, self.refreshGeneration == generation else { return }
            switch result {
            case .success(let loaded):
                (self.summary, self.todaySummary, self.lensBuckets, self.cachedLensBuckets) = (
                    loaded.summary,
                    loaded.today,
                    loaded.lensBuckets,
                    loaded.lensBucketsByPeriod
                )
                if loaded.isEmpty != self.isEmpty { self.isEmpty = loaded.isEmpty }
                if self.readError != nil { self.readError = nil }
            case .failure(let error):
                // Keep the last good buckets alongside the retained summary; the read error is surfaced.
                self.readError = error.localizedDescription
            }
        }
    }

    private struct LoadedSnapshot: Sendable {
        let summary: UsageSummary
        let today: UsageSummary
        let lensBuckets: [LensBucket]
        let lensBucketsByPeriod: [Period: [LensBucket]]
        let isEmpty: Bool
    }

    nonisolated private static func computeSnapshot(
        _ store: any UsageStore, period: Period
    ) throws -> LoadedSnapshot {
        // One read of the store serves both summaries and lens buckets, instead of one scan per query.
        let rows = try UsageAggregator.preload(store)
        let aggregator = makeAggregator(store, rows: rows)
        let summary = try aggregator.summary(for: period)
        let today = try aggregator.summary(for: .day)
        let empty = storeIsEmpty(records: rows.records, summary: summary)
        var lensBucketsByPeriod: [Period: [LensBucket]] = [:]
        if !(rows.records.isEmpty && rows.hourly.isEmpty) {
            for target in Period.allCases {
                lensBucketsByPeriod[target] = (try? aggregator.lensBuckets(for: target)) ?? []
            }
        }
        let lensBuckets = empty ? [] : (lensBucketsByPeriod[period] ?? [])
        return LoadedSnapshot(
            summary: summary,
            today: today,
            lensBuckets: lensBuckets,
            lensBucketsByPeriod: lensBucketsByPeriod,
            isEmpty: empty
        )
    }

    nonisolated private static func load(
        _ store: any UsageStore, period: Period
    ) -> (snapshot: LoadedSnapshot, error: String?) {
        do {
            return (try computeSnapshot(store, period: period), nil)
        } catch {
            // The empty store cannot fail, so the window starts blank with the error shown.
            let empty = makeAggregator(EmptyUsageStore())
            let snapshot = LoadedSnapshot(
                summary: try! empty.summary(for: period),
                today: try! empty.summary(for: .day),
                lensBuckets: [],
                lensBucketsByPeriod: [:],
                isEmpty: true
            )
            return (snapshot, error.localizedDescription)
        }
    }

    private var store: any UsageStore {
        if settings != nil {
            let local: any UsageStore
            if let realStore { local = realStore } else { local = emptyStore }
            if settings?.syncEnabled == true {
                return MergedUsageStore(local: local, remote: refreshCoordinator?.remoteSnapshots ?? [])
            }
            return local
        }
        if let fixedStore { return fixedStore }
        return emptyStore
    }

    nonisolated private static func makeAggregator(_ store: any UsageStore, rows: UsageAggregator.Rows? = nil) -> UsageAggregator {
        UsageAggregator(store: store, rows: rows, now: store is SyntheticUsageStore ? SyntheticUsageStore.defaultToday : .now)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

private struct EmptyUsageStore: UsageStore {
    let devices: [Device] = []
    func records() -> [UsageRecord] { [] }
    func hourly() -> [HourlyUsage] { [] }
}

extension RemoteDeviceStatus {
    static let staleInterval: TimeInterval = 24 * 60 * 60

    func effectiveState(now: Date = .now) -> State {
        if state == .ok, lastWrite.map({ now.timeIntervalSince($0) > Self.staleInterval }) == true {
            return .stale
        }
        return state
    }

    func isStaleOrIncomplete(now: Date = .now) -> Bool {
        effectiveState(now: now) != .ok
    }
}
