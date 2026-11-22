import AppKit
import SwiftUI
import TokenTakenKit

/// Liquid Glass Lens view: a fixed-height three-column glass readout card above a dual-pass Canvas
/// stacked time-bar chart with an interactive Liquid Glass magnifier.
struct LensView: View {
    let buckets: [LensBucket]
    let dimension: BreakdownDimension
    let period: Period
    var slice: ((ClosedRange<Int>) -> LensSlice)? = nil

    init(
        buckets: [LensBucket],
        dimension: BreakdownDimension = .sources,
        period: Period,
        slice: ((ClosedRange<Int>) -> LensSlice)? = nil
    ) {
        self.buckets = buckets
        self.dimension = dimension
        self.period = period
        self.slice = slice
    }

    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.controlActiveState) private var controlActiveState

    // Selection state
    @State private var pinnedAnchor: Int?
    @State private var pinnedHead: Int?
    @State private var hoverBucket: Int?
    @State private var hoverPoint: CGPoint?
    @State private var releasedUntilMove = false
    @State private var releaseOrigin: CGPoint?

    // Drag & double-click tracking
    private enum DragMode: Equatable {
        case brush(startBucket: Int)
        case resizeLeft(fixedUpper: Int)
        case resizeRight(fixedLower: Int)
        case moveRange(initialRange: ClosedRange<Int>)
    }

    @State private var dragMode: DragMode?
    @State private var didDrag = false
    @State private var lastClickTime: TimeInterval = 0
    @State private var lastClickPoint: CGPoint = .zero

    // Spring & mercury-stretch physics (driven by TimelineView only while moving)
    @State private var lensX: CGFloat = 0
    @State private var lensWidth: CGFloat = 64
    @State private var velX: CGFloat = 0
    @State private var velW: CGFloat = 0
    @State private var mercuryStretch: CGFloat = 0
    @State private var lensInitialized = false
    @State private var isSettling = false
    @State private var lastStepDate: Date?
    @State private var windowVisible = true
    @State private var layoutCache = LensBarLayoutCache()
    @State private var sliceCache = LensSliceCache()

    @FocusState private var isChartFocused: Bool

    private static let readoutHeight: CGFloat = 104
    private static let readoutHeightWithUncategorized: CGFloat = 122

    private var canAnimate: Bool {
        appearsActive && controlActiveState == .key && windowVisible && !reduceMotion
    }

    private var pinnedRange: ClosedRange<Int>? {
        guard let anchor = pinnedAnchor, let head = pinnedHead, !buckets.isEmpty else { return nil }
        let maxIdx = maxNonFutureIndex ?? (buckets.count - 1)
        let lo = min(max(0, min(anchor, head)), maxIdx)
        let hi = min(max(lo, max(anchor, head)), maxIdx)
        return lo...hi
    }

    private var maxNonFutureIndex: Int? {
        buckets.lastIndex(where: { !$0.isFuture })
    }

    private var peakNonFutureIndex: Int? {
        guard let maxIdx = maxNonFutureIndex else { return nil }
        var best = 0
        var bestTotal: Int64 = -1
        for idx in 0...maxIdx where !buckets[idx].isFuture {
            if buckets[idx].total > bestTotal {
                bestTotal = buckets[idx].total
                best = idx
            }
        }
        return best
    }

    /// Active slice range shown in the readout card (`nil` when unpinned and not hovering -> whole period).
    private var activeSliceRange: ClosedRange<Int>? {
        if let pinnedRange {
            return pinnedRange
        }
        if let hoverBucket, !releasedUntilMove, !buckets.isEmpty {
            let clamped = clampToNonFuture(hoverBucket)
            return clamped...clamped
        }
        return nil
    }

    /// Range where the visual lens sits (falls back to peak non-future bucket at rest when period has usage).
    private var visualLensRange: ClosedRange<Int>? {
        if let activeSliceRange {
            return activeSliceRange
        }
        guard !releasedUntilMove,
              model.summary.total.total > 0 || buckets.contains(where: { !$0.isFuture && $0.total > 0 }),
              let peak = peakNonFutureIndex
        else {
            return nil
        }
        return peak...peak
    }

    private func resolveSlice(_ range: ClosedRange<Int>) -> LensSlice {
        if let slice {
            return slice(range)
        }
        return sliceCache.slice(
            for: range,
            period: period,
            buckets: buckets,
            devices: model.summary.devices,
            compute: { model.lensSlice($0) }
        )
    }

    var body: some View {
        let activeSlice = activeSliceRange.map(resolveSlice)
        let hasUncategorized = model.summary.total.uncategorized > 0
            || (activeSlice?.counts.uncategorized ?? 0) > 0
        let cardHeight = hasUncategorized ? Self.readoutHeightWithUncategorized : Self.readoutHeight

        VStack(alignment: .leading, spacing: 10) {
            LensReadoutCard(
                summary: model.summary,
                period: period,
                dimension: dimension,
                buckets: buckets,
                activeSlice: activeSlice,
                isPinned: pinnedRange != nil,
                increasedContrast: contrast == .increased,
                onRelease: { releasePin() }
            )
            .frame(height: cardHeight)

            timeBarStage
                .frame(maxWidth: .infinity, minHeight: 110, maxHeight: .infinity)
        }
        .background {
            WindowVisibilityProbe { visible in
                windowVisible = visible
            }
        }
        .onChange(of: period) { _, _ in
            releasePin(snapImmediately: true)
        }
        .onChange(of: buckets.count) { _, newCount in
            if newCount == 0 {
                releasePin(snapImmediately: true)
            } else if let anchor = pinnedAnchor, let head = pinnedHead {
                let maxIdx = maxNonFutureIndex ?? (newCount - 1)
                pinnedAnchor = min(max(0, anchor), maxIdx)
                pinnedHead = min(max(0, head), maxIdx)
            }
        }
        .onChange(of: canAnimate) { _, active in
            if !active && isSettling {
                velX = 0
                velW = 0
                mercuryStretch = 0
                lastStepDate = nil
                isSettling = false
            }
        }
        .onExitCommand {
            if pinnedRange != nil {
                releasePin()
            }
        }
    }

    // MARK: - Time Bar Stage

    private var timeBarStage: some View {
        GeometryReader { proxy in
            let layout = layoutCache.layout(
                buckets: buckets,
                dimension: dimension,
                period: period,
                size: proxy.size,
                summarySources: model.summary.bySource,
                summaryModels: model.summary.byModel
            )
            let lensRange = visualLensRange
            let targetFrame = lensRange.map { targetLensMetrics(for: $0, in: layout) }
            let resolvedX = lensInitialized && canAnimate ? lensX : (targetFrame?.centerX ?? layout.plotRect.midX)
            let resolvedW = lensInitialized && canAnimate ? lensWidth : (targetFrame?.width ?? 64)
            let stretch = canAnimate ? mercuryStretch : 0
            let scaleX = 1 + stretch
            let scaleY = 1 - stretch * 0.42
            let lensHeight = max(36, layout.plotRect.height + 14)
            let effectiveW = max(36, resolvedW * scaleX)
            let effectiveH = max(32, lensHeight * scaleY)
            let lensCenterY = layout.plotRect.midY - 1
            let lensRect = CGRect(
                x: resolvedX - effectiveW * 0.5,
                y: lensCenterY - effectiveH * 0.5,
                width: effectiveW,
                height: effectiveH
            )
            let isRange = (lensRange?.count ?? 0) >= 2
            let lensCornerRadius = isRange
                ? min(effectiveW * 0.5, effectiveH * 0.5, 18)
                : min(effectiveW * 0.5, effectiveH * 0.5, 26)
            let lensShape = RoundedRectangle(cornerRadius: lensCornerRadius, style: .continuous)
            let showLens = lensRange != nil && !buckets.isEmpty

            ZStack(alignment: .topLeading) {
                // Pass 1: Axes + unmagnified low-opacity base bars (clipped out under the lens).
                Canvas { context, _ in
                    drawBasePass(
                        in: &context,
                        layout: layout,
                        activeRange: activeSliceRange,
                        lensRect: showLens ? lensRect : nil,
                        lensCornerRadius: lensCornerRadius
                    )
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                // Native Liquid Glass lens capsule (or opaque surface under Reduce Transparency).
                if showLens {
                    Group {
                        if reduceTransparency {
                            lensShape
                                .fill(Palette.cardSurface)
                        } else {
                            Color.clear
                                .glassEffect(.clear.interactive(), in: lensShape)
                        }
                    }
                    .frame(width: lensRect.width, height: lensRect.height)
                    .offset(x: lensRect.minX, y: lensRect.minY)
                    .opacity(activeSliceRange == nil ? 0.92 : 1.0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }

                // Pass 2: Magnified vector bars clipped inside the lens + refraction bevels, handles, and range sum.
                if showLens, let lensRange {
                    Canvas { context, _ in
                        drawMagnifiedPass(
                            in: &context,
                            layout: layout,
                            range: lensRange,
                            lensRect: lensRect,
                            lensCornerRadius: lensCornerRadius,
                            isPinned: pinnedRange != nil,
                            isResting: activeSliceRange == nil
                        )
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }

                // Day + Models degradation notice.
                if layout.isDayModelDegraded && !layout.isEmpty {
                    dayModelDegradedBanner
                        .padding(.leading, layout.plotRect.minX + 6)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }

                // Empty-period message when buckets exist or are empty with zero usage.
                if layout.isEmpty {
                    Text("No usage in this period")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink3)
                        .position(x: layout.plotRect.midX, y: layout.plotRect.midY)
                        .allowsHitTesting(false)
                }

                // Per-bucket accessibility elements for VoiceOver.
                bucketAccessibilityOverlay(layout: layout)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .overlay {
                if isChartFocused {
                    RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                        .strokeBorder(Palette.roleAccent.opacity(0.65), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .background {
                // Mount TimelineView ONLY while the mercury stretch / spring is actively settling.
                if isSettling && canAnimate {
                    TimelineView(.animation(minimumInterval: 1.0 / 120.0)) { timeline in
                        Color.clear
                            .frame(width: 0, height: 0)
                            .onChange(of: timeline.date) { _, newDate in
                                stepSpring(at: newDate, target: targetFrame)
                            }
                    }
                }
            }
            .onAppear {
                if let targetFrame {
                    lensX = targetFrame.centerX
                    lensWidth = targetFrame.width
                    lensInitialized = true
                }
            }
            .onChange(of: canAnimate) { _, active in
                // Stopping mid-settle must not leave the lens at an intermediate frame.
                if !active, let targetFrame {
                    lensX = targetFrame.centerX
                    lensWidth = targetFrame.width
                }
            }
            .onChange(of: targetFrame) { _, newTarget in
                guard let newTarget else {
                    isSettling = false
                    mercuryStretch = 0
                    return
                }
                if !lensInitialized || !canAnimate {
                    lensX = newTarget.centerX
                    lensWidth = newTarget.width
                    velX = 0
                    velW = 0
                    mercuryStretch = 0
                    lensInitialized = true
                    isSettling = false
                } else {
                    let dx = abs(newTarget.centerX - lensX)
                    let dw = abs(newTarget.width - lensWidth)
                    if dx > 0.2 || dw > 0.2 {
                        if !isSettling {
                            lastStepDate = nil
                            isSettling = true
                        }
                    }
                }
            }
            .onContinuousHover { phase in
                guard dragMode == nil else { return }
                switch phase {
                case .active(let point):
                    hoverPoint = point
                    if releasedUntilMove, let origin = releaseOrigin {
                        if hypot(point.x - origin.x, point.y - origin.y) > 5 {
                            releasedUntilMove = false
                        }
                    }
                    if pinnedRange == nil && !releasedUntilMove && !buckets.isEmpty {
                        hoverBucket = clampToNonFuture(layout.bucketIndex(atX: point.x))
                    }
                case .ended:
                    hoverPoint = nil
                    hoverBucket = nil
                    releasedUntilMove = false
                }
            }
            .gesture(chartDragGesture(layout: layout, currentLensRect: showLens ? lensRect : nil))
            .focusable(interactions: .activate)
            .focused($isChartFocused)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .return, .space, .escape], phases: [.down, .repeat]) { press in
                handleKeyPress(press)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Usage timeline"))
    }

    private var dayModelDegradedBanner: some View {
        HStack(spacing: 5) {
            Image(systemName: "info.circle")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.ink3)
                .accessibilityHidden(true)
            Text("Hourly collection has no model breakdown")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background {
            Capsule()
                .fill(Palette.cardSurface.opacity(reduceTransparency ? 1 : 0.78))
                .overlay {
                    Capsule().strokeBorder(Palette.hairline, lineWidth: 0.5)
                }
        }
    }

    // MARK: - Target Geometry & Physics

    private struct LensTargetMetrics: Equatable {
        let centerX: CGFloat
        let width: CGFloat
    }

    private func targetLensMetrics(for range: ClosedRange<Int>, in layout: LensBarLayout) -> LensTargetMetrics {
        let base = layout.lensBounds(for: range)
        var cx = base.centerX
        if pinnedRange == nil, activeSliceRange != nil, let hoverPoint, range.count == 1 {
            let pullLimit = layout.slotWidth * 0.22
            let rawPull = (hoverPoint.x - base.centerX) * 0.28
            let pull = min(max(rawPull, -pullLimit), pullLimit)
            cx = layout.clampLensCenter(base.centerX + pull, width: base.width)
        }
        return LensTargetMetrics(centerX: cx, width: base.width)
    }

    private func stepSpring(at date: Date, target: LensTargetMetrics?) {
        guard canAnimate, let target else {
            velX = 0
            velW = 0
            mercuryStretch = 0
            lastStepDate = nil
            isSettling = false
            return
        }

        let dt: CGFloat
        if let prev = lastStepDate {
            dt = CGFloat(min(max(date.timeIntervalSince(prev), 1.0 / 240.0), 1.0 / 30.0))
        } else {
            dt = 1.0 / 120.0
        }
        lastStepDate = date

        let frames = dt * 60.0
        let dx = target.centerX - lensX
        let dw = target.width - lensWidth

        velX = (velX + dx * 0.22 * frames) * pow(0.72, frames)
        velW = (velW + dw * 0.24 * frames) * pow(0.70, frames)
        lensX += velX * frames
        lensWidth = max(36, lensWidth + velW * frames)
        mercuryStretch = min(0.20, abs(velX) * 0.016)

        if abs(target.centerX - lensX) < 0.18
            && abs(target.width - lensWidth) < 0.18
            && abs(velX) < 0.08
            && abs(velW) < 0.08
        {
            lensX = target.centerX
            lensWidth = target.width
            velX = 0
            velW = 0
            mercuryStretch = 0
            lastStepDate = nil
            isSettling = false
        }
    }

    // MARK: - Pointer & Keyboard Interactions

    private func clampToNonFuture(_ index: Int) -> Int {
        guard !buckets.isEmpty else { return 0 }
        let limit = maxNonFutureIndex ?? (buckets.count - 1)
        return min(max(0, index), limit)
    }

    private func releasePin(snapImmediately: Bool = false) {
        pinnedAnchor = nil
        pinnedHead = nil
        dragMode = nil
        didDrag = false
        if snapImmediately {
            hoverBucket = nil
            releasedUntilMove = false
            lensInitialized = false
            velX = 0
            velW = 0
            mercuryStretch = 0
            isSettling = false
        } else {
            hoverBucket = nil
            releasedUntilMove = hoverPoint != nil
            releaseOrigin = hoverPoint
        }
    }

    private func chartDragGesture(layout: LensBarLayout, currentLensRect: CGRect?) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !buckets.isEmpty, maxNonFutureIndex != nil else { return }
                let startPt = value.startLocation
                let curPt = value.location
                hoverPoint = curPt
                releasedUntilMove = false

                if dragMode == nil {
                    isChartFocused = true
                    didDrag = false

                    if let pinned = pinnedRange, let rect = currentLensRect {
                        let handleZone: CGFloat = 14
                        if abs(startPt.x - rect.minX) <= handleZone {
                            dragMode = .resizeLeft(fixedUpper: pinned.upperBound)
                        } else if abs(startPt.x - rect.maxX) <= handleZone {
                            dragMode = .resizeRight(fixedLower: pinned.lowerBound)
                        } else if rect.contains(CGPoint(x: startPt.x, y: rect.midY)) {
                            dragMode = .moveRange(initialRange: pinned)
                        } else {
                            let startBucket = clampToNonFuture(layout.bucketIndex(atX: startPt.x))
                            dragMode = .brush(startBucket: startBucket)
                        }
                    } else {
                        let startBucket = clampToNonFuture(layout.bucketIndex(atX: startPt.x))
                        dragMode = .brush(startBucket: startBucket)
                    }
                }

                let movedDistance = abs(curPt.x - startPt.x)
                if movedDistance > 4 {
                    didDrag = true
                }

                let currentBucket = clampToNonFuture(layout.bucketIndex(atX: curPt.x))
                switch dragMode {
                case .resizeLeft(let fixedUpper):
                    pinnedAnchor = fixedUpper
                    pinnedHead = min(currentBucket, fixedUpper)
                case .resizeRight(let fixedLower):
                    pinnedAnchor = fixedLower
                    pinnedHead = max(currentBucket, fixedLower)
                case .moveRange(let initialRange):
                    guard didDrag else { break }
                    let maxIdx = maxNonFutureIndex ?? (buckets.count - 1)
                    let span = initialRange.count - 1
                    let delta = Int(((curPt.x - startPt.x) / max(1, layout.slotWidth)).rounded())
                    let nextLower = min(max(0, initialRange.lowerBound + delta), max(0, maxIdx - span))
                    pinnedAnchor = nextLower
                    pinnedHead = nextLower + span
                case .brush(let startBucket):
                    if didDrag && (movedDistance > max(5, layout.slotWidth * 0.35) || currentBucket != startBucket) {
                        pinnedAnchor = startBucket
                        pinnedHead = currentBucket
                    } else if pinnedRange == nil {
                        hoverBucket = currentBucket
                    }
                case .none:
                    break
                }
            }
            .onEnded { value in
                defer {
                    dragMode = nil
                    didDrag = false
                }
                guard !buckets.isEmpty, maxNonFutureIndex != nil else { return }

                if !didDrag {
                    let now = ProcessInfo.processInfo.systemUptime
                    let isDoubleClick = (now - lastClickTime) <= NSEvent.doubleClickInterval
                        && hypot(value.location.x - lastClickPoint.x, value.location.y - lastClickPoint.y) <= 8

                    if isDoubleClick {
                        lastClickTime = 0
                        releasePin()
                    } else {
                        let target = clampToNonFuture(layout.bucketIndex(atX: value.location.x))
                        pinnedAnchor = target
                        pinnedHead = target
                        lastClickTime = now
                        lastClickPoint = value.location
                    }
                }
            }
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard !buckets.isEmpty, let maxIdx = maxNonFutureIndex else { return .ignored }

        switch press.key {
        case .escape:
            guard pinnedRange != nil else { return .ignored }
            releasePin()
            return .handled

        case .return, .space:
            if pinnedRange != nil {
                releasePin()
            } else {
                let target = clampToNonFuture(hoverBucket ?? peakNonFutureIndex ?? 0)
                releasedUntilMove = false
                pinnedAnchor = target
                pinnedHead = target
            }
            return .handled

        case .leftArrow, .rightArrow:
            let step = press.key == .rightArrow ? 1 : -1
            let isShift = press.modifiers.contains(.shift)
            releasedUntilMove = false

            if let anchor = pinnedAnchor, let head = pinnedHead {
                if isShift {
                    let nextHead = min(max(0, head + step), maxIdx)
                    pinnedHead = nextHead
                } else {
                    let lo = min(anchor, head)
                    let hi = max(anchor, head)
                    let span = hi - lo
                    let nextLo = min(max(0, lo + step), max(0, maxIdx - span))
                    pinnedAnchor = nextLo
                    pinnedHead = nextLo + span
                }
            } else {
                let base = clampToNonFuture(hoverBucket ?? peakNonFutureIndex ?? 0)
                let next = min(max(0, base + step), maxIdx)
                pinnedAnchor = isShift ? base : next
                pinnedHead = next
            }
            return .handled

        default:
            return .ignored
        }
    }

    // MARK: - Dual-Pass Canvas Drawing

    private func drawBasePass(
        in context: inout GraphicsContext,
        layout: LensBarLayout,
        activeRange: ClosedRange<Int>?,
        lensRect: CGRect?,
        lensCornerRadius: CGFloat
    ) {
        let isDark = scheme == .dark
        let increased = contrast == .increased
        let plot = layout.plotRect

        // 1. Horizontal Y-axis gridlines & tick labels.
        let gridColor = isDark
            ? Color.white.opacity(increased ? 0.16 : 0.068)
            : Color(hex: "#0F172A").opacity(increased ? 0.15 : 0.065)
        let tickColor = Palette.ink3
        let steps = 4

        for s in 0...steps {
            let y = (plot.maxY - (plot.height * CGFloat(s)) / CGFloat(steps)).rounded() + 0.5
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(gridColor), lineWidth: increased ? 1.2 : 1.0)

            if !layout.isEmpty {
                let tickValue = s == 0 ? "0" : LensBarLayout.axisLabel(layout.yMax * Double(s) / Double(steps))
                let resolved = context.resolve(
                    Text(verbatim: tickValue)
                        .font(.system(size: 10.5, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(tickColor)
                )
                context.draw(resolved, at: CGPoint(x: plot.minX - 8, y: y), anchor: .trailing)
            }
        }

        // 2. X-axis labels.
        for tick in layout.xTicks {
            let isHighlighted = activeRange?.contains(tick.index) == true
            let resolved = context.resolve(
                Text(verbatim: tick.label)
                    .font(.system(size: 10.5, weight: isHighlighted ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isHighlighted ? Palette.ink1 : tickColor)
            )
            context.draw(resolved, at: CGPoint(x: tick.centerX, y: plot.maxY + 7), anchor: .top)
        }

        guard !buckets.isEmpty else { return }

        // 3. Base unmagnified bars (inverse-clipped around the lens so dim bars never ghost behind magnified bars).
        context.drawLayer { layer in
            if let lensRect {
                var inverse = Path(CGRect(origin: .zero, size: layout.size))
                inverse.addPath(Path(roundedRect: lensRect, cornerRadius: lensCornerRadius, style: .continuous))
                layer.clip(to: inverse, style: FillStyle(eoFill: true))
            }

            let baseOpacity = increased ? 0.52 : (isDark ? 0.28 : 0.34)
            for bar in layout.bars {
                drawBucketBar(
                    in: &layer,
                    bar: bar,
                    plotRect: plot,
                    yMax: layout.yMax,
                    centerX: bar.slotCenterX,
                    barWidth: bar.baseBarWidth,
                    verticalScale: 1.0,
                    opacity: baseOpacity,
                    isHighlighted: false,
                    isDark: isDark,
                    increasedContrast: increased
                )
            }
        }
    }

    private func drawMagnifiedPass(
        in context: inout GraphicsContext,
        layout: LensBarLayout,
        range: ClosedRange<Int>,
        lensRect: CGRect,
        lensCornerRadius: CGFloat,
        isPinned: Bool,
        isResting: Bool
    ) {
        let isDark = scheme == .dark
        let increased = contrast == .increased
        let plot = layout.plotRect
        let isRange = range.count >= 2
        let lensPath = Path(roundedRect: lensRect, cornerRadius: lensCornerRadius, style: .continuous)
        let lensCx = lensRect.midX
        let lensHalfW = lensRect.width * 0.5

        var rangeSum: Int64 = 0
        var minRangeTopY = plot.maxY
        var hasRangeBars = false

        context.drawLayer { mag in
            mag.clip(to: lensPath)

            // Subtle interior refraction tint when transparency is active.
            if !reduceTransparency {
                mag.fill(
                    Path(lensRect),
                    with: .linearGradient(
                        Gradient(colors: isDark
                            ? [Color(hex: "#3A4C70").opacity(0.20), Color(hex: "#121826").opacity(0.26)]
                            : [Color.white.opacity(0.58), Color(hex: "#EBF2FF").opacity(0.32)]),
                        startPoint: CGPoint(x: lensCx, y: lensRect.minY),
                        endPoint: CGPoint(x: lensCx, y: lensRect.maxY)
                    )
                )
            }

            // Refracted horizontal gridlines inside the lens.
            let gridMag = isRange ? LensBarLayout.rangeMagnification : LensBarLayout.singleMagnification
            let gridColor = isDark
                ? Color.white.opacity(increased ? 0.20 : 0.09)
                : Color(hex: "#0F172A").opacity(increased ? 0.18 : 0.075)
            for s in 0...4 {
                let gy = plot.maxY - ((plot.height * CGFloat(s)) / 4.0) * gridMag
                guard gy >= lensRect.minY - 4 else { continue }
                var curve = Path()
                curve.move(to: CGPoint(x: lensRect.minX - 4, y: gy))
                curve.addQuadCurve(
                    to: CGPoint(x: lensRect.maxX + 4, y: gy),
                    control: CGPoint(x: lensCx, y: gy + (s == 0 ? 0 : -1.2))
                )
                mag.stroke(curve, with: .color(gridColor), lineWidth: increased ? 1.2 : 1)
            }

            // Magnified vector bars.
            for bar in layout.bars {
                let dist = bar.slotCenterX - lensCx
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
                    // Range state (>= 2 buckets): zero horizontal stretch, 1.2x vertical lift, full color.
                    if inRange {
                        vScale = LensBarLayout.rangeMagnification
                        drawCenter = bar.slotCenterX
                        barWidth = bar.baseBarWidth
                    } else {
                        if abs(dist) > lensHalfW + bar.baseBarWidth * 0.5 { continue }
                        vScale = 1.04
                        drawCenter = bar.slotCenterX + (dist >= 0 ? 2.0 : -2.0)
                        barWidth = bar.baseBarWidth * 0.95
                    }
                }

                let barOpacity = inRange ? 0.96 : (increased ? 0.62 : 0.44)
                let topY = drawBucketBar(
                    in: &mag,
                    bar: bar,
                    plotRect: plot,
                    yMax: layout.yMax,
                    centerX: drawCenter,
                    barWidth: barWidth,
                    verticalScale: vScale,
                    opacity: barOpacity,
                    isHighlighted: inRange,
                    isDark: isDark,
                    increasedContrast: increased
                )

                if inRange && !bar.isFuture && bar.total > 0 {
                    if !isRange {
                        // Single-bucket top value label.
                        if plot.maxY - topY > 2, topY > lensRect.minY + 12 {
                            let labelText = TokenFormat.short(bar.total)
                            let resolved = mag.resolve(
                                Text(verbatim: labelText)
                                    .font(.system(size: 10, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(Palette.ink1)
                            )
                            let measured = resolved.measure(in: CGSize(width: 200, height: 24))
                            if lensRect.width >= measured.width + 8 {
                                mag.draw(resolved, at: CGPoint(x: drawCenter, y: topY - 3), anchor: .bottom)
                            }
                        }
                    } else {
                        rangeSum += bar.total
                        minRangeTopY = min(minRangeTopY, topY)
                        hasRangeBars = true
                    }
                }
            }

            // Refraction bevels & top specular highlight.
            if !reduceTransparency {
                if isRange {
                    // 14pt left & right refraction bands in range mode.
                    let bevel = LensBarLayout.bevelWidth
                    let rimColor = Color.white.opacity(isDark ? 0.16 : 0.68)
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
                            Gradient(colors: [.clear, Color.white.opacity(isDark ? 0.13 : 0.56)]),
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
                        Gradient(colors: [Color.white.opacity(isDark ? 0.22 : 0.72), .clear]),
                        startPoint: CGPoint(x: lensCx, y: sheenRect.minY),
                        endPoint: CGPoint(x: lensCx, y: sheenRect.maxY)
                    )
                )
            }
        }

        // Lens border: 2pt roleAccent under Reduce Transparency; subtle dispersion & rim otherwise.
        if reduceTransparency {
            context.stroke(lensPath, with: .color(Palette.roleAccent), lineWidth: 2)
        } else {
            context.stroke(
                lensPath.offsetBy(dx: 1.0, dy: 0),
                with: .color(Color(.sRGB, red: 1.0, green: 0.36, blue: 0.55, opacity: isDark ? 0.22 : 0.18)),
                lineWidth: 1.0
            )
            context.stroke(
                lensPath.offsetBy(dx: -1.0, dy: 0),
                with: .color(Color(.sRGB, red: 0.30, green: 0.65, blue: 1.0, opacity: isDark ? 0.24 : 0.20)),
                lineWidth: 1.0
            )

            let rimStroke: Color = if isPinned {
                Palette.roleAccent.opacity(increased ? (isDark ? 0.95 : 0.88) : (isDark ? 0.78 : 0.58))
            } else if increased {
                isDark ? Color.white.opacity(0.65) : Palette.ink1.opacity(0.55)
            } else {
                Color.white.opacity(isDark ? (isResting ? 0.28 : 0.38) : 0.92)
            }
            context.stroke(
                lensPath,
                with: .color(rimStroke),
                lineWidth: increased ? 1.6 : (isPinned ? 1.5 : 1.15)
            )
        }

        // Draggable left & right grip handles when pinned.
        if isPinned {
            let handleH = min(28, lensRect.height * 0.26)
            for edgeX in [lensRect.minX, lensRect.maxX] {
                let handleRect = CGRect(x: edgeX - 4, y: lensRect.midY - handleH * 0.5, width: 8, height: handleH)
                let handlePath = Path(roundedRect: handleRect, cornerRadius: 4, style: .continuous)
                context.fill(
                    handlePath,
                    with: .color(
                        isDark
                            ? Color(hex: "#42567A").opacity(increased ? 1.0 : 0.95)
                            : Color.white.opacity(increased ? 1.0 : 0.96)
                    )
                )
                context.stroke(
                    handlePath,
                    with: .color(Palette.roleAccent.opacity(increased ? 0.95 : (isDark ? 0.70 : 0.50))),
                    lineWidth: increased ? 1.5 : 1
                )

                let grooveColor = Palette.roleAccent.opacity(increased ? 1.0 : (isDark ? 0.85 : 0.70))
                let g1 = CGRect(x: edgeX - 1.5, y: lensRect.midY - 4.5, width: 1, height: 9)
                let g2 = CGRect(x: edgeX + 0.5, y: lensRect.midY - 4.5, width: 1, height: 9)
                context.fill(Path(roundedRect: g1, cornerRadius: 0.5), with: .color(grooveColor))
                context.fill(Path(roundedRect: g2, cornerRadius: 0.5), with: .color(grooveColor))
            }
        }

        // Single range-sum pill above the selected range in multi-bucket mode.
        if isRange && hasRangeBars {
            let formatted = TokenFormat.short(rangeSum)
            let pillString = lensRect.width >= 88
                ? String(localized: "Total \(formatted)", locale: locale)
                : formatted
            let resolved = context.resolve(
                Text(verbatim: pillString)
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink1)
            )
            let textSize = resolved.measure(in: CGSize(width: 240, height: 24))
            let pillW = textSize.width + 12
            let pillH: CGFloat = 17
            let clampedX = min(max(pillW * 0.5 + 4, lensCx), layout.size.width - pillW * 0.5 - 4)
            let pillTop = max(2, minRangeTopY - pillH - 5)
            let pillRect = CGRect(x: clampedX - pillW * 0.5, y: pillTop, width: pillW, height: pillH)
            let pillPath = Path(roundedRect: pillRect, cornerRadius: pillH * 0.5, style: .continuous)

            context.fill(
                pillPath,
                with: .color(
                    isDark
                        ? Color(hex: "#182130").opacity(increased ? 0.98 : 0.94)
                        : Color.white.opacity(increased ? 1.0 : 0.95)
                )
            )
            context.stroke(
                pillPath,
                with: .color(Palette.roleAccent.opacity(increased ? (isDark ? 0.90 : 0.82) : (isDark ? 0.48 : 0.34))),
                lineWidth: increased ? 1.5 : 1
            )
            context.draw(resolved, at: CGPoint(x: clampedX, y: pillRect.midY), anchor: .center)
        }
    }

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
        isDark: Bool,
        increasedContrast: Bool
    ) -> CGFloat {
        let bottomY = plotRect.maxY
        let x = centerX - barWidth * 0.5

        // 1. Future bucket: shallow bottom groove.
        if bar.isFuture {
            let grooveRect = CGRect(x: x, y: bottomY - 2.5, width: barWidth, height: 2.5)
            context.fill(
                Path(roundedRect: grooveRect, cornerRadius: 1.25, style: .continuous),
                with: .color(
                    isDark
                        ? Color.white.opacity(increasedContrast ? 0.24 : 0.13)
                        : Color(hex: "#0F172A").opacity(increasedContrast ? 0.22 : 0.11)
                )
            )
            return bottomY
        }

        // 2. Missing coverage (!isKnown) with zero measured tokens: diagonal hatched placeholder slot.
        if !bar.isKnown && bar.total <= 0 {
            let slotH: CGFloat = min(14, max(9, plotRect.height * 0.11)) * min(verticalScale, 1.2)
            let slotRect = CGRect(x: x, y: bottomY - slotH, width: barWidth, height: slotH)
            drawHatchedPlaceholder(
                in: &context,
                rect: slotRect,
                isDark: isDark,
                isHighlighted: isHighlighted,
                increasedContrast: increasedContrast
            )
            return slotRect.minY
        }

        // 3. Measured zero (isKnown && total == 0): crisp solid baseline tick.
        if bar.total <= 0 || bar.segments.isEmpty {
            let zeroRect = CGRect(x: x, y: bottomY - 1.5, width: barWidth, height: 1.5)
            context.fill(
                Path(roundedRect: zeroRect, cornerRadius: 0.75),
                with: .color(Palette.ink3.opacity(increasedContrast ? (isHighlighted ? 0.85 : 0.55) : (isHighlighted ? 0.55 : 0.30)))
            )
            return bottomY
        }

        // 4. Stacked positive segments: preserve the bucket's proportional height while giving
        // sub-1pt segments 1pt whenever taller segments have enough surplus above 1pt.
        var currentY = bottomY
        let validSegments = bar.segments.filter { $0.tokens > 0 }
        let rawHeights = validSegments.map {
            (CGFloat($0.tokens) / CGFloat(max(1, yMax))) * plotRect.height * verticalScale
        }
        let minSegmentH: CGFloat = 1.0
        let deficit = rawHeights.reduce(CGFloat(0)) { $0 + max(0, minSegmentH - $1) }
        let surplus = rawHeights.reduce(CGFloat(0)) { $0 + max(0, $1 - minSegmentH) }
        let segmentHeights: [CGFloat]
        if deficit > 0, surplus >= deficit {
            let keepRatio = (surplus - deficit) / surplus
            segmentHeights = rawHeights.map { rawH in
                rawH < minSegmentH ? minSegmentH : minSegmentH + (rawH - minSegmentH) * keepRatio
            }
        } else {
            segmentHeights = rawHeights
        }

        let gap: CGFloat = isHighlighted ? 0.6 : 0.3
        for (segIdx, segment) in validSegments.enumerated() {
            let segH = segmentHeights[segIdx]
            guard segH > 0 else { continue }
            let nextY = currentY - segH

            let isTop = segIdx == validSegments.count - 1 && bar.isKnown
            let applyGap = !isTop && segH > minSegmentH + gap
            let drawH = applyGap ? (segH - gap) : segH
            let drawY = applyGap ? (nextY + gap) : nextY
            let segRect = CGRect(x: x, y: drawY, width: barWidth, height: drawH)
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
                let capH = min(1.2, drawH)
                let capRect = CGRect(x: x + 0.5, y: drawY, width: max(0, barWidth - 1), height: capH)
                context.fill(
                    Path(roundedRect: capRect, cornerRadius: min(0.6, capH * 0.5)),
                    with: .color(Color.white.opacity(isDark ? 0.28 : 0.55))
                )
            }

            currentY = nextY
        }

        // Partial coverage indicator when a bucket has some tokens AND missing hourly coverage (!isKnown).
        if !bar.isKnown {
            let capH: CGFloat = 5
            let capRect = CGRect(x: x, y: max(plotRect.minY, currentY - capH - 1), width: barWidth, height: capH)
            drawHatchedPlaceholder(
                in: &context,
                rect: capRect,
                isDark: isDark,
                isHighlighted: isHighlighted,
                increasedContrast: increasedContrast
            )
            currentY = capRect.minY
        }

        return currentY
    }

    private func drawHatchedPlaceholder(
        in context: inout GraphicsContext,
        rect: CGRect,
        isDark: Bool,
        isHighlighted: Bool,
        increasedContrast: Bool
    ) {
        let shape = Path(roundedRect: rect, cornerRadius: min(3, rect.width * 0.4), style: .continuous)
        let strokeAlpha = increasedContrast
            ? (isHighlighted ? 0.85 : 0.58)
            : (isHighlighted ? 0.52 : (isDark ? 0.28 : 0.26))
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

    // MARK: - Per-Bucket VoiceOver Elements

    private func bucketAccessibilityOverlay(layout: LensBarLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.bars) { bar in
                let bucket = buckets[bar.index]
                let isSelected = activeSliceRange?.contains(bar.index) == true
                Color.clear
                    .frame(width: max(4, layout.slotWidth), height: max(20, layout.plotRect.height))
                    .offset(x: bar.slotRect.minX, y: layout.plotRect.minY)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: bucketAccessibilityDescription(for: bucket)))
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction {
                        guard !bucket.isFuture else { return }
                        if pinnedRange == (bar.index...bar.index) {
                            releasePin()
                        } else {
                            releasedUntilMove = false
                            pinnedAnchor = bar.index
                            pinnedHead = bar.index
                        }
                    }
            }
        }
    }

    private func bucketAccessibilityDescription(for bucket: LensBucket) -> String {
        let timeLabel = LensDateFormatter.singleBucketLabel(bucket, period: period, locale: locale)
        if bucket.isFuture {
            return String(localized: "\(timeLabel), upcoming", locale: locale)
        }
        if !bucket.isKnown && bucket.total <= 0 {
            return String(localized: "\(timeLabel), missing hourly coverage", locale: locale)
        }
        let spokenTokens = TokenFormat.spoken(bucket.total)
        let topNames = topBucketNames(for: bucket)
        if topNames.isEmpty {
            return String(localized: "\(timeLabel), \(spokenTokens) tokens", locale: locale)
        }
        let joined = topNames.joined(separator: locale.language.languageCode == .chinese ? "、" : ", ")
        return String(localized: "\(timeLabel), \(spokenTokens) tokens, top: \(joined)", locale: locale)
    }

    private func topBucketNames(for bucket: LensBucket) -> [String] {
        guard bucket.total > 0 else { return [] }
        switch dimension {
        case .sources:
            return bucket.bySource
                .filter { $0.value.total > 0 }
                .sorted { $0.value.total > $1.value.total }
                .prefix(3)
                .map { SourceCatalog.info(for: $0.key).name }
        case .models:
            guard !bucket.byModel.isEmpty else { return [] }
            return bucket.byModel
                .filter { $0.value.total > 0 }
                .sorted { $0.value.total > $1.value.total }
                .prefix(3)
                .map(\.key)
        }
    }
}

