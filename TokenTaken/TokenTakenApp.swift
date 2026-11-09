import SwiftUI
import TokenTakenKit

@main
struct TokenTakenApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: MainWindowView.windowID) {
            MainWindowView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            Label(TokenFormat.short(model.todaySummary.total.total), systemImage: "drop.fill")
                .labelStyle(.titleAndIcon)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
