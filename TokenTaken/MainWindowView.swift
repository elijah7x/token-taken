import AppKit
import Observation
import SwiftUI
import TokenTakenKit

@Observable
@MainActor
final class MainWindowRouter {
    enum Route: Equatable { case dashboard, settings }

    var route: Route = .dashboard
    var settingsSection: SettingsSection = .general

    /// Shows Settings inside the main window, at the section that explains `issues` when present.
    func openSettings(
        for issues: AppModel.DataIssues? = nil,
        syncIssue: Bool = false,
        using openWindow: OpenWindowAction? = nil
    ) {
        if let issues {
            let onlySync = issues.count == 0 && issues.skippedRecords == 0 && (issues.devices > 0 || syncIssue)
            settingsSection = onlySync ? .sync : .sources
        } else if syncIssue {
            settingsSection = .sync
        }
        route = .settings
        openWindow?(id: MainWindowView.windowID)
        NSApplication.shared.activate()
    }
}

enum SettingsSection: CaseIterable, Hashable, Identifiable {
    case general
    case sources
    case sync
    case about

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .sources: "Harnesses"
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

/// The left tray holds window controls and summary data; the dashboard or Settings sits on the themed base.
struct MainWindowView: View {
    static let windowID = "main"

    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(MainWindowRouter.self) private var router
    @Environment(RefreshCoordinator.self) private var refreshCoordinator: RefreshCoordinator?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimension: BreakdownDimension = .sources
    @State private var isPresentingShare = false
    @State private var highlight: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    private var isFirstLaunchCollecting: Bool {
        model.isEmpty && refreshCoordinator?.isRefreshing == true
    }

    var body: some View {
        HStack(spacing: 0) {
            Tray(isFirstLaunchCollecting: isFirstLaunchCollecting)
                .frame(width: 264)
                .padding(ThemeChrome.trayInset)

            Group {
                switch router.route {
                case .dashboard:
                    dashboard
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { WindowBackdrop(theme: settings.theme, transparency: settings.interfaceTransparency) }
        .ignoresSafeArea(.container, edges: .top)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: router.route)
        .sheet(isPresented: $isPresentingShare) {
            ShareExportSheet(dimension: dimension)
        }
        .fontDesign(settings.theme == .field ? .serif : nil)
        .onAppear { settings.applyAppearance() }
        .onChange(of: colorScheme) { ThemeAppIcon.apply(settings.theme) }
        .onChange(of: dimension) {
            highlight = nil
        }
    }

    private var dimensionSwitchRow: some View {
        DimensionSwitchRow(
            period: model.period,
            summary: model.summary,
            dimension: $dimension,
            isPresentingShare: $isPresentingShare
        )
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    private var fieldItems: [Breakdown] {
        dimension == .sources ? model.summary.bySource : model.summary.byModel
    }

    private var highlightBinding: Binding<String?> {
        settings.theme == .liquidGlass ? .constant(nil) : $highlight
    }

    private var breakdownCard: some View {
        let fieldCrops: [String: FieldCrop] = settings.theme == .field
            ? FieldCrop.assign(fieldItems.filter { $0.counts.total > 0 })
            : [:]
        return BreakdownCard(
            summary: model.summary,
            dimension: dimension,
            highlight: highlightBinding,
            itemSubtitles: fieldCrops.mapValues { $0.label(locale: locale) },
            itemColors: fieldCrops.mapValues(\.color)
        )
    }

    @ViewBuilder
    private var dashboard: some View {
        if isFirstLaunchCollecting {
            FirstLaunchCollectingCard()
                .padding(28)
        } else if model.isEmpty {
            DashboardEmptyStateCard {
                router.settingsSection = (model.storageError == nil && model.readError == nil) ? .sources : .general
                router.openSettings()
            }
            .padding(28)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if settings.theme == .field {
                    // On macOS 26 the scroll view's AppKit frame reaches up under the title bar area and swallows
                    // clicks on anything laid out above it, so the switch row is a safe-area inset of the scroll view.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            FieldLandscapeView(items: fieldItems, highlight: $highlight)
                            FieldCompositionStrip(counts: model.summary.total)
                                .padding(.top, 14)
                            breakdownCard
                                .padding(.top, 20)
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                    }
                    .scrollEdgeEffectHidden(true, for: .top)
                    .safeAreaInset(edge: .top, spacing: 0) { dimensionSwitchRow }
                } else {
                    dimensionSwitchRow

                    if settings.theme == .cosmos {
                        CosmosSceneView(summary: model.summary, dimension: dimension, highlight: $highlight)
                            .frame(maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
                            .clipped()
                    } else if settings.theme == .liquidGlass && settings.liquidView == .lens {
                        LensView(
                            buckets: model.lensBuckets,
                            dimension: dimension,
                            period: model.period
                        )
                        .padding(.horizontal, 28)
                        .padding(.top, 4)
                        .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
                    } else {
                        ConfluenceView(summary: model.summary, dimension: dimension)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
                    }

                    breakdownCard
                        .padding(.horizontal, 28)
                        .padding(.top, 24)
                        .padding(.bottom, 24)
                }
            }
        }
    }
}

private struct DimensionSwitchRow: View {
    let period: Period
    let summary: UsageSummary
    @Binding var dimension: BreakdownDimension
    @Binding var isPresentingShare: Bool

    @Namespace private var switchNamespace
    @FocusState private var focusedDimension: BreakdownDimension?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch ThemeKind.current {
                case .cosmos:
                    let shape = RadiusRole.control.shape
                    HStack(spacing: 0) {
                        segment(.sources, label: "Harnesses")
                        segment(.models, label: "Models")
                    }
                    .background { shape.fill(CosmosPalette.background) }
                    .overlay { shape.strokeBorder(CosmosPalette.controlRule, lineWidth: ThemeChrome.ruleWidth) }
                case .field:
                    HStack(spacing: 12) {
                        segment(.sources, label: "Harnesses")
                        segment(.models, label: "Models")
                    }
                case .liquidGlass:
                    GlassEffectContainer(spacing: 0) {
                        HStack(spacing: 2) {
                            segment(.sources, label: "Harnesses")
                            segment(.models, label: "Models")
                        }
                        .padding(2)
                    }
                    .background { Capsule().fill(Palette.barTrack) }
                    .overlay { Capsule().strokeBorder(Palette.hairline, lineWidth: reduceTransparency ? 1 : ThemeChrome.ruleWidth) }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Breakdown view"))

            Spacer(minLength: 12)

            periodLabel
                .font(ThemeFont.role(.title))
                .foregroundStyle(Palette.ink2)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)

            Spacer(minLength: 12)

            Button {
                isPresentingShare = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    .frame(width: 28, height: 28)
                    .modifier(RoundGlassControlSurface(reduceTransparency: reduceTransparency))
            }
            .buttonStyle(FieldPlainButtonStyle())
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .help(Text("Share"))
            .accessibilityLabel(Text("Share"))
        }
    }

