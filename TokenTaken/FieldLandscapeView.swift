import AppKit
import SwiftUI
import TokenTakenKit

enum FieldFont {
    /// New York for Latin and digits, Songti SC for Chinese.
    static func serif(_ size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        var descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        descriptor = descriptor.addingAttributes([.cascadeList: [NSFontDescriptor(name: "Songti SC", size: size)]])
        return Font(NSFont(descriptor: descriptor, size: size) ?? base)
    }

    /// Board signs are rebuilt on every paint, so their fonts are resolved once.
    static let signName = serif(16)
    static let signNumber = serif(13.5)
    static let stake = serif(14.5)
    static let stakeSmall = serif(12)
}

/// One plot of the farm: a source or model, its crop, and its place in the plan.
struct FieldPlot: Identifiable, Equatable {
    let id: String
    let name: String
    let value: Int64
    let crop: FieldCrop
    let plan: CGRect
    let corners: [CGPoint]
    let hitPath: Path
    let bounds: CGRect
}

/// Geometry shared by the painter and hit testing. The scene is a fixed 1200 × 720 picture scaled to fit.
struct FieldSceneModel: Equatable {
    static let size = CGSize(width: 1200, height: 720)
    static let plan = CGSize(width: 760, height: 540)
    static let gap: CGFloat = 16
    static let yFar: CGFloat = 262, yNear: CGFloat = 598, cx: CGFloat = 610, nearWidth: CGFloat = 830

    let plots: [FieldPlot]
    let total: Int64

    static let empty = FieldSceneModel(items: [])

    init(items: [Breakdown]) {
        let active = items.filter { $0.counts.total > 0 }
        let crops = FieldCrop.assign(active)
        let gap = Self.gap
        let cells = FieldTreemap.layout(active.map { Double($0.counts.total) }, in: CGSize(width: Self.plan.width - gap, height: Self.plan.height - gap))
        plots = cells.map { cell in
            let item = active[cell.index]
            let r = CGRect(x: cell.rect.minX + gap, y: cell.rect.minY + gap, width: max(1, cell.rect.width - gap), height: max(1, cell.rect.height - gap))
            let corners = [Self.project(r.minX, r.minY), Self.project(r.maxX, r.minY), Self.project(r.maxX, r.maxY), Self.project(r.minX, r.maxY)]
            var hitPath = Path()
            hitPath.addLines(corners)
            hitPath.closeSubpath()
            return FieldPlot(
                id: item.id,
                name: item.name,
                value: item.counts.total,
                crop: crops[item.id] ?? .wheat,
                plan: r,
                corners: corners,
                hitPath: hitPath,
                bounds: hitPath.boundingRect
            )
        }
        total = active.reduce(0) { $0 + $1.counts.total }
    }

    static func depthScale(_ v: CGFloat) -> CGFloat { 0.88 + 0.12 * v / plan.height }

    /// Plan (u, v) to scene point: far rows slightly narrower than near ones.
    static func project(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
        CGPoint(x: cx + (u - plan.width / 2) * (nearWidth / plan.width) * depthScale(v), y: yFar + (yNear - yFar) * v / plan.height)
    }

    func plot(at point: CGPoint) -> FieldPlot? {
        plots.first { $0.bounds.contains(point) && $0.hitPath.contains(point) }
    }
}

/// Keeps the treemap layout between body passes. Hover updates re-evaluate the whole view body, but the
/// layout only changes when the breakdown does; mutating this box does not invalidate the view.
final class FieldSceneModelCache {
    private var items: [Breakdown] = []
    private var valid = false
    private var cached = FieldSceneModel.empty

    func model(for items: [Breakdown]) -> FieldSceneModel {
        if valid, items == self.items { return cached }
        self.items = items
        valid = true
        cached = FieldSceneModel(items: items)
        return cached
    }
}

struct FieldLandscapeView: View {
    let items: [Breakdown]
    @Binding var highlight: String?
    /// Share cards pass false: their highlight is the fixed scope, so hover must not drive it or the tooltip.
    var interactive = true
    /// Small renderings (the menu bar panel) mark plots with crop-coloured flags instead of unreadable boards.
    var compact = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoverPoint: CGPoint?
    @State private var tooltipSize = CGSize(width: 220, height: 68)
    @State private var windowVisible = true
    @State private var scene = FieldSceneModelCache()

