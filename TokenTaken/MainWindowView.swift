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
    @State private var fieldHighlight: String?
    @State private var cosmosHighlight: String?
    @Environment(\.colorScheme) private var colorScheme

    private var isFirstLaunchCollecting: Bool {
        model.isEmpty && refreshCoordinator?.isRefreshing == true
    }

    var body: some View {
        HStack(spacing: 0) {
            Tray(isFirstLaunchCollecting: isFirstLaunchCollecting)
                .frame(width: settings.theme == .cosmos ? 252 : 264)
                .padding(settings.theme == .cosmos ? 0 : 8)

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
    }

    private var dimensionSwitchRow: some View {
        DimensionSwitchRow(
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

    @ViewBuilder
    private var dashboard: some View {
        if isFirstLaunchCollecting {
            FirstLaunchCollectingCard()
                .padding(28)
        } else if model.isEmpty {
            DashboardEmptyStateCard { router.openSettings() }
                .padding(28)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if settings.theme == .field {
                    // On macOS 26 the scroll view's AppKit frame reaches up under the title bar area and swallows
                    // clicks on anything laid out above it, so the switch row is a safe-area inset of the scroll view.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            FieldLandscapeView(items: fieldItems, highlight: $fieldHighlight)
                            FieldBreakdownList(items: fieldItems, total: model.summary.total.total, highlight: $fieldHighlight)
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 8)
                    }
                    .scrollEdgeEffectHidden(true, for: .top)
                    .safeAreaInset(edge: .top, spacing: 0) { dimensionSwitchRow }
                } else {
                    dimensionSwitchRow

                    if settings.theme == .cosmos {
                        CosmosSceneView(summary: model.summary, dimension: dimension, highlight: $cosmosHighlight)
                            .frame(maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
                    } else if settings.theme == .liquidGlass && settings.liquidView == .lens {
                        LensView(
                            buckets: model.lensBuckets,
                            dimension: dimension,
                            period: model.period,
                            slice: { model.lensSlice($0) }
                        )
                        .padding(.horizontal, 28)
                        .padding(.top, 4)
                        .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
                    } else {
                        ConfluenceView(summary: model.summary, dimension: dimension)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
                    }

                    Rectangle().fill(Palette.hairline).frame(height: 1)
                        .padding(.horizontal, 28)
                        .padding(.vertical, settings.theme == .cosmos ? 12 : 24)

                    BreakdownCard(summary: model.summary, dimension: dimension)
                        .padding(.horizontal, 28)
                        .background(settings.theme == .cosmos ? CosmosPalette.background : .clear)
                }
            }
            .padding(.bottom, settings.theme == .cosmos ? 16 : 24)
        }
    }
}

private struct DimensionSwitchRow: View {
    let summary: UsageSummary
    @Binding var dimension: BreakdownDimension
    @Binding var isPresentingShare: Bool

