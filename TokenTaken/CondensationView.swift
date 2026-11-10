import SwiftUI
import TokenTakenKit

/// The hero: a pane of glass with a temperature difference.
/// Fog and rain are drawn in one `Canvas`; device dew drops are native glass views
/// that refract the fog behind them. All data-to-form rules live in `CondensationLayout`.
struct CondensationView: View {
    let summary: UsageSummary

    @Namespace private var dropSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Closed or background windows keep their views alive; animate only while the window is active.
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    @State private var hover: FieldHover?
    @State private var epoch = Date.now

    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        GeometryReader { proxy in
            let layout = CondensationLayout(summary: summary, size: proxy.size)
            ZStack(alignment: .topLeading) {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !appearsActive)) { timeline in
                    let time = reduceMotion ? 0 : timeline.date.timeIntervalSince(epoch)
                    Canvas { context, _ in
                        CondensationRenderer(layout: layout, time: time, hover: hover?.target, isDark: scheme == .dark)
                            .draw(in: &context)
                    }
                }
                .accessibilityHidden(true)

                DewDrops(layout: layout, namespace: dropSpace, total: summary.total.total)
                FieldAccessibility(layout: layout, total: summary.total.total)
                FieldCaptions(layout: layout)

                if let hover {
                    FieldTooltip(target: hover.target, layout: layout, summary: summary)
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
                    hover = layout.hitTest(point).map { FieldHover(target: $0, location: point) }
                case .ended:
                    hover = nil
                }
            }
        }
        .background { surface }
        .clipShape(shape)
        .overlay { shape.strokeBorder(Palette.hairline) }
        .overlay {
            // Inner top highlight, the lit edge of the pane.
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.12 : 0.55), .clear],
                               startPoint: .top, endPoint: .center),
                lineWidth: 1
            )
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Source mist and daily usage rain trails"))
    }

    @ViewBuilder private var surface: some View {
        if reduceTransparency {
            shape.fill(Palette.solid)
        } else {
            shape.fill(LinearGradient(
                colors: scheme == .dark
                    ? [.white.opacity(0.07), .white.opacity(0.02)]
                    : [.white.opacity(0.34), .white.opacity(0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        }
    }

    private func tooltipOffset(for point: CGPoint, in size: CGSize) -> CGSize {
        let width: CGFloat = 220, height: CGFloat = 64
        let x = min(point.x + 14, size.width - width - 8)
        let y = point.y + 16 + height > size.height ? point.y - height - 10 : point.y + 16
        return CGSize(width: max(8, x), height: max(8, y))
    }
}

struct FieldHover: Equatable {
    var target: FieldTarget
    var location: CGPoint
}

enum FieldTarget: Equatable {
    case drop(String)
    case fog(String)
    case trail(Int)
}

// MARK: - Dew drops

/// Each device is one native drop; `glassEffectID` lets drops morph
/// in size when the period changes and merge or split as they appear.
/// Reduce Transparency replaces the glass with opaque circles.
private struct DewDrops: View {
    let layout: CondensationLayout
    let namespace: Namespace.ID
    let total: Int64

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack(alignment: .topLeading) {
            GlassEffectContainer(spacing: 18) {
                ZStack(alignment: .topLeading) {
                    ForEach(layout.drops) { drop in
                        Group {
                            if reduceTransparency {
                                Circle()
                                    .fill(Palette.solid)
                                    .overlay { Circle().strokeBorder(Palette.hairline) }
                                    .frame(width: drop.radius * 2, height: drop.radius * 2)
                            } else {
                                Color.clear
                                    .frame(width: drop.radius * 2, height: drop.radius * 2)
                                    .glassEffect(.regular.interactive(), in: .circle)
                                    .glassEffectID(drop.id, in: namespace)
                            }
                        }
                        .position(drop.center)
                        .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            ForEach(layout.drops) { drop in
                VStack(spacing: 1) {
                    Text(verbatim: drop.name)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                    Text(TokenFormat.short(drop.value))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .lineLimit(1)
                .fixedSize()
                .position(x: drop.center.x, y: drop.center.y + drop.radius + 17)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: drop.name))
                .accessibilityValue(Text("\(TokenFormat.short(drop.value)) tokens, \(Share.percent(drop.value, of: total)) of total"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FieldAccessibility: View {
    let layout: CondensationLayout
    let total: Int64

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.fog) { fog in
                Color.clear
                    .frame(width: fog.radii.width * 2, height: fog.radii.height * 2)
                    .position(fog.center)
                    .accessibilityElement()
                    .accessibilityLabel(Text(verbatim: fog.name))
                    .accessibilityValue(
                        Text("\(TokenFormat.short(fog.value)) tokens")
                        + Text(verbatim: " · ")
                        + Text("Rank \(fog.rank + 1) · \(Share.percent(fog.value, of: total))")
                    )
            }
            ForEach(layout.trails) { trail in
                Color.clear
                    .frame(width: 12, height: trail.length + 12)
                    .position(x: trail.x, y: trail.top + trail.length / 2)
                    .accessibilityElement()
                    .accessibilityLabel(Text(verbatim: trail.point.label))
                    .accessibilityValue(trailValue(trail))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
    }

    private func trailValue(_ trail: CondensationLayout.Trail) -> Text {
        let value = Text("\(TokenFormat.short(trail.point.total)) tokens")
        guard let top = trail.point.bySource.max(by: { $0.value < $1.value }), top.value > 0 else {
            return value
        }
        return value + Text(verbatim: " · ") + Text("Top: \(SourceCatalog.info(for: top.key).name)")
    }
}

// MARK: - Captions

private struct FieldCaptions: View {
    let layout: CondensationLayout

    var body: some View {
        VStack {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("CONDENSATION FIELD")
                Spacer()
                Text("Mist = source volume and rank")
            }
            Spacer()
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: layout.firstLabel)
                Spacer()
                Text("Trail length and ripple = usage")
                Spacer()
                Text(verbatim: layout.lastLabel)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(Palette.muted)
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .allowsHitTesting(false)
    }
}

// MARK: - Tooltip

private struct FieldTooltip: View {
    let target: FieldTarget
    let layout: CondensationLayout
    let summary: UsageSummary

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            content
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: 220, alignment: .leading)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.solid)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 11))
    }

    @ViewBuilder private var content: some View {
        switch target {
        case .drop(let id):
            if let drop = layout.drops.first(where: { $0.id == id }) {
                title(drop.name, color: nil)
                Text("\(TokenFormat.short(drop.value)) tokens").fontWeight(.medium)
                Text("\(Share.percent(drop.value, of: summary.total.total)) of total").foregroundStyle(Palette.muted)
            }
        case .fog(let id):
            if let fog = layout.fog.first(where: { $0.id == id }) {
                title(fog.name, color: fog.color)
                Text("\(TokenFormat.short(fog.value)) tokens").fontWeight(.medium)
                Text("Rank \(fog.rank + 1) · \(Share.percent(fog.value, of: summary.total.total))")
                    .foregroundStyle(Palette.muted)
            }
        case .trail(let id):
            if let trail = layout.trails.first(where: { $0.id == id }) {
                title(trail.point.label, color: nil)
                Text("\(TokenFormat.short(trail.point.total)) tokens").fontWeight(.medium)
                if let top = trail.point.bySource.max(by: { $0.value < $1.value }), top.value > 0 {
                    Text("Top: \(SourceCatalog.info(for: top.key).name)").foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private func title(_ text: String, color: Color?) -> some View {
        HStack(spacing: 6) {
            if let color { Circle().fill(color).frame(width: 6, height: 6) }
            Text(verbatim: text).font(.system(size: 11, weight: .semibold))
        }
    }
}

// MARK: - Data-to-form mapping

/// The single place where usage numbers become geometry. Refine the mapping here.
///
/// - Dew drop (one per device, stable device order): circle **area ∝ device tokens**,
///   radius = maxRadius · √(value / largest device). Horizontal slots 22%–78% of width.
/// - Fog patch (one per source, rank order): ellipse **area ∝ source tokens**
///   (rx ∝ √(value / largest source)), **opacity rises with √share**; x = rank, left to right,
///   y staggers over three rows so neighbours don't merge. Blur expresses condensation only.
/// - Rain trail (one per series point, x = time): **length ∝ point total**;
///   future points draw nothing. Ripple radius = 2 + 16 · √(total / max).
///   `SeriesPoint` has no per-point category split, so the ripple scales with the point total
///   times the period's output share (a constant), i.e. it is proportional to total, not to
///   measured daily output. Switch to real daily output once the Kit exposes it.
/// - Moving rain heads: only the latest 28 points; speed = 0.07 + 0.22 · (total / max) cycles/s.
struct CondensationLayout {
    struct Drop: Identifiable {
        let id: String
        let name: String
        let value: Int64
        let center: CGPoint
        let radius: CGFloat
    }

    struct Fog: Identifiable {
        let id: String
        let name: String
        let value: Int64
        let rank: Int
        let color: Color
        let center: CGPoint
        let radii: CGSize
        let opacity: Double
    }

    struct Trail: Identifiable {
        let id: Int
        let point: SeriesPoint
        let x: CGFloat
        let top: CGFloat
        let length: CGFloat
        let ripple: CGFloat
        /// Cycles per second and start offset of the sliding head; nil when the trail is static.
        let head: (speed: Double, phase: Double)?
    }

    private(set) var drops: [Drop] = []
    private(set) var fog: [Fog] = []
    private(set) var trails: [Trail] = []
    let trailWidth: CGFloat
    let headRadius: CGFloat
    let firstLabel: String
    let lastLabel: String
    private let trailStep: CGFloat

    init(summary: UsageSummary, size: CGSize) {
        let w = max(size.width, 1), h = max(size.height, 1)

        // Drops, in the store's device order so positions stay put across periods.
        let order = Dictionary(summary.devices.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let devices = summary.byDevice
            .filter { $0.counts.total > 0 }
            .sorted { (order[$0.id] ?? .max, $0.name) < (order[$1.id] ?? .max, $1.name) }
        let deviceMax = Double(devices.map(\.counts.total).max() ?? 1)
        var maxRadius = min(max(h * 0.13, 30), 56)
        if devices.count > 3 { maxRadius = min(maxRadius, w * 0.56 / CGFloat(devices.count - 1) * 0.45) }
        let dropY = max(h * 0.17, maxRadius + 24)
        drops = devices.enumerated().map { i, device in
            let slot = devices.count == 1 ? 0.5 : 0.22 + 0.56 * CGFloat(i) / CGFloat(devices.count - 1)
            let radius = max(5, maxRadius * sqrt(Double(device.counts.total) / deviceMax))
            return Drop(id: device.id, name: device.name, value: device.counts.total,
                        center: CGPoint(x: w * slot, y: dropY), radius: radius)
        }

        // Fog, by source rank.
        let sources = summary.bySource.filter { $0.counts.total > 0 }
        let sourceMax = Double(sources.first.map(\.counts.total) ?? 1)
        let margin = max(45, w * 0.06)
        fog = sources.enumerated().map { i, source in
            let scale = sqrt(Double(source.counts.total) / sourceMax)
            let x = sources.count == 1 ? w / 2 : margin + (w - 2 * margin) * CGFloat(i) / CGFloat(sources.count - 1)
            let rx = w * 0.085 * scale + 14
            return Fog(id: source.id, name: source.name, value: source.counts.total, rank: i,
                       color: Palette.color(forSource: source.id),
                       center: CGPoint(x: x, y: h * (0.24 + 0.11 * CGFloat(i % 3))),
                       radii: CGSize(width: rx, height: rx * 0.62),
                       opacity: 0.2 + 0.26 * scale)
        }

        // Rain trails, by time.
        let series = summary.series
        let top = max(h * 0.375, dropY + maxRadius + 36)
        let available = max(20, min(h * 0.48, h - top - 52))
        let peak = Double(series.filter { !$0.isFuture }.map(\.total).max() ?? 0)
        let step = series.count > 1 ? (w - 56) / CGFloat(series.count - 1) : 0
        trailStep = step
        let lastActual = series.lastIndex { !$0.isFuture } ?? -1
        trails = series.enumerated().compactMap { i, point in
            guard !point.isFuture, point.total > 0, peak > 0 else { return nil }
            let ratio = Double(point.total) / peak
            let moving = i > lastActual - 28
            return Trail(id: i, point: point,
                         x: series.count == 1 ? w / 2 : 28 + step * CGFloat(i),
                         top: top, length: 12 + available * ratio,
                         ripple: 2 + 16 * sqrt(ratio),
                         head: moving ? (0.07 + 0.22 * ratio, (Double(i) * 0.173).truncatingRemainder(dividingBy: 1)) : nil)
        }
        trailWidth = series.count > 80 ? 0.65 : 1.25
        headRadius = series.count > 80 ? 1.4 : 2.4
        firstLabel = series.first?.label ?? ""
        lastLabel = series.last?.label ?? ""
    }

    func hitTest(_ p: CGPoint) -> FieldTarget? {
        if let drop = drops.first(where: { hypot(p.x - $0.center.x, p.y - $0.center.y) <= $0.radius + 2 }) {
            return .drop(drop.id)
        }
        let reach = max(trailStep / 2, 4)
        if let trail = trails
            .filter({ abs($0.x - p.x) <= reach && p.y >= $0.top - 4 && p.y <= $0.top + $0.length + 12 })
            .min(by: { abs($0.x - p.x) < abs($1.x - p.x) }) {
            return .trail(trail.id)
        }
        let inside = fog.map { f -> (Fog, CGFloat) in
            let dx = (p.x - f.center.x) / f.radii.width, dy = (p.y - f.center.y) / f.radii.height
            return (f, dx * dx + dy * dy)
        }
        return inside.filter { $0.1 <= 1 }.min { $0.1 < $1.1 }.map { .fog($0.0.id) }
    }
}

// MARK: - Renderer

private struct CondensationRenderer {
    let layout: CondensationLayout
    let time: Double
    let hover: FieldTarget?
    let isDark: Bool
    /// Reduce Motion: heads rest at 72% of their trail, fog stops drifting.
    var isStatic: Bool { time == 0 }

    func draw(in context: inout GraphicsContext) {
        drawFog(in: &context)
        for trail in layout.trails { drawTrail(trail, in: &context) }
    }

    private func drawFog(in context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 14))
            for (i, patch) in layout.fog.enumerated() {
                let phase = Double(i)
                let drift = CGSize(width: sin(time * 0.11 + phase * 1.7) * 6, height: cos(time * 0.08 + phase * 0.9) * 3.5)
                let boost = hover == .fog(patch.id) ? 1.45 : 1
                let alpha = min(patch.opacity * boost * (isDark ? 0.85 : 1), 0.9)
                let r = patch.radii.width
                var g = layer
                g.translateBy(x: patch.center.x + drift.width, y: patch.center.y + drift.height)
                g.scaleBy(x: 1, y: patch.radii.height / r)
                g.fill(
                    Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2)),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: patch.color.opacity(alpha), location: 0),
                            .init(color: patch.color.opacity(alpha * 0.5), location: 0.55),
                            .init(color: patch.color.opacity(0), location: 1),
                        ]),
                        center: .zero, startRadius: 0, endRadius: r
                    )
                )
            }
        }
    }

    /// Point on the trail's gentle quadratic curve at s ∈ 0...1.
    private func point(on t: CondensationLayout.Trail, at s: Double) -> CGPoint {
        CGPoint(x: t.x + 4 * s * (1 - s), y: t.top + t.length * (1.1 * s * (1 - s) + s * s))
    }

    private func drawTrail(_ t: CondensationLayout.Trail, in context: inout GraphicsContext) {
        let highlighted = hover == .trail(t.id)
        let water = highlighted ? Palette.accent : Palette.rain
        let bottom = t.top + t.length
        var path = Path()
        path.move(to: CGPoint(x: t.x, y: t.top))
        path.addQuadCurve(to: CGPoint(x: t.x, y: bottom), control: CGPoint(x: t.x + 2, y: t.top + t.length * 0.55))
        context.stroke(
            path,
            with: .linearGradient(Gradient(colors: [water.opacity(0.06), water.opacity(highlighted ? 0.95 : 0.62)]),
                                  startPoint: CGPoint(x: t.x, y: t.top), endPoint: CGPoint(x: t.x, y: bottom)),
            style: StrokeStyle(lineWidth: layout.trailWidth * (highlighted ? 1.8 : 1), lineCap: .round)
        )

        var ripple = t.ripple
        if let head = t.head {
            let s = isStatic ? 0.72 : (time * head.speed + head.phase).truncatingRemainder(dividingBy: 1)
            let alpha = isStatic ? 0.85 : sin(s * .pi) * 0.9
            let at = point(on: t, at: s)
            // Wet streak the head leaves behind it.
            var tail = Path()
            tail.move(to: point(on: t, at: max(0, s - 0.14)))
            tail.addLine(to: at)
            context.stroke(
                tail,
                with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(alpha * 0.8)]),
                                      startPoint: point(on: t, at: max(0, s - 0.14)), endPoint: at),
                style: StrokeStyle(lineWidth: layout.trailWidth * 1.6, lineCap: .round)
            )
            let r = layout.headRadius
            context.fill(Path(ellipseIn: CGRect(x: at.x - r * 2, y: at.y - r * 2, width: r * 4, height: r * 4)),
                         with: .color(water.opacity(alpha * 0.22)))
            context.fill(Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: r * 2, height: r * 2)),
                         with: .color(.white.opacity(alpha)))
            if !isStatic, s > 0.85 { ripple *= 1 + 0.3 * (s - 0.85) / 0.15 }
        }
        context.stroke(
            Path(ellipseIn: CGRect(x: t.x - ripple, y: bottom + 7 - ripple * 0.3, width: ripple * 2, height: ripple * 0.6)),
            with: .color(water.opacity(highlighted ? 0.8 : 0.5)),
            lineWidth: 0.8
        )
    }
}
