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

    private var activeSources: [Breakdown] {
        today.bySource.filter { $0.counts.total > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let notice = AppUpdater.shared.justUpdated {
                justUpdatedRow(version: notice.version)
            }

            headerRow

            heroCard

            if settings.theme == .field, !activeSources.isEmpty {
                // Today's farm, the menu bar's small version of the dashboard field.
                FieldLandscapeView(items: activeSources, highlight: .constant(nil), interactive: false, compact: true)
            } else if settings.theme == .cosmos, !activeSources.isEmpty {
                CosmosSceneView(summary: today, dimension: .sources, highlight: .constant(nil), style: .menuBar)
            }

            topSourcesSection

            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 0.5)
                .accessibilityHidden(true)

            actionRow
        }
        .padding(14)
        .frame(width: 332)
        .background {
            if settings.theme == .field {
                FieldPalette.paper
            } else if settings.theme == .cosmos {
                CosmosPalette.panel
            } else if reduceTransparency {
                Palette.solid
            }
        }
        .overlay {
            if settings.theme == .cosmos {
                Rectangle().strokeBorder(CosmosPalette.controlRule, lineWidth: 1)
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
                        .font(.system(size: 12, weight: .semibold))
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
                                .font(.system(size: 11.5, weight: hasIssue ? .semibold : .medium))
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
        let shape = RoundedRectangle(cornerRadius: settings.theme == .cosmos ? 0 : Radius.inner, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(TokenFormat.short(today.total.total))
                    .font(.system(size: settings.theme == .cosmos ? 24 : 30, weight: .medium, design: settings.theme == .cosmos ? .monospaced : .default))
                    .tracking(settings.theme == .cosmos ? 0 : -0.8)
                    .foregroundStyle(Palette.ink1)
                    .monospacedDigit()
                Text("tokens")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.ink2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(TokenFormat.spoken(today.total.total))

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(TokenFormat.usd(today.cost.estimatedUSD))
                    .font(.system(size: 14, weight: .semibold, design: settings.theme == .cosmos ? .monospaced : .default))
                    .foregroundStyle(settings.theme == .cosmos ? CosmosPalette.accent : Palette.ink1)
                    .monospacedDigit()
                Text("estimate, not a bill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink3)
            }
            .accessibilityElement(children: .combine)
            .help(Text("Price table \(today.cost.priceTableVersion)"))

            if today.cost.unpricedTokens > 0 {
                Text("\(TokenFormat.short(today.cost.unpricedTokens)) tokens unpriced, not included in the estimate")
                    .font(.system(size: 11))
                    .foregroundStyle(settings.theme == .cosmos ? CosmosPalette.accent : Palette.ink3)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityValue(TokenFormat.spoken(today.cost.unpricedTokens))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background { shape.fill(settings.theme == .cosmos ? CosmosPalette.background : Palette.cardSurface) }
        .overlay { shape.strokeBorder(settings.theme == .cosmos ? CosmosPalette.controlRule : Palette.hairline, lineWidth: settings.theme == .cosmos ? 1 : 0.5) }
    }

    private var topSourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top sources")
                .font(.system(size: settings.theme == .cosmos ? 11 : 12, weight: .semibold))
                .foregroundStyle(settings.theme == .cosmos ? CosmosPalette.ink3 : Palette.ink2)
                .accessibilityAddTraits(.isHeader)

            if activeSources.isEmpty {
                Text(model.isEmpty ? model.statusText : LocalizedStringKey("No usage yet today"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: settings.theme == .cosmos ? 0 : 9) {
                    ForEach(activeSources.prefix(4)) { source in
                        sourceRow(source)
                    }
                }
            }
        }
    }

    private func sourceRow(_ source: Breakdown) -> some View {
        let color = Palette.color(forSource: source.id)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if settings.theme != .cosmos {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.0 }
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: source.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.ink1)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(TokenFormat.short(source.counts.total))
                        .font(.system(size: 12.5, weight: .semibold, design: settings.theme == .cosmos ? .monospaced : .default))
                        .foregroundStyle(Palette.ink1)

                    Text(Share.percent(source.counts.total, of: today.total.total))
                        .font(.system(size: 11.5, design: settings.theme == .cosmos ? .monospaced : .default))
                        .foregroundStyle(Palette.ink2)
                        .frame(minWidth: 42, alignment: .trailing)
                }

                if settings.theme != .cosmos {
                    FullWidthProportionBar(
                        ratio: Share.ratio(source.counts.total, of: today.total.total),
                        color: color,
                        height: 3
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, settings.theme == .cosmos ? 4 : 0)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CosmosPalette.rule)
                .frame(height: settings.theme == .cosmos ? 1 : 0)
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text("\(TokenFormat.spoken(source.counts.total)) tokens, \(Share.percent(source.counts.total, of: today.total.total)) of total"))
    }

    private func justUpdatedRow(version: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: settings.theme == .cosmos ? 0 : Radius.inner, style: .continuous)
        return HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.roleAccent)
                .accessibilityHidden(true)

            Text("Updated to \(version)")
                .font(.system(size: 11.5, weight: .medium))
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
            .font(.system(size: 11.5, weight: .semibold))
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
        .background { shape.fill(settings.theme == .cosmos ? CosmosPalette.background : Palette.cardSurface) }
        .overlay { shape.strokeBorder(settings.theme == .cosmos ? CosmosPalette.controlRule : Palette.hairline, lineWidth: settings.theme == .cosmos ? 1 : 0.5) }
    }

    private var actionRow: some View {
        VStack(spacing: 6) {
            if case .ready = AppUpdater.shared.phase {
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
            let syncedRemotes = model.remoteDevices.filter { $0.state == .ok }.count
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
    @Environment(AppSettings.self) private var settings
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: settings.theme == .cosmos ? 0 : 8, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(.system(size: settings.theme == .cosmos ? 11 : 12, weight: .semibold))
                .foregroundStyle(settings.theme == .cosmos ? CosmosPalette.background : .white)
                .lineLimit(1)
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
        let shape = RoundedRectangle(cornerRadius: ThemeRuntime.isCosmos ? 0 : 8, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(.system(size: ThemeRuntime.isCosmos ? 11 : 12, weight: .medium))
                .foregroundStyle(isHovered ? Palette.ink1 : foreground)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background {
                    shape.fill(ThemeRuntime.isCosmos ? (isHovered ? CosmosPalette.selection : CosmosPalette.background) : (reduceTransparency ? Palette.cardSurface : Palette.barTrack.opacity(isHovered ? 1 : 0.72)))
                }
                .overlay {
                    shape.strokeBorder(ThemeRuntime.isCosmos ? CosmosPalette.controlRule : Palette.hairline, lineWidth: ThemeRuntime.isCosmos || reduceTransparency ? 1 : 0.5)
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