// MARK: - Pure-Value Bar Layout

/// Caches the resolved active slice so the 120fps spring does not re-aggregate buckets every frame.
@MainActor
private final class LensSliceCache {
    private struct Key: Equatable {
        let range: ClosedRange<Int>
        let period: Period
        let buckets: [LensBucket]
        let devices: [Device]
    }

    private var cachedKey: Key?
    private var cachedSlice: LensSlice?

    func slice(
        for range: ClosedRange<Int>,
        period: Period,
        buckets: [LensBucket],
        devices: [Device],
        compute: (ClosedRange<Int>) -> LensSlice
    ) -> LensSlice {
        let key = Key(
            range: range,
            period: period,
            buckets: buckets,
            devices: devices
        )
        if let cachedSlice, cachedKey == key {
            return cachedSlice
        }
        let resolved = compute(range)
        cachedKey = key
        cachedSlice = resolved
        return resolved
    }
}

/// Keeps the stacked bar layout and model palette between body passes so hover and spring frames
/// do not rebuild segment geometry, source/model rank orders, or model colors when inputs stay fixed.
@MainActor
private final class LensBarLayoutCache {
    private var buckets: [LensBucket] = []
    private var dimension: BreakdownDimension = .sources
    private var period: Period = .day
    private var size: CGSize = .zero
    private var summarySources: [Breakdown] = []
    private var summaryModels: [Breakdown] = []
    private var valid = false
    private var cached: LensBarLayout?

