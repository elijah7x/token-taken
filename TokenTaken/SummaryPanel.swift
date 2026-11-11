import SwiftUI
import TokenTakenKit

// MARK: - Left rail

/// Total, cost estimate, Token mix and devices for the selected period.
struct SummaryRail: View {
    let summary: UsageSummary

    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow("TOTAL TOKENS")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(TokenFormat.short(summary.total.total))
                    .font(.system(size: 46, weight: .semibold))
                    .tracking(-1.6)
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                Text("tokens")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.muted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(TokenFormat.spoken(summary.total.total))
            .padding(.top, 6)
            .padding(.bottom, 8)

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(TokenFormat.usd(summary.cost.estimatedUSD))
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                Text("Estimate, not a bill")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            .accessibilityElement(children: .combine)
            .help(Text("Price table \(summary.cost.priceTableVersion)"))

            if summary.cost.unpricedTokens > 0 {
                Text("\(TokenFormat.short(summary.cost.unpricedTokens)) tokens unpriced, not included in the estimate")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityValue(TokenFormat.spoken(summary.cost.unpricedTokens))
                    .padding(.top, 4)
            }

            RailSection(title: "Token mix", note: "Cache is not netted out of the total") {
                VStack(spacing: 7) {
                    ForEach(TokenCategory.allCases) { category in
                        CategoryRow(category: category, value: summary.total[category], total: summary.total.total)
                    }
                }
            }

            RailSection(
                title: "Devices",
                note: settings.heroStyle == .condensation ? "Drop area ∝ tokens" : nil
            ) {
                VStack(spacing: 9) {
                    ForEach(summary.byDevice) { device in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: device.name).foregroundStyle(Palette.muted).lineLimit(1)
                            if let status = remoteStatusLabel(for: device) {
                                Text(status)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Palette.muted)
                                    .fixedSize()
                            }
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
                        .accessibilityValue(TokenFormat.spoken(device.counts.total))
                    }
                    // A remote Mac whose snapshot could not be read adds no rows; keep it visible, not silently absent.
                    ForEach(missingRemoteDevices, id: \.deviceID) { remote in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            // An unreadable identity leaves only the device ID, which the CLI also names "Unknown Mac".
                            (remote.displayName == remote.deviceID ? Text("Unknown Mac") : Text(verbatim: remote.displayName))
                                .foregroundStyle(Palette.muted).lineLimit(1)
                            Text(remote.state == .stale ? "Stale" : "Unavailable")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.muted)
                                .fixedSize()
                            Spacer(minLength: 8)
                            Text(verbatim: "–").foregroundStyle(Palette.muted)
                                .accessibilityHidden(true)
                        }
                        .font(.system(size: 12))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var missingRemoteDevices: [RemoteDeviceStatus] {
        model.remoteDevices.filter { remote in
            remote.state != .ok && !summary.byDevice.contains { $0.id == remote.deviceID }
        }
    }

    private func remoteStatusLabel(for device: Breakdown) -> LocalizedStringKey? {
        guard let remote = model.remoteDevices.first(where: {
            $0.deviceID == device.id || $0.displayName == device.name
        }) else {
            return nil
        }
        return switch remote.state {
        case .ok:
            nil
        case .stale:
            "Stale"
        case .partial, .unavailable:
            "Unavailable"
        }
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
                .accessibilityHidden(true)
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
        .accessibilityElement(children: .combine)
        .accessibilityValue(TokenFormat.spoken(value))
    }
}

private struct RailSection<Content: View>: View {
    let title: LocalizedStringKey
    let note: LocalizedStringKey?
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
    let note: LocalizedStringKey?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 8)
            if let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
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
            .accessibilityAddTraits(.isHeader)
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
                rows(summary.byModel) { _, item in modelColor(for: item.id) }
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
            if items.count > limit {
                Text("+\(items.count - limit) more")
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
                .accessibilityHidden(true)
            Text(verbatim: item.name).lineLimit(1).truncationMode(.tail)
                .accessibilityLabel(Text(verbatim: item.name))
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
        .help(item.name)
        .accessibilityElement(children: .combine)
        .accessibilityValue(TokenFormat.spoken(item.counts.total))
    }

    private func modelColor(for id: String) -> Color {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let categories = TokenCategory.allCases
        return Palette.color(for: categories[Int(hash % UInt64(categories.count))])
    }
}
