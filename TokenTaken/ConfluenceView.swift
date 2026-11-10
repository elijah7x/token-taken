import AppKit
import SwiftUI
import TokenTakenKit

/// Sources flow into a glass reservoir and back out through the token categories.
/// All token-to-geometry rules live in `ConfluenceLayout`; only labels and glass are native views.
struct ConfluenceView: View {
    let summary: UsageSummary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    @State private var hover: ConfluenceHover?
    @State private var epoch = Date.now
    @FocusState private var focused: ConfluenceTarget?

    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        GeometryReader { proxy in
            let layout = ConfluenceLayout(summary: summary, size: proxy.size)
            let activeTarget = hover?.target ?? focused

            ZStack(alignment: .topLeading) {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
                    ConfluenceScene(
                        layout: layout,
                        values: layout.animationValues,
                        time: reduceMotion ? 0 : timeline.date.timeIntervalSince(epoch),
                        activeTarget: activeTarget,
                        isDark: scheme == .dark,
                        reduceTransparency: reduceTransparency,
                        focused: $focused
                    )
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.8),
                        value: layout.animationValues
                    )
                }

                if let hover, let stream = layout.stream(for: hover.target) {
                    ConfluenceTooltip(stream: stream, total: layout.totalTokens)
                        .fixedSize()
                        .offset(tooltipOffset(for: hover.location, in: proxy.size))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .contentShape(shape)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hover = layout.hitTest(point).map { ConfluenceHover(target: $0, location: point) }
                case .ended:
                    hover = nil
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: activeTarget)
        }
        .background { surface }
        .clipShape(shape)
        .overlay { shape.strokeBorder(Palette.hairline) }
        .overlay {
            shape.strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(scheme == .dark ? 0.12 : 0.55), .clear],
                    startPoint: .top,
                    endPoint: .center
                ),
                lineWidth: 1
            )
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Confluence of sources into categories"))
    }

    @ViewBuilder private var surface: some View {
        if reduceTransparency {
            shape.fill(Palette.solid)
        } else {
            shape.fill(LinearGradient(
                colors: scheme == .dark
                    ? [.white.opacity(0.07), .white.opacity(0.02)]
                    : [.white.opacity(0.34), .white.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        }
    }

    private func tooltipOffset(for point: CGPoint, in size: CGSize) -> CGSize {
        let width: CGFloat = 210, height: CGFloat = 66
        let x = min(point.x + 14, size.width - width - 8)
        let y = point.y + 16 + height > size.height ? point.y - height - 10 : point.y + 16
        return CGSize(width: max(8, x), height: max(8, y))
    }
}

private struct ConfluenceHover: Equatable {
    var target: ConfluenceTarget
    var location: CGPoint
}

private enum ConfluenceTarget: Hashable {
    case source(String)
    case category(TokenCategory)

    var id: String {
        switch self {
        case .source(let id): "source:\(id)"
        case .category(let category): "category:\(category.rawValue)"
        }
    }
}

// MARK: - Animated scene

private struct ConfluenceScene: View, @MainActor Animatable {
    let layout: ConfluenceLayout
    var values: ConfluenceValues
    let time: Double
    let activeTarget: ConfluenceTarget?
    let isDark: Bool
    let reduceTransparency: Bool
    var focused: FocusState<ConfluenceTarget?>.Binding

    var animatableData: ConfluenceValues {
        get { values }
        set { values = newValue }
    }

    var body: some View {
        let current = layout.interpolated(with: values)

        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                ConfluenceRenderer(
                    layout: current,
                    time: time,
                    activeTarget: activeTarget,
                    isDark: isDark,
                    reduceTransparency: reduceTransparency
                )
                .draw(in: &context)
            }
            .accessibilityHidden(true)

            ConfluenceHeadings(layout: current)
            ConfluenceReservoir(layout: current, reduceTransparency: reduceTransparency)

            ForEach(current.sources) { stream in
                ConfluenceStreamLabel(
                    stream: stream,
                    total: current.totalTokens,
                    activeTarget: activeTarget,
                    compact: current.compact,
                    focused: focused
                )
            }
            ForEach(current.categories) { stream in
                ConfluenceStreamLabel(
                    stream: stream,
                    total: current.totalTokens,
                    activeTarget: activeTarget,
                    compact: current.compact,
                    focused: focused
                )
            }

            if current.isEmpty {
                Text("No usage in this period")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .position(x: current.reservoir.midX, y: current.flowBottom - 2)
            }
        }
        .animation(.easeOut(duration: 0.16), value: activeTarget)
    }
}

