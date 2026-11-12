import AppKit
import Foundation
import Observation
import ServiceManagement
import SwiftUI
import TokenTakenKit

enum AppTheme: String, CaseIterable {
    case liquidGlass = "liquid-glass"
    case field = "sketchbook"
    case cosmos = "cosmos"
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

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .system: "Follow System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// nil follows the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum NumberUnits: String, CaseIterable, Identifiable {
    case automatic
    case international
    case chinese

    var id: Self { self }

    var title: Text {
        switch self {
        case .automatic: Text("Automatic")
        case .international: Text(verbatim: "K · M · B")
        case .chinese: Text(verbatim: "万 · 亿")
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
            ThemeRuntime.isField = theme == .field
            ThemeRuntime.isCosmos = theme == .cosmos
            applyAppearance()
            formatRevision &+= 1
        }
    }

    var interfaceTransparency: Double {
        didSet {
            guard interfaceTransparency != oldValue else { return }
            defaults.set(interfaceTransparency, forKey: Keys.interfaceTransparency)
        }
    }

    var appearance: AppAppearance {
        didSet {
            guard appearance != oldValue else { return }
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }

    /// Applies the effective appearance to every window, the menu bar panel and the Dock icon.
    /// Cosmos forces dark without changing the preference that other themes use.
    func applyAppearance() {
        NSApp?.appearance = theme == .cosmos ? NSAppearance(named: .darkAqua) : appearance.nsAppearance
        FieldAppIconSwitcher.apply(theme)
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
            languageChangedThisSession = true
            applyUnitStyle(bumpRevision: true)
        }
    }

    var numberUnits: NumberUnits {
        didSet {
            guard numberUnits != oldValue else { return }
            defaults.set(numberUnits.rawValue, forKey: Keys.numberUnits)
            applyUnitStyle(bumpRevision: true)
        }
    }

    private(set) var formatRevision = 0
    private(set) var languageChangedThisSession = false

    var effectiveUnitStyle: TokenFormat.UnitStyle {
        switch numberUnits {
        case .international:
            return .international
        case .chinese:
            return .chinese
        case .automatic:
            let effectiveLanguage = language.languageCode ?? Self.systemPreferredLanguageCode
            return effectiveLanguage.lowercased().hasPrefix("zh") ? .chinese : .international
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
            Keys.numberUnits: NumberUnits.automatic.rawValue,
            Keys.syncEnabled: false,
        ])

        appearance = AppAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        let storedTheme = AppTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .liquidGlass
        theme = storedTheme
        ThemeRuntime.isField = storedTheme == .field
        ThemeRuntime.isCosmos = storedTheme == .cosmos
        interfaceTransparency = defaults.object(forKey: Keys.interfaceTransparency) as? Double ?? Self.defaultInterfaceTransparency
        language = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .system
        numberUnits = NumberUnits(rawValue: defaults.string(forKey: Keys.numberUnits) ?? "") ?? .automatic
        tokscalePathOverride = defaults.string(forKey: Keys.tokscalePathOverride)
        syncEnabled = defaults.bool(forKey: Keys.syncEnabled)
        launchAtLoginStatus = SMAppService.mainApp.status
        applyUnitStyle(bumpRevision: false)
        // NSApp is not up yet while the app's state is built; apply once launch finishes so a session
        // that only opens the menu bar panel still gets the chosen appearance.
        DispatchQueue.main.async { [weak self] in self?.applyAppearance() }
    }

    private func applyUnitStyle(bumpRevision: Bool) {
        TokenFormat.unitStyle = effectiveUnitStyle
        if bumpRevision {
            formatRevision &+= 1
        }
    }

    private static var systemPreferredLanguageCode: String {
        if let global = CFPreferencesCopyValue(
            Keys.appleLanguages as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String], let first = global.first, !first.isEmpty {
            return first
        }
        return Locale.preferredLanguages.first ?? Locale.current.identifier
    }

    private enum Keys {
        static let theme = "theme"
        static let appearance = "appearance"
        static let interfaceTransparency = "interfaceTransparency"
        static let language = "appLanguage"
        static let numberUnits = "numberUnits"
        static let appleLanguages = "AppleLanguages"
        static let refreshIntervalMinutes = "refreshIntervalMinutes"
        static let tokscalePathOverride = "tokscalePathOverride"
        static let syncEnabled = "syncEnabled"
    }
}
