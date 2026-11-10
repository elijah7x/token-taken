import ServiceManagement
import SwiftUI
import TokenTakenKit

struct SettingsView: View {
    @State private var selection: SettingsSection = .general
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            SettingsSidebar(selection: $selection)
                .frame(width: 192)
                .frame(maxHeight: .infinity)

            ScrollView {
                sectionContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .id(selection)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.leading, 16)
        .padding(.trailing, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selection)
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
        case .sources: "tray"
        case .sync: "icloud"
        case .about: "info.circle"
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsSection
    @FocusState private var focusedSection: SettingsSection?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsBackButton()
                .padding(.horizontal, 4)

            Text("Settings")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .tracking(0.8)
                .padding(.horizontal, 10)
                .padding(.top, 16)
                .padding(.bottom, 8)

            VStack(spacing: 4) {
                ForEach(SettingsSection.allCases) { section in
                    SettingsNavigationButton(section: section, selection: $selection)
                        .focused($focusedSection, equals: section)
                        .onKeyPress(.upArrow) {
                            moveSelection(by: -1)
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            moveSelection(by: 1)
                            return .handled
                        }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Settings"))

            Spacer(minLength: 16)

            HStack(spacing: 6) {
                Circle()
                    .fill(Palette.liveDot)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                Text("Local data · Read-only")
                    .lineLimit(1)
            }
            .font(.system(size: 10))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
            .accessibilityElement(children: .combine)
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .ledgerGlass(cornerRadius: 16)
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

private struct SettingsNavigationButton: View {
    let section: SettingsSection
    @Binding var selection: SettingsSection
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false

    private var isSelected: Bool { selection == section }

    var body: some View {
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
            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected || isHovered ? Color.primary.opacity(isSelected ? (contrast == .increased ? 0.14 : 0.08) : 0.04) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text(section.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isHovered ? .primary : .secondary)
            .padding(.horizontal, 6)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.escape, modifiers: [])
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text("Back"))
    }
}

private struct LedgerGlassBackground: View {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        Group {
            if reduceTransparency {
                shape.fill(Palette.solid)
            } else {
                shape.fill(.clear)
                    .glassEffect(.regular, in: shape)
            }
        }
        .overlay { shape.strokeBorder(Palette.hairline) }
    }
}

private extension View {
    func ledgerGlass(cornerRadius: CGFloat = 12) -> some View {
        background { LedgerGlassBackground(cornerRadius: cornerRadius) }
    }
}

private struct SettingsSectionLabel: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct LedgerSettingRow<Accessory: View>: View {
    let title: LocalizedStringKey
    var help: LocalizedStringKey?
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                if let help {
                    Text(help)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            accessory
        }
        .frame(minHeight: 42)
    }
}

private struct LedgerHairline: View {
    var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

private struct SettingsEmptyState: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Palette.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding(24)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Palette.hairline, style: StrokeStyle(lineWidth: 1, dash: [4]))
            }
    }
}

