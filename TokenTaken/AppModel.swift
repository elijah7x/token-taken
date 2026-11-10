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
            summary = aggregator().summary(for: newValue)
        }
    }

    private(set) var summary: UsageSummary
    private(set) var todaySummary: UsageSummary
    private(set) var last7: [SeriesPoint]
    private(set) var storageError: String?

    var isEmpty: Bool {
        if let settings {
            if settings.useSyntheticData { return false }
            return realStore?.isEmpty ?? true
        }
        return fixedStore?.records().isEmpty ?? true
    }

    var statusText: LocalizedStringKey {
        if settings?.useSyntheticData == true || (settings == nil && fixedStore is SyntheticUsageStore) {
            return "Synthetic data"
        }
        if storageError != nil {
            return "Storage unavailable"
        }
        guard let settings, let refreshCoordinator else {
            return "Not collected yet"
        }
        if refreshCoordinator.isRefreshing {
            return "Collecting…"
        }
        if !settings.enabledTokscaleClients.isEmpty {
            switch refreshCoordinator.engineStatus {
            case .found:
                break
            case .missing:
                return "Collection engine not found"
            case .invalidOverride:
                return "Invalid engine override"
            }
        }
        if let lastRefresh = refreshCoordinator.lastRefresh {
            // Collection finishes a moment after the view samples `.now`; never phrase it as future time.
            if Date.now.timeIntervalSince(lastRefresh) < 60 { return "Collected · just now" }
            let relative = Self.relativeFormatter.localizedString(for: lastRefresh, relativeTo: .now)
            return "Collected · \(relative)"
        }
        return isEmpty ? "No collected data yet" : "Not collected yet"
    }

    private var selectedPeriod: Period
    @ObservationIgnored private let settings: AppSettings?
    @ObservationIgnored private let fixedStore: (any UsageStore)?
    @ObservationIgnored private let realStore: SQLiteUsageStore?
    @ObservationIgnored private let syntheticStore: SyntheticUsageStore
    @ObservationIgnored private let emptyStore: EmptyUsageStore
    @ObservationIgnored private weak var refreshCoordinator: RefreshCoordinator?

    init(store: any UsageStore = SyntheticUsageStore(), period: Period = .month) {
        settings = nil
        fixedStore = store
        realStore = nil
        syntheticStore = SyntheticUsageStore()
        emptyStore = EmptyUsageStore()
        storageError = nil
        selectedPeriod = period
        let aggregator = Self.makeAggregator(store)
        summary = aggregator.summary(for: period)
        todaySummary = aggregator.summary(for: .day)
        last7 = aggregator.dailyTotals(lastDays: 7)
    }

    init(settings: AppSettings, store: SQLiteUsageStore?, period: Period = .month, storageError: String? = nil) {
        self.settings = settings
        fixedStore = nil
        realStore = store
        let syntheticStore = SyntheticUsageStore()
        self.syntheticStore = syntheticStore
        let emptyStore = EmptyUsageStore()
        self.emptyStore = emptyStore
        self.storageError = storageError
        selectedPeriod = period
        let initialStore: any UsageStore
        if settings.useSyntheticData {
            initialStore = syntheticStore
        } else if let store {
            initialStore = store
        } else {
            initialStore = emptyStore
        }
        let aggregator = Self.makeAggregator(initialStore)
        summary = aggregator.summary(for: period)
        todaySummary = aggregator.summary(for: .day)
        last7 = aggregator.dailyTotals(lastDays: 7)
    }

    func attach(to refreshCoordinator: RefreshCoordinator) {
        self.refreshCoordinator = refreshCoordinator
    }

    func refresh() {
        let aggregator = aggregator()
        summary = aggregator.summary(for: selectedPeriod)
        todaySummary = aggregator.summary(for: .day)
        last7 = aggregator.dailyTotals(lastDays: 7)
    }

    private var store: any UsageStore {
        if let settings {
            if settings.useSyntheticData { return syntheticStore }
            if let realStore { return realStore }
            return emptyStore
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
}