    @ViewBuilder
    private var periodLabel: some View {
        let start = summary.start
        switch period {
        case .day:
            Text("Today · \(start.formatted(.dateTime.locale(locale).month(.abbreviated).day()))")
        case .week:
            let today = Calendar.current.date(byAdding: .day, value: -1, to: summary.end) ?? start
            if Calendar.current.isDate(start, inSameDayAs: today) || today <= start {
                Text("This week · \(start.formatted(.dateTime.locale(locale).month(.abbreviated).day()))")
            } else {
                Text("This week · \(start.formatted(.dateTime.locale(locale).month(.abbreviated).day()))–\(today.formatted(.dateTime.locale(locale).month(.abbreviated).day()))")
            }
        case .month:
            Text(verbatim: start.formatted(.dateTime.locale(locale).year().month(.wide)))
        case .year:
            Text(verbatim: start.formatted(.dateTime.locale(locale).year()))
        case .all:
            Text("All time · since \(start.formatted(.dateTime.locale(locale).year().month(.abbreviated).day()))")
        }
    }

    private func segment(_ target: BreakdownDimension, label: LocalizedStringKey) -> some View {
        let isSelected = dimension == target
        return Button {
            select(target)
        } label: {
            Text(label)
                .font(ThemeFont.make(12, weight: isSelected ? .semibold : .medium, numeric: true))
                .foregroundStyle(isSelected ? Palette.ink1 : Palette.ink2)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 24)
                .padding(.horizontal, 12)
                .modifier(DimensionSegmentSurface(
                    isSelected: isSelected,
                    isFocused: focusedDimension == target,
                    reduceTransparency: reduceTransparency,
                    namespace: switchNamespace
                ))
        }
        .buttonStyle(FieldPlainButtonStyle())
        .focused($focusedDimension, equals: target)
        .onKeyPress(.leftArrow) {
            select(.sources)
            focusedDimension = .sources
            return .handled
        }
        .onKeyPress(.rightArrow) {
            select(.models)
            focusedDimension = .models
            return .handled
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func select(_ target: BreakdownDimension) {
        // No window-wide animation: animating the whole dashboard re-ran layout and pointer hit-testing on every
        // frame and froze the main thread for 1-1.7 s per switch with a real mouse. The charts animate themselves.
        dimension = target
    }
}

private struct DimensionSegmentSurface: ViewModifier {
    let isSelected: Bool
    let isFocused: Bool
    let reduceTransparency: Bool
    let namespace: Namespace.ID

    @State private var isHovered = false
    @Environment(\.fieldControlPressed) private var isPressed