// MARK: - Native labels and glass

private struct ConfluenceHeadings: View {
    let layout: ConfluenceLayout

    var body: some View {
        Text("Sources")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Palette.muted)
            .frame(width: layout.leftLabelWidth, alignment: .leading)
            .position(x: layout.leftLabelX + layout.leftLabelWidth / 2, y: layout.headerY)
            .accessibilityAddTraits(.isHeader)

        Text("Categories")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Palette.muted)
            .frame(width: layout.rightLabelWidth, alignment: .trailing)
            .position(x: layout.rightLabelX + layout.rightLabelWidth / 2, y: layout.headerY)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct ConfluenceReservoir: View {
    let layout: ConfluenceLayout
    let reduceTransparency: Bool

    var body: some View {
        VStack(spacing: 1) {
            Text(TokenFormat.short(layout.totalTokens))
                .font(.system(size: layout.compact ? 18 : 22, weight: .semibold))
                .tracking(-0.5)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text("Reservoir")
                .font(.system(size: 9))
                .foregroundStyle(Palette.muted)
        }
        .fixedSize()
        .position(x: layout.reservoir.midX, y: layout.headerY)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Reservoir"))
        .accessibilityValue(Text("\(TokenFormat.short(layout.totalTokens)) tokens"))

        Group {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: layout.reservoirCorner, style: .continuous)
                    .strokeBorder(Palette.hairline)
                    .frame(width: layout.reservoir.width, height: layout.reservoir.height)
            } else {
                Color.clear
                    .frame(width: layout.reservoir.width, height: layout.reservoir.height)
                    .glassEffect(.regular, in: .rect(cornerRadius: layout.reservoirCorner))
            }
        }
        .position(x: layout.reservoir.midX, y: layout.reservoir.midY)
        .accessibilityHidden(true)
    }
}

private struct ConfluenceStreamLabel: View {
    let stream: ConfluenceLayout.Stream
    let total: Int64
    let activeTarget: ConfluenceTarget?
    let compact: Bool
    var focused: FocusState<ConfluenceTarget?>.Binding

    private var highlighted: Bool { activeTarget == stream.target }
    private var dimmed: Bool { activeTarget != nil && !highlighted }

    var body: some View {
        VStack(alignment: stream.side == .source ? .trailing : .leading, spacing: 1) {
            confluenceName(stream)
                .font(.system(size: compact ? 10 : 11, weight: highlighted ? .semibold : .medium))
                .foregroundStyle(dimmed ? Palette.muted : Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            valueText
                .font(.system(size: compact ? 9 : 10))
                .foregroundStyle(Palette.muted)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(width: stream.labelFrame.width, height: stream.labelFrame.height)
        .contentShape(Rectangle())
        .position(x: stream.labelFrame.midX, y: stream.labelFrame.midY)
        // Like other non-control content on macOS, join the Tab loop only with Full Keyboard Access;
        // otherwise the window would focus (and highlight) the first stream at launch.
        .focusable(NSApplication.shared.isFullKeyboardAccessEnabled)
        .focused(focused, equals: stream.target)
        .focusEffectDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(confluenceName(stream))
        .accessibilityValue(Text("\(TokenFormat.short(stream.tokens)) tokens, \(Share.percent(stream.tokens, of: total)) of total"))
    }

    private var valueText: Text {
        switch stream.side {
        case .source:
            Text(verbatim: TokenFormat.short(stream.tokens))
        case .category:
            Text("\(TokenFormat.short(stream.tokens)) · \(Share.percent(stream.tokens, of: total))")
        }
    }
}

private func confluenceName(_ stream: ConfluenceLayout.Stream) -> Text {
    if let category = stream.category { return Text(category.title) }
    if stream.isOther { return Text("Other") }
    return Text(verbatim: stream.name)
}

// MARK: - Tooltip

private struct ConfluenceTooltip: View {
    let stream: ConfluenceLayout.Stream
    let total: Int64

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(stream.color).frame(width: 6, height: 6)
                confluenceName(stream).font(.system(size: 11, weight: .semibold))
            }
            Text("\(TokenFormat.short(stream.tokens)) tokens").fontWeight(.medium)
            Text("\(Share.percent(stream.tokens, of: total)) of total")
                .foregroundStyle(Palette.muted)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: 210, alignment: .leading)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.solid)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 11))
    }
}

