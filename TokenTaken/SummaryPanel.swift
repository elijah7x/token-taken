import Foundation
import SwiftUI
import TokenTakenKit

// MARK: - Left sidebar summary rail

/// Total, cost estimate, Token mix and devices for the selected period.
struct SummaryRail: View {
    let summary: UsageSummary
    var isCollecting = false

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isCollecting {
                Text(verbatim: "—")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Palette.ink3)
                    .monospacedDigit()
                    .padding(.top, 4)
                    .accessibilityHidden(true)

                Text("Summarising…")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink3)
                    .padding(.top, 4)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(TokenFormat.short(summary.total.total))
                        .font(.system(size: 40, weight: .bold))
                        .tracking(-1.0)
                        .foregroundStyle(Palette.ink1)
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                    Text("tokens")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.ink2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(TokenFormat.spoken(summary.total.total))
                .padding(.top, 2)

                if model.dataIssues.devices > 0 {
                    PartialDeviceBanner(
                        summary: summary,
                        remoteDevices: model.remoteDevices,
                        deviceIssueCount: model.dataIssues.devices,
                        reduceTransparency: reduceTransparency
                    )
                    .padding(.top, 8)
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(TokenFormat.usd(summary.cost.estimatedUSD))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Palette.ink1)
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                    Text("estimate, not a bill")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink3)
                }
                .accessibilityElement(children: .combine)
                .help(costHelp)
                .padding(.top, 8)

            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var costHelp: Text {
        let table = Text("Price table \(summary.cost.priceTableVersion)")
        guard summary.cost.unpricedTokens > 0 else { return table }
        return Text("\(TokenFormat.short(summary.cost.unpricedTokens)) tokens unpriced, not included in the estimate") + Text(verbatim: "\n") + table
    }
}

/// Devices in the tray footer: each Mac's share, plus any remote Mac that could not be read.
struct TrayDevices: View {
    let summary: UsageSummary
    var isCollecting = false

    @Environment(AppModel.self) private var model

