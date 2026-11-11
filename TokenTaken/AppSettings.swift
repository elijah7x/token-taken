import AppKit
import Foundation
import Observation
import ServiceManagement
import SwiftUI
import TokenTakenKit

enum AppTheme: String, CaseIterable {
    case liquidGlass = "liquid-glass"
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .system: "Follow System"
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    var locale: Locale? {
        guard let languageCode else { return nil }
        return Locale(identifier: languageCode)
    }

    fileprivate var languageCode: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .simplifiedChinese: "zh-Hans"
        }
    }
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

    var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            defaults.set(language.rawValue, forKey: Keys.language)
            if let code = language.languageCode {
                UserDefaults.standard.set([code], forKey: Keys.appleLanguages)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.appleLanguages)
            }
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

    func relaunch() {
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            Task { @MainActor in
                NSApplication.shared.terminate(nil)
            }
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
            Keys.language: AppLanguage.system.rawValue,
            Keys.syncEnabled: false,
        ])

        theme = AppTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .liquidGlass
        interfaceTransparency = defaults.object(forKey: Keys.interfaceTransparency) as? Double ?? Self.defaultInterfaceTransparency
        language = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .system
        tokscalePathOverride = defaults.string(forKey: Keys.tokscalePathOverride)
        syncEnabled = defaults.bool(forKey: Keys.syncEnabled)
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    private enum Keys {
        static let theme = "theme"
        static let interfaceTransparency = "interfaceTransparency"
        static let language = "appLanguage"
        static let appleLanguages = "AppleLanguages"
        static let refreshIntervalMinutes = "refreshIntervalMinutes"
        static let tokscalePathOverride = "tokscalePathOverride"
        static let syncEnabled = "syncEnabled"
    }
}