// MARK: - Data-to-form mapping

/// A shared vertical scale maps tokens to ribbon thickness on both sides. Every visible
/// stream has a minimum thickness; labels spread independently so narrow streams stay legible.
/// The reservoir stacks the source colors using the same scale. Flow speed is 36 points/s
/// times the stream's share of the period total, so motion also comes from usage data.
private struct ConfluenceLayout {
    enum Side {
        case source, category
    }

    struct Descriptor {
        let target: ConfluenceTarget
        let side: Side
        let name: String
        let tokens: Int64
        let color: Color
        let category: TokenCategory?
        let isOther: Bool
    }

    struct Stream: Identifiable {
        let target: ConfluenceTarget
        let side: Side
        let name: String
        let tokens: Int64
        let value: Double
        let color: Color
        let category: TokenCategory?
        let isOther: Bool
        let outerFrame: CGRect
        let innerTop: CGFloat
        let innerHeight: CGFloat
        let ribbon: Path
        let centerLine: Path
        var labelFrame: CGRect = .zero
        var leader: Path?

        var id: String { target.id }
    }

    private(set) var sources: [Stream] = []
    private(set) var categories: [Stream] = []
    let totalTokens: Int64
    let reservoir: CGRect
    let reservoirCorner: CGFloat
    let flowBottom: CGFloat
    let flowBasis: Double
    let compact: Bool
    let isEmpty: Bool
    let headerY: CGFloat
    let leftLabelX: CGFloat
    let leftLabelWidth: CGFloat
    let rightLabelX: CGFloat
    let rightLabelWidth: CGFloat

    private let size: CGSize
    private let sourceDescriptors: [Descriptor]
    private let categoryDescriptors: [Descriptor]

    private static let otherID = "__other__"

    var animationValues: ConfluenceValues {
        var streams: [String: Double] = [:]
        for descriptor in sourceDescriptors + categoryDescriptors {
            streams[descriptor.target.id] = Double(descriptor.tokens)
        }
        return ConfluenceValues(streams: streams, total: Double(totalTokens))
    }

    init(summary: UsageSummary, size: CGSize) {
        let positiveSources = summary.bySource
            .filter { $0.counts.total > 0 }
            .sorted { lhs, rhs in
                lhs.counts.total == rhs.counts.total
                    ? lhs.id < rhs.id
                    : lhs.counts.total > rhs.counts.total
            }
        let limit = Self.sourceLimit(for: size, count: positiveSources.count)
        var visible = Array(positiveSources.prefix(limit))
        var otherTokens: Int64 = 0

        if positiveSources.count > limit {
            let kept = max(1, limit - 1)
            visible = Array(positiveSources.prefix(kept))
            otherTokens = positiveSources.dropFirst(kept).reduce(0) { $0 + $1.counts.total }
        }

        let sourceDescriptors = visible.map { source in
            Descriptor(
                target: .source(source.id),
                side: .source,
                name: source.name,
                tokens: source.counts.total,
                color: Palette.color(forSource: source.id),
                category: nil,
                isOther: false
            )
        } + (otherTokens > 0 ? [Descriptor(
            target: .source(Self.otherID),
            side: .source,
            name: "Other",
            tokens: otherTokens,
            color: Palette.muted,
            category: nil,
            isOther: true
        )] : [])

        let categoryDescriptors = TokenCategory.allCases.compactMap { category -> Descriptor? in
            let tokens = summary.total[category]
            guard tokens > 0 else { return nil }
            return Descriptor(
                target: .category(category),
                side: .category,
                name: category.rawValue,
                tokens: tokens,
                color: Palette.color(for: category),
                category: category,
                isOther: false
            )
        }

        self.init(
            sourceDescriptors: sourceDescriptors,
            categoryDescriptors: categoryDescriptors,
            totalTokens: max(0, summary.total.total),
            size: size,
            values: nil
        )
    }

