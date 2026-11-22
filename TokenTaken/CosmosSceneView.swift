import AppKit
import Metal
import MetalKit
import Observation
import QuartzCore
import SwiftUI
import TokenTakenKit

enum CosmosSceneStyle: Equatable { case window, menuBar, share }

struct CosmosSceneView: View {
    let summary: UsageSummary
    let dimension: BreakdownDimension
    @Binding var highlight: String?
    let style: CosmosSceneStyle

    init(summary: UsageSummary, dimension: BreakdownDimension, highlight: Binding<String?>, style: CosmosSceneStyle = .window) {
        self.summary = summary
        self.dimension = dimension
        self._highlight = highlight
        self.style = style
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.locale) private var locale
    @State private var renderedFrame: CosmosFrame?
    @State private var metalAvailable = true
    @State private var hoveredBody: String?
    @State private var hoveredCategory: Int?
    @State private var hoverPoint = CosmosDiskHoverPoint()
    @FocusState private var focused: CosmosFocus?

    private var focusedBody: String? {
        if case .body(let id) = focused { return id }
        return nil
    }

    private var focusedCategory: Int? {
        if case .category(let index) = focused { return index }
        return nil
    }

    private func clearSelection() {
        focused = nil
        highlight = nil
        hoveredBody = nil
        hoveredCategory = nil
        hoverPoint.world = nil
    }

