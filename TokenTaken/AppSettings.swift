import Foundation
import Observation
import ServiceManagement
import TokenTakenKit

enum AppTheme: String, CaseIterable {
    case liquidGlass = "liquid-glass"
}

@Observable
@MainActor
final class AppSettings {
    enum HeroStyle: String, CaseIterable {
        case confluence
        case condensation
    }

    static let refreshIntervalOptions = [0, 5, 15, 30, 60]
    static let defaultInterfaceTransparency = 0.5

    var theme: AppTheme {
        didSet {
            guard theme != oldValue else { return }
            defaults.set(theme.rawValue, forKey: Keys.theme)
        }
    }

    var interfaceTransparency: Double {
        didSet {
            guard interfaceTransparency != oldValue else { return }
            defaults.set(interfaceTransparency, forKey: Keys.interfaceTransparency)
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

    var syncEnabled: Bool {
        didSet {
            guard syncEnabled != oldValue else { return }
            defaults.set(syncEnabled, forKey: Keys.syncEnabled)
            onSyncEnabledChange?()
        }
    }

    var heroStyle: HeroStyle {
        didSet {
            guard heroStyle != oldValue else { return }
            defaults.set(heroStyle.rawValue, forKey: Keys.heroStyle)
        }
    }

    /// Mirrors the system login item, which the user can change in System Settings at any time.
    var launchAtLogin: Bool {
        get { launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = error.localizedDescription
            }
            refreshLaunchAtLoginStatus()
        }
    }

    var launchAtLoginNeedsApproval: Bool { launchAtLoginStatus == .requiresApproval }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    private(set) var launchAtLoginError: String?

    private var launchAtLoginStatus: SMAppService.Status
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onRefreshIntervalChange: (() -> Void)?
    @ObservationIgnored var onSyncEnabledChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.theme: AppTheme.liquidGlass.rawValue,
            Keys.interfaceTransparency: Self.defaultInterfaceTransparency,
            Keys.refreshIntervalMinutes: 15,
            Keys.syncEnabled: false,
            Keys.heroStyle: HeroStyle.confluence.rawValue,
        ])

        theme = AppTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .liquidGlass
        interfaceTransparency = defaults.object(forKey: Keys.interfaceTransparency) as? Double ?? Self.defaultInterfaceTransparency
        let storedInterval = defaults.integer(forKey: Keys.refreshIntervalMinutes)
        refreshIntervalMinutes = Self.refreshIntervalOptions.contains(storedInterval) ? storedInterval : 15
        tokscalePathOverride = defaults.string(forKey: Keys.tokscalePathOverride)
        syncEnabled = defaults.bool(forKey: Keys.syncEnabled)
        heroStyle = HeroStyle(rawValue: defaults.string(forKey: Keys.heroStyle) ?? "") ?? .confluence
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    private enum Keys {
        static let theme = "theme"
        static let interfaceTransparency = "interfaceTransparency"
        static let refreshIntervalMinutes = "refreshIntervalMinutes"
        static let tokscalePathOverride = "tokscalePathOverride"
        static let syncEnabled = "syncEnabled"
        static let heroStyle = "heroStyle"
    }
}