    private init(
        sourceDescriptors: [Descriptor],
        categoryDescriptors: [Descriptor],
        totalTokens: Int64,
        size: CGSize,
        values: ConfluenceValues?
    ) {
        self.sourceDescriptors = sourceDescriptors
        self.categoryDescriptors = categoryDescriptors
        self.totalTokens = totalTokens
        self.size = CGSize(width: max(size.width, 1), height: max(size.height, 1))

        let w = max(size.width, 1), h = max(size.height, 1)
        compact = w < 560 || h < 280
        let bounds = Self.flowBounds(for: size)
        let top = bounds.top, bottom = bounds.bottom
        flowBottom = bottom
        let flowHeight = max(1, bottom - top)
        headerY = max(12, top * 0.42)

        let margin = min(14, max(8, w * 0.025))
        leftLabelWidth = min(compact ? 108 : 140, max(48, w * (compact ? 0.19 : 0.18)))
        rightLabelWidth = min(compact ? 118 : 150, max(60, w * (compact ? 0.21 : 0.19)))
        leftLabelX = margin
        let terminalWidth: CGFloat = 8
        let labelGap: CGFloat = 18
        let leftX = margin + leftLabelWidth + labelGap + terminalWidth
        let rightX = w - margin - rightLabelWidth - labelGap - terminalWidth
        rightLabelX = rightX + labelGap

        let poolWidth = min(58, max(36, w * 0.075))
        let desiredPoolX = (leftX + rightX - poolWidth) / 2
        let minimumPoolX = leftX + 22
        let maximumPoolX = rightX - poolWidth - 22
        let poolX = maximumPoolX >= minimumPoolX
            ? min(max(desiredPoolX, minimumPoolX), maximumPoolX)
            : max(0, (w - poolWidth) / 2)

        let sourceSum = sourceDescriptors.reduce(0.0) { result, descriptor in
            result + max(0, values?.streams[descriptor.target.id] ?? Double(descriptor.tokens))
        }
        let categorySum = categoryDescriptors.reduce(0.0) { result, descriptor in
            result + max(0, values?.streams[descriptor.target.id] ?? Double(descriptor.tokens))
        }
        let animatedTotal = max(0, values?.total ?? Double(totalTokens))
        flowBasis = max(1, max(animatedTotal, max(sourceSum, categorySum)))
        isEmpty = animatedTotal == 0 && sourceSum == 0 && categorySum == 0

        let leftGap: CGFloat = compact ? 6 : 8
        let rightGap: CGFloat = compact ? 8 : 10
        let maximumGaps = max(
            leftGap * CGFloat(max(0, sourceDescriptors.count - 1)),
            rightGap * CGFloat(max(0, categoryDescriptors.count - 1))
        )
        let scale = max(1, flowHeight - maximumGaps) / flowBasis
        let minimumThickness: CGFloat = compact ? 1.8 : 2.2

        func thickness(for descriptor: Descriptor) -> CGFloat {
            let value = max(0, values?.streams[descriptor.target.id] ?? Double(descriptor.tokens))
            return max(minimumThickness, CGFloat(value * scale))
        }

        let sourceHeights = sourceDescriptors.map(thickness)
        let categoryHeights = categoryDescriptors.map(thickness)
        let sourcePoolHeight = sourceHeights.reduce(0, +)
        let categoryPoolHeight = categoryHeights.reduce(0, +)
        let poolHeight = sourceDescriptors.isEmpty && categoryDescriptors.isEmpty
            ? min(120, flowHeight)
            : max(1, max(sourcePoolHeight, categoryPoolHeight))
        reservoir = CGRect(x: poolX, y: top + (flowHeight - poolHeight) / 2, width: poolWidth, height: poolHeight)
        reservoirCorner = min(poolWidth / 2, compact ? 16 : 20)

        sources = Self.makeStreams(
            descriptors: sourceDescriptors,
            heights: sourceHeights,
            values: values,
            side: .source,
            top: top,
            flowHeight: flowHeight,
            gap: leftGap,
            reservoir: reservoir,
            outerX: leftX,
            terminalWidth: terminalWidth,
            labelX: margin,
            labelWidth: leftLabelWidth,
            compact: compact
        )
        categories = Self.makeStreams(
            descriptors: categoryDescriptors,
            heights: categoryHeights,
            values: values,
            side: .category,
            top: top,
            flowHeight: flowHeight,
            gap: rightGap,
            reservoir: reservoir,
            outerX: rightX,
            terminalWidth: terminalWidth,
            labelX: rightX + labelGap,
            labelWidth: rightLabelWidth,
            compact: compact
        )
    }