private struct GeneralSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppModel.self) private var model
    @Environment(RefreshCoordinator.self) private var refreshCoordinator: RefreshCoordinator?

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionLabel(title: "Appearance & Behavior")

            VStack(spacing: 0) {
                LedgerSettingRow(title: "Theme") {
                    Picker("Theme", selection: $settings.theme) {
                        Text("Liquid Glass").tag(AppTheme.liquidGlass)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(minWidth: 128)
                    .accessibilityLabel(Text("Theme"))
                }
                .padding(16)

                LedgerHairline()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Main view")
                        .font(.system(size: 12, weight: .medium))
                    HStack(spacing: 12) {
                        ForEach(AppSettings.HeroStyle.allCases, id: \.self) { style in
                            PreviewSelectionTile(title: style.title, isSelected: settings.heroStyle == style) {
                                settings.heroStyle = style
                            } preview: {
                                HeroStyleThumbnail(style: style)
                            }
                        }
                    }
                }
                .padding(16)

                if settings.theme == .liquidGlass {
                    LedgerHairline()
                    LedgerSettingRow(title: "Interface transparency", help: "How much shows through the window") {
                        InterfaceTransparencySlider(value: $settings.interfaceTransparency)
                    }
                    .padding(16)
                }
            }
            .ledgerGlass()

            VStack(spacing: 0) {
                LedgerSettingRow(title: "Launch at login") {
                    Toggle("Launch at login", isOn: $settings.launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel(Text("Launch at login"))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if let error = settings.launchAtLoginError {
                    LedgerHairline()
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(16)
                }

                if settings.launchAtLoginNeedsApproval {
                    LedgerHairline()
                    HStack(spacing: 16) {
                        Text("Allow Token Taken in System Settings › Login Items to finish.")
                            .font(.caption)
                            .foregroundStyle(Palette.muted)
                        Spacer(minLength: 12)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                    .padding(16)
                }

                LedgerHairline()

                TimelineView(.everyMinute) { _ in
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Last updated")
                                .font(.system(size: 12, weight: .medium))
                            lastUpdatedText
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.muted)
                                .monospacedDigit()
                        }
                        Spacer(minLength: 12)
                        HStack(spacing: 8) {
                            Button {
                                Task { await refreshCoordinator?.refresh() }
                            } label: {
                                Label("Refresh now", systemImage: "arrow.clockwise")
                            }
                            .controlSize(.small)
                            .disabled(refreshCoordinator == nil || refreshCoordinator?.isRefreshing == true)
                            .keyboardShortcut("r", modifiers: .command)
                            .accessibilityLabel(Text("Refresh now"))

                            if refreshCoordinator?.isRefreshing == true {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel(Text("Updating…"))
                            }
                        }
                    }
                    .frame(minHeight: 42)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                if let error = model.storageError {
                    LedgerHairline()
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(16)
                }
            }
            .ledgerGlass()
        }
        .onAppear { settings.refreshLaunchAtLoginStatus() }
    }

    private var lastUpdatedText: Text {
        if refreshCoordinator?.isRefreshing == true {
            return Text("Updating…")
        }
        if let lastRefresh = refreshCoordinator?.lastRefresh {
            if Date.now.timeIntervalSince(lastRefresh) < 60 {
                return Text("Updated · just now")
            }
            return Text("Updated · \(Self.relativeFormatter.localizedString(for: lastRefresh, relativeTo: .now))")
        }
        return Text("Not updated yet")
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
            VStack(spacing: 8) {
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
            Text(value, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 10))
                .foregroundStyle(Palette.muted)
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
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

private struct SourceLedgerEntry: Identifiable {
    let source: SourceInfo
    let health: SourceHealth

    var id: String { source.id }
}

private struct SourcesSettingsTab: View {
    @Environment(RefreshCoordinator.self) private var refreshCoordinator: RefreshCoordinator?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsNotInstalled = false

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
        TimelineView(.everyMinute) { context in
            let ledger = makeLedger(now: context.date)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Local collection")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .tracking(0.8)
                        Text(verbatim: headline(for: ledger.installed, now: context.date))
                            .font(.system(size: 17, weight: .semibold))
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Label("Read-only", systemImage: "lock")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                        .labelStyle(.titleAndIcon)
                }
                .frame(minHeight: 52)

                VStack(spacing: 0) {
                    sourceColumns(count: ledger.installed.count)
                    LedgerHairline()
                    if ledger.installed.isEmpty {
                        Text("No installed sources found")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        ForEach(ledger.installed) { entry in
                            if entry.id != ledger.installed.first?.id {
                                LedgerHairline()
                            }
                            sourceRow(entry, now: context.date)
                        }
                    }
                }
                .ledgerGlass()

                VStack(spacing: 0) {
                    LedgerHairline()
                    DisclosureGroup(isExpanded: $showsNotInstalled) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                            ForEach(ledger.notInstalled) { source in
                                Text(verbatim: source.name)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Palette.muted)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
                                    .padding(8)
                                    .background {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(Color.primary.opacity(0.04))
                                    }
                            }
                        }
                        .padding(.top, 4)
                        .padding(.bottom, 12)
                    } label: {
                        HStack(spacing: 8) {
                            Text("Not installed")
                            Text(ledger.notInstalled.count, format: .number)
                                .font(.system(size: 9))
                                .monospacedDigit()
                                .frame(minWidth: 18, minHeight: 18)
                                .background {
                                    Capsule().fill(Color.primary.opacity(0.06))
                                }
                            Spacer(minLength: 8)
                            if !showsNotInstalled {
                                Text(verbatim: ledger.notInstalled.map(\.name).joined(separator: " · "))
                                    .foregroundStyle(Palette.muted)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                        .frame(minHeight: 40)
                        .contentShape(Rectangle())
                    }
                    .padding(.horizontal, 4)
                    .accessibilityLabel(Text("Not installed"))
                    LedgerHairline()
                }

                Text("Sources are identified automatically from local logs; no manual setup is needed.")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showsNotInstalled)
        }
    }

    private func makeLedger(now: Date) -> (installed: [SourceLedgerEntry], notInstalled: [SourceInfo]) {
        let healthByID = Dictionary(
            (refreshCoordinator?.health ?? []).map { ($0.sourceID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var installed: [SourceLedgerEntry] = []
        var notInstalled: [SourceInfo] = []

        for source in SourceCatalog.all {
            if let health = healthByID[source.id] {
                let currentHealth = health.markingStale(now: now)
                if currentHealth.state == .notInstalled {
                    notInstalled.append(source)
                } else {
                    installed.append(SourceLedgerEntry(source: source, health: currentHealth))
                }
            } else if isDetectedOnDisk(source) {
                installed.append(SourceLedgerEntry(
                    source: source,
                    health: SourceHealth(sourceID: source.id, state: .stale)
                ))
            } else {
                notInstalled.append(source)
            }
        }
        return (installed, notInstalled)
    }

    private func isDetectedOnDisk(_ source: SourceInfo) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Self.dataLocations[source.id, default: []].contains { path in
            FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path)
        }
    }

    private func headline(for entries: [SourceLedgerEntry], now: Date) -> String {
        if let lastUpdate = entries.compactMap({ $0.health.lastSuccess }).max() {
            return String(localized: "\(entries.count) installed sources · Last updated \(formattedDate(lastUpdate, now: now))")
        }
        return String(localized: "\(entries.count) installed sources · Not updated yet")
    }

    private func sourceColumns(count: Int) -> some View {
        HStack(spacing: 8) {
            Text("Installed · \(count)")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Health")
                .frame(width: 136, alignment: .leading)
            Text("Last collected")
                .frame(width: 88, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func sourceRow(_ entry: SourceLedgerEntry, now: Date) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                SourceMonogram(source: entry.source)
                Text(verbatim: entry.source.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SourceHealthLabel(state: entry.health.state)
                .frame(width: 136, alignment: .leading)

            Text(verbatim: entry.health.lastSuccess.map { formattedDate($0, now: now) } ?? "—")
                .font(.system(size: 10))
                .foregroundStyle(Palette.muted)
                .monospacedDigit()
                .frame(width: 88, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .accessibilityElement(children: .combine)
        .help(entry.health.errorMessage ?? "")
    }

    private func formattedDate(_ date: Date, now: Date) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return Self.timeFormatter.string(from: date)
        }
        return Self.dateFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()
}

private struct SourceMonogram: View {
    let source: SourceInfo

    private var color: Color { Color(hex: source.colorHex) }

    var body: some View {
        Text(verbatim: monogram)
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary)
            .frame(width: 26, height: 26)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color.opacity(0.18))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(color.opacity(0.32))
            }
            .accessibilityHidden(true)
    }

    private var monogram: String {
        switch source.id {
        case "claude": "CC"
        case "codex": "CX"
        case "zcode": "ZC"
        case "omp": "OM"
        case "pi": "PI"
        case "kimi": "KM"
        case "grok": "GK"
        case "opencode": "OC"
        case "gemini": "GM"
        case "factory": "FD"
        default: String(source.name.prefix(2)).uppercased()
        }
    }
}

