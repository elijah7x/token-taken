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
                    if model.state == .decodeFailed {
                        StatusBanner(
                            text: "Couldn't read the newest report. Showing the last saved copy.",
                            systemImage: "exclamationmark.triangle"
                        )
                    } else if model.state == .iCloudUnavailable {
                        StatusBanner(
                            text: "iCloud is unavailable. Showing the last saved copy.",
                            systemImage: "icloud.slash"
                        )
                    }

                    hero(report)
                    rankBlock(report)
                    totalsCard(report)
                    chartCard(report)
                    sourcesCard(report)
                    updatedRow(report)

                    Button {
                        showingShare = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
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
        if let tier = RankTable.tier(forLast30Days: report.totals.last30Days.total) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.footnote)
                        .foregroundStyle(Palette.accent)
                        .accessibilityHidden(true)
                    Text(verbatim: RankTable.line(for: tier, locale: locale))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Palette.ink1)
                }
                Text(verbatim: RankTable.footnote(locale: locale))
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

    private func chartCard(_ report: MobileReport) -> some View {
        let months = report.last12Months

        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Last 12 months")

            Chart(months, id: \.month) { month in
                BarMark(
                    x: .value("Month", ReportText.monthLabel(month.month, locale: locale)),
                    y: .value("Tokens", Double(month.total))
                )
                .foregroundStyle(Palette.accent.opacity(0.85))
                .cornerRadius(3)
                .accessibilityLabel(Text(verbatim: ReportText.monthLabel(month.month, locale: locale)))
                .accessibilityValue(Text(verbatim: TokenFormat.spoken(month.total, locale: locale)))
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisValueLabel()
                        .font(.caption2)
                        .foregroundStyle(Palette.ink3)
                }
            }
            .frame(height: 170)
        }
        .padding(16)
        .cardSurface()
    }

    @ViewBuilder
    private func sourcesCard(_ report: MobileReport) -> some View {
        if let month = report.currentMonth, !month.sources.isEmpty {
            let slices = month.sources.sorted { $0.total > $1.total }

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Sources this month")

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
        guard let report = model.report else { return nil }
        let tier = RankTable.tier(forLast30Days: report.totals.last30Days.total)
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
            rankLine: tier.map { RankTable.line(for: $0, locale: locale) },
            comparison: model.comparison?.text,
            period: period,
            footnote: RankTable.footnote(locale: locale),
            chineseUnits: TokenFormat.usesChineseUnits(locale),
            isSample: model.demoMode
        )
    }
}
