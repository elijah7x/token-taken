import AppKit
import Darwin
import SwiftUI
import TokenTakenKit

#if DEBUG
struct SyntheticLaunchOptions {
    static let current: SyntheticLaunchOptions? = {
        let arguments = Set(CommandLine.arguments)
        let flags = ["-synthetic", "-synthetic-partial", "-synthetic-lens", "-synthetic-dark", "-synthetic-zh", "-synthetic-field", "-synthetic-cosmos", "-synthetic-settings"]
        guard flags.contains(where: arguments.contains) else { return nil }
        return SyntheticLaunchOptions(
            partial: arguments.contains("-synthetic-partial"),
            lens: arguments.contains("-synthetic-lens"),
            dark: arguments.contains("-synthetic-dark"),
            simplifiedChinese: arguments.contains("-synthetic-zh"),
            field: arguments.contains("-synthetic-field"),
            cosmos: arguments.contains("-synthetic-cosmos"),
            settings: arguments.contains("-synthetic-settings")
        )
    }()

    let partial: Bool
    let lens: Bool
    let dark: Bool
    let simplifiedChinese: Bool
    let field: Bool
    let cosmos: Bool
    let settings: Bool

    var remoteDevices: [RemoteDeviceStatus] {
        guard partial else { return [] }
        return [
            RemoteDeviceStatus(deviceID: "studio", displayName: "Mac Studio", lastWrite: nil, state: .partial),
            RemoteDeviceStatus(deviceID: "mini", displayName: "Mac mini", lastWrite: nil, state: .stale),
        ]
    }

    func isolateProcessPaths() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenTakenSynthetic-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let sync = root.appendingPathComponent("Sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        setenv("TOKEN_TAKEN_SUPPORT_DIR", support.path, 1)
        setenv("TOKEN_TAKEN_SYNC_ROOT", sync.path, 1)
    }

    func makeDefaults() -> UserDefaults {
        let suiteName = "io.github.elijah7x.TokenTaken.synthetic.debug"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create the synthetic defaults suite.")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defaults.setPersistentDomain([
            "theme": cosmos ? AppTheme.cosmos.rawValue : (field ? AppTheme.field.rawValue : AppTheme.liquidGlass.rawValue),
            "liquidView": lens ? LiquidView.lens.rawValue : LiquidView.confluence.rawValue,
            "appearance": dark ? AppAppearance.dark.rawValue : AppAppearance.light.rawValue,
            "appLanguage": simplifiedChinese ? AppLanguage.simplifiedChinese.rawValue : AppLanguage.english.rawValue,
            "numberUnits": NumberUnits.automatic.rawValue,
            "syncEnabled": partial,
            "cursorAccountCollection": false,
            "mobileReportEnabled": false,
            "autoUpdateEnabled": false,
        ], forName: suiteName)
        return defaults
    }
}
#endif