    private var cachedColorBuckets: [LensBucket] = []
    private var cachedColorDimension: BreakdownDimension = .sources
    private var cachedModelOrder: [String] = []
    private var cachedModelColors: [String: Color] = [:]
    private var modelColorsValid = false

    func layout(
        buckets: [LensBucket],
        dimension: BreakdownDimension,
        period: Period,
        size: CGSize,
        summarySources: [Breakdown],
        summaryModels: [Breakdown]
    ) -> LensBarLayout {
        if valid,
           let cached,
           self.buckets == buckets,
           self.dimension == dimension,
           self.period == period,
           self.size == size,
           self.summarySources == summarySources,
           self.summaryModels == summaryModels {
            return cached
        }

        let sourceOrder = Self.resolveOrder(summary: summarySources, buckets: buckets, keyPath: \.bySource)
        let modelOrder = Self.resolveOrder(summary: summaryModels, buckets: buckets, keyPath: \.byModel)

        let degraded = period == .day && dimension == .models
        let resolvedModelPalette: [String: Color]
        if dimension == .models && !degraded {
            if modelColorsValid,
               cachedColorBuckets == buckets,
               cachedColorDimension == dimension,
               cachedModelOrder == modelOrder {
                resolvedModelPalette = cachedModelColors
            } else {
                resolvedModelPalette = Palette.modelColors(for: modelOrder)
                cachedColorBuckets = buckets
                cachedColorDimension = dimension
                cachedModelOrder = modelOrder
                cachedModelColors = resolvedModelPalette
                modelColorsValid = true
            }
        } else {
            resolvedModelPalette = [:]
        }

        let built = LensBarLayout(
            buckets: buckets,
            dimension: dimension,
            period: period,
            size: size,
            sourceOrder: sourceOrder,
            modelOrder: modelOrder,
            modelPalette: resolvedModelPalette
        )
        self.buckets = buckets
        self.dimension = dimension
        self.period = period
        self.size = size
        self.summarySources = summarySources
        self.summaryModels = summaryModels
        self.cached = built
        self.valid = true
        return built
    }

