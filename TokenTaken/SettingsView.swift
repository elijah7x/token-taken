import AppKit
import ServiceManagement
import SwiftUI
import TokenTakenKit

/// The selected settings section on the themed window base; the tray carries the section list.
struct SettingsView: View {
    @Environment(MainWindowRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var updateChecker = UpdateChecker()

    var body: some View {
        ScrollView {
            sectionContent
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.top, 104)
                .padding(.leading, 28)
                .padding(.trailing, 32)
                .padding(.bottom, 32)
                .id(router.settingsSection)
                .transition(.opacity)
        }
        .scrollIndicators(.automatic)
        .background(ThemeRuntime.isCosmos ? CosmosPalette.background : .clear)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: router.settingsSection)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch router.settingsSection {
        case .general:
            GeneralSettingsTab()
        case .sources:
            SourcesSettingsTab()
        case .sync:
            SyncSettingsTab()
        case .about:
            AboutSettingsTab(updateChecker: updateChecker)
        }
    }
}

/// Settings section list shown in the tray, with a way back to the dashboard.
struct SettingsSidebar: View {
    @Environment(MainWindowRouter.self) private var router
    @FocusState private var focusedSection: SettingsSection?
    @State private var isBackHovered = false

    var body: some View {
        @Bindable var router = router
        VStack(alignment: .leading, spacing: 0) {
            Button {
                router.route = .dashboard
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                    Text("Overview")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(isBackHovered ? Palette.ink1 : Palette.ink2)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isBackHovered = $0 }
            .keyboardShortcut(.escape, modifiers: [])
            .help(Text("Back to the overview (Esc)"))

            Text("Settings")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Palette.ink1)
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 16)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 4) {
                ForEach(SettingsSection.allCases) { section in
                    SettingsNavigationButton(section: section, selection: $router.settingsSection)
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
                    .fill(Palette.healthOK)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text("Local data · Read-only")
                    .lineLimit(1)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.ink3)
            .padding(.horizontal, 10)
            .accessibilityElement(children: .combine)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .onAppear { focusedSection = router.settingsSection }
    }

    private func moveSelection(by offset: Int) {
        let sections = SettingsSection.allCases
        guard let index = sections.firstIndex(of: router.settingsSection) else { return }
        let newIndex = min(max(index + offset, 0), sections.count - 1)
        router.settingsSection = sections[newIndex]
        focusedSection = router.settingsSection
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
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(section.title)
                Spacer()
            }
            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Palette.roleAccent : (isHovered ? Palette.ink1 : Palette.ink2))
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background {
                RoundedRectangle(cornerRadius: ThemeRuntime.isCosmos ? 0 : 8, style: .continuous)
                    .fill(
                        isSelected
                            ? (ThemeRuntime.isCosmos ? CosmosPalette.selection : Palette.roleAccent.opacity(contrast == .increased ? 0.18 : 0.12))
                            : (isHovered ? (ThemeRuntime.isCosmos ? CosmosPalette.track : Palette.ink1.opacity(0.05)) : .clear)
                    )
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(CosmosPalette.accent)
                    .frame(width: 2)
                    .opacity(ThemeRuntime.isCosmos && isSelected ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text(section.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Liquid Glass controls

struct GlassToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let spring: Animation? = reduceMotion ? nil : .spring(duration: 0.24, bounce: 0.15)
        Button {
            if let spring {
                withAnimation(spring) {
                    configuration.isOn.toggle()
                }
            } else {
                configuration.isOn.toggle()
            }
        } label: {
            if ThemeRuntime.isCosmos {
                toggleTrack(configuration: configuration)
                    .contentShape(Rectangle())
                    .animation(spring, value: configuration.isOn)
            } else {
                toggleTrack(configuration: configuration)
                    .contentShape(Capsule())
                    .animation(spring, value: configuration.isOn)
            }
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Toggle(configuration)
                .toggleStyle(.switch)
        }
    }

    private func toggleTrack(configuration: Configuration) -> some View {
        ZStack(alignment: configuration.isOn ? .trailing : .leading) {
            track(isOn: configuration.isOn)
            knob(isOn: configuration.isOn)
                .padding(ThemeRuntime.isCosmos ? 3 : 2)
        }
        .frame(width: 40, height: 24)
    }

    @ViewBuilder
    private func track(isOn: Bool) -> some View {
        if ThemeRuntime.isCosmos {
            Rectangle()
                .fill(isOn ? CosmosPalette.accent : CosmosPalette.track)
                .overlay(Rectangle().strokeBorder(CosmosPalette.controlRule, lineWidth: 1))
        } else if reduceTransparency {
            Capsule()
                .fill(isOn ? Palette.roleAccent : Palette.sidebarSurface)
                .overlay {
                    if !isOn {
                        Capsule().strokeBorder(Palette.hairline, lineWidth: 1)
                    }
                }
        } else {
            ZStack {
                Capsule()
                    .fill(Palette.barTrack)
                    .themedGlass(.regular, in: .capsule)
                    .opacity(isOn ? 0 : 1)
                Capsule()
                    .fill(Palette.roleAccent)
                    .opacity(isOn ? 1 : 0)
            }
        }
    }

    @ViewBuilder
    private func knob(isOn: Bool) -> some View {
        if ThemeRuntime.isCosmos {
            Rectangle()
                .fill(isOn ? CosmosPalette.page : CosmosPalette.ink3)
                .frame(width: 16, height: 16)
                .overlay(Rectangle().strokeBorder(CosmosPalette.controlRule, lineWidth: 1))
        } else if reduceTransparency {
            Circle()
                .fill(Color.white)
                .frame(width: 20, height: 20)
                .overlay {
                    Circle().strokeBorder(Palette.hairline, lineWidth: 0.5)
                }
        } else {
            Circle()
                .fill(Color.white.opacity(0.85))
                .frame(width: 20, height: 20)
                .themedGlass(.regular.interactive(), in: .circle)
        }
    }
}

private struct GlassMenuPicker<SelectionValue: Hashable, CurrentLabel: View, Options: View>: View {
    let title: LocalizedStringKey
    @Binding var selection: SelectionValue
    let currentLabel: CurrentLabel
    let options: Options

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        _ title: LocalizedStringKey,
        selection: Binding<SelectionValue>,
        @ViewBuilder currentLabel: () -> CurrentLabel,
        @ViewBuilder options: () -> Options
    ) {
        self.title = title
        self._selection = selection
        self.currentLabel = currentLabel()
        self.options = options()
    }

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                options
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                currentLabel
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink1)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.ink2)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .modifier(SettingsActionPillSurface(reduceTransparency: reduceTransparency))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(Text(title))
    }
}

