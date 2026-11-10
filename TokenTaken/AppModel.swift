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
    private(set) var last7: [SeriesPoint]
    private(set) var storageError: String?
    /// Set when the last read failed; the previous numbers stay on screen instead of partial ones.
    private(set) var readError: String?

    struct DataIssues {
        let failed: Int
        let unavailable: Int
        let stale: Int
        let skippedRecords: Int
        let isPartial: Bool
        var count: Int { failed + unavailable + stale }
    }

    var remoteDevices: [RemoteDeviceStatus] {
        guard settings?.syncEnabled == true else { return [] }
        return refreshCoordinator?.remoteSnapshots.map(\.status) ?? []
    }

    var dataIssues: DataIssues {
        let health = refreshCoordinator?.health.map { $0.markingStale() } ?? []
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
        unavailable += remoteDevices.filter { $0.state == .unavailable || $0.state == .partial }.count
        stale += remoteDevices.filter { $0.state == .stale }.count
        let skipped = health.reduce(0) { $0 + $1.skippedRecords }
        return DataIssues(failed: failed, unavailable: unavailable, stale: stale, skippedRecords: skipped,
            isPartial: failed + unavailable + stale > 0 || skipped > 0 || storageError != nil || readError != nil
                || (settings?.syncEnabled == true && (refreshCoordinator?.syncFailed == true || refreshCoordinator?.iCloudAvailable == false)))
    }

    /// Computed when data loads, never from a view body: checking the store reads every record.
    private(set) var isEmpty = true

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
        if let lastRefresh = refreshCoordinator.lastRefresh {
            // Collection finishes a moment after the view samples `.now`; never phrase it as future time.
            if Date.now.timeIntervalSince(lastRefresh) < 60 { return "Updated · just now" }
            let relative = Self.relativeFormatter.localizedString(for: lastRefresh, relativeTo: .now)
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

    init(store: any UsageStore = SyntheticUsageStore(), period: Period = .month) {
        settings = nil
        fixedStore = store
        realStore = nil
        emptyStore = EmptyUsageStore()
        storageError = nil
        selectedPeriod = period
        let loaded = Self.load(store, period: period)
        (summary, todaySummary, last7, readError) = (loaded.summary, loaded.today, loaded.last7, loaded.error)
        isEmpty = Self.storeIsEmpty(store, summary: loaded.summary)
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
        (summary, todaySummary, last7, readError) = (loaded.summary, loaded.today, loaded.last7, loaded.error)
        isEmpty = Self.storeIsEmpty(initialStore, summary: loaded.summary)
    }

    private static func storeIsEmpty(_ store: any UsageStore, summary: UsageSummary) -> Bool {
        guard summary.total.total == 0 else { return false }
        return (try? store.records().isEmpty) ?? true
    }

    func attach(to refreshCoordinator: RefreshCoordinator) {
        self.refreshCoordinator = refreshCoordinator
    }

    func refresh() {
        let aggregator = aggregator()
        do {
            (summary, todaySummary, last7) = (
                try aggregator.summary(for: selectedPeriod),
                try aggregator.summary(for: .day),
                try aggregator.dailyTotals(lastDays: 7)
            )
            isEmpty = Self.storeIsEmpty(store, summary: summary)
            readError = nil
        } catch {
            readError = error.localizedDescription
        }
    }

    private static func load(
        _ store: any UsageStore, period: Period
    ) -> (summary: UsageSummary, today: UsageSummary, last7: [SeriesPoint], error: String?) {
        do {
            let aggregator = makeAggregator(store)
            return (try aggregator.summary(for: period), try aggregator.summary(for: .day),
                    try aggregator.dailyTotals(lastDays: 7), nil)
        } catch {
            // The empty store cannot fail, so the window starts blank with the error shown.
            let empty = makeAggregator(EmptyUsageStore())
            return (try! empty.summary(for: period), try! empty.summary(for: .day),
                    try! empty.dailyTotals(lastDays: 7), error.localizedDescription)
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

    private func aggregator() -> UsageAggregator { Self.makeAggregator(store) }

    private static func makeAggregator(_ store: any UsageStore) -> UsageAggregator {
        UsageAggregator(store: store, now: store is SyntheticUsageStore ? SyntheticUsageStore.defaultToday : .now)
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