    @Namespace private var switchNamespace
    @FocusState private var focusedDimension: BreakdownDimension?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 12) {
            if ThemeRuntime.isCosmos {
                Spacer(minLength: 12)
            }

            Group {
                if ThemeRuntime.isCosmos {
                    HStack(spacing: 0) {
                        segment(.sources, label: "Harnesses · \(summary.bySource.count)")
                        segment(.models, label: "Models · \(summary.byModel.count)")
                    }
                    .background(CosmosPalette.background)
                    .overlay(Rectangle().strokeBorder(CosmosPalette.controlRule, lineWidth: 1))
                } else {
                    GlassEffectContainer(spacing: 0) {
                        HStack(spacing: 2) {
                            segment(.sources, label: "Harnesses · \(summary.bySource.count)")
                            segment(.models, label: "Models · \(summary.byModel.count)")
                        }
                        .padding(2)
                    }
                    .background(Capsule().fill(Palette.barTrack))
                    .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: reduceTransparency ? 1 : 0.5))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Breakdown view"))

            Spacer(minLength: 12)

            Button {
                isPresentingShare = true
            } label: {
                if ThemeRuntime.isCosmos {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                            .accessibilityHidden(true)
                        Text("Share snapshot")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CosmosPalette.ink2)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(CosmosPalette.background)
                    .overlay(Rectangle().strokeBorder(CosmosPalette.controlRule, lineWidth: 1))
                    .contentShape(Rectangle())
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ink2)
                        .frame(width: 28, height: 28)
                        .modifier(RoundGlassControlSurface(reduceTransparency: reduceTransparency))
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .help(Text("Share"))
            .accessibilityLabel(Text("Share"))
        }
    }

    private func segment(_ target: BreakdownDimension, label: LocalizedStringKey) -> some View {
        let isSelected = dimension == target
        return Button {
            select(target)
        } label: {
            Text(label)
                .font(.system(size: ThemeRuntime.isCosmos ? 11 : 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(ThemeRuntime.isCosmos ? (isSelected ? CosmosPalette.ink : CosmosPalette.ink3) : (isSelected ? Palette.ink1 : Palette.ink2))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 24)
                .padding(.horizontal, 12)
                .modifier(DimensionSegmentSurface(
                    isSelected: isSelected,
                    reduceTransparency: reduceTransparency,
                    namespace: switchNamespace
                ))
        }
        .buttonStyle(.plain)
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
    let reduceTransparency: Bool
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if ThemeRuntime.isCosmos {
            content
                .frame(minHeight: 28)
                .background(Rectangle().fill(isSelected ? CosmosPalette.selection : .clear))
                .contentShape(Rectangle())
        } else if !isSelected {
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

// MARK: - Tray

/// The themed tray: window controls, period, the period's total and cost, then devices and sync.
/// In Settings it carries the section list instead.
private struct Tray: View {
    let isFirstLaunchCollecting: Bool

    @Environment(AppModel.self) private var model
    @Environment(MainWindowRouter.self) private var router
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ThemeRuntime.isCosmos ? 0 : Radius.tray, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            // Clear band for the traffic lights, which sit inside the tray.
            Color.clear.frame(height: 46)

            switch router.route {
            case .dashboard:
                Group {
                    if ThemeRuntime.isCosmos {
                        CosmosPeriodPicker()
                    } else if ThemeRuntime.isField {
                        FieldPeriodPicker()
                    } else {
                        PeriodSlider()
                    }
                }
                .padding(.top, ThemeRuntime.isCosmos ? 14 : 22)

                SummaryRail(summary: model.summary, isCollecting: isFirstLaunchCollecting)
                    .padding(.top, ThemeRuntime.isCosmos ? 14 : 28)
                    .padding(.horizontal, ThemeRuntime.isCosmos ? 0 : 4)

                Spacer(minLength: 20)

                TrayDevices(summary: model.summary, isCollecting: isFirstLaunchCollecting)
                    .padding(.horizontal, ThemeRuntime.isCosmos ? 0 : 4)

                Rectangle().fill(Palette.hairline).frame(height: 1)
                    .padding(.vertical, 12)

                TrayFooter(isFirstLaunchCollecting: isFirstLaunchCollecting)
            case .settings:
                SettingsSidebar()
                    .padding(.top, 10)
            }
        }
        .padding(.horizontal, ThemeRuntime.isCosmos ? 16 : 20)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background { shape.fill(Palette.traySurface) }
        .overlay { shape.strokeBorder(Palette.trayRim, lineWidth: ThemeRuntime.isCosmos ? 1 : 0.5) }
        .shadow(
            color: .black.opacity(ThemeRuntime.isCosmos ? 0 : (reduceTransparency ? 0 : (scheme == .dark ? 0.30 : 0.07))),
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
        if ThemeRuntime.isCosmos {
            VStack(alignment: .leading, spacing: 8) {
                TimelineView(.everyMinute) { context in
                    modeIndicator(now: context.date)
                }
                HStack(spacing: 8) {
                    RefreshNowButton(refreshCoordinator: refreshCoordinator, showsLabel: true)
                    TraySettingsButton()
                }
            }
        } else {
            HStack(spacing: 6) {
                TimelineView(.everyMinute) { context in
                    modeIndicator(now: context.date)
                }
                Spacer(minLength: 4)
                RefreshNowButton(refreshCoordinator: refreshCoordinator)
                TraySettingsButton()
            }
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
                    .font(.system(size: 11.5))
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
                            .font(.system(size: 11.5, weight: .semibold))
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
                        .font(.system(size: 11.5))
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
        if model.dataIssues.devices > 0 {
            return true
        }
        return model.remoteDevices.contains { device in
            device.state != .ok || (device.lastWrite.map { now.timeIntervalSince($0) > 86_400 } == true)
        }
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
            || model.remoteDevices.contains(where: { $0.state == .unavailable }) {
            return "Unavailable"
        }
        if model.remoteDevices.contains(where: { $0.state == .partial }) {
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
            HStack(spacing: 6) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityHidden(true)
                if ThemeRuntime.isCosmos {
                    Text("Settings")
                }
            }
            .font(.system(size: ThemeRuntime.isCosmos ? 11 : 12, weight: .medium))
            .foregroundStyle(Palette.ink2)
            .frame(width: ThemeRuntime.isCosmos ? nil : 28, height: 28)
            .frame(maxWidth: ThemeRuntime.isCosmos ? .infinity : nil)
            .modifier(RoundGlassControlSurface(reduceTransparency: reduceTransparency))
        }
        .buttonStyle(.plain)
        .help(Text("Settings (⌘,)"))
        .accessibilityLabel(Text("Settings"))
    }
}

struct RefreshNowButton: View {
    let refreshCoordinator: RefreshCoordinator?
    var showsLabel = false
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
                Group {
                    if isRefreshing && reduceMotion {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(isSpinning ? 360 : 0))
                            .animation(
                                isSpinning ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                                value: isSpinning
                            )
                    }
                }
                if ThemeRuntime.isCosmos && showsLabel {
                    Text("Refresh now")
                }
            }
            .font(.system(size: ThemeRuntime.isCosmos ? 11 : 12, weight: .medium))
            .foregroundStyle(Palette.ink2)
            .frame(width: ThemeRuntime.isCosmos && showsLabel ? nil : 28, height: 28)
            .frame(maxWidth: ThemeRuntime.isCosmos && showsLabel ? .infinity : nil)
            .modifier(RoundGlassControlSurface(reduceTransparency: reduceTransparency))
        }
        .buttonStyle(.plain)
        .disabled(refreshCoordinator == nil || isRefreshing)
        .opacity(refreshCoordinator == nil ? 0.45 : 1)
        .help(Text("Refresh now"))
        .accessibilityLabel(Text("Refresh now"))
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

    func body(content: Content) -> some View {
        if ThemeRuntime.isCosmos {
            content
                .background(CosmosPalette.background)
                .overlay(Rectangle().strokeBorder(CosmosPalette.controlRule, lineWidth: 1))
                .contentShape(Rectangle())
        } else if reduceTransparency {
            content
                .background { Circle().fill(Palette.cardSurface) }
                .overlay { Circle().strokeBorder(Palette.hairline, lineWidth: 1) }
                .contentShape(Circle())
        } else {
            content
                .themedGlass(.regular.interactive(), in: .circle)
                .contentShape(Circle())
        }
    }
}

