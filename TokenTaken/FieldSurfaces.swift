import AppKit
import SwiftUI
import TokenTakenKit

/// The active theme for code that draws outside the SwiftUI environment (dynamic `NSColor` providers, glass helpers).
/// `AppSettings` keeps it in step with `theme` and bumps `formatRevision` so every scene rebuilds on a change.
enum ThemeRuntime {
    nonisolated(unsafe) static var isField = false
}

/// Solid paper button with a ruled edge, replacing `.glass` under the Field theme.
struct FieldButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? FieldPalette.rule : FieldPalette.panel)
            )
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(FieldPalette.rule, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension FieldCrop {
    private static let lightHex = ["#B98E34", "#8270A8", "#B9673A", "#4F7F80", "#557A41", "#A99B2E", "#6F8F4C", "#BB7C82", "#6B8DAF", "#8E8C47"]
    private static let darkHex = ["#D9B465", "#AA9BD1", "#DB8E62", "#7FB0B0", "#86AA6F", "#CFC261", "#9DBB78", "#DAA0A6", "#99B6D4", "#B8B66F"]

    var color: Color { Color(light: Self.lightHex[rawValue], dark: Self.darkHex[rawValue]) }

    static func color(forSource id: String) -> Color {
        assign([Breakdown(id: id, name: SourceCatalog.info(for: id).name, counts: TokenCounts())])[id]?.color ?? FieldCrop.wheat.color
    }

    static func colors(forModels ids: [String]) -> [String: Color] {
        assign(ids.map { Breakdown(id: $0, name: $0, counts: TokenCounts()) }).mapValues(\.color)
    }

    /// Token categories as grain tones, kept far enough apart to tell the five strata apart.
    static func color(for category: TokenCategory) -> Color {
        switch category {
        case .input: FieldCrop.pumpkin.color
        case .cacheRead: FieldCrop.wheat.color
        case .cacheWrite: FieldCrop.tea.color
        case .output: FieldCrop.flax.color
        case .reasoning: FieldCrop.lavender.color
        }
    }
}

/// Field period picker: serif labels with a hand-drawn furrow under the selected period.
struct FieldPeriodPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Period.allCases) { period in
                let selected = model.period == period
                Button {
                    model.period = period
                } label: {
                    Text(period.title)
                        .font(FieldFont.serif(15))
                        .foregroundStyle(selected ? FieldPalette.ink : FieldPalette.muted)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                        .padding(.bottom, 9)
                        .overlay(alignment: .bottom) {
                            FieldFurrow()
                                .stroke(FieldPalette.accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                                .frame(height: 5)
                                .padding(.horizontal, 5)
                                .opacity(selected ? 1 : 0)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(period.shortcutKey, modifiers: .command)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Usage period"))
    }
}

/// A slightly uneven pen line.
struct FieldFurrow: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY + 0.6))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.midY - 0.4),
                   control1: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.midY - 1.2),
                   control2: CGPoint(x: rect.minX + rect.width * 0.7, y: rect.midY + 1.4))
        return p
    }
}

// MARK: - Share card

/// Field share card: headline numbers on paper above the farm. Same data and toggles as the Liquid Glass card.
struct FieldShareCard: View {
    let data: ShareCardData
    let aspect: ShareAspect
    let showCost: Bool
    let showComposition: Bool
    var inscription = ""
    var signature = ""

    @Environment(\.colorScheme) private var scheme

