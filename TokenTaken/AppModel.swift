import Foundation
import Observation
import TokenTakenKit

/// App state shared by the main window and the menu bar extra.
/// Data comes from the synthetic store until collection is wired in.
@Observable
@MainActor
final class AppModel {
    /// Selected statistics period. Setting it recomputes `summary`.
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

    private var selectedPeriod: Period
    @ObservationIgnored private let store: any UsageStore

    init(store: any UsageStore = SyntheticUsageStore(), period: Period = .month) {
        self.store = store
        self.selectedPeriod = period
        let aggregator = Self.makeAggregator(store)
        summary = aggregator.summary(for: period)
        todaySummary = aggregator.summary(for: .day)
        last7 = aggregator.dailyTotals(lastDays: 7)
    }

    /// Recomputes everything against the current date, e.g. when the menu opens after midnight.
    func refresh() {
        let aggregator = aggregator()
        summary = aggregator.summary(for: selectedPeriod)
        todaySummary = aggregator.summary(for: .day)
        last7 = aggregator.dailyTotals(lastDays: 7)
    }

    private func aggregator() -> UsageAggregator { Self.makeAggregator(store) }

    // Synthetic data ends on a fixed day; pin "now" to it so the app and CLI show the same numbers.
    private static func makeAggregator(_ store: any UsageStore) -> UsageAggregator {
        UsageAggregator(store: store, now: store is SyntheticUsageStore ? SyntheticUsageStore.defaultToday : .now)
    }
}
