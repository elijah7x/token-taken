import AppKit
import Foundation
import SwiftUI
import TokenTakenKit

// MARK: - Left sidebar summary rail

/// Total and cost estimate for the selected period.
struct SummaryRail: View {
    let summary: UsageSummary
    var isCollecting = false

    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isCollecting {
                Text(verbatim: "—")
                    .font(ThemeFont.role(.heroNumber))
                    .foregroundStyle(Palette.ink3)
                    .padding(.top, 4)
                    .accessibilityHidden(true)

                Text("Summarising…")
                    .font(ThemeFont.role(.caption))
                    .foregroundStyle(Palette.ink3)
                    .padding(.top, 4)
            } else {
                DataHoverPopover(width: 280) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(TokenFormat.short(summary.total.total))
                            .font(ThemeFont.role(.heroNumber))
                            .tracking(-1.0)
                            .foregroundStyle(Palette.ink1)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .contentTransition(reduceMotion ? .identity : .numericText())
                        Text("tokens")
                            .font(ThemeFont.role(.heroUnit))
                            .foregroundStyle(Palette.ink2)
                            .fixedSize()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Total"))
                    .accessibilityValue(Text("\(summary.total.total.formatted(.number.locale(locale))) tokens"))
                } content: {
                    Text("\(summary.total.total.formatted(.number.locale(locale))) tokens")
                }
                .padding(.top, 6)

                if ThemeChrome.separatesSectionsWithRules {
                    Rectangle()
                        .fill(Palette.hairline)
                        .frame(height: 1)
                        .padding(.vertical, 12)
                        .accessibilityHidden(true)
                }

                DataHoverPopover(width: 280) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Group {
                            if isFullyUnpriced {
                                Text("Unpriced")
                            } else {
                                Text("≈ \(TokenFormat.usd(summary.cost.estimatedUSD)) · estimate")
                            }
                        }
                        .font(ThemeFont.role(.secondaryNumber))
                        .foregroundStyle(Palette.ink1)
                        .contentTransition(reduceMotion ? .identity : .numericText())

