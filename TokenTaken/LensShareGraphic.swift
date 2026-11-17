import Foundation
import SwiftUI
import TokenTakenKit

/// Scoped time-bucket data and frozen peak selection for Liquid Glass Lens share cards.
struct LensShareSnapshot {
    let buckets: [LensBucket]
    let dimension: BreakdownDimension
    let period: Period
    let sourceOrder: [String]
    let modelOrder: [String]
    let frozenRange: ClosedRange<Int>?
    let frozenTotal: Int64

    /// Day-period hourly buckets carry no per-model breakdown (`ADR-0005`), so a single-model day card
    /// keeps the Lens style and states the gap instead of drawing invented hourly bars.
    let modelDetailUnavailable: Bool

    init(
        buckets: [LensBucket],
        data: ShareCardData,
        dimension: BreakdownDimension = .sources,
        frozenRange: ClosedRange<Int>? = nil
    ) {
        let period = data.summary.period
        self.period = period
        if case .model = data.kind {
            self.modelDetailUnavailable = period == .day || (!buckets.isEmpty && buckets.allSatisfy { $0.byModel.isEmpty })
        } else {
            self.modelDetailUnavailable = false
        }

        let scoped: [LensBucket]
        let resolvedDimension: BreakdownDimension
        let sources: [String]
        let models: [String]

        switch data.kind {
        case .overall:
            scoped = buckets
            resolvedDimension = dimension
            sources = Self.resolvedOrder(
                primary: data.summary.bySource.map(\.id),
                buckets: scoped,
                dictionary: \.bySource
            )
            models = Self.resolvedOrder(
                primary: data.summary.byModel.map(\.id),
                buckets: scoped,
                dictionary: \.byModel
            )

        case .source(let id, _):
            scoped = buckets.map { bucket in
                let counts = bucket.isFuture ? .zero : (bucket.bySource[id] ?? .zero)
                return LensBucket(
                    id: bucket.id,
                    start: bucket.start,
                    end: bucket.end,
                    label: bucket.label,
                    counts: counts,
                    bySource: counts.total > 0 ? [id: counts] : [:],
                    byModel: [:],
                    byDevice: [:],
                    cost: nil,
                    isFuture: bucket.isFuture,
                    isKnown: bucket.isKnown,
                    reasoningKnown: bucket.reasoningKnown
                )
            }
            resolvedDimension = .sources
            sources = [id]
            models = []

        case .model(let id, _):
            scoped = buckets.map { bucket in
                let counts = bucket.isFuture ? .zero : (bucket.byModel[id] ?? .zero)
                return LensBucket(
                    id: bucket.id,
                    start: bucket.start,
                    end: bucket.end,
                    label: bucket.label,
                    counts: counts,
                    bySource: [:],
                    byModel: counts.total > 0 ? [id: counts] : [:],
                    byDevice: [:],
                    cost: nil,
                    isFuture: bucket.isFuture,
                    isKnown: bucket.isKnown,
                    reasoningKnown: bucket.reasoningKnown
                )
            }
            resolvedDimension = .models
            sources = []
            let summaryModels = data.summary.byModel.map(\.id)
            models = summaryModels.contains(id) ? summaryModels : (summaryModels + [id])
        }

        self.buckets = scoped
        self.dimension = resolvedDimension
        self.sourceOrder = sources
        self.modelOrder = models

        let resolvedRange: ClosedRange<Int>?
        if modelDetailUnavailable {
            resolvedRange = nil
        } else if let explicit = frozenRange, !scoped.isEmpty {
            let maxIdx = scoped.lastIndex(where: { !$0.isFuture }) ?? (scoped.count - 1)
            let lo = min(max(0, explicit.lowerBound), maxIdx)
            let hi = min(max(lo, explicit.upperBound), maxIdx)
            let sum = scoped[lo...hi].reduce(Int64(0)) { $0 + ($1.isFuture ? 0 : $1.total) }
            resolvedRange = sum > 0 ? (lo...hi) : nil
        } else if let peak = Self.peakNonFutureIndex(in: scoped) {
            resolvedRange = peak...peak
        } else {
            resolvedRange = nil
        }
        self.frozenRange = resolvedRange

        if let range = resolvedRange {
            self.frozenTotal = scoped[range].reduce(Int64(0)) { total, bucket in
                bucket.isFuture ? total : (total + bucket.total)
            }
        } else {
            self.frozenTotal = 0
        }
    }