    func body(content: Content) -> some View {
        switch ThemeKind.current {
        case .cosmos:
            let shape = RadiusRole.control.shape
            content
                .frame(minHeight: 28)
                .background { shape.fill(isSelected ? CosmosPalette.selection : .clear) }
                .contentShape(shape)
        case .field:
            content
                .background { Capsule().fill(FieldPalette.panel.opacity(isHovered || isPressed ? (isPressed ? 0.95 : 0.7) : 0)) }
                .overlay(alignment: .bottom) {
                    FieldFurrow()
                        .stroke(Palette.roleAccent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                        .frame(height: 5)
                        .padding(.horizontal, 8)
                        .opacity(isSelected ? 1 : 0)
                }
                .overlay {
                    if isFocused {
                        Capsule().strokeBorder(Palette.roleAccent, lineWidth: 1.5)
                    }
                }
                .contentShape(Capsule())
                .onHover { isHovered = $0 }
        case .liquidGlass:
            if !isSelected {
                content
                    .contentShape(Capsule())
            } else if reduceTransparency {
                content
                    .background { Capsule().fill(Palette.cardSurface) }
                    .overlay { Capsule().strokeBorder(Palette.hairline, lineWidth: 1) }
                    .contentShape(Capsule())
            } else {
                content
                    .themedGlass(.regular.interactive(), in: .capsule)
                    .glassEffectID("breakdownDimension", in: namespace)
                    .contentShape(Capsule())
            }
        }
    }
}

// MARK: - Tray

/// The themed tray: window controls, period selection, total and cost, then devices and sync.
/// In Settings it carries the section list instead.
private struct Tray: View {
    let isFirstLaunchCollecting: Bool

    @Environment(AppModel.self) private var model
    @Environment(MainWindowRouter.self) private var router
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RadiusRole.tray.shape
        VStack(alignment: .leading, spacing: 0) {
            // Clear band for the traffic lights, which sit inside the tray.
            Color.clear.frame(height: 46)

            switch router.route {
            case .dashboard:
                Group {
                    if ThemeKind.current == .liquidGlass {
                        PeriodSlider()
                    } else {
                        ThemedPeriodPicker()
                    }
                }
                .padding(.top, 20)

                SummaryRail(summary: model.summary, isCollecting: isFirstLaunchCollecting)
                    .padding(.top, 32)
                    .padding(.horizontal, 4)

                Spacer(minLength: 20)

                TrayDevices(summary: model.summary, isCollecting: isFirstLaunchCollecting)
                    .padding(.horizontal, 4)

                if ThemeKind.current != .field {
                    Rectangle().fill(Palette.hairline).frame(height: ThemeChrome.ruleWidth)
                        .padding(.vertical, 12)
                }

                TrayFooter(isFirstLaunchCollecting: isFirstLaunchCollecting)
                    .padding(.top, ThemeKind.current == .field ? 20 : 0)
            case .settings:
                SettingsSidebar()
                    .padding(.top, 10)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background { shape.fill(ThemeKind.current == .field ? FieldPalette.panel : Palette.traySurface) }
        .overlay {
            if ThemeKind.current != .field {
                shape.strokeBorder(Palette.trayRim, lineWidth: ThemeChrome.ruleWidth)
            }
        }
        .shadow(
            color: .black.opacity(ThemeKind.current == .field || ThemeChrome.trayInset == 0 || reduceTransparency ? 0 : (scheme == .dark ? 0.30 : 0.07)),
            radius: 14,
            x: 0,
            y: 4
        )
    }
}

/// Collection/sync mode on the left, refresh and Settings on the right.
private struct TrayFooter: View {
    let isFirstLaunchCollecting: Bool

    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(MainWindowRouter.self) private var router
    @Environment(RefreshCoordinator.self) private var refreshCoordinator: RefreshCoordinator?

    var body: some View {
        HStack(spacing: 6) {
            TimelineView(.everyMinute) { context in
                modeIndicator(now: context.date)
            }
            Spacer(minLength: 4)
            RefreshNowButton(refreshCoordinator: refreshCoordinator)
            TraySettingsButton()
        }
    }

    @ViewBuilder
    private func modeIndicator(now: Date) -> some View {
        if !settings.syncEnabled {
            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.ink3)
                    .accessibilityHidden(true)
                Text("Local only")
                    .font(ThemeFont.role(.caption))
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        } else {
            let isRefreshing = isFirstLaunchCollecting || refreshCoordinator?.isRefreshing == true
            let hasSyncWarning = !isRefreshing && hasSyncIssue(now: now)
            if hasSyncWarning {
                Button {
                    router.openSettings(syncIssue: true)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "icloud")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Palette.healthWarn)
                            .accessibilityHidden(true)
                        Text("iCloud sync")
                            .font(ThemeFont.role(.sectionHeader))
                            .foregroundStyle(Palette.healthWarn)
                            .lineLimit(1)
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.healthWarn)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(syncWarningTooltip)
                .accessibilityLabel(Text("iCloud sync"))
                .accessibilityValue(Text(syncWarningAccessibilityValue))
                .accessibilityHint(Text("Opens Settings"))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "icloud")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.ink3)
                        .accessibilityHidden(true)
                    Text("iCloud sync")
                        .font(ThemeFont.role(.caption))
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(1)
                    Circle()
                        .fill(isRefreshing ? Palette.healthScan : Palette.healthOK)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("iCloud sync"))
                .accessibilityValue(Text(isRefreshing ? "Updating…" : "Synced"))
            }
        }
    }

    private func hasSyncIssue(now: Date) -> Bool {
        if refreshCoordinator?.iCloudAvailable == false || refreshCoordinator?.syncFailed == true || ICloudSync.defaultRoot == nil {
            return true
        }
        if model.dataIssues(now: now).devices > 0 {
            return true
        }
        return model.remoteDevices.contains { $0.isStaleOrIncomplete(now: now) }
    }

    private var syncWarningTooltip: String {
        if refreshCoordinator?.iCloudAvailable == false || ICloudSync.defaultRoot == nil {
            return String(localized: "iCloud Drive is not available on this Mac.")
        }
        return model.statusTooltip(refreshCoordinator: refreshCoordinator)
    }

    private var syncWarningAccessibilityValue: LocalizedStringKey {
        if refreshCoordinator?.iCloudAvailable == false
            || ICloudSync.defaultRoot == nil
            || refreshCoordinator?.syncFailed == true
            || model.remoteDevices.contains(where: { $0.effectiveState() == .unavailable }) {
            return "Unavailable"
        }
        if model.remoteDevices.contains(where: { $0.effectiveState() == .partial }) {
            return "Partial"
        }
        return "Stale"
    }
}