private struct SourceHealthLabel: View {
    let state: SourceHealth.State

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.dotColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(state.ledgerTitle)
                .lineLimit(1)
        }
        .font(.system(size: 10))
        .foregroundStyle(state == .failed ? AnyShapeStyle(state.dotColor) : AnyShapeStyle(Palette.muted))
        .accessibilityElement(children: .combine)
    }
}

private extension SourceHealth.State {
    var ledgerTitle: LocalizedStringKey {
        switch self {
        case .ok: "Normal"
        case .stale: "Data stale"
        case .unavailable: "Temporarily unavailable"
        case .failed: "Read failed"
        case .notInstalled: "Not installed"
        }
    }

    var dotColor: Color {
        switch self {
        case .ok:
            Palette.liveDot
        case .stale:
            Color(light: "#9B762D", dark: "#D6AE68", contrastLight: "#725415", contrastDark: "#F5D695")
        case .unavailable, .notInstalled:
            Color(light: "#A5683F", dark: "#D69B73", contrastLight: "#75411D", contrastDark: "#F5C4A2")
        case .failed:
            Color(light: "#A94F4F", dark: "#DB8888", contrastLight: "#7A2929", contrastDark: "#F5AAAA")
        }
    }
}

private struct SyncSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppModel.self) private var model
    @Environment(RefreshCoordinator.self) private var refreshCoordinator: RefreshCoordinator?

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "icloud")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Only totals are shared")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Combine usage from your Macs through iCloud Drive.")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)

            VStack(spacing: 0) {
                LedgerSettingRow(title: "iCloud sync", help: "Combine usage from your Macs through iCloud Drive. Only totals are shared.") {
                    Toggle("iCloud sync", isOn: $settings.syncEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel(Text("iCloud sync"))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if refreshCoordinator?.iCloudAvailable == false || ICloudSync.defaultRoot == nil {
                    LedgerHairline()
                    Text("iCloud Drive is not available on this Mac.")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                        .padding(16)
                } else if settings.syncEnabled && refreshCoordinator?.syncFailed == true {
                    LedgerHairline()
                    Text("Unavailable")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                        .padding(16)
                }
            }
            .ledgerGlass()

            if settings.syncEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionLabel(title: "Other Macs")
                    if model.remoteDevices.isEmpty {
                        SettingsEmptyState(text: "No other Macs yet")
                    } else {
                        TimelineView(.everyMinute) { _ in
                            VStack(spacing: 0) {
                                ForEach(model.remoteDevices, id: \.deviceID) { device in
                                    if device.deviceID != model.remoteDevices.first?.deviceID {
                                        LedgerHairline()
                                    }
                                    remoteRow(device)
                                }
                            }
                            .ledgerGlass()
                        }
                    }
                }
            } else {
                SettingsEmptyState(text: "Turn on sync to see your other Macs here.")
            }
        }
    }

    private func remoteRow(_ device: RemoteDeviceStatus) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: device.displayName)
                    .font(.system(size: 11, weight: .medium))
                if let lastWrite = device.lastWrite {
                    Text("Last synced \(Self.relativeFormatter.localizedString(for: lastWrite, relativeTo: .now))")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 12)
            RemoteStatusLabel(state: device.state)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