    var body: some View {
        let model = scene.model(for: items)
        let chinese = locale.language.languageCode == .chinese
        let season = FieldSeason.of(Date())
        let isDark = scheme == .dark
        GeometryReader { proxy in
            let scale = proxy.size.width / FieldSceneModel.size.width
            // Static scenery layers are Equatable and independent of highlight, so hover changes only repaint plots and signs.
            ZStack {
                FieldBackSceneryCanvas(model: model, isDark: isDark, season: season)
                    .equatable()
                FieldPlotsCanvas(model: model, isDark: isDark, season: season, highlight: highlight)
                    .equatable()
                FieldFrontSceneryCanvas(isDark: isDark, season: season)
                    .equatable()
                FieldSignsCanvas(model: model, isDark: isDark, season: season, highlight: highlight, chinese: chinese, compact: compact)
                    .equatable()
            }
            .accessibilityHidden(true)
            .background {
                // Only the interactive farm needs to know; share cards and the panel render off screen.
                if interactive { WindowVisibilityProbe { windowVisible = $0 } }
            }
            .overlay {
                FieldAmbience(isDark: isDark, season: season, animate: interactive && !reduceMotion, windowVisible: windowVisible)
                    .accessibilityHidden(true)
            }
            .overlay {
                if model.plots.isEmpty {
                    Text("No usage in this period")
                        .font(FieldFont.serif(compact ? 11.5 : 15))
                        .foregroundStyle(FieldPalette.ink)
                        .padding(.horizontal, compact ? 10 : 18)
                        .padding(.vertical, compact ? 6 : 10)
                        .background(FieldPalette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(FieldPalette.rule, lineWidth: 1))
                        .shadow(color: Color.black.opacity(isDark ? 0.28 : 0.10), radius: 6, y: 2)
                        .position(x: proxy.size.width * 0.5, y: proxy.size.height * 0.58)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if !model.plots.isEmpty {
                    ZStack(alignment: .topLeading) {
                        ForEach(model.plots) { plot in
                            let bounds = plot.bounds
                            Color.clear
                                .frame(
                                    width: max(1, bounds.width * scale),
                                    height: max(1, bounds.height * scale)
                                )
                                .offset(x: bounds.minX * scale, y: bounds.minY * scale)
                                .accessibilityElement()
                                .accessibilityLabel(Text(verbatim: "\(plot.name), \(plot.crop.label(locale: locale))"))
                                .accessibilityValue(
                                    Text("\(TokenFormat.spoken(plot.value)) tokens, \(FieldFormat.percent(plot.value, of: model.total, locale: locale)) of total")
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                }
            }
            .onContinuousHover { phase in
                guard interactive else { return }
                switch phase {
                case .active(let location):
                    hoverPoint = location
                    highlight = model.plot(at: CGPoint(x: location.x / scale, y: location.y / scale))?.id
                case .ended:
                    hoverPoint = nil
                    highlight = nil
                }
            }
            .overlay(alignment: .topLeading) {
                if interactive, let point = hoverPoint, let id = highlight, let plot = model.plots.first(where: { $0.id == id }) {
                    let tipWidth = min(max(tooltipSize.width, 1), 260)
                    let tipHeight = max(tooltipSize.height, 64)
                    let x = max(8, min(point.x + 14, proxy.size.width - tipWidth - 8))
                    let y = max(8, point.y + tipHeight + 20 > proxy.size.height ? point.y - tipHeight - 10 : point.y + 16)
                    FieldTooltip(plot: plot, total: model.total)
                        .frame(maxWidth: 260, alignment: .leading)
                        .onGeometryChange(for: CGSize.self, of: \.size) { newSize in
                            tooltipSize = newSize
                        }
                        .offset(x: x, y: y)
                        .allowsHitTesting(false)
                }
            }
        }
        .aspectRatio(FieldSceneModel.size.width / FieldSceneModel.size.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(FieldPalette.rule, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

private struct FieldBackSceneryCanvas: View, Equatable {
    let model: FieldSceneModel
    let isDark: Bool
    let season: FieldSeason

    var body: some View {
        Canvas { ctx, size in
            let scale = size.width / FieldSceneModel.size.width
            ctx.scaleBy(x: scale, y: scale)
            FieldPainter(ctx: ctx, model: model, isDark: isDark, season: season, highlight: nil, chinese: false).paintBackScenery()
        }
    }
}

private struct FieldPlotsCanvas: View, Equatable {
    let model: FieldSceneModel
    let isDark: Bool
    let season: FieldSeason
    let highlight: String?

    var body: some View {
        Canvas { ctx, size in
            let scale = size.width / FieldSceneModel.size.width
            ctx.scaleBy(x: scale, y: scale)
            FieldPainter(ctx: ctx, model: model, isDark: isDark, season: season, highlight: highlight, chinese: false).paintPlots()
        }
    }
}

private struct FieldFrontSceneryCanvas: View, Equatable {
    let isDark: Bool
    let season: FieldSeason

    var body: some View {
        Canvas { ctx, size in
            let scale = size.width / FieldSceneModel.size.width
            ctx.scaleBy(x: scale, y: scale)
            FieldPainter(ctx: ctx, model: .empty, isDark: isDark, season: season, highlight: nil, chinese: false).paintFrontScenery()
        }
    }
}

private struct FieldSignsCanvas: View, Equatable {
    let model: FieldSceneModel
    let isDark: Bool
    let season: FieldSeason
    let highlight: String?
    let chinese: Bool
    let compact: Bool

    var body: some View {
        Canvas { ctx, size in
            let scale = size.width / FieldSceneModel.size.width
            ctx.scaleBy(x: scale, y: scale)
            FieldPainter(ctx: ctx, model: model, isDark: isDark, season: season, highlight: highlight, chinese: chinese, compact: compact).paintSigns()
        }
    }
}

/// The moving parts of the scene: water wheel, chimney smoke and, at night, fireflies.
/// Drawn as a light layer over the static farm; holds still with Reduce Motion and on share cards.
private struct FieldAmbience: View {
    let isDark: Bool
    let season: FieldSeason
    /// Share cards and Reduce Motion keep the single still frame they always had.
    let animate: Bool
    let windowVisible: Bool

    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.controlActiveState) private var controlActiveState

    /// Same conditions the Confluence particles pause on; the 20 fps redraw is pointless off screen.
    private var isRunning: Bool { appearsActive && controlActiveState == .key && windowVisible }

    var body: some View {
        Group {
            if animate {
                // Pausing the schedule stops the redraw. The phase comes from wall-clock time, so the
                // frame it stops on is the frame it resumes from.
                TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !isRunning)) { timeline in
                    canvas(timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                canvas(0)
            }
        }
        .allowsHitTesting(false)
    }

    private func canvas(_ t: Double) -> some View {
        Canvas { ctx, size in
            let scale = size.width / FieldSceneModel.size.width
            ctx.scaleBy(x: scale, y: scale)
            FieldPainter(ctx: ctx, model: .empty, isDark: isDark, season: season, highlight: nil, chinese: false).ambience(CGFloat(t))
        }
    }
}

private struct FieldTooltip: View {
    let plot: FieldPlot
    let total: Int64
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(plot.name) · \(plot.crop.label(locale: locale))")
                .font(FieldFont.serif(12.5, weight: .semibold))
                .foregroundStyle(FieldPalette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            (Text("\(TokenFormat.short(plot.value)) tokens")
                + Text(verbatim: " · \(FieldFormat.percent(plot.value, of: total, locale: locale))"))
                .font(FieldFont.serif(12.5))
                .foregroundStyle(FieldPalette.ink)
                .monospacedDigit()
                .lineLimit(1)
            Text("\(plot.value.formatted(.number.locale(locale))) tokens")
                .font(FieldFont.serif(11))
                .foregroundStyle(FieldPalette.muted)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(FieldPalette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(FieldPalette.rule, lineWidth: 1))
        .shadow(color: Color.black.opacity(scheme == .dark ? 0.30 : 0.12), radius: 6, y: 2)
    }
}

enum FieldFormat {
    static func percent(_ value: Int64, of total: Int64, locale: Locale = .current) -> String {
        Share.percent(value, of: total, locale: locale)
    }
}

// MARK: - Painter

private struct SeasonPalette {
    let sky, meadow, meadow2, far, near: FieldRGB
    let leaf, leaf2, bloom: FieldRGB?

    init(_ season: FieldSeason) {
        switch season {
        case .spring:
            sky = FieldRGB("#EEF1E2"); meadow = FieldRGB("#CDD8A3"); meadow2 = FieldRGB("#B7C78C"); far = FieldRGB("#CBD5B6"); near = FieldRGB("#AFC191")
            leaf = FieldRGB("#8DB16A"); leaf2 = FieldRGB("#6F9550"); bloom = FieldRGB("#F0C4CB")
        case .summer:
            sky = FieldRGB("#EAF0E4"); meadow = FieldRGB("#C0D093"); meadow2 = FieldRGB("#A7BC7B"); far = FieldRGB("#C2CDA8"); near = FieldRGB("#9DB27C")
            leaf = FieldRGB("#709A50"); leaf2 = FieldRGB("#587F3E"); bloom = nil
        case .autumn:
            sky = FieldRGB("#F4ECDB"); meadow = FieldRGB("#D9D19F"); meadow2 = FieldRGB("#C7BC86"); far = FieldRGB("#DACDA9"); near = FieldRGB("#C5B182")
            leaf = FieldRGB("#D69548"); leaf2 = FieldRGB("#BA6A3B"); bloom = nil
        case .winter:
            sky = FieldRGB("#ECEEEB"); meadow = FieldRGB("#E7E6DC"); meadow2 = FieldRGB("#D3D3C7"); far = FieldRGB("#DCDED7"); near = FieldRGB("#C9CCC2")
            leaf = nil; leaf2 = nil; bloom = nil
        }
    }
}

private struct CropColors {
    let col, lt, dk, leaf, leaf2, straw, bush, bushLt: FieldRGB
    let fruit: FieldRGB?
    let snow: Bool
}

private struct FieldPainter {
    let ctx: GraphicsContext
    let model: FieldSceneModel
    let isDark: Bool
    let season: FieldSeason
    let highlight: String?
    let chinese: Bool
    var compact = false

    private let c: FieldColors
    private let pal: SeasonPalette
    private let W = FieldSceneModel.size.width, H = FieldSceneModel.size.height
    private let wind: CGFloat = 1.3

    init(ctx: GraphicsContext, model: FieldSceneModel, isDark: Bool, season: FieldSeason, highlight: String?, chinese: Bool, compact: Bool = false) {
        self.ctx = ctx; self.model = model; self.isDark = isDark; self.season = season; self.highlight = highlight; self.chinese = chinese; self.compact = compact
        c = FieldColors.cached(isDark: isDark)
        pal = SeasonPalette(season)
    }

    private var sun: CGFloat { isDark ? -1 : 1 }
    private func tone(_ rgb: FieldRGB) -> FieldRGB { isDark ? rgb.mix(FieldRGB("#151A17"), 0.34) : rgb }
    private func P(_ u: CGFloat, _ v: CGFloat) -> CGPoint { FieldSceneModel.project(u, v) }
    private func fill(_ p: Path, _ rgb: FieldRGB, in g: GraphicsContext? = nil) { (g ?? ctx).fill(p, with: .color(rgb.color)) }
    private func stroke(_ p: Path, _ rgb: FieldRGB, _ w: CGFloat, in g: GraphicsContext? = nil) {
        (g ?? ctx).stroke(p, with: .color(rgb.color), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
    }

    // MARK: Shapes

    private static func smooth(_ pts: [CGPoint], closed: Bool = true) -> Path {
        var p = Path()
        guard pts.count > 1 else { return p }
        let n = pts.count
        func at(_ i: Int) -> CGPoint { closed ? pts[(i % n + n) % n] : pts[max(0, min(n - 1, i))] }
        p.move(to: pts[0])
        for i in 0..<(closed ? n : n - 1) {
            let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
            p.addCurve(to: p2,
                       control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                       control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        if closed { p.closeSubpath() }
        return p
    }

    /// A plot outline with rounded corners and gently wobbling edges.
    private static func blob(_ corners: [CGPoint], seed: String, jitter: CGFloat = 1.8, step: CGFloat = 28, round: CGFloat = 7) -> Path {
        var r = FieldRNG(seed), pts: [CGPoint] = []
        for (i, a) in corners.enumerated() {
            let b = corners[(i + 1) % corners.count], L = max(1, hypot(b.x - a.x, b.y - a.y))
            let nx = -(b.y - a.y) / L, ny = (b.x - a.x) / L, rr = min(0.45, round / L), n = max(2, Int((L / step).rounded()))
            for s in 0...n {
                let t = rr + (1 - 2 * rr) * CGFloat(s) / CGFloat(n), o = (s == 0 || s == n) ? 0 : (CGFloat(r.next()) - 0.5) * jitter * 2
                pts.append(CGPoint(x: a.x + (b.x - a.x) * t + nx * o, y: a.y + (b.y - a.y) * t + ny * o))
            }
        }
        return smooth(pts)
    }

    private static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, deg: CGFloat = 0, pivot: CGPoint? = nil) -> Path {
        let p = Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
        guard deg != 0 else { return p }
        let o = pivot ?? CGPoint(x: cx, y: cy)
        return p.applying(CGAffineTransform(translationX: o.x, y: o.y).rotated(by: deg * .pi / 180).translatedBy(x: -o.x, y: -o.y))
    }

    private static func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path { ellipse(x, y, r, r) }

    private static func leaf(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat, deg: CGFloat = 0) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: x, y: y))
        p.addCurve(to: CGPoint(x: x, y: y - s * 1.2), control1: CGPoint(x: x - s, y: y - s * 0.35), control2: CGPoint(x: x - s * 0.85, y: y - s * 1.35))
        p.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x + s * 0.85, y: y - s * 1.35), control2: CGPoint(x: x + s, y: y - s * 0.35))
        p.closeSubpath()
        guard deg != 0 else { return p }
        return p.applying(CGAffineTransform(translationX: x, y: y).rotated(by: deg * .pi / 180).translatedBy(x: -x, y: -y))
    }

    private static func tuft(_ x: CGFloat, _ y: CGFloat, _ h: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: x - h * 0.5, y: y)); p.addQuadCurve(to: CGPoint(x: x - h * 0.6, y: y - h), control: CGPoint(x: x - h * 0.4, y: y - h * 0.6))
        p.move(to: CGPoint(x: x, y: y)); p.addQuadCurve(to: CGPoint(x: x + h * 0.25, y: y - h * 1.2), control: CGPoint(x: x + h * 0.05, y: y - h * 0.7))
        p.move(to: CGPoint(x: x + h * 0.45, y: y)); p.addQuadCurve(to: CGPoint(x: x + h * 0.8, y: y - h * 0.85), control: CGPoint(x: x + h * 0.4, y: y - h * 0.5))
        return p
    }

    private static func line(_ a: CGPoint, _ b: CGPoint) -> Path {
        var p = Path(); p.move(to: a); p.addLine(to: b); return p
    }

    // MARK: Scene

    func paintBackScenery() {
        sky()
        let (farAt, _) = hills()
        _ = farAt
        meadow()
        leftMeadow()
        farmhouse()
        let riverAt = river()
        irrigation(riverAt: riverAt)
        lane(riverAt: riverAt)
    }

    func paintPlots() {
        fields()
    }

    func paintFrontScenery() {
        hedge()
        bridge(riverAt: Self.riverX)
        fence()
        bigTree()
        foreground()
        overlays()
    }

    func paintSigns() {
        signs()
    }

    private func sky() {
        fill(Path(CGRect(origin: .zero, size: FieldSceneModel.size)), isDark ? FieldRGB("#182026") : pal.sky)
        if !isDark {
            let s = CGPoint(x: 1010, y: 82)
            fill(Self.dot(s.x, s.y, 62), c.sun.opacity(0.08)); fill(Self.dot(s.x, s.y, 44), c.sun.opacity(0.14)); fill(Self.dot(s.x, s.y, 27), c.sun)
            var rays = Path()
            for i in 0..<16 {
                let a = CGFloat(i) / 16 * .pi * 2 + 0.1, r0: CGFloat = 50 + CGFloat(i % 2) * 4, r1 = r0 + 9 + CGFloat(i % 2) * 5
                rays.move(to: CGPoint(x: s.x + cos(a) * r0, y: s.y + sin(a) * r0)); rays.addLine(to: CGPoint(x: s.x + cos(a) * r1, y: s.y + sin(a) * r1))
            }
            stroke(rays, c.sun.opacity(0.7), 2)
            for (x, y, w) in [(380.0, 92.0, 110.0), (720.0, 58.0, 72.0)] as [(CGFloat, CGFloat, CGFloat)] {
                var cloud = Path()
                for (dx, dy, rr) in [(0.0, 0.0, 0.3), (0.28, -0.28, 0.34), (0.6, -0.16, 0.3), (0.86, 0.02, 0.22)] as [(CGFloat, CGFloat, CGFloat)] {
                    cloud.addEllipse(in: CGRect(x: x + dx * w - rr * w, y: y + dy * w * 0.5 - rr * w * 0.62, width: rr * w * 2, height: rr * w * 1.24))
                }
                cloud.addRoundedRect(in: CGRect(x: x - 0.2 * w, y: y - 2, width: w * 1.2, height: w * 0.14), cornerSize: CGSize(width: w * 0.07, height: w * 0.07))
                fill(cloud, FieldRGB("#FBF8F0", alpha: 0.92))
            }
            if season != .winter {
                var birds = Path()
                for (x, y, w) in [(600.0, 120.0, 9.0), (626.0, 108.0, 7.0), (648.0, 126.0, 6.0), (820.0, 96.0, 5.0)] as [(CGFloat, CGFloat, CGFloat)] {
                    birds.move(to: CGPoint(x: x - w, y: y - w * 0.4))
                    birds.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: x - w * 0.5, y: y - w * 0.5))
                    birds.addQuadCurve(to: CGPoint(x: x + w, y: y - w * 0.4), control: CGPoint(x: x + w * 0.5, y: y - w * 0.5))
                }
                stroke(birds, c.ink2, 1.4)
            }
        } else {
            let m = CGPoint(x: 210, y: 82)
            fill(Self.dot(m.x, m.y, 70), c.sun.opacity(0.05)); fill(Self.dot(m.x, m.y, 42), c.sun.opacity(0.09))
            var moon = Path()
            moon.addEllipse(in: CGRect(x: m.x - 27, y: m.y - 27, width: 54, height: 54))
            let cut = Path(ellipseIn: CGRect(x: m.x - 10, y: m.y - 33, width: 48, height: 48))
            fill(moon.subtracting(cut), c.sun)
            var r = FieldRNG("stars"), stars = Path(), bright = Path()
            for i in 0..<70 {
                let d = Self.dot(CGFloat(r.next()) * W, 8 + CGFloat(r.next()) * 150, 0.6 + CGFloat(r.next()) * 1.1)
                if i % 5 == 0 { bright.addPath(d) } else { stars.addPath(d) }
            }
            fill(stars, FieldRGB("#E9E3CE", alpha: 0.55)); fill(bright, FieldRGB("#F3EED9"))
        }
    }

