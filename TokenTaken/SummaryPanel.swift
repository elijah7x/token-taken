import Foundation
import SwiftUI
import TokenTakenKit

// MARK: - Left sidebar summary rail

/// Period range, total, cost estimate and partial-device notice for the selected period.
struct SummaryRail: View {
    let summary: UsageSummary
    var isCollecting = false

    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(periodDescription)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ink2)
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(reduceMotion ? .identity : .numericText())

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
                .padding(.top, 4)

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

                if model.dataIssues.devices > 0 {
                    PartialDeviceBanner(
                        summary: summary,
                        remoteDevices: model.remoteDevices,
                        deviceIssueCount: model.dataIssues.devices,
                        reduceTransparency: reduceTransparency
                    )
                    .padding(.top, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var periodDescription: LocalizedStringKey {
        let start = summary.start
        switch model.period {
        case .day:
            return "Today · \(start.formatted(.dateTime.locale(locale).month(.abbreviated).day()))"
        case .week:
            let today = Calendar.current.date(byAdding: .day, value: -1, to: summary.end) ?? start
            return "This week · \(start.formatted(.dateTime.locale(locale).month(.abbreviated).day()))–\(today.formatted(.dateTime.locale(locale).month(.abbreviated).day()))"
        case .month:
            return "This month · \(start.formatted(.dateTime.locale(locale).year().month(.wide)))"
        case .year:
            return "This year · \(start.formatted(.dateTime.locale(locale).year()))"
        case .all:
            return "All time · since \(start.formatted(.dateTime.locale(locale).year().month(.abbreviated).day()))"
        }
    }

    private var costHelp: Text {
        let table = Text("Price table \(summary.cost.priceTableVersion)")
        guard summary.cost.unpricedTokens > 0 else { return table }
        return Text("\(TokenFormat.short(summary.cost.unpricedTokens)) tokens unpriced, not included in the estimate") + Text(verbatim: "\n") + table
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
        TimelineView(.everyMinute) { context in
            if isCollecting {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .center, spacing: 6) {
                        Text(verbatim: Host.current().localizedName ?? "Mac")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.ink1)
                            .lineLimit(1)
                        ThisMacBadge()
                    }
                    Text(verbatim: "—")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink2)
                    Text("Summarising…")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text("Summarising…"))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(summary.byDevice) { device in
                        deviceBlock(device, now: context.date)
                    }

                    // A remote Mac whose snapshot could not be read adds no rows; keep it visible, not silently absent.
                    ForEach(missingRemoteDevices, id: \.deviceID) { remote in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.healthWarn)
                                    .accessibilityHidden(true)
                                // An unreadable identity leaves only the device ID, which the CLI also names "Unknown Mac".
                                (remote.displayName == remote.deviceID ? Text("Unknown Mac") : Text(verbatim: remote.displayName))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Palette.healthWarn)
                                    .lineLimit(1)
                            }
                            Text(remote.state == .stale ? "Stale" : "Unavailable")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Palette.healthWarn)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private func deviceBlock(_ device: Breakdown, now: Date) -> some View {
        let isLocal = isLocalDevice(device)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 6) {
                Text(verbatim: device.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink1)
                    .lineLimit(1)
                if isLocal {
                    ThisMacBadge()
                }
            }

            Group {
                if hidesDeviceShare {
                    Text(verbatim: "\(TokenFormat.short(device.counts.total)) · ") + Text("Included")
                } else {
                    Text(verbatim: "\(TokenFormat.short(device.counts.total)) · \(Share.percent(device.counts.total, of: summary.total.total))")
                }
            }
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(Palette.ink2)
            .lineLimit(1)

            if let update = updateStatus(for: device, isLocal: isLocal, now: now) {
                update.text
                    .font(.system(size: 11, weight: update.isWarning ? .medium : .regular))
                    .foregroundStyle(update.isWarning ? Palette.healthWarn : Palette.ink3)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(TokenFormat.spoken(device.counts.total))
    }

    private func updateStatus(
        for device: Breakdown,
        isLocal: Bool,
        now: Date
    ) -> (text: Text, isWarning: Bool)? {
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
            if let lastRefresh = refreshCoordinator.lastRefresh {
                if now.timeIntervalSince(lastRefresh) < 60 {
                    return (Text("Updated just now"), false)
                }
                return (Text("Updated \(relativeTime(for: lastRefresh, now: now))"), false)
            }
            return (Text("Not updated yet"), false)
        }

        guard let remote = model.remoteDevices.first(where: {
            $0.deviceID == device.id || $0.displayName == device.name
        }) else {
            return nil
        }

        let effectiveState: RemoteDeviceStatus.State =
            remote.state == .ok && remote.lastWrite.map({ now.timeIntervalSince($0) > 86_400 }) == true
            ? .stale
            : remote.state

        switch effectiveState {
        case .ok:
            guard let lastWrite = remote.lastWrite else { return nil }
            if now.timeIntervalSince(lastWrite) < 60 {
                return (Text("Updated just now"), false)
            }
            return (Text("Updated \(relativeTime(for: lastWrite, now: now))"), false)
        case .stale:
            return (Text("Stale"), true)
        case .partial, .unavailable:
            return (Text("Unavailable"), true)
        }
    }

    private func relativeTime(for date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = locale
        return formatter.localizedString(for: date, relativeTo: now)
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

/// Single-column breakdown list matching the active `BreakdownDimension`.
struct BreakdownCard: View {
    let summary: UsageSummary
    let dimension: BreakdownDimension

    // A footer that folds a single row saves nothing; show it instead.
    private var limit: Int { items.count == 5 ? 5 : 4 }

    @State private var showsAllModels = false
    @State private var showsAllSources = false
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
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                let visible = isExpanded ? items : Array(items.prefix(limit))
                let modelColors = dimension == .models ? Palette.modelColors(for: visible.map(\.id)) : [:]
                if isExpanded && items.count > limit {
                    ScrollView {
                        rowList(visible, modelColors: modelColors)
                    }
                    .frame(maxHeight: 240)
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
        let isModel = dimension == .models
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
                .frame(minHeight: 48)
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
                .frame(minHeight: 48)
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
            switch dimension {
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
            String(localized: "\(remaining[0].name), \(remaining[1].name)", locale: locale)
        default:
            String(localized: "\(remaining[0].name), \(remaining[1].name), …", locale: locale)
        }
        let remainingTokens = remaining.reduce(Int64(0)) { $0 + $1.counts.total }
        let totalShort = TokenFormat.short(remainingTokens)
        let shareText = Share.percent(remainingTokens, of: summary.total.total)
        return switch dimension {
        case .models:
            String(localized: "Other \(remaining.count) models (\(preview)) total \(totalShort) (\(shareText))", locale: locale)
        case .sources:
            String(localized: "Other \(remaining.count) sources (\(preview)) total \(totalShort) (\(shareText))", locale: locale)
        }
    }
}
