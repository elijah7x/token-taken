import ServiceManagement
import SwiftUI
import TokenTakenKit

struct SettingsView: View {
    @State private var selection: SettingsSection = .general

    var body: some View {
        HStack(spacing: 20) {
            SettingsSidebar(selection: $selection)
                .padding(.leading, 14)
                .padding(.vertical, 14)

            // One readable column, so the heading lines up with the grouped form's left edge.
            VStack(alignment: .leading, spacing: 4) {
                Text(selection.title)
                    .font(.title2.weight(.semibold))
                    .padding(.leading, 20)

                sectionContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(.top, 22)
            .padding(.trailing, 22)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selection {
        case .general:
            GeneralSettingsTab()
        case .sources:
            SourcesSettingsTab()
        case .sync:
            SyncSettingsTab()
        case .about:
            AboutSettingsTab()
        }
    }
}

private enum SettingsSection: CaseIterable, Hashable, Identifiable {
    case general
    case sources
    case sync
    case about

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .sources: "Sources"
        case .sync: "Sync"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .sources: "tray.full"
        case .sync: "icloud"
        case .about: "info.circle"
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsSection
    @FocusState private var focusedSection: SettingsSection?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Color.clear
                .frame(height: 30)
                .allowsHitTesting(false)

            SettingsBackButton()
                .padding(.leading, 2)

            VStack(spacing: 4) {
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        selection = section
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 18)
                                .accessibilityHidden(true)
                            Text(section.title)
                            Spacer()
                        }
                        .font(.system(size: 13, weight: selection == section ? .medium : .regular))
                        .foregroundStyle(selection == section ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selection == section ? Color.primary.opacity(0.08) : Color.clear)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($focusedSection, equals: section)
                    .onKeyPress(.upArrow) {
                        moveSelection(by: -1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveSelection(by: 1)
                        return .handled
                    }
                    .accessibilityLabel(Text(section.title))
                    .accessibilityAddTraits(selection == section ? .isSelected : [])
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .frame(width: 200)
        .background { SettingsTrayBackground() }
        .onAppear { focusedSection = selection }
    }

    private func moveSelection(by offset: Int) {
        let sections = SettingsSection.allCases
        guard let index = sections.firstIndex(of: selection) else { return }
        let newIndex = min(max(index + offset, 0), sections.count - 1)
        selection = sections[newIndex]
        focusedSection = selection
    }
}

private struct SettingsBackButton: View {
    @Environment(MainWindowRouter.self) private var router
    @State private var isHovered = false

    var body: some View {
        Button {
            router.route = .dashboard
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
                Text("Back")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(isHovered ? .primary : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.escape, modifiers: [])
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text("Back"))
    }
}

private struct SettingsTrayBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        Group {
            if reduceTransparency {
                shape.fill(Palette.solid)
            } else {
                shape.fill(.regularMaterial)
            }
        }
        .overlay { shape.strokeBorder(Palette.hairline) }
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
                Picker("Theme", selection: $settings.theme) {
                    Text("Liquid Glass").tag(AppTheme.liquidGlass)
                }
                .pickerStyle(.menu)

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
                LabeledContent("Last updated") {
                    TimelineView(.everyMinute) { _ in
                        HStack(spacing: 10) {
                            Group {
                                if refreshCoordinator?.isRefreshing == true {
                                    Text("Updating…")
                                } else if let lastRefresh = refreshCoordinator?.lastRefresh {
                                    if Date.now.timeIntervalSince(lastRefresh) < 60 {
                                        Text("Updated · just now")
                                    } else {
                                        Text(verbatim: Self.relativeFormatter.localizedString(for: lastRefresh, relativeTo: .now))
                                    }
                                } else {
                                    Text("Not updated yet")
                                }
                            }
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                            Button("Refresh now") {
                                Task { await refreshCoordinator?.refresh() }
                            }
                            .disabled(refreshCoordinator == nil || refreshCoordinator?.isRefreshing == true)

                            if refreshCoordinator?.isRefreshing == true {
                                ProgressView().controlSize(.small)
                            }
                        }
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

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
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
                .accessibilityLabel(Text("Solid"))
            Slider(value: $value, in: 0...1)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 140)
                .accessibilityLabel(Text("Interface transparency"))
            Image(systemName: "circle.dotted")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(Text("Transparent"))
                .accessibilityLabel(Text("Transparent"))
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
                            .accessibilityHidden(true)
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
        if let health = refreshCoordinator?.health.first(where: { $0.sourceID == source.id }) {
            switch health.state {
            case .ok, .stale:
                return true
            case .notInstalled:
                return false
            case .unavailable, .failed:
                if health.recordCount > 0 || health.lastSuccess != nil {
                    return true
                }
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Self.dataLocations[source.id, default: []].contains { path in
            FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path)
        }
    }
}

private struct SyncSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppModel.self) private var model
    @Environment(RefreshCoordinator.self) private var refreshCoordinator: RefreshCoordinator?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("iCloud sync", isOn: $settings.syncEnabled)
                Text("Combine usage from your Macs through iCloud Drive. Only totals are shared.")
                    .foregroundStyle(.secondary)
                if refreshCoordinator?.iCloudAvailable == false || ICloudSync.defaultRoot == nil {
                    Text("iCloud Drive is not available on this Mac.")
                        .foregroundStyle(.secondary)
                } else if settings.syncEnabled && refreshCoordinator?.syncFailed == true {
                    Text("Unavailable").foregroundStyle(.secondary)
                }
            }

            if settings.syncEnabled {
                Section("Other Macs") {
                    if model.remoteDevices.isEmpty {
                        Text("No other Macs yet").foregroundStyle(.secondary)
                    }
                    ForEach(model.remoteDevices, id: \.deviceID) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: device.displayName)
                                if let lastWrite = device.lastWrite {
                                    Text("Last synced \(Self.relativeFormatter.localizedString(for: lastWrite, relativeTo: .now))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if device.state == .stale || device.lastWrite.map({ Date.now.timeIntervalSince($0) > 86_400 }) == true {
                                Text("Stale").foregroundStyle(.secondary)
                            }
                            if device.state == .unavailable || device.state == .partial {
                                Text("Unavailable").foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
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