    func interpolated(with values: ConfluenceValues) -> ConfluenceLayout {
        ConfluenceLayout(
            sourceDescriptors: sourceDescriptors,
            categoryDescriptors: categoryDescriptors,
            totalTokens: totalTokens,
            size: size,
            values: values
        )
    }

    func stream(for target: ConfluenceTarget) -> Stream? {
        (sources + categories).first { $0.target == target }
    }

    func hitTest(_ point: CGPoint) -> ConfluenceTarget? {
        for stream in sources + categories {
            if stream.labelFrame.insetBy(dx: -3, dy: -2).contains(point) {
                return stream.target
            }
            if stream.outerFrame.insetBy(dx: -4, dy: -4).contains(point) {
                return stream.target
            }
        }
        for stream in (sources + categories).reversed() {
            guard stream.ribbon.boundingRect.insetBy(dx: -8, dy: -8).contains(point) else { continue }
            if stream.ribbon.contains(point)
                || stream.ribbon.strokedPath(StrokeStyle(lineWidth: 12)).contains(point) {
                return stream.target
            }
        }
        return nil
    }

    private static func sourceLimit(for size: CGSize, count: Int) -> Int {
        let bounds = flowBounds(for: size)
        let height = max(1, bounds.bottom - bounds.top)
        let pitch: CGFloat = size.height < 280 ? 28 : 32
        let fitting = max(1, Int((height + 4) / pitch))
        return min(7, max(count > 1 ? 2 : 1, fitting))
    }

    private static func flowBounds(for size: CGSize) -> (top: CGFloat, bottom: CGFloat) {
        let h = max(size.height, 1)
        let top = min(h < 240 ? 46 : 56, h * 0.3)
        let bottom = max(top + 1, h - (h < 240 ? 12 : 18))
        return (top, min(h, bottom))
    }

    private static func makeStreams(
        descriptors: [Descriptor],
        heights: [CGFloat],
        values: ConfluenceValues?,
        side: Side,
        top: CGFloat,
        flowHeight: CGFloat,
        gap: CGFloat,
        reservoir: CGRect,
        outerX: CGFloat,
        terminalWidth: CGFloat,
        labelX: CGFloat,
        labelWidth: CGFloat,
        compact: Bool
    ) -> [Stream] {
        guard !descriptors.isEmpty else { return [] }
        let innerHeight = heights.reduce(0, +)
        let outerHeight = innerHeight + gap * CGFloat(descriptors.count - 1)
        var innerY = reservoir.midY - innerHeight / 2
        var outerY = top + (flowHeight - outerHeight) / 2
        var streams: [Stream] = []

        for (index, descriptor) in descriptors.enumerated() {
            let height = heights[index]
            let startX = side == .source ? outerX : reservoir.maxX
            let endX = side == .source ? reservoir.minX : outerX
            let outerFrame = CGRect(
                x: side == .source ? outerX - terminalWidth : outerX,
                y: outerY,
                width: terminalWidth,
                height: height
            )
            // Sources flow outer → reservoir; categories flow reservoir → outer.
            let startY = side == .source ? outerY : innerY
            let endY = side == .source ? innerY : outerY
            let ribbon = ribbonPath(
                startX: startX,
                startTop: startY,
                startBottom: startY + height,
                endX: endX,
                endTop: endY,
                endBottom: endY + height
            )
            let centerLine = centerPath(
                startX: startX,
                startY: startY + height / 2,
                endX: endX,
                endY: endY + height / 2
            )
            streams.append(Stream(
                target: descriptor.target,
                side: side,
                name: descriptor.name,
                tokens: descriptor.tokens,
                value: max(0, values?.streams[descriptor.target.id] ?? Double(descriptor.tokens)),
                color: descriptor.color,
                category: descriptor.category,
                isOther: descriptor.isOther,
                outerFrame: outerFrame,
                innerTop: innerY,
                innerHeight: height,
                ribbon: ribbon,
                centerLine: centerLine
            ))
            innerY += height
            outerY += height + gap
        }

        let labelHeight: CGFloat = compact ? 26 : 30
        let labelPitch: CGFloat = compact ? 28 : 32
        let centers = spread(
            streams.map { $0.outerFrame.midY },
            minimum: top + labelHeight / 2,
            maximum: top + flowHeight - labelHeight / 2,
            gap: labelPitch
        )
        for index in streams.indices {
            let labelY = centers[index]
            streams[index].labelFrame = CGRect(
                x: labelX,
                y: labelY - labelHeight / 2,
                width: labelWidth,
                height: labelHeight
            )
            let streamY = streams[index].outerFrame.midY
            if abs(labelY - streamY) > 2 {
                let direction: CGFloat = side == .source ? -1 : 1
                var leader = Path()
                leader.move(to: CGPoint(x: outerX + direction * 10, y: streamY))
                leader.addLine(to: CGPoint(x: outerX + direction * 16, y: labelY))
                streams[index].leader = leader
            }
        }
        return streams
    }

