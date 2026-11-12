import SwiftUI

/// iOS port of the macOS `LiquidGlassVessel`: pure-Canvas liquid-glass vessel, shared by the
/// Tide Line share card. Uses no `glassEffect` so `ImageRenderer` exports the full material.
struct LiquidGlassVessel: Sendable {
    struct Layer: Sendable {
        var color: Color
        var fraction: Double
    }

    struct LayoutMetrics: Sendable {
        let wallThickness: CGFloat
        let outerCornerRadius: CGFloat
        let innerRect: CGRect
        let innerCornerRadius: CGFloat
        let meniscusHeight: CGFloat
        let lipClimb: CGFloat
        let brimCenterY: CGFloat
        let meniscusCenterY: CGFloat
        let layerRanges: [ClosedRange<CGFloat>]
    }

    static func wallThickness(for rect: CGRect) -> CGFloat {
        let minor = min(rect.width, rect.height)
        guard minor > 12 else { return max(1, minor * 0.10) }
        return min(14, min(max(3, minor * 0.03), minor * 0.18))
    }

    /// Computes the `fillLevel` (`0...1`) that places `meniscusCenterY` at `surfaceY`.
    static func fillLevel(
        forSurfaceY surfaceY: CGFloat,
        in rect: CGRect,
        cornerRadius: CGFloat
    ) -> Double {
        let base = metrics(for: rect, cornerRadius: cornerRadius, layers: [], fillLevel: 1)
        let usable = max(1, base.innerRect.maxY - base.brimCenterY)
        return min(max(Double((base.innerRect.maxY - surfaceY) / usable), 0), 1)
    }

    static func metrics(
        for rect: CGRect,
        cornerRadius: CGFloat,
        layers: [Layer],
        fillLevel: Double,
        wobble: CGFloat = 0
    ) -> LayoutMetrics {
        let wall = wallThickness(for: rect)
        let outerRadius = min(cornerRadius, min(rect.width, rect.height) * 0.5)
        let innerRect = rect.insetBy(dx: wall, dy: wall)
        let innerRadius = max(2, outerRadius - wall)
        let unitScale = max(1.0, min(2.2, min(rect.width, rect.height) / 260.0))
        let lipClimb = min(2.5 * unitScale, max(1.5, innerRect.height * 0.035))
        let meniscusHeight = min(
            max(5.0, innerRect.width * 0.10),
            min(max(6.0, innerRect.height * 0.10), 26.0)
        )

        let topClearance = max(meniscusHeight * 0.5, lipClimb) + 2.0 * unitScale
        let brimCenterY = min(innerRect.maxY, innerRect.minY + topClearance)
        let clampedFill = min(max(fillLevel, 0), 1)
        let usableHeight = max(0, innerRect.maxY - brimCenterY)

        let meniscusCenterY: CGFloat
        if clampedFill > 0, innerRect.height > 2 {
            let rawY = innerRect.maxY - usableHeight * CGFloat(clampedFill) + wobble
            let minY = min(innerRect.maxY, innerRect.minY + max(meniscusHeight * 0.5, lipClimb) + 0.5)
            meniscusCenterY = min(innerRect.maxY - 1, max(minY, rawY))
        } else {
            meniscusCenterY = innerRect.maxY
        }

        let liquidTotalHeight = max(0, innerRect.maxY - meniscusCenterY)
        let positiveSum = layers.reduce(0.0) { $0 + max(0, $1.fraction) }
        let lastPositiveIndex = layers.lastIndex { $0.fraction > 0 }

        var ranges: [ClosedRange<CGFloat>] = []
        ranges.reserveCapacity(layers.count)
        var cursorY = innerRect.maxY

        for (index, layer) in layers.enumerated() {
            guard liquidTotalHeight > 0, positiveSum > 0, layer.fraction > 0 else {
                let anchor = min(cursorY, innerRect.maxY)
                ranges.append(anchor...anchor)
                continue
            }
            let bandMaxY = cursorY
            let bandMinY: CGFloat
            if index == lastPositiveIndex {
                bandMinY = meniscusCenterY
            } else {
                let height = liquidTotalHeight * CGFloat(max(0, layer.fraction) / positiveSum)
                bandMinY = max(meniscusCenterY, cursorY - height)
            }
            cursorY = bandMinY
            ranges.append(min(bandMinY, bandMaxY)...max(bandMinY, bandMaxY))
        }

        return LayoutMetrics(
            wallThickness: wall,
            outerCornerRadius: outerRadius,
            innerRect: innerRect,
            innerCornerRadius: innerRadius,
            meniscusHeight: meniscusHeight,
            lipClimb: lipClimb,
            brimCenterY: brimCenterY,
            meniscusCenterY: meniscusCenterY,
            layerRanges: ranges
        )
    }