    private func hills() -> ((CGFloat) -> CGFloat, (CGFloat) -> CGFloat) {
        func ridge(_ base: CGFloat, _ amp: CGFloat, _ wl: CGFloat, _ seed: String) -> (Path, (CGFloat) -> CGFloat) {
            var r = FieldRNG(seed), pts: [CGPoint] = []
            let ph = CGFloat(r.next()) * 6
            var x: CGFloat = -40
            while x < W + 40 + wl { pts.append(CGPoint(x: x, y: base - amp * (0.5 + 0.5 * sin(x / wl * 1.1 + ph)) - CGFloat(r.next()) * amp * 0.35)); x += wl }
            let at: (CGFloat) -> CGFloat = { x in
                let i = max(0, min(pts.count - 2, Int((x + 40) / wl))), t = (x - pts[i].x) / wl
                return pts[i].y + (pts[i + 1].y - pts[i].y) * t
            }
            var p = Self.smooth(pts, closed: false)
            p.addLine(to: CGPoint(x: W + 40, y: H)); p.addLine(to: CGPoint(x: -40, y: H)); p.closeSubpath()
            return (p, at)
        }
        let (farPath, farAt) = ridge(196, 70, 150, "far"), (nearPath, nearAt) = ridge(226, 38, 120, "near")
        fill(farPath, tone(pal.far))
        var r = FieldRNG("ftrees"), trunks = Path(), crowns = Path()
        for _ in 0..<26 {
            let x = 30 + CGFloat(r.next()) * (W - 60), y = farAt(x) + 6 + CGFloat(r.next()) * 8, h = 7 + CGFloat(r.next()) * 6
            trunks.addPath(Self.line(CGPoint(x: x, y: y), CGPoint(x: x, y: y - h * 0.6)))
            if pal.leaf != nil { crowns.addPath(Self.ellipse(x, y - h, h * 0.42, h * 0.55)) } else {
                trunks.addPath(Self.line(CGPoint(x: x, y: y - h * 0.6), CGPoint(x: x - h * 0.3, y: y - h * 1.1)))
                trunks.addPath(Self.line(CGPoint(x: x, y: y - h * 0.6), CGPoint(x: x + h * 0.3, y: y - h * 1.2)))
            }
        }
        stroke(trunks, tone(FieldRGB("#8A7457")).opacity(0.7), 1.1)
        fill(crowns, tone(pal.leaf2 ?? FieldRGB("#999999")).opacity(0.55))
        fill(nearPath, tone(pal.near))
        var h = Path()
        for _ in 0..<40 {
            let x = CGFloat(r.next()) * W, y = nearAt(x) + 4 + CGFloat(r.next()) * 18
            h.addPath(Self.line(CGPoint(x: x, y: y), CGPoint(x: x + 7 + CGFloat(r.next()) * 6, y: y - 3 - CGFloat(r.next()) * 2)))
        }
        stroke(h, tone(pal.meadow2).opacity(0.8), 1.2)
        return (farAt, nearAt)
    }

    private func meadow() {
        var p = Path()
        p.move(to: CGPoint(x: -10, y: H)); p.addLine(to: CGPoint(x: -10, y: 246))
        p.addQuadCurve(to: CGPoint(x: 600, y: 242), control: CGPoint(x: 300, y: 236))
        p.addQuadCurve(to: CGPoint(x: 1210, y: 240), control: CGPoint(x: 900, y: 248))
        p.addLine(to: CGPoint(x: 1210, y: H)); p.closeSubpath()
        fill(p, tone(pal.meadow))
        var r = FieldRNG("meadow"), g = Path()
        for _ in 0..<150 { let x = CGFloat(r.next()) * W, y = 250 + CGFloat(r.next()) * (H - 250); g.addPath(Self.tuft(x, y, 3 + CGFloat(r.next()) * 4 * (y / H + 0.4))) }
        stroke(g, tone(pal.meadow2), 1.1)
    }

    private func leftMeadow() {
        let bark = tone(FieldRGB("#7B5E3E"))
        for (x, y, z) in [(34.0, 420.0, 1.0), (70.0, 520.0, 0.8), (22.0, 600.0, 1.15)] as [(CGFloat, CGFloat, CGFloat)] {
            fill(Self.ellipse(x - sun * 10 * z, y + 2, 16 * z, 4 * z), c.groundShadow)
            stroke(Self.line(CGPoint(x: x, y: y), CGPoint(x: x, y: y - 22 * z)), bark, 3 * z)
            if let leaf = pal.leaf, let leaf2 = pal.leaf2 {
                fill(Self.dot(x, y - 32 * z, 15 * z), tone(leaf2)); fill(Self.dot(x - 5 * z, y - 37 * z, 9 * z), tone(leaf))
            } else {
                var b = Path()
                b.addPath(Self.line(CGPoint(x: x, y: y - 20 * z), CGPoint(x: x - 9 * z, y: y - 36 * z)))
                b.addPath(Self.line(CGPoint(x: x, y: y - 22 * z), CGPoint(x: x + 8 * z, y: y - 40 * z)))
                stroke(b, bark, 1.4)
            }
        }
        guard season != .winter else { return }
        for (x, y, d) in [(58.0, 468.0, 1.0), (86.0, 474.0, -1.0), (44.0, 662.0, 1.0)] as [(CGFloat, CGFloat, CGFloat)] {
            fill(Self.ellipse(x - sun * 5, y + 1, 10, 2.4), c.groundShadow)
            var legs = Path(); legs.addPath(Self.line(CGPoint(x: x - 5, y: y), CGPoint(x: x - 5, y: y - 5))); legs.addPath(Self.line(CGPoint(x: x + 4, y: y), CGPoint(x: x + 4, y: y - 5)))
            stroke(legs, tone(FieldRGB("#3E3A33")), 1.6)
            let body = Self.ellipse(x, y - 8, 9, 6)
            fill(body, isDark ? FieldRGB("#8F8C80") : FieldRGB("#F7F3E8")); stroke(body, tone(FieldRGB("#B5AE9C")), 0.8)
            fill(Self.ellipse(x + d * 9, y - 5, 3.2, 2.6), tone(FieldRGB("#3E3A33")))
        }
    }

    private func farmhouse() {
        let hx: CGFloat = 1068, hy: CGFloat = 300, w: CGFloat = 64, hgt: CGFloat = 36, side: CGFloat = 26
        let wall = isDark ? FieldRGB("#3B382D") : FieldRGB("#F1E6CC"), wallSide = isDark ? FieldRGB("#2E2C23") : FieldRGB("#DCCDAA")
        let roof = isDark ? c.accent.mix(FieldRGB("#1D1D18"), 0.55) : c.accent.mix(.white, 0.8), line = tone(FieldRGB("#6E5B40"))
        let win = isDark ? FieldRGB("#F2C46B") : FieldRGB("#AFC2C5")
        if isDark {
            var glow = ctx
            glow.addFilter(.blur(radius: 10))
            glow.fill(Self.dot(hx + 20, hy - 16, 26), with: .color(FieldRGB("#F2C46B", alpha: 0.25).color))
        }
        fill(Self.ellipse(hx + w / 2 + 6 - sun * 8, hy + 3, w * 0.75, 7), c.groundShadow)
        func poly(_ pts: [CGPoint], _ rgb: FieldRGB) { var p = Path(); p.addLines(pts); p.closeSubpath(); fill(p, rgb); stroke(p, line, 1) }
        poly([CGPoint(x: hx, y: hy), CGPoint(x: hx, y: hy - hgt), CGPoint(x: hx + w, y: hy - hgt), CGPoint(x: hx + w, y: hy)], wall)
        poly([CGPoint(x: hx + w, y: hy), CGPoint(x: hx + w, y: hy - hgt), CGPoint(x: hx + w + side, y: hy - hgt - 10), CGPoint(x: hx + w + side, y: hy - 10)], wallSide)
        poly([CGPoint(x: hx - 6, y: hy - hgt + 2), CGPoint(x: hx + w / 2, y: hy - hgt - 26), CGPoint(x: hx + w + 6, y: hy - hgt + 2)], roof)
        poly([CGPoint(x: hx + w / 2, y: hy - hgt - 26), CGPoint(x: hx + w / 2 + side, y: hy - hgt - 36), CGPoint(x: hx + w + side + 5, y: hy - hgt - 8), CGPoint(x: hx + w + 6, y: hy - hgt + 2)], roof.mix(.init(r: 0, g: 0, b: 0), 0.9))
        if season == .winter {
            var snow = Path(); snow.addLines([CGPoint(x: hx - 4, y: hy - hgt), CGPoint(x: hx + w / 2, y: hy - hgt - 24), CGPoint(x: hx + w / 2 + side, y: hy - hgt - 34)])
            stroke(snow, FieldRGB("#FAFAF6"), 4)
        }
        fill(Path(CGRect(x: hx + 26, y: hy - 20, width: 12, height: 20)), c.post)
        for x in [hx + 8, hx + 45] { let p = Path(CGRect(x: x, y: hy - 26, width: 11, height: 10)); fill(p, win); stroke(p, line, 0.8) }
        poly([CGPoint(x: hx + 46, y: hy - hgt - 14), CGPoint(x: hx + 46, y: hy - hgt - 30), CGPoint(x: hx + 53, y: hy - hgt - 30), CGPoint(x: hx + 53, y: hy - hgt - 14)], wallSide)
        // The silo echoes the granary.
        let sx: CGFloat = 1146, sw: CGFloat = 26, sh: CGFloat = 60
        poly([CGPoint(x: sx, y: hy), CGPoint(x: sx, y: hy - sh), CGPoint(x: sx + sw, y: hy - sh), CGPoint(x: sx + sw, y: hy)], wallSide)
        var dome = Path(); dome.move(to: CGPoint(x: sx, y: hy - sh)); dome.addQuadCurve(to: CGPoint(x: sx + sw, y: hy - sh), control: CGPoint(x: sx + sw / 2, y: hy - sh - 18)); dome.closeSubpath()
        fill(dome, roof); stroke(dome, line, 1)
        if season == .autumn || season == .summer {
            var stack = Path()
            stack.move(to: CGPoint(x: hx - 34, y: hy + 4))
            stack.addQuadCurve(to: CGPoint(x: hx - 18, y: hy - 26), control: CGPoint(x: hx - 34, y: hy - 26))
            stack.addQuadCurve(to: CGPoint(x: hx - 2, y: hy + 4), control: CGPoint(x: hx - 2, y: hy - 26))
            stack.closeSubpath()
            fill(stack, tone(FieldRGB("#D8B45E"))); stroke(stack, tone(FieldRGB("#A88A3E")), 1)
        }
    }