// MARK: - First-launch collecting & empty states

private struct FirstLaunchCollectingCard: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 16) {
            CollectingVesselGlyph()
                .frame(width: 56, height: 72)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Collecting Token usage on this Mac for the first time")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.ink1)
                    .multilineTextAlignment(.center)

                Text("Reading supported agent logs in read-only mode. Your Confluence chart will appear automatically when finished.")
                    .font(.system(size: 13))
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
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: 480)
        .atmosphereCard(reduceTransparency: reduceTransparency, isDark: scheme == .dark)
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
        } else {
            liquidBody
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

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: ThemeRuntime.isCosmos ? "circle.circle" : "drop")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(ThemeRuntime.isCosmos ? CosmosPalette.accent : Palette.ink2)
                .frame(width: 48, height: 48)
                .background {
                    RoundedRectangle(cornerRadius: ThemeRuntime.isCosmos ? 0 : Radius.inner, style: .continuous)
                        .fill(Palette.barTrack)
                }
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("No usage collected yet")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.ink1)
                    .multilineTextAlignment(.center)

                Text("Token Taken reads supported agent logs on this Mac. Use Refresh now in Settings, or wait for the first collection to finish.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if reduceTransparency && !ThemeRuntime.isCosmos {
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
        .atmosphereCard(reduceTransparency: reduceTransparency, isDark: scheme == .dark)
    }
}

// MARK: - AppModel status helpers

extension AppModel {
    static let statusIssueDotColor = Palette.healthWarn
    static let statusIssueTextColor = Palette.healthWarn

    var hasStatusIssue: Bool {
        dataIssues.isPartial || remoteDevices.contains { $0.state != .ok }
    }

    var statusIssueNote: LocalizedStringKey? {
        let issues = dataIssues
        guard issues.isPartial || remoteDevices.contains(where: { $0.state != .ok }) else {
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
            let state: String? = switch device.state {
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