    private static func spread(
        _ proposed: [CGFloat],
        minimum: CGFloat,
        maximum: CGFloat,
        gap: CGFloat
    ) -> [CGFloat] {
        guard !proposed.isEmpty else { return [] }
        if proposed.count == 1 {
            return [min(max(proposed[0], minimum), max(minimum, maximum))]
        }
        var result = proposed
        result[0] = max(result[0], minimum)
        for index in 1..<result.count {
            result[index] = max(result[index], result[index - 1] + gap)
        }
        if let last = result.indices.last, result[last] > maximum {
            result[last] = max(minimum, maximum)
            for index in stride(from: result.count - 2, through: 0, by: -1) {
                result[index] = min(result[index], result[index + 1] - gap)
            }
        }
        return result
    }

    private static func ribbonPath(
        startX: CGFloat,
        startTop: CGFloat,
        startBottom: CGFloat,
        endX: CGFloat,
        endTop: CGFloat,
        endBottom: CGFloat
    ) -> Path {
        let middleX = (startX + endX) / 2
        var path = Path()
        path.move(to: CGPoint(x: startX, y: startTop))
        path.addCurve(
            to: CGPoint(x: endX, y: endTop),
            control1: CGPoint(x: middleX, y: startTop),
            control2: CGPoint(x: middleX, y: endTop)
        )
        path.addLine(to: CGPoint(x: endX, y: endBottom))
        path.addCurve(
            to: CGPoint(x: startX, y: startBottom),
            control1: CGPoint(x: middleX, y: endBottom),
            control2: CGPoint(x: middleX, y: startBottom)
        )
        path.closeSubpath()
        return path
    }

    private static func centerPath(startX: CGFloat, startY: CGFloat, endX: CGFloat, endY: CGFloat) -> Path {
        let middleX = (startX + endX) / 2
        var path = Path()
        path.move(to: CGPoint(x: startX, y: startY))
        path.addCurve(
            to: CGPoint(x: endX, y: endY),
            control1: CGPoint(x: middleX, y: startY),
            control2: CGPoint(x: middleX, y: endY)
        )
        return path
    }
}

// MARK: - Spring interpolation

private struct ConfluenceValues: VectorArithmetic, Sendable {
    var streams: [String: Double]
    var total: Double

    static let zero = ConfluenceValues(streams: [:], total: 0)

    static func + (lhs: Self, rhs: Self) -> Self {
        combine(lhs, rhs, +)
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        combine(lhs, rhs, -)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.streams == rhs.streams && lhs.total == rhs.total
    }

    mutating func scale(by rhs: Double) {
        streams = streams.mapValues { $0 * rhs }
        total *= rhs
    }

    var magnitudeSquared: Double {
        streams.values.reduce(total * total) { $0 + $1 * $1 }
    }