private struct RemoteStatusLabel: View {
    let state: RemoteDeviceStatus.State

    private var title: LocalizedStringKey {
        switch state {
        case .ok: "Synced"
        case .stale: "Stale"
        case .partial, .unavailable: "Unavailable"
        }
    }

    private var color: Color {
        switch state {
        case .ok: Palette.liveDot
        case .stale: Color(light: "#9B762D", dark: "#D6AE68")
        case .partial, .unavailable: Color(light: "#A5683F", dark: "#D69B73")
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(title)
        }
        .font(.system(size: 10))
        .foregroundStyle(Palette.muted)
        .accessibilityElement(children: .combine)
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "drop")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 48, height: 48)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Palette.accent.opacity(0.12))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Palette.hairline)
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "Token Taken")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Local Agent token usage")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.vertical, 4)

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 0) {
                    AboutValueRow(label: "Version", value: version)
                    LedgerHairline()
                    AboutValueRow(label: "License", value: "MIT")
                    LedgerHairline()
                    AboutValueRow(label: "Acknowledgements", value: "tokscale, TokenTracker")
                }
                .frame(maxWidth: .infinity)
                .ledgerGlass()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Privacy")
                        .font(.system(size: 12, weight: .medium))
                    Text("Read-only local Agent logs, no content uploads, no telemetry")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .ledgerGlass()
            }

            VStack(spacing: 0) {
                LedgerSettingRow(title: "Command-Line Tool", help: "Use token-taken in Terminal") {
                    Button("Install Command-Line Tool", action: install)
                        .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if let installationMessage {
                    LedgerHairline()
                    Text(installationMessage)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(installationFailed ? AnyShapeStyle(Color.red) : AnyShapeStyle(Palette.muted))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                }
            }
            .ledgerGlass()
        }
    }

    private func install() {
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
}

private struct AboutValueRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
    }
}
