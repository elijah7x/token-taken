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

/// One frosted glass base; the only floating layer is the tray on the left, which holds the
/// window controls. The dashboard (or the selected settings section) lies directly on the base.
struct MainWindowView: View {
    static let windowID = "main"

    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(MainWindowRouter.self) private var router
    @Environment(RefreshCoordinator.self) private var refreshCoordinator: RefreshCoordinator?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isFirstLaunchCollecting: Bool {
        model.isEmpty && refreshCoordinator?.isRefreshing == true
    }

    var body: some View {
        HStack(spacing: 0) {
            Tray(isFirstLaunchCollecting: isFirstLaunchCollecting)
                .frame(width: 264)
                .padding(10)

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
    }

    @ViewBuilder
    private var dashboard: some View {
        if isFirstLaunchCollecting {
            FirstLaunchCollectingCard()
                .padding(24)
        } else if model.isEmpty {
            DashboardEmptyStateCard { router.openSettings() }
                .padding(24)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                RangeTitle()
                    .padding(.leading, 20)
                    .frame(height: 48)

                ConfluenceView(summary: model.summary)
                    .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)

                Rectangle().fill(Palette.hairline).frame(height: 1)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)

                BreakdownCard(summary: model.summary)
                    .padding(.horizontal, 20)
            }
            .padding(.leading, 0)
            .padding(.trailing, 6)
            .padding(.bottom, 20)
        }
    }
}

// MARK: - Tray

/// The floating tray: window controls, period, the period's total and cost, then devices and sync.
/// In Settings it carries the section list instead.
private struct Tray: View {
    let isFirstLaunchCollecting: Bool

    @Environment(AppModel.self) private var model
    @Environment(MainWindowRouter.self) private var router
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.tray, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            // Clear band for the traffic lights, which sit inside the tray.
            Color.clear.frame(height: 34)

            switch router.route {
            case .dashboard:
                PeriodPicker()
                    .padding(.top, 10)

                SummaryRail(summary: model.summary, isCollecting: isFirstLaunchCollecting)
                    .padding(.top, 24)
                    .padding(.horizontal, 4)

                Spacer(minLength: 20)

                TrayDevices(summary: model.summary, isCollecting: isFirstLaunchCollecting)
                    .padding(.horizontal, 4)

                Rectangle().fill(Palette.hairline).frame(height: 1)
                    .padding(.vertical, 12)

                TrayFooter(isFirstLaunchCollecting: isFirstLaunchCollecting)
            case .settings:
                SettingsSidebar()
                    .padding(.top, 10)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background { shape.fill(Palette.traySurface) }
        .overlay { shape.strokeBorder(Palette.trayRim, lineWidth: 0.5) }
        .shadow(
            color: .black.opacity(reduceTransparency ? 0 : (scheme == .dark ? 0.30 : 0.07)),
            radius: 14,
            x: 0,
            y: 4
        )
    }
}

/// Sync status and refresh on the left, Settings on the right.
private struct TrayFooter: View {
    let isFirstLaunchCollecting: Bool

    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(MainWindowRouter.self) private var router
    @Environment(RefreshCoordinator.self) private var refreshCoordinator: RefreshCoordinator?

    var body: some View {
        HStack(spacing: 6) {
            // Relative time ("5 min ago") and staleness must re-render as the clock advances.
            TimelineView(.everyMinute) { _ in status }
            Spacer(minLength: 4)
            RefreshNowButton(refreshCoordinator: refreshCoordinator)
            TraySettingsButton()
        }
    }

    private var status: some View {
        let hasIssue = !isFirstLaunchCollecting && model.hasStatusIssue && refreshCoordinator?.isRefreshing != true
        let hasSyncIssue = settings.syncEnabled
            && (refreshCoordinator?.syncFailed == true || refreshCoordinator?.iCloudAvailable == false)
        return Button {
            router.openSettings(for: hasIssue ? model.dataIssues : nil, syncIssue: hasIssue && hasSyncIssue)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Group {
                    if hasIssue {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.healthWarn)
                    } else {
                        Circle()
                            .fill(isFirstLaunchCollecting || refreshCoordinator?.isRefreshing == true ? Palette.healthScan : Palette.healthOK)
                            .frame(width: 6, height: 6)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    }
                }
                .accessibilityHidden(true)
                statusLabel
                    .font(.system(size: 11.5, weight: hasIssue ? .semibold : .regular))
                    .foregroundStyle(hasIssue ? Palette.healthWarn : Palette.ink3)
                    .monospacedDigit()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.statusTooltip(refreshCoordinator: refreshCoordinator))
        .accessibilityHint(Text("Opens Settings"))
    }

    private var statusLabel: Text {
        if isFirstLaunchCollecting {
            return Text("Collecting for the first time")
        }
        if refreshCoordinator?.isRefreshing == true {
            return Text("Updating…")
        }
        if let note = model.statusIssueNote {
            return Text(note)
        }
        return Text(model.statusText)
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ink2)
                .frame(width: 28, height: 28)
                .modifier(RoundGlassControlSurface(reduceTransparency: reduceTransparency))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(Text("Settings (⌘,)"))
        .accessibilityLabel(Text("Settings"))
    }
}