    static func draw(
        in context: inout GraphicsContext,
        rect: CGRect,
        cornerRadius: CGFloat,
        layers: [Layer],
        fillLevel: Double,
        isDark: Bool,
        reduceTransparency: Bool,
        inflows: [(color: Color, y: CGFloat, height: CGFloat, fromLeft: Bool)] = []
    ) {
        draw(
            in: &context,
            rect: rect,
            cornerRadius: cornerRadius,
            layers: layers,
            fillLevel: fillLevel,
            isDark: isDark,
            reduceTransparency: reduceTransparency,
            inflows: inflows,
            wobblePhase: nil
        )
    }

    static func draw(
        in context: inout GraphicsContext,
        rect: CGRect,
        cornerRadius: CGFloat,
        layers: [Layer],
        fillLevel: Double,
        isDark: Bool,
        reduceTransparency: Bool,
        inflows: [(color: Color, y: CGFloat, height: CGFloat, fromLeft: Bool)],
        wobblePhase: Double?
    ) {
        guard rect.width > 4, rect.height > 4 else { return }

        let wobbleOffset: CGFloat
        let wobbleTilt: CGFloat
        if let phase = wobblePhase, !reduceTransparency, fillLevel > 0 {
            let angle = phase * 2 * .pi
            wobbleOffset = CGFloat(sin(angle)) * 1.0
            wobbleTilt = CGFloat(cos(angle)) * 0.6
        } else {
            wobbleOffset = 0
            wobbleTilt = 0
        }

        let m = metrics(
            for: rect,
            cornerRadius: cornerRadius,
            layers: layers,
            fillLevel: fillLevel,
            wobble: wobbleOffset
        )
        let innerRect = m.innerRect
        guard innerRect.width > 2, innerRect.height > 2 else { return }

        let unitScale = max(1.0, min(2.2, min(rect.width, rect.height) / 260.0))
        let outerPath = RoundedRectangle(cornerRadius: m.outerCornerRadius, style: .continuous)
            .path(in: rect)
        let innerPath = RoundedRectangle(cornerRadius: m.innerCornerRadius, style: .continuous)
            .path(in: innerRect)

        // 1. Soft contact shadow ellipse under the vessel.
        if !reduceTransparency {
            let shadowRadiusX = rect.width * 0.44
            let shadowRadiusY = max(4.5, min(16, rect.width * 0.065))
            let shadowCenter = CGPoint(x: rect.midX, y: rect.maxY + shadowRadiusY * 0.22)
            let peakShadow = isDark ? 0.30 : 0.10
            fillEllipticalGradient(
                in: &context,
                center: shadowCenter,
                radiusX: shadowRadiusX,
                radiusY: shadowRadiusY,
                gradient: Gradient(stops: [
                    .init(color: .black.opacity(peakShadow), location: 0),
                    .init(color: .black.opacity(peakShadow * 0.42), location: 0.55),
                    .init(color: .clear, location: 1),
                ])
            )
        }

        // 2. Glass wall band & stream continuations through the wall.
        if reduceTransparency {
            context.fill(outerPath, with: .color(Palette.cardSurface))
            context.fill(innerPath, with: .color(Palette.solid))
        } else {
            var wallContext = context
            wallContext.clip(to: outerPath)
            wallContext.clip(to: innerPath, options: .inverse)

            for inflow in inflows where inflow.height > 0 {
                let bandX = inflow.fromLeft ? rect.minX : innerRect.maxX
                let bandWidth = inflow.fromLeft
                    ? max(0, innerRect.minX - rect.minX)
                    : max(0, rect.maxX - innerRect.maxX)
                guard bandWidth > 0 else { continue }
                let passRect = CGRect(
                    x: bandX,
                    y: inflow.y,
                    width: bandWidth,
                    height: inflow.height
                )
                let outerStop = inflow.color.opacity(0.32)
                let innerStop = inflow.color.opacity(0.24)
                wallContext.fill(
                    Path(passRect),
                    with: .linearGradient(
                        Gradient(colors: inflow.fromLeft ? [outerStop, innerStop] : [innerStop, outerStop]),
                        startPoint: CGPoint(x: passRect.minX, y: passRect.midY),
                        endPoint: CGPoint(x: passRect.maxX, y: passRect.midY)
                    )
                )
            }

            let wallTop = isDark ? 0.05 : 0.08
            let wallMid = isDark ? 0.032 : 0.05
            let wallBottom = isDark ? 0.018 : 0.03
            wallContext.fill(
                Path(rect),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(wallTop), location: 0),
                        .init(color: .white.opacity(wallMid), location: 0.46),
                        .init(color: .white.opacity(wallBottom), location: 1),
                    ]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                )
            )
        }

        // 3. Inner chamber: clear headspace, luminous liquid, plumes, cylindrical shading & meniscus.
        var chamberContext = context
        chamberContext.clip(to: innerPath)

        let hasLiquid = fillLevel > 0.0005 && layers.contains(where: { $0.fraction > 0 })
        if hasLiquid {
            let meniscusCurves = makeMeniscusPaths(
                innerRect: innerRect,
                centerY: m.meniscusCenterY,
                meniscusHeight: m.meniscusHeight,
                lipClimb: m.lipClimb,
                tilt: wobbleTilt
            )

            // Very faint tint in the empty air headspace so the backdrop shows through.
            if !reduceTransparency, m.meniscusCenterY > innerRect.minY + 1 {
                chamberContext.fill(
                    meniscusCurves.airHeadspace,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: .white.opacity(isDark ? 0.03 : 0.045), location: 0),
                            .init(color: .white.opacity(isDark ? 0.01 : 0.015), location: 1),
                        ]),
                        startPoint: CGPoint(x: innerRect.midX, y: innerRect.minY),
                        endPoint: CGPoint(x: innerRect.midX, y: m.meniscusCenterY)
                    )
                )
            }

            // Liquid body with 6-10pt soft-blended layer boundaries and vertical depth.
            var liquidContext = chamberContext
            liquidContext.clip(to: meniscusCurves.liquidBody)

            let stops = makeLiquidGradientStops(
                layers: layers,
                ranges: m.layerRanges,
                topY: m.meniscusCenterY,
                bottomY: innerRect.maxY,
                blendHeight: 8.0 * unitScale,
                isDark: isDark,
                reduceTransparency: reduceTransparency
            )
            liquidContext.fill(
                Path(innerRect),
                with: .linearGradient(
                    Gradient(stops: stops),
                    startPoint: CGPoint(x: innerRect.midX, y: m.meniscusCenterY),
                    endPoint: CGPoint(x: innerRect.midX, y: innerRect.maxY)
                )
            )

            if !reduceTransparency {
                let singleBodyLayer = layers.filter { $0.fraction > 0 }.count == 1
                // Inflow & outflow diffusion plumes inside the liquid near each stream's entry height.
                for inflow in inflows where inflow.height > 0 {
                    // When the body already carries the dominant outflow tint, skip redundant full-height self-plume.
                    if !inflow.fromLeft, singleBodyLayer, inflow.height >= innerRect.height * 0.45 {
                        continue
                    }
                    let entryMidY = inflow.y + inflow.height * 0.5
                    let radiusX = min(
                        innerRect.width * (inflow.fromLeft ? 0.56 : 0.48),
                        max(18 * unitScale, inflow.height * 1.5 + innerRect.width * 0.30)
                    )
                    let radiusY = max(
                        inflow.height * 0.85,
                        min(innerRect.height * 0.24, inflow.height * 0.65 + 13 * unitScale)
                    )
                    let plumeCenter = CGPoint(
                        x: inflow.fromLeft
                            ? innerRect.minX + radiusX * 0.10
                            : innerRect.maxX - radiusX * 0.10,
                        y: entryMidY
                    )
                    let peak = 0.23
                    fillEllipticalGradient(
                        in: &liquidContext,
                        center: plumeCenter,
                        radiusX: radiusX,
                        radiusY: radiusY,
                        gradient: Gradient(stops: [
                            .init(color: inflow.color.opacity(peak), location: 0),
                            .init(color: inflow.color.opacity(peak * 0.40), location: 0.54),
                            .init(color: .clear, location: 1),
                        ])
                    )
                }

                // Overall vertical depth pass (luminous top lift, gentle base depth).
                liquidContext.fill(
                    Path(innerRect),
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: .white.opacity(isDark ? 0.08 : 0.14), location: 0),
                            .init(color: .clear, location: 0.42),
                            .init(color: .black.opacity(isDark ? 0.08 : 0.04), location: 1),
                        ]),
                        startPoint: CGPoint(x: innerRect.midX, y: m.meniscusCenterY),
                        endPoint: CGPoint(x: innerRect.midX, y: innerRect.maxY)
                    )
                )

                // Light cylindrical shading across the width: <=0.08 black multiply at 0 and 1,
                // gentle highlight lift around 0.32, luminous base in the middle.
                let edgeShade = isDark ? 0.08 : 0.07
                var cylinderMultiply = liquidContext
                cylinderMultiply.blendMode = .multiply
                cylinderMultiply.fill(
                    Path(innerRect),
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: .black.opacity(edgeShade), location: 0),
                            .init(color: .black.opacity(edgeShade * 0.25), location: 0.14),
                            .init(color: .clear, location: 0.28),
                            .init(color: .clear, location: 0.70),
                            .init(color: .black.opacity(edgeShade * 0.28), location: 0.86),
                            .init(color: .black.opacity(edgeShade), location: 1),
                        ]),
                        startPoint: CGPoint(x: innerRect.minX, y: innerRect.midY),
                        endPoint: CGPoint(x: innerRect.maxX, y: innerRect.midY)
                    )
                )

                liquidContext.fill(
                    Path(innerRect),
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: .clear, location: 0.08),
                            .init(color: .white.opacity(isDark ? 0.14 : 0.18), location: 0.32),
                            .init(color: .clear, location: 0.58),
                        ]),
                        startPoint: CGPoint(x: innerRect.minX, y: innerRect.midY),
                        endPoint: CGPoint(x: innerRect.maxX, y: innerRect.midY)
                    )
                )
            }

            // Elliptical meniscus top surface (lighter than body), bright thin back-edge line,
            // and front capillary rim curving up 2-3pt at the walls.
            let topColor = layers.last(where: { $0.fraction > 0 })?.color ?? Palette.accent
            let meniscusTopY = m.meniscusCenterY - m.meniscusHeight * 0.5
            let meniscusBottomY = m.meniscusCenterY + m.meniscusHeight * 0.5

            if reduceTransparency {
                let solidMeniscus = topColor.mixed(with: .white, by: isDark ? 0.22 : 0.28)
                chamberContext.fill(meniscusCurves.surface, with: .color(solidMeniscus))
            } else {
                let rearTint = topColor.mixed(with: .white, by: isDark ? 0.36 : 0.48)
                let frontTint = topColor.mixed(with: .white, by: isDark ? 0.20 : 0.30)
                chamberContext.fill(
                    meniscusCurves.surface,
                    with: .linearGradient(
                        Gradient(colors: [
                            rearTint.opacity(isDark ? 0.62 : 0.72),
                            frontTint.opacity(isDark ? 0.44 : 0.54),
                        ]),
                        startPoint: CGPoint(x: innerRect.midX, y: meniscusTopY),
                        endPoint: CGPoint(x: innerRect.midX, y: meniscusBottomY)
                    )
                )
                chamberContext.fill(
                    meniscusCurves.surface,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: .white.opacity(0.06), location: 0),
                            .init(color: .white.opacity(isDark ? 0.24 : 0.34), location: 0.34),
                            .init(color: .white.opacity(0.08), location: 0.72),
                            .init(color: .white.opacity(0.04), location: 1),
                        ]),
                        startPoint: CGPoint(x: innerRect.minX, y: m.meniscusCenterY),
                        endPoint: CGPoint(x: innerRect.maxX, y: m.meniscusCenterY)
                    )
                )
            }

            // Bright thin back-edge line.
            chamberContext.stroke(
                meniscusCurves.backArc,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(0.18), location: 0),
                        .init(color: .white.opacity(reduceTransparency ? 0.45 : (isDark ? 0.54 : 0.70)), location: 0.22),
                        .init(color: .white.opacity(reduceTransparency ? 0.45 : (isDark ? 0.50 : 0.66)), location: 0.78),
                        .init(color: .white.opacity(0.16), location: 1),
                    ]),
                    startPoint: CGPoint(x: innerRect.minX, y: m.meniscusCenterY),
                    endPoint: CGPoint(x: innerRect.maxX, y: m.meniscusCenterY)
                ),
                style: StrokeStyle(lineWidth: 1.0 * unitScale, lineCap: .round)
            )

            // Front capillary meniscus edge curving up at the walls.
            chamberContext.stroke(
                meniscusCurves.frontArc,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(reduceTransparency ? 0.50 : (isDark ? 0.62 : 0.78)), location: 0),
                        .init(color: .white.opacity(reduceTransparency ? 0.56 : (isDark ? 0.66 : 0.84)), location: 0.35),
                        .init(color: .white.opacity(reduceTransparency ? 0.44 : (isDark ? 0.48 : 0.66)), location: 0.72),
                        .init(color: .white.opacity(reduceTransparency ? 0.48 : (isDark ? 0.56 : 0.72)), location: 1),
                    ]),
                    startPoint: CGPoint(x: innerRect.minX, y: m.meniscusCenterY),
                    endPoint: CGPoint(x: innerRect.maxX, y: m.meniscusCenterY)
                ),
                style: StrokeStyle(lineWidth: 1.15 * unitScale, lineCap: .round)
            )
        } else if !reduceTransparency {
            // Empty glass chamber: minimal tint so the backdrop shows through.
            chamberContext.fill(
                Path(innerRect),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(isDark ? 0.03 : 0.045), location: 0),
                        .init(color: .white.opacity(isDark ? 0.01 : 0.015), location: 1),
                    ]),
                    startPoint: CGPoint(x: innerRect.midX, y: innerRect.minY),
                    endPoint: CGPoint(x: innerRect.midX, y: innerRect.maxY)
                )
            )
        }

        // 4. Caustic elliptical light pool near the inside bottom.
        if !reduceTransparency {
            let causticRadiusX = innerRect.width * 0.37
            let causticRadiusY = max(5, min(22, min(innerRect.width * 0.11, innerRect.height * 0.08)))
            let causticCenter = CGPoint(
                x: innerRect.midX - innerRect.width * 0.04,
                y: innerRect.maxY - causticRadiusY * 0.95 - 2 * unitScale
            )
            fillEllipticalGradient(
                in: &chamberContext,
                center: causticCenter,
                radiusX: causticRadiusX,
                radiusY: causticRadiusY,
                gradient: Gradient(stops: [
                    .init(color: .white.opacity(0.18), location: 0),
                    .init(color: .white.opacity(0.07), location: 0.55),
                    .init(color: .clear, location: 1),
                ])
            )
        }

        // 5. Specular highlights:
        //    broad left vertical highlight (18% width, white 0.35->0), sharp narrow streak (2-3pt, white 0.7),
        //    faint right-edge rim light (all fading over top/bottom 15%), plus curved top-left shoulder catchlight.
        if !reduceTransparency {
            var chamberSpecular = context
            chamberSpecular.clip(to: innerPath)

            let broadX = innerRect.minX + rect.width * 0.008
            let broadWidth = max(6, rect.width * 0.18)
            let broadRect = CGRect(x: broadX, y: rect.minY, width: broadWidth, height: rect.height)

            let streakWidth = 2.4 * unitScale
            let streakX = innerRect.minX + max(2 * unitScale, broadWidth * 0.18)
            let streakRect = CGRect(x: streakX, y: rect.minY, width: streakWidth, height: rect.height)

            let rightRimWidth = max(3 * unitScale, innerRect.width * 0.05)
            let rightRimRect = CGRect(
                x: innerRect.maxX - rightRimWidth,
                y: rect.minY,
                width: rightRimWidth,
                height: rect.height
            )

            chamberSpecular.drawLayer { layer in
                layer.fill(
                    Path(broadRect),
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: .white.opacity(isDark ? 0.28 : 0.32), location: 0),
                            .init(color: .white.opacity(isDark ? 0.10 : 0.13), location: 0.46),
                            .init(color: .clear, location: 1),
                        ]),
                        startPoint: CGPoint(x: broadRect.minX, y: broadRect.midY),
                        endPoint: CGPoint(x: broadRect.maxX, y: broadRect.midY)
                    )
                )

                let streakPath = Capsule().path(in: streakRect)
                layer.fill(
                    streakPath,
                    with: .color(.white.opacity(isDark ? 0.58 : 0.66))
                )

                layer.fill(
                    Path(rightRimRect),
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(isDark ? 0.12 : 0.16), location: 1),
                        ]),
                        startPoint: CGPoint(x: rightRimRect.minX, y: rightRimRect.midY),
                        endPoint: CGPoint(x: rightRimRect.maxX, y: rightRimRect.midY)
                    )
                )

                var fadeMask = layer
                fadeMask.blendMode = .destinationIn
                fadeMask.fill(
                    Path(rect),
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white, location: 0.15),
                            .init(color: .white, location: 0.85),
                            .init(color: .clear, location: 1),
                        ]),
                        startPoint: CGPoint(x: rect.midX, y: rect.minY),
                        endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                    )
                )
            }

            // Small curved highlight on the top-left shoulder.
            var shoulderContext = context
            shoulderContext.clip(to: outerPath)
            let shoulderInset = m.wallThickness * 0.50
            let shoulderRect = rect.insetBy(dx: shoulderInset, dy: shoulderInset)
            let shoulderRadius = max(4, min(m.outerCornerRadius - shoulderInset, min(shoulderRect.width, shoulderRect.height) * 0.42))
            let shoulderStart = CGPoint(
                x: shoulderRect.minX,
                y: shoulderRect.minY + shoulderRadius * 0.90
            )
            let shoulderEnd = CGPoint(
                x: shoulderRect.minX + shoulderRadius * 0.90,
                y: shoulderRect.minY
            )
            var shoulderArc = Path()
            shoulderArc.move(to: shoulderStart)
            shoulderArc.addQuadCurve(
                to: shoulderEnd,
                control: CGPoint(
                    x: shoulderRect.minX + shoulderRadius * 0.10,
                    y: shoulderRect.minY + shoulderRadius * 0.10
                )
            )
            shoulderContext.stroke(
                shoulderArc,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(0.04), location: 0),
                        .init(color: .white.opacity(isDark ? 0.48 : 0.60), location: 0.45),
                        .init(color: .white.opacity(0.05), location: 1),
                    ]),
                    startPoint: shoulderStart,
                    endPoint: shoulderEnd
                ),
                style: StrokeStyle(lineWidth: 1.3 * unitScale, lineCap: .round)
            )
        }

        // 6. Crisp 1pt outer rim only (inner hairline reserved for Reduce Transparency).
        if reduceTransparency {
            context.stroke(innerPath, with: .color(Palette.hairline), lineWidth: 1.0 * unitScale)
        }

        let outerStrokeWidth = 1.0 * unitScale
        let outerRimRect = rect.insetBy(dx: outerStrokeWidth * 0.5, dy: outerStrokeWidth * 0.5)
        let outerRimPath = RoundedRectangle(
            cornerRadius: max(1, m.outerCornerRadius - outerStrokeWidth * 0.5),
            style: .continuous
        ).path(in: outerRimRect)
        let outerRimColor = isDark ? Color.white.opacity(0.16) : Palette.ink1.opacity(0.12)
        context.stroke(outerRimPath, with: .color(outerRimColor), lineWidth: outerStrokeWidth)
    }

    // MARK: - Private geometry & shading helpers

    private struct MeniscusPaths {
        let backArc: Path
        let frontArc: Path
        let surface: Path
        let liquidBody: Path
        let airHeadspace: Path
    }

    private static func makeMeniscusPaths(
        innerRect: CGRect,
        centerY: CGFloat,
        meniscusHeight: CGFloat,
        lipClimb: CGFloat,
        tilt: CGFloat
    ) -> MeniscusPaths {
        let minX = innerRect.minX
        let maxX = innerRect.maxX
        let width = innerRect.width
        let halfH = meniscusHeight * 0.5

        let leftY = centerY - lipClimb + tilt
        let rightY = centerY - lipClimb - tilt
        let midLipY = (leftY + rightY) * 0.5

        let backApexY = centerY - halfH
        let frontApexY = centerY + halfH
        // Solve cubic Bezier midpoint y(0.5) = 0.25 * midLipY + 0.75 * controlY = apexY.
        let backControlY = (backApexY - 0.25 * midLipY) / 0.75
        let frontControlY = (frontApexY - 0.25 * midLipY) / 0.75

        let backC1 = CGPoint(x: minX + width * 0.22, y: backControlY + tilt * 0.35)
        let backC2 = CGPoint(x: maxX - width * 0.22, y: backControlY - tilt * 0.35)
        let frontC1 = CGPoint(x: minX + width * 0.16, y: frontControlY + tilt * 0.35)
        let frontC2 = CGPoint(x: maxX - width * 0.16, y: frontControlY - tilt * 0.35)

        var backArc = Path()
        backArc.move(to: CGPoint(x: minX, y: leftY))
        backArc.addCurve(to: CGPoint(x: maxX, y: rightY), control1: backC1, control2: backC2)

        var frontArc = Path()
        frontArc.move(to: CGPoint(x: minX, y: leftY))
        frontArc.addCurve(to: CGPoint(x: maxX, y: rightY), control1: frontC1, control2: frontC2)

        var surface = Path()
        surface.move(to: CGPoint(x: minX, y: leftY))
        surface.addCurve(to: CGPoint(x: maxX, y: rightY), control1: backC1, control2: backC2)
        surface.addCurve(to: CGPoint(x: minX, y: leftY), control1: frontC2, control2: frontC1)
        surface.closeSubpath()

        var liquidBody = Path()
        liquidBody.move(to: CGPoint(x: minX, y: leftY))
        liquidBody.addCurve(to: CGPoint(x: maxX, y: rightY), control1: backC1, control2: backC2)
        liquidBody.addLine(to: CGPoint(x: maxX, y: innerRect.maxY + 2))
        liquidBody.addLine(to: CGPoint(x: minX, y: innerRect.maxY + 2))
        liquidBody.closeSubpath()

        var airHeadspace = Path()
        airHeadspace.move(to: CGPoint(x: minX, y: innerRect.minY - 2))
        airHeadspace.addLine(to: CGPoint(x: maxX, y: innerRect.minY - 2))
        airHeadspace.addLine(to: CGPoint(x: maxX, y: rightY))
        airHeadspace.addCurve(to: CGPoint(x: minX, y: leftY), control1: backC2, control2: backC1)
        airHeadspace.closeSubpath()

        return MeniscusPaths(
            backArc: backArc,
            frontArc: frontArc,
            surface: surface,
            liquidBody: liquidBody,
            airHeadspace: airHeadspace
        )
    }

    private static func makeLiquidGradientStops(
        layers: [Layer],
        ranges: [ClosedRange<CGFloat>],
        topY: CGFloat,
        bottomY: CGFloat,
        blendHeight: CGFloat,
        isDark: Bool,
        reduceTransparency: Bool
    ) -> [Gradient.Stop] {
        let span = max(1, bottomY - topY)

        // Convert bottom-up layers into top-down visual segments.
        var segments: [(color: Color, minY: CGFloat, maxY: CGFloat)] = []
        segments.reserveCapacity(layers.count)
        for index in layers.indices.reversed() {
            guard layers[index].fraction > 0, index < ranges.count else { continue }
            let range = ranges[index]
            guard range.upperBound > range.lowerBound else { continue }
            segments.append((layers[index].color, range.lowerBound, range.upperBound))
        }

        guard !segments.isEmpty else {
            let fallback = Palette.accent
            return [
                .init(color: liquidStopColor(base: fallback, depth: 0, isDark: isDark, reduceTransparency: reduceTransparency), location: 0),
                .init(color: liquidStopColor(base: fallback, depth: 1, isDark: isDark, reduceTransparency: reduceTransparency), location: 1),
            ]
        }

        if segments.count == 1 {
            let color = segments[0].color
            return [
                .init(color: liquidStopColor(base: color, depth: 0, isDark: isDark, reduceTransparency: reduceTransparency), location: 0),
                .init(color: liquidStopColor(base: color, depth: 1, isDark: isDark, reduceTransparency: reduceTransparency), location: 1),
            ]
        }

        var stops: [Gradient.Stop] = []
        stops.reserveCapacity(segments.count * 2)
        var lastLocation = 0.0

        for index in segments.indices {
            let seg = segments[index]
            let height = max(0, seg.maxY - seg.minY)
            let topFeather: CGFloat = if index == 0 {
                0
            } else {
                min(
                    blendHeight * 0.5,
                    0.42 * min(max(0, segments[index - 1].maxY - segments[index - 1].minY), height)
                )
            }
            let bottomFeather: CGFloat = if index == segments.count - 1 {
                0
            } else {
                min(
                    blendHeight * 0.5,
                    0.42 * min(height, max(0, segments[index + 1].maxY - segments[index + 1].minY))
                )
            }

            let yStart = seg.minY + topFeather
            let yEnd = max(yStart, seg.maxY - bottomFeather)
            let locStart = min(1, max(lastLocation, Double((yStart - topY) / span)))
            let locEnd = min(1, max(locStart, Double((yEnd - topY) / span)))
            lastLocation = locEnd

            stops.append(.init(
                color: liquidStopColor(base: seg.color, depth: locStart, isDark: isDark, reduceTransparency: reduceTransparency),
                location: locStart
            ))
            stops.append(.init(
                color: liquidStopColor(base: seg.color, depth: locEnd, isDark: isDark, reduceTransparency: reduceTransparency),
                location: locEnd
            ))
        }

        return stops
    }

    private static func liquidStopColor(
        base: Color,
        depth: Double,
        isDark: Bool,
        reduceTransparency: Bool
    ) -> Color {
        let d = min(max(depth, 0), 1)
        if reduceTransparency {
            let lift = (1 - d) * (isDark ? 0.06 : 0.10)
            let deepen = d * (isDark ? 0.08 : 0.05)
            return base
                .mixed(with: .white, by: lift)
                .mixed(with: .black, by: deepen)
        }
        let lift = (1 - d) * (isDark ? 0.10 : 0.16)
        let deepen = d * (isDark ? 0.06 : 0.02)
        let pigmented = base
            .mixed(with: .white, by: lift)
            .mixed(with: .black, by: deepen)
        let alpha = (isDark ? 0.64 : 0.62) + d * 0.12
        return pigmented.opacity(alpha)
    }

    private static func fillEllipticalGradient(
        in context: inout GraphicsContext,
        center: CGPoint,
        radiusX: CGFloat,
        radiusY: CGFloat,
        gradient: Gradient
    ) {
        guard radiusX > 0.5, radiusY > 0.5 else { return }
        var transformed = context
        transformed.translateBy(x: center.x, y: center.y)
        transformed.scaleBy(x: 1, y: radiusY / radiusX)
        let circleRect = CGRect(x: -radiusX, y: -radiusX, width: radiusX * 2, height: radiusX * 2)
        transformed.fill(
            Path(ellipseIn: circleRect),
            with: .radialGradient(
                gradient,
                center: .zero,
                startRadius: 0,
                endRadius: radiusX
            )
        )
    }
}