    var body: some View {
        let scene = CosmosScene.cached(summary: summary, dimension: dimension)
        let activeBody = hoveredBody ?? focusedBody ?? highlight
        let activeCategory = hoveredCategory ?? focusedCategory
        let increasedContrast = contrast == .increased
        GeometryReader { proxy in
            let compactHeight = proxy.size.height < 360
            let midHeight = proxy.size.height < 420
            let activeBodyItem = activeBody.flatMap { id in scene.bodies.first(where: { $0.id == id }) }
            let legendTop: CGFloat = compactHeight ? 14 : (midHeight ? 32 : 64)
            let dustTop: CGFloat = compactHeight ? 14 : (midHeight ? 32 : 72)
            let readoutTop: CGFloat = compactHeight
                ? (scene.restCount > 0 ? 34 : 14)
                : (midHeight ? (scene.restCount > 0 ? 54 : 32) : (scene.restCount > 0 ? 102 : 72))
            let captionBottom: CGFloat = compactHeight ? 12 : 24
            let exclusionZones = style == .window
                ? Self.overlayExclusionZones(
                    scene: scene,
                    activeBody: activeBodyItem,
                    size: proxy.size,
                    compact: compactHeight,
                    legendTop: legendTop,
                    dustTop: dustTop,
                    readoutTop: readoutTop,
                    captionBottom: captionBottom,
                    locale: locale
                )
                : []

            // `??` is lazy: the still frame (a full projection pass) is only built when no
            // rendered frame matches the current scene and size.
            let baseFrame = renderedFrame.flatMap {
                $0.target == scene && $0.size == proxy.size ? $0 : nil
            } ?? scene.stillFrame(
                size: proxy.size,
                compact: style == .menuBar,
                hoverCategory: activeCategory ?? -1
            )
            let labelSizes = Dictionary(uniqueKeysWithValues: baseFrame.scene.bodies.map {
                ($0.id, Self.labelSize(for: $0, total: scene.total))
            })
            let frame = baseFrame.layingOutLabels(sizes: labelSizes, exclusionZones: exclusionZones)

            ZStack(alignment: .topLeading) {
                CosmosMetalView(
                    scene: scene,
                    style: style,
                    reduceMotion: reduceMotion,
                    isActive: appearsActive && controlActiveState == .key,
                    hoverCategory: activeCategory ?? -1,
                    frame: $renderedFrame,
                    metalAvailable: $metalAvailable
                )
                .background(CosmosPalette.background, ignoresSafeAreaEdges: [])
                .contentShape(Rectangle())
                .onTapGesture {
                    guard style == .window else { return }
                    clearSelection()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary.total.uncategorized > 0
                    ? Text("A black hole bends starlight and particle flow; six token categories form the disk and up to six bodies share the same occluded light paths.")
                    : Text("A black hole bends starlight and particle flow; five token categories form the disk and up to six bodies share the same occluded light paths."))
                .onContinuousHover { phase in
                    guard style == .window, metalAvailable else { return }
                    switch phase {
                    case .active(let location):
                        if let hit = frame.diskHit(at: location) {
                            if hoveredCategory != hit.index { hoveredCategory = hit.index }
                            if hoverPoint.world != hit.world { hoverPoint.world = hit.world }
                        } else {
                            if hoveredCategory != nil { hoveredCategory = nil }
                            if hoverPoint.world != nil { hoverPoint.world = nil }
                        }
                    case .ended:
                        if hoveredCategory != nil { hoveredCategory = nil }
                        if hoverPoint.world != nil { hoverPoint.world = nil }
                    }
                }

                if !metalAvailable {
                    Text("The cosmos scene cannot be drawn on this Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(CosmosSceneInk.ink2(increased: increasedContrast))
                        .multilineTextAlignment(.center)
                        .frame(width: min(330, max(180, proxy.size.width - 32)))
                        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.44)
                        .allowsHitTesting(false)
                }

                if style == .window {
                    if metalAvailable {
                        if scene.total == 0 {
                            Text("No usage in this period")
                                .font(.system(size: 12))
                                .foregroundStyle(CosmosSceneInk.ink2(increased: increasedContrast))
                                .multilineTextAlignment(.center)
                                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                                .allowsHitTesting(false)
                        }
                        orbitOverlay(frame: frame, activeBody: activeBody)
                        bodyOverlay(frame: frame, activeBody: activeBody, increasedContrast: increasedContrast)
                    }
                    categoryLegend(
                        scene: scene,
                        compact: compactHeight,
                        topOffset: legendTop,
                        increasedContrast: increasedContrast
                    )
                    if scene.restCount > 0 {
                        Text("\(scene.restCount) more · \(TokenFormat.short(scene.restTotal)) tokens")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(CosmosSceneInk.ink3(increased: increasedContrast))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(.top, dustTop)
                            .padding(.trailing, 28)
                            .allowsHitTesting(false)
                    }
                    Text("Disk flow ∝ tokens per hour (\(Self.rate(scene.tokensPerHour)))")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(CosmosSceneInk.ink2(increased: increasedContrast))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.leading, 28)
                        .padding(.bottom, captionBottom)
                        .allowsHitTesting(false)
                    if let body = activeBodyItem {
                        readout(
                            body: body,
                            scene: scene,
                            viewWidth: proxy.size.width,
                            compact: compactHeight,
                            topPadding: readoutTop,
                            increasedContrast: increasedContrast
                        )
                    }
                    if metalAvailable, let activeCategory {
                        CosmosCategoryCalloutView(
                            frame: frame,
                            index: activeCategory,
                            hoveredCategory: hoveredCategory,
                            hoverPoint: hoverPoint,
                            compact: compactHeight,
                            increasedContrast: increasedContrast,
                            locale: locale
                        )
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(CosmosPalette.background, ignoresSafeAreaEdges: [])
        .environment(\.colorScheme, .dark)
        .onExitCommand {
            clearSelection()
        }
        .onChange(of: focused) { oldValue, newValue in
            switch newValue {
            case .body(let id):
                highlight = id
            case .category:
                if case .body(let id) = oldValue, hoveredBody != id, highlight == id { highlight = nil }
            case nil:
                if case .body(let id) = oldValue, hoveredBody != id, highlight == id { highlight = nil }
            }
        }
    }

    @ViewBuilder
    private func orbitOverlay(frame: CosmosFrame, activeBody: String?) -> some View {
        if let activeBody, let placement = frame.placements.first(where: { $0.id == activeBody && $0.isVisible }),
           let point = placement.point {
            Canvas { context, _ in
                var orbit = Path()
                for segment in frame.orbitSegments(for: activeBody) where !segment.isEmpty {
                    orbit.move(to: segment[0])
                    for point in segment.dropFirst() { orbit.addLine(to: point) }
                }
                context.stroke(orbit, with: .color(CosmosSceneInk.accent.opacity(0.38)), lineWidth: 0.7)
                let radius = max(2, placement.screenRadius + 4)
                let focus = Path(ellipseIn: CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
                context.stroke(focus, with: .color(CosmosSceneInk.ink1.opacity(0.65)), lineWidth: 0.7)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func bodyOverlay(frame: CosmosFrame, activeBody: String?, increasedContrast: Bool) -> some View {
        ForEach(frame.placements.filter { $0.isVisible }) { placement in
            let body = placement.body
            if let labelFrame = placement.labelFrame,
               labelFrame.origin.x.isFinite, labelFrame.origin.y.isFinite,
               labelFrame.width.isFinite, labelFrame.height.isFinite {
                VStack(alignment: placement.labelSide > 0 ? .leading : .trailing, spacing: 0) {
                    Text(verbatim: body.name)
                        .font(.system(size: 11))
                        .foregroundStyle(
                            activeBody == body.id
                                ? CosmosSceneInk.accent
                                : CosmosSceneInk.bodyName(increased: increasedContrast)
                        )
                        .lineLimit(1)
                        .frame(height: 15)
                    Text(verbatim: Share.percent(body.tokens, of: frame.target.total))
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(CosmosSceneInk.ink3(increased: increasedContrast))
                        .lineLimit(1)
                        .frame(height: 14)
                }
                .frame(width: labelFrame.width, height: labelFrame.height, alignment: placement.labelSide > 0 ? .leading : .trailing)
                .offset(x: labelFrame.minX, y: labelFrame.minY)
                .shadow(color: .black, radius: 2, y: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            if placement.hitFrame.origin.x.isFinite, placement.hitFrame.origin.y.isFinite,
               placement.hitFrame.width.isFinite, placement.hitFrame.height.isFinite {
                Button {
                    highlight = body.id
                    focused = .body(body.id)
                } label: {
                    Circle()
                        .fill(Color.white.opacity(0.001))
                        .overlay {
                            Circle().stroke(
                                focused == .body(body.id) ? CosmosSceneInk.accent : Color.clear,
                                lineWidth: 1
                            )
                        }
                }
                .buttonStyle(.plain)
                .frame(width: placement.hitFrame.width, height: placement.hitFrame.height)
                .contentShape(Circle())
                .offset(x: placement.hitFrame.minX, y: placement.hitFrame.minY)
                .focused($focused, equals: .body(body.id))
                .onHover { inside in
                    if inside {
                        hoveredBody = body.id
                        highlight = body.id
                    } else {
                        if hoveredBody == body.id { hoveredBody = nil }
                        if focused != .body(body.id), highlight == body.id { highlight = nil }
                    }
                }
                .accessibilityLabel(Text(verbatim: body.name))
                .accessibilityValue(Text("\(TokenFormat.spoken(body.tokens)) tokens, \(Share.percent(body.tokens, of: frame.target.total)) of total, approximately \(TokenFormat.spoken(Int64(body.rate.rounded()))) tokens per hour"))
            }
        }
    }

    @ViewBuilder
    private func categoryLegend(
        scene: CosmosScene,
        compact: Bool,
        topOffset: CGFloat,
        increasedContrast: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 3) {
            ForEach(Array(scene.categories.enumerated()), id: \.element.id) { index, category in
                let shortValue = TokenFormat.short(category.value)
                let exactValue = category.value.formatted(.number.locale(locale))
                let showExact = !compact && exactValue != shortValue
                Button {
                    focused = .category(index)
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(CosmosSceneInk.color(for: category))
                                .frame(width: 5, height: 5)
                            Text(category.title)
                                .font(.system(size: 11))
                        }
                        .frame(height: compact ? 13 : 15)
                        HStack(spacing: 4) {
                            Text("\(shortValue) tokens")
                            Text(verbatim: "· \(Share.percent(category.value, of: scene.total))")
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .font(.system(size: compact ? 10.5 : 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(CosmosSceneInk.ink2(increased: increasedContrast))
                        .frame(height: compact ? 13 : 15)
                        .padding(.leading, 12)
                        if showExact {
                            Text(verbatim: exactValue)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .font(.system(size: 9.5, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(CosmosSceneInk.ink3(increased: increasedContrast))
                                .frame(height: 12)
                                .padding(.leading, 12)
                        }
                    }
                    .foregroundStyle(
                        hoveredCategory == index || focusedCategory == index
                            ? CosmosSceneInk.categoryHighlight
                            : CosmosSceneInk.ink2(increased: increasedContrast)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, compact ? 1 : 2)
                    .overlay {
                        Rectangle()
                            .strokeBorder(
                                focusedCategory == index ? CosmosSceneInk.accent : Color.clear,
                                lineWidth: 1
                            )
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($focused, equals: .category(index))
                .onHover { inside in
                    if inside {
                        if hoveredCategory != index { hoveredCategory = index }
                        if hoverPoint.world != nil { hoverPoint.world = nil }
                    } else {
                        if hoveredCategory == index { hoveredCategory = nil }
                        if hoverPoint.world != nil { hoverPoint.world = nil }
                    }
                }
                .help(Text("\(exactValue) tokens"))
                .accessibilityLabel(Text(category.title))
                .accessibilityValue(Text("\(TokenFormat.spoken(category.value)) tokens, \(Share.percent(category.value, of: scene.total)) of total"))
            }
        }
        .frame(width: 232)
        .offset(x: 22, y: topOffset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(scene.categories.count > 5 ? Text("Token categories") : Text("Five token categories"))
    }

    @ViewBuilder
    private func readout(
        body: CosmosBody,
        scene: CosmosScene,
        viewWidth: CGFloat,
        compact: Bool,
        topPadding: CGFloat,
        increasedContrast: Bool
    ) -> some View {
        let width = min(238, max(180, viewWidth - 56))
        let shortTokens = TokenFormat.short(body.tokens)
        let exactTokens = body.tokens.formatted(.number.locale(locale))
        VStack(alignment: .leading, spacing: compact ? 2 : 3) {
            Text(verbatim: body.name)
                .font(.system(size: compact ? 13 : 14, weight: .semibold))
                .foregroundStyle(CosmosSceneInk.ink1)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("\(shortTokens) tokens")
                .font(.system(size: compact ? 13 : 14, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(CosmosSceneInk.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if exactTokens != shortTokens {
                Text(verbatim: exactTokens)
                    .font(.system(size: 10.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(CosmosSceneInk.ink3(increased: increasedContrast))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Text("\(Share.percent(body.tokens, of: scene.total)) of this period · approximately \(Self.rate(body.rate)) tokens per hour")
                .font(.system(size: 11))
                .foregroundStyle(CosmosSceneInk.ink2(increased: increasedContrast))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                ForEach(scene.categories) { category in
                    let value = category.value(in: body.counts)
                    HStack(spacing: 6) {
                        Text(category.title)
                            .frame(width: 70, alignment: .leading)
                            .lineLimit(1)
                        GeometryReader { proxy in
                            if value > 0 {
                                Rectangle()
                                    .fill(CosmosSceneInk.color(for: category))
                                    .frame(width: proxy.size.width * max(0.01, Share.ratio(value, of: body.tokens)))
                            }
                        }
                        .frame(height: 3)
                        Text(verbatim: Share.percent(value, of: body.tokens))
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(CosmosSceneInk.ink3(increased: increasedContrast))
                    .frame(height: compact ? 11 : 12)
                }
            }
            .padding(.vertical, compact ? 3 : 5)
            if let mainlyFrom = body.mainlyFrom {
                Text("Mainly from \(mainlyFrom)")
                    .font(.system(size: 11))
                    .foregroundStyle(CosmosSceneInk.ink2(increased: increasedContrast))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, compact ? 7 : 11)
        .frame(width: width, alignment: .leading)
        .background(CosmosSceneInk.readoutBackground)
        .overlay(Rectangle().stroke(CosmosSceneInk.border(increased: increasedContrast), lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, topPadding)
        .padding(.trailing, 28)
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
    }

    private static func overlayExclusionZones(
        scene: CosmosScene,
        activeBody: CosmosBody?,
        size: CGSize,
        compact: Bool,
        legendTop: CGFloat,
        dustTop: CGFloat,
        readoutTop: CGFloat,
        captionBottom: CGFloat,
        locale: Locale
    ) -> [CGRect] {
        var zones: [CGRect] = []
        let rowSpacing: CGFloat = compact ? 2 : 3
        var legendHeight: CGFloat = 0
        for (index, category) in scene.categories.enumerated() {
            if index > 0 { legendHeight += rowSpacing }
            if compact {
                legendHeight += 28
            } else {
                let hasExact = category.value.formatted(.number.locale(locale)) != TokenFormat.short(category.value)
                legendHeight += hasExact ? 46 : 34
            }
        }
        zones.append(CGRect(x: 22, y: legendTop, width: 232, height: legendHeight))
        zones.append(CGRect(
            x: 28,
            y: max(0, size.height - captionBottom - 16),
            width: min(320, max(0, size.width - 56)),
            height: 16
        ))
        if scene.restCount > 0 {
            zones.append(CGRect(
                x: max(0, size.width - 28 - 190),
                y: dustTop,
                width: 190,
                height: 16
            ))
        }
        if let activeBody {
            let readoutWidth = min(238, max(180, size.width - 56))
            let hasExact = activeBody.tokens.formatted(.number.locale(locale)) != TokenFormat.short(activeBody.tokens)
            let readoutHeight: CGFloat = (compact ? 98 : 118)
                + (hasExact ? 14 : 0)
                + CGFloat(scene.categories.count) * (compact ? 13 : 16)
                + (activeBody.mainlyFrom != nil ? 16 : 0)
            zones.append(CGRect(
                x: max(0, size.width - 28 - readoutWidth),
                y: readoutTop,
                width: readoutWidth,
                height: readoutHeight
            ))
        }
        return zones
    }

    @MainActor
    private static func labelSize(for body: CosmosBody, total: Int64) -> CGSize {
        CosmosLabelMetrics.size(name: body.name, share: Share.percent(body.tokens, of: total))
    }

    private static func rate(_ value: Double) -> String {
        TokenFormat.short(Int64(value.rounded()))
    }
}

@Observable
@MainActor
private final class CosmosDiskHoverPoint {
    var world: SIMD3<Double>?
}

private struct CosmosCategoryCalloutView: View {
    let frame: CosmosFrame
    let index: Int
    let hoveredCategory: Int?
    let hoverPoint: CosmosDiskHoverPoint
    let compact: Bool
    let increasedContrast: Bool
    let locale: Locale

    var body: some View {
        let direct = hoveredCategory == index ? hoverPoint.world : nil
        if frame.scene.categories.indices.contains(index),
           let anchor = frame.categoryAnchor(index: index, direct: direct) {
            let calloutWidth = 176.0
            let xLow = 18.0
            let xHigh = max(xLow, Double(frame.size.width) - calloutWidth - 18.0)
            let x = CosmosScene.clamp(anchor.x + 42, xLow, xHigh)
            let yLow = compact ? 14.0 : 48.0
            let yHigh = max(yLow, Double(frame.size.height) - (compact ? 92.0 : 112.0))
            let y = CosmosScene.clamp(anchor.y - 38, yLow, yHigh)
            let category = frame.target.categories[index]
            let shortValue = TokenFormat.short(category.value)
            let exactValue = category.value.formatted(.number.locale(locale))

            Canvas { context, _ in
                var leader = Path()
                leader.move(to: anchor.point)
                leader.addLine(to: CGPoint(x: x - 7, y: y + 16))
                leader.addLine(to: CGPoint(x: x, y: y + 16))
                context.stroke(
                    leader,
                    with: .color(CosmosSceneInk.accent.opacity(increasedContrast ? 0.95 : 0.72)),
                    lineWidth: increasedContrast ? 1.0 : 0.7
                )
                let dot = Path(ellipseIn: CGRect(x: anchor.x - 2, y: anchor.y - 2, width: 4, height: 4))
                context.fill(dot, with: .color(CosmosSceneInk.accent))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(category.title)
                    .foregroundStyle(CosmosSceneInk.ink1)
                HStack(spacing: 4) {
                    Text("\(shortValue) tokens")
                    Text(verbatim: "· \(Share.percent(category.value, of: frame.target.total))")
                }
                .monospacedDigit()
                .foregroundStyle(CosmosSceneInk.ink2(increased: increasedContrast))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                if exactValue != shortValue {
                    Text(verbatim: exactValue)
                        .font(.system(size: 10, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(CosmosSceneInk.ink3(increased: increasedContrast))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: calloutWidth, alignment: .leading)
            .background(CosmosSceneInk.readoutBackground)
            .overlay(Rectangle().stroke(CosmosSceneInk.border(increased: increasedContrast), lineWidth: increasedContrast ? 1 : 0))
            .overlay(alignment: .leading) {
                Rectangle().fill(CosmosSceneInk.accent).frame(width: 1)
            }
            .offset(x: x, y: y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private extension CosmosCategory {
    var title: LocalizedStringKey {
        category?.title ?? LocalizedStringKey("Uncategorized")
    }
}

enum CosmosSnapshot {
    @MainActor private static var cachedRenderer: CosmosRenderer?
    @MainActor private static var attemptedInit = false

    @MainActor static func image(summary: UsageSummary, dimension: BreakdownDimension, size: CGSize, scale: CGFloat) -> NSImage? {
        guard size.width > 1, size.height > 1, scale > 0 else { return nil }
        if !attemptedInit {
            attemptedInit = true
            cachedRenderer = MTLCreateSystemDefaultDevice().flatMap { CosmosRenderer(device: $0) }
        }
        guard let renderer = cachedRenderer else { return nil }
        let scene = CosmosScene.cached(summary: summary, dimension: dimension)
        let frame = scene.stillFrame(size: size)
        guard let image = renderer.snapshot(
            frame,
            pixelSize: CGSize(width: size.width * scale, height: size.height * scale)
        ) else { return nil }
        return NSImage(cgImage: image, size: size)
    }
}

private enum CosmosFocus: Hashable {
    case body(String)
    case category(Int)
}

/// Label widths only change with the text, so measure each distinct string once instead of laying
/// out two attributed strings for every body on every view evaluation.
@MainActor
private enum CosmosLabelMetrics {
    private static var names: [String: CGFloat] = [:]
    private static var shares: [String: CGFloat] = [:]

    static func size(name: String, share: String) -> CGSize {
        let nameWidth = width(name, cache: &names, font: .systemFont(ofSize: 11))
        let shareWidth = width(share, cache: &shares, font: .monospacedSystemFont(ofSize: 11, weight: .regular))
        return CGSize(width: ceil(max(nameWidth, shareWidth)), height: 29)
    }

    private static func width(_ text: String, cache: inout [String: CGFloat], font: NSFont) -> CGFloat {
        if let measured = cache[text] { return measured }
        let measured = NSAttributedString(string: text, attributes: [.font: font]).size().width
        if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
        cache[text] = measured
        return measured
    }
}

private enum CosmosSceneInk {
    static var ink1: Color { CosmosPalette.ink }
    static var ink2: Color { CosmosPalette.ink2 }
    static var ink3: Color { CosmosPalette.ink3 }
    static let bodyName = Color(hex: "#C3C9D2")
    static var accent: Color { CosmosPalette.accent }
    static let categoryHighlight = Color(hex: "#FFF4E4")
    static var rule2: Color { CosmosPalette.controlRule }
    static let rule2Increased = Color(hex: "#4D596C")
    static let ink2Increased = Color(hex: "#D5DCE6")
    static let ink3Increased = Color(hex: "#B5BCC7")
    static var readoutBackground: Color { CosmosPalette.background }
    static let uncategorized = Color(hex: "#8A93A3")

    static func color(for category: CosmosCategory) -> Color {
        if let tokenCategory = category.category {
            return Palette.color(for: tokenCategory)
        }
        return uncategorized
    }

    static func bodyName(increased: Bool) -> Color {
        increased ? ink1 : bodyName
    }

    static func ink2(increased: Bool) -> Color {
        increased ? ink2Increased : ink2
    }

    static func ink3(increased: Bool) -> Color {
        increased ? ink3Increased : ink3
    }

    static func border(increased: Bool) -> Color {
        increased ? rule2Increased : rule2
    }
}

private struct CosmosMetalView: NSViewRepresentable {
    let scene: CosmosScene
    let style: CosmosSceneStyle
    let reduceMotion: Bool
    let isActive: Bool
    let hoverCategory: Int
    @Binding var frame: CosmosFrame?
    @Binding var metalAvailable: Bool

    func makeCoordinator() -> CosmosCoordinator {
        CosmosCoordinator()
    }

    func makeNSView(context: Context) -> CosmosMTKView {
        let device = MTLCreateSystemDefaultDevice()
        let view = CosmosMTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(
            red: 7.0 / 255.0,
            green: 9.0 / 255.0,
            blue: 13.0 / 255.0,
            alpha: 1
        )
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = true
        view.delegate = context.coordinator
        context.coordinator.renderer = device.flatMap { CosmosRenderer(device: $0) }
        let coordinator = context.coordinator
        view.onOcclusionChange = { [weak coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.updatePlayback(view)
        }
        coordinator.onFrame = { self.frame = $0 }
        coordinator.update(
            scene: scene,
            style: style,
            reduceMotion: reduceMotion,
            isActive: isActive,
            hoverCategory: hoverCategory,
            view: view
        )
        let available = coordinator.renderer != nil
        DispatchQueue.main.async {
            self.metalAvailable = available
        }
        return view
    }

    func updateNSView(_ view: CosmosMTKView, context: Context) {
        context.coordinator.onFrame = { self.frame = $0 }
        context.coordinator.update(
            scene: scene,
            style: style,
            reduceMotion: reduceMotion,
            isActive: isActive,
            hoverCategory: hoverCategory,
            view: view
        )
    }
}

@MainActor
private final class CosmosMTKView: MTKView {
    var onOcclusionChange: (@MainActor () -> Void)?

    var windowVisible: Bool {
        window?.occlusionState.contains(.visible) == true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        appearance = NSAppearance(named: .darkAqua)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowOcclusionDidChange(_:)),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
        }
        onOcclusionChange?()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowOcclusionDidChange(_ notification: Notification) {
        onOcclusionChange?()
    }
}

@MainActor
private final class CosmosCoordinator: NSObject, MTKViewDelegate {
    var renderer: CosmosRenderer?
    var onFrame: ((CosmosFrame) -> Void)?

    private var target: CosmosScene?
    private var previous: CosmosScene?
    private var current: CosmosScene?
    private var style: CosmosSceneStyle = .window
    private var reduceMotion = false
    private var isActive = true
    private var hoverCategory = -1
    private var lastSize = CGSize.zero
    private var wasPaused = true
    private var needsStaticRedraw = true
    private var transitionStart = 0.0
    private var startTime: CFTimeInterval?
    private var lastTime: CFTimeInterval?
    private var orbitTime = 0.0
    private var flowTime = 0.0
    private var motionTime = 0.0
    private var publishedFrame: CosmosFrame?
    private var publishPending = true
    private var transitionSettled = true

    func update(
        scene: CosmosScene,
        style: CosmosSceneStyle,
        reduceMotion: Bool,
        isActive: Bool,
        hoverCategory: Int,
        view: CosmosMTKView
    ) {
        let now = CACurrentMediaTime()
        var changed = needsStaticRedraw || lastSize != view.bounds.size
        if target == nil {
            target = scene
            previous = scene
            current = scene
            transitionStart = now
            startTime = now
            changed = true
        } else if target != scene {
            previous = current ?? scene
            target = scene
            transitionStart = now
            transitionSettled = false
            orbitTime = 0
            changed = true
        }
        if self.style != style || self.reduceMotion != reduceMotion || self.isActive != isActive
            || self.hoverCategory != hoverCategory {
            changed = true
        }
        self.style = style
        self.reduceMotion = reduceMotion
        self.isActive = isActive
        self.hoverCategory = hoverCategory
        lastSize = view.bounds.size
        updatePlayback(view)
        guard changed else { return }
        needsStaticRedraw = true
        publishPending = true
        if renderer == nil {
            emitFallbackFrame(view)
        } else if view.isPaused {
            view.setNeedsDisplay(view.bounds)
        }
    }

    func updatePlayback(_ view: CosmosMTKView) {
        let paused = reduceMotion || style != .window || !isActive || !view.windowVisible
        if wasPaused && !paused { lastTime = nil }
        wasPaused = paused
        view.isPaused = paused
        view.enableSetNeedsDisplay = paused
        if paused, needsStaticRedraw { view.setNeedsDisplay(view.bounds) }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsStaticRedraw = true
        if view.isPaused { view.setNeedsDisplay(view.bounds) }
    }

    func draw(in view: MTKView) {
        guard let view = view as? CosmosMTKView,
              let target, let previous, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let now = CACurrentMediaTime()
        if startTime == nil { startTime = now }
        let delta = lastTime.map { min(0.05, max(0, now - $0)) } ?? 0
        lastTime = now
        let animate = !view.isPaused && !reduceMotion && style == .window
        if animate {
            orbitTime += delta
            flowTime += delta * target.tokensPerHour / 1_000_000
            motionTime += delta
        }
        let reveal = startTime.map { CosmosScene.clamp((now - $0) / 1.5, 0, 1) } ?? 1
        let staticFrame = reduceMotion || style != .window
        let frame = target.frame(
            from: previous,
            transitionStart: transitionStart,
            timestamp: now,
            orbitTime: orbitTime,
            flowTime: flowTime,
            motionTime: motionTime,
            reveal: reveal,
            size: view.bounds.size,
            compact: style == .menuBar,
            reduceMotion: staticFrame,
            hoverCategory: hoverCategory
        )
        current = frame.scene
        needsStaticRedraw = false
        let settled = now - transitionStart >= 0.9
        publish(frame, forcing: publishPending || (settled && !transitionSettled))
        if settled { transitionSettled = true }
        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }
        renderer?.draw(frame, to: renderPassDescriptor, drawable: drawable, drawableSize: view.drawableSize)
    }

    /// Drawing stays at the display's rate, but SwiftUI lays out labels, hit targets and the
    /// orbit overlay from the frame it holds. Handing it every drawn frame re-evaluated the whole
    /// view 60 times a second for sub-pixel drift, so only frames it can visibly differ from are
    /// published, plus one at the end of every transition (and one after any update that forces
    /// a redraw).
    private func publish(_ frame: CosmosFrame, forcing: Bool) {
        if !forcing, let publishedFrame, frame.isVisuallySame(as: publishedFrame) { return }
        publishPending = false
        publishedFrame = frame
        onFrame?(frame)
    }

    private func emitFallbackFrame(_ view: CosmosMTKView) {
        guard let target else { return }
        var frame = target.stillFrame(
            size: view.bounds.size,
            compact: style == .menuBar,
            hoverCategory: hoverCategory
        )
        frame.placements = []
        current = frame.scene
        needsStaticRedraw = false
        publishPending = false
        publishedFrame = frame
        onFrame?(frame)
    }
}
