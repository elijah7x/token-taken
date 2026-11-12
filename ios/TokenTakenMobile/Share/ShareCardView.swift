import SwiftUI

/// 1080x1350 portrait share card, following the macOS Tide Line card's liquid-glass language.
/// Always renders in light appearance so `ImageRenderer` output is identical on every device.
struct ShareCardView: View {
    static let size = CGSize(width: 1080, height: 1350)
    static let canvasMargin: CGFloat = 84

    let last30Days: Int64
    let allTime: Int64
    let rankLine: String?
    let comparison: String?
    let period: String
    let footnote: String
    let chineseUnits: Bool
    var isSample = false

    private var vesselRect: CGRect {
        let top: CGFloat = 660
        let bottom = Self.size.height - 64
        return CGRect(
            x: Self.canvasMargin,
            y: top,
            width: Self.size.width - Self.canvasMargin * 2,
            height: bottom - top
        )
    }

    private var fillLevel: Double {
        guard allTime > 0, last30Days > 0 else { return 0 }
        return min(1, max(0.04, Double(last30Days) / Double(allTime)))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            content
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .light)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                ShareDropGlyph()
                    .frame(width: 34, height: 40)
                    .accessibilityHidden(true)

                Text(verbatim: "Token Taken")
                    .font(.system(size: 34, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(Palette.ink1)

                Spacer(minLength: 12)

                if isSample {
                    Text("Sample data")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Palette.warn)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background { Capsule().fill(Palette.warn.opacity(0.14)) }
                }
            }

            Text(verbatim: period)
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(Palette.ink2)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 12)

            heroBlock
                .padding(.top, 20)

            if let rankLine {
                Text(verbatim: rankLine)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Palette.ink1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.top, 16)
            }

            if let comparison {
                Text(verbatim: comparison)
                    .font(.system(size: 29))
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .padding(.top, 10)
            }

            Text(verbatim: footnote)
                .font(.system(size: 20))
                .foregroundStyle(Palette.ink3)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .padding(.top, 14)
        }
        .padding(.horizontal, Self.canvasMargin)
        .padding(.top, 68)
        .frame(width: Self.size.width, alignment: .leading)
    }

    private var heroBlock: some View {
        let formatted = TokenFormat.short(last30Days, chineseUnits: chineseUnits)
        let (digits, unit) = TokenFormat.split(formatted)

        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: digits)
                    .font(.system(size: 150, weight: .bold))
                    .tracking(-5)
                    .foregroundStyle(Palette.ink1)
                    .monospacedDigit()

                if !unit.isEmpty {
                    Text(verbatim: unit)
                        .font(.system(size: 74, weight: .semibold))
                        .tracking(-1.2)
                        .foregroundStyle(Palette.ink1)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)

            Text("Token")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Palette.ink2)
                .padding(.leading, 18)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Last 30 days"))
        .accessibilityValue(Text(verbatim: TokenFormat.spoken(last30Days, locale: Locale(identifier: chineseUnits ? "zh_CN" : "en_US"))))
    }

    private var backdrop: some View {
        Canvas { context, size in
            let full = CGRect(origin: .zero, size: size)
            context.fill(
                Path(full),
                with: .linearGradient(
                    Gradient(colors: [Color(hex: "#F7F4F0"), Color(hex: "#EEF2F8")]),
                    startPoint: CGPoint(x: size.width / 2, y: 0),
                    endPoint: CGPoint(x: size.width / 2, y: size.height)
                )
            )

            let glowSpan = max(size.width, size.height)
            let warm = Color(.sRGB, red: 255 / 255, green: 205 / 255, blue: 172 / 255, opacity: 0.68)
            let cool = Color(.sRGB, red: 172 / 255, green: 203 / 255, blue: 248 / 255, opacity: 0.72)
            let depth = Color(.sRGB, red: 204 / 255, green: 216 / 255, blue: 246 / 255, opacity: 0.78)

            context.fill(
                Path(full),
                with: .radialGradient(
                    Gradient(colors: [warm, .clear]),
                    center: CGPoint(x: size.width * 0.10, y: size.height * 0.06),
                    startRadius: 0,
                    endRadius: glowSpan * 0.58
                )
            )
            context.fill(
                Path(full),
                with: .radialGradient(
                    Gradient(colors: [cool, .clear]),
                    center: CGPoint(x: size.width * 0.96, y: size.height * 0.32),
                    startRadius: 0,
                    endRadius: glowSpan * 0.62
                )
            )
            context.fill(
                Path(full),
                with: .radialGradient(
                    Gradient(colors: [depth, .clear]),
                    center: CGPoint(x: size.width * 0.42, y: size.height * 1.06),
                    startRadius: 0,
                    endRadius: glowSpan * 0.64
                )
            )

            if fillLevel > 0 {
                let bloomCenter = CGPoint(
                    x: vesselRect.midX,
                    y: (vesselRect.minY + 120 + vesselRect.maxY) * 0.5
                )
                context.fill(
                    Path(full),
                    with: .radialGradient(
                        Gradient(colors: [Palette.accent.opacity(0.20), .clear]),
                        center: bloomCenter,
                        startRadius: 0,
                        endRadius: max(vesselRect.width, vesselRect.height) * 0.65
                    )
                )
            }

            LiquidGlassVessel.draw(
                in: &context,
                rect: vesselRect,
                cornerRadius: 46,
                layers: fillLevel > 0
                    ? [LiquidGlassVessel.Layer(color: Palette.accent, fraction: fillLevel)]
                    : [],
                fillLevel: fillLevel,
                isDark: false,
                reduceTransparency: false
            )

            let rimRect = full.insetBy(dx: 1.5, dy: 1.5)
            context.stroke(Path(rimRect), with: .color(.white.opacity(0.65)), lineWidth: 3)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityHidden(true)
    }
}