    private static func resolveOrder(
        summary: [Breakdown],
        buckets: [LensBucket],
        keyPath: KeyPath<LensBucket, [String: TokenCounts]>
    ) -> [String] {
        let fromSummary = summary.map(\.id)
        if !fromSummary.isEmpty { return fromSummary }
        var totals: [String: Int64] = [:]
        for bucket in buckets where !bucket.isFuture {
            for (id, counts) in bucket[keyPath: keyPath] {
                totals[id, default: 0] += counts.total
            }
        }
        return totals.sorted { $0.value > $1.value }.map(\.key)
    }
}

private final class LensModelColorCache {
    private var idSet: Set<String> = []
    private var valid = false
    private var cached: [String: Color] = [:]

    func colors(for ids: [String]) -> [String: Color] {
        let key = Set(ids)
        if valid, key == idSet { return cached }
        idSet = key
        valid = true
        cached = Palette.modelColors(for: ids)
        return cached
    }
}

struct LensBarLayout {
    static let singleMagnification: CGFloat = 1.35
    static let rangeMagnification: CGFloat = 1.20
    static let bevelWidth: CGFloat = 14
    private static let mergedTailColor = Color(light: "#6E7D92", dark: "#8494AB")

    struct BarSegment: Equatable {
        let id: String
        let tokens: Int64
        let color: Color
    }

