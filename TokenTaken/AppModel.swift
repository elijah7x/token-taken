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
        var unavailableDevices = 0
        var partialDevices = 0
        var staleDevices = 0
        for remote in remoteDevices where remote.state != .ok && deviceKind(for: remote.deviceID) == .mac {
            switch remote.state {
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
        (summary, todaySummary, readError) = (loaded.summary, loaded.today, loaded.error)
        lensBuckets = loaded.lensBuckets
        isEmpty = Self.storeIsEmpty(records: loaded.records, summary: loaded.summary)
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
        (summary, todaySummary, readError) = (loaded.summary, loaded.today, loaded.error)
        lensBuckets = loaded.lensBuckets
        isEmpty = Self.storeIsEmpty(records: loaded.records, summary: loaded.summary)
    }

    /// The store is read once per refresh; emptiness is judged from those same rows.
    private static func storeIsEmpty(records: [UsageRecord], summary: UsageSummary) -> Bool {
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
        let store = store
        do {
            let rows = try UsageAggregator.preload(store)
            if rows.records.isEmpty && rows.hourly.isEmpty {
                return []
            }
            return try Self.makeAggregator(store, rows: rows).lensBuckets(for: period)
        } catch {
            return []
        }
    }

    func lensSlice(_ range: ClosedRange<Int>) -> LensSlice {
        UsageAggregator.lensSlice(lensBuckets, range: range, period: selectedPeriod, devices: summary.devices)
    }

    func refresh() {
        let store = store
        do {
            // One read of the store serves both summaries and lens buckets, instead of one scan per query.
            let rows = try UsageAggregator.preload(store)
            let aggregator = Self.makeAggregator(store, rows: rows)
            let newSummary = try aggregator.summary(for: selectedPeriod)
            let newToday = try aggregator.summary(for: .day)
            let empty = Self.storeIsEmpty(records: rows.records, summary: newSummary)
            let newLensBuckets = empty ? [] : ((try? aggregator.lensBuckets(for: selectedPeriod)) ?? [])
            (summary, todaySummary, lensBuckets) = (newSummary, newToday, newLensBuckets)
            if empty != isEmpty { isEmpty = empty }
            readError = nil
        } catch {
            // Keep the last good buckets alongside the retained summary; the read error is surfaced.
            readError = error.localizedDescription
        }
    }

    private static func load(
        _ store: any UsageStore, period: Period
    ) -> (summary: UsageSummary, today: UsageSummary, lensBuckets: [LensBucket], records: [UsageRecord], error: String?) {
        do {
            let rows = try UsageAggregator.preload(store)
            let aggregator = makeAggregator(store, rows: rows)
            let summary = try aggregator.summary(for: period)
            let today = try aggregator.summary(for: .day)
            let empty = storeIsEmpty(records: rows.records, summary: summary)
            let lensBuckets = empty ? [] : ((try? aggregator.lensBuckets(for: period)) ?? [])
            return (summary, today, lensBuckets, rows.records, nil)
        } catch {
            // The empty store cannot fail, so the window starts blank with the error shown.
            let empty = makeAggregator(EmptyUsageStore())
            return (try! empty.summary(for: period), try! empty.summary(for: .day),
                    [], [], error.localizedDescription)
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

    private static func makeAggregator(_ store: any UsageStore, rows: UsageAggregator.Rows? = nil) -> UsageAggregator {
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