@main
struct TokenTakenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: AppSettings
    @State private var model: AppModel
    @State private var refreshCoordinator: RefreshCoordinator?
    @State private var router = MainWindowRouter()

    init() {
        #if DEBUG
        if let synthetic = SyntheticLaunchOptions.current {
            synthetic.isolateProcessPaths()
            let settings = AppSettings(defaults: synthetic.makeDefaults())
            let model = AppModel(
                store: SyntheticUsageStore(),
                syntheticRemoteDevices: synthetic.remoteDevices
            )
            _settings = State(initialValue: settings)
            _model = State(initialValue: model)
            _refreshCoordinator = State(initialValue: nil)
            let router = MainWindowRouter()
            if synthetic.settings { router.route = .settings }
            _router = State(initialValue: router)
            appDelegate.configureSynthetic(settings: settings, model: model)
            return
        }
        #endif

        let settings = AppSettings()
        let coordinator: RefreshCoordinator?
        do {
            let refreshCoordinator = try RefreshCoordinator(settings: settings)
            let model = AppModel(settings: settings, store: refreshCoordinator.store)
            refreshCoordinator.onChange = { [weak model] in
                model?.refresh()
            }
            model.attach(to: refreshCoordinator)
            _settings = State(initialValue: settings)
            _model = State(initialValue: model)
            _refreshCoordinator = State(initialValue: refreshCoordinator)
            coordinator = refreshCoordinator
        } catch {
            let model = AppModel(
                settings: settings,
                store: nil,
                storageError: String(localized: "Could not open the local usage store.")
            )
            _settings = State(initialValue: settings)
            _model = State(initialValue: model)
            _refreshCoordinator = State(initialValue: nil)
            coordinator = nil
        }
        appDelegate.configure(settings: settings, model: model, refreshCoordinator: coordinator)
    }

    var body: some Scene {
        // A single-instance Window, so openWindow from the menu bar focuses it instead of adding another.
        Window(Text(verbatim: "Token Taken"), id: MainWindowView.windowID) {
            withEnvironment(MainWindowView().id(settings.formatRevision))
                .frame(minWidth: 900, minHeight: 620)
                .task { refreshCoordinator?.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(router: router)
            }
            CommandGroup(replacing: .appSettings) {
                SettingsCommand(router: router)
            }
            CommandGroup(after: .newItem) {
                Button("Refresh Now") {
                    Task { await refreshCoordinator?.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(refreshCoordinator == nil || refreshCoordinator?.isRefreshing == true)
            }
        }

        MenuBarExtra {
            withEnvironment(MenuBarContent().id(settings.formatRevision))
                .onAppear { refreshCoordinator?.start() }
        } label: {
            Label {
                Text(TokenFormat.short(model.todaySummary.total.total))
                    .font(ThemeFont.make(12, weight: .medium, numeric: true))
            } icon: {
                if settings.theme == .cosmos {
                    Image(nsImage: CosmosMenuBarGlyph.templateImage)
                        .accessibilityHidden(true)
                } else {
                    Image("MenuBarGlyph")
                        .accessibilityHidden(true)
                }
            }
            .id(settings.formatRevision)
            .labelStyle(.titleAndIcon)
            .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private func withEnvironment<Content: View>(_ content: Content) -> some View {
        let locale = settings.language.locale ?? .autoupdatingCurrent
        if let refreshCoordinator {
            content
                .environment(settings)
                .environment(model)
                .environment(refreshCoordinator)
                .environment(router)
                .environment(\.locale, locale)
                .fontDesign(settings.theme == .field ? .serif : nil)
                .preferredColorScheme(settings.theme == .cosmos ? .dark : nil)
        } else {
            content
                .environment(settings)
                .environment(model)
                .environment(router)
                .environment(\.locale, locale)
                .fontDesign(settings.theme == .field ? .serif : nil)
                .preferredColorScheme(settings.theme == .cosmos ? .dark : nil)
        }
    }
}

private struct CosmosMenuBarGlyph: View {
    @MainActor
    static let templateImage: NSImage = {
        let renderer = ImageRenderer(
            content: CosmosMenuBarGlyph()
                .environment(\.colorScheme, .light)
        )
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        return image
    }()

    var body: some View {
        ZStack {
            Circle()
                .stroke(.primary, lineWidth: 1)
                .frame(width: 7, height: 7)
            Ellipse()
                .stroke(.primary, lineWidth: 1)
                .frame(width: 17, height: 6)
                .rotationEffect(.degrees(-12))
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

/// ⌘, shows Settings inside the main window instead of a separate Settings scene.
private struct SettingsCommand: View {
    let router: MainWindowRouter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            router.openSettings(using: openWindow)
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

private struct CheckForUpdatesCommand: View {
    let router: MainWindowRouter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Check for Updates…") {
            router.settingsSection = .about
            router.openSettings(using: openWindow)
            #if DEBUG
            guard SyntheticLaunchOptions.current == nil else { return }
            #endif
            Task { await UpdateChecker.shared.checkNow() }
        }
        #if DEBUG
        .disabled(SyntheticLaunchOptions.current != nil)
        #endif
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings?
    private weak var model: AppModel?
    private var refreshCoordinator: RefreshCoordinator?
    private var didStartUpdater = false
    #if DEBUG
    private var isSynthetic = false
    #endif
    private nonisolated(unsafe) var dayChangedObserver: NSObjectProtocol?

    deinit {
        if let dayChangedObserver {
            NotificationCenter.default.removeObserver(dayChangedObserver)
        }
    }

    func configure(settings: AppSettings, model: AppModel, refreshCoordinator: RefreshCoordinator?) {
        self.settings = settings
        self.model = model
        self.refreshCoordinator = refreshCoordinator
    }

    #if DEBUG
    func configureSynthetic(settings: AppSettings, model: AppModel) {
        configure(settings: settings, model: model, refreshCoordinator: nil)
        isSynthetic = true
    }
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings?.applyAppearance()
        #if DEBUG
        guard !isSynthetic else { return }
        #endif
        if dayChangedObserver == nil {
            dayChangedObserver = NotificationCenter.default.addObserver(
                forName: .NSCalendarDayChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.model?.refresh()
                }
            }
        }
        guard !didStartUpdater, let settings else { return }
        didStartUpdater = true

        AppUpdater.shared.consumeLaunchMarker()
        AppUpdater.shared.canInstallSilently = { [weak refreshCoordinator] in
            if refreshCoordinator?.isRefreshing == true {
                return false
            }
            if NSApp.modalWindow != nil {
                return false
            }
            if NSApp.isActive, NSApp.keyWindow != nil {
                return false
            }
            return true
        }
        UpdateChecker.shared.start(automatic: { settings.autoUpdateEnabled })
    }

    func applicationWillTerminate(_ notification: Notification) {
        #if DEBUG
        guard !isSynthetic else { return }
        #endif
        _ = AppUpdater.shared.installStagedOnQuit()
    }
}
