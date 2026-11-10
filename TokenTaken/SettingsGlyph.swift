import SwiftUI

struct SettingsGlyph: View {
    var size: CGFloat = 18
    var isHovered = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ringWidth: CGFloat { max(1, size * 0.07) }
    private var detailWidth: CGFloat { max(1, size * 0.055) }
    private var liquidBlue: Color {
        Color(light: "#4A86C4", dark: "#6DA5D8")
    }

    var body: some View {
        ZStack {
            ToothedSettingsRing(teeth: 11)
                .stroke(style: StrokeStyle(lineWidth: ringWidth, lineCap: .round, lineJoin: .round))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .rotationEffect(.degrees(isHovered && !reduceMotion ? 30 : 0))
                .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.72), value: isHovered)

            Circle()
                .stroke(lineWidth: detailWidth)
                .foregroundStyle(.secondary)
                .frame(width: size * 0.46, height: size * 0.46)

            SettingsLiquidArc()
                .stroke(style: StrokeStyle(lineWidth: detailWidth, lineCap: .round))
                .foregroundStyle(liquidBlue)
                .frame(width: size * 0.31, height: size * 0.31)
                .offset(y: size * 0.055)

            Circle()
                .fill(.secondary)
                .frame(width: max(2, size * 0.12), height: max(2, size * 0.12))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct ToothedSettingsRing: Shape {
    let teeth: Int

    func path(in rect: CGRect) -> Path {
        let insetRect = rect.insetBy(dx: 0.75, dy: 0.75)
        let center = CGPoint(x: insetRect.midX, y: insetRect.midY)
        let outerRadius = min(insetRect.width, insetRect.height) / 2
        let rootRadius = outerRadius * 0.8
        let sampleCount = teeth * 12
        var path = Path()

        for index in 0...sampleCount {
            let progress = Double(index % sampleCount) / Double(sampleCount)
            let angle = progress * 2 * .pi - .pi / 2
            let toothPosition = (progress * Double(teeth)).truncatingRemainder(dividingBy: 1)
            let edgeDistance = abs(toothPosition - 0.5) * 2
            let transition = min(max((edgeDistance - 0.34) / 0.56, 0), 1)
            let smoothing = transition * transition * (3 - 2 * transition)
            let radius = outerRadius - (outerRadius - rootRadius) * CGFloat(smoothing)
            let point = CGPoint(
                x: center.x + CGFloat(cos(angle)) * radius,
                y: center.y + CGFloat(sin(angle)) * radius
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}

private struct SettingsLiquidArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) / 2 - 0.5,
            startAngle: .degrees(28),
            endAngle: .degrees(152),
            clockwise: false
        )
        return path
    }
}
