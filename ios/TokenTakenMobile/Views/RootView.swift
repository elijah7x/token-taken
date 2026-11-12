import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            HomeView(onOpenSettings: { showingSettings = true })
        }
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.reload() }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
}