    var body: some View {
                if isCollecting {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: Host.current().localizedName ?? "Mac")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.ink1)
                            .lineLimit(1)
                        ThisMacBadge()
                        Spacer(minLength: 8)
                        Text(verbatim: "—")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink3)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(Text("Summarising…"))
                } else {
                    VStack(spacing: 8) {
                        ForEach(summary.byDevice) { device in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(verbatim: device.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Palette.ink1)
                                    .lineLimit(1)
                                if isLocalDevice(device) {
                                    ThisMacBadge()
                                }
                                if let status = remoteStatusLabel(for: device) {
                                    Text(status)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Palette.healthWarn)
                                        .fixedSize()
                                }
                                Spacer(minLength: 8)
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(TokenFormat.short(device.counts.total))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Palette.ink1)
                                    if hidesDeviceShare {
                                        Text("Included")
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(Palette.ink3)
                                    } else {
                                        Text(Share.percent(device.counts.total, of: summary.total.total))
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(Palette.ink3)
                                    }
                                }
                                .monospacedDigit()
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityValue(TokenFormat.spoken(device.counts.total))
                        }

                        // A remote Mac whose snapshot could not be read adds no rows; keep it visible, not silently absent.
                        ForEach(missingRemoteDevices, id: \.deviceID) { remote in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.healthWarn)
                                    .accessibilityHidden(true)
                                // An unreadable identity leaves only the device ID, which the CLI also names "Unknown Mac".
                                (remote.displayName == remote.deviceID ? Text("Unknown Mac") : Text(verbatim: remote.displayName))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Palette.healthWarn)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(remote.state == .stale ? "Stale" : "Unavailable")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(Palette.healthWarn)
                                    .fixedSize()
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
    }

    private var missingRemoteDevices: [RemoteDeviceStatus] {
        model.remoteDevices.filter { remote in
            remote.state != .ok && !summary.byDevice.contains { $0.id == remote.deviceID }
        }
    }

    /// Avoids showing local usage as 100.0% when another Mac is unavailable or incomplete.
    private var hidesDeviceShare: Bool {
        guard model.dataIssues.devices > 0 else { return false }
        return !missingRemoteDevices.isEmpty
            || summary.byDevice.count == 1
            || model.remoteDevices.contains { $0.state == .unavailable || $0.state == .partial }
    }

    private func isLocalDevice(_ device: Breakdown) -> Bool {
        if let storedID = LocalDevice.storedID(), summary.devices.contains(where: { $0.id == storedID }) {
            return device.id == storedID
        }
        if !model.remoteDevices.isEmpty {
            return !model.remoteDevices.contains { $0.deviceID == device.id }
        }
        return summary.devices.first?.id == device.id
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

private struct PartialDeviceBanner: View {
    let summary: UsageSummary
    let remoteDevices: [RemoteDeviceStatus]
    let deviceIssueCount: Int
    let reduceTransparency: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.healthWarn)
                .accessibilityHidden(true)
            message
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.healthWarn)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                .fill(Palette.healthWarn.opacity(reduceTransparency ? 0.18 : 0.12))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                .strokeBorder(Palette.healthWarn.opacity(0.30), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var message: Text {
        let issueDevices = remoteDevices.filter { $0.state != .ok }
        if issueDevices.count == 1, let remote = issueDevices.first {
            let name = remote.displayName == remote.deviceID ? String(localized: "Unknown Mac") : remote.displayName
            if !summary.byDevice.contains(where: { $0.id == remote.deviceID }) {
                return Text("Does not include \(name)")
            }
            let state = remote.state == .stale ? String(localized: "Stale") : String(localized: "Unavailable")
            return Text("\(name): \(state)")
        }
        return Text(deviceIssueCount == 1 ? "1 Mac unavailable" : "\(deviceIssueCount) Macs unavailable")
    }
}

private struct ThisMacBadge: View {
    var body: some View {
        Text("This Mac")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.ink2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: Radius.badge, style: .continuous)
                    .fill(Palette.ink1.opacity(0.06))
            }
            .fixedSize()
    }
}

private struct CategoryRow: View {
    let category: TokenCategory
    let value: Int64
    let total: Int64
    let isCollecting: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(Palette.color(for: category).opacity(isCollecting ? 0.45 : 1))
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(category.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.ink1)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if isCollecting {
                        Text(verbatim: "—")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink3)
                    } else {
                        Text(Share.percent(value, of: total))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.ink1)
                    }
                }

                FullWidthProportionBar(
                    ratio: isCollecting ? 0 : Share.ratio(value, of: total),
                    color: Palette.color(for: category),
                    height: 3
                )

                if !isCollecting {
                    Text("\(TokenFormat.short(value)) tokens")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
        .accessibilityValue(isCollecting ? Text("Summarising…") : Text(TokenFormat.spoken(value)))
    }
}

struct FullWidthProportionBar: View {
    let ratio: Double
    let color: Color
    let height: CGFloat

