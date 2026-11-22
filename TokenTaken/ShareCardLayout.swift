import AppKit
import SwiftUI
import TokenTakenKit

enum ShareCardDetail: String, CaseIterable, Identifiable {
    case top3
    case composition
    case none

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .top3: "Top 3"
        case .composition: "Composition"
        case .none: "None"
        }
    }
}

enum ShareCardMetrics {
    /// Minimum rendered point size after `minimumScaleFactor` at the 1080pt short-side canvas.
    static let minimumScaledPointSize: CGFloat = 22

    static func visualSize(for aspect: ShareAspect) -> CGSize {
        let canvas = aspect.canvasSize
        switch aspect {
        case .square:
            return CGSize(width: canvas.width, height: (canvas.height * 0.42).rounded())
        case .portrait:
            return CGSize(width: canvas.width, height: (canvas.height * 0.50).rounded())
        case .landscape:
            return CGSize(width: (canvas.width * 0.55).rounded(), height: canvas.height)
        }
    }

    static func infoSize(for aspect: ShareAspect) -> CGSize {
        let canvas = aspect.canvasSize
        let visual = visualSize(for: aspect)
        switch aspect {
        case .square, .portrait:
            return CGSize(width: canvas.width, height: canvas.height - visual.height)
        case .landscape:
            return CGSize(width: canvas.width - visual.width, height: canvas.height)
        }
    }

    static func padding(for aspect: ShareAspect) -> CGFloat {
        switch aspect {
        case .square: 52
        case .portrait, .landscape: 64
        }
    }

    /// Guarantees `minimumScaleFactor` never scales a text element below `minimumScaledPointSize` (22pt).
    static func safeScaleFactor(for size: CGFloat, preferred: CGFloat = 0.75) -> CGFloat {
        let floorFactor = min(1, minimumScaledPointSize / max(1, size))
        return min(1, max(preferred, floorFactor))
    }
}

struct ShareCardTypography {
    let headerBrand: CGFloat
    let headerPeriod: CGFloat
    let heroNumber: CGFloat
    let heroUnit: CGFloat
    let cost: CGFloat
    let l2: CGFloat
    let l3Row: CGFloat
    let legend: CGFloat
    let inscription: CGFloat
    let logoSize: CGFloat

    init(aspect: ShareAspect) {
        switch aspect {
        case .square:
            headerBrand = 28
            headerPeriod = 24
            heroNumber = 104
            heroUnit = 30
            cost = 28
            l2 = 26
            l3Row = 26
            legend = 24
            inscription = 26
            logoSize = 40
        case .landscape:
            headerBrand = 32
            headerPeriod = 26
            heroNumber = 132
            heroUnit = 34
            cost = 32
            l2 = 28
            l3Row = 28
            legend = 24
            inscription = 30
            logoSize = 44
        case .portrait:
            headerBrand = 32
            headerPeriod = 28
            heroNumber = 144
            heroUnit = 36
            cost = 34
            l2 = 28
            l3Row = 28
            legend = 24
            inscription = 32
            logoSize = 44
        }
    }
}

struct ShareCardSkin<Visual: View> {
    let theme: AppTheme
    let pageColor: Color
    let panelColor: Color
    let ink1: Color
    let ink2: Color
    let ink3: Color
    let accent: Color
    let rule: Color
    let barTrack: Color
    let categoryOrder: [TokenCategory]
    let categoryColors: [TokenCategory: Color]
    let uncategorizedColor: Color
    let cornerRadius: CGFloat
    let showsSeriesSwatches: Bool
    let fullBleedVisual: Bool
    let usesLiquidAtmosphere: Bool
    let visual: @MainActor () -> Visual

    init(
        theme: AppTheme,
        pageColor: Color,
        panelColor: Color,
        ink1: Color,
        ink2: Color,
        ink3: Color,
        accent: Color,
        rule: Color,
        barTrack: Color,
        categoryOrder: [TokenCategory] = TokenCategory.allCases,
        categoryColors: [TokenCategory: Color],
        uncategorizedColor: Color,
        cornerRadius: CGFloat,
        showsSeriesSwatches: Bool = true,
        fullBleedVisual: Bool = false,
        usesLiquidAtmosphere: Bool = false,
        @ViewBuilder visual: @escaping @MainActor () -> Visual
    ) {
        self.theme = theme
        self.pageColor = pageColor
        self.panelColor = panelColor
        self.ink1 = ink1
        self.ink2 = ink2
        self.ink3 = ink3
        self.accent = accent
        self.rule = rule
        self.barTrack = barTrack
        self.categoryOrder = categoryOrder
        self.categoryColors = categoryColors
        self.uncategorizedColor = uncategorizedColor
        self.cornerRadius = cornerRadius
        self.showsSeriesSwatches = showsSeriesSwatches
        self.fullBleedVisual = fullBleedVisual
        self.usesLiquidAtmosphere = usesLiquidAtmosphere
        self.visual = visual
    }
}

