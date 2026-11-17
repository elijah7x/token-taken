import SwiftUI

/// Two selectable schematic thumbnail cards for Liquid Glass's View setting (`Confluence` vs `Lens`).
struct LiquidViewPicker: View {
    @Binding var selection: LiquidView

    @FocusState private var focusedOption: LiquidView?
    @State private var hoveredOption: LiquidView?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 12) {
            ForEach(LiquidView.allCases) { option in
                optionButton(option)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("View"))
    }

    private func optionButton(_ option: LiquidView) -> some View {
        let isSelected = selection == option
        let isHovered = hoveredOption == option
        let cardShape = RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)

        return Button {
            selection = option
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    cardShape
                        .fill(Palette.cardSurface)

                    switch option {
                    case .confluence:
                        ConfluenceThumbnailCanvas(isDark: scheme == .dark)
                    case .lens:
                        LensThumbnailCanvas(
                            isDark: scheme == .dark,
                            reduceTransparency: reduceTransparency
                        )
                    }
                }
                .frame(width: 120, height: 76)
                .clipShape(cardShape)
                .overlay {
                    cardShape.strokeBorder(
                        isSelected
                            ? Palette.roleAccent
                            : (isHovered ? Palette.ink3.opacity(0.45) : Palette.hairline),
                        lineWidth: isSelected ? 2 : 1
                    )
                }

                Text(option.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Palette.ink1 : Palette.ink2)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredOption = option
            } else if hoveredOption == option {
                hoveredOption = nil
            }
        }
        .focused($focusedOption, equals: option)
        .onKeyPress(.leftArrow) {
            selection = .confluence
            focusedOption = .confluence
            return .handled
        }
        .onKeyPress(.rightArrow) {
            selection = .lens
            focusedOption = .lens
            return .handled
        }
        .accessibilityLabel(Text(option.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Schematic Confluence preview: three colored ribbons converging into a rounded glass reservoir.
private struct ConfluenceThumbnailCanvas: View {
    let isDark: Bool

    var body: some View {
        Canvas { context, size in
            let c1 = Palette.color(forSource: "claude")
            let c2 = Palette.color(forSource: "codex")
            let c3 = Palette.color(forSource: "zcode")

            let vesselRect = CGRect(
                x: size.width * 0.54,
                y: 13,
                width: 42,
                height: size.height - 26
            )
            let targetX = vesselRect.minX + 3

            // Three Bezier streams entering from the left into the reservoir wall.
            let specs: [(y0: CGFloat, h0: CGFloat, y1: CGFloat, h1: CGFloat, color: Color)] = [
                (15, 11, vesselRect.minY + 13, 9, c1),
                (33, 9, vesselRect.minY + 23.5, 8, c2),
                (49, 7, vesselRect.minY + 33, 6.5, c3),
            ]

            for spec in specs {
                let path = ribbonPath(
                    x0: 12,
                    top0: spec.y0,
                    bottom0: spec.y0 + spec.h0,
                    x1: targetX,
                    top1: spec.y1,
                    bottom1: spec.y1 + spec.h1
                )
                context.fill(path, with: .color(spec.color.opacity(isDark ? 0.82 : 0.85)))
            }

            // Rounded reservoir body + stratified liquid + meniscus + rim.
            let vesselShape = Path(roundedRect: vesselRect, cornerRadius: 10, style: .continuous)
            context.fill(
                vesselShape,
                with: .color(isDark ? Color.white.opacity(0.06) : Color.white.opacity(0.70))
            )

            let innerRect = vesselRect.insetBy(dx: 2.5, dy: 2.5)
            let innerClip = Path(roundedRect: innerRect, cornerRadius: 7.5, style: .continuous)
            context.drawLayer { layer in
                layer.clip(to: innerClip)

                let waterTop = innerRect.minY + innerRect.height * 0.24
                let waterH = innerRect.maxY - waterTop
                let band1 = CGRect(x: innerRect.minX, y: waterTop, width: innerRect.width, height: waterH * 0.34)
                let band2 = CGRect(x: innerRect.minX, y: band1.maxY, width: innerRect.width, height: waterH * 0.34)
                let band3 = CGRect(x: innerRect.minX, y: band2.maxY, width: innerRect.width, height: innerRect.maxY - band2.maxY)

                layer.fill(Path(band1), with: .color(c3.opacity(isDark ? 0.72 : 0.76)))
                layer.fill(Path(band2), with: .color(c2.opacity(isDark ? 0.78 : 0.82)))
                layer.fill(Path(band3), with: .color(c1.opacity(isDark ? 0.84 : 0.88)))

                var meniscus = Path()
                meniscus.move(to: CGPoint(x: innerRect.minX, y: waterTop))
                meniscus.addQuadCurve(
                    to: CGPoint(x: innerRect.maxX, y: waterTop),
                    control: CGPoint(x: innerRect.midX, y: waterTop + 2.5)
                )
                layer.stroke(
                    meniscus,
                    with: .color(.white.opacity(isDark ? 0.55 : 0.90)),
                    lineWidth: 1.3
                )
            }

            context.stroke(
                vesselShape,
                with: .color(isDark ? Color.white.opacity(0.28) : Color(hex: "#0F172A").opacity(0.16)),
                lineWidth: 1.1
            )
        }
        .accessibilityHidden(true)
    }

    private func ribbonPath(
        x0: CGFloat,
        top0: CGFloat,
        bottom0: CGFloat,
        x1: CGFloat,
        top1: CGFloat,
        bottom1: CGFloat
    ) -> Path {
        let midX = (x0 + x1) * 0.52
        var path = Path()
        path.move(to: CGPoint(x: x0, y: top0))
        path.addCurve(
            to: CGPoint(x: x1, y: top1),
            control1: CGPoint(x: midX, y: top0),
            control2: CGPoint(x: midX, y: top1)
        )
        path.addLine(to: CGPoint(x: x1, y: bottom1))
        path.addCurve(
            to: CGPoint(x: x0, y: bottom0),
            control1: CGPoint(x: midX, y: bottom1),
            control2: CGPoint(x: midX, y: bottom0)
        )
        path.closeSubpath()
        return path
    }
}

/// Schematic Lens preview: a row of mini stacked bars with a glass capsule magnifying the central bars.
private struct LensThumbnailCanvas: View {
    let isDark: Bool
    let reduceTransparency: Bool

    private static let heights: [[CGFloat]] = [
        [7, 5, 3],
        [10, 7, 4],
        [6, 5, 2],
        [13, 8, 5],
        [18, 11, 7],
        [15, 9, 5],
        [9, 6, 3],
        [12, 7, 4],
        [8, 4, 2],
    ]

    var body: some View {
        Canvas { context, size in
            let c1 = Palette.color(forSource: "claude")
            let c2 = Palette.color(forSource: "codex")
            let c3 = Palette.color(forSource: "zcode")
            let colors = [c1, c2, c3]

            let leftPad: CGFloat = 12
            let rightPad: CGFloat = 12
            let baselineY = size.height - 13
            let plotW = size.width - leftPad - rightPad
            let count = Self.heights.count
            let slotW = plotW / CGFloat(count)
            let barW: CGFloat = 6

            // Subtle baseline rule.
            var baseline = Path()
            baseline.move(to: CGPoint(x: leftPad, y: baselineY + 0.5))
            baseline.addLine(to: CGPoint(x: size.width - rightPad, y: baselineY + 0.5))
            context.stroke(
                baseline,
                with: .color(isDark ? Color.white.opacity(0.10) : Color(hex: "#0F172A").opacity(0.09)),
                lineWidth: 1
            )

            let lensCenterIndex = 4
            let lensCx = leftPad + (CGFloat(lensCenterIndex) + 0.5) * slotW
            let lensRect = CGRect(x: lensCx - 15, y: 10, width: 30, height: baselineY - 6)
            let lensShape = Path(roundedRect: lensRect, cornerRadius: 15, style: .continuous)

            // Pass 1: Low-opacity base bars outside the lens.
            context.drawLayer { baseLayer in
                var inverseClip = Path(CGRect(origin: .zero, size: size))
                inverseClip.addPath(lensShape)
                baseLayer.clip(to: inverseClip, style: FillStyle(eoFill: true))

                let dimAlpha = isDark ? 0.30 : 0.36
                for (index, segs) in Self.heights.enumerated() {
                    let cx = leftPad + (CGFloat(index) + 0.5) * slotW
                    drawStackedBar(
                        in: &baseLayer,
                        centerX: cx,
                        bottomY: baselineY,
                        barWidth: barW,
                        segments: segs,
                        scale: 1.0,
                        colors: colors,
                        alpha: dimAlpha
                    )
                }
            }

            // Pass 2: Glass capsule + magnified vivid bars inside.
            if !reduceTransparency {
                context.drawLayer { shadowLayer in
                    shadowLayer.addFilter(.shadow(
                        color: .black.opacity(isDark ? 0.42 : 0.14),
                        radius: 5,
                        x: 0,
                        y: 2
                    ))
                    shadowLayer.fill(
                        lensShape,
                        with: .color(isDark ? Color(hex: "#1C2638").opacity(0.88) : Color.white.opacity(0.88))
                    )
                }
            } else {
                context.fill(lensShape, with: .color(Palette.cardSurface))
            }

            context.drawLayer { magLayer in
                magLayer.clip(to: lensShape)

                if !reduceTransparency {
                    magLayer.fill(
                        Path(lensRect),
                        with: .linearGradient(
                            Gradient(colors: isDark
                                ? [Color.white.opacity(0.12), Color.clear]
                                : [Color.white.opacity(0.75), Color(hex: "#E8F1FF").opacity(0.35)]),
                            startPoint: CGPoint(x: lensRect.midX, y: lensRect.minY),
                            endPoint: CGPoint(x: lensRect.midX, y: lensRect.maxY)
                        )
                    )
                }

                for index in (lensCenterIndex - 1)...(lensCenterIndex + 1) {
                    let segs = Self.heights[index]
                    let isTarget = index == lensCenterIndex
                    let slotCx = leftPad + (CGFloat(index) + 0.5) * slotW
                    let cx = lensCx + (slotCx - lensCx) * 1.22
                    drawStackedBar(
                        in: &magLayer,
                        centerX: cx,
                        bottomY: baselineY,
                        barWidth: isTarget ? barW * 1.32 : barW * 1.06,
                        segments: segs,
                        scale: isTarget ? 1.32 : 1.10,
                        colors: colors,
                        alpha: isTarget ? 0.96 : 0.48
                    )
                }
            }

            if reduceTransparency {
                context.stroke(lensShape, with: .color(Palette.roleAccent), lineWidth: 1.8)
            } else {
                context.stroke(
                    lensShape,
                    with: .color(isDark ? Color.white.opacity(0.42) : Color.white.opacity(0.95)),
                    lineWidth: 1.2
                )
                context.stroke(
                    lensShape,
                    with: .color(Palette.roleAccent.opacity(isDark ? 0.45 : 0.28)),
                    lineWidth: 0.8
                )
            }
        }
        .accessibilityHidden(true)
    }

    private func drawStackedBar(
        in context: inout GraphicsContext,
        centerX: CGFloat,
        bottomY: CGFloat,
        barWidth: CGFloat,
        segments: [CGFloat],
        scale: CGFloat,
        colors: [Color],
        alpha: Double
    ) {
        var currentY = bottomY
        let x = centerX - barWidth * 0.5
        for (idx, rawH) in segments.enumerated() {
            let h = max(1.2, rawH * scale)
            let nextY = currentY - h
            let isTop = idx == segments.count - 1
            let rect = CGRect(x: x, y: nextY, width: barWidth, height: max(0.8, h - 0.5))
            let path = isTop
                ? Path(
                    roundedRect: rect,
                    cornerRadii: RectangleCornerRadii(
                        topLeading: min(2.5, barWidth * 0.45),
                        bottomLeading: 0,
                        bottomTrailing: 0,
                        topTrailing: min(2.5, barWidth * 0.45)
                    ),
                    style: .continuous
                )
                : Path(rect)
            context.fill(path, with: .color(colors[idx % colors.count].opacity(alpha)))
            currentY = nextY
        }
    }
}
