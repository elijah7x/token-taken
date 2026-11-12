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
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let usingDemo = demoMode
        let source: any ReportSource = usingDemo ? demoSource : iCloudSource
        let load = await source.load()
        if let loaded = load.report {
            report = loaded
            state = load.state
            if !usingDemo { cache.write(loaded) }
        } else {
            // Keep the last good copy on screen; the state tells the UI why it may be old.
            state = load.state
        }
        comparison = makeComparison()
        lastLoadedAt = .now
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
        }
        await reload()
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
                guard let self, !self.demoMode else { continue }
                self.cache.clear()
                self.report = nil
                self.comparison = nil
                self.state = .iCloudUnavailable
                await self.reload()
            }
        }
    }
}