    var body: some View {
        let clamped = min(max(ratio, 0), 1)
        GeometryReader { proxy in
            let width = proxy.size.width
            let fillWidth = clamped > 0 ? min(width, max(height, width * CGFloat(clamped))) : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Palette.barTrack)
                    .frame(width: width, height: height)
                if fillWidth > 0 {
                    Capsule()
                        .fill(color)
                        .frame(width: fillWidth, height: height)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct ProportionBar: View {
    let ratio: Double
    let color: Color
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let clamped = min(max(ratio, 0), 1)
        let fillWidth = clamped > 0 ? max(height, width * CGFloat(clamped)) : 0
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Palette.barTrack)
                .frame(width: width, height: height)
            if fillWidth > 0 {
                Capsule()
                    .fill(color)
                    .frame(width: fillWidth, height: height)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct RailSection<Content: View>: View {
    let title: LocalizedStringKey
    let note: LocalizedStringKey?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHead(title: title, note: note)
            content
        }
        .padding(.top, 16)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        .padding(.top, 16)
    }
}

struct SectionHead: View {
    let title: LocalizedStringKey
    let note: LocalizedStringKey?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink1)
            Spacer(minLength: 8)
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Bottom breakdown card

/// Single-column two-line breakdown card with a `Models · N | Sources · N` switch.
struct BreakdownCard: View {
    let summary: UsageSummary

    private enum Mode: CaseIterable, Hashable {
        case models
        case sources
    }

    private let limit = 4

    @State private var mode: Mode = .models
    @State private var showsAllModels = false
    @State private var showsAllSources = false
    @Namespace private var switchNamespace
    @FocusState private var focusedMode: Mode?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    private var items: [Breakdown] {
        switch mode {
        case .models: summary.byModel
        case .sources: summary.bySource
        }
    }

    private var isExpanded: Bool {
        switch mode {
        case .models: showsAllModels
        case .sources: showsAllSources
        }
    }

    private var soleActiveSourceName: String? {
        let active = summary.bySource.filter { $0.counts.total > 0 }
        return active.count == 1 ? active[0].name : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 8)

            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 0.5)

            if items.isEmpty {
                Text("No usage in this period")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                let visible = isExpanded ? items : Array(items.prefix(limit))
                let modelColors = mode == .models ? Palette.modelColors(for: visible.map(\.id)) : [:]
                if isExpanded && items.count > limit {
                    ScrollView {
                        rowList(visible, modelColors: modelColors)
                    }
                    .frame(maxHeight: 220)
                } else {
                    rowList(visible, modelColors: modelColors)
                }

                if items.count > limit {
                    footer
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 12) {
            GlassEffectContainer(spacing: 0) {
                HStack(spacing: 2) {
                    modeSegment(.models, label: "Models · \(summary.byModel.count)")
                    modeSegment(.sources, label: "Sources · \(summary.bySource.count)")
                }
                .padding(2)
            }
            .fixedSize(horizontal: true, vertical: false)
            .background(Capsule().fill(Palette.barTrack))
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: reduceTransparency ? 1 : 0.5))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Breakdown view"))

            Spacer(minLength: 8)

            Text("By tokens, descending")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.ink3)
                .lineLimit(1)
        }
    }

    private func modeSegment(_ target: Mode, label: LocalizedStringKey) -> some View {
        let isSelected = mode == target
        return Button {
            selectMode(target)
        } label: {
            Text(label)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Palette.ink1 : Palette.ink2)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 24)
                .padding(.horizontal, 12)
                .contentShape(Capsule())
                .modifier(BreakdownSegmentSurface(
                    isSelected: isSelected,
                    reduceTransparency: reduceTransparency,
                    namespace: switchNamespace
                ))
        }
        .buttonStyle(.plain)
        .focused($focusedMode, equals: target)
        .onKeyPress(.leftArrow) {
            selectMode(.models)
            focusedMode = .models
            return .handled
        }
        .onKeyPress(.rightArrow) {
            selectMode(.sources)
            focusedMode = .sources
            return .handled
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func selectMode(_ target: Mode) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
            mode = target
        }
    }

    private func rowList(_ visible: [Breakdown], modelColors: [String: Color]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { entry in
                if entry.offset > 0 {
                    Rectangle()
                        .fill(Palette.hairline)
                        .frame(height: 0.5)
                }
                row(entry.element, modelColors: modelColors)
            }
        }
    }

    private func row(_ item: Breakdown, modelColors: [String: Color]) -> some View {
        let isModel = mode == .models
        let color = isModel
            ? (modelColors[item.id] ?? Palette.color(for: .output))
            : Palette.color(forSource: item.id)
        let secondary = isModel ? soleActiveSourceName : nil

        return Group {
            if let secondary {
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(color)
                            .frame(width: 8, height: 8)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                            .accessibilityHidden(true)

                        Text(verbatim: item.name)
                            .font(isModel
                                ? .system(size: 13, weight: .semibold, design: .monospaced)
                                : .system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.ink1)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .accessibilityLabel(Text(verbatim: item.name))

                        Spacer(minLength: 12)

                        Text("\(TokenFormat.short(item.counts.total)) tokens")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.ink1)
                            .monospacedDigit()
                            .fixedSize()
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Mainly from \(secondary)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.ink2)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            ProportionBar(
                                ratio: Share.ratio(item.counts.total, of: summary.total.total),
                                color: color,
                                width: 120,
                                height: 4
                            )
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.0 }

                            Text(Share.percent(item.counts.total, of: summary.total.total))
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.ink2)
                                .monospacedDigit()
                                .fixedSize()
                                .frame(minWidth: 46, alignment: .trailing)
                        }
                    }
                    .padding(.leading, 16)
                }
                .padding(.vertical, 6)
                .frame(minHeight: 44)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(color)
                            .frame(width: 8, height: 8)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                            .accessibilityHidden(true)

                        Text(verbatim: item.name)
                            .font(isModel
                                ? .system(size: 13, weight: .semibold, design: .monospaced)
                                : .system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.ink1)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .accessibilityLabel(Text(verbatim: item.name))
                    }

                    Spacer(minLength: 0)

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(TokenFormat.short(item.counts.total)) tokens")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.ink1)
                            .monospacedDigit()
                            .fixedSize()

                        ProportionBar(
                            ratio: Share.ratio(item.counts.total, of: summary.total.total),
                            color: color,
                            width: 120,
                            height: 4
                        )
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }

                        Text(Share.percent(item.counts.total, of: summary.total.total))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.ink2)
                            .monospacedDigit()
                            .fixedSize()
                            .frame(minWidth: 46, alignment: .trailing)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44)
            }
        }
        .help(item.name)
        .accessibilityElement(children: .combine)
        .accessibilityValue(TokenFormat.spoken(item.counts.total))
    }

    private var footer: some View {
        let remaining = Array(items.dropFirst(limit))
        return VStack(spacing: 0) {
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 0.5)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if isExpanded {
                    Text("Showing all \(items.count)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.ink3)
                        .monospacedDigit()
                } else {
                    Text(otherSummaryText(for: remaining))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.ink3)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Button {
                    toggleExpanded()
                } label: {
                    Group {
                        if isExpanded {
                            Text("Show top 4")
                        } else {
                            Text("Show all \(items.count) ›")
                        }
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.roleAccent)
                    .monospacedDigit()
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            .padding(.top, 4)
        }
    }

    private func toggleExpanded() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            switch mode {
            case .models:
                showsAllModels.toggle()
            case .sources:
                showsAllSources.toggle()
            }
        }
    }

    private func otherSummaryText(for remaining: [Breakdown]) -> String {
        let preview: String = switch remaining.count {
        case 0:
            ""
        case 1:
            remaining[0].name
        case 2:
            String(localized: "\(remaining[0].name), \(remaining[1].name)")
        default:
            String(localized: "\(remaining[0].name), \(remaining[1].name), …")
        }
        let remainingTokens = remaining.reduce(Int64(0)) { $0 + $1.counts.total }
        let totalShort = TokenFormat.short(remainingTokens)
        let shareText = Share.percent(remainingTokens, of: summary.total.total)
        return switch mode {
        case .models:
            String(localized: "Other \(remaining.count) models (\(preview)) total \(totalShort) (\(shareText))")
        case .sources:
            String(localized: "Other \(remaining.count) sources (\(preview)) total \(totalShort) (\(shareText))")
        }
    }
}

private struct BreakdownSegmentSurface: ViewModifier {
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
                .glassEffectID("breakdownMode", in: namespace)
        }
    }
}