    private var quote: String { inscription.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var signer: String { signature.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var items: [Breakdown] {
        if case .model = data.kind { return data.summary.byModel }
        return data.summary.bySource
    }

    private var focusID: String? {
        switch data.kind {
        case .overall: nil
        case .source(let id, _), .model(let id, _): id
        }
    }

    var body: some View {
        let size = aspect.canvasSize, portrait = aspect == .portrait, margin: CGFloat = portrait ? 80 : 90
        ZStack(alignment: .topLeading) {
            FieldPalette.paper
            if portrait {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    headline(numberSize: 168).padding(.top, 70)
                    facts(vertical: false).padding(.top, 40)
                    if !quote.isEmpty { inscriptionLine.padding(.top, 36) }
                    Spacer(minLength: 30)
                    field.frame(width: size.width - margin * 2)
                    if showComposition { composition.padding(.top, 34) }
                    Spacer(minLength: 30)
                    footer
                }
                .padding(margin)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    HStack(alignment: .top, spacing: 56) {
                        VStack(alignment: .leading, spacing: 0) {
                            headline(numberSize: 150)
                            facts(vertical: true).padding(.top, 40)
                            if !quote.isEmpty { inscriptionLine.padding(.top, 36) }
                        }
                        .frame(width: 560, alignment: .leading)
                        VStack(alignment: .leading, spacing: 26) {
                            field
                            if showComposition { composition }
                        }
                    }
                    .padding(.top, 60)
                    Spacer(minLength: 20)
                    footer
                }
                .padding(margin)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private var dateRange: String {
        let style = Date.FormatStyle.dateTime.year().month().day()
        let last = data.summary.end.addingTimeInterval(-1)
        let start = data.summary.start.formatted(style), end = last.formatted(style)
        return start == end ? start : "\(start) – \(end)"
    }

    private var header: some View {
        HStack(spacing: 22) {
            FieldAppIcon(isDark: scheme == .dark)
                .scaleEffect(84 / 512)
                .frame(width: 84, height: 84)
            Text(verbatim: "Token Taken").font(FieldFont.serif(36)).foregroundStyle(FieldPalette.ink)
            Spacer()
            Text(verbatim: dateRange).font(FieldFont.serif(28)).foregroundStyle(FieldPalette.muted)
        }
    }

    @ViewBuilder
    private func headline(numberSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                switch data.kind {
                case .overall: Text("All sources")
                case .source(_, let name), .model(_, let name): Text(verbatim: name)
                }
            }
            .font(FieldFont.serif(54))
            .foregroundStyle(FieldPalette.ink)
            .lineLimit(1)
            .truncationMode(.middle)
            Text(verbatim: TokenFormat.short(data.counts.total))
                .font(FieldFont.serif(numberSize))
                .foregroundStyle(FieldPalette.ink)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(verbatim: "Token").font(FieldFont.serif(32)).foregroundStyle(FieldPalette.muted)
                if showCost {
                    Text(verbatim: "· " + TokenFormat.usd(data.estimatedUSD)).font(FieldFont.serif(32)).foregroundStyle(FieldPalette.accent)
                    Text("estimate, not a bill").font(FieldFont.serif(28)).foregroundStyle(FieldPalette.accent)
                }
            }
        }
    }

    @ViewBuilder
    private func facts(vertical: Bool) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 26)) : AnyLayout(HStackLayout(alignment: .top, spacing: 48))
        layout {
            ForEach(data.supportingFacts) { fact in
                VStack(alignment: .leading, spacing: 6) {
                    Text(fact.label).font(FieldFont.serif(26)).foregroundStyle(FieldPalette.muted)
                    Text(verbatim: fact.value).font(FieldFont.serif(34)).foregroundStyle(FieldPalette.ink).lineLimit(1)
                }
            }
        }
    }

    private var field: some View {
        FieldLandscapeView(items: items, highlight: .constant(focusID), interactive: false)
    }

    private var composition: some View {
        let total = max(data.counts.total, 1)
        let parts = TokenCategory.allCases.map { ($0, data.counts[$0]) }.filter { $0.1 > 0 }
        return VStack(alignment: .leading, spacing: 14) {
            GeometryReader { proxy in
                HStack(spacing: 3) {
                    ForEach(parts, id: \.0) { category, value in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Palette.color(for: category))
                            .frame(width: max(2, (proxy.size.width - CGFloat(parts.count - 1) * 3) * CGFloat(value) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 18)
            HStack(spacing: 22) {
                ForEach(parts, id: \.0) { category, value in
                    HStack(spacing: 6) {
                        Text(category.title)
                        Text(verbatim: Share.percent(value, of: total))
                    }
                    .font(FieldFont.serif(22))
                    .foregroundStyle(FieldPalette.ink)
                    .lineLimit(1)
                }
            }
        }
    }

    private var inscriptionLine: some View {
        HStack(alignment: .top, spacing: 18) {
            Rectangle().fill(FieldPalette.accent).frame(width: 3)
            Text(verbatim: quote)
                .font(FieldFont.serif(34))
                .foregroundStyle(FieldPalette.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Rectangle().fill(FieldPalette.rule).frame(height: 2)
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                Text("Plot area and plant count follow tokens · read from local logs only")
                    .font(FieldFont.serif(24))
                    .foregroundStyle(FieldPalette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                if !signer.isEmpty {
                    Text(verbatim: "— " + signer)
                        .font(FieldFont.serif(28))
                        .foregroundStyle(FieldPalette.ink)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
        }
    }
}