// MARK: - Shared group captions & rows

private struct SettingsGroupCaption<Trailing: View>: View {
    let title: LocalizedStringKey
    var description: LocalizedStringKey?
    let trailing: Trailing

    init(
        title: LocalizedStringKey,
        description: LocalizedStringKey? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.description = description
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink1)
                if let description {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            if Trailing.self != EmptyView.self {
                Spacer(minLength: 12)
                trailing
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension SettingsGroupCaption where Trailing == EmptyView {
    init(title: LocalizedStringKey, description: LocalizedStringKey? = nil) {
        self.init(title: title, description: description) {
            EmptyView()
        }
    }
}

private struct SettingsRowsGroup<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ThemeRuntime.isCosmos ? 0 : Radius.inner, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(ThemeRuntime.isCosmos ? CosmosPalette.panel : (reduceTransparency ? Palette.cardSurface : Palette.ink1.opacity(0.025)))
        }
        .overlay {
            if ThemeRuntime.isCosmos {
                shape.strokeBorder(CosmosPalette.controlRule, lineWidth: 1)
            } else if reduceTransparency {
                shape.strokeBorder(Palette.hairline, lineWidth: 1)
            }
        }
    }
}

private struct SettingsScanActionPill: View {
    @Environment(RefreshCoordinator.self) private var refreshCoordinator: RefreshCoordinator?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isSpinning = false

    private var isRefreshing: Bool {
        refreshCoordinator?.isRefreshing == true
    }