private struct TraySettingsButton: View {
    @Environment(MainWindowRouter.self) private var router
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button {
            router.openSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink2)
                .frame(width: 28, height: 28)
                .modifier(RoundGlassControlSurface(reduceTransparency: reduceTransparency))
        }
        .buttonStyle(FieldPlainButtonStyle())
        .help(Text("Settings (⌘,)"))
        .accessibilityLabel(Text("Settings"))
    }
}

struct RefreshNowButton: View {
    let refreshCoordinator: RefreshCoordinator?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isSpinning = false

    private var isRefreshing: Bool {
        refreshCoordinator?.isRefreshing == true
    }

    private var showsUpdatingText: Bool {
        isRefreshing && reduceMotion
    }

    var body: some View {
        Button {
            Task { await refreshCoordinator?.refresh() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .rotationEffect(.degrees(isSpinning ? 360 : 0))
                    .animation(
                        isSpinning ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                        value: isSpinning
                    )
                    .accessibilityHidden(true)
                if showsUpdatingText {
                    Text("Updating…")
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .font(ThemeFont.role(.control))
            .foregroundStyle(Palette.ink2)
            .padding(.horizontal, showsUpdatingText ? 8 : 0)
            .frame(width: showsUpdatingText ? nil : 28, height: 28)
            .modifier(RoundGlassControlSurface(reduceTransparency: reduceTransparency, isCapsule: showsUpdatingText))
        }
        .buttonStyle(FieldPlainButtonStyle())
        .disabled(refreshCoordinator == nil || isRefreshing)
        .opacity(refreshCoordinator == nil ? 0.45 : 1)
        .help(Text(isRefreshing ? "Updating…" : "Refresh now"))
        .accessibilityLabel(Text(isRefreshing ? "Updating…" : "Refresh now"))
        .onChange(of: isRefreshing, initial: true) { _, refreshing in
            isSpinning = refreshing && !reduceMotion
        }
        .onChange(of: reduceMotion) { _, reduced in
            isSpinning = isRefreshing && !reduced
        }
    }
}

private struct RoundGlassControlSurface: ViewModifier {
    let reduceTransparency: Bool
    var isCapsule = false

    @State private var isHovered = false
    @Environment(\.fieldControlPressed) private var isPressed

    func body(content: Content) -> some View {
        switch ThemeKind.current {
        case .cosmos:
            let shape = RadiusRole.control.shape
            content
                .background { shape.fill(CosmosPalette.background) }
                .overlay { shape.strokeBorder(CosmosPalette.controlRule, lineWidth: ThemeChrome.ruleWidth) }
                .contentShape(shape)
        case .field:
            let opacity = isHovered || isPressed ? (isPressed ? 0.95 : 0.7) : 0
            if isCapsule {
                content
                    .background { Capsule().fill(FieldPalette.panel.opacity(opacity)) }
                    .contentShape(Capsule())
                    .onHover { isHovered = $0 }
            } else {
                content
                    .background { Circle().fill(FieldPalette.panel.opacity(opacity)) }
                    .contentShape(Circle())
                    .onHover { isHovered = $0 }
            }
        case .liquidGlass:
            if reduceTransparency {
                if isCapsule {
                    content
                        .background { Capsule().fill(Palette.cardSurface) }
                        .overlay { Capsule().strokeBorder(Palette.hairline, lineWidth: 1) }
                        .contentShape(Capsule())
                } else {
                    content
                        .background { Circle().fill(Palette.cardSurface) }
                        .overlay { Circle().strokeBorder(Palette.hairline, lineWidth: 1) }
                        .contentShape(Circle())
                }
            } else if isCapsule {
                content
                    .background { Capsule().fill(isHovered ? Palette.barTrack : .clear) }
                    .contentShape(Capsule())
                    .onHover { isHovered = $0 }
            } else {
                content
                    .background { Circle().fill(isHovered ? Palette.barTrack : .clear) }
                    .contentShape(Circle())
                    .onHover { isHovered = $0 }
            }
        }
    }
}

// MARK: - First-launch collecting & empty states

private struct FirstLaunchCollectingCard: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    private var collectingSubtitle: LocalizedStringKey {
        if settings.theme == .liquidGlass && settings.liquidView == .confluence {
            return "Reading supported agent logs in read-only mode. Your Confluence chart will appear automatically when finished."
        }
        return "Reading supported agent logs in read-only mode. Your usage overview will appear automatically when finished."
    }

    @ViewBuilder
    var body: some View {
        let content = VStack(spacing: 16) {
            CollectingVesselGlyph()
                .frame(width: 56, height: 72)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Collecting Token usage on this Mac for the first time")
                    .font(ThemeFont.role(.title, size: 17))
                    .foregroundStyle(Palette.ink1)
                    .multilineTextAlignment(.center)

                Text(collectingSubtitle)
                    .font(ThemeFont.role(.body))
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ProgressView()
                .progressViewStyle(.linear)
                .tint(Palette.healthScan)
                .frame(maxWidth: 320)
                .accessibilityLabel(Text("Collecting for the first time"))

            Text("Everything is computed offline on this Mac; logs are never modified or uploaded.")
                .font(ThemeFont.role(.caption))
                .foregroundStyle(Palette.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: 480)
        if settings.theme == .field {
            content
        } else {
            content.atmosphereCard(reduceTransparency: reduceTransparency, isDark: scheme == .dark)
        }
    }
}

private struct CollectingVesselGlyph: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if ThemeRuntime.isCosmos {
            ZStack {
                Rectangle().fill(CosmosPalette.background)
                Circle()
                    .stroke(CosmosPalette.ink2, lineWidth: 1)
                    .frame(width: 20, height: 20)
                Ellipse()
                    .stroke(CosmosPalette.accent, lineWidth: 1)
                    .frame(width: 40, height: 12)
                    .rotationEffect(.degrees(-12))
            }
            .padding(4)
            .overlay(Rectangle().strokeBorder(CosmosPalette.controlRule, lineWidth: 1))
        } else if ThemeRuntime.isField {
            fieldBody
        } else {
            liquidBody
        }
    }

