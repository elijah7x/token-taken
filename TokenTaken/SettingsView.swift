import ServiceManagement
import SwiftUI
import TokenTakenKit

struct SettingsView: View {
    @Environment(MainWindowRouter.self) private var router

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    router.route = .dashboard
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.escape, modifiers: [])
                Text("Settings")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.leading, 84)
            .padding(.trailing, 22)
            .frame(height: 52)
            .padding(.top, 2)

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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct GeneralSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppModel.self) private var model
    @Environment(RefreshCoordinator.self) private var refreshCoordinator: RefreshCoordinator?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Appearance") {
                LabeledContent("Theme") {
                    PreviewSelectionTile(title: "Liquid Glass", isSelected: settings.theme == .liquidGlass) {
                        settings.theme = .liquidGlass
                    } preview: {
                        LiquidGlassThumbnail()
                    }
                }

                LabeledContent("Main view") {
                    HStack(spacing: 14) {
                        ForEach(AppSettings.HeroStyle.allCases, id: \.self) { style in
                            PreviewSelectionTile(title: style.title, isSelected: settings.heroStyle == style) {
                                settings.heroStyle = style
                            } preview: {
                                HeroStyleThumbnail(style: style)
                            }
                        }
                    }
                }

                if settings.theme == .liquidGlass {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Interface transparency")
                            Text("How much shows through the window")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        InterfaceTransparencySlider(value: $settings.interfaceTransparency)
                    }
                }
            }

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
                        if minutes == 0 {
                            Text("Manual").tag(minutes)
                        } else {
                            Text("\(minutes) minutes").tag(minutes)
                        }
                    }
                }
                HStack {
                    Button("Refresh now") {
                        Task { await refreshCoordinator?.refresh() }
                    }
                    .disabled(refreshCoordinator == nil || refreshCoordinator?.isRefreshing == true)
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
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
        .onAppear { settings.refreshLaunchAtLoginStatus() }
    }
}

private struct PreviewSelectionTile<Preview: View>: View {
    let title: LocalizedStringKey
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let preview: Preview

    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                preview
                    .frame(width: 120, height: 76)
                    .clipShape(shape)
                    .overlay {
                        shape.strokeBorder(isSelected ? Palette.accent : Palette.hairline, lineWidth: isSelected ? 2 : 1)
                    }
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Palette.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct LiquidGlassThumbnail: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0, 0], [0.55, 0], [1, 0],
                    [0, 0.5], [0.45, 0.55], [1, 0.45],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: Palette.meshColors(scheme)
            )
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(scheme == .dark ? 0.09 : 0.28))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(scheme == .dark ? 0.16 : 0.55))
                }
                .frame(width: 82, height: 46)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(Palette.accent).frame(width: 25, height: 4)
                Capsule().fill(Palette.muted.opacity(0.35)).frame(width: 48, height: 3)
                Capsule().fill(Palette.muted.opacity(0.25)).frame(width: 35, height: 3)
            }
            .frame(width: 66, alignment: .leading)
        }
    }
}

