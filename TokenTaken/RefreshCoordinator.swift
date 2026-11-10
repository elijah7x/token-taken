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

    @ObservationIgnored let store: SQLiteUsageStore
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let device: Device
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(settings: AppSettings) throws {
        self.settings = settings
        store = try SQLiteUsageStore(url: AppPaths.databaseURL)
        device = LocalDevice.current()
        health = store.health()
        lastRefresh = health.compactMap(\.lastSuccess).max()
        updateEngineStatus()
        settings.onRefreshIntervalChange = { [weak self] in
            self?.restart()
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
        let collectors = makeCollectors()
        let store = store
        let device = device
        let attemptedAt = Date.now
        let runner = CollectionRunner(store: store, device: device, collectors: collectors)
        _ = await Task.detached(priority: .utility) {
            await runner.runAll(now: attemptedAt)
        }.value

        health = store.health()
        if health.contains(where: { $0.lastSuccess.map({ $0 >= attemptedAt }) ?? false }) {
            lastRefresh = health.compactMap(\.lastSuccess).max()
        }
    }

    private func makeCollectors() -> [any UsageCollector] {
        var collectors: [any UsageCollector] = []
        if case .found(let path) = engineStatus {
            collectors.append(TokscaleCollector(
                executableURL: URL(fileURLWithPath: path),
                configDirectory: AppPaths.tokscaleConfigDirectory,
                clients: TokscaleCollector.defaultClients,
                deviceID: device.id
            ))
        }
        collectors.append(ZcodeCollector(deviceID: device.id))
        return collectors
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