    private var fieldBody: some View {
        let colors = FieldColors.cached(isDark: scheme == .dark)
        return Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
            let clip = Path(roundedRect: rect, cornerRadius: 12, style: .continuous)
            context.clip(to: clip)

            var mound = Path()
            let groundY = rect.maxY - 14
            mound.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            mound.addLine(to: CGPoint(x: rect.minX, y: groundY + 4))
            mound.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: groundY + 4),
                control: CGPoint(x: rect.midX, y: groundY - 6)
            )
            mound.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            mound.closeSubpath()
            context.fill(mound, with: .color(colors.soil.color))

            let base = CGPoint(x: rect.midX, y: groundY + 1)
            let top = CGPoint(x: rect.midX, y: rect.minY + 20)
            var stem = Path()
            stem.move(to: base)
            stem.addQuadCurve(to: top, control: CGPoint(x: rect.midX - 2, y: (base.y + top.y) / 2))
            context.stroke(
                stem,
                with: .color(colors.stem.color),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )

            var leftLeaf = Path()
            leftLeaf.move(to: CGPoint(x: rect.midX - 0.5, y: top.y + 10))
            leftLeaf.addCurve(
                to: CGPoint(x: rect.midX - 15, y: top.y - 2),
                control1: CGPoint(x: rect.midX - 10, y: top.y + 10),
                control2: CGPoint(x: rect.midX - 16, y: top.y + 4)
            )
            leftLeaf.addCurve(
                to: CGPoint(x: rect.midX - 0.5, y: top.y + 10),
                control1: CGPoint(x: rect.midX - 9, y: top.y - 4),
                control2: CGPoint(x: rect.midX - 2, y: top.y + 2)
            )
            leftLeaf.closeSubpath()
            context.fill(leftLeaf, with: .color(colors.hedge.color))

            var rightLeaf = Path()
            rightLeaf.move(to: CGPoint(x: rect.midX + 0.5, y: top.y + 6))
            rightLeaf.addCurve(
                to: CGPoint(x: rect.midX + 14, y: top.y - 6),
                control1: CGPoint(x: rect.midX + 9, y: top.y + 5),
                control2: CGPoint(x: rect.midX + 15, y: top.y)
            )
            rightLeaf.addCurve(
                to: CGPoint(x: rect.midX + 0.5, y: top.y + 6),
                control1: CGPoint(x: rect.midX + 8, y: top.y - 7),
                control2: CGPoint(x: rect.midX + 2, y: top.y - 1)
            )
            rightLeaf.closeSubpath()
            context.fill(rightLeaf, with: .color(colors.hedge.mix(colors.crops[FieldCrop.tea.rawValue], 0.5).color))
        }
    }

    @ViewBuilder
    private var liquidBody: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
                let clip = Path(roundedRect: rect, cornerRadius: 16, style: .continuous)
                context.clip(to: clip)

                context.fill(
                    Path(rect),
                    with: .color(Palette.barTrack)
                )

                let waterTop = rect.minY + rect.height * 0.44
                var water = Path()
                water.move(to: CGPoint(x: rect.minX, y: waterTop))
                water.addQuadCurve(
                    to: CGPoint(x: rect.maxX, y: waterTop),
                    control: CGPoint(x: rect.midX, y: waterTop + 5)
                )
                water.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                water.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                water.closeSubpath()
                context.fill(water, with: .color(Palette.healthScan.opacity(scheme == .dark ? 0.34 : 0.24)))

                var meniscus = Path()
                meniscus.move(to: CGPoint(x: rect.minX + 1, y: waterTop))
                meniscus.addQuadCurve(
                    to: CGPoint(x: rect.maxX - 1, y: waterTop),
                    control: CGPoint(x: rect.midX, y: waterTop + 5)
                )
                context.stroke(
                    meniscus,
                    with: .color(.white.opacity(scheme == .dark ? 0.45 : 0.85)),
                    lineWidth: 1.6
                )

                let drop1 = CGRect(x: rect.midX - 2.5, y: rect.minY + 12, width: 5, height: 5)
                let drop2 = CGRect(x: rect.midX - 8, y: rect.minY + 21, width: 4, height: 4)
                context.fill(Path(ellipseIn: drop1), with: .color(Palette.color(forSource: "codex").opacity(0.72)))
                context.fill(Path(ellipseIn: drop2), with: .color(Palette.color(forSource: "zcode").opacity(0.72)))

                let caustic = CGRect(x: rect.minX + 5, y: rect.minY + 6, width: 4, height: rect.height - 12)
                context.fill(
                    Path(roundedRect: caustic, cornerRadius: 2),
                    with: .color(.white.opacity(scheme == .dark ? 0.16 : 0.52))
                )
            }

            if !reduceTransparency {
                Color.clear
                    .padding(4)
                    .themedGlass(.regular, in: .rect(cornerRadius: 16))
                    .opacity(0.35)
            }

            shape
                .strokeBorder(Palette.hairline, lineWidth: 1)
                .padding(4)
        }
    }
}

