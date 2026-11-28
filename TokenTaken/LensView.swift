import AppKit
import SwiftUI
import TokenTakenKit

/// Liquid Glass Lens view: a dual-pass stacked time-bar chart with an interactive magnifier,
/// an on-demand slice overlay, and a bare whole-period composition strip.
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
    @State private var hoverPointCoalescer = LensHoverPointCoalescer()
    @State private var hoverCloseTask: Task<Void, Never>?
    @State private var isSliceOverlayHovered = false
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
    @State private var derivedDataCache = LensDerivedDataCache()
    @State private var layoutCache = LensBarLayoutCache()
    @State private var sliceCache = LensSliceCache()
    @State private var sliceOverlaySize: CGSize = .zero

    @FocusState private var isChartFocused: Bool

    private var canAnimate: Bool {
        appearsActive && controlActiveState == .key && windowVisible && !reduceMotion
    }

    private var derivedData: LensDerivedData {
        derivedDataCache.data(
            buckets: buckets,
            dimension: dimension,
            period: period,
            locale: locale
        )
    }

    private var pinnedRange: ClosedRange<Int>? {
        resolvedPinnedRange(maxNonFutureIndex: derivedData.maxNonFutureIndex)
    }

    private func resolvedPinnedRange(maxNonFutureIndex: Int?) -> ClosedRange<Int>? {
        guard let anchor = pinnedAnchor, let head = pinnedHead, !buckets.isEmpty else { return nil }
        let maxIdx = maxNonFutureIndex ?? (buckets.count - 1)
        let lo = min(max(0, min(anchor, head)), maxIdx)
        let hi = min(max(lo, max(anchor, head)), maxIdx)
        return lo...hi
    }

    private var maxNonFutureIndex: Int? {
        derivedData.maxNonFutureIndex
    }

    private var peakNonFutureIndex: Int? {
        derivedData.peakNonFutureIndex
    }

    /// Active slice range shown in the overlay; resting on the peak does not create a slice.
    private var activeSliceRange: ClosedRange<Int>? {
        resolvedActiveSliceRange(
            pinnedRange: pinnedRange,
            maxNonFutureIndex: derivedData.maxNonFutureIndex
        )
    }

    private func resolvedActiveSliceRange(
        pinnedRange: ClosedRange<Int>?,
        maxNonFutureIndex: Int?
    ) -> ClosedRange<Int>? {
        if let pinnedRange {
            return pinnedRange
        }
        if let hoverBucket, !releasedUntilMove, !buckets.isEmpty {
            let clamped = clampToNonFuture(hoverBucket, maxNonFutureIndex: maxNonFutureIndex)
            return clamped...clamped
        }
        return nil
    }

    /// Range where the visual lens sits (falls back to peak non-future bucket at rest when period has usage).
    private func visualLensRange(
        activeRange: ClosedRange<Int>?,
        derivedData: LensDerivedData
    ) -> ClosedRange<Int>? {
        if let activeRange {
            return activeRange
        }
        guard !releasedUntilMove,
              model.summary.total.total > 0 || derivedData.hasNonFutureUsage,
              let peak = derivedData.peakNonFutureIndex
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
        let resolvedDerivedData = derivedData
        VStack(alignment: .leading, spacing: 10) {
            timeBarStage(derivedData: resolvedDerivedData)
                .frame(maxWidth: .infinity, minHeight: 110, maxHeight: .infinity)

            DataHoverPopover(width: 280) {
                LensCompositionStrip(
                    counts: model.summary.total,
                    reasoningKnown: resolvedDerivedData.periodReasoningKnown,
                    increasedContrast: contrast == .increased,
                    height: 5
                )
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .center)
            } content: {
                LensCompositionDetails(
                    counts: model.summary.total,
                    reasoningKnown: resolvedDerivedData.periodReasoningKnown,
                    increasedContrast: contrast == .increased
                )
            }
            .accessibilityLabel(Text("Composition"))
            .accessibilityValue(Text("\(model.summary.total.total.formatted(.number.locale(locale))) tokens"))
            .accessibilityHint(Text("Shows composition details"))
        }
        .background {
            WindowVisibilityProbe { visible in
                windowVisible = visible
            }
        }
        .onChange(of: period) { _, _ in
            releasePin(snapImmediately: true)
        }
        .onChange(of: activeSliceRange) { _, newRange in
            if newRange == nil {
                sliceOverlaySize = .zero
            }
        }
        .onChange(of: buckets.count) { _, newCount in
            if newCount == 0 {
                releasePin(snapImmediately: true)
            } else if let anchor = pinnedAnchor, let head = pinnedHead {
                let maxIdx = resolvedDerivedData.maxNonFutureIndex ?? (newCount - 1)
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
        .onDisappear(perform: resetHover)
    }

    // MARK: - Time Bar Stage

    private func timeBarStage(derivedData: LensDerivedData) -> some View {
        let pinnedRange = resolvedPinnedRange(maxNonFutureIndex: derivedData.maxNonFutureIndex)
        let activeRange = resolvedActiveSliceRange(
            pinnedRange: pinnedRange,
            maxNonFutureIndex: derivedData.maxNonFutureIndex
        )
        return GeometryReader { proxy in
            let layout = layoutCache.layout(
                buckets: buckets,
                dimension: dimension,
                period: period,
                size: proxy.size,
                summarySources: model.summary.bySource,
                summaryModels: model.summary.byModel
            )
            let lensRange = visualLensRange(activeRange: activeRange, derivedData: derivedData)
            let activeSlice = activeRange.map(resolveSlice)
            let targetFrame = lensRange.map {
                targetLensMetrics(
                    for: $0,
                    in: layout,
                    isPinned: pinnedRange != nil,
                    hasActiveSlice: activeRange != nil
                )
            }
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
            let targetLensRect = targetFrame.map { target in
                let width = max(36, target.width)
                return CGRect(
                    x: target.centerX - width * 0.5,
                    y: lensCenterY - lensHeight * 0.5,
                    width: width,
                    height: lensHeight
                )
            }
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
                        activeRange: activeRange,
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
                    .opacity(activeRange == nil ? 0.25 : 0.82)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }

                // Pass 2: Magnified vector bars clipped inside the lens + refraction bevels and range sum.
                if showLens, let lensRange {
                    Canvas { context, _ in
                        drawMagnifiedPass(
                            in: &context,
                            layout: layout,
                            range: lensRange,
                            lensRect: lensRect,
                            lensCornerRadius: lensCornerRadius,
                            isPinned: pinnedRange != nil,
                            isResting: activeRange == nil,
                            isSettling: isSettling
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
                bucketAccessibilityOverlay(
                    layout: layout,
                    activeRange: activeRange,
                    descriptions: derivedData.accessibilityDescriptions
                )

                if showLens, let activeSlice {
                    let overlayWidth = min(280, max(1, proxy.size.width - 8))
                    let hasMeasuredSize = sliceOverlaySize.width > 0 && sliceOverlaySize.height > 0
                    let measuredSize = hasMeasuredSize
                        ? CGSize(width: min(sliceOverlaySize.width, overlayWidth), height: sliceOverlaySize.height)
                        : CGSize(width: overlayWidth, height: 200)
                    let origin = sliceOverlayOrigin(
                        lensRect: targetLensRect ?? lensRect,
                        overlaySize: measuredSize,
                        chartSize: proxy.size
                    )

                    LensSliceOverlay(
                        slice: activeSlice,
                        summary: model.summary,
                        period: period,
                        buckets: buckets,
                        dimension: dimension,
                        width: overlayWidth,
                        maxHeight: max(1, proxy.size.height - 8),
                        isPinned: pinnedRange != nil,
                        increasedContrast: contrast == .increased,
                        onRelease: { releasePin() }
                    )
                    .onGeometryChange(for: CGSize.self, of: \.size) { newSize in
                        if sliceOverlaySize != newSize {
                            sliceOverlaySize = newSize
                        }
                    }
                    .opacity(hasMeasuredSize ? 1 : 0)
                    .accessibilityHidden(!hasMeasuredSize)
                    .offset(x: origin.x, y: origin.y)
                    .allowsHitTesting(hasMeasuredSize && pinnedRange != nil)
                    .onHover { hovering in
                        guard pinnedRange != nil else {
                            isSliceOverlayHovered = false
                            return
                        }
                        isSliceOverlayHovered = hovering
                        if hovering {
                            cancelHoverClose()
                        } else {
                            scheduleHoverClose()
                        }
                    }
                    .onDisappear { isSliceOverlayHovered = false }
                    .zIndex(2)
                }
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
                    cancelHoverClose()
                    if releasedUntilMove, let origin = releaseOrigin {
                        if hypot(point.x - origin.x, point.y - origin.y) > 5 {
                            releasedUntilMove = false
                        }
                    }
                    let nextBucket = pinnedRange == nil && !isSliceOverlayHovered && !releasedUntilMove && !buckets.isEmpty
                        ? clampToNonFuture(
                            layout.bucketIndex(atX: point.x),
                            maxNonFutureIndex: derivedData.maxNonFutureIndex
                        )
                        : nil
                    if let nextBucket, hoverBucket != nextBucket {
                        hoverPointCoalescer.cancel()
                        hoverPoint = point
                        hoverBucket = nextBucket
                    } else {
                        hoverPointCoalescer.submit(point) { latestPoint in
                            hoverPoint = latestPoint
                        }
                    }
                case .ended:
                    hoverPointCoalescer.cancel()
                    hoverPoint = nil
                    releasedUntilMove = false
                    scheduleHoverClose()
                }
            }
            .gesture(chartDragGesture(
                layout: layout,
                currentLensRect: showLens ? lensRect : nil,
                maxNonFutureIndex: derivedData.maxNonFutureIndex
            ))
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

    private func sliceOverlayOrigin(
        lensRect: CGRect,
        overlaySize: CGSize,
        chartSize: CGSize
    ) -> CGPoint {
        let inset: CGFloat = 4
        let gap: CGFloat = 10
        let bounds = CGRect(
            x: inset,
            y: inset,
            width: max(0, chartSize.width - inset * 2),
            height: max(0, chartSize.height - inset * 2)
        )
        let fittedWidth = min(overlaySize.width, max(0, bounds.width))
        let fittedHeight = min(overlaySize.height, max(0, bounds.height))
        let maxX = max(bounds.minX, bounds.maxX - fittedWidth)
        let maxY = max(bounds.minY, bounds.maxY - fittedHeight)
        let aboveY = lensRect.minY - gap - overlaySize.height
        let preferredY = aboveY >= bounds.minY ? aboveY : lensRect.maxY + gap
        return CGPoint(
            x: min(max(lensRect.midX - fittedWidth * 0.5, bounds.minX), maxX),
            y: min(max(preferredY, bounds.minY), maxY)
        )
    }

    // MARK: - Target Geometry & Physics

    private struct LensTargetMetrics: Equatable {
        let centerX: CGFloat
        let width: CGFloat
    }

    private func targetLensMetrics(
        for range: ClosedRange<Int>,
        in layout: LensBarLayout,
        isPinned: Bool,
        hasActiveSlice: Bool
    ) -> LensTargetMetrics {
        let base = layout.lensBounds(for: range)
        var cx = base.centerX
        if !isPinned, hasActiveSlice, let hoverPoint, range.count == 1 {
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
        clampToNonFuture(index, maxNonFutureIndex: maxNonFutureIndex)
    }

    private func clampToNonFuture(_ index: Int, maxNonFutureIndex: Int?) -> Int {
        guard !buckets.isEmpty else { return 0 }
        let limit = maxNonFutureIndex ?? (buckets.count - 1)
        return min(max(0, index), limit)
    }

    private func scheduleHoverClose() {
        cancelHoverClose()
        hoverCloseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            hoverCloseTask = nil
            guard pinnedRange == nil, hoverPoint == nil, !isSliceOverlayHovered else { return }
            hoverBucket = nil
        }
    }

    private func cancelHoverClose() {
        hoverCloseTask?.cancel()
        hoverCloseTask = nil
    }

    private func resetHover() {
        cancelHoverClose()
        hoverPointCoalescer.cancel()
        hoverBucket = nil
        hoverPoint = nil
        isSliceOverlayHovered = false
        releasedUntilMove = false
        releaseOrigin = nil
    }

    private func releasePin(snapImmediately: Bool = false) {
        cancelHoverClose()
        hoverPointCoalescer.flush()
        isSliceOverlayHovered = false
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

    private func chartDragGesture(
        layout: LensBarLayout,
        currentLensRect: CGRect?,
        maxNonFutureIndex: Int?
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !buckets.isEmpty, maxNonFutureIndex != nil else { return }
                let startPt = value.startLocation
                let curPt = value.location
                hoverPointCoalescer.cancel()
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
                            let startBucket = clampToNonFuture(
                                layout.bucketIndex(atX: startPt.x),
                                maxNonFutureIndex: maxNonFutureIndex
                            )
                            dragMode = .brush(startBucket: startBucket)
                        }
                    } else {
                        let startBucket = clampToNonFuture(
                            layout.bucketIndex(atX: startPt.x),
                            maxNonFutureIndex: maxNonFutureIndex
                        )
                        dragMode = .brush(startBucket: startBucket)
                    }
                }

                let movedDistance = abs(curPt.x - startPt.x)
                if movedDistance > 4 {
                    didDrag = true
                }

                let currentBucket = clampToNonFuture(
                    layout.bucketIndex(atX: curPt.x),
                    maxNonFutureIndex: maxNonFutureIndex
                )
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
                        let target = clampToNonFuture(
                            layout.bucketIndex(atX: value.location.x),
                            maxNonFutureIndex: maxNonFutureIndex
                        )
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

        for value in layout.yAxisValues {
            let fraction = CGFloat(value / layout.yMax)
            let y = (plot.maxY - plot.height * fraction).rounded() + 0.5
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(gridColor), lineWidth: increased ? 1.2 : 1.0)

            if !layout.isEmpty {
                let tickValue = value == 0
                    ? "0"
                    : LensBarLayout.axisLabel(value, step: layout.yAxisStep, upperBound: layout.yMax)
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

            for bar in layout.bars {
                let isSelected = activeRange?.contains(bar.index) == true
                let opacity: Double
                if activeRange == nil {
                    opacity = increased ? 0.68 : (isDark ? 0.48 : 0.58)
                } else if isSelected {
                    opacity = increased ? 0.96 : 0.86
                } else {
                    opacity = increased ? 0.44 : (isDark ? 0.26 : 0.30)
                }
                drawBucketBar(
                    in: &layer,
                    bar: bar,
                    plotRect: plot,
                    yMax: layout.yMax,
                    centerX: bar.slotCenterX,
                    barWidth: bar.baseBarWidth,
                    verticalScale: 1.0,
                    opacity: opacity,
                    isHighlighted: isSelected,
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
        isResting: Bool,
        isSettling: Bool
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
                let interiorColors: [Color] = if isDark {
                    [Color(hex: "#3A4C70").opacity(0.20), Color(hex: "#121826").opacity(0.26)]
                } else if isRange {
                    [Color.white.opacity(0.36), Color(hex: "#EBF2FF").opacity(0.18)]
                } else {
                    [Color.white.opacity(0.12), Color(hex: "#EBF2FF").opacity(0.06)]
                }
                mag.fill(
                    Path(lensRect),
                    with: .linearGradient(
                        Gradient(colors: interiorColors),
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
            for value in layout.yAxisValues {
                let gy = plot.maxY - (plot.height * CGFloat(value / layout.yMax)) * gridMag
                guard gy >= lensRect.minY - 4 else { continue }
                var curve = Path()
                curve.move(to: CGPoint(x: lensRect.minX - 4, y: gy))
                curve.addQuadCurve(
                    to: CGPoint(x: lensRect.maxX + 4, y: gy),
                    control: CGPoint(x: lensCx, y: gy + (value == 0 ? 0 : -1.2))
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

                let barOpacity = inRange || isResting ? 0.96 : (increased ? 0.62 : 0.44)
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
                        if !isSettling, plot.maxY - topY > 2, topY > lensRect.minY + 12 {
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
                            Gradient(colors: [.clear, Color.white.opacity(isDark ? 0.08 : 0.12)]),
                            center: CGPoint(x: lensCx, y: lensRect.midY),
                            startRadius: min(lensRect.width, lensRect.height) * 0.28,
                            endRadius: maxDim * 0.68
                        )
                    )
                }

                let sheenRect = CGRect(x: lensRect.minX, y: lensRect.minY, width: lensRect.width, height: 24)
                let sheenOpacity = isRange ? (isDark ? 0.16 : 0.36) : (isDark ? 0.08 : 0.14)
                mag.fill(
                    Path(sheenRect),
                    with: .linearGradient(
                        Gradient(colors: [Color.white.opacity(sheenOpacity), .clear]),
                        startPoint: CGPoint(x: lensCx, y: sheenRect.minY),
                        endPoint: CGPoint(x: lensCx, y: sheenRect.maxY)
                    )
                )
            }
        }

        // Lens border: 2pt roleAccent under Reduce Transparency; dark-only dispersion & rim otherwise.
        if reduceTransparency {
            context.stroke(lensPath, with: .color(Palette.roleAccent), lineWidth: 2)
        } else {
            if isDark {
                context.stroke(
                    lensPath.offsetBy(dx: 1.0, dy: 0),
                    with: .color(Color(.sRGB, red: 1.0, green: 0.36, blue: 0.55, opacity: 0.22)),
                    lineWidth: 1.0
                )
                context.stroke(
                    lensPath.offsetBy(dx: -1.0, dy: 0),
                    with: .color(Color(.sRGB, red: 0.30, green: 0.65, blue: 1.0, opacity: 0.24)),
                    lineWidth: 1.0
                )
            }

            let rimStroke: Color = if isPinned {
                Palette.roleAccent.opacity(increased ? (isDark ? 0.95 : 0.88) : (isDark ? 0.78 : 0.58))
            } else if increased {
                isDark ? Color.white.opacity(0.65) : Palette.ink1.opacity(0.55)
            } else {
                Color.white.opacity(isDark ? (isResting ? 0.28 : 0.38) : (isResting ? 0.48 : 0.72))
            }
            context.stroke(
                lensPath,
                with: .color(rimStroke),
                lineWidth: increased ? 1.6 : (isPinned ? 1.5 : 1.15)
            )
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

    private func bucketAccessibilityOverlay(
        layout: LensBarLayout,
        activeRange: ClosedRange<Int>?,
        descriptions: [String]
    ) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.bars) { bar in
                let bucket = buckets[bar.index]
                let isSelected = activeRange?.contains(bar.index) == true
                let element = Color.clear
                    .frame(width: max(4, layout.slotWidth), height: max(20, layout.plotRect.height))
                    .offset(x: bar.slotRect.minX, y: layout.plotRect.minY)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: descriptions[bar.index]))
                if bucket.isFuture {
                    element
                } else {
                    element
                        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction {
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
    }
}

// MARK: - Pure-Value Bar Layout

private struct LensDerivedData {
    let maxNonFutureIndex: Int?
    let peakNonFutureIndex: Int?
    let hasNonFutureUsage: Bool
    let periodReasoningKnown: Bool
    let accessibilityDescriptions: [String]
}

@MainActor
private final class LensHoverPointCoalescer {
    private var pending: (point: CGPoint, apply: (CGPoint) -> Void)?
    private var task: Task<Void, Never>?

    func submit(_ point: CGPoint, apply: @escaping (CGPoint) -> Void) {
        pending = (point, apply)
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        task?.cancel()
        task = nil
        guard let pending else { return }
        self.pending = nil
        pending.apply(pending.point)
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }
}

@MainActor
private final class LensDerivedDataCache {
    private struct Key: Equatable {
        let buckets: [LensBucket]
        let dimension: BreakdownDimension
        let period: Period
        let locale: Locale
        let calendar: Calendar
        let timeZone: TimeZone
    }

    private var cachedKey: Key?
    private var cachedData: LensDerivedData?

    func data(
        buckets: [LensBucket],
        dimension: BreakdownDimension,
        period: Period,
        locale: Locale
    ) -> LensDerivedData {
        let key = Key(
            buckets: buckets,
            dimension: dimension,
            period: period,
            locale: locale,
            calendar: .current,
            timeZone: .current
        )
        if let cachedData, cachedKey == key {
            return cachedData
        }

        var maxNonFutureIndex: Int?
        var peakNonFutureIndex: Int?
        var peakTotal: Int64 = -1
        var hasNonFutureUsage = false
        var periodReasoningKnown = true
        for (index, bucket) in buckets.enumerated() where !bucket.isFuture {
            maxNonFutureIndex = index
            if bucket.total > peakTotal {
                peakTotal = bucket.total
                peakNonFutureIndex = index
            }
            hasNonFutureUsage = hasNonFutureUsage || bucket.total > 0
            periodReasoningKnown = periodReasoningKnown && bucket.reasoningKnown
        }

        let resolved = LensDerivedData(
            maxNonFutureIndex: maxNonFutureIndex,
            peakNonFutureIndex: peakNonFutureIndex,
            hasNonFutureUsage: hasNonFutureUsage,
            periodReasoningKnown: periodReasoningKnown,
            accessibilityDescriptions: buckets.map {
                accessibilityDescription(
                    for: $0,
                    dimension: dimension,
                    period: period,
                    locale: locale
                )
            }
        )
        cachedKey = key
        cachedData = resolved
        return resolved
    }

    private func accessibilityDescription(
        for bucket: LensBucket,
        dimension: BreakdownDimension,
        period: Period,
        locale: Locale
    ) -> String {
        let timeLabel = LensDateFormatter.singleBucketLabel(bucket, period: period, locale: locale)
        if bucket.isFuture {
            return String(localized: "\(timeLabel), upcoming", locale: locale)
        }
        if !bucket.isKnown && bucket.total <= 0 {
            return String(localized: "\(timeLabel), missing hourly coverage", locale: locale)
        }
        let spokenTokens = bucket.total.formatted(.number.locale(locale))
        let coverageNote = bucket.isKnown ? "" : ", \(String(localized: "Partial hourly coverage", locale: locale))"
        let topNames = topBucketNames(for: bucket, dimension: dimension)
        if topNames.isEmpty {
            return String(localized: "\(timeLabel), \(spokenTokens) tokens", locale: locale) + coverageNote
        }
        let joined = topNames.joined(separator: locale.language.languageCode == .chinese ? "、" : ", ")
        return String(localized: "\(timeLabel), \(spokenTokens) tokens, top: \(joined)", locale: locale) + coverageNote
    }

    private func topBucketNames(for bucket: LensBucket, dimension: BreakdownDimension) -> [String] {
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
    let yAxisStep: Double
    let yAxisValues: [Double]
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
        let axis = Self.axisScale(for: Double(max(1, maxRaw)) * Double(Self.singleMagnification) * 1.08)
        self.yMax = axis.upperBound
        self.yAxisStep = axis.step
        self.yAxisValues = axis.values

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

    private static func axisScale(for target: Double) -> (upperBound: Double, step: Double, values: [Double]) {
        guard target > 4, target.isFinite else {
            return (4, 1, [0, 1, 2, 3, 4])
        }

        let desiredStep = target / 4
        let base = pow(10, floor(log10(desiredStep)))
        let normalized = desiredStep / base
        let multipliers = [1.0, 2.0, 2.5, 5.0, 10.0]
        let multiplier = multipliers.first(where: { $0 >= normalized }) ?? 10
        let step = max(1, multiplier * base)
        let upperBound = ceil(target / step - 0.000_000_001) * step
        let count = max(1, Int((upperBound / step).rounded()))
        return (upperBound, step, (0...count).map { Double($0) * step })
    }

    static func axisLabel(_ value: Double, step: Double, upperBound: Double) -> String {
        guard value.isFinite, abs(value) >= 0.5 else { return "0" }

        let divisor: Double
        let suffix: String
        switch TokenFormat.unitStyle {
        case .international:
            if upperBound >= 1_000_000_000 {
                (divisor, suffix) = (1_000_000_000, "B")
            } else if upperBound >= 1_000_000 {
                (divisor, suffix) = (1_000_000, "M")
            } else if upperBound >= 1_000 {
                (divisor, suffix) = (1_000, "K")
            } else {
                (divisor, suffix) = (1, "")
            }
        case .chinese:
            if upperBound >= 1_000_000_000_000 {
                (divisor, suffix) = (1_000_000_000_000, "万亿")
            } else if upperBound >= 100_000_000 {
                (divisor, suffix) = (100_000_000, "亿")
            } else if upperBound >= 10_000 {
                (divisor, suffix) = (10_000, "万")
            } else {
                (divisor, suffix) = (1, "")
            }
        }

        let scaledStep = step / divisor
        var fractionDigits = 0
        while fractionDigits < 3 {
            let factor = pow(10, Double(fractionDigits))
            if abs(scaledStep * factor - (scaledStep * factor).rounded()) < 0.000_001 {
                break
            }
            fractionDigits += 1
        }
        let scaled = value / divisor
        let number = scaled.formatted(
            .number
                .precision(.fractionLength(fractionDigits))
                .grouping(.automatic)
                .locale(Locale(identifier: "en_US_POSIX"))
        )
        return number + suffix
    }
}

// MARK: - Slice Overlay

private struct LensSliceOverlay: View {
    let slice: LensSlice
    let summary: UsageSummary
    let period: Period
    let buckets: [LensBucket]
    let dimension: BreakdownDimension
    let width: CGFloat
    let maxHeight: CGFloat
    let isPinned: Bool
    let increasedContrast: Bool
    let onRelease: () -> Void

    @Environment(\.locale) private var locale

    private var displayCounts: TokenCounts {
        slice.counts
    }

    private var displayTotal: Int64 {
        displayCounts.total
    }

    /// False when the selection includes an elapsed bucket without full coverage: zero is then unknown.
    private var coverageKnown: Bool {
        slice.isKnown
    }

    private var reasoningKnown: Bool {
        slice.reasoningKnown
    }

    private var displayCost: CostEstimate? {
        slice.cost
    }

    private var hasModelDetail: Bool {
        slice.hasModelDetail
    }

    private var rankedItems: [Breakdown] {
        let raw = dimension == .sources ? slice.bySource : slice.byModel
        return raw.filter { $0.counts.total > 0 }
    }

    var body: some View {
        DataHoverCard(width: width) {
            ViewThatFits(in: .vertical) {
                sliceContent
                ScrollView {
                    sliceContent
                }
            }
        }
        .frame(maxHeight: maxHeight)
    }

    private var sliceContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            summarySection
            rankingSection
            DataHoverPopover(width: min(width, 280)) {
                LensCompositionStrip(
                    counts: displayCounts,
                    reasoningKnown: reasoningKnown,
                    increasedContrast: increasedContrast,
                    height: 4
                )
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .center)
            } content: {
                LensCompositionDetails(
                    counts: displayCounts,
                    reasoningKnown: reasoningKnown,
                    increasedContrast: increasedContrast
                )
            }
            .accessibilityLabel(Text("Composition"))
            .accessibilityValue(Text("\(displayTotal.formatted(.number.locale(locale))) tokens"))
            .accessibilityHint(Text("Shows composition details"))
        }
    }

    // MARK: Time Range, Total Tokens, Share of Period, Cost

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                timeRangeLabel
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.roleAccent)
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
                    .keyboardShortcut(.cancelAction)
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
                        Text("\(Share.percent(displayTotal, of: summary.total.total, locale: locale)) of period")
                    } else {
                        Text("Partial hourly coverage")
                    }
                }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.roleAccent)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.top, 4)

            let exactTotal = !coverageKnown && displayTotal == 0
                ? "-"
                : displayTotal.formatted(.number.locale(locale))
            Text("\(exactTotal) tokens")
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink3)
                .monospacedDigit()
                .lineLimit(1)
                .padding(.top, 2)

            Color.clear.frame(height: 8)

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
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.ink2)
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
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            if let displayCost {
                VStack(alignment: .leading, spacing: 3) {
                    Text("estimate, not a bill")
                    Text("Price table \(displayCost.priceTableVersion)")
                }
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var timeRangeLabel: some View {
        Text(verbatim: LensDateFormatter.sliceLabel(
            slice: slice,
            buckets: buckets,
            period: period,
            locale: locale
        ))
    }

    // MARK: Top 3 in Current Dimension

    private var rankingSection: some View {
        let topThree = Array(rankedItems.prefix(3))
        let modelColors = dimension == .models
            ? Palette.modelColors(for: summary.byModel.map(\.id) + topThree.map(\.id))
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
                Text("Hourly collection has no model breakdown")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(2)
            } else if topThree.isEmpty {
                Text(coverageKnown ? "No usage in this period" : "Hourly coverage is missing for this time")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(1)
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
            }
        }
    }
}