    func frozenTimeText(locale: Locale) -> String? {
        guard let range = frozenRange, !buckets.isEmpty else { return nil }
        let lo = min(max(0, range.lowerBound), buckets.count - 1)
        let hi = min(max(lo, range.upperBound), buckets.count - 1)

        if lo == hi {
            return Self.singleBucketLabel(buckets[lo], period: period, locale: locale)
        }

        let start = buckets[lo].start
        let end = buckets[hi].end
        switch period {
        case .day:
            return "\(Self.hourMinute(start))–\(Self.hourMinute(end))"
        case .week, .month:
            let endInclusive = end.addingTimeInterval(-1)
            let startText = start.formatted(.dateTime.locale(locale).month(.abbreviated).day())
            let sameMonth = Calendar.current.isDate(start, equalTo: endInclusive, toGranularity: .month)
            let endText = sameMonth
                ? endInclusive.formatted(.dateTime.locale(locale).day())
                : endInclusive.formatted(.dateTime.locale(locale).month(.abbreviated).day())
            return "\(startText)–\(endText)"
        case .year, .all:
            let endInclusive = end.addingTimeInterval(-1)
            let startText = start.formatted(.dateTime.locale(locale).year().month(.abbreviated))
            let endText = endInclusive.formatted(.dateTime.locale(locale).year().month(.abbreviated))
            return "\(startText) – \(endText)"
        }
    }

    private static func peakNonFutureIndex(in buckets: [LensBucket]) -> Int? {
        var bestIndex: Int?
        var bestTotal: Int64 = 0
        for (index, bucket) in buckets.enumerated() where !bucket.isFuture && bucket.total > bestTotal {
            bestTotal = bucket.total
            bestIndex = index
        }
        return bestIndex
    }

    private static func resolvedOrder(
        primary: [String],
        buckets: [LensBucket],
        dictionary: KeyPath<LensBucket, [String: TokenCounts]>
    ) -> [String] {
        if !primary.isEmpty { return primary }
        var totals: [String: Int64] = [:]
        for bucket in buckets where !bucket.isFuture {
            for (id, counts) in bucket[keyPath: dictionary] {
                totals[id, default: 0] += counts.total
            }
        }
        return totals.sorted { $0.value > $1.value }.map(\.key)
    }

    private static func singleBucketLabel(_ bucket: LensBucket, period: Period, locale: Locale) -> String {
        switch period {
        case .day:
            return "\(hourMinute(bucket.start))–\(hourMinute(bucket.end))"
        case .week, .month:
            return bucket.start.formatted(
                .dateTime.locale(locale).month(.abbreviated).day().weekday(.abbreviated)
            )
        case .year, .all:
            return bucket.start.formatted(
                .dateTime.locale(locale).year().month(.abbreviated)
            )
        }
    }

    private static func hourMinute(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
    }
}

/// Pure-Canvas stacked time-bar chart with a hand-crafted frozen Liquid Glass lens for offscreen share export.
/// Avoids `glassEffect` so `ImageRenderer` rasterizes every optical layer deterministically.
struct LensShareGraphic: View {
    let snapshot: LensShareSnapshot

    init(snapshot: LensShareSnapshot) {
        self.snapshot = snapshot
    }

