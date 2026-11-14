import AppKit
import QuartzCore
import SwiftUI
import TokenTakenKit

enum BreakdownDimension: Hashable, CaseIterable { case sources, models }

/// Sources or models flow into a glass reservoir and back out through the token categories.
/// All token-to-geometry rules live in `ConfluenceLayout`; only labels and glass are native views.
struct ConfluenceView: View {
    let summary: UsageSummary
    let dimension: BreakdownDimension

    init(summary: UsageSummary, dimension: BreakdownDimension = .sources) {
        self.summary = summary
        self.dimension = dimension
    }

    @Environment(AppSettings.self) private var settings: AppSettings?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Closed or background windows keep their views alive; animate only while the window is active.
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    @State private var hover: ConfluenceHover?
    /// Particles follow the final geometry, so they are hidden while the ribbons spring to new values.
    @State private var particlesSettled = true
    /// Values the scene last settled on; nil until the first mount has run.
    @State private var settledValues: ConfluenceValues?
    @FocusState private var focused: ConfluenceTarget?

    private let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)

    var body: some View {
        let isLiquidGlass = settings.map { $0.theme == .liquidGlass }
            ?? (!ThemeRuntime.isField && !ThemeRuntime.isCosmos)
        let vesselBodyStyle: LiquidGlassVessel.BodyStyle = isLiquidGlass ? .prismatic : .solid

        GeometryReader { proxy in
            let layout = ConfluenceLayout(summary: summary, dimension: dimension, size: proxy.size)
            let rawTarget = hover?.target ?? focused
            let activeTarget = rawTarget.flatMap { layout.stream(for: $0) != nil ? $0 : nil }
            let values = layout.animationValues
            let particleTracks = layout.particleTracks(
                activeTarget: activeTarget,
                reduceMotion: reduceMotion,
                reduceTransparency: reduceTransparency
            )
            let tooltip = hover.map { ($0.target, $0.location) }
                ?? focused.flatMap { target in
                    layout.stream(for: target).map { (target, focusAnchor(for: $0)) }
                }

            ZStack(alignment: .topLeading) {
                ConfluenceScene(
                    layout: layout,
                    values: values,
                    activeTarget: activeTarget,
                    isDark: scheme == .dark,
                    reduceTransparency: reduceTransparency,
                    vesselBodyStyle: vesselBodyStyle,
                    focused: $focused
                )
                // A refresh that leaves the displayed values unchanged gets no spring.
                .animation(
                    reduceMotion || values == settledValues ? nil : .spring(response: 0.35, dampingFraction: 0.8),
                    value: values
                )

                if !reduceMotion && !reduceTransparency {
                    ConfluenceParticleLayer(
                        tracks: particleTracks,
                        isActive: appearsActive
                    )
                    .opacity(particlesSettled ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: particlesSettled)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }

                if let tooltip, let stream = layout.stream(for: tooltip.0) {
                    ConfluenceTooltip(stream: stream, total: layout.totalTokens)
                        .fixedSize()
                        .offset(tooltipOffset(for: tooltip.1, in: proxy.size))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            // Particles follow the final geometry, so hide them only while a real value change springs.
            // First mount and unchanged refreshes keep them visible (no fade, no group-opacity pass).
            .task(id: values) {
                guard !reduceMotion, let previous = settledValues, previous != values else {
                    settledValues = values
                    particlesSettled = true
                    return
                }
                particlesSettled = false
                // The 0.35 spring settles in ~0.32s; hold the specks 150ms longer so they return
                // once the ribbons have stopped, counted from the change rather than a restart.
                try? await Task.sleep(for: .milliseconds(470))
                guard !Task.isCancelled else { return }
                settledValues = values
                particlesSettled = true
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            dimension == .sources
                ? Text("Confluence of harnesses into categories")
                : Text("Confluence of models into categories")
        )
    }

    /// Keyboard focus has no pointer location; anchor the tooltip beside the focused label, toward the chart.
    private func focusAnchor(for stream: ConfluenceLayout.Stream) -> CGPoint {
        let frame = stream.labelFrame
        return stream.side == .source
            ? CGPoint(x: frame.maxX, y: frame.minY)
            : CGPoint(x: frame.minX - Self.tooltipWidth - 28, y: frame.minY)
    }

    private static let tooltipWidth: CGFloat = 210

    private func tooltipOffset(for point: CGPoint, in size: CGSize) -> CGSize {
        let width = Self.tooltipWidth, height: CGFloat = 66
        let pad: CGFloat = 12
        let x = min(point.x + 14, size.width - width - pad)
        let y = point.y + 16 + height > size.height - pad ? point.y - height - 10 : point.y + 16
        return CGSize(width: max(pad, x), height: max(pad, y))
    }
}

private struct ConfluenceHover: Equatable {
    var target: ConfluenceTarget
    var location: CGPoint
}

private enum ConfluenceTarget: Hashable {
    case source(String)
    case model(String)
    case category(TokenCategory)

    var id: String {
        switch self {
        case .source(let id): "source:\(id)"
        case .model(let id): "model:\(id)"
        case .category(let category): "category:\(category.rawValue)"
        }
    }
}

// MARK: - Static scene

private struct ConfluenceScene: View, @MainActor Animatable {
    let layout: ConfluenceLayout
    var values: ConfluenceValues
    let activeTarget: ConfluenceTarget?
    let isDark: Bool
    let reduceTransparency: Bool
    let vesselBodyStyle: LiquidGlassVessel.BodyStyle
    var focused: FocusState<ConfluenceTarget?>.Binding

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.controlActiveState) private var controlActiveState

    var animatableData: ConfluenceValues {
        get { values }
        set { values = newValue }
    }

    var body: some View {
        let current = layout.interpolated(with: values)
        let wobbleActive = controlActiveState == .key
            && appearsActive
            && !reduceMotion
            && !reduceTransparency
            && !current.isEmpty

        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                ConfluenceRenderer(
                    layout: current,
                    activeTarget: activeTarget,
                    isDark: isDark,
                    reduceTransparency: reduceTransparency,
                    vesselBodyStyle: vesselBodyStyle
                )
                .drawStreamsAndLeaders(in: &context)
            }
            .accessibilityHidden(true)

            if wobbleActive {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
                    vesselCanvas(
                        current: current,
                        wobblePhase: timeline.date.timeIntervalSinceReferenceDate / 6.0
                    )
                }
            } else {
                vesselCanvas(current: current, wobblePhase: nil)
            }

            streamGroup(.source, streams: current.sources, in: current)
            streamGroup(.category, streams: current.categories, in: current)

            if current.isEmpty {
                Text("No usage in this period")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink3)
                    .position(x: current.reservoir.midX, y: current.reservoir.midY)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: activeTarget)
    }

    private func vesselCanvas(current: ConfluenceLayout, wobblePhase: Double?) -> some View {
        let padX: CGFloat = 12
        let padTop: CGFloat = 8
        let padBottom: CGFloat = 24
        let canvasRect = CGRect(
            x: current.reservoir.minX - padX,
            y: current.reservoir.minY - padTop,
            width: current.reservoir.width + padX * 2,
            height: current.reservoir.height + padTop + padBottom
        )
        return Canvas { context, _ in
            var shifted = context
            shifted.translateBy(x: -canvasRect.minX, y: -canvasRect.minY)
            ConfluenceRenderer(
                layout: current,
                activeTarget: activeTarget,
                isDark: isDark,
                reduceTransparency: reduceTransparency,
                vesselBodyStyle: vesselBodyStyle
            )
            .drawVessel(in: &shifted, wobblePhase: wobblePhase)
        }
        .frame(width: canvasRect.width, height: canvasRect.height)
        .offset(x: canvasRect.minX, y: canvasRect.minY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One VoiceOver group per side, named by its heading; chart chrome is hidden when the period is empty.
    private func streamGroup(
        _ side: ConfluenceLayout.Side,
        streams: [ConfluenceLayout.Stream],
        in current: ConfluenceLayout
    ) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(streams) { stream in
                ConfluenceStreamLabel(
                    stream: stream,
                    total: current.totalTokens,
                    activeTarget: activeTarget,
                    isDark: isDark,
                    focused: focused
                )
                // Switching dimension replaces every label id; a fade keeps SwiftUI from running
                // an insert/remove transition for each of them inside the switch transaction.
                .transition(.opacity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            side == .source
                ? (current.dimension == .sources ? Text("Harnesses") : Text("Models"))
                : Text("Categories")
        )
        .accessibilityAddTraits(.isHeader)
        .accessibilityHidden(current.isEmpty)
    }
}

// MARK: - Particles

private struct ConfluenceParticleSample: Equatable {
    let point: CGPoint
    let distance: CGFloat
}

private struct ConfluenceParticleSpec: Equatable {
    let samples: [ConfluenceParticleSample]
    let length: CGFloat
    let phaseOffset: Double
    let radius: CGFloat
}

private struct ConfluenceParticleTrack: Equatable {
    let id: String
    let particles: [ConfluenceParticleSpec]
    let speed: Double
    let color: Color
    let isDimmed: Bool
}

private struct ConfluenceParticleLayer: NSViewRepresentable {
    let tracks: [ConfluenceParticleTrack]
    let isActive: Bool

    func makeNSView(context: Context) -> ConfluenceParticleView {
        let view = ConfluenceParticleView(frame: .zero)
        view.updateTracks(tracks)
        view.isActive = isActive
        return view
    }

    func updateNSView(_ view: ConfluenceParticleView, context: Context) {
        if view.tracks != tracks {
            view.updateTracks(tracks)
        }
        view.isActive = isActive
    }
}

private final class ConfluenceParticleView: NSView {
    private(set) var tracks: [ConfluenceParticleTrack] = []
    var isActive = true {
        didSet {
            if oldValue != isActive { updatePlayback() }
        }
    }

    private var trackLayers: [String: CALayer] = [:]
    private var paused = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isGeometryFlipped = true
        layer?.masksToBounds = true
        // Particles barely overlap, so per-particle opacity looks the same as group opacity
        // and avoids an offscreen pass over sublayers whenever the host fades.
        layer?.allowsGroupOpacity = false
        updateContentsScale()
        updatePlayback()
    }

    required init?(coder: NSCoder) {
        fatalError("Unsupported initializer")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowOcclusionDidChange(_:)),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
        }
        updateContentsScale()
        updatePlayback()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    @objc private func windowOcclusionDidChange(_ notification: Notification) {
        updatePlayback()
    }

    func updateTracks(_ tracks: [ConfluenceParticleTrack]) {
        let previous = Dictionary(uniqueKeysWithValues: self.tracks.map { ($0.id, $0) })
        let identifiers = Set(tracks.map(\.id))
        let staleIdentifiers = trackLayers.keys.filter { !identifiers.contains($0) }
        for identifier in staleIdentifiers {
            trackLayers[identifier]?.removeFromSuperlayer()
            trackLayers.removeValue(forKey: identifier)
        }

        for track in tracks {
            if let existing = trackLayers[track.id], let old = previous[track.id] {
                let geometryChanged = old.particles != track.particles || old.speed != track.speed
                // Reuse the track's layers; only retarget their paths when the geometry moved.
                if !geometryChanged || configureParticles(of: existing, for: track) {
                    applyAppearance(track, to: existing, animated: !geometryChanged)
                    continue
                }
            }
            trackLayers[track.id]?.removeFromSuperlayer()
            trackLayers.removeValue(forKey: track.id)
            guard let trackLayer = makeTrackLayer(for: track) else { continue }
            trackLayers[track.id] = trackLayer
            applyAppearance(track, to: trackLayer, animated: false)
        }
        self.tracks = tracks
    }

    private func makeTrackLayer(for track: ConfluenceParticleTrack) -> CALayer? {
        guard let root = layer else { return nil }
        let trackLayer = CALayer()
        trackLayer.frame = root.bounds
        trackLayer.contentsScale = backingScale
        trackLayer.allowsGroupOpacity = false
        guard configureParticles(of: trackLayer, for: track) else { return nil }
        root.addSublayer(trackLayer)
        return trackLayer
    }

    private func configureParticles(of trackLayer: CALayer, for track: ConfluenceParticleTrack) -> Bool {
        guard !track.particles.isEmpty, track.speed > 0 else { return false }
        let count = track.particles.count

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var layers = trackLayer.sublayers ?? []
        while layers.count > count {
            layers.removeLast().removeFromSuperlayer()
        }
        while layers.count < count {
            let particle = CALayer()
            particle.contentsScale = backingScale
            trackLayer.addSublayer(particle)
            layers.append(particle)
        }
        for (index, spec) in track.particles.enumerated() {
            guard let first = spec.samples.first, spec.length > 0 else { continue }
            let path = CGMutablePath()
            path.move(to: first.point)
            for sample in spec.samples.dropFirst() {
                path.addLine(to: sample.point)
            }

            let diameter = spec.radius * 2
            let duration = Double(spec.length) / track.speed
            let particle = layers[index]
            particle.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            particle.position = first.point
            particle.cornerRadius = spec.radius

            let animation = CAKeyframeAnimation(keyPath: "position")
            animation.path = path
            animation.calculationMode = .paced
            animation.repeatCount = .infinity
            animation.duration = duration
            animation.timeOffset = spec.phaseOffset * duration
            particle.add(animation, forKey: "confluence.flow")
        }
        CATransaction.commit()
        return true
    }

    private func applyAppearance(_ track: ConfluenceParticleTrack, to trackLayer: CALayer, animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setDisableActions(!animated)
        trackLayer.opacity = track.isDimmed ? 0 : 1
        let color = NSColor(track.color).cgColor
        for particle in trackLayer.sublayers ?? [] {
            particle.backgroundColor = color
        }
        CATransaction.commit()
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func updateContentsScale() {
        let scale = backingScale
        layer?.contentsScale = scale
        for trackLayer in trackLayers.values {
            trackLayer.contentsScale = scale
            for particle in trackLayer.sublayers ?? [] {
                particle.contentsScale = scale
            }
        }
    }

    private func updatePlayback() {
        let windowVisible = window?.occlusionState.contains(.visible) == true
        let shouldPause = !isActive || !windowVisible
        guard shouldPause != paused, let layer else { return }
        paused = shouldPause

        if shouldPause {
            let pausedTime = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
            layer.timeOffset = pausedTime
        } else {
            let pausedTime = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        }
    }
}