@MainActor
struct ShareCardLayout<Visual: View>: View {
    let data: ShareCardData
    let aspect: ShareAspect
    let dimension: BreakdownDimension
    let detail: ShareCardDetail
    let showCost: Bool
    let rank: Double?
    let inscription: String
    let signature: String
    let dataUnavailable: Bool
    let reduceTransparency: Bool
    let skin: ShareCardSkin<Visual>

    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var scheme

    private var type: ShareCardTypography { ShareCardTypography(aspect: aspect) }
    private var canvasSize: CGSize { aspect.canvasSize }
    private var visualSize: CGSize { ShareCardMetrics.visualSize(for: aspect) }
    private var infoSize: CGSize { ShareCardMetrics.infoSize(for: aspect) }
    private var pad: CGFloat { ShareCardMetrics.padding(for: aspect) }

    private var detailDimension: BreakdownDimension {
        data.detailDimension(for: dimension)
    }

    private var rankedItems: [Breakdown] {
        data.rankedItems(dimension: dimension)
    }

    private var formattedFieldQuote: String? {
        guard ThemeKind.current == .field else { return nil }
        let quote = inscription.trimmingCharacters(in: .whitespacesAndNewlines)
        let signer = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (quote.isEmpty, signer.isEmpty) {
        case (true, true): return nil
        case (false, true): return quote
        case (true, false): return "— \(signer)"
        case (false, false): return "\(quote) — \(signer)"
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            cardBackdrop

            if aspect == .landscape {
                HStack(spacing: 0) {
                    visualSlot
                        .frame(width: visualSize.width, height: visualSize.height)
                    infoPanel
                        .frame(width: infoSize.width, height: infoSize.height, alignment: .topLeading)
                }
            } else {
                VStack(spacing: 0) {
                    visualSlot
                        .frame(width: visualSize.width, height: visualSize.height)
                    infoPanel
                        .frame(width: infoSize.width, height: infoSize.height, alignment: .topLeading)
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    @ViewBuilder
    private var cardBackdrop: some View {
        if skin.usesLiquidAtmosphere {
            ShareLiquidCardBackdrop(
                accentColor: data.accentColor,
                hasUsage: data.counts.total > 0,
                visualRect: CGRect(origin: .zero, size: visualSize),
                isDark: scheme == .dark,
                reduceTransparency: reduceTransparency
            )
        } else {
            skin.pageColor
        }
    }

    @ViewBuilder
    private var visualSlot: some View {
        if skin.fullBleedVisual {
            skin.visual()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            skin.visual()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, pad)
                .padding(.trailing, aspect == .landscape ? 0 : pad)
                .padding(.top, pad)
                .padding(.bottom, aspect == .landscape ? pad : 0)
        }
    }

    private var infoPanel: some View {
        let topPad: CGFloat = if skin.fullBleedVisual || aspect == .landscape {
            pad
        } else {
            aspect == .square ? 32 : 44
        }
        let leadingPad: CGFloat = (!skin.fullBleedVisual && aspect == .landscape) ? 52 : pad

        return VStack(alignment: .leading, spacing: 0) {
            header

            heroSection
                .padding(.top, aspect == .square ? 18 : (aspect == .landscape ? 32 : 28))

            contextSection
                .padding(.top, aspect == .square ? 12 : 18)

            if let quote = formattedFieldQuote {
                quoteLine(quote)
                    .padding(.top, aspect == .square ? 10 : 16)
            }

            if detail != .none {
                Spacer(minLength: aspect == .square ? 12 : 20)

                Rectangle()
                    .fill(skin.rule)
                    .frame(height: 1)

                detailSection
                    .padding(.top, aspect == .square ? 14 : 20)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.top, topPad)
        .padding(.bottom, pad)
        .padding(.leading, leadingPad)
        .padding(.trailing, pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(skin.fullBleedVisual ? skin.panelColor : Color.clear)
        .overlay(alignment: aspect == .landscape ? .leading : .top) {
            if skin.fullBleedVisual {
                Rectangle()
                    .fill(skin.rule)
                    .frame(
                        width: aspect == .landscape ? 1 : nil,
                        height: aspect == .landscape ? nil : 1
                    )
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if aspect == .landscape {
            VStack(alignment: .leading, spacing: 8) {
                brandMark
                periodLabel
            }
        } else {
            HStack(alignment: .center, spacing: 16) {
                brandMark
                Spacer(minLength: 16)
                periodLabel
            }
        }
    }

    private var brandMark: some View {
        HStack(alignment: .center, spacing: aspect == .square ? 10 : 12) {
            ShareBrandLogo(theme: skin.theme, size: type.logoSize)
                .accessibilityHidden(true)

            Text(verbatim: "Token Taken")
                .font(ThemeFont.make(type.headerBrand, weight: .semibold))
                .tracking(skin.theme == .cosmos ? 0 : -0.3)
                .foregroundStyle(skin.ink1)
                .lineLimit(1)
                .minimumScaleFactor(ShareCardMetrics.safeScaleFactor(for: type.headerBrand, preferred: 0.80))
        }
    }

    private var periodLabel: some View {
        Text(data.periodDescription(locale: locale))
            .font(ThemeFont.make(type.headerPeriod, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(skin.ink2)
            .lineLimit(1)
            .minimumScaleFactor(ShareCardMetrics.safeScaleFactor(for: type.headerPeriod, preferred: 0.85))
    }

    // MARK: - L1 Hero

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: aspect == .square ? 6 : 10) {
            HStack(alignment: .firstTextBaseline, spacing: aspect == .square ? 12 : 16) {
                Text(verbatim: TokenFormat.short(data.counts.total))
                    .font(ThemeFont.make(type.heroNumber, weight: .bold, numeric: true))
                    .tracking(skin.theme == .cosmos ? 0 : (aspect == .square ? -2.5 : -3.5))
                    .foregroundStyle(skin.ink1)
                    .lineLimit(1)
                    .minimumScaleFactor(ShareCardMetrics.safeScaleFactor(for: type.heroNumber, preferred: 0.60))

                Text("Token")
                    .font(ThemeFont.make(type.heroUnit, weight: .medium))
                    .foregroundStyle(skin.ink2)
                    .lineLimit(1)
                    .fixedSize()
            }

            if showCost {
                costLine
            }
        }
    }

    @ViewBuilder
    private var costLine: some View {
        if data.unpricedTokens > 0, data.unpricedTokens >= data.counts.total {
            Text("No prices for these models")
                .font(ThemeFont.make(type.cost, weight: .medium))
                .foregroundStyle(skin.ink2)
                .lineLimit(1)
                .minimumScaleFactor(ShareCardMetrics.safeScaleFactor(for: type.cost, preferred: 0.80))
        } else {
            costSummaryText
                .lineLimit(1)
                .minimumScaleFactor(ShareCardMetrics.safeScaleFactor(for: type.cost, preferred: 0.72))
        }
    }

    private var costSummaryText: Text {
        let amount = Text(verbatim: TokenFormat.usd(data.estimatedUSD))
            .font(ThemeFont.make(type.cost, weight: .semibold, numeric: true))
            .foregroundStyle(skin.accent)
        let space = Text(verbatim: " ")
        let disclaimer = Text("estimate, not a bill")
            .font(ThemeFont.make(type.cost, weight: .regular))
            .foregroundStyle(skin.ink2)
        if data.unpricedTokens > 0 {
            let dot = Text(verbatim: " · ")
                .font(ThemeFont.make(type.cost, weight: .regular))
                .foregroundStyle(skin.ink3)
            let unpriced = Text("\(TokenFormat.short(data.unpricedTokens)) unpriced")
                .font(ThemeFont.make(type.cost, weight: .regular, numeric: true))
                .foregroundStyle(skin.ink3)
            return amount + space + disclaimer + dot + unpriced
        }
        return amount + space + disclaimer
    }

    // MARK: - L2 Context

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: aspect == .square ? 6 : 8) {
            contextLine

            if let rank {
                Text("Last 30 days · about top \(UsageRank.formatted(rank)) (estimate)")
                    .font(ThemeFont.make(type.l2, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(skin.ink3)
                    .lineLimit(1)
                    .minimumScaleFactor(ShareCardMetrics.safeScaleFactor(for: type.l2, preferred: 0.80))
            }
        }
    }

    @ViewBuilder
    private var contextLine: some View {
        switch data.kind {
        case .overall:
            Text(verbatim: data.overallContextText(locale: locale))
                .font(ThemeFont.make(type.l2, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(skin.ink2)
                .lineLimit(1)
                .minimumScaleFactor(ShareCardMetrics.safeScaleFactor(for: type.l2, preferred: 0.80))

        case .source(_, let name):
            scopedContextLine(name: name, isModel: false)

        case .model(let id, let name):
            scopedContextLine(name: name.isEmpty ? id : name, isModel: true)
        }
    }

    private func scopedContextLine(name: String, isModel: Bool) -> some View {
        let shareText = data.scopedShareDescription(locale: locale)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: name)
                .font(ThemeFont.make(type.l2, weight: .semibold, numeric: isModel && skin.theme == .cosmos))
                .foregroundStyle(skin.ink1)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(ShareCardMetrics.safeScaleFactor(for: type.l2, preferred: 0.82))

            Text(verbatim: " · \(shareText)")
                .font(ThemeFont.make(type.l2, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(skin.ink2)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    // MARK: - Field Quote Line

    private func quoteLine(_ text: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Rectangle()
                .fill(skin.accent)
                .frame(width: 3, height: type.inscription)
                .accessibilityHidden(true)

            Text(verbatim: text)
                .font(ThemeFont.make(type.inscription, weight: .regular))
                .foregroundStyle(skin.ink1)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(ShareCardMetrics.safeScaleFactor(for: type.inscription, preferred: 0.78))
        }
    }

    // MARK: - L3 Detail

    @ViewBuilder
    private var detailSection: some View {
        switch detail {
        case .top3:
            top3Section
        case .composition:
            compositionSection
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var top3Section: some View {
        let items = Array(rankedItems.prefix(3))
        if dataUnavailable || (items.isEmpty && data.isPartialScope && data.counts.total > 0) {
            unavailablePanel
        } else if items.isEmpty {
            Text("No usage in this period")
                .font(ThemeFont.make(type.l3Row, weight: .regular))
                .foregroundStyle(skin.ink3)
                .lineLimit(1)
                .minimumScaleFactor(ShareCardMetrics.safeScaleFactor(for: type.l3Row, preferred: 0.85))
        } else {
            let denominator = data.counts.total
            let modelColorMap = detailDimension == .models
                ? Palette.modelColors(for: data.summary.byModel.map(\.id) + items.map(\.id))
                : [:]

            VStack(alignment: .leading, spacing: aspect == .square ? 12 : 16) {
                ForEach(items) { item in
                    let swatchColor: Color = detailDimension == .sources
                        ? Palette.color(forSource: item.id)
                        : (modelColorMap[item.id] ?? Palette.color(for: .output))

                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        if skin.showsSeriesSwatches {
                            Circle()
                                .fill(swatchColor)
                                .frame(width: 12, height: 12)
                                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + type.l3Row * 0.24 }
                                .accessibilityHidden(true)
                        }

                        Text(verbatim: item.name)
                            .font(ThemeFont.make(type.l3Row, weight: .medium, numeric: detailDimension == .models && skin.theme == .cosmos))
                            .foregroundStyle(skin.ink1)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .minimumScaleFactor(ShareCardMetrics.safeScaleFactor(for: type.l3Row, preferred: 0.85))

                        Spacer(minLength: 16)

                        Text(verbatim: "\(Share.percent(item.counts.total, of: denominator, locale: locale)) · \(TokenFormat.short(item.counts.total))")
                            .font(ThemeFont.make(type.l3Row, weight: .regular, numeric: true))
                            .foregroundStyle(skin.ink2)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
    }

    private struct CompositionPart: Identifiable {
        let id: String
        let label: LocalizedStringKey
        let tokens: Int64
        let color: Color
    }

    private var compositionParts: [CompositionPart] {
        var parts = skin.categoryOrder.compactMap { category -> CompositionPart? in
            let value = data.counts[category]
            guard value > 0 else { return nil }
            return CompositionPart(
                id: category.rawValue,
                label: category.title,
                tokens: value,
                color: skin.categoryColors[category] ?? skin.accent
            )
        }
        if data.counts.uncategorized > 0 {
            parts.append(CompositionPart(
                id: "uncategorized",
                label: "Uncategorized",
                tokens: data.counts.uncategorized,
                color: skin.uncategorizedColor
            ))
        }
        return parts
    }

    @ViewBuilder
    private var compositionSection: some View {
        let parts = compositionParts
        if dataUnavailable {
            unavailablePanel
        } else if parts.isEmpty {
            Text("No usage in this period")
                .font(ThemeFont.make(type.l3Row, weight: .regular))
                .foregroundStyle(skin.ink3)
                .lineLimit(1)
                .minimumScaleFactor(ShareCardMetrics.safeScaleFactor(for: type.l3Row, preferred: 0.85))
        } else {
            let total = data.counts.total
            let divisor = max(Int64(1), total)
            let barHeight: CGFloat = aspect == .square ? 14 : 16
            let barRadius: CGFloat = skin.cornerRadius == 0 ? 0 : barHeight * 0.5
            let segmentRadius: CGFloat = skin.cornerRadius == 0 ? 0 : 3
            let perRow = aspect == .landscape ? 2 : 3
            let rows = stride(from: 0, to: parts.count, by: perRow).map { start in
                Array(parts[start..<min(start + perRow, parts.count)])
            }

            let barTrackColor = skin.barTrack
            VStack(alignment: .leading, spacing: aspect == .square ? 14 : 16) {
                Canvas { context, size in
                    let fullRect = CGRect(origin: .zero, size: size)
                    let trackPath = Path(roundedRect: fullRect, cornerRadius: barRadius, style: .continuous)
                    context.fill(trackPath, with: .color(barTrackColor))

                    context.drawLayer { layer in
                        layer.clip(to: trackPath)
                        let gap: CGFloat = 3
                        let totalGaps = CGFloat(max(0, parts.count - 1)) * gap
                        let usable = max(0, size.width - totalGaps)
                        var cursorX: CGFloat = 0

                        for (idx, part) in parts.enumerated() {
                            let rawW = usable * CGFloat(part.tokens) / CGFloat(divisor)
                            let w = idx == parts.count - 1
                                ? max(2, size.width - cursorX)
                                : max(2, rawW)
                            let segRect = CGRect(x: cursorX, y: 0, width: w, height: size.height)
                            layer.fill(
                                Path(roundedRect: segRect, cornerRadius: segmentRadius, style: .continuous),
                                with: .color(part.color)
                            )
                            cursorX += w + gap
                        }
                    }
                }
                .frame(height: barHeight)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: aspect == .square ? 8 : 10) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: aspect == .landscape ? 20 : 24) {
                            ForEach(row) { part in
                                HStack(spacing: 8) {
                                    if skin.cornerRadius == 0 {
                                        Rectangle()
                                            .fill(part.color)
                                            .frame(width: 11, height: 11)
                                            .accessibilityHidden(true)
                                    } else {
                                        Circle()
                                            .fill(part.color)
                                            .frame(width: 11, height: 11)
                                            .accessibilityHidden(true)
                                    }

                                    Text(part.label)
                                        .font(ThemeFont.make(type.legend, weight: .regular))
                                        .foregroundStyle(skin.ink2)

                                    Text(verbatim: Share.percent(part.tokens, of: total, locale: locale))
                                        .font(ThemeFont.make(type.legend, weight: .semibold, numeric: true))
                                        .foregroundStyle(skin.ink1)
                                }
                                .lineLimit(1)
                                .minimumScaleFactor(ShareCardMetrics.safeScaleFactor(for: type.legend, preferred: 0.92))
                            }
                        }
                    }
                }
            }
        }
    }

    private var unavailablePanel: some View {
        let shape = RoundedRectangle(cornerRadius: skin.cornerRadius, style: .continuous)
        return Text("Breakdown unavailable")
            .font(ThemeFont.make(type.l3Row, weight: .medium))
            .foregroundStyle(skin.ink3)
            .lineLimit(1)
            .minimumScaleFactor(ShareCardMetrics.safeScaleFactor(for: type.l3Row, preferred: 0.85))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, aspect == .square ? 22 : 28)
            .padding(.horizontal, 20)
            .background(shape.fill(skin.panelColor))
            .overlay(shape.strokeBorder(skin.rule, lineWidth: 1))
    }
}

// MARK: - Liquid Glass Confluence Vessel Visual

private struct TideVesselVisualLayout {
    struct Band: Identifiable {
        let id: String
        let stratum: ShareCardData.Stratum
        let minY: CGFloat
        let maxY: CGFloat
        let inlineMidY: CGFloat?
        let nameFontSize: CGFloat
        let valueFontSize: CGFloat
    }

    let vesselRect: CGRect
    let cornerRadius: CGFloat
    let innerRect: CGRect
    let fillLevel: Double
    let layers: [LiquidGlassVessel.Layer]
    let brimY: CGFloat
    let strataTotalTokens: Int64
    let bands: [Band]

    private static let inlineMinLayerHeight: CGFloat = 48
    private static let minLabelSize: CGFloat = 24

    init(rect: CGRect, data: ShareCardData, dimension: BreakdownDimension) {
        self.vesselRect = rect
        let radius = min(40, min(rect.width, rect.height) * 0.14)
        self.cornerRadius = radius

        let effectiveFill: Double
        if data.counts.total <= 0 {
            effectiveFill = 0
        } else if data.isPartialScope {
            effectiveFill = min(1, max(0.035, data.periodShareRatio))
        } else {
            effectiveFill = 1.0
        }
        self.fillLevel = effectiveFill

        let rawItems = data.unmergedStrata(dimension: dimension)
        let rawSum = rawItems.reduce(Int64(0)) { $0 + $1.tokens }
        self.strataTotalTokens = max(rawSum, data.counts.total)

        let baseMetrics = LiquidGlassVessel.metrics(
            for: rect,
            cornerRadius: radius,
            layers: effectiveFill > 0
                ? [LiquidGlassVessel.Layer(color: data.accentColor, fraction: effectiveFill)]
                : [],
            fillLevel: effectiveFill
        )
        let liquidTotalHeight = max(0, baseMetrics.innerRect.maxY - baseMetrics.meniscusCenterY)

        // Merge strata shorter than 48pt into a single "Other N" layer so every visible label stays >= 24pt.
        let resolvedStrata: [ShareCardData.Stratum]
        if effectiveFill > 0, !rawItems.isEmpty, rawSum > 0, liquidTotalHeight > 0 {
            var tall: [ShareCardData.Stratum] = []
            var thin: [ShareCardData.Stratum] = []
            for item in rawItems {
                let proposedHeight = liquidTotalHeight * CGFloat(item.tokens) / CGFloat(rawSum)
                if proposedHeight >= Self.inlineMinLayerHeight {
                    tall.append(item)
                } else {
                    thin.append(item)
                }
            }
            if thin.count >= 2 {
                let mergedTokens = thin.reduce(Int64(0)) { $0 + $1.tokens }
                var combined = tall
                if mergedTokens > 0 {
                    combined.append(ShareCardData.Stratum(
                        id: "others",
                        label: .localized("Other \(thin.count)"),
                        tokens: mergedTokens,
                        color: ShareCardData.mergedStratumColor
                    ))
                }
                resolvedStrata = combined
            } else {
                resolvedStrata = rawItems
            }
        } else {
            resolvedStrata = rawItems
        }

        let sum = resolvedStrata.reduce(Int64(0)) { $0 + $1.tokens }
        let computedLayers: [LiquidGlassVessel.Layer]
        if effectiveFill <= 0 {
            computedLayers = []
        } else if !resolvedStrata.isEmpty, sum > 0 {
            computedLayers = resolvedStrata.map { item in
                LiquidGlassVessel.Layer(
                    color: item.color,
                    fraction: (Double(item.tokens) / Double(sum)) * effectiveFill
                )
            }
        } else {
            computedLayers = [LiquidGlassVessel.Layer(color: data.accentColor, fraction: effectiveFill)]
        }
        self.layers = computedLayers

        let finalMetrics = LiquidGlassVessel.metrics(
            for: rect,
            cornerRadius: radius,
            layers: computedLayers,
            fillLevel: effectiveFill
        )
        self.innerRect = finalMetrics.innerRect
        self.brimY = finalMetrics.brimCenterY

        guard effectiveFill > 0, !resolvedStrata.isEmpty, sum > 0 else {
            self.bands = []
            return
        }

        let maxNameSize: CGFloat = 30
        var computedBands: [Band] = []
        computedBands.reserveCapacity(resolvedStrata.count)

        for (index, item) in resolvedStrata.enumerated() {
            let range = index < finalMetrics.layerRanges.count
                ? finalMetrics.layerRanges[index]
                : finalMetrics.meniscusCenterY...finalMetrics.meniscusCenterY
            let bandMinY = range.lowerBound
            let bandMaxY = range.upperBound
            let bandHeight = bandMaxY - bandMinY

            let inlineMidY: CGFloat?
            let nameSize: CGFloat
            let valueSize: CGFloat

            if bandHeight >= Self.inlineMinLayerHeight {
                if index == resolvedStrata.count - 1 {
                    let topClear = min(
                        finalMetrics.meniscusHeight * 0.24,
                        max(0, bandHeight - 36) * 0.45
                    )
                    inlineMidY = (bandMinY + topClear + bandMaxY) * 0.5
                } else {
                    inlineMidY = (bandMinY + bandMaxY) * 0.5
                }

                if bandHeight >= 92 {
                    nameSize = maxNameSize
                } else {
                    let t = min(max((bandHeight - Self.inlineMinLayerHeight) / 44, 0), 1)
                    nameSize = (Self.minLabelSize + t * (maxNameSize - Self.minLabelSize)).rounded()
                }
                valueSize = max(Self.minLabelSize, nameSize - 2)
            } else {
                inlineMidY = nil
                nameSize = Self.minLabelSize
                valueSize = Self.minLabelSize
            }

            computedBands.append(Band(
                id: item.id,
                stratum: item,
                minY: bandMinY,
                maxY: bandMaxY,
                inlineMidY: inlineMidY,
                nameFontSize: nameSize,
                valueFontSize: valueSize
            ))
        }

        self.bands = computedBands
    }
}

struct ShareTideVesselVisual: View {
    let data: ShareCardData
    let dimension: BreakdownDimension
    let isDark: Bool
    let reduceTransparency: Bool
    let increasedContrast: Bool

    @Environment(\.locale) private var locale

    var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            let layout = TideVesselVisualLayout(rect: rect, data: data, dimension: dimension)
            let inlineInsetX: CGFloat = 28
            let inlineWidth = max(120, layout.innerRect.width - inlineInsetX * 2)

            let isPartialScope = data.isPartialScope

            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    LiquidGlassVessel.draw(
                        in: &context,
                        rect: layout.vesselRect,
                        cornerRadius: layout.cornerRadius,
                        layers: layout.layers,
                        fillLevel: layout.fillLevel,
                        isDark: isDark,
                        reduceTransparency: reduceTransparency,
                        increasedContrast: increasedContrast
                    )

                    if isPartialScope {
                        var brimPath = Path()
                        brimPath.move(to: CGPoint(x: layout.innerRect.minX + 18, y: layout.brimY))
                        brimPath.addLine(to: CGPoint(x: layout.innerRect.maxX - 18, y: layout.brimY))
                        context.stroke(
                            brimPath,
                            with: .color(Palette.ink2.opacity(isDark ? 0.44 : 0.38)),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [8, 13])
                        )
                    }
                }

                ForEach(layout.bands) { band in
                    if let midY = band.inlineMidY {
                        let rowHeight = max(32, min(44, band.maxY - band.minY - 4))
                        HStack(alignment: .firstTextBaseline, spacing: 18) {
                            stratumNameText(band.stratum.label, size: band.nameFontSize)
                                .foregroundStyle(Color.white)
                                .lineLimit(1)
                                .minimumScaleFactor(ShareCardMetrics.safeScaleFactor(for: band.nameFontSize, preferred: 0.85))
                                .truncationMode(.middle)

                            Spacer(minLength: 14)

                            Text(verbatim: "\(Share.percent(band.stratum.tokens, of: layout.strataTotalTokens, locale: locale)) · \(TokenFormat.short(band.stratum.tokens))")
                                .font(ThemeFont.make(band.valueFontSize, weight: .semibold, numeric: true))
                                .foregroundStyle(Color.white.opacity(0.95))
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .shadow(color: .black.opacity(reduceTransparency ? 0 : 0.34), radius: 5, x: 0, y: 1.5)
                        .frame(width: inlineWidth, height: rowHeight, alignment: .center)
                        .offset(x: layout.innerRect.minX + inlineInsetX, y: midY - rowHeight / 2)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func stratumNameText(_ label: ShareCardData.Stratum.Label, size: CGFloat) -> some View {
        let clampedSize = max(24, size)
        switch label {
        case .verbatim(let text, let monospaced):
            Text(verbatim: text)
                .font(monospaced
                    ? .system(size: clampedSize, weight: .semibold, design: .monospaced)
                    : ThemeFont.make(clampedSize, weight: .semibold))
        case .localized(let key):
            Text(key)
                .font(ThemeFont.make(clampedSize, weight: .semibold))
        }
    }
}

// MARK: - Liquid Glass Card Backdrop

struct ShareLiquidCardBackdrop: View {
    let accentColor: Color
    let hasUsage: Bool
    let visualRect: CGRect
    let isDark: Bool
    let reduceTransparency: Bool

    var body: some View {
        Canvas { context, size in
            let fullRect = CGRect(origin: .zero, size: size)

            if reduceTransparency {
                context.fill(Path(fullRect), with: .color(Palette.solid))
                let rimRect = fullRect.insetBy(dx: 1, dy: 1)
                context.stroke(Path(rimRect), with: .color(Palette.hairline), lineWidth: 2)
                return
            }

            let topBase = isDark ? Color(hex: "#1B212C") : Color(hex: "#F7F4F0")
            let bottomBase = isDark ? Color(hex: "#121722") : Color(hex: "#EEF2F8")
            context.fill(
                Path(fullRect),
                with: .linearGradient(
                    Gradient(colors: [topBase, bottomBase]),
                    startPoint: CGPoint(x: size.width / 2, y: 0),
                    endPoint: CGPoint(x: size.width / 2, y: size.height)
                )
            )

            let glowSpan = max(size.width, size.height)
            let warmGlow = isDark
                ? Color(.sRGB, red: 200 / 255, green: 122 / 255, blue: 82 / 255, opacity: 0.34)
                : Color(.sRGB, red: 255 / 255, green: 205 / 255, blue: 172 / 255, opacity: 0.68)
            let coolGlow = isDark
                ? Color(.sRGB, red: 72 / 255, green: 112 / 255, blue: 192 / 255, opacity: 0.40)
                : Color(.sRGB, red: 172 / 255, green: 203 / 255, blue: 248 / 255, opacity: 0.72)
            let depthGlow = isDark
                ? Color(.sRGB, red: 96 / 255, green: 84 / 255, blue: 168 / 255, opacity: 0.28)
                : Color(.sRGB, red: 204 / 255, green: 216 / 255, blue: 246 / 255, opacity: 0.78)

            context.fill(
                Path(fullRect),
                with: .radialGradient(
                    Gradient(colors: [warmGlow, .clear]),
                    center: CGPoint(x: size.width * 0.10, y: size.height * 0.06),
                    startRadius: 0,
                    endRadius: glowSpan * 0.58
                )
            )
            context.fill(
                Path(fullRect),
                with: .radialGradient(
                    Gradient(colors: [coolGlow, .clear]),
                    center: CGPoint(x: size.width * 0.96, y: size.height * 0.32),
                    startRadius: 0,
                    endRadius: glowSpan * 0.62
                )
            )
            context.fill(
                Path(fullRect),
                with: .radialGradient(
                    Gradient(colors: [depthGlow, .clear]),
                    center: CGPoint(x: size.width * 0.42, y: size.height * 1.06),
                    startRadius: 0,
                    endRadius: glowSpan * 0.64
                )
            )

            if hasUsage {
                let bloomCenter = CGPoint(x: visualRect.midX, y: visualRect.midY)
                let bloomRadius = max(visualRect.width, visualRect.height) * 0.65
                context.fill(
                    Path(fullRect),
                    with: .radialGradient(
                        Gradient(colors: [
                            accentColor.opacity(isDark ? 0.16 : 0.18),
                            .clear,
                        ]),
                        center: bloomCenter,
                        startRadius: 0,
                        endRadius: bloomRadius
                    )
                )
            }

            let rimRect = fullRect.insetBy(dx: 1.5, dy: 1.5)
            context.stroke(
                Path(rimRect),
                with: .color(.white.opacity(isDark ? 0.14 : 0.65)),
                lineWidth: 3
            )
        }
        .accessibilityHidden(true)
    }
}