    private static let riverPoints: [CGPoint] = [(-20, 236), (60, 238), (116, 252), (150, 282), (140, 340), (116, 400), (134, 470), (152, 540), (128, 610), (96, 680), (66, 750), (36, 830)].map { CGPoint(x: $0.0, y: $0.1) }
    private static func riverWidth(_ y: CGFloat) -> CGFloat { 7 + max(0, y - 236) / 560 * 34 }

    private static func riverX(_ y: CGFloat) -> CGFloat {
        let pts = riverPoints
        for i in 0..<(pts.count - 1) where y >= pts[i].y && y <= pts[i + 1].y {
            return pts[i].x + (pts[i + 1].x - pts[i].x) * (y - pts[i].y) / (pts[i + 1].y - pts[i].y)
        }
        return pts[0].x
    }

    private func river() -> (CGFloat) -> CGFloat {
        let pts = Self.riverPoints
        let at: (CGFloat) -> CGFloat = Self.riverX
        var left: [CGPoint] = [], right: [CGPoint] = [], lb: [CGPoint] = [], rb: [CGPoint] = []
        for (i, p) in pts.enumerated() {
            let q = pts[min(pts.count - 1, i + 1)], pp = pts[max(0, i - 1)]
            let dx = q.x - pp.x, dy = q.y - pp.y, L = max(1, hypot(dx, dy)), nx = -dy / L, ny = dx / L, w = Self.riverWidth(p.y)
            left.append(CGPoint(x: p.x + nx * w / 2, y: p.y + ny * w / 2)); right.append(CGPoint(x: p.x - nx * w / 2, y: p.y - ny * w / 2))
            lb.append(CGPoint(x: p.x + nx * (w / 2 + 5), y: p.y + ny * (w / 2 + 5))); rb.append(CGPoint(x: p.x - nx * (w / 2 + 5), y: p.y - ny * (w / 2 + 5)))
        }
        fill(Self.smooth(lb + rb.reversed()), bank)
        fill(Self.smooth(left + right.reversed()), water)
        var r = FieldRNG("ripple"), rp = Path()
        for _ in 0..<46 {
            let y = 250 + CGFloat(r.next()) * 560, x = at(y) + (CGFloat(r.next()) - 0.5) * Self.riverWidth(y) * 0.6, l = 3 + Self.riverWidth(y) * 0.25
            rp.move(to: CGPoint(x: x - l / 2, y: y)); rp.addQuadCurve(to: CGPoint(x: x + l / 2, y: y), control: CGPoint(x: x, y: y - 1.4))
        }
        stroke(rp, (isDark ? FieldRGB("#6F8F96") : FieldRGB("#E6F0EE")).opacity(0.8), 1.1)
        if isDark {
            var m = Path()
            for i in 0..<6 { let y = 318 + CGFloat(i) * 9, x = at(y); m.addPath(Self.line(CGPoint(x: x - 5 + CGFloat(i % 2) * 2, y: y), CGPoint(x: x + 4 - CGFloat(i), y: y))) }
            stroke(m, c.sun.opacity(0.55), 2)
        }
        var reed = Path(), cat = Path()
        for (j, (y, side)) in ([(300.0, 1.0), (372.0, -1.0), (452.0, 1.0), (560.0, -1.0), (690.0, 1.0)] as [(CGFloat, CGFloat)]).enumerated() {
            let x = at(y) + side * (Self.riverWidth(y) / 2 + 3)
            for i in 0..<5 {
                let bx = x + CGFloat(i - 2) * 2.2, h = 12 + CGFloat((i * 7 + j * 3) % 9), tip = CGPoint(x: bx + 1.5 + CGFloat(i) * 0.4, y: y - h)
                reed.move(to: CGPoint(x: bx, y: y)); reed.addQuadCurve(to: tip, control: CGPoint(x: bx + 1 + CGFloat(i) * 0.3, y: y - h * 0.6))
                if i % 2 == 0 { cat.addPath(Self.ellipse(tip.x, tip.y - 2, 1.4, 3.2)) }
            }
        }
        stroke(reed, tone(season == .winter ? FieldRGB("#A99E83") : FieldRGB("#7E8E57")), 1)
        fill(cat, tone(FieldRGB("#8A6A44")))
        return at
    }

    private var water: FieldRGB { isDark ? FieldRGB("#2C4650") : FieldRGB("#9CBEC4") }
    private var bank: FieldRGB { isDark ? FieldRGB("#26302A") : tone(pal.meadow2) }

    private func irrigation(riverAt: (CGFloat) -> CGFloat) {
        let gap = FieldSceneModel.gap, plan = FieldSceneModel.plan
        let c0 = P(-gap * 0.2, gap * 0.45), c1 = P(plan.width, gap * 0.45)
        var canal = Path()
        canal.move(to: CGPoint(x: riverAt(282) + 4, y: 282)); canal.addQuadCurve(to: c0, control: CGPoint(x: c0.x - 30, y: c0.y + 2)); canal.addLine(to: c1)
        stroke(canal, bank, 9); stroke(canal, water, 5)
        var ditches = Path()
        for plot in model.plots {
            let p = plot.plan
            if p.minX > gap + 1 { ditches.addPath(Self.line(P(p.minX - gap / 2, p.minY - gap / 2), P(p.minX - gap / 2, p.maxY + gap / 2))) }
            if p.minY > gap + 1 { ditches.addPath(Self.line(P(p.minX - gap / 2, p.minY - gap / 2), P(p.maxX + gap / 2, p.minY - gap / 2))) }
        }
        ditches.addPath(Self.line(P(gap / 2, gap / 2), P(gap / 2, plan.height)))
        stroke(ditches, water.opacity(0.9), 2.4)
        // Trodden ground under the farm.
        let plan2 = FieldSceneModel.plan
        fill(Self.blob([P(0, 0), P(plan2.width, 0), P(plan2.width, plan2.height), P(0, plan2.height)], seed: "farm", jitter: 2.5, step: 40, round: 12), tone(pal.meadow2).opacity(0.55))
    }

    private var laneY: (left: CGPoint, right: CGPoint) {
        let v = FieldSceneModel.plan.height + 30
        return (P(-40, v), P(FieldSceneModel.plan.width + 40, v))
    }

    private func lane(riverAt: (CGFloat) -> CGFloat) {
        let (l, r) = laneY
        var p = Path()
        p.move(to: CGPoint(x: riverAt(l.y) - 40, y: l.y + 4)); p.addLine(to: r)
        p.addQuadCurve(to: CGPoint(x: 1070, y: r.y - 90), control: CGPoint(x: r.x + 60, y: r.y - 4))
        p.addQuadCurve(to: CGPoint(x: 1098, y: 304), control: CGPoint(x: 1080, y: r.y - 180))
        let dirt = isDark ? FieldRGB("#3A3629") : c.path.mix(c.soilL, 0.55)
        stroke(p, dirt, 22)
        var ruts = Path()
        ruts.addPath(Self.line(CGPoint(x: riverAt(l.y) + 30, y: l.y - 3), CGPoint(x: r.x - 20, y: r.y - 3)))
        ruts.addPath(Self.line(CGPoint(x: riverAt(l.y) + 30, y: l.y + 5), CGPoint(x: r.x - 20, y: r.y + 5)))
        ctx.stroke(ruts, with: .color(tone(FieldRGB("#BCA77B")).opacity(0.7).color), style: StrokeStyle(lineWidth: 1.2, dash: [14, 6, 30, 8]))
    }

    // MARK: Fields

    private func colors(_ crop: FieldCrop) -> CropColors {
        let col = c.crops[crop.rawValue]
        return CropColors(
            col: col, lt: col.mix(.white, 0.5), dk: col.mix(FieldRGB("#1D1A12"), 0.68),
            leaf: c.stem.mix(.white, 0.8), leaf2: c.stem, straw: col.mix(c.stem, 0.55),
            bush: c.stem.mix(FieldRGB("#8F9A90"), 0.55), bushLt: c.stem.mix(FieldRGB("#C9CFC4"), 0.3),
            fruit: crop == .orchard ? (season == .spring ? FieldRGB("#F3D0D6") : season == .winter ? nil : c.crops[FieldCrop.pumpkin.rawValue]) : nil,
            snow: season == .winter
        )
    }

    private static let groundShare: [FieldCrop: Double] = [.wheat: 0.52, .lavender: 0.3, .pumpkin: 0.16, .cabbage: 0.18, .tea: 0.2, .rapeseed: 0.5, .orchard: 0.22, .buckwheat: 0.36, .flax: 0.4, .corn: 0.26]
    private static let shadowSize: [FieldCrop: CGFloat] = [.wheat: 6, .lavender: 8, .pumpkin: 7, .cabbage: 6.5, .tea: 0, .rapeseed: 5, .orchard: 9, .buckwheat: 5, .flax: 4, .corn: 6]

    private struct Spot { let x, y, k: CGFloat }

    /// Fixed planting density: rows across the view, so plant count tracks plot area and therefore tokens.
    private static func planting(_ plot: FieldPlot) -> [[Spot]] {
        let s: CGFloat = 22, sr = s * 1.15, sa = s / 1.15, pad = s * 0.45, p = plot.plan
        guard p.width >= s * 0.9, p.height >= s * 0.9 else { return [] }
        let nRow = max(1, Int((p.height - pad) / sr)), nCol = max(1, Int((p.width - pad) / sa))
        let v0 = p.minY + (p.height - CGFloat(nRow) * sr) / 2 + sr / 2, u0 = p.minX + (p.width - CGFloat(nCol) * sa) / 2 + sa / 2
        let kBase = FieldSceneModel.nearWidth / FieldSceneModel.plan.width
        var r = FieldRNG("plant" + plot.id), rows: [[Spot]] = []
        for a in 0..<nRow {
            let wave = CGFloat(r.next()) * 6
            var row: [Spot] = []
            for b in 0..<nCol {
                let u = u0 + CGFloat(b) * sa + (CGFloat(r.next()) - 0.5) * sa * 0.5
                let v = v0 + CGFloat(a) * sr + sin(CGFloat(b) * 0.5 + wave) * sr * 0.12 + (CGFloat(r.next()) - 0.5) * sr * 0.2
                let pt = FieldSceneModel.project(u, v)
                row.append(Spot(x: pt.x, y: pt.y, k: kBase * FieldSceneModel.depthScale(v) * (0.86 + CGFloat(r.next()) * 0.28)))
            }
            rows.append(row)
        }
        return rows
    }