    struct BucketBar: Identifiable, Equatable {
        let index: Int
        let slotRect: CGRect
        let slotCenterX: CGFloat
        let baseBarWidth: CGFloat
        let total: Int64
        let isFuture: Bool
        let isKnown: Bool
        let segments: [BarSegment]

        var id: Int { index }
    }

    struct AxisTick: Identifiable, Equatable {
        let index: Int
        let label: String
        let centerX: CGFloat

        var id: Int { index }
    }

    let size: CGSize
    let plotRect: CGRect
    let slotWidth: CGFloat
    let yMax: Double
    let isDayModelDegraded: Bool
    let isEmpty: Bool
    let bars: [BucketBar]
    let xTicks: [AxisTick]

    init(
        buckets: [LensBucket],
        dimension: BreakdownDimension,
        period: Period,
        size: CGSize,
        sourceOrder: [String],
        modelOrder: [String],
        modelPalette precomputedModelPalette: [String: Color]? = nil
    ) {
        self.size = size
        let leftPad: CGFloat = 46
        let rightPad: CGFloat = Self.bevelWidth + 4
        let topPad: CGFloat = 22
        let bottomPad: CGFloat = 24
        let plotW = max(60, size.width - leftPad - rightPad)
        let plotH = max(40, size.height - topPad - bottomPad)
        let resolvedPlot = CGRect(x: leftPad, y: topPad, width: plotW, height: plotH)
        self.plotRect = resolvedPlot

        let count = max(1, buckets.count)
        let bw = plotW / CGFloat(count)
        self.slotWidth = bw

        let degraded = period == .day && dimension == .models
        self.isDayModelDegraded = degraded

        let maxRaw = buckets.reduce(Int64(0)) { current, bucket in
            bucket.isFuture ? current : max(current, bucket.total)
        }
        let hasKnownCoverageGap = buckets.contains { !$0.isFuture && !$0.isKnown }
        self.isEmpty = buckets.isEmpty || (maxRaw <= 0 && !hasKnownCoverageGap)
        self.yMax = Self.niceCeil(Double(max(1, maxRaw)) * Double(Self.singleMagnification) * 1.08)

        let padRatio: CGFloat = count > 20 ? 0.20 : (count > 10 ? 0.23 : 0.27)
        let computedBarW = min(44, max(2, bw * (1 - padRatio * 2)))

        let modelPalette = dimension == .models && !degraded
            ? (precomputedModelPalette ?? Palette.modelColors(for: modelOrder))
            : [:]
        let sourceRank = Dictionary(uniqueKeysWithValues: sourceOrder.enumerated().map { ($0.element, $0.offset) })
        let modelRank = Dictionary(uniqueKeysWithValues: modelOrder.enumerated().map { ($0.element, $0.offset) })

        var builtBars: [BucketBar] = []
        builtBars.reserveCapacity(buckets.count)

        for (idx, bucket) in buckets.enumerated() {
            let slotX = resolvedPlot.minX + CGFloat(idx) * bw
            let slot = CGRect(x: slotX, y: resolvedPlot.minY, width: bw, height: resolvedPlot.height)
            let cx = slot.midX

            let segments: [BarSegment]
            if bucket.isFuture || bucket.total <= 0 {
                segments = []
            } else if degraded {
                segments = [BarSegment(id: "total", tokens: bucket.total, color: Palette.roleAccent)]
            } else {
                switch dimension {
                case .sources:
                    segments = Self.buildSegments(
                        from: bucket.bySource,
                        rankMap: sourceRank,
                        limit: 5,
                        colorForID: { Palette.color(forSource: $0) }
                    )
                case .models:
                    segments = Self.buildSegments(
                        from: bucket.byModel,
                        rankMap: modelRank,
                        limit: 6,
                        colorForID: { modelPalette[$0] ?? Palette.color(for: .output) }
                    )
                }
            }

            builtBars.append(BucketBar(
                index: idx,
                slotRect: slot,
                slotCenterX: cx,
                baseBarWidth: computedBarW,
                total: bucket.total,
                isFuture: bucket.isFuture,
                isKnown: bucket.isKnown,
                segments: segments
            ))
        }
        self.bars = builtBars
        self.xTicks = Self.makeXTicks(buckets: buckets, period: period, plotRect: resolvedPlot, slotWidth: bw)
    }

