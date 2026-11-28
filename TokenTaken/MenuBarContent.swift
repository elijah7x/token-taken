import AppKit
import SwiftUI
import TokenTakenKit

/// Atmosphere menu bar panel: today's total and cost estimate, top sources with thin bars and shares,
/// collection/sync status, and actions for opening the dashboard, Settings, or quitting.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(MainWindowRouter.self) private var router
    @Environment(RefreshCoordinator.self) private var refreshCoordinator: RefreshCoordinator?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var today: UsageSummary { model.todaySummary }

    private var showsUpdaterUI: Bool {
        #if DEBUG
        if SyntheticLaunchOptions.current != nil { return false }
        #endif
        return true
    }

    private var activeSources: [Breakdown] {
        today.bySource.filter { $0.counts.total > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsUpdaterUI, let notice = AppUpdater.shared.justUpdated {
                justUpdatedRow(version: notice.version)
            }

            headerRow

            heroCard

            if settings.theme == .field, !activeSources.isEmpty {
                // Today's farm, the menu bar's small version of the dashboard field.
                FieldLandscapeView(items: activeSources, highlight: .constant(nil), interactive: false, compact: true)
            } else if settings.theme == .cosmos, !activeSources.isEmpty {
                CosmosSceneView(summary: today, dimension: .sources, highlight: .constant(nil), style: .menuBar)
                    .aspectRatio(FieldSceneModel.size.width / FieldSceneModel.size.height, contentMode: .fit)
                    .overlay {
                        Rectangle().strokeBorder(CosmosPalette.controlRule, lineWidth: 1)
                    }
            }

            topSourcesSection

            Rectangle()
                .fill(Palette.hairline)
                .frame(height: ThemeChrome.ruleWidth)
                .accessibilityHidden(true)

            actionRow
        }
        .padding(14)
        .frame(width: 332)
        .background {
            if reduceTransparency || ThemeKind.current != .liquidGlass {
                Palette.solid
            }
        }
        .onAppear { model.refresh() }
    }

    private var headerRow: some View {
        TimelineView(.everyMinute) { _ in
            let hasIssue = model.hasStatusIssue && refreshCoordinator?.isRefreshing != true
            let hasSyncIssue = settings.syncEnabled
                && (refreshCoordinator?.syncFailed == true || refreshCoordinator?.iCloudAvailable == false)
            let tooltip = model.statusTooltip(refreshCoordinator: refreshCoordinator)

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today · \(today.start.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(ThemeFont.role(.title))
                        .foregroundStyle(Palette.ink2)
                        .monospacedDigit()
                        .lineLimit(1)

                    Button {
                        router.openSettings(
                            for: hasIssue ? model.dataIssues : nil,
                            syncIssue: hasIssue && hasSyncIssue,
                            using: openWindow
                        )
                        dismiss()
                    } label: {
                        HStack(spacing: 5) {
                            if hasIssue {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Palette.healthWarn)
                                    .accessibilityHidden(true)
                            } else {
                                Circle()
                                    .fill(Palette.healthOK)
                                    .frame(width: 6, height: 6)
                                    .accessibilityHidden(true)
                            }

                            statusLabel
                                .font(hasIssue ? ThemeFont.role(.sectionHeader) : ThemeFont.role(.caption))
                                .foregroundStyle(hasIssue ? Palette.healthWarn : Palette.ink2)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tooltip)
                    .accessibilityHint(Text("Opens Settings"))
                }

                RefreshNowButton(refreshCoordinator: refreshCoordinator)
            }
        }
    }

    private var heroCard: some View {
        let shape = RadiusRole.inner.shape
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(TokenFormat.short(today.total.total))
                    .font(ThemeFont.role(.heroNumber, size: 30))
                    .foregroundStyle(Palette.ink1)
                    .monospacedDigit()
                Text("tokens")
                    .font(ThemeFont.role(.heroUnit))
                    .foregroundStyle(Palette.ink2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(TokenFormat.spoken(today.total.total))

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(TokenFormat.usd(today.cost.estimatedUSD))
                    .font(ThemeFont.role(.secondaryNumber))
                    .foregroundStyle(Palette.ink1)
                    .monospacedDigit()
                Text("estimate, not a bill")
                    .font(ThemeFont.role(.caption))
                    .foregroundStyle(Palette.ink3)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .accessibilityElement(children: .combine)
            .help(Text("Price table \(today.cost.priceTableVersion)"))

            if today.cost.unpricedTokens > 0 {
                Text("\(TokenFormat.short(today.cost.unpricedTokens)) tokens unpriced, not included in the estimate")
                    .font(ThemeFont.role(.caption))
                    .foregroundStyle(Palette.ink3)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityValue(TokenFormat.spoken(today.cost.unpricedTokens))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background { shape.fill(Palette.cardSurface) }
        .overlay {
            shape.strokeBorder(Palette.hairline, lineWidth: ThemeChrome.ruleWidth)
        }
    }

    private var topSourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top harnesses")
                .font(ThemeFont.role(.sectionHeader))
                .foregroundStyle(Palette.ink2)
                .accessibilityAddTraits(.isHeader)

            if activeSources.isEmpty {
                Text(model.isEmpty ? model.statusText : LocalizedStringKey("No usage yet today"))
                    .font(ThemeFont.role(.body))
                    .foregroundStyle(Palette.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                let topSources = Array(activeSources.prefix(4))
                VStack(spacing: ThemeChrome.showsSeriesSwatches ? 9 : 0) {
                    ForEach(Array(topSources.enumerated()), id: \.element.id) { index, source in
                        sourceRow(source, showBottomRule: index < topSources.count - 1)
                    }
                }
            }
        }
    }

    private func sourceRow(_ source: Breakdown, showBottomRule: Bool) -> some View {
        let color = Palette.color(forSource: source.id)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if ThemeChrome.showsSeriesSwatches {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.0 }
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: source.name)
                        .font(ThemeFont.role(.bodyStrong))
                        .foregroundStyle(Palette.ink1)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(TokenFormat.short(source.counts.total))
                        .font(ThemeFont.role(.secondaryNumber, size: 13))
                        .foregroundStyle(Palette.ink1)

                    Text(Share.percent(source.counts.total, of: today.total.total))
                        .font(ThemeFont.role(.numericCaption))
                        .foregroundStyle(Palette.ink2)
                        .frame(minWidth: 42, alignment: .trailing)
                }

                if ThemeChrome.showsSeriesSwatches {
                    FullWidthProportionBar(
                        ratio: Share.ratio(source.counts.total, of: today.total.total),
                        color: color,
                        height: 3
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, ThemeChrome.showsSeriesSwatches ? 0 : 4)
        .overlay(alignment: .bottom) {
            if !ThemeChrome.showsSeriesSwatches, showBottomRule {
                Rectangle()
                    .fill(Palette.hairline)
                    .frame(height: ThemeChrome.ruleWidth)
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text("\(TokenFormat.spoken(source.counts.total)) tokens, \(Share.percent(source.counts.total, of: today.total.total)) of total"))
    }

    private func justUpdatedRow(version: String) -> some View {
        let shape = RadiusRole.inner.shape
        return HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.roleAccent)
                .accessibilityHidden(true)

            Text("Updated to \(version)")
                .font(ThemeFont.role(.caption))
                .foregroundStyle(Palette.ink1)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Button("What's New") {
                router.settingsSection = .about
                router.openSettings(using: openWindow)
                dismiss()
            }
            .buttonStyle(.plain)
            .font(ThemeFont.role(.sectionHeader))
            .foregroundStyle(Palette.roleAccent)
            .fixedSize()

            Button {
                AppUpdater.shared.dismissJustUpdated()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.ink3)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background { shape.fill(Palette.cardSurface) }
        .overlay {
            shape.strokeBorder(Palette.hairline, lineWidth: ThemeChrome.ruleWidth)
        }
    }

    private var actionRow: some View {
        VStack(spacing: 6) {
            if showsUpdaterUI, case .ready = AppUpdater.shared.phase {
                MenuBarPrimaryButton(title: "Restart to Update") {
                    AppUpdater.shared.installNowAndRelaunch()
                }
            }

            HStack(spacing: 6) {
                MenuBarPrimaryButton(title: "Open Token Taken") {
                    router.route = .dashboard
                    openWindow(id: MainWindowView.windowID)
                    NSApplication.shared.activate()
                    dismiss()
                }

                MenuBarSecondaryButton(title: "Settings…", foreground: Palette.ink1) {
                    router.openSettings(using: openWindow)
                    dismiss()
                }

                MenuBarSecondaryButton(title: "Quit", foreground: Palette.ink2) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    private var statusLabel: Text {
        if refreshCoordinator?.isRefreshing == true {
            return Text("Updating…")
        }
        if let note = model.statusIssueNote {
            return Text(model.statusText) + Text(verbatim: " · ") + Text(note)
        }
        if settings.syncEnabled {
            let syncedRemotes = model.remoteDevices.filter { !$0.isStaleOrIncomplete() }.count
            if syncedRemotes > 0 {
                return Text("\(syncedRemotes + 1) Macs synced") + Text(verbatim: " · ") + Text(model.statusText)
            }
        }
        return Text(model.statusText)
    }
}

private struct MenuBarPrimaryButton: View {
    let title: LocalizedStringKey
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let shape = RadiusRole.control.shape
        Button(action: action) {
            Text(title)
                .font(ThemeFont.role(.control))
                .foregroundStyle(Palette.onAccent)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background {
                    shape.fill(Palette.roleAccent.opacity(isHovered ? 0.90 : 1))
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct MenuBarSecondaryButton: View {
    let title: LocalizedStringKey
    let foreground: Color
    let action: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovered = false

    var body: some View {
        let shape = RadiusRole.control.shape
        Button(action: action) {
            Text(title)
                .font(ThemeFont.role(.control))
                .foregroundStyle(isHovered ? Palette.ink1 : foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background {
                    shape.fill(isHovered ? Palette.barTrack : Palette.cardSurface)
                }
                .overlay {
                    shape.strokeBorder(Palette.hairline, lineWidth: reduceTransparency ? 1 : ThemeChrome.ruleWidth)
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