    private func fields() {
        let ordered = model.plots.sorted { $0.plan.maxY < $1.plan.maxY }
        let soilBase = isDark ? c.soil : FieldRGB("#D8C69C")
        var plantings: [String: [[Spot]]] = [:]
        for plot in ordered { plantings[plot.id] = Self.planting(plot) }
        // Plots first, so near crops can overlap far plots.
        for plot in ordered {
            var g = ctx
            if let highlight, highlight != plot.id { g.opacity = 0.3 }
            let shape = Self.blob(plot.corners, seed: "b" + plot.id, jitter: 1.6, step: 26, round: 9)
            let col = c.crops[plot.crop.rawValue]
            fill(shape.offsetBy(dx: 0, dy: 3.5), isDark ? FieldRGB("#1E1F19") : c.soilR, in: g)
            fill(shape, col.mix(soilBase, Self.groundShare[plot.crop] ?? 0.25), in: g)
            var furrows = Path()
            for row in plantings[plot.id] ?? [] where row.count > 1 {
                furrows.addLines(row.map { CGPoint(x: $0.x, y: $0.y + 2.5) })
            }
            var clipped = g
            clipped.clip(to: shape)
            stroke(furrows, (isDark ? FieldRGB("#000000") : col.mix(FieldRGB("#6B5434"), 0.4)).opacity(0.32), 2.4, in: clipped)
            if season == .winter {
                var r = FieldRNG("snow" + plot.id), sn = Path()
                for _ in 0..<Int(plot.plan.width * plot.plan.height / 900) {
                    let pt = P(plot.plan.minX + CGFloat(r.next()) * plot.plan.width, plot.plan.minY + CGFloat(r.next()) * plot.plan.height)
                    sn.addPath(Self.line(pt, CGPoint(x: pt.x + 4 + CGFloat(r.next()) * 8, y: pt.y)))
                }
                stroke(sn, FieldRGB("#FAFAF6").opacity(0.75), 2.4, in: clipped)
            }
            stroke(shape, isDark ? FieldRGB("#55604A") : c.hedge.mix(.white, 0.7), 1.1, in: g)
        }
        // Ridge grass.
        var r = FieldRNG("ridgegrass"), grass = Path(), flowers = Path()
        for plot in model.plots {
            var t: CGFloat = 0
            while t < plot.plan.width {
                let pt = P(plot.plan.minX + t, plot.plan.maxY + FieldSceneModel.gap * 0.5)
                grass.addPath(Self.tuft(pt.x, pt.y, 4 + CGFloat(r.next()) * 3))
                if r.next() < 0.18, season != .winter { flowers.addPath(Self.dot(pt.x + 3, pt.y - 5, 1.6)) }
                t += 26 + CGFloat(r.next()) * 30
            }
        }
        stroke(grass, tone(pal.leaf2 ?? FieldRGB("#9A9A88")).opacity(0.8), 1)
        fill(flowers, season == .autumn ? c.crops[FieldCrop.pumpkin.rawValue] : FieldRGB("#F4F1E6"))
        // Crops, back to front.
        let biggest = model.plots.max { $0.value < $1.value }
        for plot in ordered {
            var g = ctx
            if let highlight, highlight != plot.id { g.opacity = 0.3 }
            let rows = plantings[plot.id] ?? []
            let cc = colors(plot.crop)
            var rng = FieldRNG(plot.id + "crop")
            if plot.crop == .tea {
                for row in rows where !row.isEmpty { teaRow(row, cc, g) }
            } else {
                var shadows = Path()
                let size = Self.shadowSize[plot.crop] ?? 6
                for row in rows { for s in row { let w = size * s.k; shadows.addPath(Self.ellipse(s.x - sun * w * 0.45, s.y + 0.5, w, w * 0.32)) } }
                fill(shadows, c.groundShadow, in: g)
                let scarecrowAt: CGPoint? = (plot.id == biggest?.id && !rows.isEmpty) ? P(plot.plan.minX + plot.plan.width * 0.62, plot.plan.minY + plot.plan.height * 0.55) : nil
                var scarecrowDrawn = false
                for row in rows {
                    if let at = scarecrowAt, !scarecrowDrawn, let y = row.first?.y, y > at.y { scarecrow(at, g); scarecrowDrawn = true }
                    for s in row { plant(plot.crop, s, &rng, cc, g) }
                }
                if let at = scarecrowAt, !scarecrowDrawn { scarecrow(at, g) }
            }
        }
    }

    private func teaRow(_ row: [Spot], _ cc: CropColors, _ g: GraphicsContext) {
        let k = row[0].k, a = row[0], b = row[row.count - 1]
        var top: [CGPoint] = [], bottom: [CGPoint] = []
        for (j, s) in row.enumerated() { top.append(CGPoint(x: s.x, y: s.y - (7.5 + CGFloat(j % 2) * 1.6) * k)); bottom.append(CGPoint(x: s.x, y: s.y)) }
        let band = Self.smooth([CGPoint(x: a.x - 6 * k, y: a.y), CGPoint(x: a.x - 7 * k, y: a.y - 5 * k)] + top + [CGPoint(x: b.x + 7 * k, y: b.y - 5 * k), CGPoint(x: b.x + 6 * k, y: b.y)] + bottom.reversed())
        stroke(Self.line(CGPoint(x: a.x - 5 * k, y: a.y + 2.5), CGPoint(x: b.x + 5 * k, y: b.y + 2.5)), c.groundShadow, 4 * k, in: g)
        fill(band, cc.dk, in: g)
        fill(band.offsetBy(dx: 0, dy: -1.4 * k), cc.col, in: g)
        var hl = Path()
        for s in row { hl.move(to: CGPoint(x: s.x - 4 * s.k, y: s.y - 7.6 * s.k)); hl.addQuadCurve(to: CGPoint(x: s.x + 4 * s.k, y: s.y - 7.6 * s.k), control: CGPoint(x: s.x, y: s.y - 10 * s.k)) }
        stroke(hl, cc.lt, 1.2 * k, in: g)
    }

