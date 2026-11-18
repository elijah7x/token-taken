import Charts
import SwiftUI

struct HomeView: View {
    let onOpenSettings: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale
    @State private var showingShare = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.demoMode {
                    SampleDataBadge()
                }

                if let report = model.report {
                    statusBanner

                    hero(report)
                    rankBlock(report)
                    totalsCard(report)
                    chartCard(report)
                    sourcesCard(report)
                    coverageCard(report)
                    updatedRow(report)

                    Button {
                        showingShare = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(report.totals.allTime.total <= 0)
                    .padding(.top, 4)
                } else {
                    EmptyStateView()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .refreshable { await model.reload() }
        .background(Palette.solid.ignoresSafeArea())
        .navigationTitle("Token Taken")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(Text("Settings"))
            }
        }
        .sheet(isPresented: $showingShare) {
            if let card = shareCard {
                ShareSheetView(card: card)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var statusBanner: some View {
        switch model.state {
        case .ok, .noReport:
            EmptyView()
        case .stale:
            StatusBanner(
                text: "Data is more than a day old. Open Token Taken on your Mac to refresh.",
                systemImage: "clock.badge.exclamationmark"
            )
        case .downloading:
            StatusBanner(
                text: "Downloading the newest report from iCloud. Showing the last saved copy.",
                systemImage: "icloud.and.arrow.down",
                tint: Palette.accent
            )
        case .unsupportedVersion:
            StatusBanner(
                text: "Update Token Taken to read the newest report. Showing the last saved copy.",
                systemImage: "arrow.down.circle"
            )
        case .decodeFailed:
            StatusBanner(
                text: "Couldn't read the newest report. Showing the last saved copy.",
                systemImage: "exclamationmark.triangle"
            )
        case .iCloudUnavailable:
            StatusBanner(
                text: "iCloud is unavailable. Showing the last saved copy.",
                systemImage: "icloud.slash"
            )
        }
    }

    private func hero(_ report: MobileReport) -> some View {
        let total = report.totals.last30Days.total
        let (digits, unit) = TokenFormat.split(TokenFormat.short(total, locale: locale))

        return VStack(alignment: .leading, spacing: 8) {
            Text("Last 30 days")
                .font(.subheadline)
                .foregroundStyle(Palette.ink2)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: digits)
                    .font(.system(size: 48, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink1)
                if !unit.isEmpty {
                    Text(verbatim: unit)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Palette.ink1)
                }
                Text("Token")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Palette.ink2)
                    .padding(.leading, 4)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Last 30 days"))
        .accessibilityValue(Text(verbatim: TokenFormat.spoken(total, locale: locale)))
    }

    @ViewBuilder
    private func rankBlock(_ report: MobileReport) -> some View {
        if let line = Ranking.line(forLast30Days: report.totals.last30Days.total, locale: locale) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.footnote)
                        .foregroundStyle(Palette.accent)
                        .accessibilityHidden(true)
                    Text(verbatim: line)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Palette.ink1)
                }
                Text(verbatim: Ranking.footnote(locale: locale))
                    .font(.caption2)
                    .foregroundStyle(Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)

                if let comparison = model.comparison {
                    Text(verbatim: comparison.text)
                        .font(.footnote)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func totalsCard(_ report: MobileReport) -> some View {
        VStack(spacing: 0) {
            StatRow(label: "Today", tokens: report.totals.today.total)
            Divider().overlay(Palette.hairline)
            StatRow(label: "This month", tokens: report.totals.thisMonth.total)
            Divider().overlay(Palette.hairline)
            StatRow(label: "All time", tokens: report.totals.allTime.total)
        }
        .padding(.horizontal, 16)
        .cardSurface()
    }

    @ViewBuilder
    private func chartCard(_ report: MobileReport) -> some View {
        let months = report.last12Months
        if !months.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Last 12 months")

                Chart(months, id: \.month) { month in
                    BarMark(
                        x: .value("Month", month.month),
                        y: .value("Tokens", Double(month.total))
                    )
                    .foregroundStyle(Palette.accent.opacity(0.85))
                    .cornerRadius(3)
                    .accessibilityLabel(Text(verbatim: ReportText.monthLabel(month.month, locale: locale)))
                    .accessibilityValue(Text(verbatim: TokenFormat.spoken(month.total, locale: locale)))
                }
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { value in
                        AxisValueLabel {
                            Text(verbatim: value.as(String.self).map { ReportText.monthLabel($0, locale: locale) } ?? "")
                        }
                        .font(.caption2)
                        .foregroundStyle(Palette.ink3)
                    }
                }
                .frame(height: 170)
            }
            .padding(16)
            .cardSurface()
        }
    }

    @ViewBuilder
    private func sourcesCard(_ report: MobileReport) -> some View {
        if let month = report.currentMonth, !month.sources.isEmpty {
            let slices = month.sources.sorted { $0.total > $1.total }

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Harnesses this month")

                ForEach(slices, id: \.id) { slice in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Palette.color(forSource: slice.id))
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)

                        Text(verbatim: report.displayName(forSource: slice.id))
                            .foregroundStyle(Palette.ink1)

                        Spacer(minLength: 8)

                        Text(verbatim: TokenFormat.short(slice.total, locale: locale))
                            .monospacedDigit()
                            .foregroundStyle(Palette.ink1)

                        Text(verbatim: ReportText.percent(slice.total, of: month.total))
                            .monospacedDigit()
                            .foregroundStyle(Palette.ink3)
                            .frame(minWidth: 48, alignment: .trailing)
                    }
                    .font(.footnote)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: report.displayName(forSource: slice.id)))
                    .accessibilityValue(
                        Text(verbatim: "\(TokenFormat.spoken(slice.total, locale: locale)), \(ReportText.percent(slice.total, of: month.total))")
                    )
                }
            }
            .padding(16)
            .cardSurface()
        }
    }

    private func coverageCard(_ report: MobileReport) -> some View {
        let rows = coverageRows(for: report)

        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Macs in this report")

            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows) { row in
                    CoverageDeviceRow(
                        displayName: row.displayName,
                        isGenerator: row.isGenerator,
                        status: row.status
                    )
                }
            }

            Text("Missing a Mac? It needs iCloud sync on and the same Apple ID as this iPhone.")
                .font(.caption)
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .cardSurface()
    }

    private func coverageRows(for report: MobileReport) -> [CoverageRow] {
        let devices = report.coverage.devices
        // The publisher always writes itself first; coverage carries no device ID, so matching by name
        // elsewhere could badge another Mac with the same name.
        let generatorIndex: Int? =
            devices.first.map { $0.displayName == report.generator.displayName && $0.lastWriteUTC == report.generatedAt } == true
            ? 0 : nil

        var rows: [CoverageRow] = []
        if generatorIndex == nil {
            rows.append(
                CoverageRow(
                    id: -1,
                    displayName: report.generator.displayName,
                    isGenerator: true,
                    status: nil
                )
            )
        }
        for (index, device) in devices.enumerated() {
            rows.append(
                CoverageRow(
                    id: index,
                    displayName: device.displayName,
                    isGenerator: index == generatorIndex,
                    status: device.status
                )
            )
        }
        return rows
    }

    private struct CoverageRow: Identifiable {
        let id: Int
        let displayName: String
        let isGenerator: Bool
        let status: MobileReport.Coverage.Status?
    }

    private func updatedRow(_ report: MobileReport) -> some View {
        let isStale = model.state == .stale
        let relative = ReportText.relativeTime(since: report.generatedAt, locale: locale)

        return HStack(spacing: 6) {
            Circle()
                .fill(isStale ? Palette.warn : Palette.ok)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text("Updated \(relative)")
                .font(.caption)
                .foregroundStyle(isStale ? Palette.warn : Palette.ink3)
            if isStale {
                Text("Data is more than a day old")
                    .font(.caption)
                    .foregroundStyle(Palette.warn)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var shareCard: ShareCardView? {
        guard let report = model.report, report.totals.allTime.total > 0 else { return nil }
        let period: String
        if let range = report.last30DayRange {
            period = String(localized: "Last 30 days", locale: locale)
                + " · "
                + ReportText.periodLabel(start: range.start, end: range.end, locale: locale)
        } else {
            period = String(localized: "Last 30 days", locale: locale)
        }
        return ShareCardView(
            last30Days: report.totals.last30Days.total,
            allTime: report.totals.allTime.total,
            rankLine: Ranking.line(forLast30Days: report.totals.last30Days.total, locale: locale),
            comparison: model.comparison?.text,
            period: period,
            footnote: Ranking.footnote(locale: locale),
            chineseUnits: TokenFormat.usesChineseUnits(locale),
            isSample: model.demoMode
        )
    }
}