private struct HeroStyleThumbnail: View {
    let style: AppSettings.HeroStyle
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: scheme == .dark
                    ? [Color(hex: "#263948"), Color(hex: "#1B2628")]
                    : [Color(hex: "#E4ECF3"), Color(hex: "#F2ECE7")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Canvas { context, _ in
                switch style {
                case .confluence:
                    drawConfluence(in: &context)
                case .condensation:
                    drawCondensation(in: &context)
                }
            }
        }
    }

    private func drawConfluence(in context: inout GraphicsContext) {
        let sourceColors = [Palette.color(forSource: "claude"), Palette.color(forSource: "codex"), Palette.color(forSource: "zcode")]
        let categoryColors = [Palette.color(for: .input), Palette.color(for: .output), Palette.color(for: .reasoning)]
        for index in 0..<3 {
            let y = 16 + Double(index) * 21
            var source = Path()
            source.move(to: CGPoint(x: 10, y: y))
            source.addCurve(
                to: CGPoint(x: 54, y: 38),
                control1: CGPoint(x: 30, y: y),
                control2: CGPoint(x: 32, y: 38)
            )
            context.stroke(source, with: .color(sourceColors[index].opacity(0.75)), lineWidth: 3)

            var category = Path()
            category.move(to: CGPoint(x: 66, y: 38))
            category.addCurve(
                to: CGPoint(x: 110, y: y),
                control1: CGPoint(x: 88, y: 38),
                control2: CGPoint(x: 90, y: y)
            )
            context.stroke(category, with: .color(categoryColors[index].opacity(0.75)), lineWidth: 3)
        }
        let reservoir = Path(roundedRect: CGRect(x: 52, y: 13, width: 16, height: 50), cornerRadius: 8)
        context.fill(reservoir, with: .color(Palette.accent.opacity(0.25)))
        context.stroke(reservoir, with: .color(Palette.hairline), lineWidth: 1)
    }

    private func drawCondensation(in context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 5))
            layer.fill(
                Path(ellipseIn: CGRect(x: 12, y: 12, width: 40, height: 24)),
                with: .color(Palette.color(forSource: "claude").opacity(0.38))
            )
            layer.fill(
                Path(ellipseIn: CGRect(x: 48, y: 8, width: 46, height: 28)),
                with: .color(Palette.color(forSource: "codex").opacity(0.34))
            )
            layer.fill(
                Path(ellipseIn: CGRect(x: 78, y: 20, width: 34, height: 22)),
                with: .color(Palette.color(forSource: "zcode").opacity(0.35))
            )
        }
        for index in 0..<6 {
            let x = 18 + Double(index) * 17
            let top = 37 + Double(index % 2) * 4
            let bottom = 66 - Double(index % 3) * 4
            var rain = Path()
            rain.move(to: CGPoint(x: x, y: top))
            rain.addQuadCurve(
                to: CGPoint(x: x + 2, y: bottom),
                control: CGPoint(x: x - 2, y: (top + bottom) / 2)
            )
            context.stroke(rain, with: .color(Palette.rain.opacity(0.55)), lineWidth: 1)
        }
        for (x, y, radius) in [(38.0, 23.0, 8.0), (76.0, 20.0, 11.0), (99.0, 28.0, 6.0)] {
            let drop = Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            context.fill(drop, with: .color(.white.opacity(scheme == .dark ? 0.09 : 0.26)))
            context.stroke(drop, with: .color(.white.opacity(scheme == .dark ? 0.2 : 0.55)), lineWidth: 1)
        }
    }
}

private struct InterfaceTransparencySlider: View {
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(Text("Solid"))
            Slider(value: $value, in: 0...1)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 140)
                .accessibilityLabel(Text("Interface transparency"))
            Image(systemName: "circle.dotted")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(Text("Transparent"))
        }
        .accessibilityElement(children: .contain)
    }
}

private extension AppSettings.HeroStyle {
    var title: LocalizedStringKey {
        switch self {
        case .confluence: "Confluence"
        case .condensation: "Condensation"
        }
    }
}

private struct SourcesSettingsTab: View {
    @Environment(RefreshCoordinator.self) private var refreshCoordinator: RefreshCoordinator?

    private static let dataLocations = [
        "claude": [".claude"],
        "codex": [".codex"],
        "zcode": [".zcode/cli/db/db.sqlite"],
        "omp": [".omp"],
        "pi": [".pi"],
        "kimi": [".kimi"],
        "grok": [".grok"],
        "opencode": [".local/share/opencode", ".config/opencode"],
        "gemini": [".gemini"],
        "factory": [".factory"],
    ]

    var body: some View {
        Form {
            Section {
                ForEach(SourceCatalog.all) { source in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color(hex: source.colorHex))
                            .frame(width: 8, height: 8)
                        Text(verbatim: source.name)
                        Spacer()
                        Text(isDetected(source) ? "Detected" : "Not found")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
    }

    private func isDetected(_ source: SourceInfo) -> Bool {
        if refreshCoordinator?.health.contains(where: { $0.sourceID == source.id && $0.recordCount > 0 }) == true {
            return true
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Self.dataLocations[source.id, default: []].contains { path in
            FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path)
        }
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
        .scrollContentBackground(.hidden)
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
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
    }
}