    private func plant(_ crop: FieldCrop, _ s: Spot, _ r: inout FieldRNG, _ cc: CropColors, _ g: GraphicsContext) {
        let x = s.x, y = s.y, k = s.k
        func rnd() -> CGFloat { CGFloat(r.next()) }
        switch crop {
        case .wheat:
            var stalks = Path(), ears = Path(), ears2 = Path()
            let n = 4 + Int(rnd() * 3)
            for i in 0..<n {
                let dx = (CGFloat(i) - CGFloat(n - 1) / 2) * 2.3 * k + (rnd() - 0.5) * 1.4 * k, h = (16 + rnd() * 8) * k, lean = (rnd() - 0.5) * 4 * k + wind * k
                let tip = CGPoint(x: x + dx + lean, y: y - h), deg = atan2(lean, h) * 180 / .pi
                stalks.move(to: CGPoint(x: x + dx * 0.5, y: y)); stalks.addQuadCurve(to: tip, control: CGPoint(x: x + dx + lean * 0.15, y: y - h * 0.6))
                let e = Self.ellipse(tip.x, tip.y - 3 * k, 1.6 * k, 4 * k, deg: deg, pivot: tip)
                if rnd() < 0.55 { ears.addPath(e) } else { ears2.addPath(e) }
            }
            stroke(stalks, cc.straw, 0.75 * k, in: g); fill(ears, cc.col, in: g); fill(ears2, cc.lt, in: g)
        case .lavender:
            var stems = Path(), heads = Path(), heads2 = Path()
            let n = 8 + Int(rnd() * 4)
            for i in 0..<n {
                let a = (-58 + 116 * CGFloat(i) / CGFloat(n - 1) + (rnd() - 0.5) * 12) * .pi / 180, L = (9 + rnd() * 5) * k
                let base = CGPoint(x: x + sin(a) * 2.5 * k, y: y - 4 * k), tip = CGPoint(x: base.x + sin(a) * L, y: base.y - cos(a) * L)
                stems.addPath(Self.line(base, tip))
                let e = Self.ellipse(tip.x, tip.y, 1.35 * k, 3.3 * k, deg: a * 180 / .pi)
                if i % 3 == 0 { heads2.addPath(e) } else { heads.addPath(e) }
            }
            stroke(stems, cc.bush, 0.7 * k, in: g)
            fill(Self.ellipse(x, y - 2.6 * k, 7.5 * k, 4.2 * k), cc.bush, in: g)
            fill(Self.ellipse(x - 2 * k, y - 4 * k, 3.5 * k, 1.8 * k), cc.bushLt, in: g)
            fill(heads, cc.col, in: g); fill(heads2, cc.dk, in: g)
        case .pumpkin:
            for i in 0..<3 {
                let lx = x + (rnd() - 0.5) * 13 * k, ly = y - rnd() * 2.5 * k, sz = (3.6 + rnd() * 2.2) * k
                fill(Self.leaf(lx, ly, sz, deg: (rnd() - 0.5) * 120), i % 2 == 0 ? cc.leaf2 : cc.leaf, in: g)
            }
            if rnd() < 0.6 {
                let rx = (4 + rnd() * 3.4) * k, ry = rx * 0.74, px = x + (rnd() - 0.5) * 5 * k, py = y - ry + 0.5 * k
                let body = Self.ellipse(px, py, rx, ry)
                fill(body, cc.col, in: g); stroke(body, cc.dk, 0.6 * k, in: g)
                var ribs = Path()
                ribs.move(to: CGPoint(x: px, y: py - ry)); ribs.addQuadCurve(to: CGPoint(x: px, y: py + ry), control: CGPoint(x: px - rx * 0.6, y: py))
                ribs.move(to: CGPoint(x: px, y: py - ry)); ribs.addQuadCurve(to: CGPoint(x: px, y: py + ry), control: CGPoint(x: px + rx * 0.6, y: py))
                stroke(ribs, cc.dk.opacity(0.65), 0.55 * k, in: g)
                fill(Self.ellipse(px - rx * 0.42, py - ry * 0.35, rx * 0.22, ry * 0.2), cc.lt.opacity(0.75), in: g)
                var stem = Path(); stem.move(to: CGPoint(x: px, y: py - ry)); stem.addQuadCurve(to: CGPoint(x: px + 2.1 * k, y: py - ry - 2.4 * k), control: CGPoint(x: px + 0.6 * k, y: py - ry - 2 * k))
                stroke(stem, cc.leaf2, 1.3 * k, in: g)
            }
        case .cabbage:
            let cy = y - 3.2 * k
            let angles = (0..<7).map { CGFloat($0) / 7 * .pi * 2 + rnd() * 0.5 }.sorted { sin($0) < sin($1) }
            for (i, a) in angles.enumerated() {
                let lx = x + cos(a) * 4.4 * k, ly = cy + sin(a) * 2.3 * k, e = Self.ellipse(lx, ly, 4.6 * k, 2.8 * k, deg: a * 180 / .pi)
                fill(e, i % 2 == 0 ? cc.dk : cc.col, in: g); stroke(e, cc.dk, 0.4 * k, in: g)
            }
            let head = Self.dot(x, cy - 1.3 * k, 3.7 * k)
            fill(head, cc.lt, in: g); stroke(head, cc.col, 0.6 * k, in: g)
            var curl = Path(); curl.move(to: CGPoint(x: x - 2.5 * k, y: cy - k)); curl.addQuadCurve(to: CGPoint(x: x + 2.5 * k, y: cy - k), control: CGPoint(x: x, y: cy - 3.8 * k))
            stroke(curl, cc.col, 0.55 * k, in: g)
        case .tea:
            break
        case .rapeseed:
            var stems = Path(), fl = Path(), fl2 = Path()
            for i in 0..<3 {
                let dx = CGFloat(i - 1) * 2.6 * k + (rnd() - 0.5) * 2 * k, h = (11 + rnd() * 7) * k
                let tip = CGPoint(x: x + dx + (rnd() - 0.5) * 3 * k + wind * 0.6 * k, y: y - h)
                stems.move(to: CGPoint(x: x + dx * 0.4, y: y)); stems.addQuadCurve(to: tip, control: CGPoint(x: x + dx, y: y - h * 0.5))
                for j in 0..<5 { let d = Self.dot(tip.x + (rnd() - 0.5) * 3.6 * k, tip.y + (rnd() - 0.5) * 3.2 * k, (1 + rnd() * 0.7) * k); if j % 3 == 0 { fl2.addPath(d) } else { fl.addPath(d) } }
            }
            stroke(stems, cc.leaf2, 0.7 * k, in: g); fill(fl, cc.col, in: g); fill(fl2, cc.lt, in: g)
        case .orchard:
            let h = (9 + rnd() * 3) * k, R = (6.6 + rnd() * 2) * k, cx = x + (rnd() - 0.5) * 2 * k + wind * 0.5 * k, cy = y - h - R * 0.5
            var trunk = Path(); trunk.move(to: CGPoint(x: x, y: y)); trunk.addQuadCurve(to: CGPoint(x: cx, y: y - h), control: CGPoint(x: x, y: y - h * 0.6))
            stroke(trunk, c.post, 1.9 * k, in: g)
            for (dx, dy, sz, rgb) in [(-0.48, 0.18, 0.78, cc.dk), (0.46, 0.12, 0.8, cc.dk), (0, -0.22, 1, cc.col), (-0.28, -0.46, 0.5, cc.lt)] as [(CGFloat, CGFloat, CGFloat, FieldRGB)] {
                fill(Self.dot(cx + dx * R, cy + dy * R, R * sz), rgb, in: g)
            }
            if let fruit = cc.fruit { var d = Path(); for _ in 0..<4 { d.addPath(Self.dot(cx + (rnd() - 0.5) * R * 1.5, cy + (rnd() - 0.3) * R, 1.15 * k)) }; fill(d, fruit, in: g) }
            if cc.snow { var sn = Path(); sn.move(to: CGPoint(x: cx - R * 0.8, y: cy - R * 0.6)); sn.addQuadCurve(to: CGPoint(x: cx + R * 0.8, y: cy - R * 0.6), control: CGPoint(x: cx, y: cy - R * 1.45)); stroke(sn, .white, 2 * k, in: g) }
        case .buckwheat:
            var stems = Path(), fl = Path(), fl2 = Path()
            for i in 0..<3 {
                let dx = CGFloat(i - 1) * 3 * k + (rnd() - 0.5) * 2 * k, h = (10 + rnd() * 6) * k, tip = CGPoint(x: x + dx + (rnd() - 0.5) * 2 * k + wind * 0.4 * k, y: y - h)
                stems.addPath(Self.line(CGPoint(x: x + dx * 0.5, y: y), tip))
                fill(Self.leaf(x + dx * 0.75, y - h * 0.45, 2.5 * k, deg: dx > 0 ? 55 : -55), cc.leaf, in: g)
                for j in 0..<4 { let d = Self.dot(tip.x + (CGFloat(j) - 1.5) * 1.5 * k, tip.y - CGFloat(j % 2) * 1.6 * k, (1.3 + rnd() * 0.5) * k); if j == 1 { fl2.addPath(d) } else { fl.addPath(d) } }
            }
            stroke(stems, cc.dk, 0.75 * k, in: g); fill(fl, cc.lt, in: g); fill(fl2, cc.col, in: g)
        case .flax:
            var stems = Path(), petals = Path(), mids = Path(), buds = Path()
            for i in 0..<3 {
                let dx = CGFloat(i - 1) * 2.4 * k, h = (14 + rnd() * 8) * k, tip = CGPoint(x: x + dx + (rnd() - 0.5) * 5 * k + wind * k, y: y - h)
                stems.move(to: CGPoint(x: x + dx * 0.3, y: y)); stems.addQuadCurve(to: tip, control: CGPoint(x: x + dx, y: y - h * 0.6))
                if rnd() < 0.78 {
                    for p in 0..<5 { let a = CGFloat(p) / 5 * .pi * 2; petals.addPath(Self.dot(tip.x + cos(a) * 1.5 * k, tip.y + sin(a) * 1.1 * k, 1.15 * k)) }
                    mids.addPath(Self.dot(tip.x, tip.y, 0.65 * k))
                } else { buds.addPath(Self.ellipse(tip.x, tip.y, 0.9 * k, 1.7 * k)) }
            }
            stroke(stems, cc.leaf2, 0.55 * k, in: g); fill(petals, cc.col, in: g); fill(mids, cc.lt, in: g); fill(buds, cc.dk, in: g)
        case .corn:
            let h = (26 + rnd() * 8) * k, lean = (rnd() - 0.5) * 3 * k + wind * 0.6 * k, tip = CGPoint(x: x + lean, y: y - h)
            var stalk = Path(); stalk.move(to: CGPoint(x: x, y: y)); stalk.addQuadCurve(to: tip, control: CGPoint(x: x, y: y - h * 0.5))
            stroke(stalk, cc.leaf2, 1.7 * k, in: g)
            for i in 0..<4 {
                let t = 0.28 + CGFloat(i) * 0.15, ax = x + lean * t, ay = y - h * t, side: CGFloat = i % 2 == 0 ? -1 : 1, L = (9 + rnd() * 4) * k
                var lf = Path(); lf.move(to: CGPoint(x: ax, y: ay)); lf.addQuadCurve(to: CGPoint(x: ax + side * L, y: ay + L * 0.18), control: CGPoint(x: ax + side * L * 0.6, y: ay - L * 0.6))
                stroke(lf, i % 2 == 0 ? cc.dk : cc.col, 1.9 * k, in: g)
            }
            var tassel = Path()
            tassel.addPath(Self.line(tip, CGPoint(x: tip.x - 2 * k, y: tip.y - 4 * k))); tassel.addPath(Self.line(tip, CGPoint(x: tip.x, y: tip.y - 5 * k))); tassel.addPath(Self.line(tip, CGPoint(x: tip.x + 2 * k, y: tip.y - 4 * k)))
            stroke(tassel, c.crops[0], 0.8 * k, in: g)
            if rnd() < 0.7 { let cob = Self.ellipse(x + lean * 0.45 + 1.7 * k, y - h * 0.45, 1.7 * k, 3.7 * k, deg: 18); fill(cob, c.crops[0], in: g); stroke(cob, cc.dk, 0.4 * k, in: g) }
        }
    }

