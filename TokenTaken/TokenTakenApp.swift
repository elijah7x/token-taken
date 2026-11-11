import AppKit
import SwiftUI
import TokenTakenKit

@main
struct TokenTakenApp: App {
    @State private var settings: AppSettings
    @State private var model: AppModel
    @State private var refreshCoordinator: RefreshCoordinator?
    @State private var router = MainWindowRouter()

    init() {
        let settings = AppSettings()
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
        } catch {
            let model = AppModel(
                settings: settings,
                store: nil,
                storageError: String(localized: "Could not open the local usage store.")
            )
            _settings = State(initialValue: settings)
            _model = State(initialValue: model)
            _refreshCoordinator = State(initialValue: nil)
        }
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
            Label(TokenFormat.short(model.todaySummary.total.total), image: "MenuBarGlyph")
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
        } else {
            content
                .environment(settings)
                .environment(model)
                .environment(router)
                .environment(\.locale, locale)
        }
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