/// Wordmark droplet, same path as the macOS share card.
struct ShareDropGlyph: View {
    var body: some View {
        Canvas { context, size in
            let sx = size.width / 14
            let sy = size.height / 16

            var drop = Path()
            drop.move(to: CGPoint(x: 7 * sx, y: 0.8 * sy))
            drop.addCurve(
                to: CGPoint(x: 1.4 * sx, y: 10.3 * sy),
                control1: CGPoint(x: 7 * sx, y: 0.8 * sy),
                control2: CGPoint(x: 1.4 * sx, y: 6.9 * sy)
            )
            drop.addCurve(
                to: CGPoint(x: 7.0 * sx, y: 15.9 * sy),
                control1: CGPoint(x: 1.4 * sx, y: 13.4 * sy),
                control2: CGPoint(x: 3.9 * sx, y: 15.9 * sy)
            )
            drop.addCurve(
                to: CGPoint(x: 12.6 * sx, y: 10.3 * sy),
                control1: CGPoint(x: 10.1 * sx, y: 15.9 * sy),
                control2: CGPoint(x: 12.6 * sx, y: 13.4 * sy)
            )
            drop.addCurve(
                to: CGPoint(x: 7 * sx, y: 0.8 * sy),
                control1: CGPoint(x: 12.6 * sx, y: 6.9 * sy),
                control2: CGPoint(x: 7 * sx, y: 0.8 * sy)
            )
            drop.closeSubpath()

            context.fill(
                drop,
                with: .linearGradient(
                    Gradient(colors: [Color(hex: "#7CC8F2"), Color(hex: "#3A9BE0")]),
                    startPoint: CGPoint(x: size.width / 2, y: 0),
                    endPoint: CGPoint(x: size.width / 2, y: size.height)
                )
            )

            var highlight = Path()
            highlight.move(to: CGPoint(x: 4.2 * sx, y: 10.6 * sy))
            highlight.addQuadCurve(
                to: CGPoint(x: 6.6 * sx, y: 13.2 * sy),
                control: CGPoint(x: 4.5 * sx, y: 12.7 * sy)
            )
            context.stroke(
                highlight,
                with: .color(.white.opacity(0.78)),
                style: StrokeStyle(lineWidth: max(1.5, 1.1 * sx), lineCap: .round)
            )
        }
    }
}