    init(
        buckets: [LensBucket],
        data: ShareCardData,
        dimension: BreakdownDimension = .sources,
        frozenRange: ClosedRange<Int>? = nil
    ) {
        self.snapshot = LensShareSnapshot(
            buckets: buckets,
            data: data,
            dimension: dimension,
            frozenRange: frozenRange
        )
    }

    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Canvas { context, size in
            // Hourly buckets carry no model detail, so drawing them would show empty bars and "No usage".
            guard !snapshot.modelDetailUnavailable else { return }
            draw(in: &context, size: size)
        }
        .overlay {
            if snapshot.modelDetailUnavailable {
                Text("Hourly collection has no model breakdown")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Palette.ink3)
                    .multilineTextAlignment(.center)
                    .padding(24)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Canvas Pipeline

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 8, size.height > 8 else { return }

        let isDark = scheme == .dark
        let increased = contrast == .increased

        // Scale logical coordinates so LensBarLayout's bar widths, bevels, and radii stay proportional
        // across 1080x1620, 1080x1080, and 1620x1080 share card canvases.
        let scale = min(max(min(size.width / 380, size.height / 205), 1.0), 2.30)
        let logicalSize = CGSize(width: size.width / scale, height: size.height / scale)
        context.scaleBy(x: scale, y: scale)

        let stageRect = CGRect(origin: .zero, size: logicalSize).insetBy(dx: 0.75, dy: 0.75)
        drawStageSurface(in: &context, rect: stageRect, isDark: isDark, increased: increased)

        let leftPad: CGFloat = 20
        let rightPad: CGFloat = 20
        let topPad: CGFloat = 42
        let bottomPad: CGFloat = 28
        let desiredPlotW = max(60, logicalSize.width - leftPad - rightPad)
        let desiredPlotH = max(40, logicalSize.height - topPad - bottomPad)

        // Reuse LensBarLayout's exact stacking, color ranking, ceiling, and X-tick selection while omitting
        // its left Y-axis gutter so bars span symmetrically across the full stage width.
        let internalLeft: CGFloat = 46
        let internalRight: CGFloat = LensBarLayout.bevelWidth + 4
        let internalTop: CGFloat = 22
        let internalBottom: CGFloat = 24
        let layoutInputSize = CGSize(
            width: desiredPlotW + internalLeft + internalRight,
            height: desiredPlotH + internalTop + internalBottom
        )
        let layout = LensBarLayout(
            buckets: snapshot.buckets,
            dimension: snapshot.dimension,
            period: snapshot.period,
            size: layoutInputSize,
            sourceOrder: snapshot.sourceOrder,
            modelOrder: snapshot.modelOrder
        )

        let shiftX = leftPad - layout.plotRect.minX
        let shiftY = topPad - layout.plotRect.minY
        let plotRect = layout.plotRect.offsetBy(dx: shiftX, dy: shiftY)

        let lensMetrics = snapshot.frozenRange.flatMap { range in
            resolveLensGeometry(
                for: range,
                layout: layout,
                shiftX: shiftX,
                plotRect: plotRect,
                stageRect: stageRect
            )
        }
        let showLens = lensMetrics != nil && !layout.isEmpty

        drawBasePass(
            in: &context,
            layout: layout,
            plotRect: plotRect,
            shiftX: shiftX,
            logicalSize: logicalSize,
            activeRange: showLens ? snapshot.frozenRange : nil,
            lensRect: lensMetrics?.rect,
            lensCornerRadius: lensMetrics?.cornerRadius ?? 0,
            isDark: isDark,
            increased: increased
        )

        if let metrics = lensMetrics, let range = snapshot.frozenRange, !layout.isEmpty {
            drawMagnifiedLensPass(
                in: &context,
                layout: layout,
                plotRect: plotRect,
                shiftX: shiftX,
                stageRect: stageRect,
                range: range,
                lensRect: metrics.rect,
                lensCornerRadius: metrics.cornerRadius,
                isDark: isDark,
                increased: increased
            )
        }

        if layout.isEmpty {
            let emptyText = String(localized: "No usage in this period", locale: locale)
            let resolved = context.resolve(
                Text(verbatim: emptyText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink3)
            )
            context.draw(resolved, at: CGPoint(x: plotRect.midX, y: plotRect.midY), anchor: .center)
        } else if layout.isDayModelDegraded {
            drawDegradedNotice(
                in: &context,
                stageRect: stageRect,
                lensCenterX: lensMetrics?.rect.midX,
                isDark: isDark
            )
        }
    }

    private struct ResolvedLensGeometry {
        let rect: CGRect
        let cornerRadius: CGFloat
    }

    private func resolveLensGeometry(
        for range: ClosedRange<Int>,
        layout: LensBarLayout,
        shiftX: CGFloat,
        plotRect: CGRect,
        stageRect: CGRect
    ) -> ResolvedLensGeometry? {
        guard !layout.bars.isEmpty else { return nil }
        let s0 = min(max(0, range.lowerBound), layout.bars.count - 1)
        let s1 = min(max(s0, range.upperBound), layout.bars.count - 1)
        let isRange = s1 > s0
        let baseBarW = layout.bars[s0].baseBarWidth
        let bevel = LensBarLayout.bevelWidth

        let rawCx: CGFloat
        let width: CGFloat
        if isRange {
            let leftEdge = (layout.bars[s0].slotCenterX + shiftX) - baseBarW * 0.5 - bevel
            let rightEdge = (layout.bars[s1].slotCenterX + shiftX) + baseBarW * 0.5 + bevel
            width = min(stageRect.width - 12, max(40, rightEdge - leftEdge))
            rawCx = (leftEdge + rightEdge) * 0.5
        } else {
            rawCx = layout.bars[s0].slotCenterX + shiftX
            let magBarW = min(layout.slotWidth * 0.92, baseBarW * LensBarLayout.singleMagnification)
            width = min(stageRect.width - 12, max(56, magBarW + bevel * 2))
        }

        let halfW = width * 0.5
        let minCx = stageRect.minX + halfW + 6
        let maxCx = stageRect.maxX - halfW - 6
        let clampedCx = minCx <= maxCx ? min(max(rawCx, minCx), maxCx) : stageRect.midX

        let lensTop = plotRect.minY - 8
        let lensBottom = plotRect.maxY + 6
        let height = max(32, lensBottom - lensTop)
        let rect = CGRect(x: clampedCx - halfW, y: lensTop, width: width, height: height)
        let radius = isRange
            ? min(width * 0.5, height * 0.5, 18)
            : min(width * 0.5, height * 0.5, 26)
        return ResolvedLensGeometry(rect: rect, cornerRadius: radius)
    }

