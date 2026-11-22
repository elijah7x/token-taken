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
    var horizontalPadding: CGFloat = 12
    var verticalPadding: CGFloat = 5

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(
            configuration: configuration,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding
        )
    }

    private struct StyledBody: View {
        let configuration: Configuration
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(configuration.isPressed && isEnabled ? FieldPalette.rule : FieldPalette.panel)
                )
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(FieldPalette.rule, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(isEnabled ? (configuration.isPressed ? 0.92 : 1) : 0.45)
        }
    }
}

struct CosmosButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(CosmosPalette.ink2)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Rectangle()
                        .fill(configuration.isPressed && isEnabled ? CosmosPalette.selection : CosmosPalette.background)
                )
                .overlay(Rectangle().stroke(CosmosPalette.controlRule, lineWidth: 1))
                .contentShape(Rectangle())
                .opacity(isEnabled ? (configuration.isPressed ? 0.92 : 1) : 0.45)
        }
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
    @FocusState private var focusedPeriod: Period?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Period.allCases) { period in
                let selected = model.period == period
                // Natural widths spread with flexible gaps, so long English titles never truncate
                // while the short Chinese titles still span the tray.
                if period != Period.allCases.first {
                    Spacer(minLength: 2)
                }
                Button {
                    model.period = period
                } label: {
                    Text(period.title)
                        .font(FieldFont.serif(15))
                        // English titles ("Month") must not wrap inside the narrow tray.
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(selected ? FieldPalette.ink : FieldPalette.muted)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                        .padding(.bottom, 9)
                        .fixedSize()
                        .overlay(alignment: .bottom) {
                            FieldFurrow()
                                .stroke(FieldPalette.accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                                .frame(height: 5)
                                .padding(.horizontal, 4)
                                .opacity(selected ? 1 : 0)
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
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Usage period"))
    }

    private func moveSelection(by offset: Int) {
        let periods = Period.allCases
        guard let index = periods.firstIndex(of: model.period) else { return }
        let newIndex = min(max(index + offset, 0), periods.count - 1)
        model.period = periods[newIndex]
        focusedPeriod = periods[newIndex]
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
    var dimension: BreakdownDimension = .sources
    var rank: Double? = nil
    var inscription = ""
    var signature = ""

    @Environment(\.locale) private var locale

    private var quote: String { inscription.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var signer: String { signature.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var sceneSummary: UsageSummary { data.cosmosSceneSummary }

    private var sceneDimension: BreakdownDimension {
        switch data.kind {
        case .overall: dimension
        case .source: .models
        case .model: .sources
        }
    }

    private var items: [Breakdown] {
        let raw = sceneDimension == .sources ? sceneSummary.bySource : sceneSummary.byModel
        return raw.filter { $0.counts.total > 0 }
    }

    var body: some View {
        let size = aspect.canvasSize
        ZStack(alignment: .topLeading) {
            FieldPalette.paper
            switch aspect {
            case .portrait:
                let margin: CGFloat = 80
                VStack(alignment: .leading, spacing: 0) {
                    header(logoSize: 84, titleSize: 36, periodSize: 28)
                    headline(numberSize: 168, portrait: true).padding(.top, 48)
                    facts(vertical: false, compact: false).padding(.top, 30)
                    if let rank { rankLine(rank, fontSize: 28).padding(.top, 24) }
                    if !quote.isEmpty { inscriptionLine(fontSize: 34).padding(.top, 24) }
                    Spacer(minLength: 16)
                    field.frame(width: size.width - margin * 2)
                    if showComposition { composition(compact: false).padding(.top, 24) }
                    Spacer(minLength: 16)
                    footer(compact: false)
                }
                .padding(margin)

            case .square:
                let margin: CGFloat = 60
                VStack(alignment: .leading, spacing: 0) {
                    header(logoSize: 56, titleSize: 30, periodSize: 24)

                    data.headlineText(locale: locale)
                        .font(FieldFont.serif(36))
                        .foregroundStyle(FieldPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .truncationMode(.middle)
                        .padding(.top, 18)

                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Text(verbatim: TokenFormat.short(data.counts.total))
                                    .font(FieldFont.serif(112))
                                    .foregroundStyle(FieldPalette.ink)
                                    .minimumScaleFactor(0.5)
                                    .lineLimit(1)
                                Text("Token")
                                    .font(FieldFont.serif(30))
                                    .foregroundStyle(FieldPalette.muted)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            if showCost {
                                costLine(amountSize: 26, noteSize: 22, unpricedSize: 20)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        facts(vertical: true, compact: true)
                            .frame(width: 390, alignment: .leading)
                            .padding(.top, 8)
                    }
                    .padding(.top, 4)

                    if let rank {
                        rankLine(rank, fontSize: 22).padding(.top, 10)
                    }
                    if !quote.isEmpty {
                        inscriptionLine(fontSize: 24).padding(.top, 10)
                    }

                    Spacer(minLength: 12)

                    field
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                    if showComposition {
                        composition(compact: true).padding(.top, 14)
                    }

                    footer(compact: true).padding(.top, 14)
                }
                .padding(margin)

            case .landscape:
                let margin: CGFloat = 80
                VStack(alignment: .leading, spacing: 0) {
                    header(logoSize: 84, titleSize: 36, periodSize: 28)
                    HStack(alignment: .top, spacing: 52) {
                        VStack(alignment: .leading, spacing: 0) {
                            headline(numberSize: 150, portrait: false)
                            facts(vertical: true, compact: false).padding(.top, 28)
                            if let rank { rankLine(rank, fontSize: 28).padding(.top, 22) }
                            if !quote.isEmpty { inscriptionLine(fontSize: 34).padding(.top, 24) }
                        }
                        .frame(width: 560, alignment: .leading)
                        VStack(alignment: .leading, spacing: 26) {
                            field
                            if showComposition { composition(compact: false) }
                        }
                    }
                    .padding(.top, 40)
                    Spacer(minLength: 16)
                    footer(compact: false)
                }
                .padding(margin)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func header(logoSize: CGFloat, titleSize: CGFloat, periodSize: CGFloat) -> some View {
        HStack(spacing: logoSize > 64 ? 22 : 16) {
            ShareBrandLogo(theme: .field, size: logoSize)
                .accessibilityHidden(true)
            Text(verbatim: "Token Taken").font(FieldFont.serif(titleSize)).foregroundStyle(FieldPalette.ink)
            Spacer()
            Text(data.periodDescription(locale: locale))
                .font(FieldFont.serif(periodSize))
                .foregroundStyle(FieldPalette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.80)
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
                Text("Token")
                    .font(FieldFont.serif(portrait ? 38 : 34))
                    .foregroundStyle(FieldPalette.muted)
                    .lineLimit(1)
                    .fixedSize()
            }
            if showCost {
                costLine(amountSize: 32, noteSize: 28, unpricedSize: 26)
            }
        }
    }

    @ViewBuilder
    private func costLine(amountSize: CGFloat, noteSize: CGFloat, unpricedSize: CGFloat) -> some View {
        if data.unpricedTokens > 0, data.unpricedTokens >= data.counts.total {
            Text("No prices for these models")
                .font(FieldFont.serif(noteSize))
                .foregroundStyle(FieldPalette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: TokenFormat.usd(data.estimatedUSD))
                    .font(FieldFont.serif(amountSize))
                    .foregroundStyle(FieldPalette.accent)
                Text("estimate, not a bill")
                    .font(FieldFont.serif(noteSize))
                    .foregroundStyle(FieldPalette.muted)
                if data.unpricedTokens > 0 {
                    Text(verbatim: "·")
                        .font(FieldFont.serif(unpricedSize))
                        .foregroundStyle(FieldPalette.muted)
                    Text("\(TokenFormat.short(data.unpricedTokens)) unpriced")
                        .font(FieldFont.serif(unpricedSize))
                        .foregroundStyle(FieldPalette.muted)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
    }

    private func factItem(_ fact: ShareCardData.SupportingFact, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            Text(fact.label)
                .font(FieldFont.serif(compact ? 21 : 26))
                .foregroundStyle(FieldPalette.muted)
                .lineLimit(1)
            Text(verbatim: fact.value)
                .font(FieldFont.serif(compact ? 27 : 34))
                .foregroundStyle(FieldPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func facts(vertical: Bool, compact: Bool) -> some View {
        let items = data.supportingFacts
        let rowSpacing: CGFloat = compact ? 14 : 22
        let colSpacing: CGFloat = compact ? 32 : 48
        if vertical {
            if items.count == 3 {
                VStack(alignment: .leading, spacing: rowSpacing) {
                    HStack(alignment: .top, spacing: colSpacing) {
                        factItem(items[0], compact: compact)
                        factItem(items[1], compact: compact)
                    }
                    factItem(items[2], compact: compact)
                }
            } else {
                VStack(alignment: .leading, spacing: rowSpacing) {
                    ForEach(items) { fact in
                        factItem(fact, compact: compact)
                    }
                }
            }
        } else {
            HStack(alignment: .top, spacing: colSpacing) {
                ForEach(items) { fact in
                    factItem(fact, compact: compact)
                        .layoutPriority(fact.isMonospacedValue ? 0 : 1)
                }
            }
        }
    }

    private func rankLine(_ rank: Double, fontSize: CGFloat) -> some View {
        Text("Last 30 days · about top \(UsageRank.formatted(rank))")
            .font(FieldFont.serif(fontSize))
            .foregroundStyle(FieldPalette.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var field: some View {
        FieldLandscapeView(items: items, highlight: .constant(nil), interactive: false)
    }

    private struct CompositionPart: Identifiable {
        let id: String
        let label: LocalizedStringKey
        let tokens: Int64
        let color: Color
    }

    @ViewBuilder
    private func composition(compact: Bool) -> some View {
        let total = data.counts.total
        let divisor = max(total, 1)
        let parts: [CompositionPart] = TokenCategory.allCases.compactMap { category in
            let value = data.counts[category]
            return value > 0
                ? CompositionPart(id: category.rawValue, label: category.title, tokens: value, color: FieldCrop.color(for: category))
                : nil
        } + (data.counts.uncategorized > 0
            ? [CompositionPart(id: "uncategorized", label: "Uncategorized", tokens: data.counts.uncategorized, color: FieldPalette.muted.opacity(0.45))]
            : [])
        let rows: [[CompositionPart]] = parts.count >= 4
            ? [
                Array(parts.prefix((parts.count + 1) / 2)),
                Array(parts.dropFirst((parts.count + 1) / 2)),
            ]
            : (parts.isEmpty ? [] : [parts])
        let barHeight: CGFloat = compact ? 14 : 18
        let swatchSize: CGFloat = compact ? 9.5 : 11
        let fontSize: CGFloat = compact ? 19.5 : 22

        if !parts.isEmpty {
            VStack(alignment: .leading, spacing: compact ? 10 : 14) {
                GeometryReader { proxy in
                    let gap: CGFloat = 3
                    let usable = max(0, proxy.size.width - CGFloat(max(0, parts.count - 1)) * gap)
                    HStack(spacing: gap) {
                        ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                            let isLast = index == parts.count - 1
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(part.color)
                                .frame(
                                    width: isLast ? nil : max(2, usable * CGFloat(part.tokens) / CGFloat(divisor)),
                                    height: barHeight
                                )
                                .frame(maxWidth: isLast ? .infinity : nil, alignment: .leading)
                        }
                    }
                    .frame(width: proxy.size.width, height: barHeight, alignment: .leading)
                    .background(FieldPalette.rule.opacity(0.35))
                    .clipShape(Capsule())
                }
                .frame(height: barHeight)

                VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: compact ? 14 : 18) {
                            ForEach(row) { part in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(part.color)
                                        .frame(width: swatchSize, height: swatchSize)
                                        .accessibilityHidden(true)
                                    Text(part.label)
                                    Text(verbatim: Share.percent(part.tokens, of: total))
                                }
                                .font(FieldFont.serif(fontSize))
                                .foregroundStyle(FieldPalette.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            }
                        }
                    }
                }
            }
        }
    }

    private func inscriptionLine(fontSize: CGFloat) -> some View {
        HStack(alignment: .top, spacing: fontSize > 28 ? 18 : 14) {
            Rectangle().fill(FieldPalette.accent).frame(width: 3)
            Text(verbatim: quote)
                .font(FieldFont.serif(fontSize))
                .foregroundStyle(FieldPalette.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func footer(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            Rectangle().fill(FieldPalette.rule).frame(height: 2)
            if rank != nil || !signer.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    if rank != nil {
                        Text("Rank is an estimate derived from public usage sources.")
                            .font(FieldFont.serif(compact ? 21 : 24))
                            .foregroundStyle(FieldPalette.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 0)
                    if !signer.isEmpty {
                        Text(verbatim: "— " + signer)
                            .font(FieldFont.serif(compact ? 24 : 28))
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