    private static func buildSegments(
        from dict: [String: TokenCounts],
        rankMap: [String: Int],
        limit: Int,
        colorForID: (String) -> Color
    ) -> [BarSegment] {
        let positive = dict
            .compactMap { key, counts -> (id: String, tokens: Int64)? in
                counts.total > 0 ? (key, counts.total) : nil
            }
            .sorted { lhs, rhs in
                let rL = rankMap[lhs.id] ?? Int.max
                let rR = rankMap[rhs.id] ?? Int.max
                if rL != rR { return rL < rR }
                if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
                return lhs.id < rhs.id
            }

        guard positive.count > limit + 1 else {
            return positive.map { BarSegment(id: $0.id, tokens: $0.tokens, color: colorForID($0.id)) }
        }

        var result = positive.prefix(limit).map {
            BarSegment(id: $0.id, tokens: $0.tokens, color: colorForID($0.id))
        }
        let tailTokens = positive.dropFirst(limit).reduce(Int64(0)) { $0 + $1.tokens }
        if tailTokens > 0 {
            result.append(BarSegment(id: "other", tokens: tailTokens, color: mergedTailColor))
        }
        return result
    }

    private static func makeXTicks(
        buckets: [LensBucket],
        period: Period,
        plotRect: CGRect,
        slotWidth: CGFloat
    ) -> [AxisTick] {
        let n = buckets.count
        guard n > 0 else { return [] }

        let indices: [Int]
        switch period {
        case .day where n >= 23:
            indices = [0, 6, 12, 18, n - 1].filter { $0 < n }
        case .month where n >= 28:
            indices = [0, 4, 9, 14, 19, 24, n - 1].filter { $0 < n }
        default:
            let step: Int
            if n <= 12 {
                step = slotWidth < 28 ? 2 : 1
            } else if n <= 20 {
                step = 2
            } else {
                step = max(2, Int(ceil(42.0 / max(1, slotWidth))))
            }
            var picked = stride(from: 0, to: n, by: step).map { $0 }
            if let last = picked.last, last != n - 1, CGFloat(n - 1 - last) * slotWidth >= 26 {
                picked.append(n - 1)
            }
            indices = picked
        }

        return indices.map { i in
            AxisTick(
                index: i,
                label: buckets[i].label,
                centerX: plotRect.minX + (CGFloat(i) + 0.5) * slotWidth
            )
        }
    }

