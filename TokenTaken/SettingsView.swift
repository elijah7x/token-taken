import AppKit
import ServiceManagement
import SwiftUI
import TokenTakenKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }
            SourcesSettingsTab()
                .tabItem { Label("Sources", systemImage: "dot.radiowaves.left.and.right") }
            SyncSettingsTab()
                .tabItem { Label("Sync", systemImage: "icloud") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 580, idealWidth: 620, minHeight: 480, idealHeight: 520)
    }
}

private struct GeneralSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppModel.self) private var model
    @Environment(RefreshCoordinator.self) private var refreshCoordinator: RefreshCoordinator?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                if let error = settings.launchAtLoginError {
                    Text(error).foregroundStyle(.red)
                }
                if settings.launchAtLoginNeedsApproval {
                    HStack {
                        Text("Allow Token Taken in System Settings › Login Items to finish.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Picker("Refresh every", selection: $settings.refreshIntervalMinutes) {
                    ForEach(AppSettings.refreshIntervalOptions, id: \.self) { minutes in
                        Text("\(minutes) minutes").tag(minutes)
                    }
                }
                HStack {
                    Button("Refresh now") {
                        Task { await refreshCoordinator?.refresh() }
                    }
                    .disabled(refreshCoordinator == nil || refreshCoordinator?.isRefreshing == true || settings.useSyntheticData)
                    if refreshCoordinator?.isRefreshing == true {
                        ProgressView().controlSize(.small)
                    }
                }
                LabeledContent("Last refresh") {
                    if let lastRefresh = refreshCoordinator?.lastRefresh {
                        Text(lastRefresh, style: .relative)
                    } else {
                        Text("Never")
                    }
                }
                if let error = model.storageError {
                    Text(error).foregroundStyle(.red)
                }
            }

            Section("Developer") {
                Toggle("Use synthetic data", isOn: Binding(
                    get: { settings.useSyntheticData },
                    set: { enabled in
                        settings.useSyntheticData = enabled
                        model.refresh()
                        if !enabled {
                            Task { await refreshCoordinator?.refresh() }
                        }
                    }
                ))
                Text("Demo data only; not collected usage.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { settings.refreshLaunchAtLoginStatus() }
    }
}

private struct SourcesSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RefreshCoordinator.self) private var refreshCoordinator: RefreshCoordinator?

    private var sources: [SourceInfo] {
        var sources = SourceCatalog.all
        if !sources.contains(where: { $0.id == "factory" }) {
            sources.append(SourceInfo(id: "factory", name: "Factory Droid", colorHex: "#D6A77C"))
        }
        return sources
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                ForEach(sources) { source in
                    let health = refreshCoordinator?.health.first(where: { $0.sourceID == source.id })
                    Toggle(isOn: Binding(
                        get: { settings.enabledSources.contains(source.id) },
                        set: { enabled in
                            var enabledSources = settings.enabledSources
                            if enabled {
                                enabledSources.insert(source.id)
                            } else {
                                enabledSources.remove(source.id)
                            }
                            settings.enabledSources = enabledSources
                        }
                    )) {
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(Color(hex: source.colorHex))
                                .frame(width: 8, height: 8)
                                .padding(.top, 5)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.name)
                                HStack {
                                    if let lastSuccess = health?.lastSuccess {
                                        Text("Last success")
                                        Text(lastSuccess, style: .relative)
                                    } else {
                                        Text("No successful collection yet")
                                    }
                                    Text("Records: \(health?.recordCount ?? 0)")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                if let error = health?.errorMessage {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
            }

            Section("Collection engine") {
                LabeledContent("Status") {
                    if let status = refreshCoordinator?.engineStatus {
                        switch status {
                        case .found:
                            Text("Available")
                        case .missing:
                            Text("Not found")
                        case .invalidOverride:
                            Text("Invalid override path")
                        }
                    } else {
                        Text("Unavailable")
                    }
                }
                if case .found(let path)? = refreshCoordinator?.engineStatus {
                    LabeledContent("Binary") {
                        Text(verbatim: path)
                            .font(.caption)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                }
                LabeledContent("Pinned version") {
                    if let pinnedVersion {
                        Text(verbatim: pinnedVersion)
                    } else {
                        Text("Not bundled")
                    }
                }
                HStack {
                    TextField("Override path", text: Binding(
                        get: { settings.tokscalePathOverride ?? "" },
                        set: { path in
                            settings.tokscalePathOverride = path.isEmpty ? nil : path
                            refreshCoordinator?.updateEngineStatus()
                        }
                    ))
                    Button("Choose…") { chooseEngine() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var pinnedVersion: String? {
        guard let url = Bundle.main.url(forResource: "engine.lock", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let lock = try? JSONDecoder().decode(EngineLock.self, from: data) else {
            return nil
        }
        return lock.version
    }

    private func chooseEngine() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose the tokscale executable.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.tokscalePathOverride = url.path
        refreshCoordinator?.updateEngineStatus()
    }

    private struct EngineLock: Decodable {
        let version: String
    }
}

private struct SyncSettingsTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("iCloud sync", isOn: $settings.syncEnabled)
                    .disabled(true)
                Text("iCloud sync is in development")
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("• Sync is opt-in and contains aggregate usage only.")
                Text("• Hourly UTC buckets contain token and event counts with a random device ID.")
                Text("• Never sync prompts, responses, paths, project names, credentials, or cost.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettingsTab: View {
    @State private var installationMessage: String?
    @State private var installationFailed = false

    private var version: String {
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(marketing) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: version)
                LabeledContent("License", value: "MIT")
                LabeledContent("Acknowledgements", value: "tokscale, TokenTracker")
            }

            Section("Privacy") {
                Text("Read-only local Agent logs, no content uploads, no telemetry")
            }

            Section {
                Button("Install Command-Line Tool") {
                    do {
                        if let destination = try CLIInstaller.install() {
                            installationMessage = String(localized: "Installed at \(destination.path)")
                            installationFailed = false
                        }
                    } catch {
                        installationMessage = error.localizedDescription
                        installationFailed = true
                    }
                }
                if let installationMessage {
                    Text(installationMessage)
                        .foregroundStyle(installationFailed ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}
