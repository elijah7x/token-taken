import AppKit
import SwiftUI
import TokenTakenKit

/// The active theme for code that draws outside the SwiftUI environment (dynamic `NSColor` providers, glass helpers).
/// `AppSettings` keeps it in step with `theme` and bumps `formatRevision` so every scene rebuilds on a change.
enum ThemeRuntime {
    nonisolated(unsafe) static var isField = false
    nonisolated(unsafe) static var isCosmos = false
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

struct CosmosButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(CosmosPalette.ink2)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Rectangle()
                    .fill(configuration.isPressed ? CosmosPalette.selection : CosmosPalette.background)
            )
            .overlay(Rectangle().stroke(CosmosPalette.controlRule, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

extension View {
    @ViewBuilder
    func themedPlainButton() -> some View {
        if ThemeRuntime.isCosmos {
            buttonStyle(CosmosButtonStyle())
        } else {
            buttonStyle(.plain)
        }
    }
}

extension FieldCrop {
    private static let lightHex = ["#B98E34", "#8270A8", "#B9673A", "#4F7F80", "#557A41", "#A99B2E", "#6F8F4C", "#BB7C82", "#6B8DAF", "#8E8C47"]
    private static let darkHex = ["#D9B465", "#AA9BD1", "#DB8E62", "#7FB0B0", "#86AA6F", "#CFC261", "#9DBB78", "#DAA0A6", "#99B6D4", "#B8B66F"]

    /// The ten crop colours, resolved once: reads happen per row and per frame, and every call used to
    /// build a new dynamic `Color`.
    private static let palette: [FieldCrop: Color] = Dictionary(uniqueKeysWithValues: FieldCrop.allCases.map { crop in
        (crop, Color(light: lightHex[crop.rawValue], dark: darkHex[crop.rawValue]))
    })

    /// Source and model colours keep the crop assignment out of the render path the same way.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var sourceCache: [String: Color] = [:]
    nonisolated(unsafe) private static var modelCache: [String: [String: Color]] = [:]

    var color: Color { Self.palette[self] ?? Self.palette[.wheat] ?? .gray }

    static func color(forSource id: String) -> Color {
        cacheLock.lock()
        let cached = sourceCache[id]
        cacheLock.unlock()
        if let cached { return cached }
        let color = assign([Breakdown(id: id, name: SourceCatalog.info(for: id).name, counts: TokenCounts())])[id]?.color ?? FieldCrop.wheat.color
        cacheLock.lock()
        sourceCache[id] = color
        cacheLock.unlock()
        return color
    }

    /// Assigned jointly so models in one view avoid sharing a crop; cached per id list for that reason.
    static func colors(forModels ids: [String]) -> [String: Color] {
        let key = ids.joined(separator: "\u{1F}")
        cacheLock.lock()
        let cached = modelCache[key]
        cacheLock.unlock()
        if let cached { return cached }
        let colors = assign(ids.map { Breakdown(id: $0, name: $0, counts: TokenCounts()) }).mapValues(\.color)
        cacheLock.lock()
        modelCache[key] = colors
        cacheLock.unlock()
        return colors
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

struct CosmosPeriodPicker: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focusedPeriod: Period?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Usage period")
                .font(.system(size: 11))
                .tracking(0.8)
                .foregroundStyle(CosmosPalette.ink3)

            HStack(spacing: 0) {
                ForEach(Array(Period.allCases.enumerated()), id: \.element.id) { index, period in
                    let selected = model.period == period
                    Button {
                        model.period = period
                    } label: {
                        Text(period.title)
                            .font(.system(size: 11, weight: selected ? .medium : .regular))
                            .foregroundStyle(selected ? CosmosPalette.ink : CosmosPalette.ink3)
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(selected ? CosmosPalette.track : .clear)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(CosmosPalette.accent)
                                    .frame(height: 2)
                                    .opacity(selected ? 1 : 0)
                            }
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(CosmosPalette.rule)
                                    .frame(width: index == 0 ? 0 : 1)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(period.shortcutKey, modifiers: .command)
                    .focused($focusedPeriod, equals: period)
                    .onKeyPress(.leftArrow) {
                        moveSelection(by: -1)
                        return .handled
                    }
                    .onKeyPress(.rightArrow) {
                        moveSelection(by: 1)
                        return .handled
                    }
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .background(CosmosPalette.background)
            .overlay(Rectangle().strokeBorder(CosmosPalette.controlRule, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Usage period"))
        }
    }

    private func moveSelection(by offset: Int) {
        let periods = Period.allCases
        guard let index = periods.firstIndex(of: model.period) else { return }
        let newIndex = min(max(index + offset, 0), periods.count - 1)
        model.period = periods[newIndex]
        focusedPeriod = periods[newIndex]
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
    var rank: Double? = nil
    var inscription = ""
    var signature = ""

    @Environment(\.locale) private var locale

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
        let size = aspect.canvasSize, portrait = aspect == .portrait, margin: CGFloat = 80
        ZStack(alignment: .topLeading) {
            FieldPalette.paper
            if portrait {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    headline(numberSize: 168, portrait: true).padding(.top, 48)
                    facts(vertical: false).padding(.top, 30)
                    if let rank { rankLine(rank).padding(.top, 24) }
                    if !quote.isEmpty { inscriptionLine.padding(.top, 24) }
                    Spacer(minLength: 16)
                    field.frame(width: size.width - margin * 2)
                    if showComposition { composition.padding(.top, 24) }
                    Spacer(minLength: 16)
                    footer
                }
                .padding(margin)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    HStack(alignment: .top, spacing: 52) {
                        VStack(alignment: .leading, spacing: 0) {
                            headline(numberSize: 150, portrait: false)
                            facts(vertical: true).padding(.top, 28)
                            if let rank { rankLine(rank).padding(.top, 22) }
                            if !quote.isEmpty { inscriptionLine.padding(.top, 24) }
                        }
                        .frame(width: 560, alignment: .leading)
                        VStack(alignment: .leading, spacing: 26) {
                            field
                            if showComposition { composition }
                        }
                    }
                    .padding(.top, 40)
                    Spacer(minLength: 16)
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
            if let icon = ThemeAppIcon.image(for: .field) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 84, height: 84)
            }
            Text(verbatim: "Token Taken").font(FieldFont.serif(36)).foregroundStyle(FieldPalette.ink)
            Spacer()
            Text(verbatim: dateRange).font(FieldFont.serif(28)).foregroundStyle(FieldPalette.muted)
        }
    }

    @ViewBuilder
    private func headline(numberSize: CGFloat, portrait: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            data.headlineText(locale: locale)
                .font(FieldFont.serif(portrait ? 50 : 46))
                .foregroundStyle(FieldPalette.ink)
                .lineLimit(portrait ? 1 : 2)
                .minimumScaleFactor(0.7)
                .truncationMode(.middle)
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(verbatim: TokenFormat.short(data.counts.total))
                    .font(FieldFont.serif(numberSize))
                    .foregroundStyle(FieldPalette.ink)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(verbatim: "Token")
                    .font(FieldFont.serif(portrait ? 38 : 34))
                    .foregroundStyle(FieldPalette.muted)
                    .lineLimit(1)
                    .fixedSize()
            }
            if showCost {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: TokenFormat.usd(data.estimatedUSD)).font(FieldFont.serif(32)).foregroundStyle(FieldPalette.accent)
                    Text("estimate, not a bill").font(FieldFont.serif(28)).foregroundStyle(FieldPalette.accent)
                }
            }
        }
    }

    private func factItem(_ fact: ShareCardData.SupportingFact) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(fact.label)
                .font(FieldFont.serif(26))
                .foregroundStyle(FieldPalette.muted)
                .lineLimit(1)
            Text(verbatim: fact.value)
                .font(FieldFont.serif(34))
                .foregroundStyle(FieldPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func facts(vertical: Bool) -> some View {
        let items = data.supportingFacts
        if vertical {
            if items.count == 3 {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top, spacing: 48) {
                        factItem(items[0])
                        factItem(items[1])
                    }
                    factItem(items[2])
                }
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(items) { fact in
                        factItem(fact)
                    }
                }
            }
        } else {
            HStack(alignment: .top, spacing: 48) {
                ForEach(items) { fact in
                    factItem(fact)
                        .layoutPriority(fact.isMonospacedValue ? 0 : 1)
                }
            }
        }
    }

    private func rankLine(_ rank: Double) -> some View {
        Text("Last 30 days · about top \(UsageRank.formatted(rank))")
            .font(FieldFont.serif(28))
            .foregroundStyle(FieldPalette.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
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
            if rank != nil || !signer.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    if rank != nil {
                        Text("Rank is an estimate derived from public usage sources.")
                            .font(FieldFont.serif(24))
                            .foregroundStyle(FieldPalette.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 0)
                    if !signer.isEmpty {
                        Text(verbatim: "— " + signer)
                            .font(FieldFont.serif(28))
                            .foregroundStyle(FieldPalette.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .layoutPriority(1)
                    }
                }
            }
        }
    }
}