// MARK: - Native labels and glass

private struct ConfluenceStreamLabel: View {
    let stream: ConfluenceLayout.Stream
    let total: Int64
    let activeTarget: ConfluenceTarget?
    let isDark: Bool
    var focused: FocusState<ConfluenceTarget?>.Binding

    private var highlighted: Bool { activeTarget == stream.target }
    private var dimmed: Bool { activeTarget != nil && !highlighted }

    var body: some View {
        Group {
            switch stream.side {
            case .source:
                sourceLane
            case .category:
                categoryChip
            }
        }
        .frame(width: stream.labelFrame.width, height: stream.labelFrame.height)
        .contentShape(Rectangle())
        .position(x: stream.labelFrame.midX, y: stream.labelFrame.midY)
        // Keyboard focus shows the system focus ring and the same tooltip as hover.
        .focusable(interactions: .activate)
        .focused(focused, equals: stream.target)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(confluenceName(stream))
        .accessibilityValue(Text("\(TokenFormat.spoken(stream.tokens)) tokens, \(Share.percent(stream.tokens, of: total)) of total"))
    }

    private var nameFont: Font {
        stream.dimension == .models && !stream.isOther
            ? .system(size: 12.5, weight: .medium, design: .monospaced)
            : .system(size: 13, weight: .semibold)
    }