private struct DashboardEmptyStateCard: View {
    let openSettings: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(RefreshCoordinator.self) private var refreshCoordinator: RefreshCoordinator?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    private var emptyContent: (symbol: String, color: Color, title: LocalizedStringKey, detail: Text) {
        if let error = model.storageError ?? model.readError {
            return (
                "exclamationmark.triangle",
                Palette.healthWarn,
                "Storage unavailable",
                Text(error)
            )
        }
        if let refreshCoordinator {
            switch refreshCoordinator.engineStatus {
            case .found:
                break
            case .missing:
                return (
                    "exclamationmark.triangle",
                    Palette.healthWarn,
                    "Collection engine not found",
                    Text("Token Taken could not find the collection engine on this Mac. Reinstall the app or use Scan now in Settings › Harnesses for native harnesses, or turn on iCloud sync.")
                )
            case .invalidOverride:
                return (
                    "exclamationmark.triangle",
                    Palette.healthWarn,
                    "Invalid engine override",
                    Text("The custom collection engine path is invalid or not executable. Fix or clear the override, or turn on iCloud sync to view usage from other Macs.")
                )
            }
        }
        return (
            ThemeKind.current == .cosmos ? "circle.circle" : (ThemeKind.current == .field ? "leaf" : "drop"),
            ThemeKind.current == .cosmos ? Palette.roleAccent : (ThemeKind.current == .field ? FieldPalette.hedge : Palette.ink2),
            "No usage collected yet",
            Text("Token Taken reads supported agent logs on this Mac. Use Scan now in Settings › Harnesses, or turn on iCloud sync to view usage from other Macs.")
        )
    }