private struct LensCompositionStrip: View {
    let counts: TokenCounts
    let reasoningKnown: Bool
    let increasedContrast: Bool
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let total = counts.total
            if total <= 0 {
                Capsule()
                    .fill(Palette.barTrack)
                    .frame(width: proxy.size.width, height: height)
            } else {
                let uncategorizedColor = Palette.ink3.opacity(increasedContrast ? 0.80 : 0.45)
                let parts: [(id: String, value: Int64, color: Color)] =
                    TokenCategory.allCases.compactMap { category in
                        let value = counts[category]
                        guard value > 0 else { return nil }
                        let isKnown = category != .reasoning || reasoningKnown
                        let color = Palette.color(for: category).opacity(isKnown ? 1 : 0.42)
                        return (category.rawValue, value, color)
                    } + (counts.uncategorized > 0
                        ? [("uncategorized", counts.uncategorized, uncategorizedColor)]
                        : [])
                let gap: CGFloat = 1
                let gaps = CGFloat(max(0, parts.count - 1)) * gap
                let usable = max(0, proxy.size.width - gaps)

                HStack(spacing: gap) {
                    ForEach(parts, id: \.id) { part in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(part.color)
                            .frame(
                                width: max(1, usable * CGFloat(part.value) / CGFloat(total)),
                                height: height
                            )
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct LensCompositionDetails: View {
    let counts: TokenCounts
    let reasoningKnown: Bool
    let increasedContrast: Bool

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(TokenCategory.allCases) { category in
                row(
                    title: category.title,
                    value: counts[category],
                    color: Palette.color(for: category),
                    isKnown: category != .reasoning || reasoningKnown
                )
            }
            if counts.uncategorized > 0 {
                row(
                    title: "Uncategorized",
                    value: counts.uncategorized,
                    color: Palette.ink3.opacity(increasedContrast ? 0.80 : 0.45),
                    isKnown: true
                )
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func row(
        title: LocalizedStringKey,
        value: Int64,
        color: Color,
        isKnown: Bool
    ) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
            Spacer(minLength: 6)
            Group {
                if isKnown {
                    Text(verbatim: value.formatted(.number.locale(locale)))
                } else {
                    Text("Unavailable")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.ink1)
            .monospacedDigit()
            .lineLimit(1)
            Text(verbatim: isKnown ? Share.percent(value, of: counts.total, locale: locale) : "-")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.ink2)
                .monospacedDigit()
                .frame(width: 46, alignment: .trailing)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
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