    private var sourceLane: some View {
        HStack(alignment: .center, spacing: 8) {
            if stream.dimension == .models {
                Circle()
                    .fill(stream.color)
                    .frame(width: 8, height: 8)
                    .opacity(dimmed ? 0.45 : 1)
            } else {
                RoundedRectangle(cornerRadius: Radius.badge, style: .continuous)
                    .fill(stream.color.opacity(isDark ? 0.18 : 0.14))
                    .frame(width: 22, height: 22)
                    .overlay {
                        Text(verbatim: stream.monogram)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(stream.color)
                    }
                    .opacity(dimmed ? 0.45 : 1)
            }

            if stream.isCollapsedLabel {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    confluenceName(stream)
                        .font(nameFont)
                        .foregroundStyle(dimmed ? Palette.ink3 : Palette.ink1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(verbatim: " · \(TokenFormat.short(stream.tokens))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(dimmed ? Palette.ink3 : Palette.ink2)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    confluenceName(stream)
                        .font(nameFont)
                        .foregroundStyle(dimmed ? Palette.ink3 : Palette.ink1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(verbatim: "\(TokenFormat.short(stream.tokens)) · \(Share.percent(stream.tokens, of: total))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(dimmed ? Palette.ink3 : Palette.ink2)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var categoryChip: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            confluenceName(stream)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(dimmed ? Palette.ink3 : Palette.ink1)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(verbatim: "\(TokenFormat.short(stream.tokens)) · \(Share.percent(stream.tokens, of: total))")
                .font(.system(size: 11.5))
                .foregroundStyle(dimmed ? Palette.ink3 : Palette.ink2)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private func confluenceName(_ stream: ConfluenceLayout.Stream) -> Text {
    if let category = stream.category { return Text(category.title) }
    if stream.isOther {
        if stream.dimension == .models, stream.otherCount > 0 {
            return Text("Other \(stream.otherCount)")
        }
        return Text("Other")
    }
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
                confluenceName(stream)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.ink1)
            }
            Text("\(TokenFormat.short(stream.tokens)) tokens")
                .fontWeight(.medium)
                .foregroundStyle(Palette.ink1)
            Text("\(Share.percent(stream.tokens, of: total)) of total")
                .foregroundStyle(Palette.ink2)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: 210, alignment: .leading)
        .tooltipSurface(reduceTransparency: reduceTransparency, cornerRadius: Radius.inner)
    }
}

// MARK: - Data-to-form mapping

/// A shared vertical scale maps tokens to ribbon thickness on both sides. Every non-zero
/// stream keeps at least 4.5pt thickness (4.5–7pt under 2%); labels occupy independent lanes
/// so small streams never collide. The central vessel derives its vertical bounds directly from
/// the stream stack: 10pt of air headroom above the curved meniscus down to the lowest stream
/// plus the bottom corner radius.
private struct ConfluenceLayout {
    enum Side {
        case source, category
    }

    struct Descriptor {
        let target: ConfluenceTarget
        let side: Side
        let dimension: BreakdownDimension
        let sourceID: String?
        let name: String
        let tokens: Int64
        let color: Color
        let category: TokenCategory?
        let isOther: Bool
        let otherCount: Int
    }

    struct Stream: Identifiable {
        let target: ConfluenceTarget
        let side: Side
        let dimension: BreakdownDimension
        let name: String
        let monogram: String
        let tokens: Int64
        let value: Double
        let color: Color
        let category: TokenCategory?
        let isOther: Bool
        let otherCount: Int
        let outerFrame: CGRect
        let innerTop: CGFloat
        let innerHeight: CGFloat
        let ribbon: Path
        /// Filled only for the settled layout; interpolated frames skip the 33-sample curves.
        let particleSpecs: [ConfluenceParticleSpec]
        var labelFrame: CGRect = .zero
        var isCollapsedLabel = false
        var leader: Path?

        var id: String { target.id }
    }

    let dimension: BreakdownDimension
    private(set) var sources: [Stream] = []
    private(set) var categories: [Stream] = []
    let totalTokens: Int64
    let reservoir: CGRect
    let reservoirCorner: CGFloat
    let vesselLayers: [LiquidGlassVessel.Layer]
    let vesselFillLevel: Double
    let flowBottom: CGFloat
    let flowBasis: Double
    let compact: Bool
    let isEmpty: Bool
    let leftLabelX: CGFloat
    let leftLabelWidth: CGFloat
    let rightLabelX: CGFloat
    let rightLabelWidth: CGFloat

    private let size: CGSize
    private let sourceDescriptors: [Descriptor]
    private let categoryDescriptors: [Descriptor]
    /// Reservoir hue for the settled values; reused by every interpolated frame.
    private let vesselColor: Color

    private static let otherID = "__other__"
    private static let pad: CGFloat = 20
    private static let vesselHeadroom: CGFloat = 18

    var animationValues: ConfluenceValues {
        var streams: [String: Double] = [:]
        for (index, descriptor) in sourceDescriptors.enumerated() {
            streams[Self.slotKey(for: index)] = Double(descriptor.tokens)
            streams[descriptor.target.id] = Double(descriptor.tokens)
        }
        for descriptor in categoryDescriptors {
            streams[descriptor.target.id] = Double(descriptor.tokens)
        }
        return ConfluenceValues(streams: streams, total: Double(totalTokens))
    }

    init(summary: UsageSummary, dimension: BreakdownDimension = .sources, size: CGSize) {
        let sourceDescriptors: [Descriptor]
        switch dimension {
        case .sources:
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
            var otherCount = 0

            if positiveSources.count > limit {
                let kept = max(1, limit - 1)
                visible = Array(positiveSources.prefix(kept))
                let remaining = positiveSources.dropFirst(kept)
                otherCount = remaining.count
                otherTokens = remaining.reduce(0) { $0 + $1.counts.total }
            }

            sourceDescriptors = visible.map { source in
                Descriptor(
                    target: .source(source.id),
                    side: .source,
                    dimension: .sources,
                    sourceID: source.id,
                    name: source.name,
                    tokens: source.counts.total,
                    color: Palette.color(forSource: source.id),
                    category: nil,
                    isOther: false,
                    otherCount: 0
                )
            } + (otherTokens > 0 ? [Descriptor(
                target: .source(Self.otherID),
                side: .source,
                dimension: .sources,
                sourceID: Self.otherID,
                name: "Other",
                tokens: otherTokens,
                color: Palette.ink3,
                category: nil,
                isOther: true,
                otherCount: otherCount
            )] : [])

        case .models:
            let positiveModels = summary.byModel
                .filter { $0.counts.total > 0 }
                .sorted { lhs, rhs in
                    lhs.counts.total == rhs.counts.total
                        ? lhs.id < rhs.id
                        : lhs.counts.total > rhs.counts.total
                }
            let limit = 6
            let visible = Array(positiveModels.prefix(limit))
            let remaining = positiveModels.dropFirst(limit)
            let otherCount = remaining.count
            let otherTokens = remaining.reduce(Int64(0)) { $0 + $1.counts.total }
            let modelColors = Palette.modelColors(for: visible.map(\.id))

            sourceDescriptors = visible.map { model in
                Descriptor(
                    target: .model(model.id),
                    side: .source,
                    dimension: .models,
                    sourceID: nil,
                    name: model.name,
                    tokens: model.counts.total,
                    color: modelColors[model.id] ?? Palette.color(for: .output),
                    category: nil,
                    isOther: false,
                    otherCount: 0
                )
            } + (otherTokens > 0 ? [Descriptor(
                target: .model(Self.otherID),
                side: .source,
                dimension: .models,
                sourceID: nil,
                name: "Other",
                tokens: otherTokens,
                color: Palette.ink3.opacity(0.5),
                category: nil,
                isOther: true,
                otherCount: otherCount
            )] : [])
        }

        let breakdownTotals = (dimension == .models ? summary.byModel : summary.bySource)
            .reduce(TokenCounts.zero) { $0 + $1.counts }
        let categoryTotals = breakdownTotals.total > 0 ? breakdownTotals : summary.total

        let categoryDescriptors = TokenCategory.allCases.compactMap { category -> Descriptor? in
            let tokens = categoryTotals[category]
            guard tokens > 0 else { return nil }
            return Descriptor(
                target: .category(category),
                side: .category,
                dimension: dimension,
                sourceID: nil,
                name: category.rawValue,
                tokens: tokens,
                color: Palette.color(for: category),
                category: category,
                isOther: false,
                otherCount: 0
            )
        }

        self.init(
            dimension: dimension,
            sourceDescriptors: sourceDescriptors,
            categoryDescriptors: categoryDescriptors,
            totalTokens: max(0, max(summary.total.total, categoryTotals.total)),
            size: size,
            values: nil,
            vesselColor: Self.dominantColor(of: categoryDescriptors),
            withParticles: true
        )
    }

    private init(
        dimension: BreakdownDimension,
        sourceDescriptors: [Descriptor],
        categoryDescriptors: [Descriptor],
        totalTokens: Int64,
        size: CGSize,
        values: ConfluenceValues?,
        vesselColor: Color,
        withParticles: Bool
    ) {
        self.dimension = dimension
        self.sourceDescriptors = sourceDescriptors
        self.categoryDescriptors = categoryDescriptors
        self.totalTokens = totalTokens
        self.size = CGSize(width: max(size.width, 1), height: max(size.height, 1))
        self.vesselColor = vesselColor

        let w = max(size.width, 1), h = max(size.height, 1)
        compact = w < 680 || h < 340
        let bounds = Self.flowBounds(for: size)
        let top = bounds.top, bottom = bounds.bottom
        flowBottom = bottom
        let flowHeight = max(1, bottom - top)

        leftLabelX = Self.pad
        leftLabelWidth = min(188, max(140, ((w * 0.22) / 4).rounded() * 4))
        rightLabelWidth = min(220, max(164, ((w * 0.25) / 4).rounded() * 4))
        rightLabelX = max(leftLabelX + leftLabelWidth + 120, w - Self.pad - rightLabelWidth)

        let terminalWidth: CGFloat = 4
        let leftLabelGap: CGFloat = 12
        let rightLabelGap: CGFloat = 16
        let leftX = leftLabelX + leftLabelWidth + leftLabelGap + terminalWidth
        let rightX = rightLabelX - rightLabelGap - terminalWidth

        let poolWidth = min(150, max(96, ((w * 0.12) / 4).rounded() * 4))
        reservoirCorner = min(poolWidth / 2, 22)
        let desiredPoolX = ((leftX + rightX - poolWidth) / 8).rounded() * 4
        let minimumPoolX = leftX + 24
        let maximumPoolX = rightX - poolWidth - 24
        let poolX = maximumPoolX >= minimumPoolX
            ? min(max(desiredPoolX, minimumPoolX), maximumPoolX)
            : max(Self.pad, (w - poolWidth) / 2)

        let sourceSum = sourceDescriptors.enumerated().reduce(0.0) { result, entry in
            result + Self.animatedValue(for: entry.element, at: entry.offset, in: values)
        }
        let categorySum = categoryDescriptors.enumerated().reduce(0.0) { result, entry in
            result + Self.animatedValue(for: entry.element, at: entry.offset, in: values)
        }
        let animatedTotal = max(0, values?.total ?? Double(totalTokens))
        flowBasis = max(1, max(animatedTotal, max(sourceSum, categorySum)))
        isEmpty = animatedTotal == 0 && sourceSum == 0 && categorySum == 0

        let leftGap: CGFloat = compact ? 6 : 8
        let rightGap: CGFloat = compact ? 6 : 8
        let maxOuterGaps = max(
            leftGap * CGFloat(max(0, sourceDescriptors.count - 1)),
            rightGap * CGFloat(max(0, categoryDescriptors.count - 1))
        )
        let vesselExtra = Self.vesselHeadroom + reservoirCorner
        let stackHeight = isEmpty
            ? min(136, max(48, flowHeight - vesselExtra))
            : max(36, flowHeight - max(maxOuterGaps, vesselExtra))

        let sourceHeights = Self.allocateHeights(
            descriptors: sourceDescriptors,
            values: values,
            flowBasis: flowBasis,
            targetSum: stackHeight
        )
        let categoryHeights = Self.allocateHeights(
            descriptors: categoryDescriptors,
            values: values,
            flowBasis: flowBasis,
            targetSum: stackHeight
        )
        let actualStackHeight = isEmpty
            ? stackHeight
            : max(1, max(sourceHeights.reduce(0, +), categoryHeights.reduce(0, +)))

        let vesselHeight = Self.vesselHeadroom + actualStackHeight + reservoirCorner
        let vesselTop = top + ((flowHeight - vesselHeight) / 2).rounded()
        let streamTop = vesselTop + Self.vesselHeadroom
        let vesselRect = CGRect(x: poolX, y: vesselTop, width: poolWidth, height: vesselHeight)
        reservoir = vesselRect

        let fill = isEmpty
            ? 0
            : LiquidGlassVessel.fillLevel(
                forSurfaceY: streamTop,
                in: vesselRect,
                cornerRadius: reservoirCorner
            )
        vesselFillLevel = fill

        if isEmpty || fill <= 0 {
            vesselLayers = []
        } else {
            vesselLayers = [
                LiquidGlassVessel.Layer(
                    color: vesselColor,
                    fraction: fill
                ),
            ]
        }

        sources = Self.makeStreams(
            descriptors: sourceDescriptors,
            heights: sourceHeights,
            values: values,
            flowBasis: flowBasis,
            side: .source,
            top: top,
            flowHeight: flowHeight,
            streamTop: streamTop,
            gap: leftGap,
            reservoir: reservoir,
            outerX: leftX,
            terminalWidth: terminalWidth,
            labelX: leftLabelX,
            labelWidth: leftLabelWidth,
            withParticles: withParticles
        )
        categories = Self.makeStreams(
            descriptors: categoryDescriptors,
            heights: categoryHeights,
            values: values,
            flowBasis: flowBasis,
            side: .category,
            top: top,
            flowHeight: flowHeight,
            streamTop: streamTop,
            gap: rightGap,
            reservoir: reservoir,
            outerX: rightX,
            terminalWidth: terminalWidth,
            labelX: rightLabelX,
            labelWidth: rightLabelWidth,
            withParticles: withParticles
        )
    }

    /// Rebuilds only what an animated frame draws: interpolated heights, ribbon paths, label
    /// positions and vessel geometry. Particle paths and the reservoir hue stay on the settled layout.
    func interpolated(with values: ConfluenceValues) -> ConfluenceLayout {
        ConfluenceLayout(
            dimension: dimension,
            sourceDescriptors: sourceDescriptors,
            categoryDescriptors: categoryDescriptors,
            totalTokens: totalTokens,
            size: size,
            values: values,
            vesselColor: vesselColor,
            withParticles: false
        )
    }

    /// Largest category by token count; equal counts pick the smaller id, as the animated scan did.
    private static func dominantColor(of descriptors: [Descriptor]) -> Color {
        descriptors
            .max { lhs, rhs in
                lhs.tokens == rhs.tokens ? lhs.target.id > rhs.target.id : lhs.tokens < rhs.tokens
            }?
            .color ?? Palette.color(for: .cacheRead)
    }

    func stream(for target: ConfluenceTarget) -> Stream? {
        (sources + categories).first { $0.target == target }
    }

    func particleTracks(
        activeTarget: ConfluenceTarget?,
        reduceMotion: Bool,
        reduceTransparency: Bool
    ) -> [ConfluenceParticleTrack] {
        guard !reduceMotion, !reduceTransparency else { return [] }
        return (sources + categories).compactMap { stream in
            guard stream.value > 0, !stream.particleSpecs.isEmpty else { return nil }
            let highlighted = activeTarget == stream.target
            // Specks stay in the stream's own hue at <= 0.12 opacity.
            let opacity = highlighted ? 0.12 : 0.09
            return ConfluenceParticleTrack(
                id: stream.target.id,
                particles: stream.particleSpecs,
                speed: max(10, 22 * stream.value / flowBasis),
                color: stream.color.opacity(opacity),
                isDimmed: activeTarget != nil && !highlighted
            )
        }
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
        let pitch: CGFloat = 32
        let fitting = max(1, Int((height + 4) / pitch))
        return min(7, max(count > 1 ? 2 : 1, fitting))
    }

    private static func slotKey(for index: Int) -> String {
        "slot:\(index)"
    }

    private static func animatedValue(
        for descriptor: Descriptor,
        at index: Int,
        in values: ConfluenceValues?
    ) -> Double {
        guard let values else { return Double(descriptor.tokens) }
        if descriptor.side == .source, let slotValue = values.streams[slotKey(for: index)] {
            return max(0, slotValue)
        }
        return max(0, values.streams[descriptor.target.id] ?? Double(descriptor.tokens))
    }

    private static func flowBounds(for size: CGSize) -> (top: CGFloat, bottom: CGFloat) {
        let h = max(size.height, 1)
        let top: CGFloat = pad
        let bottom = max(top + 64, h - pad)
        return (top, min(h - pad, bottom))
    }

    /// Allocates vessel-side heights that sum to `targetSum` while keeping every non-zero stream >= 4.5pt
    /// and streams under 2% share within 4.5–7pt.
    private static func allocateHeights(
        descriptors: [Descriptor],
        values: ConfluenceValues?,
        flowBasis: Double,
        targetSum: CGFloat
    ) -> [CGFloat] {
        guard !descriptors.isEmpty else { return [] }
        let count = descriptors.count
        let rawValues = descriptors.enumerated().map { index, descriptor in
            animatedValue(for: descriptor, at: index, in: values)
        }
        let minFloor: CGFloat = 4.5
        let smallMax: CGFloat = 7.0
        let effectiveMin = min(minFloor, targetSum / CGFloat(count))
        let effectiveSmallMax = max(effectiveMin, min(smallMax, targetSum / CGFloat(count)))

        var heights = Array(repeating: CGFloat(0), count: count)
        var locked = Array(repeating: false, count: count)

        for index in 0..<count {
            let value = rawValues[index]
            guard value > 0 else {
                heights[index] = effectiveMin
                locked[index] = true
                continue
            }
            let share = value / max(1, flowBasis)
            if share < 0.02 {
                let t = CGFloat(max(0, min(1, share / 0.02)))
                heights[index] = effectiveMin + t * (effectiveSmallMax - effectiveMin)
                locked[index] = true
            }
        }

        while true {
            let lockedSum = locked.indices.filter { locked[$0] }.reduce(CGFloat(0)) { $0 + heights[$1] }
            let remainingHeight = max(0, targetSum - lockedSum)
            let unlockedIndices = locked.indices.filter { !locked[$0] }
            guard !unlockedIndices.isEmpty else {
                if lockedSum > 0, abs(lockedSum - targetSum) > 0.01 {
                    let scale = targetSum / lockedSum
                    heights = heights.map { max(effectiveMin, $0 * scale) }
                }
                break
            }
            let unlockedValueSum = unlockedIndices.reduce(0.0) { $0 + rawValues[$1] }
            guard unlockedValueSum > 0 else {
                let each = remainingHeight / CGFloat(unlockedIndices.count)
                for index in unlockedIndices {
                    heights[index] = each
                    locked[index] = true
                }
                break
            }
            var clampedAny = false
            for index in unlockedIndices {
                let proposed = CGFloat(rawValues[index] / unlockedValueSum) * remainingHeight
                if proposed < effectiveSmallMax {
                    heights[index] = effectiveSmallMax
                    locked[index] = true
                    clampedAny = true
                } else {
                    heights[index] = proposed
                }
            }
            if !clampedAny { break }
        }
        return heights
    }

    private static func makeStreams(
        descriptors: [Descriptor],
        heights: [CGFloat],
        values: ConfluenceValues?,
        flowBasis: Double,
        side: Side,
        top: CGFloat,
        flowHeight: CGFloat,
        streamTop: CGFloat,
        gap: CGFloat,
        reservoir: CGRect,
        outerX: CGFloat,
        terminalWidth: CGFloat,
        labelX: CGFloat,
        labelWidth: CGFloat,
        withParticles: Bool
    ) -> [Stream] {
        guard !descriptors.isEmpty else { return [] }
        let innerHeight = heights.reduce(0, +)
        let outerHeight = innerHeight + gap * CGFloat(descriptors.count - 1)
        var innerY = streamTop
        var outerY = top + (flowHeight - outerHeight) / 2
        var streams: [Stream] = []
        let wall = LiquidGlassVessel.wallThickness(for: reservoir)
        let innerLeftX = reservoir.minX + wall
        let innerRightX = reservoir.maxX - wall
        let bleed = min(8, reservoir.width * 0.12)

        for (index, descriptor) in descriptors.enumerated() {
            let height = heights[index]
            let outerFrame = CGRect(
                x: side == .source ? outerX - terminalWidth : outerX,
                y: outerY,
                width: terminalWidth,
                height: height
            )
            let ribbonStartX = side == .source ? outerFrame.minX : innerRightX
            let ribbonEndX = side == .source ? innerLeftX : outerFrame.maxX
            // Sources flow outer → reservoir; categories flow reservoir → outer.
            let startY = side == .source ? outerY : innerY
            let endY = side == .source ? innerY : outerY
            let ribbon = ribbonPath(
                side: side,
                startX: ribbonStartX,
                startTop: startY,
                startBottom: startY + height,
                endX: ribbonEndX,
                endTop: endY,
                endBottom: endY + height,
                vesselBleed: bleed
            )
            let particleStartX = side == .source ? outerFrame.minX + 8 : reservoir.maxX + 6
            let particleEndX = side == .source ? reservoir.minX - 6 : outerFrame.maxX - 8
            let particleSpecs = withParticles
                ? makeParticleSpecs(
                    streamID: descriptor.target.id,
                    startX: particleStartX,
                    startTop: startY,
                    endX: particleEndX,
                    endTop: endY,
                    height: height
                )
                : []
            streams.append(Stream(
                target: descriptor.target,
                side: side,
                dimension: descriptor.dimension,
                name: descriptor.name,
                monogram: monogram(for: descriptor),
                tokens: descriptor.tokens,
                value: animatedValue(for: descriptor, at: index, in: values),
                color: descriptor.color,
                category: descriptor.category,
                isOther: descriptor.isOther,
                otherCount: descriptor.otherCount,
                outerFrame: outerFrame,
                innerTop: innerY,
                innerHeight: height,
                ribbon: ribbon,
                particleSpecs: particleSpecs
            ))
            innerY += height
            outerY += height + gap
        }

        let labelHeight: CGFloat = side == .source ? 28 : 34
        let labelPitch: CGFloat = if side == .source {
            30
        } else {
            flowHeight >= CGFloat(streams.count) * 38 ? 38 : 34
        }
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
            if side == .source {
                let share = streams[index].value / max(1, flowBasis)
                let prevGap = index > 0 ? centers[index] - centers[index - 1] : .infinity
                let nextGap = index + 1 < centers.count ? centers[index + 1] - centers[index] : .infinity
                let neighborGap = min(prevGap, nextGap)
                streams[index].isCollapsedLabel = share < 0.08
                    || streams[index].outerFrame.height < 16
                    || (neighborGap < 32 && index > 0 && share < 0.20)
            }
            let streamY = streams[index].outerFrame.midY
            if side == .category, abs(labelY - streamY) > 1.5 {
                var leader = Path()
                leader.move(to: CGPoint(x: streams[index].outerFrame.maxX + 2, y: streamY))
                leader.addLine(to: CGPoint(x: labelX - 3, y: labelY))
                streams[index].leader = leader
            }
        }
        return streams
    }

    private static func monogram(for descriptor: Descriptor) -> String {
        if descriptor.isOther { return "OT" }
        switch descriptor.sourceID {
        case "claude": return "CC"
        case "pi": return "PI"
        case "codex": return "CX"
        case "kimi": return "KM"
        case "zcode": return "ZC"
        case "grok": return "GK"
        case "omp": return "OM"
        case "opencode": return "OC"
        case "gemini": return "GM"
        case "factory": return "FD"
        case "deepseek": return "DS"
        default: break
        }
        let words = descriptor.name
            .split { !$0.isLetter && !$0.isNumber }
            .filter { !$0.isEmpty }
        if words.count >= 2, let first = words[0].first, let second = words[1].first {
            return "\(first)\(second)".uppercased()
        }
        let chars = descriptor.name.filter { $0.isLetter || $0.isNumber }
        let prefix = String(chars.prefix(2)).uppercased()
        return prefix.isEmpty ? "••" : prefix
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
        if result[0] < minimum {
            let shift = minimum - result[0]
            for index in result.indices {
                result[index] += shift
            }
        }
        return result
    }

    /// Extends the vessel-side edge slightly inside the vessel so clipping against the inverse
    /// vessel shape produces a flush join, and rounds the outer end with a 3pt cap.
    private static func ribbonPath(
        side: Side,
        startX: CGFloat,
        startTop: CGFloat,
        startBottom: CGFloat,
        endX: CGFloat,
        endTop: CGFloat,
        endBottom: CGFloat,
        vesselBleed: CGFloat
    ) -> Path {
        let middleX = (startX + endX) / 2
        var path = Path()
        if side == .source {
            let height = max(0, startBottom - startTop)
            let cap = min(3, height / 2)
            let capX = min(endX, startX + cap)
            let midY = (startTop + startBottom) / 2
            path.move(to: CGPoint(x: capX, y: startTop))
            path.addCurve(
                to: CGPoint(x: endX, y: endTop),
                control1: CGPoint(x: middleX, y: startTop),
                control2: CGPoint(x: middleX, y: endTop)
            )
            path.addLine(to: CGPoint(x: endX + vesselBleed, y: endTop))
            path.addLine(to: CGPoint(x: endX + vesselBleed, y: endBottom))
            path.addLine(to: CGPoint(x: endX, y: endBottom))
            path.addCurve(
                to: CGPoint(x: capX, y: startBottom),
                control1: CGPoint(x: middleX, y: endBottom),
                control2: CGPoint(x: middleX, y: startBottom)
            )
            if cap > 0.25 {
                path.addArc(
                    tangent1End: CGPoint(x: startX, y: startBottom),
                    tangent2End: CGPoint(x: startX, y: midY),
                    radius: cap
                )
                path.addArc(
                    tangent1End: CGPoint(x: startX, y: startTop),
                    tangent2End: CGPoint(x: capX, y: startTop),
                    radius: cap
                )
            }
        } else {
            let height = max(0, endBottom - endTop)
            let cap = min(3, height / 2)
            let capX = max(startX, endX - cap)
            let midY = (endTop + endBottom) / 2
            path.move(to: CGPoint(x: startX - vesselBleed, y: startTop))
            path.addLine(to: CGPoint(x: startX, y: startTop))
            path.addCurve(
                to: CGPoint(x: capX, y: endTop),
                control1: CGPoint(x: middleX, y: startTop),
                control2: CGPoint(x: middleX, y: endTop)
            )
            if cap > 0.25 {
                path.addArc(
                    tangent1End: CGPoint(x: endX, y: endTop),
                    tangent2End: CGPoint(x: endX, y: midY),
                    radius: cap
                )
                path.addArc(
                    tangent1End: CGPoint(x: endX, y: endBottom),
                    tangent2End: CGPoint(x: capX, y: endBottom),
                    radius: cap
                )
                path.addLine(to: CGPoint(x: capX, y: endBottom))
            } else {
                path.addLine(to: CGPoint(x: endX, y: endBottom))
            }
            path.addCurve(
                to: CGPoint(x: startX, y: startBottom),
                control1: CGPoint(x: middleX, y: endBottom),
                control2: CGPoint(x: middleX, y: startBottom)
            )
            path.addLine(to: CGPoint(x: startX - vesselBleed, y: startBottom))
        }
        path.closeSubpath()
        return path
    }

    /// Generates at most 3 seeded-jitter particle tracks per stream (none on thin streams).
    private static func makeParticleSpecs(
        streamID: String,
        startX: CGFloat,
        startTop: CGFloat,
        endX: CGFloat,
        endTop: CGFloat,
        height: CGFloat
    ) -> [ConfluenceParticleSpec] {
        guard height >= 10, endX > startX + 12 else { return [] }
        let count = height < 20 ? 1 : (height < 48 ? 2 : 3)
        var specs: [ConfluenceParticleSpec] = []
        specs.reserveCapacity(count)

        for index in 0..<count {
            let h1 = seededUnit(streamID, salt: UInt64(index * 3 + 1))
            let h2 = seededUnit(streamID, salt: UInt64(index * 3 + 2))
            let h3 = seededUnit(streamID, salt: UInt64(index * 3 + 3))

            // Jitter cross-stream lane and phase so specks never line up on a grid.
            let laneFraction = 0.24 + 0.52 * CGFloat(h1)
            let endFraction = 0.26 + 0.48 * CGFloat(h2)
            let samples = makeCenterSamples(
                startX: startX,
                startY: startTop + height * laneFraction,
                endX: endX,
                endY: endTop + height * endFraction
            )
            guard let length = samples.last?.distance, length > 0 else { continue }
            let basePhase = (Double(index) + 0.18 + 0.64 * h2) / Double(count)
            let phase = (basePhase + h3 * 0.37).truncatingRemainder(dividingBy: 1.0)
            let radius = 1.1 + 0.5 * CGFloat(h3)
            specs.append(ConfluenceParticleSpec(
                samples: samples,
                length: length,
                phaseOffset: phase,
                radius: radius
            ))
        }
        return specs
    }

    private static func seededUnit(_ key: String, salt: UInt64) -> Double {
        var hash: UInt64 = 0xcbf29ce484222325 ^ (salt &* 0x9e3779b97f4a7c15)
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        hash ^= hash >> 33
        hash = hash &* 0xff51afd7ed558ccd
        hash ^= hash >> 33
        return Double(hash & 0x1F_FFFF) / Double(0x1F_FFFF)
    }

    private static func makeCenterSamples(
        startX: CGFloat,
        startY: CGFloat,
        endX: CGFloat,
        endY: CGFloat
    ) -> [ConfluenceParticleSample] {
        let sampleCount = 32
        let middleX = (startX + endX) / 2
        var samples: [ConfluenceParticleSample] = []
        samples.reserveCapacity(sampleCount + 1)
        var previous = CGPoint(x: startX, y: startY)
        var distance: CGFloat = 0

        for index in 0...sampleCount {
            let t = CGFloat(index) / CGFloat(sampleCount)
            let inverse = 1 - t
            let point = CGPoint(
                x: inverse * inverse * inverse * startX
                    + 3 * inverse * inverse * t * middleX
                    + 3 * inverse * t * t * middleX
                    + t * t * t * endX,
                y: inverse * inverse * inverse * startY
                    + 3 * inverse * inverse * t * startY
                    + 3 * inverse * t * t * endY
                    + t * t * t * endY
            )
            if index > 0 {
                let dx = point.x - previous.x
                let dy = point.y - previous.y
                distance += (dx * dx + dy * dy).squareRoot()
            }
            samples.append(ConfluenceParticleSample(point: point, distance: distance))
            previous = point
        }
        return samples
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
    let activeTarget: ConfluenceTarget?
    let isDark: Bool
    let reduceTransparency: Bool
    let vesselBodyStyle: LiquidGlassVessel.BodyStyle

    func drawStreamsAndLeaders(in context: inout GraphicsContext) {
        let vesselShape = RoundedRectangle(cornerRadius: layout.reservoirCorner, style: .continuous)
            .path(in: layout.reservoir)

        var streamContext = context
        streamContext.clip(to: vesselShape, options: .inverse)
        for stream in layout.sources + layout.categories {
            draw(stream, in: &streamContext)
        }

        for stream in layout.categories {
            guard let leader = stream.leader else { continue }
            context.stroke(
                leader,
                with: .color(stream.color.opacity(0.5)),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2.5, 2.5])
            )
        }
    }

    func drawVessel(in context: inout GraphicsContext, wobblePhase: Double?) {
        let inflows: [(color: Color, y: CGFloat, height: CGFloat, fromLeft: Bool)] =
            (layout.sources + layout.categories).compactMap { stream in
                guard stream.value > 0, stream.innerHeight > 0 else { return nil }
                let dimmed = activeTarget != nil && activeTarget != stream.target
                let color = dimmed ? stream.color.opacity(0.22) : stream.color
                return (
                    color: color,
                    y: stream.innerTop,
                    height: stream.innerHeight,
                    fromLeft: stream.side == .source
                )
            }

        LiquidGlassVessel.draw(
            in: &context,
            rect: layout.reservoir,
            cornerRadius: layout.reservoirCorner,
            layers: layout.vesselLayers,
            fillLevel: layout.vesselFillLevel,
            isDark: isDark,
            reduceTransparency: reduceTransparency,
            inflows: inflows,
            wobblePhase: wobblePhase,
            bodyStyle: vesselBodyStyle
        )
    }

    private func draw(_ stream: ConfluenceLayout.Stream, in context: inout GraphicsContext) {
        let highlighted = activeTarget == stream.target
        let dimmed = activeTarget != nil && !highlighted
        let alpha = (highlighted ? 0.96 : isDark ? 0.78 : 0.72) * (dimmed ? 0.2 : 1)
        let fillColor = dimmed && reduceTransparency ? Palette.ink3 : stream.color
        let wall = LiquidGlassVessel.wallThickness(for: layout.reservoir)
        let startX = stream.side == .source ? stream.outerFrame.minX : layout.reservoir.maxX - wall
        let endX = stream.side == .source ? layout.reservoir.minX + wall : stream.outerFrame.maxX
        let bounds = stream.ribbon.boundingRect

        if reduceTransparency {
            context.fill(stream.ribbon, with: .color(fillColor))
        } else {
            let colors = stream.side == .source
                ? [stream.color.opacity(alpha), stream.color.opacity(alpha * 0.48)]
                : [stream.color.opacity(alpha * 0.46), stream.color.opacity(alpha * 0.88)]
            context.fill(
                stream.ribbon,
                with: .linearGradient(
                    Gradient(colors: colors),
                    startPoint: CGPoint(x: startX, y: bounds.minY),
                    endPoint: CGPoint(x: endX, y: bounds.minY)
                )
            )
            context.fill(
                stream.ribbon,
                with: .linearGradient(
                    Gradient(colors: [
                        .white.opacity(dimmed ? 0.04 : 0.24),
                        .white.opacity(0),
                        .white.opacity(dimmed ? 0.02 : 0.06),
                    ]),
                    startPoint: CGPoint(x: bounds.minX, y: bounds.minY),
                    endPoint: CGPoint(x: bounds.minX, y: bounds.maxY)
                )
            )
        }

        if highlighted && !reduceTransparency {
            context.stroke(stream.ribbon, with: .color(.white.opacity(0.5)), lineWidth: 0.8)
        }
    }
}