    private static func combine(
        _ lhs: Self,
        _ rhs: Self,
        _ operation: (Double, Double) -> Double
    ) -> Self {
        var streams = lhs.streams
        for (key, value) in rhs.streams {
            streams[key] = operation(streams[key] ?? 0, value)
        }
        return Self(streams: streams, total: operation(lhs.total, rhs.total))
    }
}

// MARK: - Canvas renderer

private struct ConfluenceRenderer {
    let layout: ConfluenceLayout
    let time: Double
    let activeTarget: ConfluenceTarget?
    let isDark: Bool
    let reduceTransparency: Bool

    func draw(in context: inout GraphicsContext) {
        drawReservoir(in: &context)
        for stream in layout.sources + layout.categories {
            draw(stream, in: &context)
        }
        for stream in layout.sources + layout.categories {
            guard let leader = stream.leader else { continue }
            context.stroke(leader, with: .color(Palette.hairline), lineWidth: 0.8)
        }
    }

    private func drawReservoir(in context: inout GraphicsContext) {
        let shape = Path(roundedRect: layout.reservoir, cornerRadius: layout.reservoirCorner)
        context.drawLayer { layer in
            layer.clip(to: shape)
            layer.fill(
                shape,
                with: .color(reduceTransparency ? Palette.solid : Palette.accent.opacity(isDark ? 0.12 : 0.08))
            )
            for source in layout.sources {
                let rect = CGRect(
                    x: layout.reservoir.minX,
                    y: source.innerTop,
                    width: layout.reservoir.width,
                    height: source.innerHeight
                )
                layer.fill(
                    Path(rect),
                    with: .color(reduceTransparency ? source.color : source.color.opacity(isDark ? 0.5 : 0.4))
                )
            }
        }
    }

    private func draw(_ stream: ConfluenceLayout.Stream, in context: inout GraphicsContext) {
        let highlighted = activeTarget == stream.target
        let dimmed = activeTarget != nil && !highlighted
        let alpha = (highlighted ? 0.96 : isDark ? 0.8 : 0.72) * (dimmed ? 0.2 : 1)
        let fillColor = dimmed && reduceTransparency ? Palette.muted : stream.color
        let bounds = stream.ribbon.boundingRect

        if reduceTransparency {
            context.fill(stream.ribbon, with: .color(fillColor))
        } else {
            let colors = stream.side == .source
                ? [stream.color.opacity(alpha), stream.color.opacity(alpha * 0.58)]
                : [stream.color.opacity(alpha * 0.55), stream.color.opacity(alpha)]
            context.fill(
                stream.ribbon,
                with: .linearGradient(
                    Gradient(colors: colors),
                    startPoint: CGPoint(x: bounds.minX, y: bounds.minY),
                    endPoint: CGPoint(x: bounds.maxX, y: bounds.minY)
                )
            )
            context.fill(
                stream.ribbon,
                with: .linearGradient(
                    Gradient(colors: [
                        .white.opacity(dimmed ? 0.04 : 0.34),
                        .white.opacity(0),
                        .white.opacity(dimmed ? 0.02 : 0.1),
                    ]),
                    startPoint: CGPoint(x: bounds.minX, y: bounds.minY),
                    endPoint: CGPoint(x: bounds.minX, y: bounds.maxY)
                )
            )
        }

        let terminal = Path(roundedRect: stream.outerFrame, cornerRadius: min(4, stream.outerFrame.height / 2))
        context.fill(
            terminal,
            with: .color(reduceTransparency ? fillColor : stream.color.opacity(alpha))
        )

        if highlighted && !reduceTransparency {
            context.stroke(stream.ribbon, with: .color(.white.opacity(0.5)), lineWidth: 0.8)
        }

        guard !dimmed, stream.value > 0 else { return }
        let lineWidth = max(0.65, min(4, stream.innerHeight * 0.16))
        let phase = CGFloat(-time * 36 * stream.value / layout.flowBasis)
        let flowColor = reduceTransparency
            ? Color.white
            : Color.white.opacity(highlighted ? 0.82 : 0.48)
        context.stroke(
            stream.centerLine,
            with: .color(flowColor),
            style: StrokeStyle(
                lineWidth: lineWidth,
                lineCap: .round,
                dash: [2, 28],
                dashPhase: phase
            )
        )
    }
}
