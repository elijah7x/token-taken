import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class AppModel {
    private(set) var report: MobileReport?
    private(set) var state: ReportState = .noReport
    private(set) var isLoading = false
    private(set) var demoMode: Bool
    private(set) var comparison: ComparisonLine?
    private(set) var lastLoadedAt: Date?

    @ObservationIgnored private let cache = ReportCache()
    @ObservationIgnored private let iCloudSource = ICloudReportSource()
    @ObservationIgnored private let demoSource = DemoReportSource()
    @ObservationIgnored private let comparisons = ComparisonCatalog.load()
    @ObservationIgnored private var identityTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration: UInt64 = 0
    @ObservationIgnored private var hasStarted = false

    private static let demoModeKey = "TokenTakenDemoMode"

    init() {
        let stored = UserDefaults.standard.bool(forKey: Self.demoModeKey)
        demoMode = stored
        if !stored, let cached = cache.read() {
            // Show the last good numbers immediately; the source load replaces them when it lands.
            report = cached.report
            state = cached.state
        }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        observeUbiquityIdentity()
        await reload()
    }

    func reload() async {
        loadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        let usingDemo = demoMode
        let source: any ReportSource = usingDemo ? demoSource : iCloudSource
        isLoading = true

        let task = Task { @MainActor [weak self] in
            let load = await source.load()
            guard let self, self.loadGeneration == generation else { return }
            self.isLoading = false
            self.loadTask = nil
            guard !Task.isCancelled else { return }
            self.apply(load, usingDemo: usingDemo)
        }
        loadTask = task
        await task.value
    }

    func setDemoMode(_ enabled: Bool) async {
        guard enabled != demoMode else { return }
        demoMode = enabled
        UserDefaults.standard.set(enabled, forKey: Self.demoModeKey)
        if !enabled {
            // Leaving demo mode drops synthetic numbers instead of showing them as real ones.
            if let cached = cache.read() {
                report = cached.report
                state = cached.state
            } else {
                report = nil
                state = .noReport
            }
            comparison = makeComparison()
        }
        await reload()
    }

    private func apply(_ load: ReportLoad, usingDemo: Bool) {
        if let loaded = load.report {
            report = loaded
            state = load.state
            if !usingDemo { cache.write(loaded) }
        } else if !usingDemo, load.state == .noReport {
            // iCloud is reachable and holds no report files (e.g. Sync to iPhone was turned off).
            cache.clear()
            report = nil
            state = .noReport
        } else {
            // Keep the last good copy on screen; the state tells the UI why it may be old.
            state = load.state
        }
        comparison = makeComparison()
        lastLoadedAt = .now
    }

    private func makeComparison() -> ComparisonLine? {
        guard let comparisons, let total = report?.totals.last30Days.total else { return nil }
        return comparisons.pick(tokens: total, locale: .current)
    }

    /// iCloud sign-out or container change: the cached copy belongs to the old account.
    private func observeUbiquityIdentity() {
        guard identityTask == nil else { return }
        identityTask = Task { [weak self] in
            for await _ in ICloudReportSource.identityChangeStream() {
                guard let self else { continue }
                self.cache.clear()
                guard !self.demoMode else { continue }
                self.report = nil
                self.comparison = nil
                self.state = .iCloudUnavailable
                await self.reload()
            }
        }
    }
}