    // MARK: - Stage Surface

    private func drawStageSurface(
        in context: inout GraphicsContext,
        rect: CGRect,
        isDark: Bool,
        increased: Bool
    ) {
        let shape = Path(roundedRect: rect, cornerRadius: 18, style: .continuous)

        if reduceTransparency {
            context.fill(shape, with: .color(Palette.cardSurface))
            context.stroke(shape, with: .color(Palette.hairline), lineWidth: 1)
            return
        }

        context.fill(
            shape,
            with: .linearGradient(
                Gradient(colors: isDark
                    ? [Color.white.opacity(0.068), Color(hex: "#0E1522").opacity(0.46)]
                    : [Color.white.opacity(0.66), Color(hex: "#EFF4FC").opacity(0.48)]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.maxY)
            )
        )

        context.drawLayer { layer in
            layer.clip(to: shape)
            let sheen = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 22)
            layer.fill(
                Path(sheen),
                with: .linearGradient(
                    Gradient(colors: [Color.white.opacity(isDark ? 0.08 : 0.44), .clear]),
                    startPoint: CGPoint(x: rect.midX, y: sheen.minY),
                    endPoint: CGPoint(x: rect.midX, y: sheen.maxY)
                )
            )
        }

        context.stroke(
            shape,
            with: .color(isDark
                ? Color.white.opacity(increased ? 0.24 : 0.12)
                : Color.white.opacity(0.82)),
            lineWidth: 1.0
        )
        context.stroke(
            shape,
            with: .color(Palette.hairline),
            lineWidth: increased ? 1.0 : 0.55
        )
    }

    // MARK: - Pass 1: Gridlines, X-Axis & Dimmed Base Bars

    private func drawBasePass(
        in context: inout GraphicsContext,
        layout: LensBarLayout,
        plotRect: CGRect,
        shiftX: CGFloat,
        logicalSize: CGSize,
        activeRange: ClosedRange<Int>?,
        lensRect: CGRect?,
        lensCornerRadius: CGFloat,
        isDark: Bool,
        increased: Bool
    ) {
        let gridColor = isDark
            ? Color.white.opacity(increased ? 0.16 : 0.066)
            : Color(hex: "#0F172A").opacity(increased ? 0.15 : 0.062)
        let baselineColor = isDark
            ? Color.white.opacity(increased ? 0.20 : 0.095)
            : Color(hex: "#0F172A").opacity(increased ? 0.18 : 0.088)
        let steps = 4

        for s in 0...steps {
            let y = (plotRect.maxY - (plotRect.height * CGFloat(s)) / CGFloat(steps)).rounded() + 0.5
            var line = Path()
            line.move(to: CGPoint(x: plotRect.minX, y: y))
            line.addLine(to: CGPoint(x: plotRect.maxX, y: y))
            context.stroke(
                line,
                with: .color(s == 0 ? baselineColor : gridColor),
                lineWidth: increased ? 1.2 : 1.0
            )
        }

        for tick in layout.xTicks {
            let isHighlighted = activeRange?.contains(tick.index) == true
            let resolved = context.resolve(
                Text(verbatim: tick.label)
                    .font(.system(size: 10.5, weight: isHighlighted ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isHighlighted ? Palette.ink1 : Palette.ink3)
            )
            context.draw(
                resolved,
                at: CGPoint(x: tick.centerX + shiftX, y: plotRect.maxY + 8.5),
                anchor: .top
            )
        }

        guard !layout.bars.isEmpty else { return }

        // Inverse-clip out the lens interior so dimmed base bars never bleed behind magnified bars.
        context.drawLayer { layer in
            if let lensRect {
                var inverse = Path(CGRect(origin: .zero, size: logicalSize))
                inverse.addPath(Path(roundedRect: lensRect, cornerRadius: lensCornerRadius, style: .continuous))
                layer.clip(to: inverse, style: FillStyle(eoFill: true))
            }

            let baseOpacity = increased ? 0.52 : (isDark ? 0.28 : 0.34)
            for bar in layout.bars {
                drawBucketBar(
                    in: &layer,
                    bar: bar,
                    plotRect: plotRect,
                    yMax: layout.yMax,
                    centerX: bar.slotCenterX + shiftX,
                    barWidth: bar.baseBarWidth,
                    verticalScale: 1.0,
                    opacity: baseOpacity,
                    isHighlighted: false,
                    isDark: isDark
                )
            }
        }
    }

    // MARK: - Pass 2: Hand-Drawn Glass Lens, Magnified Bars & Sum Pill

    private func drawMagnifiedLensPass(
        in context: inout GraphicsContext,
        layout: LensBarLayout,
        plotRect: CGRect,
        shiftX: CGFloat,
        stageRect: CGRect,
        range: ClosedRange<Int>,
        lensRect: CGRect,
        lensCornerRadius: CGFloat,
        isDark: Bool,
        increased: Bool
    ) {
        let isRange = range.count >= 2
        let lensPath = Path(roundedRect: lensRect, cornerRadius: lensCornerRadius, style: .continuous)
        let lensCx = lensRect.midX
        let lensHalfW = lensRect.width * 0.5

        // 1. Hand-drawn glass capsule body & ambient shadow (replaces offscreen-unsupported glassEffect).
        if reduceTransparency {
            context.fill(lensPath, with: .color(Palette.cardSurface))
        } else {
            context.drawLayer { shadowLayer in
                shadowLayer.addFilter(.shadow(
                    color: isDark ? .black.opacity(0.52) : Color(hex: "#16264C").opacity(0.16),
                    radius: 11,
                    x: 0,
                    y: 4.5
                ))
                shadowLayer.fill(
                    lensPath,
                    with: .color(isDark
                        ? Color(hex: "#1A2436").opacity(0.88)
                        : Color(hex: "#FAFDFE").opacity(0.88))
                )
            }
        }

        // 2. Clipped interior: refraction tint, curved grid, magnified bars, bevels & specular sheen.
        context.drawLayer { mag in
            mag.clip(to: lensPath)

            if !reduceTransparency {
                mag.fill(
                    Path(lensRect),
                    with: .linearGradient(
                        Gradient(colors: isDark
                            ? [Color(hex: "#3A4C70").opacity(0.24), Color(hex: "#121826").opacity(0.32)]
                            : [Color.white.opacity(0.72), Color(hex: "#EBF2FF").opacity(0.42)]),
                        startPoint: CGPoint(x: lensCx, y: lensRect.minY),
                        endPoint: CGPoint(x: lensCx, y: lensRect.maxY)
                    )
                )
            }

            let gridMag = isRange ? LensBarLayout.rangeMagnification : LensBarLayout.singleMagnification
            let gridColor = isDark ? Color.white.opacity(0.095) : Color(hex: "#0F172A").opacity(0.075)
            for s in 0...4 {
                let gy = plotRect.maxY - ((plotRect.height * CGFloat(s)) / 4.0) * gridMag
                guard gy >= lensRect.minY - 4 else { continue }
                var curve = Path()
                curve.move(to: CGPoint(x: lensRect.minX - 4, y: gy))
                curve.addQuadCurve(
                    to: CGPoint(x: lensRect.maxX + 4, y: gy),
                    control: CGPoint(x: lensCx, y: gy + (s == 0 ? 0 : -1.2))
                )
                mag.stroke(curve, with: .color(gridColor), lineWidth: 1)
            }

            for bar in layout.bars {
                let slotCenterX = bar.slotCenterX + shiftX
                let dist = slotCenterX - lensCx
                let inRange = range.contains(bar.index)

                let drawCenter: CGFloat
                let barWidth: CGFloat
                let vScale: CGFloat

                if !isRange {
                    // Single-bucket: 1.35x bottom-anchored radial magnification.
                    if abs(dist) > lensHalfW + layout.slotWidth * 0.85 { continue }
                    let u = min(1, abs(dist) / max(1, lensHalfW))
                    let radial = cos(u * .pi * 0.5)
                    if inRange {
                        vScale = LensBarLayout.singleMagnification
                        drawCenter = lensCx + dist * LensBarLayout.singleMagnification
                        barWidth = min(layout.slotWidth * 0.92, bar.baseBarWidth * LensBarLayout.singleMagnification)
                    } else {
                        vScale = 1 + (LensBarLayout.singleMagnification - 1) * radial * 0.52
                        drawCenter = lensCx + dist * (1 + 0.22 * radial)
                        barWidth = bar.baseBarWidth * (1 + 0.14 * radial)
                    }
                } else {
                    // Range (>= 2 buckets): 1.2x vertical lift only, zero horizontal stretch, ~14pt side bevels.
                    if inRange {
                        vScale = LensBarLayout.rangeMagnification
                        drawCenter = slotCenterX
                        barWidth = bar.baseBarWidth
                    } else {
                        if abs(dist) > lensHalfW + bar.baseBarWidth * 0.5 { continue }
                        vScale = 1.04
                        drawCenter = slotCenterX + (dist >= 0 ? 2.0 : -2.0)
                        barWidth = bar.baseBarWidth * 0.95
                    }
                }

                drawBucketBar(
                    in: &mag,
                    bar: bar,
                    plotRect: plotRect,
                    yMax: layout.yMax,
                    centerX: drawCenter,
                    barWidth: barWidth,
                    verticalScale: vScale,
                    opacity: inRange ? 0.96 : 0.44,
                    isHighlighted: inRange,
                    isDark: isDark
                )
            }

            if !reduceTransparency {
                if isRange {
                    let bevel = LensBarLayout.bevelWidth
                    let rimColor = Color.white.opacity(isDark ? 0.16 : 0.70)
                    let leftBand = CGRect(x: lensRect.minX, y: lensRect.minY, width: bevel, height: lensRect.height)
                    mag.fill(
                        Path(leftBand),
                        with: .linearGradient(
                            Gradient(colors: [rimColor, .clear]),
                            startPoint: CGPoint(x: leftBand.minX, y: leftBand.midY),
                            endPoint: CGPoint(x: leftBand.maxX, y: leftBand.midY)
                        )
                    )
                    let rightBand = CGRect(x: lensRect.maxX - bevel, y: lensRect.minY, width: bevel, height: lensRect.height)
                    mag.fill(
                        Path(rightBand),
                        with: .linearGradient(
                            Gradient(colors: [.clear, rimColor]),
                            startPoint: CGPoint(x: rightBand.minX, y: rightBand.midY),
                            endPoint: CGPoint(x: rightBand.maxX, y: rightBand.midY)
                        )
                    )
                } else {
                    let maxDim = max(lensRect.width, lensRect.height)
                    mag.fill(
                        Path(lensRect),
                        with: .radialGradient(
                            Gradient(colors: [.clear, Color.white.opacity(isDark ? 0.14 : 0.58)]),
                            center: CGPoint(x: lensCx, y: lensRect.midY),
                            startRadius: min(lensRect.width, lensRect.height) * 0.28,
                            endRadius: maxDim * 0.68
                        )
                    )
                }

                let sheenRect = CGRect(x: lensRect.minX, y: lensRect.minY, width: lensRect.width, height: 24)
                mag.fill(
                    Path(sheenRect),
                    with: .linearGradient(
                        Gradient(colors: [Color.white.opacity(isDark ? 0.25 : 0.78), .clear]),
                        startPoint: CGPoint(x: lensCx, y: sheenRect.minY),
                        endPoint: CGPoint(x: lensCx, y: sheenRect.maxY)
                    )
                )
            }
        }

        // 3. Hand-drawn glass capsule rim: subtle red/cyan chromatic dispersion, fine border & top highlight.
        if reduceTransparency {
            context.stroke(lensPath, with: .color(Palette.roleAccent), lineWidth: 2)
        } else {
            context.stroke(
                lensPath.offsetBy(dx: 1.0, dy: 0),
                with: .color(Color(.sRGB, red: 1.0, green: 0.36, blue: 0.55, opacity: isDark ? 0.25 : 0.20)),
                lineWidth: 1.0
            )
            context.stroke(
                lensPath.offsetBy(dx: -1.0, dy: 0),
                with: .color(Color(.sRGB, red: 0.30, green: 0.65, blue: 1.0, opacity: isDark ? 0.27 : 0.22)),
                lineWidth: 1.0
            )
            context.stroke(
                lensPath,
                with: .color(isDark ? Color.white.opacity(0.36) : Color.white.opacity(0.95)),
                lineWidth: increased ? 1.6 : 1.25
            )
            context.stroke(
                lensPath,
                with: .color(Palette.roleAccent.opacity(isDark ? 0.44 : 0.28)),
                lineWidth: 0.9
            )

            // Crisp specular highlight crest along the top arc of the capsule.
            context.drawLayer { crest in
                let topClip = CGRect(
                    x: lensRect.minX - 2,
                    y: lensRect.minY - 2,
                    width: lensRect.width + 4,
                    height: min(16, lensCornerRadius * 0.75 + 4)
                )
                crest.clip(to: Path(topClip))
                crest.stroke(
                    lensPath,
                    with: .color(Color.white.opacity(isDark ? 0.62 : 0.98)),
                    lineWidth: 1.4
                )
            }
        }

        // 4. Single total capsule centered above the frozen lens.
        if snapshot.frozenTotal > 0 {
            drawSumPill(
                in: &context,
                total: snapshot.frozenTotal,
                isRange: isRange,
                lensRect: lensRect,
                stageRect: stageRect,
                isDark: isDark
            )
        }
    }

    private func drawSumPill(
        in context: inout GraphicsContext,
        total: Int64,
        isRange: Bool,
        lensRect: CGRect,
        stageRect: CGRect,
        isDark: Bool
    ) {
        let formatted = TokenFormat.short(total)
        let pillString = isRange && lensRect.width >= 88
            ? String(localized: "Total \(formatted)", locale: locale)
            : formatted
        let resolved = context.resolve(
            Text(verbatim: pillString)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.ink1)
        )
        let textSize = resolved.measure(in: CGSize(width: 240, height: 26))
        let pillW = textSize.width + 14
        let pillH: CGFloat = 19
        let minCx = stageRect.minX + pillW * 0.5 + 8
        let maxCx = stageRect.maxX - pillW * 0.5 - 8
        let clampedX = minCx <= maxCx ? min(max(lensRect.midX, minCx), maxCx) : stageRect.midX
        let pillTop = max(stageRect.minY + 5, lensRect.minY - pillH - 6)
        let pillRect = CGRect(x: clampedX - pillW * 0.5, y: pillTop, width: pillW, height: pillH)
        let pillPath = Path(roundedRect: pillRect, cornerRadius: pillH * 0.5, style: .continuous)

        if reduceTransparency {
            context.fill(pillPath, with: .color(Palette.cardSurface))
            context.stroke(pillPath, with: .color(Palette.roleAccent), lineWidth: 1.2)
        } else {
            context.drawLayer { shadowLayer in
                shadowLayer.addFilter(.shadow(
                    color: isDark ? .black.opacity(0.38) : Color(hex: "#0F172A").opacity(0.10),
                    radius: 4,
                    x: 0,
                    y: 1.5
                ))
                shadowLayer.fill(
                    pillPath,
                    with: .color(isDark
                        ? Color(hex: "#192334").opacity(0.95)
                        : Color.white.opacity(0.96))
                )
            }
            context.stroke(
                pillPath,
                with: .color(Palette.roleAccent.opacity(isDark ? 0.52 : 0.36)),
                lineWidth: 1.0
            )
        }

        context.draw(resolved, at: CGPoint(x: clampedX, y: pillRect.midY), anchor: .center)
    }

    private func drawDegradedNotice(
        in context: inout GraphicsContext,
        stageRect: CGRect,
        lensCenterX: CGFloat?,
        isDark: Bool
    ) {
        let notice = String(localized: "Hourly collection has no model breakdown", locale: locale)
        let resolved = context.resolve(
            Text(verbatim: notice)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Palette.ink2)
        )
        let textSize = resolved.measure(in: CGSize(width: stageRect.width - 32, height: 22))
        let badgeW = textSize.width + 14
        let badgeH: CGFloat = 17
        let placeTrailing = (lensCenterX ?? stageRect.midX) < stageRect.midX
        let badgeX = placeTrailing
            ? max(stageRect.minX + 10, stageRect.maxX - badgeW - 10)
            : (stageRect.minX + 10)
        let badgeRect = CGRect(x: badgeX, y: stageRect.minY + 7, width: badgeW, height: badgeH)
        let badgePath = Path(roundedRect: badgeRect, cornerRadius: badgeH * 0.5, style: .continuous)

        context.fill(
            badgePath,
            with: .color(reduceTransparency
                ? Palette.cardSurface
                : (isDark ? Color(hex: "#182130").opacity(0.86) : Color.white.opacity(0.84)))
        )
        context.stroke(badgePath, with: .color(Palette.hairline), lineWidth: 0.7)
        context.draw(resolved, at: CGPoint(x: badgeRect.midX, y: badgeRect.midY), anchor: .center)
    }

    // MARK: - Bar & Hatched Gap Primitives

    @discardableResult
    private func drawBucketBar(
        in context: inout GraphicsContext,
        bar: LensBarLayout.BucketBar,
        plotRect: CGRect,
        yMax: Double,
        centerX: CGFloat,
        barWidth: CGFloat,
        verticalScale: CGFloat,
        opacity: Double,
        isHighlighted: Bool,
        isDark: Bool
    ) -> CGFloat {
        let bottomY = plotRect.maxY
        let x = centerX - barWidth * 0.5

        if bar.isFuture {
            let grooveRect = CGRect(x: x, y: bottomY - 2.5, width: barWidth, height: 2.5)
            context.fill(
                Path(roundedRect: grooveRect, cornerRadius: 1.25, style: .continuous),
                with: .color(isDark ? Color.white.opacity(0.13) : Color(hex: "#0F172A").opacity(0.11))
            )
            return bottomY
        }

        if !bar.isKnown && bar.total <= 0 {
            let slotH: CGFloat = min(14, max(9, plotRect.height * 0.11)) * min(verticalScale, 1.2)
            let slotRect = CGRect(x: x, y: bottomY - slotH, width: barWidth, height: slotH)
            drawHatchedPlaceholder(in: &context, rect: slotRect, isDark: isDark, isHighlighted: isHighlighted)
            return slotRect.minY
        }

        if bar.total <= 0 || bar.segments.isEmpty {
            let zeroRect = CGRect(x: x, y: bottomY - 1.5, width: barWidth, height: 1.5)
            context.fill(
                Path(roundedRect: zeroRect, cornerRadius: 0.75),
                with: .color(Palette.ink3.opacity(isHighlighted ? 0.55 : 0.30))
            )
            return bottomY
        }

        var currentY = bottomY
        let validSegments = bar.segments.filter { $0.tokens > 0 }
        for (segIdx, segment) in validSegments.enumerated() {
            let rawH = (CGFloat(segment.tokens) / CGFloat(max(1, yMax))) * plotRect.height * verticalScale
            guard rawH > 0.35 else { continue }
            let nextY = max(plotRect.minY - 4, currentY - rawH)
            let segH = currentY - nextY
            guard segH > 0.25 else { continue }

            let isTop = segIdx == validSegments.count - 1 && bar.isKnown
            let drawH = max(0.6, segH - (isHighlighted ? 0.6 : 0.3))
            let segRect = CGRect(x: x, y: nextY, width: barWidth, height: drawH)
            let topR = min(5, barWidth * 0.5)
            let path = isTop
                ? Path(
                    roundedRect: segRect,
                    cornerRadii: RectangleCornerRadii(
                        topLeading: topR,
                        bottomLeading: 0,
                        bottomTrailing: 0,
                        topTrailing: topR
                    ),
                    style: .continuous
                )
                : Path(segRect)

            context.fill(path, with: .color(segment.color.opacity(opacity)))

            if isHighlighted && isTop {
                let capRect = CGRect(x: x + 0.5, y: nextY, width: max(0, barWidth - 1), height: 1.2)
                context.fill(
                    Path(roundedRect: capRect, cornerRadius: 0.6),
                    with: .color(Color.white.opacity(isDark ? 0.28 : 0.55))
                )
            }

            currentY = nextY
        }

        if !bar.isKnown {
            let capH: CGFloat = 5
            let capRect = CGRect(x: x, y: max(plotRect.minY, currentY - capH - 1), width: barWidth, height: capH)
            drawHatchedPlaceholder(in: &context, rect: capRect, isDark: isDark, isHighlighted: isHighlighted)
            currentY = capRect.minY
        }

        return currentY
    }

    private func drawHatchedPlaceholder(
        in context: inout GraphicsContext,
        rect: CGRect,
        isDark: Bool,
        isHighlighted: Bool
    ) {
        let shape = Path(roundedRect: rect, cornerRadius: min(3, rect.width * 0.4), style: .continuous)
        let strokeAlpha = isHighlighted ? 0.52 : (isDark ? 0.28 : 0.26)
        let strokeColor = Palette.ink3.opacity(strokeAlpha)

        context.drawLayer { layer in
            layer.clip(to: shape)
            layer.fill(shape, with: .color(Palette.barTrack.opacity(isHighlighted ? 0.9 : 0.6)))

            var hatch = Path()
            let step: CGFloat = 4.5
            var xCursor = rect.minX - rect.height
            while xCursor < rect.maxX + rect.height {
                hatch.move(to: CGPoint(x: xCursor, y: rect.maxY))
                hatch.addLine(to: CGPoint(x: xCursor + rect.height, y: rect.minY))
                xCursor += step
            }
            layer.stroke(hatch, with: .color(strokeColor), lineWidth: 1)
        }

        context.stroke(
            shape,
            with: .color(strokeColor),
            style: StrokeStyle(lineWidth: 0.9, dash: [2.5, 2.0])
        )
    }
}
