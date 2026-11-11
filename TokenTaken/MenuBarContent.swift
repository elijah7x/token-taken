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
            headerRow

            heroCard

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
            if reduceTransparency {
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
        let shape = RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(TokenFormat.short(today.total.total))
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.8)
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink1)
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
        .overlay { shape.strokeBorder(Palette.hairline, lineWidth: 0.5) }
    }

    private var topSourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top sources")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.ink2)
                .accessibilityAddTraits(.isHeader)

            if activeSources.isEmpty {
                Text(model.isEmpty ? model.statusText : LocalizedStringKey("No usage yet today"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 9) {
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
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.0 }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: source.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.ink1)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(TokenFormat.short(source.counts.total))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.ink1)

                    Text(Share.percent(source.counts.total, of: today.total.total))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.ink2)
                        .frame(minWidth: 42, alignment: .trailing)
                }

                FullWidthProportionBar(
                    ratio: Share.ratio(source.counts.total, of: today.total.total),
                    color: color,
                    height: 3
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text("\(TokenFormat.spoken(source.counts.total)) tokens, \(Share.percent(source.counts.total, of: today.total.total)) of total"))
    }

    private var actionRow: some View {
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
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.roleAccent.opacity(isHovered ? 0.90 : 1))
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? Palette.ink1 : foreground)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background {
                    shape.fill(reduceTransparency ? Palette.cardSurface : Palette.barTrack.opacity(isHovered ? 1 : 0.72))
                }
                .overlay {
                    shape.strokeBorder(Palette.hairline, lineWidth: reduceTransparency ? 1 : 0.5)
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