    private func scarecrow(_ at: CGPoint, _ g: GraphicsContext) {
        var t = g
        t.translateBy(x: at.x, y: at.y)
        t.scaleBy(x: FieldSceneModel.depthScale(FieldSceneModel.plan.height / 2) * 1.09, y: FieldSceneModel.depthScale(FieldSceneModel.plan.height / 2) * 1.09)
        t.fill(Self.ellipse(-sun * 8, 1, 12, 3), with: .color(c.groundShadow.color))
        var pole = Path(); pole.addPath(Self.line(.zero, CGPoint(x: 0, y: -44))); pole.addPath(Self.line(CGPoint(x: -15, y: -32), CGPoint(x: 15, y: -32)))
        t.stroke(pole, with: .color(c.post.color), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        var shirt = Path(); shirt.addLines([CGPoint(x: -9, y: -34), CGPoint(x: 9, y: -34), CGPoint(x: 7, y: -18), CGPoint(x: -7, y: -18)]); shirt.closeSubpath()
        t.fill(shirt, with: .color(c.accent.opacity(0.85).color))
        t.fill(Self.dot(0, -40, 5), with: .color(FieldRGB("#E5D3A8").color))
        t.stroke(Self.dot(0, -40, 5), with: .color(FieldRGB("#8A6A44").color), lineWidth: 0.8)
        var hat = Path(); hat.move(to: CGPoint(x: -5, y: -43)); hat.addQuadCurve(to: CGPoint(x: 5, y: -43), control: CGPoint(x: 0, y: -54)); hat.closeSubpath()
        hat.addPath(Self.line(CGPoint(x: -9, y: -43), CGPoint(x: 9, y: -43)))
        t.fill(hat, with: .color(FieldRGB("#C9A85A").color)); t.stroke(hat, with: .color(FieldRGB("#8A6A44").color), lineWidth: 0.8)
    }

    // MARK: Surroundings

    private func hedge() {
        var r = FieldRNG("hedge"), body = Path(), light = Path()
        var v: CGFloat = 6
        while v < FieldSceneModel.plan.height + 10 {
            let pt = P(FieldSceneModel.plan.width + 12, v), rr = (5 + CGFloat(r.next()) * 4) * FieldSceneModel.depthScale(v)
            body.addPath(Self.dot(pt.x, pt.y - rr * 0.8, rr)); body.addPath(Self.dot(pt.x + rr * 0.7, pt.y - rr * 0.5, rr * 0.8))
            if season != .winter { light.addPath(Self.dot(pt.x - rr * 0.3, pt.y - rr * 1.2, rr * 0.4)) }
            v += 18 + CGFloat(r.next()) * 16
        }
        fill(body, tone(season == .winter ? FieldRGB("#9AA08E") : FieldRGB("#6F8A55")))
        fill(light, tone(season == .autumn ? FieldRGB("#C99A4E") : FieldRGB("#9DB878")).opacity(0.85))
    }

    private func bridge(riverAt: (CGFloat) -> CGFloat) {
        let ly = laneY.left.y, bx = riverAt(ly), by = ly + 4, w = Self.riverWidth(by) + 24
        var deck = Path()
        deck.move(to: CGPoint(x: bx - w / 2, y: by + 6)); deck.addQuadCurve(to: CGPoint(x: bx + w / 2, y: by + 4), control: CGPoint(x: bx, y: by - 6))
        deck.addLine(to: CGPoint(x: bx + w / 2, y: by + 12)); deck.addQuadCurve(to: CGPoint(x: bx - w / 2, y: by + 14), control: CGPoint(x: bx, y: by + 2)); deck.closeSubpath()
        fill(deck, tone(FieldRGB("#B48D5E"))); stroke(deck, c.post, 1)
        var rail = Path()
        rail.addPath(Self.line(CGPoint(x: bx - w / 2 + 3, y: by + 6), CGPoint(x: bx - w / 2 + 3, y: by - 6)))
        rail.addPath(Self.line(CGPoint(x: bx + w / 2 - 3, y: by + 4), CGPoint(x: bx + w / 2 - 3, y: by - 8)))
        rail.move(to: CGPoint(x: bx - w / 2 + 3, y: by - 4)); rail.addQuadCurve(to: CGPoint(x: bx + w / 2 - 3, y: by - 6), control: CGPoint(x: bx, y: by - 16))
        stroke(rail, c.post, 1.8)
    }

    private func fence() {
        let v = FieldSceneModel.plan.height + 50
        var r = FieldRNG("fence"), posts: [(CGPoint, CGFloat)] = []
        var u: CGFloat = -30
        while u <= FieldSceneModel.plan.width + 30 { posts.append((P(u, v), (CGFloat(r.next()) - 0.5) * 2.4)); u += 34 }
        let gate = posts.count / 2
        var shadows = Path(), postPath = Path(), rails = Path(), caps = Path()
        for (p, lean) in posts {
            shadows.addPath(Self.line(CGPoint(x: p.x - sun * 2, y: p.y + 1), CGPoint(x: p.x - sun * 10, y: p.y + 1)))
            postPath.addPath(Self.line(p, CGPoint(x: p.x + lean, y: p.y - 22)))
            if season == .winter { caps.addPath(Self.line(CGPoint(x: p.x + lean - 2.5, y: p.y - 23), CGPoint(x: p.x + lean + 2.5, y: p.y - 23))) }
        }
        for j in 0..<(posts.count - 1) where j != gate {
            let a = posts[j].0, b = posts[j + 1].0
            rails.addPath(Self.line(CGPoint(x: a.x, y: a.y - 8), CGPoint(x: b.x, y: b.y - 8)))
            rails.addPath(Self.line(CGPoint(x: a.x, y: a.y - 16), CGPoint(x: b.x, y: b.y - 16)))
        }
        let gp = posts[gate].0
        rails.addPath(Self.line(CGPoint(x: gp.x, y: gp.y - 6), CGPoint(x: gp.x + 18, y: gp.y + 6)))
        rails.addPath(Self.line(CGPoint(x: gp.x, y: gp.y - 17), CGPoint(x: gp.x + 18, y: gp.y - 5)))
        rails.addPath(Self.line(CGPoint(x: gp.x + 18, y: gp.y + 7), CGPoint(x: gp.x + 18, y: gp.y - 6)))
        stroke(shadows, c.groundShadow, 3); stroke(rails, c.post, 2); stroke(postPath, c.post, 3.6)
        if season == .winter { stroke(caps, FieldRGB("#FAFAF6"), 3) }
        guard !isDark else { return }
        for (j, (p, lean)) in [posts[3], posts[posts.count - 6]].enumerated() {
            let x = p.x + lean, y = p.y - 23, d: CGFloat = j == 0 ? 1 : -1, body = j == 0 ? FieldRGB("#8C5E46") : FieldRGB("#7A6A55")
            fill(Self.ellipse(x, y - 4, 5, 3.6), body); fill(Self.dot(x + d * 4, y - 8, 2.6), body)
            var tail = Path(); tail.addLines([CGPoint(x: x - d * 4, y: y - 4), CGPoint(x: x - d * 10, y: y - 7), CGPoint(x: x - d * 9, y: y - 3)]); tail.closeSubpath()
            fill(tail, body)
            var beak = Path(); beak.addLines([CGPoint(x: x + d * 6.4, y: y - 8.4), CGPoint(x: x + d * 8.6, y: y - 7.8), CGPoint(x: x + d * 6.4, y: y - 7)]); beak.closeSubpath()
            fill(beak, FieldRGB("#D9A53F")); fill(Self.dot(x + d * 4.6, y - 8.8, 0.7), FieldRGB("#1D1D18"))
        }
    }

    private func bigTree() {
        let tx: CGFloat = 1136, ty: CGFloat = 740, top: CGFloat = 560, bark = tone(FieldRGB("#7B5E3E"))
        var trunk = Path()
        trunk.move(to: CGPoint(x: tx - 10, y: ty))
        trunk.addCurve(to: CGPoint(x: tx, y: top + 20), control1: CGPoint(x: tx - 6, y: ty - 90), control2: CGPoint(x: tx - 10, y: top + 60))
        trunk.addCurve(to: CGPoint(x: tx + 10, y: ty), control1: CGPoint(x: tx + 8, y: top + 60), control2: CGPoint(x: tx + 8, y: ty - 90))
        trunk.closeSubpath()
        fill(trunk, bark)
        var limbs = Path()
        limbs.move(to: CGPoint(x: tx - 2, y: top + 70)); limbs.addQuadCurve(to: CGPoint(x: tx - 70, y: top + 10), control: CGPoint(x: tx - 40, y: top + 30))
        limbs.move(to: CGPoint(x: tx + 2, y: top + 90)); limbs.addQuadCurve(to: CGPoint(x: tx + 72, y: top + 30), control: CGPoint(x: tx + 40, y: top + 50))
        limbs.move(to: CGPoint(x: tx, y: top + 40)); limbs.addQuadCurve(to: CGPoint(x: tx - 20, y: top - 40), control: CGPoint(x: tx - 10, y: top))
        stroke(limbs, bark, 4)
        if let leaf = pal.leaf, let leaf2 = pal.leaf2 {
            var r = FieldRNG("canopy"), back = Path(), front = Path(), blossom = Path()
            for _ in 0..<26 {
                let a = CGFloat(r.next()) * .pi * 2, d = CGFloat(r.next()) * 74, x = tx + cos(a) * d * 1.15, y = top + sin(a) * d * 0.75, rr = 22 + CGFloat(r.next()) * 18
                if y > top + 10 { back.addPath(Self.dot(x, y, rr)) } else { front.addPath(Self.dot(x, y, rr)) }
                if pal.bloom != nil, r.next() < 0.7 { blossom.addPath(Self.dot(x + (CGFloat(r.next()) - 0.5) * rr, y - rr * 0.4, 2.4)) }
            }
            fill(back, tone(leaf2)); fill(front, tone(leaf))
            if let bloom = pal.bloom { fill(blossom, tone(bloom)) }
        } else {
            var r = FieldRNG("bare"), twigs = Path()
            for _ in 0..<14 {
                let a = -CGFloat.pi * (0.15 + CGFloat(r.next()) * 0.7), x = tx + (CGFloat(r.next()) - 0.5) * 30, y = top + 30 + CGFloat(r.next()) * 40, L = 40 + CGFloat(r.next()) * 50
                twigs.move(to: CGPoint(x: x, y: y)); twigs.addQuadCurve(to: CGPoint(x: x + cos(a) * L, y: y + sin(a) * L), control: CGPoint(x: x + cos(a) * L * 0.4, y: y + sin(a) * L * 0.7))
            }
            stroke(twigs, bark, 1.8)
        }
    }

    private func foreground() {
        var r = FieldRNG("front"), grass = Path(), stones = Path()
        for _ in 0..<70 { grass.addPath(Self.tuft(160 + CGFloat(r.next()) * 900, 660 + CGFloat(r.next()) * 60, 6 + CGFloat(r.next()) * 6)) }
        for _ in 0..<6 { stones.addPath(Self.ellipse(200 + CGFloat(r.next()) * 840, 668 + CGFloat(r.next()) * 44, 5 + CGFloat(r.next()) * 6, 3 + CGFloat(r.next()) * 2)) }
        fill(stones, tone(FieldRGB("#B9B19C")))
        stroke(grass, tone(pal.leaf2 ?? FieldRGB("#A5A495")), 1.3)
        let flowers: [FieldRGB] = switch season {
        case .spring: [FieldRGB("#F2C6CF"), FieldRGB("#F4F1E6"), FieldRGB("#E6C55A"), FieldRGB("#B9A6D6")]
        case .summer: [FieldRGB("#F4F1E6"), FieldRGB("#E6C55A"), FieldRGB("#E39A6E")]
        case .autumn: [FieldRGB("#E6C55A"), FieldRGB("#D69548")]
        case .winter: []
        }
        let count = season == .spring ? 40 : season == .summer ? 26 : 12
        if !flowers.isEmpty {
            for i in 0..<count { fill(Self.dot(170 + CGFloat(r.next()) * 900, 664 + CGFloat(r.next()) * 52, 2 + CGFloat(r.next())), tone(flowers[i % flowers.count])) }
        }
        if season == .autumn, let leaf = pal.leaf, let leaf2 = pal.leaf2 {
            var l = FieldRNG("leaves")
            for _ in 0..<22 {
                let x = 980 + CGFloat(l.next()) * 220, y = 600 + CGFloat(l.next()) * 120
                fill(Self.leaf(x, y, 3 + CGFloat(l.next()) * 2, deg: CGFloat(l.next()) * 360), tone(l.next() < 0.5 ? leaf : leaf2))
            }
        }
    }

    private func overlays() {
        if season == .winter {
            var r = FieldRNG("flakes"), flakes = Path()
            for _ in 0..<120 { flakes.addPath(Self.dot(CGFloat(r.next()) * W, CGFloat(r.next()) * H, 0.8 + CGFloat(r.next()) * 1.5)) }
            fill(flakes, FieldRGB("#FFFFFF").opacity(isDark ? 0.5 : 0.85))
        }
    }

    // MARK: Moving parts

    func ambience(_ t: CGFloat) {
        // Water wheel at the canal intake, turning slowly.
        let wx = Self.riverX(296) + 16, wy: CGFloat = 296, wr: CGFloat = 17, turn = t * 0.55
        var spokes = Path(), paddles = Path(), frame = Path()
        for i in 0..<8 {
            let a = CGFloat(i) / 8 * .pi * 2 + turn
            spokes.addPath(Self.line(CGPoint(x: wx, y: wy), CGPoint(x: wx + cos(a) * wr, y: wy + sin(a) * wr)))
            paddles.addPath(Self.line(CGPoint(x: wx + cos(a) * wr, y: wy + sin(a) * wr), CGPoint(x: wx + cos(a) * (wr + 5), y: wy + sin(a) * (wr + 5))))
        }
        frame.addLines([CGPoint(x: wx - 4, y: wy + 24), CGPoint(x: wx, y: wy), CGPoint(x: wx + 4, y: wy + 24)])
        stroke(frame, c.post, 2.4)
        stroke(Self.dot(wx, wy, wr), c.post, 2); stroke(spokes, c.post, 1.2); stroke(paddles, c.post, 3.2)
        fill(Self.dot(wx, wy, 2.6), c.post)
        // Chimney smoke: puffs rise, drift downwind and thin out.
        let chimney = CGPoint(x: 1118, y: 230), smoke = isDark ? FieldRGB("#56605E") : FieldRGB("#CFC8B7")
        for i in 0..<5 {
            let phase = (t * 0.09 + CGFloat(i) / 5).truncatingRemainder(dividingBy: 1)
            let x = chimney.x + sin(phase * 5 + CGFloat(i)) * 3 + phase * 14, y = chimney.y - phase * 58, r = 3 + phase * 6
            fill(Self.dot(x, y, r), smoke.opacity(Double((1 - phase) * min(1, phase * 6)) * 0.8))
        }
        guard isDark else { return }
        // Fireflies drift and pulse over the near meadow.
        var r = FieldRNG("fireflies"), dim = Path(), lit = Path()
        for _ in 0..<26 {
            let x = 60 + CGFloat(r.next()) * 1080, y = 500 + CGFloat(r.next()) * 210, size = 1.4 + CGFloat(r.next())
            let p1 = CGFloat(r.next()) * 6, p2 = CGFloat(r.next()) * 6, speed = 0.8 + CGFloat(r.next()) * 1.2
            let d = Self.dot(x + sin(t * 0.35 + p1) * 8, y + cos(t * 0.3 + p2) * 5, size)
            if sin(t * speed + p1) > 0 { lit.addPath(d) } else { dim.addPath(d) }
        }
        var glow = ctx
        glow.addFilter(.blur(radius: 2.4))
        glow.fill(lit, with: .color(FieldRGB("#F4E58A").color))
        fill(lit, FieldRGB("#F4E58A").opacity(0.75))
        fill(dim, FieldRGB("#F4E58A").opacity(0.3))
    }

    // MARK: Signs

    /// Big plots get a two-line board at the near-left corner; small plots a one-line stake.
    private func signs() {
        for plot in model.plots.sorted(by: { $0.plan.maxY < $1.plan.maxY }) {
            var g = ctx
            if let highlight, highlight != plot.id { g.opacity = 0.3 }
            if compact { pennant(plot, g, scale: 2.2); continue }
            let name = g.resolve(Text(verbatim: plot.name).font(FieldFont.signName).foregroundStyle(c.ink.color))
            let num = g.resolve(Text(verbatim: "\(TokenFormat.short(plot.value)) · \(FieldFormat.percent(plot.value, of: model.total))").font(FieldFont.signNumber).foregroundStyle(c.ink2.color))
            let screenW0 = plot.corners[2].x - plot.corners[3].x
            var small = g.resolve(Text(verbatim: plot.name).font(FieldFont.stake).foregroundStyle(c.ink.color))
            // Narrow plots get a smaller stake rather than none.
            if small.measure(in: CGSize(width: 600, height: 60)).width + 26 > screenW0 {
                small = g.resolve(Text(verbatim: plot.name).font(FieldFont.stakeSmall).foregroundStyle(c.ink.color))
            }
            let nameW = name.measure(in: CGSize(width: 600, height: 60)).width, numW = num.measure(in: CGSize(width: 600, height: 60)).width
            let screenW = plot.corners[2].x - plot.corners[3].x
            let full = screenW >= max(nameW, numW) + 70 && plot.plan.height >= 120
            let smallW = small.measure(in: CGSize(width: 600, height: 60)).width
            let bw = full ? max(nameW, numW) + 24 : smallW + (smallW + 18 > screenW ? 10 : 18), bh: CGFloat = full ? 46 : 26
            guard screenW >= bw + 4, plot.plan.height >= 34 else { pennant(plot, g); continue }
            let ny = P(plot.plan.minX, plot.plan.maxY + FieldSceneModel.gap * 0.25).y, nx = plot.corners[3].x + bw / 2 + (full ? 16 : max(2, min(6, (screenW - bw) / 2)))
            let top = ny - (full ? 12 : 6) - bh
            g.fill(Self.ellipse(nx - sun * 7, ny + 1, bw * 0.32, 3), with: .color(c.groundShadow.color))
            var posts = Path()
            posts.addPath(Self.line(CGPoint(x: nx - bw * 0.28, y: ny), CGPoint(x: nx - bw * 0.28, y: top + bh - 4)))
            posts.addPath(Self.line(CGPoint(x: nx + bw * 0.28, y: ny), CGPoint(x: nx + bw * 0.28, y: top + bh - 4)))
            g.stroke(posts, with: .color(c.post.color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            var t = g
            var tr = FieldRNG("t" + plot.id)
            t.translateBy(x: nx, y: top + bh / 2)
            t.rotate(by: .degrees((tr.next() - 0.5) * 3.2))
            t.translateBy(x: -nx, y: -(top + bh / 2))
            let board = Self.blob([CGPoint(x: nx - bw / 2, y: top), CGPoint(x: nx + bw / 2, y: top), CGPoint(x: nx + bw / 2, y: top + bh), CGPoint(x: nx - bw / 2, y: top + bh)], seed: "s" + plot.id, jitter: 0.9, step: 30, round: 4)
            t.fill(board.offsetBy(dx: 2, dy: 3), with: .color(c.groundShadow.color))
            t.fill(board, with: .color(c.sign.color))
            t.stroke(board, with: .color(c.post.color), lineWidth: 1.3)
            if full {
                t.draw(name, at: CGPoint(x: nx, y: top + 14), anchor: .center)
                t.draw(num, at: CGPoint(x: nx, y: top + 33), anchor: .center)
            } else {
                t.draw(small, at: CGPoint(x: nx, y: top + bh / 2), anchor: .center)
            }
        }
    }

    /// Plots too small for a stake get a flag in the crop's colour, matching the swatch in the list below.
    private func pennant(_ plot: FieldPlot, _ g: GraphicsContext, scale: CGFloat = 1) {
        var g = g
        let base = P(plot.plan.minX + min(10 * scale, plot.plan.width / 2), plot.plan.maxY)
        g.translateBy(x: base.x, y: base.y); g.scaleBy(x: scale, y: scale); g.translateBy(x: -base.x, y: -base.y)
        let top = CGPoint(x: base.x, y: base.y - 24)
        g.fill(Self.ellipse(base.x - sun * 4, base.y + 1, 5, 1.6), with: .color(c.groundShadow.color))
        g.stroke(Self.line(base, top), with: .color(c.post.color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        var flag = Path()
        flag.move(to: top)
        flag.addQuadCurve(to: CGPoint(x: top.x + 14, y: top.y + 4.5), control: CGPoint(x: top.x + 7, y: top.y - 1))
        flag.addQuadCurve(to: CGPoint(x: top.x, y: top.y + 9), control: CGPoint(x: top.x + 7, y: top.y + 7))
        flag.closeSubpath()
        g.fill(flag, with: .color(c.crops[plot.crop.rawValue].color))
        g.stroke(flag, with: .color(c.post.color), lineWidth: 0.8)
    }
}

// MARK: - Composition strip & list under the field

struct FieldCompositionStrip: View {
    let counts: TokenCounts

    @Environment(\.locale) private var locale

    private static let categoryOrder: [TokenCategory] = [.cacheRead, .input, .cacheWrite, .output, .reasoning]

    private struct Part: Identifiable {
        let id: String
        let label: LocalizedStringKey
        let tokens: Int64
        let color: Color
    }

    private var parts: [Part] {
        var list = Self.categoryOrder.map { category in
            Part(
                id: category.rawValue,
                label: category.title,
                tokens: counts[category],
                color: Palette.color(for: category)
            )
        }
        if counts.uncategorized > 0 {
            list.append(
                Part(
                    id: "uncategorized",
                    label: "Uncategorized",
                    tokens: counts.uncategorized,
                    color: FieldPalette.muted.opacity(0.55)
                )
            )
        }
        return list
    }

    var body: some View {
        let total = counts.total
        if total > 0 {
            let allParts = parts
            let barParts = allParts.filter { $0.tokens > 0 }
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { proxy in
                    let gap: CGFloat = 2
                    let usable = max(0, proxy.size.width - CGFloat(max(0, barParts.count - 1)) * gap)
                    HStack(spacing: gap) {
                        ForEach(Array(barParts.enumerated()), id: \.element.id) { index, part in
                            let isLast = index == barParts.count - 1
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(part.color)
                                .frame(
                                    width: isLast ? nil : max(2, usable * CGFloat(part.tokens) / CGFloat(total)),
                                    height: 6
                                )
                                .frame(maxWidth: isLast ? .infinity : nil, alignment: .leading)
                        }
                    }
                    .frame(width: proxy.size.width, height: 6, alignment: .leading)
                    .background(FieldPalette.rule.opacity(0.45))
                    .clipShape(Capsule())
                }
                .frame(height: 6)
                .accessibilityHidden(true)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        ForEach(allParts) { part in
                            partItem(part, total: total)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .leading), count: 3),
                        alignment: .leading,
                        spacing: 6
                    ) {
                        ForEach(allParts) { part in
                            partItem(part, total: total)
                                .minimumScaleFactor(0.85)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(FieldPalette.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(FieldPalette.rule, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Composition"))
        }
    }

    private func partItem(_ part: Part, total: Int64) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(part.color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(part.label)
                .font(FieldFont.serif(12.5))
                .foregroundStyle(FieldPalette.muted)
                .lineLimit(1)
            Text(verbatim: Share.percent(part.tokens, of: total, locale: locale))
                .font(FieldFont.serif(12.5, weight: .medium))
                .foregroundStyle(FieldPalette.ink)
                .monospacedDigit()
                .lineLimit(1)
        }
        .help(Text("\(part.tokens.formatted(.number.locale(locale))) tokens"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(part.label))
        .accessibilityValue(
            Text("\(TokenFormat.spoken(part.tokens)) tokens, \(Share.percent(part.tokens, of: total, locale: locale)) of total")
        )
    }
}

struct FieldBreakdownList: View {
    let items: [Breakdown]
    let total: Int64
    let dimension: BreakdownDimension
    var soleSource: String? = nil
    @Binding var highlight: String?

    @State private var cacheDetailModelID: String?
    @FocusState private var focusedItemID: String?
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let active = items.filter { $0.counts.total > 0 }
        Group {
            if active.isEmpty {
                Text("No usage in this period")
                    .font(FieldFont.serif(14))
                    .foregroundStyle(FieldPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                let crops = FieldCrop.assign(active)
                let colors = FieldColors.cached(isDark: scheme == .dark)
                let columnCount = dimension == .models ? 2 : 3
                let secondary = dimension == .models ? soleSource : nil
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 24), count: columnCount),
                    alignment: .leading,
                    spacing: 0
                ) {
                    ForEach(active) { item in
                        let crop = crops[item.id] ?? .wheat
                        row(item, crop: crop, colors: colors, secondary: secondary)
                    }
                }
            }
        }
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

    @ViewBuilder
    private func row(_ item: Breakdown, crop: FieldCrop, colors: FieldColors, secondary: String?) -> some View {
        let isHighlighted = highlight == item.id
        let isFocused = focusedItemID == item.id
        let content = HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(colors.crops[crop.rawValue].mix(colors.paper, 0.22).color)
                .overlay(Circle().fill(colors.crops[crop.rawValue].color).padding(7))
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.name)
                    .font(FieldFont.serif(16))
                    .foregroundStyle(FieldPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: crop.label(locale: locale))
                    .font(FieldFont.serif(12.5))
                    .foregroundStyle(FieldPalette.muted)
                    .lineLimit(1)
                if let secondary {
                    Text("Mainly from \(secondary)")
                        .font(FieldFont.serif(11.5))
                        .foregroundStyle(FieldPalette.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: TokenFormat.short(item.counts.total))
                    .font(FieldFont.serif(15))
                    .foregroundStyle(FieldPalette.ink)
                    .monospacedDigit()
                Text(verbatim: FieldFormat.percent(item.counts.total, of: total, locale: locale))
                    .font(FieldFont.serif(12.5))
                    .foregroundStyle(FieldPalette.muted)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(isHighlighted ? FieldPalette.hedge.opacity(0.1) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isFocused ? FieldPalette.accent : .clear, lineWidth: 1))
        .overlay(alignment: .bottom) { Rectangle().fill(FieldPalette.rule).frame(height: 1) }
        .contentShape(Rectangle())

        if dimension == .models {
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
            .accessibilityLabel(rowAccessibilityLabel(item, crop: crop, secondary: secondary))
            .accessibilityHint(Text("Shows cache details"))
            .accessibilityAddTraits(.isButton)
            .popover(isPresented: cacheDetailPresented(for: item.id), arrowEdge: .trailing) {
                ModelCacheDetail(item: item, color: crop.color)
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
                .accessibilityLabel(rowAccessibilityLabel(item, crop: crop, secondary: nil))
        }
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

    private func rowAccessibilityLabel(_ item: Breakdown, crop: FieldCrop, secondary: String?) -> Text {
        var label = Text(verbatim: "\(item.name), \(crop.label(locale: locale)), ")
            + Text("\(TokenFormat.spoken(item.counts.total)) tokens, \(FieldFormat.percent(item.counts.total, of: total, locale: locale)) of total")
        if let secondary {
            label = label + Text(verbatim: ", ") + Text("Mainly from \(secondary)")
        }
        return label
    }
}