    @ViewBuilder
    var body: some View {
        let content = emptyContent
        let stateContent = VStack(spacing: 16) {
            Image(systemName: content.symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(content.color)
                .frame(width: 48, height: 48)
                .background {
                    if ThemeKind.current != .field {
                        RadiusRole.inner.shape
                            .fill(Palette.barTrack)
                    }
                }
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(content.title)
                    .font(ThemeFont.role(.title, size: 17))
                    .foregroundStyle(Palette.ink1)
                    .multilineTextAlignment(.center)

                content.detail
                    .font(ThemeFont.role(.body))
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if reduceTransparency && ThemeKind.current == .liquidGlass {
                Button("Open Settings…", action: openSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            } else {
                Button("Open Settings…", action: openSettings)
                    .themedGlassButton()
                    .controlSize(.regular)
            }
        }
        .padding(28)
        .frame(maxWidth: 460)
        if ThemeKind.current == .field {
            stateContent
        } else {
            stateContent.atmosphereCard(reduceTransparency: reduceTransparency, isDark: scheme == .dark)
        }
    }
}

// MARK: - AppModel status helpers

extension AppModel {
    static let statusIssueDotColor = Palette.healthWarn
    static let statusIssueTextColor = Palette.healthWarn

    var hasStatusIssue: Bool {
        hasEngineIssue || dataIssues.isPartial || remoteDevices.contains { $0.isStaleOrIncomplete() }
    }

    var statusIssueNote: LocalizedStringKey? {
        let issues = dataIssues
        guard issues.isPartial || remoteDevices.contains(where: { $0.isStaleOrIncomplete() }) else {
            return nil
        }
        if issues.stale > 0, issues.failed == 0, issues.unavailable == 0 {
            return issues.stale == 1 ? "1 harness stale" : "\(issues.stale) harnesses stale"
        }
        if issues.count > 0 {
            return issues.count == 1 ? "1 harness unavailable" : "\(issues.count) harnesses unavailable"
        }
        if let remoteNote = issues.remoteIssueNote {
            return remoteNote
        }
        return "data may be incomplete"
    }

    func statusTooltip(refreshCoordinator: RefreshCoordinator?) -> String {
        guard hasStatusIssue else { return "" }
        var lines: [String] = []
        if let refreshCoordinator {
            switch refreshCoordinator.engineStatus {
            case .found:
                break
            case .missing:
                lines.append(String(localized: "Collection engine not found"))
            case .invalidOverride:
                lines.append(String(localized: "Invalid engine override"))
            }
        }
        let health = refreshCoordinator?.health.map { $0.markingStale() } ?? []
        for entry in health {
            let state: String? = switch entry.state {
            case .ok:
                entry.skippedRecords > 0 ? String(localized: "Partial") : nil
            case .unavailable:
                String(localized: "Unavailable")
            case .failed:
                String(localized: "Failed")
            case .stale:
                String(localized: "Stale")
            case .notInstalled:
                nil
            }
            if let state {
                let name = SourceCatalog.info(for: entry.sourceID).name
                lines.append(String(localized: "\(name): \(state)"))
            }
        }
        for device in remoteDevices {
            let state: String? = switch device.effectiveState() {
            case .ok:
                nil
            case .stale:
                String(localized: "Stale")
            case .partial:
                String(localized: "Partial")
            case .unavailable:
                String(localized: "Unavailable")
            }
            if let state {
                lines.append(String(localized: "\(device.displayName): \(state)"))
            }
        }
        if lines.isEmpty, let error = storageError ?? readError {
            lines.append(error)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Liquid fill period selector

/// Five-detent liquid-filled selector whose leading meniscus replaces a separate thumb.
private struct PeriodSlider: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private let periods = Period.allCases
    private let controlWidth: CGFloat = 224
    private let trackHeight: CGFloat = 8
    private let trackTop: CGFloat = 6
    private let horizontalInset: CGFloat = 10

    @State private var dragProgress: Double?
    @State private var stretchAmount: CGFloat = 0
    @State private var settleTask: Task<Void, Never>?

    private var selectedIndex: Int {
        periods.firstIndex(of: model.period) ?? 0
    }

    private var currentProgress: Double {
        dragProgress ?? Double(selectedIndex)
    }

    private var activePeriod: Period {
        let index = min(max(Int(currentProgress.rounded()), 0), periods.count - 1)
        return periods[index]
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let span = width - horizontalInset * 2
            let step = span / CGFloat(max(periods.count - 1, 1))
            let centerY = trackTop + trackHeight / 2
            let liquidX = horizontalInset + CGFloat(currentProgress) * step
            let fillWidth = liquidX + 2

            ZStack {
                PeriodGroove(isDark: scheme == .dark)
                    .frame(width: width, height: trackHeight)
                    .position(x: width / 2, y: centerY)

                LiquidPeriodFill(reduceMotion: reduceMotion)
                    .frame(width: fillWidth, height: trackHeight)
                    .position(x: fillWidth / 2, y: centerY)

                ForEach(Array(periods.enumerated()), id: \.element.id) { index, _ in
                    let detentX = horizontalInset + CGFloat(index) * step
                    let isWet = detentX < liquidX - 5
                    Circle()
                        .fill(isWet ? Color.white.opacity(0.85) : Palette.ink3.opacity(0.5))
                        .frame(width: 3, height: 3)
                        .scaleEffect(isWet ? 0.8 : 1)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isWet)
                        .position(x: detentX, y: centerY)
                }

                LiquidMeniscusHead()
                    .frame(width: 16, height: 14)
                    .scaleEffect(
                        x: reduceMotion ? 1 : (1 + 0.35 * stretchAmount),
                        y: reduceMotion ? 1 : (1 - 0.15 * stretchAmount)
                    )
                    .position(x: liquidX, y: centerY)

                ForEach(Array(periods.enumerated()), id: \.element.id) { index, period in
                    let isSelected = activePeriod == period
                    Text(period.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Palette.ink1 : Palette.ink3)
                        .lineLimit(1)
                        .fixedSize()
                        .scaleEffect(isSelected ? 1.14 : 1)
                        .frame(minWidth: 36, minHeight: 20)
                        .animation(
                            reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.62),
                            value: activePeriod
                        )
                        .position(x: horizontalInset + CGFloat(index) * step, y: 30)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        settleTask?.cancel()
                        guard abs(value.translation.width) > 1.5 else { return }
                        let clampedX = min(max(value.location.x, horizontalInset), horizontalInset + span)
                        dragProgress = Double((clampedX - horizontalInset) / step)
                        if !reduceMotion {
                            let velocityRatio = min(abs(value.velocity.width) / 650, 1)
                            withAnimation(.interactiveSpring(response: 0.14, dampingFraction: 0.78)) {
                                stretchAmount = velocityRatio
                            }
                        }
                    }
                    .onEnded { value in
                        let clampedX = min(max(value.location.x, horizontalInset), horizontalInset + span)
                        let rawProgress = Double((clampedX - horizontalInset) / step)
                        let targetIndex = min(max(Int(rawProgress.rounded()), 0), periods.count - 1)
                        let target = periods[targetIndex]
                        let wasDragged = dragProgress != nil

                        if wasDragged {
                            let settle: Animation? = reduceMotion
                                ? nil
                                : .spring(response: 0.42, dampingFraction: 0.62)
                            withAnimation(settle) {
                                dragProgress = nil
                                stretchAmount = 0
                                model.period = target
                            }
                        } else {
                            select(target)
                        }
                    }
            )
        }
        .frame(width: controlWidth, height: 42)
        // Focusable only with system keyboard navigation on, so launch shows no focus ring.
        .focusable(interactions: .activate)
        .onKeyPress(.leftArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onDisappear {
            settleTask?.cancel()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Usage period"))
        .accessibilityValue(Text(model.period.title))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                moveSelection(by: 1)
            case .decrement:
                moveSelection(by: -1)
            @unknown default:
                break
            }
        }
        .background {
            HStack(spacing: 0) {
                ForEach(periods) { period in
                    Button(period.title) {
                        select(period)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(period.shortcutKey, modifiers: .command)
                    .focusable(false)
                }
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func select(_ period: Period) {
        guard period != model.period else { return }
        let oldIndex = selectedIndex
        let newIndex = periods.firstIndex(of: period) ?? oldIndex
        let distance = abs(newIndex - oldIndex)

        settleTask?.cancel()
        if reduceMotion {
            stretchAmount = 0
            model.period = period
            return
        }

        let peakStretch = min(1.0, 0.55 + 0.15 * CGFloat(distance))
        withAnimation(.easeOut(duration: 0.10)) {
            stretchAmount = peakStretch
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
            model.period = period
        }
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(105))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
                stretchAmount = 0
            }
        }
    }

    private func moveSelection(by offset: Int) {
        let newIndex = min(max(selectedIndex + offset, 0), periods.count - 1)
        select(periods[newIndex])
    }
}

private struct PeriodGroove: View {
    let isDark: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        shape
            .fill(isDark ? Color.black.opacity(0.30) : Palette.barTrack)
            .overlay {
                shape
                    .stroke(
                        isDark ? Color.black.opacity(0.45) : Color(hex: "#0F172A").opacity(0.14),
                        lineWidth: 1
                    )
                    .blur(radius: 0.75)
                    .offset(y: 0.5)
                    .mask(shape)
            }
            .shadow(
                color: isDark ? Color.white.opacity(0.06) : Color.white.opacity(0.9),
                radius: 0,
                y: 1
            )
    }
}

private struct LiquidPeriodFill: View {
    let reduceMotion: Bool

    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var windowVisible = true