    var body: some View {
        Button {
            Task { await refreshCoordinator?.refresh() }
        } label: {
            HStack(spacing: 6) {
                if isRefreshing && reduceMotion {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.ink2)
                        .rotationEffect(.degrees(isSpinning ? 360 : 0))
                        .animation(
                            isSpinning ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                            value: isSpinning
                        )
                        .accessibilityHidden(true)
                }

                Text(isRefreshing ? "Scanning…" : "Scan now")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink1)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .modifier(SettingsActionPillSurface(reduceTransparency: reduceTransparency))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(refreshCoordinator == nil || isRefreshing)
        .opacity(refreshCoordinator == nil ? 0.45 : 1)
        .accessibilityLabel(Text(isRefreshing ? "Scanning…" : "Scan now"))
        .onChange(of: isRefreshing, initial: true) { _, refreshing in
            isSpinning = refreshing && !reduceMotion
        }
        .onChange(of: reduceMotion) { _, reduced in
            isSpinning = isRefreshing && !reduced
        }
    }
}

private struct SettingsActionPillSurface: ViewModifier {
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        if ThemeRuntime.isCosmos {
            content
                .background(CosmosPalette.background)
                .overlay(Rectangle().strokeBorder(CosmosPalette.controlRule, lineWidth: 1))
                .contentShape(Rectangle())
        } else if reduceTransparency {
            content
                .background { Capsule().fill(Palette.cardSurface) }
                .overlay { Capsule().strokeBorder(Palette.hairline, lineWidth: 1) }
                .contentShape(Capsule())
        } else {
            content
                .themedGlass(.regular.interactive(), in: .capsule)
                .contentShape(Capsule())
        }
    }
}

private struct SettingsControlRow<Accessory: View>: View {
    let title: LocalizedStringKey
    var help: LocalizedStringKey?
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Palette.ink1)
                if let help {
                    Text(help)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityHidden(true)
            Spacer(minLength: 12)
            if let help {
                accessory
                    .accessibilityHint(Text(help))
            } else {
                accessory
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: 48)
    }
}

