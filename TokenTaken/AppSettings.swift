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
    @ObservationIgnored var onSyncEnabledChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.removeObject(forKey: Keys.refreshIntervalMinutes)
        defaults.register(defaults: [
            Keys.theme: AppTheme.liquidGlass.rawValue,
            Keys.interfaceTransparency: Self.defaultInterfaceTransparency,
            Keys.syncEnabled: false,
        ])

        theme = AppTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .liquidGlass
        interfaceTransparency = defaults.object(forKey: Keys.interfaceTransparency) as? Double ?? Self.defaultInterfaceTransparency
        tokscalePathOverride = defaults.string(forKey: Keys.tokscalePathOverride)
        syncEnabled = defaults.bool(forKey: Keys.syncEnabled)
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    private enum Keys {
        static let theme = "theme"
        static let interfaceTransparency = "interfaceTransparency"
        static let refreshIntervalMinutes = "refreshIntervalMinutes"
        static let tokscalePathOverride = "tokscalePathOverride"
        static let syncEnabled = "syncEnabled"
    }
}
