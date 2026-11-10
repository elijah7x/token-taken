import Foundation
import Observation
import ServiceManagement
import TokenTakenKit

@Observable
@MainActor
final class AppSettings {
    static let refreshIntervalOptions = [5, 15, 30, 60]
    static var defaultEnabledSources: Set<String> {
        Set(SourceCatalog.all.map(\.id)).union(["factory"])
    }

    var enabledSources: Set<String> {
        didSet {
            guard enabledSources != oldValue else { return }
            defaults.set(enabledSources.sorted(), forKey: Keys.enabledSources)
        }
    }

    var refreshIntervalMinutes: Int {
        didSet {
            guard refreshIntervalMinutes != oldValue else { return }
            defaults.set(refreshIntervalMinutes, forKey: Keys.refreshIntervalMinutes)
            onRefreshIntervalChange?()
        }
    }

    var tokscalePathOverride: String? {
        didSet {
            guard tokscalePathOverride != oldValue else { return }
            defaults.set(tokscalePathOverride, forKey: Keys.tokscalePathOverride)
        }
    }

    var useSyntheticData: Bool {
        didSet {
            guard useSyntheticData != oldValue else { return }
            defaults.set(useSyntheticData, forKey: Keys.useSyntheticData)
        }
    }

    var syncEnabled: Bool {
        didSet {
            guard syncEnabled != oldValue else { return }
            defaults.set(syncEnabled, forKey: Keys.syncEnabled)
        }
    }

    var launchAtLogin: Bool {
        get { launchAtLoginValue }
        set {
            guard newValue != launchAtLoginValue else { return }
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchAtLoginValue = newValue
                defaults.set(newValue, forKey: Keys.launchAtLogin)
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = error.localizedDescription
            }
        }
    }

    private(set) var launchAtLoginError: String?

    private var launchAtLoginValue: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onRefreshIntervalChange: (() -> Void)?

    var enabledTokscaleClients: [String] {
        TokscaleCollector.defaultClients.filter { client in
            enabledSources.contains(client == "droid" ? "factory" : client)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.enabledSources: Self.defaultEnabledSources.sorted(),
            Keys.refreshIntervalMinutes: 15,
            Keys.useSyntheticData: false,
            Keys.syncEnabled: false,
            Keys.launchAtLogin: false,
        ])

        enabledSources = Set(defaults.stringArray(forKey: Keys.enabledSources) ?? Self.defaultEnabledSources.sorted())
        let storedInterval = defaults.integer(forKey: Keys.refreshIntervalMinutes)
        refreshIntervalMinutes = Self.refreshIntervalOptions.contains(storedInterval) ? storedInterval : 15
        tokscalePathOverride = defaults.string(forKey: Keys.tokscalePathOverride)
        useSyntheticData = defaults.bool(forKey: Keys.useSyntheticData)
        syncEnabled = defaults.bool(forKey: Keys.syncEnabled)
        launchAtLoginValue = defaults.bool(forKey: Keys.launchAtLogin)
    }

    private enum Keys {
        static let enabledSources = "enabledSources"
        static let refreshIntervalMinutes = "refreshIntervalMinutes"
        static let tokscalePathOverride = "tokscalePathOverride"
        static let useSyntheticData = "useSyntheticData"
        static let syncEnabled = "syncEnabled"
        static let launchAtLogin = "launchAtLogin"
    }
}