private struct SettingsHairline: View {
    var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppModel.self) private var model
    @Environment(RefreshCoordinator.self) private var refreshCoordinator: RefreshCoordinator?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 36) {
            VStack(alignment: .leading, spacing: 10) {
                SettingsGroupCaption(
                    title: "Appearance",
                    description: settings.theme == .liquidGlass ? LocalizedStringKey("Theme, transparency, language, and number units.") : LocalizedStringKey("Theme, language, and number units.")
                )

                SettingsRowsGroup {
                    SettingsControlRow(title: "Theme") {
                        GlassMenuPicker("Theme", selection: $settings.theme) {
                            switch settings.theme {
                            case .liquidGlass:
                                Text("Liquid Glass")
                            case .field:
                                Text("Field")
                            case .cosmos:
                                Text("Cosmos")
                            }
                        } options: {
                            Text("Liquid Glass").tag(AppTheme.liquidGlass)
                            Text("Field").tag(AppTheme.field)
                            Text("Cosmos").tag(AppTheme.cosmos)
                        }
                    }

                    SettingsHairline()
                    SettingsControlRow(
                        title: "Light or dark",
                        help: settings.theme == .cosmos ? LocalizedStringKey("Cosmos is dark only.") : nil
                    ) {
                        GlassMenuPicker("Light or dark", selection: $settings.appearance) {
                            Text(settings.appearance.title)
                        } options: {
                            ForEach(AppAppearance.allCases) { appearance in
                                Text(appearance.title).tag(appearance)
                            }
                        }
                        .disabled(settings.theme == .cosmos)
                    }

                    if settings.theme == .liquidGlass {
                        SettingsHairline()
                        SettingsControlRow(title: "Interface transparency", help: "How much shows through the window") {
                            InterfaceTransparencySlider(value: $settings.interfaceTransparency)
                        }
                    }

                    SettingsHairline()
                    SettingsControlRow(title: "Language") {
                        GlassMenuPicker("Language", selection: $settings.language) {
                            Text(settings.language.title)
                        } options: {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.title).tag(language)
                            }
                        }
                    }

                    if settings.languageChangedThisSession {
                        SettingsHairline()
                        HStack(spacing: 16) {
                            Text("Some text changes language after relaunch.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 12)
                            if reduceTransparency && !ThemeRuntime.isCosmos {
                                Button("Relaunch") { settings.relaunch() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            } else {
                                Button("Relaunch") { settings.relaunch() }
                                    .themedGlassButton()
                                    .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 8)
                        .frame(minHeight: 48)
                    }

                    SettingsHairline()
                    SettingsControlRow(title: "Number units") {
                        GlassMenuPicker("Number units", selection: $settings.numberUnits) {
                            settings.numberUnits.title
                        } options: {
                            ForEach(NumberUnits.allCases) { unit in
                                unit.title.tag(unit)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SettingsGroupCaption(
                    title: "Data collection",
                    description: "Launch and background collection."
                )

                SettingsRowsGroup {
                    SettingsControlRow(title: "Launch at login") {
                        Toggle("Launch at login", isOn: $settings.launchAtLogin)
                            .labelsHidden()
                            .toggleStyle(GlassToggleStyle())
                            .accessibilityLabel(Text("Launch at login"))
                    }

                    if let error = settings.launchAtLoginError {
                        SettingsHairline()
                        Text(error)
                            .font(.system(size: 11.5))
                            .foregroundStyle(SourceHealth.State.failed.dotColor)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    }

                    if settings.launchAtLoginNeedsApproval {
                        SettingsHairline()
                        HStack(spacing: 16) {
                            Text("Allow Token Taken in System Settings › Login Items to finish.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.ink3)
                            Spacer(minLength: 12)
                            if reduceTransparency && !ThemeRuntime.isCosmos {
                                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            } else {
                                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                                    .themedGlassButton()
                                    .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 8)
                        .frame(minHeight: 48)
                    }

                    SettingsHairline()

                    TimelineView(.everyMinute) { _ in
                        HStack(spacing: 16) {
                            Text("Last updated")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(Palette.ink1)
                            Spacer(minLength: 12)
                            lastUpdatedText
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.ink2)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 8)
                        .frame(minHeight: 48)
                        .accessibilityElement(children: .combine)
                    }

                    if let error = model.storageError {
                        SettingsHairline()
                        Text(error)
                            .font(.system(size: 11.5))
                            .foregroundStyle(SourceHealth.State.failed.dotColor)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    }
                }
            }
        }
        .onAppear {
            settings.refreshLaunchAtLoginStatus()
        }
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

private struct InterfaceTransparencySlider: View {
    @Binding var value: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var reduceTransparencyHelp: LocalizedStringKey {
        "Reduce Transparency is on in System Settings."
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink2)
                .help(reduceTransparency ? Text(reduceTransparencyHelp) : Text("Solid"))
                .accessibilityHidden(true)
            Slider(value: $value, in: 0...1)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 140)
                .disabled(reduceTransparency)
                .help(reduceTransparency ? String(localized: "Reduce Transparency is on in System Settings.") : "")
                .accessibilityLabel(Text("Interface transparency"))
                .accessibilityHint(
                    reduceTransparency
                        ? Text(reduceTransparencyHelp)
                        : Text("How much shows through the window")
                )
            Image(systemName: "circle.dotted")
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink2)
                .help(reduceTransparency ? Text(reduceTransparencyHelp) : Text("Transparent"))
                .accessibilityHidden(true)
            Text(value, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink2)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Sources

private struct SourceLedgerEntry: Identifiable {
    let source: SourceInfo
    let health: SourceHealth

    var id: String { source.id }
}

private struct SourcesSettingsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(RefreshCoordinator.self) private var refreshCoordinator: RefreshCoordinator?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsNotInstalled = false
    @State private var localMonthBySource: [String: Int64] = [:]

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
        "devin": [".local/share/devin", "Library/Application Support/Devin"],
        "antigravity": [".gemini/antigravity-cli", ".gemini/antigravity"],
        "dsh": [".dsh"],
        "fx": [".fx"],
        "mcode": [".minimax/v2/sessions"],
        "deepseek-cli": [".deepseek/sessions"],
    ]

    var body: some View {
        TimelineView(.everyMinute) { context in
            let ledger = makeLedger(now: context.date)
            VStack(alignment: .leading, spacing: 36) {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsGroupCaption(
                        title: "Installed sources",
                        description: "Agents on this Mac whose logs are read."
                    ) {
                        SettingsScanActionPill()
                    }

                    SettingsRowsGroup {
                        if ledger.installed.isEmpty {
                            Text("No installed sources found")
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.ink3)
                                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        } else {
                            ForEach(Array(ledger.installed.enumerated()), id: \.element.id) { item in
                                if item.offset > 0 {
                                    SettingsHairline()
                                }
                                sourceRow(item.element, now: context.date)
                            }
                        }
                    }
                }

                if !ledger.notInstalled.isEmpty {
                    notInstalledGroup(ledger.notInstalled)
                }

                Text("Sources are identified automatically from local logs; no manual setup is needed.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showsNotInstalled)
        }
        .onAppear(perform: reloadLocalMonthUsage)
        .onChange(of: refreshCoordinator?.lastRefresh) { _, _ in reloadLocalMonthUsage() }
        .onChange(of: refreshCoordinator?.isRefreshing) { _, refreshing in
            if refreshing == false {
                reloadLocalMonthUsage()
            }
        }
    }

    private func reloadLocalMonthUsage() {
        if let store = refreshCoordinator?.store,
           let summary = try? UsageAggregator(store: store).summary(for: .month) {
            localMonthBySource = Dictionary(
                summary.bySource.map { ($0.id, $0.counts.total) },
                uniquingKeysWith: { first, _ in first }
            )
            return
        }
        if refreshCoordinator == nil, model.storageError == nil, model.period == .month {
            localMonthBySource = Dictionary(
                model.summary.bySource.map { ($0.id, $0.counts.total) },
                uniquingKeysWith: { first, _ in first }
            )
        } else {
            localMonthBySource = [:]
        }
    }

    private func makeLedger(now: Date) -> (installed: [SourceLedgerEntry], notInstalled: [SourceInfo]) {
        let healthByID = Dictionary(
            (refreshCoordinator?.health ?? []).map { ($0.sourceID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var installed: [(order: Int, entry: SourceLedgerEntry)] = []
        var notInstalled: [SourceInfo] = []

        for (index, source) in SourceCatalog.all.enumerated() {
            if let health = healthByID[source.id] {
                let currentHealth = health.markingStale(now: now)
                if currentHealth.state == .notInstalled {
                    notInstalled.append(source)
                } else {
                    installed.append((index, SourceLedgerEntry(source: source, health: currentHealth)))
                }
            } else if isDetectedOnDisk(source) {
                installed.append((index, SourceLedgerEntry(
                    source: source,
                    health: SourceHealth(sourceID: source.id, state: .stale)
                )))
            } else {
                notInstalled.append(source)
            }
        }

        let sortedInstalled = installed.sorted { lhs, rhs in
            let leftTokens = localMonthBySource[lhs.entry.id] ?? 0
            let rightTokens = localMonthBySource[rhs.entry.id] ?? 0
            if leftTokens != rightTokens {
                return leftTokens > rightTokens
            }
            return lhs.order < rhs.order
        }.map(\.entry)

        return (sortedInstalled, notInstalled)
    }

    private func isDetectedOnDisk(_ source: SourceInfo) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Self.dataLocations[source.id, default: []].contains { path in
            FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path)
        }
    }

    private func sourceRow(_ entry: SourceLedgerEntry, now: Date) -> some View {
        let monthTokens = localMonthBySource[entry.id] ?? 0
        return HStack(spacing: 12) {
            HStack(spacing: 9) {
                SourceMonogramBadge(sourceID: entry.source.id, name: entry.source.name)
                Text(verbatim: entry.source.name)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Palette.ink1)
                    .lineLimit(1)
            }
            .frame(width: 176, alignment: .leading)

            Group {
                if monthTokens > 0 {
                    Text("\(TokenFormat.short(monthTokens)) tokens")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink2)
                        .monospacedDigit()
                } else {
                    Text("No usage this month")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.ink3)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                SourceHealthLabel(state: entry.health.state)
                Text(verbatim: entry.health.lastSuccess.map { formattedDate($0, now: now) } ?? "—")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink3)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(width: 192, alignment: .trailing)
        }
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
        .help(entry.health.errorMessage ?? "")
    }

    private func notInstalledGroup(_ sources: [SourceInfo]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsGroupCaption(title: "Not installed")

            SettingsRowsGroup {
                Button {
                    showsNotInstalled.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.ink3)
                            .rotationEffect(.degrees(showsNotInstalled ? 90 : 0))
                            .frame(width: 12)
                            .accessibilityHidden(true)

                        Text("Not installed (\(sources.count))")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Palette.ink1)
                            .monospacedDigit()

                        Spacer(minLength: 12)

                        if !showsNotInstalled {
                            Text(verbatim: sources.map(\.name).joined(separator: " · "))
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.ink3)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onKeyPress(.leftArrow) {
                    guard showsNotInstalled else { return .ignored }
                    showsNotInstalled = false
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    guard !showsNotInstalled else { return .ignored }
                    showsNotInstalled = true
                    return .handled
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Not installed (\(sources.count))"))
                .accessibilityValue(showsNotInstalled ? Text("Expanded") : Text("Collapsed"))

                if showsNotInstalled {
                    SettingsHairline()
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .leading), count: 3),
                        alignment: .leading,
                        spacing: 10
                    ) {
                        ForEach(sources) { source in
                            HStack(spacing: 8) {
                                SourceMonogramBadge(sourceID: source.id, name: source.name, size: 20)
                                    .opacity(0.65)
                                Text(verbatim: source.name)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Palette.ink2)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
        }
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

private struct SourceHealthLabel: View {
    let state: SourceHealth.State

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(state.dotColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(state.ledgerTitle)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
        }
        .font(.system(size: 11.5, weight: state == .ok || state == .failed ? .semibold : .medium))
        .foregroundStyle(state.textColor)
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
            Palette.healthOK
        case .stale, .unavailable:
            Palette.healthWarn
        case .notInstalled:
            Palette.ink3
        case .failed:
            Color(light: "#C43E3E", dark: "#EF6B6B", contrastLight: "#962424", contrastDark: "#FF9494")
        }
    }

    var textColor: Color {
        switch self {
        case .ok:
            Palette.healthOK
        case .stale, .unavailable:
            Palette.healthWarn
        case .notInstalled:
            Palette.ink3
        case .failed:
            dotColor
        }
    }
}

// MARK: - Sync

private struct SyncSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppModel.self) private var model
    @Environment(RefreshCoordinator.self) private var refreshCoordinator: RefreshCoordinator?

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 36) {
            VStack(alignment: .leading, spacing: 10) {
                SettingsGroupCaption(
                    title: "iCloud sync",
                    description: "Share totals between your Macs through iCloud Drive."
                )

                SettingsRowsGroup {
                    SettingsControlRow(
                        title: "iCloud sync",
                        help: "Only aggregate token counts and a random device ID are stored in iCloud Drive."
                    ) {
                        Toggle("iCloud sync", isOn: $settings.syncEnabled)
                            .labelsHidden()
                            .toggleStyle(GlassToggleStyle())
                            .accessibilityLabel(Text("iCloud sync"))
                    }

                    if refreshCoordinator?.iCloudAvailable == false || ICloudSync.defaultRoot == nil {
                        SettingsHairline()
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.healthWarn)
                                .accessibilityHidden(true)
                            Text("iCloud Drive is not available on this Mac.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.healthWarn)
                        }
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    } else if settings.syncEnabled && refreshCoordinator?.syncFailed == true {
                        SettingsHairline()
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.healthWarn)
                                .accessibilityHidden(true)
                            Text("Unavailable")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.healthWarn)
                        }
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SettingsGroupCaption(title: "Devices")

                SettingsRowsGroup {
                    if !settings.syncEnabled {
                        Text("Turn on sync to see your other Macs here.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.ink3)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    } else if model.remoteDevices.isEmpty {
                        Text("No other Macs yet")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.ink3)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    } else {
                        TimelineView(.everyMinute) { _ in
                            VStack(spacing: 0) {
                                ForEach(Array(model.remoteDevices.enumerated()), id: \.element.deviceID) { entry in
                                    if entry.offset > 0 {
                                        SettingsHairline()
                                    }
                                    remoteRow(entry.element)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func remoteRow(_ device: RemoteDeviceStatus) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                (device.displayName == device.deviceID ? Text("Unknown Mac") : Text(verbatim: device.displayName))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Palette.ink1)
                if let lastWrite = device.lastWrite {
                    Text("Last synced \(Self.relativeFormatter.localizedString(for: lastWrite, relativeTo: .now))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.ink3)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 12)
            // Same 24 h rule as source health: an `.ok` snapshot that has not been rewritten since reads as stale.
            RemoteStatusLabel(state: device.state == .ok && device.lastWrite.map { Date.now.timeIntervalSince($0) > 86_400 } == true
                ? .stale : device.state)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 48)
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
        case .ok: Palette.healthOK
        case .stale, .partial, .unavailable: Palette.healthWarn
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(title)
        }
        .font(.system(size: 11.5, weight: state == .ok ? .semibold : .medium))
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - About

private struct AboutSettingsTab: View {
    let updateChecker: UpdateChecker

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var installationMessage: String?
    @State private var installationFailed = false

    private var version: String {
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(marketing) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 52, height: 52)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "Token Taken")
                        .font(.system(size: 19, weight: .bold))
                        .tracking(-0.2)
                        .foregroundStyle(Palette.ink1)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Local Agent token usage")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink3)
                        Text(verbatim: "·")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink3)
                            .accessibilityHidden(true)
                        Text(verbatim: version)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink2)
                            .monospacedDigit()
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            SettingsRowsGroup {
                updateRow
                SettingsHairline()
                AboutValueRow(label: "License", value: Text(verbatim: "MIT"))
                SettingsHairline()
                AboutValueRow(label: "Acknowledgements", value: Text(verbatim: "tokscale, TokenTracker"))
                SettingsHairline()
                AboutValueRow(label: "Privacy", value: Text("Read-only local Agent logs, no content uploads, no telemetry"))
            }

            SettingsRowsGroup {
                SettingsControlRow(title: "Command-Line Tool", help: "Use token-taken in Terminal") {
                    if reduceTransparency && !ThemeRuntime.isCosmos {
                        Button("Install Command-Line Tool", action: install)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else {
                        Button("Install Command-Line Tool", action: install)
                            .themedGlassButton()
                            .controlSize(.small)
                    }
                }

                if let installationMessage {
                    SettingsHairline()
                    Text(installationMessage)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(installationFailed ? SourceHealth.State.failed.dotColor : Palette.ink2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                }
            }
        }
    }

    private var updateRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Version")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Palette.ink1)
                    Text(verbatim: version)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink2)
                        .monospacedDigit()
                }
                updateStateLabel
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                if case .available(_, let url) = updateChecker.state {
                    if reduceTransparency && !ThemeRuntime.isCosmos {
                        Link("Download", destination: url)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else {
                        Link("Download", destination: url)
                            .themedGlassButton()
                            .controlSize(.small)
                    }
                }

                if reduceTransparency && !ThemeRuntime.isCosmos {
                    Button("Check for Updates") {
                        Task { await updateChecker.check() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(updateChecker.isChecking)
                } else {
                    Button("Check for Updates") {
                        Task { await updateChecker.check() }
                    }
                    .themedGlassButton()
                    .controlSize(.small)
                    .disabled(updateChecker.isChecking)
                }
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: 48)
    }

    @ViewBuilder
    private var updateStateLabel: some View {
        switch updateChecker.state {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Checking…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink3)
            }
        case .upToDate:
            Text("Up to date")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.ink3)
        case .available(let latestVersion, _):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Update available")
                Text(verbatim: "· \(latestVersion)")
                    .monospacedDigit()
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.roleAccent)
        case .noRelease:
            Text("No published release yet")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.ink3)
        case .failed(let message):
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(SourceHealth.State.failed.dotColor)
                .fixedSize(horizontal: false, vertical: true)
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
    let value: Text

    var body: some View {
        HStack(spacing: 16) {
            Text(label)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Palette.ink1)
            Spacer(minLength: 12)
            value
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink2)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
    }
}
