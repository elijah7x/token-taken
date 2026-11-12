import SwiftUI

extension View {
    /// Grounded card surface matching the macOS Atmosphere cards, minus the glass.
    func cardSurface() -> some View {
        modifier(CardSurfaceModifier())
    }
}

private struct CardSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        content
            .background { shape.fill(Palette.cardSurface) }
            .clipShape(shape)
            .overlay { shape.strokeBorder(Palette.hairline, lineWidth: 0.5) }
    }
}

struct SampleDataBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .accessibilityHidden(true)
            Text("Sample data")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(Palette.warn)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background { Capsule().fill(Palette.warn.opacity(0.14)) }
        .accessibilityElement(children: .combine)
    }
}

struct StatusBanner: View {
    let text: LocalizedStringKey
    let systemImage: String
    var tint: Color = Palette.warn

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .font(.footnote)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.12)) }
    }
}

struct StatRow: View {
    let label: LocalizedStringKey
    let tokens: Int64

    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(Palette.ink2)
            Spacer(minLength: 12)
            Text(verbatim: TokenFormat.short(tokens, locale: locale))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.ink1)
        }
        .font(.callout)
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(verbatim: TokenFormat.spoken(tokens, locale: locale)))
    }
}

struct SectionHeader: View {
    let title: LocalizedStringKey
    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(Palette.ink1)
    }
}