                        if summary.cost.unpricedTokens > 0 {
                            Image(systemName: "info.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.ink3)
                                .accessibilityLabel(Text("Unpriced tokens"))
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .accessibilityElement(children: .combine)
                } content: {
                    costHelp
                }
                .padding(.top, ThemeChrome.separatesSectionsWithRules ? 0 : 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isFullyUnpriced: Bool {
        summary.cost.unpricedTokens > 0 && summary.cost.unpricedTokens >= summary.total.total
    }

    private var costHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            if summary.cost.unpricedTokens > 0 {
                Text("\(TokenFormat.short(summary.cost.unpricedTokens)) tokens unpriced, not included in the estimate")
            }
            Text("estimate, not a bill")
            Text("Price table \(summary.cost.priceTableVersion)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.ink3)
        }
        .font(ThemeFont.role(.caption))
        .foregroundStyle(Palette.ink2)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Devices in the tray: each Mac as a stacked block, plus any remote Mac that could not be read.
struct TrayDevices: View {
    let summary: UsageSummary
    var isCollecting = false

    @Environment(AppModel.self) private var model
    @Environment(RefreshCoordinator.self) private var refreshCoordinator: RefreshCoordinator?
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Devices")
                .font(ThemeFont.role(.sectionHeader))
                .foregroundStyle(Palette.ink3)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            deviceTimeline
        }
    }

    private var deviceTimeline: some View {
        TimelineView(.everyMinute) { context in
            if isCollecting {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .center, spacing: 6) {
                        Text(verbatim: Host.current().localizedName ?? "Mac")
                            .font(ThemeFont.role(.bodyStrong))
                            .foregroundStyle(Palette.ink1)
                            .lineLimit(1)
                        ThisMacBadge()
                    }
                    Text(verbatim: "—")
                        .font(ThemeFont.role(.numericCaption))
                        .foregroundStyle(Palette.ink2)
                    Text("Summarising…")
                        .font(ThemeFont.role(.caption))
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, ThemeChrome.separatesSectionsWithRules ? 8 : 0)
                .overlay(alignment: .top) {
                    if ThemeChrome.separatesSectionsWithRules {
                        Rectangle()
                            .fill(Palette.hairline)
                            .frame(height: 1)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: Host.current().localizedName ?? "Mac") + Text(verbatim: ", ") + Text("This Mac"))
                .accessibilityValue(Text("Summarising…"))
            } else {
                VStack(alignment: .leading, spacing: ThemeChrome.separatesSectionsWithRules ? 0 : 12) {
                    ForEach(summary.byDevice) { device in
                        deviceBlock(device, now: context.date)
                    }

                    // A remote Mac whose snapshot could not be read adds no rows; keep it visible, not silently absent.
                    ForEach(missingRemoteDevices(now: context.date), id: \.deviceID) { remote in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.healthWarn)
                                    .accessibilityHidden(true)
                                // An unreadable identity leaves only the device ID, which the CLI also names "Unknown Mac".
                                (remote.displayName == remote.deviceID ? Text("Unknown Mac") : Text(verbatim: remote.displayName))
                                    .font(ThemeFont.role(.bodyStrong))
                                    .foregroundStyle(Palette.healthWarn)
                                    .lineLimit(1)
                            }
                            Text(remoteLabelKey(for: remote.effectiveState(now: context.date)))
                                .font(ThemeFont.role(.caption))
                                .foregroundStyle(Palette.healthWarn)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, ThemeChrome.separatesSectionsWithRules ? 8 : 0)
                        .overlay(alignment: .top) {
                            if ThemeChrome.separatesSectionsWithRules {
                                Rectangle()
                                    .fill(Palette.hairline)
                                    .frame(height: 1)
                                    .accessibilityHidden(true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private func deviceBlock(_ device: Breakdown, now: Date) -> some View {
        let isLocal = isLocalDevice(device)
        let isAccount = deviceKind(device) == .account
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 6) {
                Text(verbatim: device.name)
                    .font(ThemeFont.role(.bodyStrong))
                    .foregroundStyle(Palette.ink1)
                    .lineLimit(1)
                if isAccount {
                    AccountBadge()
                }
                if isLocal {
                    ThisMacBadge()
                }
            }

            Group {
                if hidesDeviceShare(now: now) {
                    Text(verbatim: "\(TokenFormat.short(device.counts.total)) · ") + Text("Included")
                } else {
                    Text(verbatim: "\(TokenFormat.short(device.counts.total)) · \(Share.percent(device.counts.total, of: summary.total.total))")
                }
            }
            .font(ThemeFont.role(.numericCaption))
            .foregroundStyle(Palette.ink2)
            .lineLimit(1)

            if let update = updateStatus(for: device, isLocal: isLocal, now: now) {
                update.text
                    .font(ThemeFont.make(11, weight: update.isWarning ? .medium : .regular))
                    .foregroundStyle(update.isWarning ? Palette.healthWarn : Palette.ink3)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, ThemeChrome.separatesSectionsWithRules ? 8 : 0)
        .overlay(alignment: .top) {
            if ThemeChrome.separatesSectionsWithRules {
                Rectangle()
                    .fill(Palette.hairline)
                    .frame(height: 1)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(deviceAccessibilityLabel(device, isAccount: isAccount, isLocal: isLocal))
        .accessibilityValue(deviceAccessibilityValue(device, isLocal: isLocal, now: now))
    }

    private func deviceAccessibilityLabel(_ device: Breakdown, isAccount: Bool, isLocal: Bool) -> Text {
        var label = Text(verbatim: device.name)
        if isAccount {
            label = label + Text(verbatim: ", ") + Text("Account")
        }
        if isLocal {
            label = label + Text(verbatim: ", ") + Text("This Mac")
        }
        return label
    }

    private func deviceAccessibilityValue(_ device: Breakdown, isLocal: Bool, now: Date) -> Text {
        var value = Text("\(TokenFormat.spoken(device.counts.total)) tokens")
        if hidesDeviceShare(now: now) {
            value = value + Text(verbatim: ", ") + Text("Included")
        } else {
            value = value + Text(verbatim: ", \(Share.percent(device.counts.total, of: summary.total.total))")
        }
        if let update = updateStatus(for: device, isLocal: isLocal, now: now) {
            value = value + Text(verbatim: ", ") + update.text
        }
        return value
    }

    private func updateStatus(
        for device: Breakdown,
        isLocal: Bool,
        now: Date
    ) -> (text: Text, isWarning: Bool)? {
        // An account device is neither this Mac nor another one; it has no local collection state.
        if deviceKind(device) == .account { return nil }
        if isLocal {
            if model.storageError != nil || model.readError != nil {
                return (Text("Storage unavailable"), true)
            }
            guard let refreshCoordinator else {
                return (Text("Not updated yet"), false)
            }
            if refreshCoordinator.isRefreshing {
                return (Text("Updating…"), false)
            }
            switch refreshCoordinator.engineStatus {
            case .found:
                break
            case .missing:
                return (Text("Collection engine not found"), true)
            case .invalidOverride:
                return (Text("Invalid engine override"), true)
            }
            if let lastScan = model.lastUpdated {
                if now.timeIntervalSince(lastScan) < 60 {
                    return (Text("Updated just now"), false)
                }
                return (Text("Updated \(relativeTime(for: lastScan, now: now))"), false)
            }
            return (Text("Not updated yet"), false)
        }

        guard let remote = model.remoteDevices.first(where: {
            $0.deviceID == device.id || $0.displayName == device.name
        }) else {
            return nil
        }

        let effectiveState = remote.effectiveState(now: now)

        switch effectiveState {
        case .ok:
            guard let lastWrite = remote.lastWrite else { return nil }
            if now.timeIntervalSince(lastWrite) < 60 {
                return (Text("Updated just now"), false)
            }
            return (Text("Updated \(relativeTime(for: lastWrite, now: now))"), false)
        case .stale:
            return (Text("Stale"), true)
        case .partial:
            return (Text("Partial"), true)
        case .unavailable:
            return (Text("Unavailable"), true)
        }
    }

    private func remoteLabelKey(for state: RemoteDeviceStatus.State) -> LocalizedStringKey {
        switch state {
        case .ok: "Synced"
        case .stale: "Stale"
        case .partial: "Partial"
        case .unavailable: "Unavailable"
        }
    }

    private func relativeTime(for date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = locale
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private func missingRemoteDevices(now: Date) -> [RemoteDeviceStatus] {
        model.remoteDevices.filter { remote in
            remote.isStaleOrIncomplete(now: now) && !summary.byDevice.contains { $0.id == remote.deviceID }
        }
    }

    /// Avoids showing local usage as 100.0% when another Mac is unavailable or incomplete.
    private func hidesDeviceShare(now: Date) -> Bool {
        guard model.dataIssues(now: now).devices > 0 else { return false }
        return !missingRemoteDevices(now: now).isEmpty
            || macDeviceCount == 1
            || model.remoteDevices.contains {
                let state = $0.effectiveState(now: now)
                return state == .unavailable || state == .partial
            }
    }

    /// Account devices carry one account's usage, so they never make the Mac share look like a single Mac.
    private var macDeviceCount: Int {
        summary.byDevice.filter { deviceKind($0) == .mac }.count
    }

    private func deviceKind(_ device: Breakdown) -> DeviceKind {
        summary.devices.first { $0.id == device.id }?.kind ?? .mac
    }

    private func isLocalDevice(_ device: Breakdown) -> Bool {
        if deviceKind(device) == .account { return false }
        if let storedID = LocalDevice.storedID(), summary.devices.contains(where: { $0.id == storedID }) {
            return device.id == storedID
        }
        if !model.remoteDevices.isEmpty {
            return !model.remoteDevices.contains { $0.deviceID == device.id }
        }
        return summary.devices.first?.id == device.id
    }
}

private struct ThisMacBadge: View {
    var body: some View {
        Text("This Mac")
            .font(ThemeFont.role(.caption))
            .foregroundStyle(Palette.ink3)
            .fixedSize()
    }
}

private struct AccountBadge: View {
    var body: some View {
        Text("Account")
            .font(ThemeFont.role(.caption))
            .foregroundStyle(Palette.ink3)
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
            if ThemeChrome.showsSeriesSwatches {
                Circle()
                    .fill(Palette.color(for: category).opacity(isCollecting ? 0.45 : 1))
                    .frame(width: 8, height: 8)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(category.title)
                        .font(ThemeFont.role(.bodyStrong))
                        .foregroundStyle(Palette.ink1)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if isCollecting {
                        Text(verbatim: "—")
                            .font(ThemeFont.role(.body))
                            .foregroundStyle(Palette.ink3)
                    } else {
                        Text(Share.percent(value, of: total))
                            .font(ThemeFont.make(13, weight: .semibold, numeric: true))
                            .foregroundStyle(Palette.ink1)
                    }
                }

                if ThemeChrome.showsSeriesSwatches {
                    FullWidthProportionBar(
                        ratio: isCollecting ? 0 : Share.ratio(value, of: total),
                        color: Palette.color(for: category),
                        height: 3
                    )
                }

                if !isCollecting {
                    Text("\(TokenFormat.short(value)) tokens")
                        .font(ThemeFont.role(.numericCaption))
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(category.title))
        .accessibilityValue(
            isCollecting
                ? Text("Summarising…")
                : Text("\(TokenFormat.spoken(value)) tokens, \(Share.percent(value, of: total)) of total")
        )
    }
}

struct FullWidthProportionBar: View {
    let ratio: Double
    let color: Color
    let height: CGFloat

    var body: some View {
        let clamped = min(max(ratio, 0), 1)
        let barShape = RoundedRectangle(cornerRadius: min(height / 2, RadiusRole.badge.value), style: .continuous)
        GeometryReader { proxy in
            let width = proxy.size.width
            let fillWidth = clamped > 0 ? min(width, max(height, width * CGFloat(clamped))) : 0
            ZStack(alignment: .leading) {
                barShape
                    .fill(Palette.barTrack)
                    .frame(width: width, height: height)
                if fillWidth > 0 {
                    barShape
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
        let barShape = RoundedRectangle(cornerRadius: min(height / 2, RadiusRole.badge.value), style: .continuous)
        ZStack(alignment: .leading) {
            barShape
                .fill(Palette.barTrack)
                .frame(width: width, height: height)
            if fillWidth > 0 {
                barShape
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
                .font(ThemeFont.role(.title))
                .foregroundStyle(Palette.ink1)
            Spacer(minLength: 8)
            if let note {
                Text(note)
                    .font(ThemeFont.role(.caption))
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Bottom breakdown card

/// Single-column breakdown list matching the active `BreakdownDimension`.
struct BreakdownCard: View {
    let summary: UsageSummary
    let dimension: BreakdownDimension
    @Binding var highlight: String?
    let itemSubtitles: [String: String]
    let itemColors: [String: Color]

    init(
        summary: UsageSummary,
        dimension: BreakdownDimension,
        highlight: Binding<String?> = .constant(nil),
        itemSubtitles: [String: String] = [:],
        itemColors: [String: Color] = [:]
    ) {
        self.summary = summary
        self.dimension = dimension
        self._highlight = highlight
        self.itemSubtitles = itemSubtitles
        self.itemColors = itemColors
    }

    // A footer that folds a single row saves nothing; show it instead.
    private var limit: Int { items.count == 5 ? 5 : 4 }

    @State private var showsAllModels = false
    @State private var showsAllSources = false
    @State private var cacheDetailModelID: String?
    @FocusState private var focusedItemID: String?
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var items: [Breakdown] {
        switch dimension {
        case .models: summary.byModel
        case .sources: summary.bySource
        }
    }

    private var isExpanded: Bool {
        switch dimension {
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
            if items.isEmpty {
                Text("No usage in this period")
                    .font(ThemeFont.role(.body))
                    .foregroundStyle(Palette.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                let visible = isExpanded ? items : Array(items.prefix(limit))
                let modelColors = dimension == .models ? Palette.modelColors(for: visible.map(\.id)) : [:]
                // Row-independent, so resolved once for the whole list instead of per row.
                let soleSource = soleActiveSourceName
                if isExpanded && items.count > limit {
                    ScrollView {
                        rowList(visible, modelColors: modelColors, soleSource: soleSource)
                    }
                    .frame(maxHeight: 240)
                } else {
                    rowList(visible, modelColors: modelColors, soleSource: soleSource)
                }

                if items.count > limit {
                    footer
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: dimension) {
            cacheDetailModelID = nil
            focusedItemID = nil
        }
        .onChange(of: focusedItemID) { oldID, newID in
            if let newID {
                highlight = newID
            } else if let oldID, highlight == oldID {
                highlight = nil
            }
        }
    }

    private func rowList(
        _ visible: [Breakdown],
        modelColors: [String: Color],
        soleSource: String?
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(visible) { item in
                row(item, modelColors: modelColors, soleSource: soleSource)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: Breakdown, modelColors: [String: Color], soleSource: String?) -> some View {
        let isModel = dimension == .models
        let isHighlighted = highlight == item.id
        let isFocused = focusedItemID == item.id
        let color = itemColors[item.id] ?? (
            isModel
                ? (modelColors[item.id] ?? Palette.color(for: .output))
                : Palette.color(forSource: item.id)
        )
        let subtitle = itemSubtitles[item.id].flatMap { $0.isEmpty ? nil : $0 }
        let secondary = isModel ? soleSource : nil
        let detailText = rowDetailText(subtitle: subtitle, secondary: secondary)
        let nameColor: Color = isHighlighted ? Palette.roleAccent : Palette.ink1

        let content = Group {
            if let detailText {
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if ThemeChrome.showsSeriesSwatches {
                            if isModel || ThemeKind.current == .field {
                                Circle()
                                    .fill(color)
                                    .frame(width: 8, height: 8)
                                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                                    .accessibilityHidden(true)
                            } else {
                                SourceIcon(sourceID: item.id, name: item.name, size: 16)
                                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                                    .accessibilityHidden(true)
                            }
                        }

                        Text(verbatim: item.name)
                            .font(isModel && ThemeKind.current != .field
                                ? .system(size: 13, weight: .semibold, design: .monospaced)
                                : ThemeFont.role(.bodyStrong))
                            .foregroundStyle(nameColor)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 12)

                        Text(TokenFormat.short(item.counts.total))
                            .font(ThemeFont.make(13, weight: .semibold, numeric: true))
                            .foregroundStyle(Palette.ink1)
                            .fixedSize()
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        detailText
                            .font(ThemeFont.role(.caption))
                            .foregroundStyle(Palette.ink2)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 8)

                        Text(Share.percent(item.counts.total, of: summary.total.total))
                            .font(ThemeFont.role(.numericCaption))
                            .foregroundStyle(Palette.ink2)
                            .fixedSize()
                            .frame(minWidth: 46, alignment: .trailing)
                    }
                    .padding(.leading, ThemeChrome.showsSeriesSwatches ? (isModel || ThemeKind.current == .field ? 16 : 24) : 0)
                }
                .padding(.vertical, 6)
                .frame(minHeight: 44)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if ThemeChrome.showsSeriesSwatches {
                            if isModel || ThemeKind.current == .field {
                                Circle()
                                    .fill(color)
                                    .frame(width: 8, height: 8)
                                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                                    .accessibilityHidden(true)
                            } else {
                                SourceIcon(sourceID: item.id, name: item.name, size: 16)
                                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                                    .accessibilityHidden(true)
                            }
                        }

                        Text(verbatim: item.name)
                            .font(isModel && ThemeKind.current != .field
                                ? .system(size: 13, weight: .semibold, design: .monospaced)
                                : ThemeFont.role(.bodyStrong))
                            .foregroundStyle(nameColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 0)

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(TokenFormat.short(item.counts.total))
                            .font(ThemeFont.make(13, weight: .semibold, numeric: true))
                            .foregroundStyle(Palette.ink1)
                            .fixedSize()

                        Text(Share.percent(item.counts.total, of: summary.total.total))
                            .font(ThemeFont.role(.numericCaption))
                            .foregroundStyle(Palette.ink2)
                            .fixedSize()
                            .frame(minWidth: 46, alignment: .trailing)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44)
            }
        }
        .background {
            RadiusRole.badge.shape
                .fill(isHighlighted ? Palette.barTrack : .clear)
        }
        .overlay {
            RadiusRole.badge.shape
                .strokeBorder(isFocused ? Palette.roleAccent : .clear, lineWidth: 1)
        }
        .contentShape(Rectangle())

        if isModel {
            Button {
                cacheDetailModelID = item.id
            } label: {
                content
            }
            .buttonStyle(.plain)
            .focused($focusedItemID, equals: item.id)
            .onHover { inside in
                if inside {
                    highlight = item.id
                } else if highlight == item.id {
                    highlight = focusedItemID
                }
            }
            .help(item.name)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rowAccessibilityLabel(item, subtitle: subtitle))
            .accessibilityValue(rowAccessibilityValue(item, secondary: secondary))
            .accessibilityHint(Text("Shows cache details"))
            .accessibilityAddTraits(.isButton)
            .popover(isPresented: cacheDetailPresented(for: item.id), arrowEdge: .trailing) {
                ModelCacheDetail(item: item, color: color)
            }
        } else {
            content
                .focusable(interactions: .activate)
                .focused($focusedItemID, equals: item.id)
                .onHover { inside in
                    if inside {
                        highlight = item.id
                    } else if highlight == item.id {
                        highlight = focusedItemID
                    }
                }
                .help(item.name)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(rowAccessibilityLabel(item, subtitle: subtitle))
                .accessibilityValue(rowAccessibilityValue(item, secondary: secondary))
        }
    }

    private func rowDetailText(subtitle: String?, secondary: String?) -> Text? {
        switch (subtitle, secondary) {
        case let (subtitle?, secondary?):
            return Text(verbatim: "\(subtitle) · ") + Text("Mainly from \(secondary)")
        case let (subtitle?, nil):
            return Text(verbatim: subtitle)
        case let (nil, secondary?):
            return Text("Mainly from \(secondary)")
        case (nil, nil):
            return nil
        }
    }

    private func rowAccessibilityLabel(_ item: Breakdown, subtitle: String?) -> Text {
        if let subtitle {
            return Text(verbatim: "\(item.name), \(subtitle)")
        }
        return Text(verbatim: item.name)
    }

    private func cacheDetailPresented(for modelID: String) -> Binding<Bool> {
        Binding(
            get: { cacheDetailModelID == modelID },
            set: { isPresented in
                if isPresented {
                    cacheDetailModelID = modelID
                } else if cacheDetailModelID == modelID {
                    cacheDetailModelID = nil
                }
            }
        )
    }

    private func rowAccessibilityValue(_ item: Breakdown, secondary: String?) -> Text {
        let base = Text("\(item.counts.total.formatted(.number.locale(locale))) tokens, \(Share.percent(item.counts.total, of: summary.total.total)) of total")
        if let secondary {
            return base + Text(verbatim: ", ") + Text("Mainly from \(secondary)")
        }
        return base
    }

    private var footer: some View {
        let remaining = Array(items.dropFirst(limit))
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if isExpanded {
                    Text("Showing all \(items.count)")
                        .font(ThemeFont.role(.caption))
                        .foregroundStyle(Palette.ink3)
                        .monospacedDigit()
                } else {
                    Text(otherSummaryText(for: remaining))
                        .font(ThemeFont.role(.caption))
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
                            Text("Show less")
                        } else {
                            Text("Show all")
                        }
                    }
                    .font(ThemeFont.role(.control))
                    .foregroundStyle(Palette.roleAccent)
                    .monospacedDigit()
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
                }
                .themedPlainButton()
                .fixedSize()
            }
            .padding(.top, 4)
        }
    }

    private func toggleExpanded() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            switch dimension {
            case .models:
                showsAllModels.toggle()
            case .sources:
                showsAllSources.toggle()
            }
        }
    }

    private func otherSummaryText(for remaining: [Breakdown]) -> LocalizedStringKey {
        let isChinese = locale.language.languageCode == .chinese
        let separator = isChinese ? "、" : ", "
        let preview: String = switch remaining.count {
        case 0:
            ""
        case 1:
            remaining[0].name
        case 2:
            remaining.map(\.name).joined(separator: separator)
        default:
            remaining.prefix(2).map(\.name).joined(separator: separator) + (isChinese ? " 等" : ", …")
        }
        let remainingTokens = remaining.reduce(Int64(0)) { $0 + $1.counts.total }
        let totalShort = TokenFormat.short(remainingTokens)
        let shareText = Share.percent(remainingTokens, of: summary.total.total)
        return switch dimension {
        case .models:
            "Other \(remaining.count) models (\(preview)) total \(totalShort) (\(shareText))"
        case .sources:
            "Other \(remaining.count) harnesses (\(preview)) total \(totalShort) (\(shareText))"
        }
    }
}

struct ModelCacheDetail: View {
    let item: Breakdown
    let color: Color

    @Environment(\.locale) private var locale

    private static let popoverWidth: CGFloat = 260
    private static let popoverPadding: CGFloat = 14
    private static let barWidth: CGFloat = popoverWidth - popoverPadding * 2

    private var promptTokens: Int64 {
        item.counts.input + item.counts.cacheRead + item.counts.cacheWrite
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: item.name)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.ink1)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Cache hit rate")
                    .font(ThemeFont.role(.caption))
                    .foregroundStyle(Palette.ink2)

                if let rate = item.counts.cacheHitRate {
                    Text(rate, format: .percent.precision(.fractionLength(0)))
                        .font(ThemeFont.role(.secondaryNumber, size: 22))
                        .foregroundStyle(Palette.ink1)
                } else {
                    Text(verbatim: "-")
                        .font(ThemeFont.role(.secondaryNumber, size: 22))
                        .foregroundStyle(Palette.ink3)

                    Text(promptTokens == 0 && item.counts.uncategorized == 0
                        ? LocalizedStringKey("No input tokens in this period.")
                        : LocalizedStringKey("Most usage for this model has no category split."))
                        .font(ThemeFont.role(.caption))
                        .foregroundStyle(Palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }

            Rectangle()
                .fill(Palette.hairline)
                .frame(height: ThemeChrome.ruleWidth)

            VStack(alignment: .leading, spacing: 8) {
                splitRow(title: "Uncached input", value: item.counts.input, barColor: color.opacity(0.45))
                splitRow(title: "Cache read", value: item.counts.cacheRead, barColor: color)
                splitRow(title: "Cache write", value: item.counts.cacheWrite, barColor: color.opacity(0.45))
            }

            Rectangle()
                .fill(Palette.hairline)
                .frame(height: ThemeChrome.ruleWidth)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Estimated savings")
                    .font(ThemeFont.role(.control))
                    .foregroundStyle(Palette.ink2)
                Spacer(minLength: 8)
                if let savings = item.cacheSavingsUSD {
                    Text(verbatim: TokenFormat.usd(savings))
                        .font(ThemeFont.make(12, weight: .semibold, numeric: true))
                        .foregroundStyle(Palette.ink1)
                } else {
                    Text("Unpriced")
                        .font(ThemeFont.role(.caption))
                        .foregroundStyle(Palette.ink3)
                }
            }
            .accessibilityElement(children: .combine)

            Text("Rate = cache read ÷ all input tokens. Providers report cache writes differently, so compare models from the same provider.")
                .font(ThemeFont.role(.caption))
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Self.popoverPadding)
        .frame(width: Self.popoverWidth, alignment: .leading)
        .overlay {
            if ThemeChrome.separatesSectionsWithRules {
                RadiusRole.inner.shape
                    .strokeBorder(Palette.hairline, lineWidth: ThemeChrome.ruleWidth)
            }
        }
        .modifier(ThemedPopoverBackground())
    }

    private func splitRow(title: LocalizedStringKey, value: Int64, barColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(ThemeFont.role(.control))
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: TokenFormat.short(value))
                    .font(ThemeFont.make(12, weight: .semibold, numeric: true))
                    .foregroundStyle(Palette.ink1)
                    .fixedSize()
                Text(verbatim: Share.percent(value, of: promptTokens, locale: locale))
                    .font(ThemeFont.role(.numericCaption))
                    .foregroundStyle(Palette.ink2)
                    .fixedSize()
                    .frame(minWidth: 44, alignment: .trailing)
            }

            ProportionBar(
                ratio: Share.ratio(value, of: promptTokens),
                color: barColor,
                width: Self.barWidth,
                height: 4
            )
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ThemedPopoverBackground: ViewModifier {
    func body(content: Content) -> some View {
        switch ThemeKind.current {
        case .field, .cosmos:
            content.presentationBackground(Palette.cardSurface)
        case .liquidGlass:
            content
        }
    }
}
