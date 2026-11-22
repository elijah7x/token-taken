import AppKit
import SwiftUI
import TokenTakenKit

@main
struct TokenTakenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: AppSettings
    @State private var model: AppModel
    @State private var refreshCoordinator: RefreshCoordinator?
    @State private var router = MainWindowRouter()

    init() {
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
            Group {
                if settings.theme == .cosmos {
                    Label {
                        Text(TokenFormat.short(model.todaySummary.total.total))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                    } icon: {
                        Image(nsImage: CosmosMenuBarGlyph.templateImage)
                            .accessibilityHidden(true)
                    }
                } else {
                    Label(TokenFormat.short(model.todaySummary.total.total), image: "MenuBarGlyph")
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
            Task { await UpdateChecker.shared.checkNow() }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings?
    private weak var model: AppModel?
    private var refreshCoordinator: RefreshCoordinator?
    private var didStartUpdater = false
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings?.applyAppearance()
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
        _ = AppUpdater.shared.installStagedOnQuit()
    }
}