    /// The sheen only needs redrawing while the window is on screen and key.
    private var sheenActive: Bool { appearsActive && controlActiveState == .key && windowVisible }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        shape
            .fill(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color(hex: "#7CC8F2").opacity(0.55), location: 0),
                        .init(color: Color(hex: "#7CC8F2"), location: 0.45),
                        .init(color: Color(hex: "#3A9BE0"), location: 1),
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.55))
                    .frame(height: 1)
                    .padding(.horizontal, 2)
            }
            .overlay(alignment: .leading) {
                if !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !sheenActive)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 3.6) / 3.6
                        let easedPhase = phase * phase * (3 - 2 * phase)
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [.clear, Color.white.opacity(0.45), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: 60, height: 8)
                            .offset(x: CGFloat(-60 + 320 * easedPhase))
                    }
                }
            }
            .background { WindowVisibilityProbe { windowVisible = $0 } }
            .clipShape(shape)
            .shadow(color: Color(hex: "#7CC8F2").opacity(0.35), radius: 5)
    }
}

private struct LiquidMeniscusHead: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color(hex: "#E6F6FF"), location: 0),
                        .init(color: Color(hex: "#E6F6FF"), location: 0.12),
                        .init(color: Color(hex: "#7CC8F2"), location: 0.45),
                        .init(color: Color(hex: "#3A9BE0"), location: 1),
                    ]),
                    center: UnitPoint(x: 0.38, y: 0.30),
                    startRadius: 0,
                    endRadius: 9
                )
            )
            .shadow(color: Color(hex: "#3A9BE0").opacity(0.45), radius: 2, y: 1)
    }
}

extension Period {
    var shortcutKey: KeyEquivalent {
        switch self {
        case .day: "1"
        case .week: "2"
        case .month: "3"
        case .year: "4"
        case .all: "5"
        }
    }
}
