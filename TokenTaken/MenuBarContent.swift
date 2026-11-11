import AppKit
import SwiftUI
import TokenTakenKit

/// Minimal menu bar window: today's total, last 7 days, top sources, cost estimate.
/// Uses the same summary semantics as the main window.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(MainWindowRouter.self) private var router
    @Environment(RefreshCoordinator.self) private var refreshCoordinator: RefreshCoordinator?
    @Environment(\.openWindow) private var openWindow

    private var today: UsageSummary { model.todaySummary }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Text(TokenFormat.short(today.total.total))
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.8)
                    .monospacedDigit()
            }

            WeekSparkline(points: model.last7)

            Divider()

            VStack(spacing: 7) {
                ForEach(today.bySource.prefix(3)) { source in
                    HStack(spacing: 7) {
                        Circle().fill(Palette.color(forSource: source.id)).frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(verbatim: source.name).foregroundStyle(Palette.muted).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(TokenFormat.short(source.counts.total)).fontWeight(.medium)
                    }
                    .accessibilityElement(children: .combine)
                }
                if today.bySource.isEmpty {
                    Text(model.isEmpty ? model.statusText : LocalizedStringKey("No usage yet today"))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 12))
            .monospacedDigit()

            Divider()

            TimelineView(.everyMinute) { _ in
                let hasIssue = model.hasStatusIssue
                let tooltip = model.statusTooltip(refreshCoordinator: refreshCoordinator)
                HStack(spacing: 8) {
                    Button {
                        router.route = .settings
                        openWindow(id: MainWindowView.windowID)
                        NSApplication.shared.activate()
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(hasIssue ? AppModel.statusIssueDotColor : Palette.liveDot)
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                            statusLabel
                                .font(.system(size: 11))
                                .foregroundStyle(hasIssue ? AppModel.statusIssueTextColor : Palette.muted)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tooltip)
                    .accessibilityHint(Text("Opens Settings"))

                    RefreshNowButton(refreshCoordinator: refreshCoordinator)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(TokenFormat.usd(today.cost.estimatedUSD))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                Text("Estimate, not a bill")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 6) {
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("Quit Token Taken")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minHeight: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                Button {
                    router.route = .settings
                    openWindow(id: MainWindowView.windowID)
                    NSApplication.shared.activate()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .controlSize(.small)
                .help(Text("Settings"))
                .accessibilityLabel(Text("Settings"))

                Button("Open Token Taken") {
                    router.route = .dashboard
                    openWindow(id: MainWindowView.windowID)
                    NSApplication.shared.activate()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .lineLimit(1)
                .fixedSize()
            }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { model.refresh() }
    }

    private var statusLabel: Text {
        if refreshCoordinator?.isRefreshing == true {
            return Text("Updating…")
        }
        if let note = model.statusIssueNote {
            return Text(model.statusText) + Text(verbatim: " · ") + Text(note)
        }
        return Text(model.statusText)
    }
}

/// Seven daily bars, today (the last point) highlighted.
private struct WeekSparkline: View {
    let points: [SeriesPoint]

    var body: some View {
        let peak = max(points.map(\.total).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 5) {
            Text("Last 7 days")
                .font(.system(size: 10))
                .foregroundStyle(Palette.muted)
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(points.enumerated()), id: \.element.id) { entry in
                    bar(entry.element, isToday: entry.offset == points.count - 1, peak: peak)
                }
            }
        }
    }

    private func bar(_ point: SeriesPoint, isToday: Bool, peak: Int64) -> some View {
        VStack(spacing: 3) {
            UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3, style: .continuous)
                .fill(isToday ? Palette.accent : Palette.muted.opacity(0.32))
                .frame(height: max(2, 38 * CGFloat(point.total) / CGFloat(peak)))
                .frame(maxHeight: 38, alignment: .bottom)
            Text(verbatim: point.label)
                .font(.system(size: 9, weight: isToday ? .semibold : .regular))
                .foregroundStyle(isToday ? AnyShapeStyle(HierarchicalShapeStyle.primary) : AnyShapeStyle(Palette.muted))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .help(Text("\(point.label): \(TokenFormat.short(point.total)) tokens"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: point.label))
        .accessibilityValue(Text("\(TokenFormat.short(point.total)) tokens"))
    }
}