/// Quiet title over the dashboard naming the period's range.
private struct RangeTitle: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Palette.ink1)
            .monospacedDigit()
            .lineLimit(1)
            .contentTransition(reduceMotion ? .identity : .numericText())
            .accessibilityAddTraits(.isHeader)
    }

    private var title: LocalizedStringKey {
        let start = model.summary.start
        switch model.period {
        case .day:
            return "Today · \(start.formatted(.dateTime.month(.abbreviated).day()))"
        case .week:
            let today = Calendar.current.date(byAdding: .day, value: -1, to: model.summary.end) ?? start
            return "This week · \(start.formatted(.dateTime.month(.abbreviated).day()))–\(today.formatted(.dateTime.month(.abbreviated).day()))"
        case .month:
            return "This month · \(start.formatted(.dateTime.year().month(.wide)))"
        case .year:
            return "This year · \(start.formatted(.dateTime.year()))"
        case .all:
            return "All time · since \(start.formatted(.dateTime.year().month(.abbreviated).day()))"
        }
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

    var body: some View {
        Button {
            Task { await refreshCoordinator?.refresh() }
        } label: {
            Group {
                if isRefreshing && reduceMotion {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ink2)
                        .rotationEffect(.degrees(isSpinning ? 360 : 0))
                        .animation(
                            isSpinning ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                            value: isSpinning
                        )
                }
            }
            .frame(width: 28, height: 28)
            .modifier(RoundGlassControlSurface(reduceTransparency: reduceTransparency))
            .contentShape(Circle())
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
        if reduceTransparency {
            content
                .background { Circle().fill(Palette.cardSurface) }
                .overlay { Circle().strokeBorder(Palette.hairline, lineWidth: 1) }
        } else {
            content
                .glassEffect(.regular.interactive(), in: .circle)
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
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
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
            Image(systemName: "drop")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Palette.ink2)
                .frame(width: 48, height: 48)
                .background {
                    RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
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

            if reduceTransparency {
                Button("Open Settings…", action: openSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            } else {
                Button("Open Settings…", action: openSettings)
                    .buttonStyle(.glass)
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
            return issues.stale == 1 ? "1 source stale" : "\(issues.stale) sources stale"
        }
        if issues.count > 0 {
            return issues.count == 1 ? "1 source unavailable" : "\(issues.count) sources unavailable"
        }
        if issues.devices > 0 {
            return issues.devices == 1 ? "1 Mac unavailable" : "\(issues.devices) Macs unavailable"
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

// MARK: - Segmented period picker

/// Segmented control whose selection is a native glass capsule that morphs
/// between segments through `glassEffectID`, with an opaque fallback under Reduce Transparency.
private struct PeriodPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var selection
    @FocusState private var focusedPeriod: Period?

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Period.allCases) { period in
                    segment(period)
                }
            }
            .padding(3)
        }
        .background(Capsule().fill(Palette.barTrack))
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: reduceTransparency ? 1 : 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Usage period"))
    }

    private func segment(_ period: Period) -> some View {
        let isSelected = model.period == period
        return Button {
            select(period)
        } label: {
            Text(period.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Palette.ink1 : Palette.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 26)
                .padding(.horizontal, 2)
                .contentShape(Capsule())
                // Glass applied to the label itself renders behind its text; as a background it covered the text.
                .modifier(SelectedGlass(
                    isSelected: isSelected,
                    reduceTransparency: reduceTransparency,
                    namespace: selection
                ))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(period.shortcutKey, modifiers: .command)
        .focused($focusedPeriod, equals: period)
        .onKeyPress(.leftArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func select(_ period: Period) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.45)) {
            model.period = period
        }
    }

    private func moveSelection(by offset: Int) {
        let periods = Period.allCases
        guard let index = periods.firstIndex(of: model.period) else { return }
        let newIndex = min(max(index + offset, 0), periods.count - 1)
        let target = periods[newIndex]
        select(target)
        focusedPeriod = target
    }
}

private extension Period {
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

private struct SelectedGlass: ViewModifier {
    let isSelected: Bool
    let reduceTransparency: Bool
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if !isSelected {
            content
        } else if reduceTransparency {
            content
                .background { Capsule().fill(Palette.cardSurface) }
                .overlay { Capsule().strokeBorder(Palette.hairline, lineWidth: 1) }
        } else {
            content
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("selection", in: namespace)
        }
    }
}