    func bucketIndex(atX x: CGFloat) -> Int {
        guard !bars.isEmpty else { return 0 }
        let raw = Int(floor((x - plotRect.minX) / max(1, slotWidth)))
        return min(max(0, raw), bars.count - 1)
    }

    func lensBounds(for range: ClosedRange<Int>) -> (centerX: CGFloat, width: CGFloat) {
        guard !bars.isEmpty else { return (plotRect.midX, 56) }
        let s0 = min(max(0, range.lowerBound), bars.count - 1)
        let s1 = min(max(s0, range.upperBound), bars.count - 1)
        let baseBarW = bars[s0].baseBarWidth
        let bevel = Self.bevelWidth

        if s1 > s0 {
            let leftEdge = bars[s0].slotCenterX - baseBarW * 0.5 - bevel
            let rightEdge = bars[s1].slotCenterX + baseBarW * 0.5 + bevel
            let w = max(40, rightEdge - leftEdge)
            let cx = clampLensCenter((leftEdge + rightEdge) * 0.5, width: w)
            return (cx, w)
        } else {
            let center = bars[s0].slotCenterX
            let magBarW = min(slotWidth * 0.92, baseBarW * Self.singleMagnification)
            let w = max(56, magBarW + bevel * 2)
            let cx = clampLensCenter(center, width: w)
            return (cx, w)
        }
    }

    func clampLensCenter(_ centerX: CGFloat, width: CGFloat) -> CGFloat {
        let half = width * 0.5
        let minCx = max(half + 2, plotRect.minX - Self.bevelWidth + half * 0.25)
        let maxCx = min(size.width - half - 2, plotRect.maxX + Self.bevelWidth - half * 0.25)
        guard minCx <= maxCx else { return size.width * 0.5 }
        return min(max(centerX, minCx), maxCx)
    }

    static func niceCeil(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let exp = floor(log10(value))
        let base = pow(10, exp)
        for mult in [1.0, 1.2, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0] {
            if mult * base >= value {
                return mult * base
            }
        }
        return 10 * base
    }

    static func axisLabel(_ value: Double) -> String {
        guard value.isFinite, abs(value) >= 0.5 else { return "0" }
        let clamped = min(max(value.rounded(), Double(Int64.min)), Double(Int64.max))
        return TokenFormat.short(Int64(clamped))
    }
}

// MARK: - Three-Column Docked Readout Card

private struct LensReadoutCard: View {
    let summary: UsageSummary
    let period: Period
    let dimension: BreakdownDimension
    let buckets: [LensBucket]
    let activeSlice: LensSlice?
    let isPinned: Bool
    let increasedContrast: Bool
    let onRelease: () -> Void

    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var modelColorCache = LensModelColorCache()

    private var displayCounts: TokenCounts {
        activeSlice?.counts ?? summary.total
    }

    private var displayTotal: Int64 {
        displayCounts.total
    }

    /// False when the selection includes an elapsed bucket without full coverage: zero is then unknown.
    private var coverageKnown: Bool {
        activeSlice?.isKnown ?? true
    }

    private var reasoningKnown: Bool {
        activeSlice?.reasoningKnown ?? true
    }

    private var displayCost: CostEstimate? {
        if let activeSlice {
            return activeSlice.cost
        }
        return summary.cost
    }

    private var hasModelDetail: Bool {
        if let activeSlice {
            return activeSlice.hasModelDetail
        }
        return true
    }

    private var rankedItems: [Breakdown] {
        let raw: [Breakdown] = switch (dimension, activeSlice) {
        case (.sources, let slice?): slice.bySource
        case (.sources, nil): summary.bySource
        case (.models, let slice?): slice.byModel
        case (.models, nil): summary.byModel
        }
        return raw.filter { $0.counts.total > 0 }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)

        HStack(alignment: .top, spacing: 14) {
            leftColumn
                .frame(minWidth: 168, idealWidth: 215, maxWidth: 245, maxHeight: .infinity, alignment: .topLeading)

            columnDivider

            middleColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            columnDivider

            rightColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(LensReadoutSurface(
            reduceTransparency: reduceTransparency,
            isDark: scheme == .dark,
            increasedContrast: increasedContrast,
            shape: shape
        ))
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(width: increasedContrast ? 1.5 : 1)
            .padding(.vertical, 2)
            .accessibilityHidden(true)
    }

