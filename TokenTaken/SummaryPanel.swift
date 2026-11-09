import SwiftUI
import TokenTakenKit

// MARK: - Left rail

/// Total, cost estimate, Token mix and devices for the selected period.
struct SummaryRail: View {
    let summary: UsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow("TOTAL TOKENS")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(TokenFormat.short(summary.total.total))
                    .font(.system(size: 46, weight: .semibold))
                    .tracking(-1.6)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(verbatim: "tokens")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.top, 6)
            .padding(.bottom, 8)

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(TokenFormat.usd(summary.cost.estimatedUSD))
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("Estimate, not a bill")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            .help(Text("Price table \(summary.cost.priceTableVersion)"))

            if summary.cost.unpricedTokens > 0 {
                Text("\(TokenFormat.short(summary.cost.unpricedTokens)) tokens unpriced, not included in the estimate")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }

            RailSection(title: "Token mix", note: "Cache is not netted out of the total") {
                VStack(spacing: 7) {
                    ForEach(TokenCategory.allCases) { category in
                        CategoryRow(category: category, value: summary.total[category], total: summary.total.total)
                    }
                }
            }

            RailSection(title: "Devices", note: "Drop area ∝ tokens") {
                VStack(spacing: 9) {
                    ForEach(summary.byDevice) { device in
                        HStack(alignment: .firstTextBaseline) {
                            Text(device.name).foregroundStyle(Palette.muted).lineLimit(1)
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(TokenFormat.short(device.counts.total)).fontWeight(.semibold)
                                Text(Share.percent(device.counts.total, of: summary.total.total))
                                    .font(.system(size: 10))
                                    .foregroundStyle(Palette.muted)
                            }
                            .monospacedDigit()
                        }
                        .font(.system(size: 12))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CategoryRow: View {
    let category: TokenCategory
    let value: Int64
    let total: Int64

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Palette.color(for: category)).frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 1) {
                Text(category.title).foregroundStyle(Palette.muted)
                Text("\(TokenFormat.short(value)) tokens")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            Text(Share.percent(value, of: total)).fontWeight(.semibold)
        }
        .font(.system(size: 12))
        .monospacedDigit()
        // Cache reads dominate real usage; the reference sets that row on a faint pane.
        .padding(.vertical, category == .cacheRead ? 7 : 0)
        .padding(.horizontal, category == .cacheRead ? 8 : 0)
        .background {
            if category == .cacheRead {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline))
            }
        }
        .padding(.horizontal, category == .cacheRead ? -8 : 0)
        .accessibilityElement(children: .combine)
    }
}

private struct RailSection<Content: View>: View {
    let title: LocalizedStringKey
    let note: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHead(title: title, note: note)
            content
        }
        .padding(.top, 13)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        .padding(.top, 16)
    }
}

struct SectionHead: View {
    let title: LocalizedStringKey
    let note: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 8)
            Text(note)
                .font(.system(size: 10))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct Eyebrow: View {
    let key: LocalizedStringKey
    init(_ key: LocalizedStringKey) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .medium))
            .tracking(1.3)
            .foregroundStyle(Palette.muted)
    }
}

// MARK: - Lower lists

/// Sources and models, top six each, below the condensation field.
struct BreakdownColumns: View {
    let summary: UsageSummary
    private let limit = 6

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHead(title: "Sources", note: "\(summary.bySource.count) agents")
                rows(summary.bySource) { _, item in Palette.color(forSource: item.id) }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionHead(title: "Models", note: "By tokens, descending")
                rows(summary.byModel) { rank, _ in Palette.color(forModelRank: rank) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func rows(_ items: [Breakdown], color: @escaping (Int, Breakdown) -> Color) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.prefix(limit).enumerated()), id: \.element.id) { entry in
                row(entry.element, color: color(entry.offset, entry.element))
            }
            if items.isEmpty {
                Text("No usage in this period")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
            }
        }
    }

    private func row(_ item: Breakdown, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(item.name).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Text(TokenFormat.short(item.counts.total)).fontWeight(.medium)
            Text(Share.percent(item.counts.total, of: summary.total.total))
                .font(.system(size: 10))
                .foregroundStyle(Palette.muted)
                .frame(width: 40, alignment: .trailing)
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}