    // MARK: Left Column: Time Range, Total Tokens, Share of Period, Cost

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                timeRangeLabel
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(activeSlice != nil ? Palette.roleAccent : Palette.ink2)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 4)

                if isPinned {
                    Button(action: onRelease) {
                        HStack(spacing: 3) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8.5, weight: .bold))
                                .accessibilityHidden(true)
                            Text("Release")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(Palette.roleAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            Capsule().fill(Palette.roleAccent.opacity(increasedContrast ? 0.22 : 0.12))
                        }
                        .overlay {
                            if increasedContrast {
                                Capsule().strokeBorder(Palette.roleAccent, lineWidth: 1)
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(Text("Release lens (Esc)"))
                    .accessibilityLabel(Text("Release lens"))
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(verbatim: !coverageKnown && displayTotal == 0 ? "-" : TokenFormat.short(displayTotal))
                    .font(.system(size: 25, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Palette.ink1)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text("tokens")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Group {
                    if coverageKnown {
                        Text("\(Share.percent(displayTotal, of: summary.total.total)) of period")
                    } else {
                        Text("Partial hourly coverage")
                    }
                }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(activeSlice != nil ? Palette.roleAccent : Palette.ink3)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.top, 4)

            Spacer(minLength: 2)

            if let cost = displayCost, cost.unpricedTokens > 0, cost.unpricedTokens >= displayTotal {
                Text("No prices for these models")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } else if let cost = displayCost {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("≈ \(TokenFormat.usd(cost.estimatedUSD)) · estimate")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.ink1)
                        .monospacedDigit()
                        .lineLimit(1)
                    if cost.unpricedTokens > 0 {
                        Text("\(TokenFormat.short(cost.unpricedTokens)) unpriced")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.ink3)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .minimumScaleFactor(0.85)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "-")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.ink2)
                    Text("Hourly granularity has no model pricing")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var timeRangeLabel: some View {
        if let slice = activeSlice {
            Text(verbatim: LensDateFormatter.sliceLabel(
                slice: slice,
                buckets: buckets,
                period: period,
                locale: locale
            ))
        } else {
            Text(periodSummaryDescription)
        }
    }

    private var periodSummaryDescription: LocalizedStringKey {
        let start = summary.start
        switch period {
        case .day:
            return "Today · \(start.formatted(.dateTime.locale(locale).month(.abbreviated).day()))"
        case .week:
            let today = Calendar.current.date(byAdding: .day, value: -1, to: summary.end) ?? start
            if Calendar.current.isDate(start, inSameDayAs: today) || today <= start {
                return "This week · \(start.formatted(.dateTime.locale(locale).month(.abbreviated).day()))"
            }
            return "This week · \(start.formatted(.dateTime.locale(locale).month(.abbreviated).day()))–\(today.formatted(.dateTime.locale(locale).month(.abbreviated).day()))"
        case .month:
            return "This month · \(start.formatted(.dateTime.locale(locale).year().month(.wide)))"
        case .year:
            return "This year · \(start.formatted(.dateTime.locale(locale).year()))"
        case .all:
            return "All time · since \(start.formatted(.dateTime.locale(locale).year().month(.abbreviated).day()))"
        }
    }

    // MARK: Middle Column: Top 3 in Current Dimension with Color Bars

    private var middleColumn: some View {
        let topThree = Array(rankedItems.prefix(3))
        let maxTokens = max(topThree.first?.counts.total ?? 1, 1)
        let modelColors = dimension == .models
            ? modelColorCache.colors(for: summary.byModel.map(\.id) + topThree.map(\.id))
            : [:]

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(dimension == .sources ? LocalizedStringKey("Top harnesses") : LocalizedStringKey("Top models"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hasModelDetail || dimension == .sources {
                    Text(verbatim: "\(rankedItems.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink3)
                        .monospacedDigit()
                }
            }

            if dimension == .models && !hasModelDetail {
                Spacer(minLength: 0)
                Text("Hourly collection has no model breakdown")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(2)
                Spacer(minLength: 0)
            } else if topThree.isEmpty {
                Spacer(minLength: 0)
                Text(coverageKnown ? "No usage in this period" : "Hourly coverage is missing for this time")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(topThree) { item in
                        let itemColor = dimension == .models
                            ? (modelColors[item.id] ?? Palette.color(for: .output))
                            : Palette.color(forSource: item.id)
                        HStack(alignment: .center, spacing: 6) {
                            Circle()
                                .fill(itemColor)
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)

                            Text(verbatim: item.name)
                                .font(dimension == .models
                                    ? .system(size: 11, weight: .medium, design: .monospaced)
                                    : .system(size: 11.5, weight: .medium))
                                .foregroundStyle(Palette.ink1)
                                .lineLimit(1)
                                .truncationMode(dimension == .models ? .middle : .tail)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            LensMiniBar(
                                ratio: Double(item.counts.total) / Double(maxTokens),
                                color: itemColor
                            )
                            .frame(width: 42, height: 4)

                            Text(TokenFormat.short(item.counts.total))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.ink2)
                                .monospacedDigit()
                                .frame(minWidth: 42, alignment: .trailing)
                                .lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Right Column: Five-Category Composition Strip

    private var rightColumn: some View {
        let total = displayCounts.total
        let categories = TokenCategory.allCases

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Text("Composition")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                let reasoning = displayCounts[.reasoning]
                HStack(spacing: 4) {
                    Circle()
                        .fill(Palette.color(for: .reasoning))
                        .frame(width: 5.5, height: 5.5)
                        .accessibilityHidden(true)
                    Text(TokenCategory.reasoning.title)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(1)
                    Text(verbatim: reasoningKnown ? Share.percent(reasoning, of: total) : "-")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Palette.ink1)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }

            // Segmented horizontal strip across all 5 categories (+ uncategorized when present).
            GeometryReader { proxy in
                let width = proxy.size.width
                if total <= 0 {
                    Capsule()
                        .fill(Palette.barTrack)
                        .frame(width: width, height: 6)
                } else {
                    let uncategorizedColor = Palette.ink3.opacity(increasedContrast ? 0.80 : 0.45)
                    let activeParts: [(id: String, value: Int64, color: Color)] = categories.compactMap { cat in
                        let v = displayCounts[cat]
                        return v > 0 ? (cat.rawValue, v, Palette.color(for: cat)) : nil
                    } + (displayCounts.uncategorized > 0
                        ? [("uncategorized", displayCounts.uncategorized, uncategorizedColor)]
                        : [])
                    let gaps = CGFloat(max(0, activeParts.count - 1)) * 1.5
                    let usable = max(0, width - gaps)

                    HStack(spacing: 1.5) {
                        ForEach(activeParts, id: \.id) { part in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(part.color)
                                .frame(width: max(2, usable * CGFloat(part.value) / CGFloat(total)), height: 6)
                        }
                    }
                    .clipShape(Capsule())
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)

            // Compact 2x2 + reasoning legend for the 5 categories (+ uncategorized when present).
            let gridCategories: [TokenCategory] = [.input, .cacheRead, .cacheWrite, .output]
            let uncategorizedLegendColor = Palette.ink3.opacity(increasedContrast ? 0.80 : 0.45)
            let legendItems: [(id: String, title: LocalizedStringKey, color: Color, value: Int64)] =
                gridCategories.map { category in
                    (category.rawValue, category.title, Palette.color(for: category), displayCounts[category])
                } + (total > 0 && displayCounts.uncategorized > 0
                    ? [("uncategorized", LocalizedStringKey("Uncategorized"), uncategorizedLegendColor, displayCounts.uncategorized)]
                    : [])
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                alignment: .leading,
                spacing: 4
            ) {
                ForEach(legendItems, id: \.id) { item in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(item.color)
                            .frame(width: 5.5, height: 5.5)
                            .accessibilityHidden(true)
                        Text(item.title)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.ink2)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text(Share.percent(item.value, of: total))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Palette.ink1)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

private struct LensMiniBar: View {
    let ratio: Double
    let color: Color

    var body: some View {
        let clamped = min(max(ratio, 0), 1)
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let fillW = clamped > 0 ? max(h, w * CGFloat(clamped)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.barTrack)
                if fillW > 0 {
                    Capsule()
                        .fill(color)
                        .frame(width: min(w, fillW), height: h)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct LensReadoutSurface<S: InsettableShape>: ViewModifier {
    let reduceTransparency: Bool
    let isDark: Bool
    let increasedContrast: Bool
    let shape: S

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background { shape.fill(Palette.cardSurface) }
                .overlay { shape.strokeBorder(Palette.hairline, lineWidth: increasedContrast ? 1.5 : 1) }
        } else {
            let tintOpacity = isDark
                ? (increasedContrast ? 0.68 : 0.45)
                : (increasedContrast ? 0.65 : 0.38)
            content
                .background { shape.fill(Palette.cardSurface.opacity(tintOpacity)) }
                .glassEffect(.regular, in: shape)
                .overlay { shape.strokeBorder(Palette.hairline, lineWidth: increasedContrast ? 1.25 : 0.5) }
        }
    }
}

// MARK: - Localized Bucket & Range Date Formatting

private enum LensDateFormatter {
    static func singleBucketLabel(_ bucket: LensBucket, period: Period, locale: Locale) -> String {
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

    static func sliceLabel(
        slice: LensSlice,
        buckets: [LensBucket],
        period: Period,
        locale: Locale
    ) -> String {
        if slice.range.count == 1,
           slice.range.lowerBound >= 0,
           slice.range.lowerBound < buckets.count
        {
            return singleBucketLabel(buckets[slice.range.lowerBound], period: period, locale: locale)
        }

        switch period {
        case .day:
            return "\(hourMinute(slice.start))–\(hourMinute(slice.end))"
        case .week, .month:
            let endInclusive = slice.end.addingTimeInterval(-1)
            let startText = slice.start.formatted(.dateTime.locale(locale).month(.abbreviated).day())
            let sameMonth = Calendar.current.isDate(slice.start, equalTo: endInclusive, toGranularity: .month)
            let endText = sameMonth
                ? endInclusive.formatted(.dateTime.locale(locale).day())
                : endInclusive.formatted(.dateTime.locale(locale).month(.abbreviated).day())
            return "\(startText)–\(endText)"
        case .year, .all:
            let endInclusive = slice.end.addingTimeInterval(-1)
            let startText = slice.start.formatted(.dateTime.locale(locale).year().month(.abbreviated))
            let endText = endInclusive.formatted(.dateTime.locale(locale).year().month(.abbreviated))
            return "\(startText) – \(endText)"
        }
    }

    private static func hourMinute(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        let h = comps.hour ?? 0
        let m = comps.minute ?? 0
        return String(format: "%02d:%02d", h, m)
    }
}
