import AppKit
import SwiftUI
import TokenTakenKit
import UniformTypeIdentifiers

enum ShareScope: Hashable {
    case overall
    case source(String)
    case model(String)
}

enum ShareAspect: String, CaseIterable, Identifiable {
    case portrait
    case square
    case landscape

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .portrait: "Portrait 2:3"
        case .square: "Square 1:1"
        case .landscape: "Landscape 3:2"
        }
    }

    var canvasSize: CGSize {
        switch self {
        case .portrait: CGSize(width: 1080, height: 1620)
        case .square: CGSize(width: 1080, height: 1080)
        case .landscape: CGSize(width: 1620, height: 1080)
        }
    }
}

private struct CosmosShareSnapshotKey: Hashable {
    let scope: ShareScope
    let period: Period
    let start: Date
    let end: Date
    let aspect: ShareAspect
    let dimension: BreakdownDimension
    let total: TokenCounts
    let sourcesDigest: Int
    let modelsDigest: Int

    static func breakdownDigest(_ breakdowns: [Breakdown]) -> Int {
        var hasher = Hasher()
        hasher.combine(breakdowns.count)
        for item in breakdowns {
            hasher.combine(item.id)
            hasher.combine(item.counts.total)
        }
        return hasher.finalize()
    }
}

private func cosmosShareSceneSize(for aspect: ShareAspect) -> CGSize {
    let cardSize = aspect.canvasSize
    switch aspect {
    case .portrait:
        return CGSize(width: cardSize.width, height: (cardSize.height * 0.52).rounded())
    case .square:
        return CGSize(width: cardSize.width, height: (cardSize.height * 0.46).rounded())
    case .landscape:
        return CGSize(width: (cardSize.width * 0.575).rounded(), height: cardSize.height)
    }
}

// MARK: - Share & Export Sheet

@MainActor
struct ShareExportSheet: View {
    var dimension: BreakdownDimension = .sources

    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(RefreshCoordinator.self) private var refreshCoordinator: RefreshCoordinator?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var previewPeriod: Period?
    @State private var scope: ShareScope = .overall
    @State private var aspect: ShareAspect = .portrait
    @State private var showCost = false
    @State private var showComposition = true
    @State private var showRank = true
    @State private var showInscription = true
    @State private var showSignature = true
    // Field share cards only; kept for this sheet, never saved or synced.
    @State private var inscription: String?
    @State private var signature = ""
    @State private var previewSummary: UsageSummary?
    @State private var scopedSummary: UsageSummary?
    @State private var previewLensBuckets: [LensBucket] = []
    @State private var loadedScopeKey: SnapshotQueryKey?
    @State private var rankTopPercent: Double?
    @State private var cosmosSnapshot: NSImage?
    @State private var renderedCosmosSnapshotKey: CosmosShareSnapshotKey?
    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var shareAnchor = SharePickerAnchor()
    @State private var exportError: String?

    @Namespace private var periodNamespace
    @Namespace private var aspectNamespace
    @FocusState private var focusedPeriod: Period?
    @FocusState private var focusedAspect: ShareAspect?

    private struct SnapshotQueryKey: Equatable {
        let period: Period
        let scope: ShareScope
        let modelPeriod: Period
        let modelStart: Date
        let modelEnd: Date
        let modelTotalTokens: Int64
        let modelUnpricedTokens: Int64
        let syncEnabled: Bool
        let remoteCount: Int
        let remoteRevision: Int
        let lastRefresh: Date?
        let dayStart: Date
        let isLiquidLens: Bool
    }

    private var activePeriod: Period { previewPeriod ?? model.period }
    private var summary: UsageSummary { previewSummary ?? model.summary }
    private var isCosmos: Bool { settings.theme == .cosmos }
    private var isLiquidLens: Bool { settings.theme == .liquidGlass && settings.liquidView == .lens }
    private var primaryInk: Color { isCosmos ? CosmosPalette.ink : Palette.ink1 }
    private var secondaryInk: Color { isCosmos ? CosmosPalette.ink2 : Palette.ink2 }
    private var tertiaryInk: Color { isCosmos ? CosmosPalette.ink3 : Palette.ink3 }
    private var hairline: Color { isCosmos ? CosmosPalette.rule : Palette.hairline }

    private var availableAspects: [ShareAspect] {
        ShareAspect.allCases.filter { isCosmos || isLiquidLens || $0 != .square }
    }

    private var effectiveAspect: ShareAspect {
        availableAspects.contains(aspect) ? aspect : .portrait
    }

    private var currentLensBuckets: [LensBucket] {
        guard isLiquidLens else { return [] }
        return previewLensBuckets
    }

    private var effectiveScope: ShareScope {
        validatedScope(scope, against: summary)
    }

    private func validatedScope(_ targetScope: ShareScope, against targetSummary: UsageSummary) -> ShareScope {
        switch targetScope {
        case .overall:
            return .overall
        case .source(let id):
            return targetSummary.bySource.contains(where: { $0.id == id }) ? targetScope : .overall
        case .model(let id):
            return targetSummary.byModel.contains(where: { $0.id == id }) ? targetScope : .overall
        }
    }

    private var snapshotQueryKey: SnapshotQueryKey {
        SnapshotQueryKey(
            period: activePeriod,
            scope: scope,
            modelPeriod: model.period,
            modelStart: model.summary.start,
            modelEnd: model.summary.end,
            modelTotalTokens: model.summary.total.total,
            modelUnpricedTokens: model.summary.cost.unpricedTokens,
            syncEnabled: settings.syncEnabled,
            remoteCount: refreshCoordinator?.remoteSnapshots.count ?? 0,
            remoteRevision: refreshCoordinator?.remoteRevision ?? 0,
            lastRefresh: refreshCoordinator?.lastRefresh,
            dayStart: Calendar.current.startOfDay(for: .now),
            isLiquidLens: isLiquidLens
        )
    }

    private var cardData: ShareCardData {
        ShareCardData(
            summary: summary,
            scope: effectiveScope,
            scopedSummary: loadedScopeKey == snapshotQueryKey ? scopedSummary : nil
        )
    }

    private var cardCanvasSize: CGSize { effectiveAspect.canvasSize }

    private func cosmosDimension(for scope: ShareScope) -> BreakdownDimension {
        switch scope {
        case .overall: dimension
        case .source: .models
        case .model: .sources
        }
    }

    private func makeCosmosSnapshotKey(
        scope: ShareScope,
        sceneSummary: UsageSummary,
        aspect: ShareAspect
    ) -> CosmosShareSnapshotKey {
        CosmosShareSnapshotKey(
            scope: scope,
            period: sceneSummary.period,
            start: sceneSummary.start,
            end: sceneSummary.end,
            aspect: aspect,
            dimension: cosmosDimension(for: scope),
            total: sceneSummary.total,
            sourcesDigest: CosmosShareSnapshotKey.breakdownDigest(sceneSummary.bySource),
            modelsDigest: CosmosShareSnapshotKey.breakdownDigest(sceneSummary.byModel)
        )
    }

    private var currentCosmosSnapshotKey: CosmosShareSnapshotKey {
        makeCosmosSnapshotKey(
            scope: effectiveScope,
            sceneSummary: cardData.cosmosSceneSummary,
            aspect: effectiveAspect
        )
    }

    private var currentCosmosSnapshot: NSImage? {
        guard renderedCosmosSnapshotKey == currentCosmosSnapshotKey else { return nil }
        return cosmosSnapshot
    }

    private var activeInscription: String {
        guard settings.theme == .field, showInscription else { return "" }
        return inscription ?? ""
    }

    private var activeSignature: String {
        guard settings.theme == .field, showSignature else { return "" }
        return signature
    }

    private var displayedRank: Double? {
        guard showRank, loadedScopeKey == snapshotQueryKey else { return nil }
        return rankTopPercent
    }

    var body: some View {
        HStack(spacing: 0) {
            previewPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(isCosmos ? 20 : 24)

            Rectangle()
                .fill(hairline)
                .frame(width: 1)
                .padding(.vertical, 20)

            controlColumn
                .frame(width: isCosmos ? 324 : 308)
                .padding(24)
                .background(isCosmos ? CosmosPalette.background : Color.clear)
        }
        .frame(width: isCosmos ? 892 : 760, height: isCosmos ? 640 : 620)
        .background {
            ShareSheetBackdrop(
                theme: settings.theme,
                transparency: settings.interfaceTransparency
            )
        }
        .environment(\.colorScheme, isCosmos ? .dark : scheme)
        .onAppear {
            if previewPeriod == nil {
                previewPeriod = model.period
            }
            if inscription == nil {
                inscription = ShareInscriptions.random(for: settings.theme, locale: locale)
            }
        }
        .onChange(of: snapshotQueryKey, initial: true) { _, key in
            let resolved = resolveShareSnapshot(for: key)
            previewSummary = resolved.summary
            scopedSummary = resolved.scopedSummary
            previewLensBuckets = resolved.lensBuckets
            rankTopPercent = resolved.rank
            loadedScopeKey = key
        }
        .onChange(of: currentCosmosSnapshotKey, initial: true) { _, key in
            renderCosmosSnapshot(for: key)
        }
        .alert(
            "Export Failed",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            ),
            presenting: exportError
        ) { _ in
            Button("OK", role: .cancel) {
                exportError = nil
            }
        } message: { message in
            Text(verbatim: message)
        }
        .onExitCommand {
            dismiss()
        }
        .onDisappear {
            copyResetTask?.cancel()
        }
    }

    private func renderCosmosSnapshot(for key: CosmosShareSnapshotKey) {
        guard isCosmos else {
            cosmosSnapshot = nil
            renderedCosmosSnapshotKey = nil
            return
        }
        cosmosSnapshot = CosmosSnapshot.image(
            summary: cardData.cosmosSceneSummary,
            dimension: key.dimension,
            size: cosmosShareSceneSize(for: key.aspect),
            scale: 2
        )
        renderedCosmosSnapshotKey = key
    }

    // MARK: - Left preview pane

    private var previewPane: some View {
        GeometryReader { proxy in
            let canvasSize = cardCanvasSize
            let availableWidth = max(1, proxy.size.width - 8)
            let availableHeight = max(1, proxy.size.height - 8)
            let scale = min(availableWidth / canvasSize.width, availableHeight / canvasSize.height)
            let scaledWidth = canvasSize.width * scale
            let scaledHeight = canvasSize.height * scale
            let cornerRadius = isCosmos ? 0 : max(12, 36 * scale)

            ShareCardView(
                data: cardData,
                aspect: effectiveAspect,
                showCost: showCost,
                showComposition: showComposition,
                dimension: dimension,
                liquidView: settings.liquidView,
                lensBuckets: currentLensBuckets,
                cosmosSnapshot: currentCosmosSnapshot,
                rank: displayedRank,
                inscription: activeInscription,
                signature: activeSignature
            )
            .frame(width: canvasSize.width, height: canvasSize.height)
            .scaleEffect(scale, anchor: .center)
            .frame(width: scaledWidth, height: scaledHeight)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isCosmos ? CosmosPalette.controlRule : hairline, lineWidth: 1)
            }
            .shadow(
                color: isCosmos ? .clear : .black.opacity(reduceTransparency ? 0 : (scheme == .dark ? 0.34 : 0.10)),
                radius: 18,
                x: 0,
                y: 6
            )
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: aspect)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Share card preview"))
        .accessibilityValue(Text("\(cardData.headlineAccessibilityText(locale: locale)), \(TokenFormat.spoken(cardData.counts.total)) tokens"))
    }

    // MARK: - Right control column

    private var controlColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(secondaryInk)
                        .frame(width: 24, height: 24)
                        .modifier(ShareRoundButtonSurface(
                            reduceTransparency: reduceTransparency,
                            isCosmos: isCosmos
                        ))
                        .contentShape(isCosmos ? AnyShape(Rectangle()) : AnyShape(Circle()))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help(Text("Close (Esc)"))
                .accessibilityLabel(Text("Close"))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Scope")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(secondaryInk)

                scopePicker
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Aspect")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(secondaryInk)

                aspectSegmentedControl
            }

            Rectangle()
                .fill(hairline)
                .frame(height: 1)

            VStack(spacing: 8) {
                shareToggleRow(title: "Show cost estimate", isOn: $showCost)
                shareToggleRow(title: "Show composition", isOn: $showComposition)
                shareToggleRow(title: "Show rank", isOn: $showRank)
                if settings.theme == .field {
                    shareToggleRow(title: "Inscription", isOn: $showInscription)
                    shareToggleRow(title: "Signature", isOn: $showSignature)
                    if showSignature {
                        fieldTextRow("Your name", text: $signature, limit: 24)
                    }
                }
            }

            Spacer(minLength: 12)

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    actionButton(
                        title: didCopy ? "Copied" : "Copy",
                        symbol: didCopy ? "checkmark" : "doc.on.doc",
                        accessibilityLabel: "Copy",
                        action: copyCardToPasteboard
                    )

                    actionButton(
                        title: "Save PNG…",
                        symbol: "arrow.down.to.line",
                        accessibilityLabel: "Save PNG…",
                        action: saveCardAsPNG
                    )
                }

                sharePickerButton
            }
        }
    }

    private func fieldTextRow(_ title: LocalizedStringKey, text: Binding<String>, limit: Int) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Palette.ink1)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(FieldPalette.panel))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(FieldPalette.rule, lineWidth: 1))
            .onChange(of: text.wrappedValue) { _, value in
                if value.count > limit { text.wrappedValue = String(value.prefix(limit)) }
            }
            .accessibilityLabel(Text(title))
    }

    private func shareToggleRow(
        title: LocalizedStringKey,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(primaryInk)
                .lineLimit(1)
                .accessibilityHidden(true)

            Spacer(minLength: 8)

            Group {
                if isCosmos {
                    Toggle(title, isOn: isOn)
                        .labelsHidden()
                        .toggleStyle(CosmosShareToggleStyle())
                } else {
                    Toggle(title, isOn: isOn)
                        .labelsHidden()
                        .toggleStyle(GlassToggleStyle())
                }
            }
            .accessibilityLabel(Text(title))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
    }

    // MARK: - Scope picker (Period + Harness menu + Model menu)

    private func periodTitle(_ period: Period) -> LocalizedStringKey {
        switch period {
        case .day: "Today"
        case .week: "This week"
        case .month: "This month"
        case .year: "This year"
        case .all: "All time"
        }
    }

    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            periodSegmentedControl

            HStack(spacing: 8) {
                sourceScopeMenu
                modelScopeMenu
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Scope"))
    }

    private var periodSegmentedControl: some View {
        segmentedContainer {
            HStack(spacing: isCosmos ? 0 : 2) {
                ForEach(Period.allCases) { option in
                    periodSegment(option)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Usage period"))
    }

    private func periodSegment(_ option: Period) -> some View {
        let isSelected = activePeriod == option
        return Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                previewPeriod = option
            }
        } label: {
            Text(periodTitle(option))
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? primaryInk : secondaryInk)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .padding(.horizontal, 3)
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(isCosmos ? AnyShape(Rectangle()) : AnyShape(Capsule()))
                .modifier(ShareSegmentSurface(
                    isSelected: isSelected,
                    reduceTransparency: reduceTransparency,
                    namespace: periodNamespace,
                    effectID: "sharePeriod",
                    isCosmos: isCosmos
                ))
        }
        .buttonStyle(.plain)
        .focused($focusedPeriod, equals: option)
        .onKeyPress(.leftArrow) {
            movePeriod(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            movePeriod(by: 1)
            return .handled
        }
        .accessibilityLabel(Text(periodTitle(option)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func movePeriod(by offset: Int) {
        let options = Period.allCases
        guard let index = options.firstIndex(of: activePeriod) else { return }
        let nextIndex = min(max(index + offset, 0), options.count - 1)
        previewPeriod = options[nextIndex]
        focusedPeriod = options[nextIndex]
    }

    private var selectedSourceBreakdown: Breakdown? {
        guard case .source(let id) = effectiveScope else { return nil }
        return summary.bySource.first { $0.id == id }
    }

    private var selectedModelBreakdown: Breakdown? {
        guard case .model(let id) = effectiveScope else { return nil }
        return summary.byModel.first { $0.id == id }
    }

    private var sourceScopeMenu: some View {
        let isSelected = selectedSourceBreakdown != nil
        return Menu {
            Button {
                scope = .overall
            } label: {
                if effectiveScope == .overall {
                    Label("All harnesses", systemImage: "checkmark")
                } else {
                    Text("All harnesses")
                }
            }
            if !summary.bySource.isEmpty {
                Divider()
            }
            ForEach(summary.bySource) { source in
                Button {
                    scope = .source(source.id)
                } label: {
                    if case .source(let id) = effectiveScope, id == source.id {
                        Label(
                            "\(source.name) · \(TokenFormat.short(source.counts.total))",
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(verbatim: "\(source.name) · \(TokenFormat.short(source.counts.total))")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let source = selectedSourceBreakdown {
                    Text(verbatim: source.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(primaryInk)
                        .lineLimit(1)
                } else {
                    Text("All harnesses")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(secondaryInk)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(tertiaryInk)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .modifier(SharePillSurface(
                isSelected: isSelected,
                reduceTransparency: reduceTransparency,
                isCosmos: isCosmos
            ))
            .contentShape(isCosmos
                ? AnyShape(Rectangle())
                : AnyShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .tint(isCosmos ? CosmosPalette.accent : Palette.roleAccent)
        .environment(\.colorScheme, isCosmos ? .dark : scheme)
        .disabled(summary.bySource.isEmpty)
        .opacity(summary.bySource.isEmpty ? 0.45 : 1)
        .accessibilityLabel(Text("Harness scope"))
        .accessibilityValue(selectedSourceBreakdown.map { Text(verbatim: $0.name) } ?? Text("All harnesses"))
    }

    private var modelScopeMenu: some View {
        let isSelected = selectedModelBreakdown != nil
        return Menu {
            Button {
                scope = .overall
            } label: {
                if effectiveScope == .overall {
                    Label("All models", systemImage: "checkmark")
                } else {
                    Text("All models")
                }
            }
            if !summary.byModel.isEmpty {
                Divider()
            }
            ForEach(summary.byModel) { item in
                Button {
                    scope = .model(item.id)
                } label: {
                    if case .model(let id) = effectiveScope, id == item.id {
                        Label(
                            "\(item.name) · \(TokenFormat.short(item.counts.total))",
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(verbatim: "\(item.name) · \(TokenFormat.short(item.counts.total))")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let item = selectedModelBreakdown {
                    Text(verbatim: item.name)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(primaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("All models")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(secondaryInk)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(tertiaryInk)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .modifier(SharePillSurface(
                isSelected: isSelected,
                reduceTransparency: reduceTransparency,
                isCosmos: isCosmos
            ))
            .contentShape(isCosmos
                ? AnyShape(Rectangle())
                : AnyShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .tint(isCosmos ? CosmosPalette.accent : Palette.roleAccent)
        .environment(\.colorScheme, isCosmos ? .dark : scheme)
        .disabled(summary.byModel.isEmpty)
        .opacity(summary.byModel.isEmpty ? 0.45 : 1)
        .accessibilityLabel(Text("Model scope"))
        .accessibilityValue(selectedModelBreakdown.map { Text(verbatim: $0.name) } ?? Text("All models"))
    }

    // MARK: - Aspect segmented control

    @ViewBuilder
    private func segmentedContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if isCosmos {
            content()
                .frame(maxWidth: .infinity)
                .background(CosmosPalette.background)
                .overlay(Rectangle().strokeBorder(CosmosPalette.controlRule, lineWidth: 1))
        } else {
            GlassEffectContainer(spacing: 0) {
                content()
                    .padding(2)
            }
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(Palette.barTrack))
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: reduceTransparency ? 1 : 0.5))
        }
    }

    @ViewBuilder private var aspectSegmentedControl: some View {
        let options = availableAspects
        segmentedContainer {
            HStack(spacing: isCosmos ? 0 : 2) {
                ForEach(options) { option in
                    aspectSegment(option)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Aspect ratio"))
    }

    private func aspectSegment(_ option: ShareAspect) -> some View {
        let isSelected = effectiveAspect == option
        return Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                aspect = option
            }
        } label: {
            Text(option.title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? primaryInk : secondaryInk)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 30)
                .contentShape(isCosmos ? AnyShape(Rectangle()) : AnyShape(Capsule()))
                .modifier(ShareSegmentSurface(
                    isSelected: isSelected,
                    reduceTransparency: reduceTransparency,
                    namespace: aspectNamespace,
                    effectID: "shareAspect",
                    isCosmos: isCosmos
                ))
        }
        .buttonStyle(.plain)
        .focused($focusedAspect, equals: option)
        .onKeyPress(.leftArrow) {
            moveAspect(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            moveAspect(by: 1)
            return .handled
        }
        .accessibilityLabel(Text(option.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func moveAspect(by offset: Int) {
        let options = availableAspects
        guard let index = options.firstIndex(of: effectiveAspect) else { return }
        let nextIndex = min(max(index + offset, 0), options.count - 1)
        aspect = options[nextIndex]
        focusedAspect = aspect
    }

    // MARK: - Action buttons

    private func actionButtonLabel(title: LocalizedStringKey, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(secondaryInk)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(primaryInk)
                .lineLimit(1)
        }
    }

    @ViewBuilder private func actionButton(
        title: LocalizedStringKey,
        symbol: String,
        accessibilityLabel: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        if isCosmos {
            Button(action: action) {
                actionButtonLabel(title: title, symbol: symbol)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
            }
            .buttonStyle(CosmosButtonStyle())
            .accessibilityLabel(Text(accessibilityLabel))
        } else {
            Button(action: action) {
                actionButtonLabel(title: title, symbol: symbol)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .modifier(ShareActionButtonSurface(isProminent: false, reduceTransparency: reduceTransparency))
                    .contentShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(accessibilityLabel))
        }
    }

    private var shareButtonLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isCosmos ? CosmosPalette.accent : Palette.roleAccent)
                .accessibilityHidden(true)
            Text("Share…")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(primaryInk)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var sharePickerButton: some View {
        Group {
            if isCosmos {
                Button(action: presentSharePicker) {
                    shareButtonLabel
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                }
                .buttonStyle(CosmosButtonStyle())
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(CosmosPalette.accent, lineWidth: 1))
            } else {
                Button(action: presentSharePicker) {
                    shareButtonLabel
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .modifier(ShareActionButtonSurface(isProminent: true, reduceTransparency: reduceTransparency))
                        .contentShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .background {
            SharePickerAnchorRepresentable(anchor: shareAnchor)
        }
        .accessibilityLabel(Text("Share…"))
    }

    // MARK: - Scoped summary & export

    private struct ResolvedShareSnapshot {
        let summary: UsageSummary
        let scopedSummary: UsageSummary?
        let lensBuckets: [LensBucket]
        let rank: Double?
    }

    private var themeFileTag: String {
        switch settings.theme {
        case .liquidGlass: "liquid-glass"
        case .field: "field"
        case .cosmos: "cosmos"
        }
    }

    private func resolveBaseStore() -> (store: any UsageStore, now: Date, priceTable: PriceTable)? {
        let isSynthetic = model.summary.cost.priceTableVersion == PriceTable.synthetic.version
        if let refreshCoordinator {
            let store: any UsageStore = settings.syncEnabled
                ? MergedUsageStore(local: refreshCoordinator.store, remote: refreshCoordinator.remoteSnapshots)
                : refreshCoordinator.store
            return (store, .now, isSynthetic ? .synthetic : .bundled)
        } else if isSynthetic {
            return (SyntheticUsageStore(), SyntheticUsageStore.defaultToday, .synthetic)
        } else {
            return nil
        }
    }

    /// Queries summary, scoped summary, lens buckets, and 30-day rank from a single preload and query-time `now`.
    private func resolveShareSnapshot(for key: SnapshotQueryKey) -> ResolvedShareSnapshot {
        guard let context = resolveBaseStore(),
              let rows = try? UsageAggregator.preload(context.store) else {
            return ResolvedShareSnapshot(
                summary: model.summary,
                scopedSummary: nil,
                lensBuckets: key.isLiquidLens ? model.lensBuckets(for: key.period) : [],
                rank: nil
            )
        }

        let cachedStore = PreloadedUsageStore(rows: rows)
        let aggregator = UsageAggregator(
            store: cachedStore,
            rows: rows,
            now: context.now,
            priceTable: context.priceTable
        )
        let resolvedSummary = (try? aggregator.summary(for: key.period)) ?? model.summary
        let targetScope = validatedScope(key.scope, against: resolvedSummary)

        let filter: UsageFilter? = switch targetScope {
        case .overall: nil
        case .source(let id): UsageFilter(sources: [id])
        case .model(let id): UsageFilter(models: [id])
        }

        let resolvedScoped: UsageSummary?
        if let filter {
            let filtered = FilteredUsageStore(store: cachedStore, filter: filter)
            resolvedScoped = try? UsageAggregator(
                store: filtered,
                now: context.now,
                priceTable: context.priceTable
            ).summary(for: key.period)
        } else {
            resolvedScoped = nil
        }

        let resolvedBuckets = key.isLiquidLens
            ? ((try? aggregator.lensBuckets(for: key.period)) ?? [])
            : []
        let resolvedRank: Double?
        if let points = try? aggregator.dailyTotals(lastDays: 30) {
            let total = points.reduce(Int64(0)) { $0 + $1.total }
            resolvedRank = UsageRank.topPercent(last30DaysTokens: total)
        } else {
            resolvedRank = nil
        }

        return ResolvedShareSnapshot(
            summary: resolvedSummary,
            scopedSummary: resolvedScoped,
            lensBuckets: resolvedBuckets,
            rank: resolvedRank
        )
    }

    private func sanitizedFileNameStem(for data: ShareCardData, scope targetScope: ShareScope) -> String {
        let periodLabel: String = switch data.summary.period {
        case .day: String(localized: "Today", locale: locale)
        case .week: String(localized: "This week", locale: locale)
        case .month: String(localized: "This month", locale: locale)
        case .year: String(localized: "This year", locale: locale)
        case .all: String(localized: "All time", locale: locale)
        }
        let scopeSuffix: String = switch targetScope {
        case .overall:
            String(localized: "Overall", locale: locale)
        case .source, .model:
            data.scopeDisplayTitle(locale: locale)
        }
        var sanitizedScope = scopeSuffix
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while sanitizedScope.hasPrefix(".") {
            sanitizedScope.removeFirst()
        }
        var stem = sanitizedScope.isEmpty
            ? "Token Taken - \(periodLabel)"
            : "Token Taken - \(periodLabel) - \(sanitizedScope)"
        while stem.hasPrefix(".") {
            stem.removeFirst()
        }
        let maxStemLength = 80 - 4
        if stem.count > maxStemLength {
            stem = String(stem.prefix(maxStemLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return stem.isEmpty ? "Token Taken" : stem
    }

    private var defaultFileName: String {
        "\(sanitizedFileNameStem(for: cardData, scope: effectiveScope)).png"
    }

    private func renderPNGData() -> Data? {
        let queryKey = snapshotQueryKey
        let resolved: ResolvedShareSnapshot
        if loadedScopeKey == queryKey {
            resolved = ResolvedShareSnapshot(
                summary: summary,
                scopedSummary: scopedSummary,
                lensBuckets: previewLensBuckets,
                rank: rankTopPercent
            )
        } else {
            resolved = resolveShareSnapshot(for: queryKey)
        }
        let resolvedScope = validatedScope(scope, against: resolved.summary)
        let resolvedRank = showRank ? resolved.rank : nil
        let exportData = ShareCardData(
            summary: resolved.summary,
            scope: resolvedScope,
            scopedSummary: resolved.scopedSummary
        )
        let resolvedAspect = effectiveAspect
        let canvasSize = resolvedAspect.canvasSize
        let exportSceneSummary = exportData.cosmosSceneSummary
        let exportSnapshotKey = makeCosmosSnapshotKey(
            scope: resolvedScope,
            sceneSummary: exportSceneSummary,
            aspect: resolvedAspect
        )
        let exportCosmosSnapshot: NSImage?
        if isCosmos, renderedCosmosSnapshotKey == exportSnapshotKey {
            exportCosmosSnapshot = cosmosSnapshot
        } else if isCosmos {
            exportCosmosSnapshot = CosmosSnapshot.image(
                summary: exportSceneSummary,
                dimension: exportSnapshotKey.dimension,
                size: cosmosShareSceneSize(for: resolvedAspect),
                scale: 2
            )
        } else {
            exportCosmosSnapshot = nil
        }
        let exportLensBuckets = isLiquidLens ? resolved.lensBuckets : []
        let view = ShareCardView(
            data: exportData,
            aspect: resolvedAspect,
            showCost: showCost,
            showComposition: showComposition,
            dimension: dimension,
            liquidView: settings.liquidView,
            lensBuckets: exportLensBuckets,
            cosmosSnapshot: exportCosmosSnapshot,
            rank: resolvedRank,
            inscription: activeInscription,
            signature: activeSignature
        )
        .frame(width: canvasSize.width, height: canvasSize.height)
        .environment(\.colorScheme, settings.theme == .cosmos ? .dark : scheme)
        .environment(\.locale, locale)
        .fontDesign(settings.theme == .field ? .serif : nil)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        renderer.proposedSize = ProposedViewSize(canvasSize)

        let targetAppearance = NSAppearance(named: settings.theme == .cosmos || scheme == .dark ? .darkAqua : .aqua)
        var cgImage: CGImage?
        if let targetAppearance {
            targetAppearance.performAsCurrentDrawingAppearance {
                cgImage = renderer.cgImage
            }
        } else {
            cgImage = renderer.cgImage
        }
        guard let cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = canvasSize
        return rep.representation(using: .png, properties: [:])
    }

    private func copyCardToPasteboard() {
        exportError = nil
        guard let pngData = renderPNGData() else {
            exportError = String(localized: "Could not render the share card image.", locale: locale)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setData(pngData, forType: .png) else {
            exportError = String(localized: "Could not copy the image to the clipboard.", locale: locale)
            return
        }

        didCopy = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }

    private func saveCardAsPNG() {
        exportError = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultFileName

        let finishSave: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            guard let pngData = renderPNGData() else {
                exportError = String(localized: "Could not render the share card image.", locale: locale)
                return
            }
            do {
                try pngData.write(to: url, options: .atomic)
            } catch {
                exportError = String(localized: "Could not save PNG: \(error.localizedDescription)", locale: locale)
            }
        }

        if let window = shareAnchor.view?.window ?? NSApp.keyWindow {
            Task { @MainActor in
                let response = await panel.beginSheetModal(for: window)
                finishSave(response)
            }
        } else {
            finishSave(panel.runModal())
        }
    }

    private func presentSharePicker() {
        exportError = nil
        guard let anchorView = shareAnchor.view else {
            exportError = String(localized: "Could not open the share menu.", locale: locale)
            return
        }
        guard let pngData = renderPNGData() else {
            exportError = String(localized: "Could not render the share card image.", locale: locale)
            return
        }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenTakenShare", isDirectory: true)
        let shortUUID = String(UUID().uuidString.prefix(8)).lowercased()
        let stem = sanitizedFileNameStem(for: cardData, scope: effectiveScope)
        let fileName = "\(stem)-\(themeFileTag)-\(effectiveAspect.rawValue)-\(shortUUID).png"
        let fileURL = tempDir.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            pruneExpiredShareTempFiles(in: tempDir, before: Date.now.addingTimeInterval(-86_400))
            try pngData.write(to: fileURL, options: .atomic)
            let picker = NSSharingServicePicker(items: [fileURL])
            picker.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        } catch {
            exportError = String(localized: "Could not prepare the share image: \(error.localizedDescription)", locale: locale)
        }
    }

    private func pruneExpiredShareTempFiles(in directory: URL, before cutoff: Date) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: []
        ) else { return }
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let timestamp = values?.contentModificationDate ?? values?.creationDate
            if let timestamp, timestamp < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

private struct PreloadedUsageStore: UsageStore {
    let rows: UsageAggregator.Rows
    var devices: [Device] { rows.devices }
    func records() -> [UsageRecord] { rows.records }
    func hourly() -> [HourlyUsage] { rows.hourly }
}

// MARK: - Card Data

struct ShareCardData {
    enum Kind {
        case overall
        case source(id: String, name: String)
        case model(id: String, name: String)
    }

    struct SupportingFact: Identifiable {
        let id: String
        let label: LocalizedStringKey
        let value: String
        let isMonospacedValue: Bool
    }

    struct Stratum: Identifiable {
        enum Label {
            case verbatim(String, monospaced: Bool)
            case localized(LocalizedStringKey)
        }

        let id: String
        let label: Label
        let tokens: Int64
        let color: Color
    }

    let summary: UsageSummary
    let scopedSummary: UsageSummary?
    let kind: Kind
    let counts: TokenCounts
    let estimatedUSD: Double
    let unpricedTokens: Int64

    private static let overallSkyColor = Color(light: "#3A9BE0", dark: "#5BB2F0")
    fileprivate static let mergedStratumColor = Color(light: "#6E7D92", dark: "#8494AB")

    init(summary: UsageSummary, scope: ShareScope, scopedSummary: UsageSummary? = nil) {
        self.summary = summary
        self.scopedSummary = scopedSummary
        let priceTable = summary.cost.priceTableVersion == PriceTable.synthetic.version
            ? PriceTable.synthetic
            : PriceTable.bundled

        switch scope {
        case .overall:
            self.kind = .overall
            self.counts = summary.total
            self.estimatedUSD = summary.cost.estimatedUSD
            self.unpricedTokens = summary.cost.unpricedTokens

        case .source(let id):
            if let source = summary.bySource.first(where: { $0.id == id }) {
                self.kind = .source(id: source.id, name: source.name)
                self.counts = source.counts
                if let scopedSummary {
                    self.estimatedUSD = scopedSummary.cost.estimatedUSD
                    self.unpricedTokens = scopedSummary.cost.unpricedTokens
                } else if summary.bySource.count == 1 {
                    self.estimatedUSD = summary.cost.estimatedUSD
                    self.unpricedTokens = summary.cost.unpricedTokens
                } else {
                    let ratio = Share.ratio(source.counts.total, of: summary.total.total)
                    self.estimatedUSD = summary.cost.estimatedUSD * ratio
                    if summary.cost.unpricedTokens <= 0 {
                        self.unpricedTokens = 0
                    } else if summary.cost.unpricedTokens >= summary.total.total, summary.total.total > 0 {
                        self.unpricedTokens = source.counts.total
                    } else {
                        let scaled = Int64((Double(summary.cost.unpricedTokens) * ratio).rounded())
                        self.unpricedTokens = min(source.counts.total, max(source.counts.uncategorized, scaled))
                    }
                }
            } else {
                self.kind = .overall
                self.counts = summary.total
                self.estimatedUSD = summary.cost.estimatedUSD
                self.unpricedTokens = summary.cost.unpricedTokens
            }

        case .model(let id):
            if let item = summary.byModel.first(where: { $0.id == id }) {
                self.kind = .model(id: item.id, name: item.name)
                self.counts = item.counts
                if let scopedSummary {
                    self.estimatedUSD = scopedSummary.cost.estimatedUSD
                    self.unpricedTokens = scopedSummary.cost.unpricedTokens
                } else {
                    let estimate = priceTable.estimate(model: item.id, counts: item.counts)
                    self.estimatedUSD = estimate.usd
                    self.unpricedTokens = estimate.unpricedTokens
                }
            } else {
                self.kind = .overall
                self.counts = summary.total
                self.estimatedUSD = summary.cost.estimatedUSD
                self.unpricedTokens = summary.cost.unpricedTokens
            }
        }
    }

    func scopeDisplayTitle(locale: Locale) -> String {
        switch kind {
        case .overall:
            String(localized: "Overall", locale: locale)
        case .source(_, let name):
            name
        case .model(_, let name):
            name
        }
    }

    /// Scoped summary for Cosmos scene/ranking; avoids leaking global summary when `scopedSummary` is nil.
    var cosmosSceneSummary: UsageSummary {
        if let scopedSummary {
            return scopedSummary
        }
        guard isPartialScope else {
            return summary
        }

        let fallbackSources: [Breakdown]
        let fallbackModels: [Breakdown]
        switch kind {
        case .overall:
            fallbackSources = summary.bySource
            fallbackModels = summary.byModel
        case .source(let id, let name):
            fallbackSources = counts.total > 0 ? [Breakdown(id: id, name: name, counts: counts)] : []
            fallbackModels = activeSources.count == 1 ? activeModels : []
        case .model(let id, let name):
            if activeSources.count == 1, let sole = activeSources.first, counts.total > 0 {
                fallbackSources = [Breakdown(id: sole.id, name: sole.name, counts: counts)]
            } else {
                fallbackSources = []
            }
            fallbackModels = counts.total > 0 ? [Breakdown(id: id, name: name, counts: counts)] : []
        }

        return UsageSummary(
            period: summary.period,
            start: summary.start,
            end: summary.end,
            total: counts,
            bySource: fallbackSources,
            byModel: fallbackModels,
            byDevice: [],
            series: [],
            cost: CostEstimate(
                estimatedUSD: estimatedUSD,
                unpricedTokens: unpricedTokens,
                priceTableVersion: summary.cost.priceTableVersion
            ),
            devices: summary.devices
        )
    }

    func periodHeadlineText(locale: Locale) -> String {
        switch summary.period {
        case .day:
            return String(localized: "Used today", locale: locale)
        case .week:
            return String(localized: "Used this week", locale: locale)
        case .month:
            // Chinese reads "11 月", not the wide form "十一月".
            let month = locale.language.languageCode == .chinese
                ? "\(Calendar.current.component(.month, from: summary.start)) 月"
                : summary.start.formatted(.dateTime.locale(locale).month(.wide))
            return String(localized: "Used in \(month)", locale: locale)
        case .year:
            let year = String(Calendar.current.component(.year, from: summary.start))
            return String(localized: "Used in \(year) so far", locale: locale)
        case .all:
            return String(localized: "Used in total", locale: locale)
        }
    }

    func headlineAccessibilityText(locale: Locale) -> String {
        let periodPart = periodHeadlineText(locale: locale)
        switch kind {
        case .overall:
            return periodPart
        case .source(_, let name):
            return "\(name) · \(periodPart)"
        case .model(let id, let name):
            let modelDisplay = name.isEmpty ? id : name
            return "\(modelDisplay) · \(periodPart)"
        }
    }

    func headlineText(locale: Locale, modelFont: Font? = nil) -> Text {
        let periodText = Text(verbatim: periodHeadlineText(locale: locale))
        switch kind {
        case .overall:
            return periodText
        case .source(_, let name):
            return Text(verbatim: "\(name) · ") + periodText
        case .model(let id, let name):
            let modelDisplay = name.isEmpty ? id : name
            let modelText = if let modelFont {
                Text(verbatim: modelDisplay).font(modelFont)
            } else {
                Text(verbatim: modelDisplay)
            }
            return modelText + Text(verbatim: " · ") + periodText
        }
    }

    var isPartialScope: Bool {
        switch kind {
        case .overall: false
        case .source, .model: true
        }
    }

    var periodShareRatio: Double {
        switch kind {
        case .overall:
            return counts.total > 0 ? 1.0 : 0.0
        case .source, .model:
            return min(max(Share.ratio(counts.total, of: summary.total.total), 0), 1)
        }
    }

    var accentColor: Color {
        switch kind {
        case .overall:
            Self.overallSkyColor
        case .source(let id, _):
            Palette.color(forSource: id)
        case .model(let id, _):
            Palette.modelColors(for: summary.byModel.map(\.id))[id] ?? Palette.color(for: .output)
        }
    }

    /// All positive strata sorted descending by token count before any tail merging.
    fileprivate var unmergedStrata: [Stratum] {
        switch kind {
        case .overall:
            return activeSources.map { source in
                Stratum(
                    id: source.id,
                    label: .verbatim(source.name, monospaced: false),
                    tokens: source.counts.total,
                    color: Palette.color(forSource: source.id)
                )
            }

        case .source:
            let models = resolvedModelsForSource
            guard !models.isEmpty else {
                return categoryStrata
            }
            let palette = Palette.modelColors(for: summary.byModel.map(\.id) + models.map(\.id))
            return models.map { item in
                Stratum(
                    id: item.id,
                    label: .verbatim(item.name, monospaced: true),
                    tokens: item.counts.total,
                    color: palette[item.id] ?? Palette.color(for: .output)
                )
            }

        case .model:
            let sources = resolvedSourcesForModel
            guard !sources.isEmpty else {
                return categoryStrata
            }
            return sources.map { source in
                Stratum(
                    id: source.id,
                    label: .verbatim(source.name, monospaced: false),
                    tokens: source.counts.total,
                    color: Palette.color(forSource: source.id)
                )
            }
        }
    }

    /// Stratified layers sorted descending by token count (index 0 is thickest at the bottom).
    var strata: [Stratum] {
        let limit = switch kind {
        case .overall: 5
        case .source, .model: 4
        }
        return Self.mergeTail(unmergedStrata, limit: limit)
    }

    /// Supporting facts for the selected scope (3 for overall, 2 for a single harness or model).
    var supportingFacts: [SupportingFact] {
        switch kind {
        case .overall:
            return [
                SupportingFact(
                    id: "harnesses",
                    label: "Harnesses",
                    value: "\(activeSources.count)",
                    isMonospacedValue: false
                ),
                SupportingFact(
                    id: "models",
                    label: "Models",
                    value: "\(activeModels.count)",
                    isMonospacedValue: false
                ),
                SupportingFact(
                    id: "topModel",
                    label: "Top model",
                    value: activeModels.first?.name ?? "—",
                    isMonospacedValue: true
                ),
            ]

        case .source:
            let models = resolvedModelsForSource
            return [
                SupportingFact(
                    id: "models",
                    label: "Models",
                    value: "\(models.count)",
                    isMonospacedValue: false
                ),
                SupportingFact(
                    id: "topModel",
                    label: "Top model",
                    value: models.first?.name ?? "—",
                    isMonospacedValue: true
                ),
            ]

        case .model:
            let harnesses = resolvedSourcesForModel
            return [
                SupportingFact(
                    id: "harnesses",
                    label: "Harnesses",
                    value: "\(harnesses.count)",
                    isMonospacedValue: false
                ),
                SupportingFact(
                    id: "topHarness",
                    label: "Top harness",
                    value: harnesses.first?.name ?? "—",
                    isMonospacedValue: false
                ),
            ]
        }
    }

    private var activeSources: [Breakdown] {
        summary.bySource
            .filter { $0.counts.total > 0 }
            .sorted { $0.counts.total > $1.counts.total }
    }

    private var activeModels: [Breakdown] {
        summary.byModel
            .filter { $0.counts.total > 0 }
            .sorted { $0.counts.total > $1.counts.total }
    }

    private var resolvedModelsForSource: [Breakdown] {
        if let scopedSummary {
            return scopedSummary.byModel
                .filter { $0.counts.total > 0 }
                .sorted { $0.counts.total > $1.counts.total }
        }
        if activeSources.count == 1 {
            return activeModels
        }
        return []
    }

    private var resolvedSourcesForModel: [Breakdown] {
        if let scopedSummary {
            return scopedSummary.bySource
                .filter { $0.counts.total > 0 }
                .sorted { $0.counts.total > $1.counts.total }
        }
        if activeSources.count == 1 {
            return activeSources
        }
        return []
    }

    private var categoryStrata: [Stratum] {
        var strata = TokenCategory.allCases.compactMap { category -> Stratum? in
            let value = counts[category]
            guard value > 0 else { return nil }
            return Stratum(
                id: category.rawValue,
                label: .localized(category.title),
                tokens: value,
                color: Palette.color(for: category)
            )
        }
        if counts.uncategorized > 0 {
            strata.append(Stratum(
                id: "uncategorized",
                label: .localized("Uncategorized"),
                tokens: counts.uncategorized,
                color: Palette.ink3.opacity(0.45)
            ))
        }
        return strata.sorted { $0.tokens > $1.tokens }
    }

    /// Mirrors `BreakdownCard`: folding a single trailing item into "Other 1" saves no space.
    private static func mergeTail(_ items: [Stratum], limit: Int) -> [Stratum] {
        guard items.count > limit + 1 else { return items }
        let kept = Array(items.prefix(limit))
        let remaining = items.dropFirst(limit)
        let mergedTokens = remaining.reduce(Int64(0)) { $0 + $1.tokens }
        guard mergedTokens > 0 else { return kept }
        var result = kept
        result.append(Stratum(
            id: "others",
            label: .localized("Other \(remaining.count)"),
            tokens: mergedTokens,
            color: mergedStratumColor
        ))
        return result
    }
}

// MARK: - Concept 3: Tide Line ShareCardView (1080x1620 portrait / 1620x1080 landscape)

private struct TideGeometry {
    struct Band: Identifiable {
        let id: String
        let stratum: ShareCardData.Stratum
        let minY: CGFloat
        let maxY: CGFloat
        let inlineMidY: CGFloat?
        let nameFontSize: CGFloat
        let valueFontSize: CGFloat
    }

    let canvasSize: CGSize
    let horizontalMargin: CGFloat
    let verticalMargin: CGFloat
    let footerBottomPadding: CGFloat
    let leftColumnWidth: CGFloat
    let vesselRect: CGRect
    let vesselCornerRadius: CGFloat
    let innerRect: CGRect
    let fillLevel: Double
    let vesselLayers: [LiquidGlassVessel.Layer]
    let brimY: CGFloat
    let meniscusY: CGFloat
    let meniscusHeight: CGFloat
    let strataTotalTokens: Int64
    let bands: [Band]

    private static let inlineMinLayerHeight: CGFloat = 44
    private static let minCardLabelSize: CGFloat = 22

    init(data: ShareCardData, aspect: ShareAspect, showComposition: Bool) {
        let size = aspect.canvasSize
        self.canvasSize = size

        let hMargin: CGFloat = 76
        let vMargin: CGFloat = 72
        let footerPad: CGFloat = 24
        let cornerRadius: CGFloat
        let resolvedVesselRect: CGRect
        let leftColWidth: CGFloat

        switch aspect {
        case .portrait, .square:
            let contentWidth = size.width - hMargin * 2
            let topY: CGFloat = 660
            let bottomY: CGFloat = size.height - 76
            cornerRadius = 44
            resolvedVesselRect = CGRect(
                x: hMargin,
                y: topY,
                width: contentWidth,
                height: max(80, bottomY - topY)
            )
            leftColWidth = contentWidth

        case .landscape:
            let contentWidth = size.width - hMargin * 2
            let vesselWidth = (contentWidth * 0.55).rounded()
            let vesselX = size.width - hMargin - vesselWidth
            let topY: CGFloat = data.isPartialScope ? (vMargin + 44) : vMargin
            let bottomY: CGFloat = size.height - 76
            let columnGap: CGFloat = 52
            cornerRadius = 42
            resolvedVesselRect = CGRect(
                x: vesselX,
                y: topY,
                width: vesselWidth,
                height: max(80, bottomY - topY)
            )
            leftColWidth = max(320, vesselX - hMargin - columnGap)
        }

        self.horizontalMargin = hMargin
        self.verticalMargin = vMargin
        self.footerBottomPadding = footerPad
        self.leftColumnWidth = leftColWidth
        self.vesselCornerRadius = cornerRadius
        self.vesselRect = resolvedVesselRect

        let effectiveFill: Double
        if data.counts.total <= 0 {
            effectiveFill = 0
        } else if data.isPartialScope {
            effectiveFill = min(1, max(0.035, data.periodShareRatio))
        } else {
            effectiveFill = 1.0
        }
        self.fillLevel = effectiveFill

        let rawItems = data.unmergedStrata
        let rawSum = rawItems.reduce(Int64(0)) { $0 + $1.tokens }
        self.strataTotalTokens = max(rawSum, data.counts.total)

        let baseMetrics = LiquidGlassVessel.metrics(
            for: resolvedVesselRect,
            cornerRadius: cornerRadius,
            layers: effectiveFill > 0
                ? [LiquidGlassVessel.Layer(color: data.accentColor, fraction: effectiveFill)]
                : [],
            fillLevel: effectiveFill
        )
        let liquidTotalHeight = max(0, baseMetrics.innerRect.maxY - baseMetrics.meniscusCenterY)

        // Merge strata shorter than 44pt into a single "Other N" layer so no external micro labels remain.
        let resolvedStrata: [ShareCardData.Stratum]
        if showComposition, effectiveFill > 0, !rawItems.isEmpty, rawSum > 0, liquidTotalHeight > 0 {
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
        let layers: [LiquidGlassVessel.Layer]
        if effectiveFill <= 0 {
            layers = []
        } else if showComposition, !resolvedStrata.isEmpty, sum > 0 {
            layers = resolvedStrata.map { item in
                LiquidGlassVessel.Layer(
                    color: item.color,
                    fraction: (Double(item.tokens) / Double(sum)) * effectiveFill
                )
            }
        } else {
            layers = [LiquidGlassVessel.Layer(color: data.accentColor, fraction: effectiveFill)]
        }
        self.vesselLayers = layers

        let finalMetrics = LiquidGlassVessel.metrics(
            for: resolvedVesselRect,
            cornerRadius: cornerRadius,
            layers: layers,
            fillLevel: effectiveFill
        )

        self.innerRect = finalMetrics.innerRect
        self.brimY = finalMetrics.brimCenterY
        self.meniscusY = finalMetrics.meniscusCenterY
        self.meniscusHeight = finalMetrics.meniscusHeight

        guard showComposition, effectiveFill > 0, !resolvedStrata.isEmpty, sum > 0 else {
            self.bands = []
            return
        }

        let maxNameSize: CGFloat = aspect == .portrait ? 33 : 31
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
                        max(0, bandHeight - 34) * 0.45
                    )
                    inlineMidY = (bandMinY + topClear + bandMaxY) * 0.5
                } else {
                    inlineMidY = (bandMinY + bandMaxY) * 0.5
                }

                if bandHeight >= 84 {
                    nameSize = maxNameSize
                } else {
                    let t = min(max((bandHeight - Self.inlineMinLayerHeight) / 40, 0), 1)
                    nameSize = (24 + t * (maxNameSize - 24)).rounded()
                }
                valueSize = max(Self.minCardLabelSize, nameSize - 2)
            } else {
                inlineMidY = nil
                nameSize = 24
                valueSize = Self.minCardLabelSize
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

@MainActor
struct CosmosShareCard: View {
    let data: ShareCardData
    let aspect: ShareAspect
    let showCost: Bool
    let showComposition: Bool
    let dimension: BreakdownDimension
    let snapshot: NSImage?
    var rank: Double? = nil

    @Environment(\.locale) private var locale

    private static let categoryColors: [TokenCategory: Color] = [
        .cacheRead: Color(hex: "#EAF2FF"),
        .input: Color(hex: "#FFF0D2"),
        .cacheWrite: Color(hex: "#E8C48E"),
        .output: Color(hex: "#D99A56"),
        .reasoning: Color(hex: "#B65A35"),
    ]

    private var cardSize: CGSize { aspect.canvasSize }
    private var sceneSize: CGSize { cosmosShareSceneSize(for: aspect) }
    private var isWide: Bool { cardSize.width > cardSize.height }
    private var detailSize: CGSize {
        isWide
            ? CGSize(width: cardSize.width - sceneSize.width, height: cardSize.height)
            : CGSize(width: cardSize.width, height: cardSize.height - sceneSize.height)
    }
    private var sceneSummary: UsageSummary { data.cosmosSceneSummary }
    private var sceneDimension: BreakdownDimension {
        switch data.kind {
        case .overall: dimension
        case .source: .models
        case .model: .sources
        }
    }
    private var items: [Breakdown] {
        let items = sceneDimension == .sources ? sceneSummary.bySource : sceneSummary.byModel
        return items.filter { $0.counts.total > 0 }
    }

    var body: some View {
        Group {
            if isWide {
                HStack(spacing: 0) {
                    scene
                    details
                }
            } else {
                VStack(spacing: 0) {
                    scene
                    details
                }
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .background(CosmosPalette.page)
    }

    private var scene: some View {
        CosmosPalette.page
            .overlay {
                if let snapshot {
                    Image(nsImage: snapshot)
                        .resizable()
                        .frame(width: sceneSize.width, height: sceneSize.height)
                }
            }
            .frame(width: sceneSize.width, height: sceneSize.height)
            .clipped()
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isWide {
                wideDetails
            } else {
                stackedDetails
            }

            if rank != nil {
                Text("Rank is an estimate derived from public usage sources.")
                    .font(.system(size: 13))
                    .foregroundStyle(CosmosPalette.ink3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, isWide ? 40 : 36)
                    .padding(.bottom, isWide ? 24 : 20)
            }
        }
        .frame(width: detailSize.width, height: detailSize.height, alignment: .topLeading)
        .background(CosmosPalette.background)
        .overlay(alignment: isWide ? .leading : .top) {
            Rectangle()
                .fill(CosmosPalette.controlRule)
                .frame(width: isWide ? 1 : nil, height: isWide ? nil : 1)
        }
    }

    private var wideDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            hero.padding(.top, 22)
            if showCost {
                cost.padding(.top, 16)
            }
            factsRow.padding(.top, 20)
            if let rank {
                rankLine(rank).padding(.top, 14)
            }
            hairline.padding(.top, 20)
            ranking.padding(.top, 20)
            if showComposition {
                hairline.padding(.top, 20)
                composition.padding(.top, 18)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 36)
        .padding(.horizontal, 40)
        .padding(.bottom, rank != nil ? 16 : 36)
    }

    private var stackedDetails: some View {
        HStack(alignment: .top, spacing: 44) {
            VStack(alignment: .leading, spacing: 0) {
                header
                hero.padding(.top, 20)
                if showCost {
                    cost.padding(.top, 14)
                }
                factsRow.padding(.top, 20)
                if let rank {
                    rankLine(rank).padding(.top, 14)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 0) {
                ranking
                if showComposition {
                    hairline.padding(.top, 18)
                    composition.padding(.top, 16)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.top, 36)
        .padding(.horizontal, 36)
        .padding(.bottom, rank != nil ? 16 : 36)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                ShareBrandLogo(theme: .cosmos, size: 38)
                    .accessibilityHidden(true)

                Text(verbatim: "Token Taken")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(CosmosPalette.ink)
                    .lineLimit(1)
            }

            Text(periodDescription)
                .font(.system(size: 20))
                .foregroundStyle(CosmosPalette.ink3)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 8)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            data.headlineText(
                locale: locale,
                modelFont: .system(size: 17, weight: .medium, design: .monospaced)
            )
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(CosmosPalette.ink2)
            .lineLimit(1)
            .truncationMode(.middle)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: TokenFormat.short(data.counts.total))
                    .font(.system(size: 58, weight: .light, design: .monospaced))
                    .foregroundStyle(CosmosPalette.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                Text(verbatim: "Token")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(CosmosPalette.ink3)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.top, 8)
        }
    }

    private var factsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(data.supportingFacts) { fact in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(fact.label)
                        .font(.system(size: 16))
                        .foregroundStyle(CosmosPalette.ink3)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(verbatim: fact.value)
                        .font(.system(size: 17, weight: .medium, design: fact.isMonospacedValue ? .monospaced : .default))
                        .foregroundStyle(CosmosPalette.ink)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func rankLine(_ rank: Double) -> some View {
        Text("Last 30 days · about top \(UsageRank.formatted(rank))")
            .font(.system(size: 16, weight: .medium, design: .monospaced))
            .foregroundStyle(CosmosPalette.ink2)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    @ViewBuilder
    private var cost: some View {
        if data.unpricedTokens > 0, data.unpricedTokens >= data.counts.total {
            Text("No prices for these models")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(CosmosPalette.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: TokenFormat.usd(data.estimatedUSD))
                    .font(.system(size: 30, weight: .medium, design: .monospaced))
                    .foregroundStyle(CosmosPalette.accent)
                    .monospacedDigit()
                    .lineLimit(1)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("estimate, not a bill")
                        .foregroundStyle(CosmosPalette.ink3)
                    if data.unpricedTokens > 0 {
                        Text(verbatim: "·")
                            .foregroundStyle(CosmosPalette.ink3)
                        Text("\(TokenFormat.short(data.unpricedTokens)) unpriced")
                            .foregroundStyle(CosmosPalette.accent)
                            .monospacedDigit()
                    }
                }
                .font(.system(size: 16))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 4)
            }
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(CosmosPalette.controlRule)
            .frame(height: 1)
    }

    private var ranking: some View {
        let denominator = data.counts.total
        return VStack(alignment: .leading, spacing: 0) {
            Text(sceneDimension == .sources ? LocalizedStringKey("Top 3 harnesses") : LocalizedStringKey("Top 3 models"))
                .font(.system(size: 18))
                .foregroundStyle(CosmosPalette.ink2)

            if items.isEmpty {
                Text(data.isPartialScope && data.counts.total > 0 ? LocalizedStringKey("Breakdown unavailable") : LocalizedStringKey("No usage in this period"))
                    .font(.system(size: 18))
                    .foregroundStyle(CosmosPalette.ink3)
                    .padding(.top, 16)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { index, item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                Text(verbatim: "\(index + 1). \(item.name)")
                                    .font(.system(size: 20))
                                    .foregroundStyle(CosmosPalette.ink)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer(minLength: 8)

                                Text(verbatim: TokenFormat.short(item.counts.total))
                                    .font(.system(size: 18, design: .monospaced))
                                    .foregroundStyle(CosmosPalette.ink2)
                                    .monospacedDigit()
                                    .lineLimit(1)
                            }

                            Group {
                                if data.isPartialScope {
                                    Text("Share of scope \(Share.percent(item.counts.total, of: denominator))")
                                } else {
                                    Text("Share of period \(Share.percent(item.counts.total, of: denominator))")
                                }
                            }
                            .font(.system(size: 16, design: .monospaced))
                            .foregroundStyle(CosmosPalette.ink3)
                            .monospacedDigit()
                        }
                    }
                }
                .padding(.top, 14)
            }
        }
    }

    private var composition: some View {
        let total = data.counts.total
        return VStack(alignment: .leading, spacing: 0) {
            Text("Composition")
                .font(.system(size: 18))
                .foregroundStyle(CosmosPalette.ink2)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(CosmosScene.categoryOrder) { category in
                    let value = data.counts[category]
                    compositionRow(
                        color: Self.categoryColors[category] ?? CosmosPalette.ink3,
                        title: category.title,
                        value: value,
                        total: total
                    )
                }
                if data.counts.uncategorized > 0 {
                    compositionRow(
                        color: CosmosPalette.ink3,
                        title: "Uncategorized",
                        value: data.counts.uncategorized,
                        total: total
                    )
                }
            }
            .padding(.top, 12)
        }
    }

    private func compositionRow(color: Color, title: LocalizedStringKey, value: Int64, total: Int64) -> some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(CosmosPalette.ink2)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(verbatim: TokenFormat.short(value))
                .font(.system(size: 16, design: .monospaced))
                .foregroundStyle(CosmosPalette.ink)
                .monospacedDigit()
                .lineLimit(1)
            Text(verbatim: Share.percent(value, of: total))
                .font(.system(size: 16, design: .monospaced))
                .foregroundStyle(CosmosPalette.ink3)
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)
        }
    }

    private var periodDescription: LocalizedStringKey {
        let start = data.summary.start
        switch data.summary.period {
        case .day:
            return "Today · \(start.formatted(.dateTime.locale(locale).month(.abbreviated).day()))"
        case .week:
            let today = Calendar.current.date(byAdding: .day, value: -1, to: data.summary.end) ?? start
            return "This week · \(start.formatted(.dateTime.locale(locale).month(.abbreviated).day()))–\(today.formatted(.dateTime.locale(locale).month(.abbreviated).day()))"
        case .month:
            return "This month · \(start.formatted(.dateTime.locale(locale).year().month(.wide)))"
        case .year:
            return "This year · \(start.formatted(.dateTime.locale(locale).year()))"
        case .all:
            return "All time · since \(start.formatted(.dateTime.locale(locale).year().month(.abbreviated).day()))"
        }
    }
}

struct ShareCardView: View {
    let data: ShareCardData
    let aspect: ShareAspect
    let showCost: Bool
    let showComposition: Bool
    var dimension: BreakdownDimension = .sources
    var liquidView: LiquidView = .confluence
    var lensBuckets: [LensBucket] = []
    var cosmosSnapshot: NSImage?
    var rank: Double? = nil
    var inscription = ""
    var signature = ""

    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var isDark: Bool { scheme == .dark }

    private var usesLensGraphic: Bool {
        liquidView == .lens
    }

    var body: some View {
        if ThemeRuntime.isCosmos {
            CosmosShareCard(
                data: data,
                aspect: aspect,
                showCost: showCost,
                showComposition: showComposition,
                dimension: dimension,
                snapshot: cosmosSnapshot,
                rank: rank
            )
        } else if ThemeRuntime.isField {
            FieldShareCard(
                data: data,
                aspect: aspect,
                showCost: showCost,
                showComposition: showComposition,
                rank: rank,
                inscription: inscription,
                signature: signature
            )
        } else if usesLensGraphic {
            lensCard
        } else {
            tideCard
        }
    }

    // MARK: - Liquid Glass Lens share card

    private var lensCard: some View {
        let snapshot = LensShareSnapshot(
            buckets: lensBuckets,
            data: data,
            dimension: dimension
        )
        let size = aspect.canvasSize

        return ZStack(alignment: .topLeading) {
            ShareLiquidCardBackdrop(
                accentColor: data.accentColor,
                hasUsage: data.counts.total > 0,
                bloomRect: lensBloomRect(for: aspect),
                isDark: isDark,
                reduceTransparency: reduceTransparency
            )

            switch aspect {
            case .portrait:
                lensPortraitContent(snapshot: snapshot, size: size)
            case .square:
                lensSquareContent(snapshot: snapshot, size: size)
            case .landscape:
                lensLandscapeContent(snapshot: snapshot, size: size)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func lensBloomRect(for aspect: ShareAspect) -> CGRect {
        let size = aspect.canvasSize
        switch aspect {
        case .portrait:
            return CGRect(x: 76, y: 640, width: size.width - 152, height: size.height - 716)
        case .square:
            return CGRect(x: 68, y: 460, width: size.width - 136, height: size.height - 524)
        case .landscape:
            let contentWidth = size.width - 152
            let rightWidth = (contentWidth * 0.55).rounded()
            return CGRect(x: size.width - 76 - rightWidth, y: 72, width: rightWidth, height: size.height - 148)
        }
    }

    private func lensPortraitContent(snapshot: LensShareSnapshot, size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 24) {
                wordmarkRow
                Spacer(minLength: 20)
                lensHeaderTimeLabel(snapshot: snapshot)
                    .font(.system(size: 33, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.80)
            }

            headlineRow
                .padding(.top, 32)

            heroBlock(numberSize: 164, unitSize: 82, tokenLabelSize: 38)
                .padding(.top, 12)

            if showCost {
                costRow(amountSize: 38, noteSize: 32)
                    .padding(.top, 10)
            }

            portraitSupportingFacts
                .padding(.top, 24)

            if let rank {
                rankRow(rank)
                    .padding(.top, 18)
            }

            LensShareGraphic(snapshot: snapshot)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 34)

            if showComposition, !compositionParts.isEmpty {
                lensCompositionStrip(compact: false)
                    .padding(.top, 22)
            }

            lensFooterRow(rankFontSize: 22, dateFontSize: 25)
                .padding(.top, 22)
        }
        .padding(.horizontal, 76)
        .padding(.top, 72)
        .padding(.bottom, 24)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func lensSquareContent(snapshot: LensShareSnapshot, size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 20) {
                HStack(alignment: .center, spacing: 11) {
                    ShareBrandLogo(theme: .liquidGlass, size: 48)
                        .accessibilityHidden(true)

                    Text(verbatim: "Token Taken")
                        .font(.system(size: 32, weight: .semibold))
                        .tracking(-0.4)
                        .foregroundStyle(Palette.ink1)
                }

                Spacer(minLength: 16)

                lensHeaderTimeLabel(snapshot: snapshot)
                    .font(.system(size: 29, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.80)
            }

            HStack(alignment: .center, spacing: 14) {
                Circle()
                    .fill(data.accentColor)
                    .frame(width: 17, height: 17)
                    .accessibilityHidden(true)

                data.headlineText(
                    locale: locale,
                    modelFont: .system(size: 29, weight: .semibold, design: .monospaced)
                )
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .truncationMode(.middle)
            }
            .padding(.top, 20)

            heroBlock(numberSize: 120, unitSize: 60, tokenLabelSize: 32)
                .padding(.top, 8)

            if showCost {
                costRow(amountSize: 31, noteSize: 26)
                    .padding(.top, 8)
            }

            lensSquareSupportingFacts
                .padding(.top, 16)

            if let rank {
                Text("Last 30 days · about top \(UsageRank.formatted(rank))")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.80)
                    .padding(.top, 12)
            }

            LensShareGraphic(snapshot: snapshot)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 22)

            if showComposition, !compositionParts.isEmpty {
                lensCompositionStrip(compact: true)
                    .padding(.top, 16)
            }

            lensFooterRow(rankFontSize: 20, dateFontSize: 22)
                .padding(.top, 16)
        }
        .padding(.horizontal, 68)
        .padding(.top, 54)
        .padding(.bottom, 22)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func lensLandscapeContent(snapshot: LensShareSnapshot, size: CGSize) -> some View {
        let hMargin: CGFloat = 76
        let contentWidth = size.width - hMargin * 2
        let rightWidth = (contentWidth * 0.55).rounded()
        let columnGap: CGFloat = 52
        let leftWidth = max(320, contentWidth - rightWidth - columnGap)

        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: columnGap) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        wordmarkRow

                        lensHeaderTimeLabel(snapshot: snapshot)
                            .font(.system(size: 31, weight: .medium))
                            .foregroundStyle(Palette.ink2)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.80)
                    }

                    headlineRow
                        .padding(.top, 38)

                    heroBlock(numberSize: 144, unitSize: 72, tokenLabelSize: 36)
                        .padding(.top, 16)

                    if showCost {
                        costRow(amountSize: 36, noteSize: 30)
                            .padding(.top, 12)
                    }

                    Spacer(minLength: 20)

                    Rectangle()
                        .fill(Palette.hairline)
                        .frame(height: 2)

                    landscapeSupportingFacts
                        .padding(.top, 22)

                    if let rank {
                        rankRow(rank)
                            .padding(.top, 18)
                    }
                }
                .frame(minWidth: leftWidth, maxWidth: leftWidth, maxHeight: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 20) {
                    LensShareGraphic(snapshot: snapshot)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if showComposition, !compositionParts.isEmpty {
                        lensCompositionStrip(compact: true)
                    }
                }
                .frame(minWidth: rightWidth, maxWidth: rightWidth, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            lensFooterRow(rankFontSize: 22, dateFontSize: 25)
                .padding(.top, 24)
        }
        .padding(.horizontal, hMargin)
        .padding(.top, 72)
        .padding(.bottom, 24)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func lensHeaderTimeLabel(snapshot: LensShareSnapshot) -> some View {
        if let frozenTime = snapshot.frozenTimeText(locale: locale) {
            Text(verbatim: String(localized: "Peak · \(frozenTime)", locale: locale))
        } else {
            Text(periodDescription)
        }
    }

    private var lensSquareSupportingFacts: some View {
        HStack(alignment: .top, spacing: 44) {
            ForEach(data.supportingFacts) { fact in
                VStack(alignment: .leading, spacing: 5) {
                    Text(fact.label)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(1)

                    Text(verbatim: fact.value)
                        .font(fact.isMonospacedValue
                            ? .system(size: 30, weight: .semibold, design: .monospaced)
                            : .system(size: 32, weight: .semibold))
                        .foregroundStyle(Palette.ink1)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                        .truncationMode(.middle)
                }
                .layoutPriority(fact.isMonospacedValue ? 0 : 1)
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
        TokenCategory.allCases.compactMap { category in
            let value = data.counts[category]
            return value > 0
                ? CompositionPart(id: category.rawValue, label: category.title, tokens: value, color: Palette.color(for: category))
                : nil
        } + (data.counts.uncategorized > 0
            ? [CompositionPart(id: "uncategorized", label: "Uncategorized", tokens: data.counts.uncategorized, color: Palette.ink3.opacity(0.45))]
            : [])
    }

    private func lensCompositionStrip(compact: Bool) -> some View {
        let total = data.counts.total
        let divisor = max(1, total)
        let parts = compositionParts
        let barHeight: CGFloat = compact ? 12 : 14

        return VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            Canvas { context, size in
                let fullRect = CGRect(origin: .zero, size: size)
                let capsule = Path(roundedRect: fullRect, cornerRadius: barHeight * 0.5, style: .continuous)
                context.fill(capsule, with: .color(Palette.barTrack))

                guard !parts.isEmpty else { return }

                context.drawLayer { layer in
                    layer.clip(to: capsule)
                    let gap: CGFloat = 2.5
                    let totalGaps = CGFloat(max(0, parts.count - 1)) * gap
                    let usable = max(0, size.width - totalGaps)
                    var cursorX: CGFloat = 0

                    for (idx, seg) in parts.enumerated() {
                        let rawW = usable * CGFloat(seg.tokens) / CGFloat(divisor)
                        let w = idx == parts.count - 1
                            ? max(2, size.width - cursorX)
                            : max(2, rawW)
                        let segRect = CGRect(x: cursorX, y: 0, width: w, height: size.height)
                        layer.fill(
                            Path(roundedRect: segRect, cornerRadius: 3, style: .continuous),
                            with: .color(seg.color)
                        )
                        cursorX += w + gap
                    }
                }
            }
            .frame(height: barHeight)
            .accessibilityHidden(true)

            HStack(spacing: compact ? 12 : 18) {
                ForEach(parts) { part in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(part.color)
                            .frame(width: compact ? 9.5 : 11, height: compact ? 9.5 : 11)
                            .accessibilityHidden(true)

                        Text(part.label)
                            .foregroundStyle(Palette.ink2)

                        Text(verbatim: Share.percent(part.tokens, of: total))
                            .fontWeight(.semibold)
                            .foregroundStyle(Palette.ink1)
                            .monospacedDigit()
                    }
                    .font(.system(size: compact ? 19.5 : 22, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                }
            }
        }
    }

    private func lensFooterRow(rankFontSize: CGFloat, dateFontSize: CGFloat) -> some View {
        let dateText = Date.now.formatted(.dateTime.locale(locale).year().month(.abbreviated).day())

        return HStack(alignment: .firstTextBaseline, spacing: 20) {
            if rank != nil {
                Text("Rank is an estimate derived from public usage sources.")
                    .font(.system(size: rankFontSize, weight: .regular))
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
            Text(verbatim: dateText)
                .font(.system(size: dateFontSize, weight: .medium))
                .foregroundStyle(Palette.ink3)
                .monospacedDigit()
                .layoutPriority(1)
        }
    }

    private var tideCard: some View {
        let geometry = TideGeometry(data: data, aspect: aspect, showComposition: showComposition)

        return ZStack(alignment: .topLeading) {
            ShareTideVesselCanvas(
                data: data,
                geometry: geometry,
                showComposition: showComposition,
                isDark: isDark,
                reduceTransparency: reduceTransparency
            )

            switch aspect {
            case .portrait, .square:
                portraitTopContent(geometry: geometry)
            case .landscape:
                landscapeLeftColumn(geometry: geometry)
            }

            if data.isPartialScope {
                brimAndShareCallouts(geometry: geometry)
            }

            if showComposition {
                inlineStrataLabels(geometry: geometry)
            }

            footerDateOverlay(geometry: geometry)
        }
        .frame(width: aspect.canvasSize.width, height: aspect.canvasSize.height)
    }

    // MARK: - Top & side content layouts

    private func portraitTopContent(geometry: TideGeometry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader

            headlineRow
                .padding(.top, 32)

            heroBlock(numberSize: 164, unitSize: 82, tokenLabelSize: 38)
                .padding(.top, 12)

            if showCost {
                costRow(amountSize: 38, noteSize: 32)
                    .padding(.top, 10)
            }

            portraitSupportingFacts
                .padding(.top, 24)

            if let rank {
                rankRow(rank)
                    .padding(.top, 18)
            }
        }
        .padding(.horizontal, geometry.horizontalMargin)
        .padding(.top, geometry.verticalMargin)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func landscapeLeftColumn(geometry: TideGeometry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            landscapeHeader

            headlineRow
                .padding(.top, 38)

            heroBlock(numberSize: 144, unitSize: 72, tokenLabelSize: 36)
                .padding(.top, 16)

            if showCost {
                costRow(amountSize: 36, noteSize: 30)
                    .padding(.top, 12)
            }

            Spacer(minLength: 20)

            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 2)

            landscapeSupportingFacts
                .padding(.top, 22)

            if let rank {
                rankRow(rank)
                    .padding(.top, 18)
            }
        }
        .frame(
            width: geometry.leftColumnWidth,
            height: max(320, geometry.vesselRect.maxY - geometry.verticalMargin),
            alignment: .topLeading
        )
        .offset(x: geometry.horizontalMargin, y: geometry.verticalMargin)
    }

    // MARK: - Header, Scope, Hero, Cost, Supporting Facts

    private var wordmarkRow: some View {
        HStack(alignment: .center, spacing: 12) {
            ShareBrandLogo(theme: .liquidGlass, size: 54)
                .accessibilityHidden(true)

            Text(verbatim: "Token Taken")
                .font(.system(size: 35, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(Palette.ink1)
        }
    }

    private var cardHeader: some View {
        HStack(alignment: .center, spacing: 24) {
            wordmarkRow

            Spacer(minLength: 20)

            Text(periodDescription)
                .font(.system(size: 33, weight: .medium))
                .foregroundStyle(Palette.ink2)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.80)
        }
    }

    private var landscapeHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            wordmarkRow

            Text(periodDescription)
                .font(.system(size: 31, weight: .medium))
                .foregroundStyle(Palette.ink2)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.80)
        }
    }

    private var headlineRow: some View {
        HStack(alignment: .center, spacing: 18) {
            Circle()
                .fill(data.accentColor)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)

            data.headlineText(
                locale: locale,
                modelFont: .system(size: 34, weight: .semibold, design: .monospaced)
            )
            .font(.system(size: 35, weight: .semibold))
            .foregroundStyle(Palette.ink2)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .truncationMode(.middle)
        }
    }

    private func heroBlock(numberSize: CGFloat, unitSize: CGFloat, tokenLabelSize: CGFloat) -> some View {
        let formatted = TokenFormat.short(data.counts.total)
        let (digits, unit) = Self.splitShortTokens(formatted)

        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: digits)
                    .font(.system(size: numberSize, weight: .bold))
                    .tracking(numberSize > 160 ? -5 : -4)
                    .foregroundStyle(Palette.ink1)
                    .monospacedDigit()

                if !unit.isEmpty {
                    Text(verbatim: unit)
                        .font(.system(size: unitSize, weight: .semibold))
                        .tracking(-1.2)
                        .foregroundStyle(Palette.ink1)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.68)

            Text("Token")
                .font(.system(size: tokenLabelSize, weight: .medium))
                .foregroundStyle(Palette.ink2)
                .padding(.leading, 20)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func costRow(amountSize: CGFloat, noteSize: CGFloat) -> some View {
        if data.unpricedTokens > 0, data.unpricedTokens >= data.counts.total {
            Text("No prices for these models")
                .font(.system(size: noteSize, weight: .semibold))
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.80)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(verbatim: TokenFormat.usd(data.estimatedUSD))
                    .font(.system(size: amountSize, weight: .semibold))
                    .foregroundStyle(Palette.ink1)
                    .monospacedDigit()

                Text("estimate, not a bill")
                    .font(.system(size: noteSize, weight: .regular))
                    .foregroundStyle(Palette.ink2)

                if data.unpricedTokens > 0 {
                    Text("\(TokenFormat.short(data.unpricedTokens)) unpriced")
                        .font(.system(size: noteSize - 4, weight: .medium))
                        .foregroundStyle(Palette.ink3)
                        .monospacedDigit()
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
    }

    private var portraitSupportingFacts: some View {
        HStack(alignment: .top, spacing: 56) {
            ForEach(data.supportingFacts) { fact in
                VStack(alignment: .leading, spacing: 8) {
                    Text(fact.label)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(1)

                    Text(verbatim: fact.value)
                        .font(fact.isMonospacedValue
                            ? .system(size: 37, weight: .semibold, design: .monospaced)
                            : .system(size: 40, weight: .semibold))
                        .foregroundStyle(Palette.ink1)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                        .truncationMode(.middle)
                }
                .layoutPriority(fact.isMonospacedValue ? 0 : 1)
            }
        }
    }

    private func rankRow(_ rank: Double) -> some View {
        Text("Last 30 days · about top \(UsageRank.formatted(rank))")
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(Palette.ink2)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var landscapeSupportingFacts: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(data.supportingFacts) { fact in
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    Text(fact.label)
                        .font(.system(size: 29, weight: .medium))
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(1)

                    Spacer(minLength: 12)

                    Text(verbatim: fact.value)
                        .font(fact.isMonospacedValue
                            ? .system(size: 35, weight: .semibold, design: .monospaced)
                            : .system(size: 39, weight: .semibold))
                        .foregroundStyle(Palette.ink1)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                        .truncationMode(.middle)
                }
            }
        }
    }

    // MARK: - Tide Line callouts, inline layer labels & footer

    @ViewBuilder
    private func brimAndShareCallouts(geometry: TideGeometry) -> some View {
        let labelHeight: CGFloat = 36
        let topCalloutBottomY = geometry.vesselRect.minY - 10
        let shareText = Share.percent(data.counts.total, of: data.summary.total.total)
        let meniscusTopY = geometry.meniscusY - geometry.meniscusHeight * 0.5
        let insideHeadspaceClear = meniscusTopY - geometry.brimY >= 68
        let shareBottomY: CGFloat = insideHeadspaceClear
            ? min(meniscusTopY - 12, geometry.innerRect.maxY - 24)
            : topCalloutBottomY
        let shareX: CGFloat = insideHeadspaceClear
            ? geometry.innerRect.minX + 30
            : geometry.vesselRect.minX

        ZStack(alignment: .topLeading) {
            HStack {
                Spacer(minLength: 0)
                brimPeriodTotalText
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(width: geometry.vesselRect.width, height: labelHeight, alignment: .bottomTrailing)
            .offset(x: geometry.vesselRect.minX, y: topCalloutBottomY - labelHeight)

            Text(verbatim: shareText)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Palette.ink2)
                .monospacedDigit()
                .lineLimit(1)
                .frame(height: labelHeight, alignment: .bottomLeading)
                .offset(x: shareX, y: shareBottomY - labelHeight)
        }
    }

    private func inlineStrataLabels(geometry: TideGeometry) -> some View {
        let inlineInsetX: CGFloat = 32
        let inlineWidth = max(120, geometry.innerRect.width - inlineInsetX * 2)

        return ZStack(alignment: .topLeading) {
            ForEach(geometry.bands) { band in
                if let midY = band.inlineMidY {
                    let rowHeight = max(32, min(44, band.maxY - band.minY - 4))
                    HStack(alignment: .firstTextBaseline, spacing: 20) {
                        stratumNameText(band.stratum.label, size: band.nameFontSize)
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .truncationMode(.middle)

                        Spacer(minLength: 14)

                        Text(verbatim: "\(Share.percent(band.stratum.tokens, of: geometry.strataTotalTokens)) · \(TokenFormat.short(band.stratum.tokens))")
                            .font(.system(size: band.valueFontSize, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.95))
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .shadow(color: .black.opacity(reduceTransparency ? 0 : 0.34), radius: 5, x: 0, y: 1.5)
                    .frame(width: inlineWidth, height: rowHeight, alignment: .center)
                    .offset(x: geometry.innerRect.minX + inlineInsetX, y: midY - rowHeight / 2)
                }
            }
        }
    }

    @ViewBuilder
    private func stratumNameText(_ label: ShareCardData.Stratum.Label, size: CGFloat) -> some View {
        switch label {
        case .verbatim(let text, let monospaced):
            Text(verbatim: text)
                .font(monospaced
                    ? .system(size: max(22, size - 1), weight: .semibold, design: .monospaced)
                    : .system(size: max(22, size), weight: .semibold))
        case .localized(let key):
            Text(key)
                .font(.system(size: max(22, size), weight: .semibold))
        }
    }

    private func footerDateOverlay(geometry: TideGeometry) -> some View {
        let dateText = Date.now.formatted(.dateTime.locale(locale).year().month(.abbreviated).day())

        return VStack {
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                if rank != nil {
                    Text("Rank is an estimate derived from public usage sources.")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 0)
                Text(verbatim: dateText)
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(Palette.ink3)
                    .monospacedDigit()
                    .layoutPriority(1)
            }
            .padding(.horizontal, geometry.horizontalMargin)
            .padding(.bottom, geometry.footerBottomPadding)
        }
        .frame(width: geometry.canvasSize.width, height: geometry.canvasSize.height)
    }

    // MARK: - Formatting helpers

    private var periodDescription: LocalizedStringKey {
        let start = data.summary.start
        switch data.summary.period {
        case .day:
            return "Today · \(start.formatted(.dateTime.locale(locale).month(.abbreviated).day()))"
        case .week:
            let today = Calendar.current.date(byAdding: .day, value: -1, to: data.summary.end) ?? start
            return "This week · \(start.formatted(.dateTime.locale(locale).month(.abbreviated).day()))–\(today.formatted(.dateTime.locale(locale).month(.abbreviated).day()))"
        case .month:
            return "This month · \(start.formatted(.dateTime.locale(locale).year().month(.wide)))"
        case .year:
            return "This year · \(start.formatted(.dateTime.locale(locale).year()))"
        case .all:
            return "All time · since \(start.formatted(.dateTime.locale(locale).year().month(.abbreviated).day()))"
        }
    }

    private var brimPeriodTotalText: Text {
        let overall = TokenFormat.short(data.summary.total.total)
        switch data.summary.period {
        case .day:
            return Text("All of today \(overall)")
        case .week:
            return Text("All of this week \(overall)")
        case .month:
            return Text("All of this month \(overall)")
        case .year:
            return Text("All of this year \(overall)")
        case .all:
            return Text("All time \(overall)")
        }
    }

    private static func splitShortTokens(_ formatted: String) -> (digits: String, unit: String) {
        let numericSet: Set<Character> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ".", ",", "-"]
        guard let splitIndex = formatted.firstIndex(where: { !numericSet.contains($0) }) else {
            return (formatted, "")
        }
        return (String(formatted[..<splitIndex]), String(formatted[splitIndex...]))
    }
}

// MARK: - Brand App Icon Logo & Full-Card Tide Vessel Canvas

@MainActor
struct ShareBrandLogo: View {
    let theme: AppTheme
    let size: CGFloat

    private static let defaultAppIcon: NSImage? = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url)
        {
            return image
        }
        return Bundle.main.image(forResource: "AppIcon") ?? NSImage(named: "AppIcon")
    }()

    private var resolvedCGImage: CGImage? {
        let nsImage = ThemeAppIcon.image(for: theme)
            ?? Self.defaultAppIcon
            ?? NSApp?.applicationIconImage
        guard let nsImage else { return nil }

        // Select a high-resolution bitmap cut (>= 256px) directly so offscreen ImageRenderer
        // never picks the 16pt icon cut or drops lazy NSIconRef representations.
        if let bestBitmap = nsImage.representations
            .compactMap({ $0 as? NSBitmapImageRep })
            .filter({ $0.pixelsWide >= 256 && $0.pixelsHigh >= 256 })
            .min(by: { $0.pixelsWide < $1.pixelsWide }),
           let cg = bestBitmap.cgImage
        {
            return cg
        }

        var proposed = CGRect(x: 0, y: 0, width: 256, height: 256)
        return nsImage.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }

    var body: some View {
        Group {
            if let cgImage = resolvedCGImage {
                Image(decorative: cgImage, scale: 1.0)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.224, style: .continuous))
    }
}

private struct ShareTideVesselCanvas: View {
    let data: ShareCardData
    let geometry: TideGeometry
    let showComposition: Bool
    let isDark: Bool
    let reduceTransparency: Bool

    var body: some View {
        Canvas { context, size in
            let fullRect = CGRect(origin: .zero, size: size)

            // 1. Card backdrop & soft warm/cool atmosphere glows.
            if reduceTransparency {
                context.fill(Path(fullRect), with: .color(Palette.solid))
            } else {
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

                if geometry.fillLevel > 0 {
                    let bloomCenter = CGPoint(
                        x: geometry.vesselRect.midX,
                        y: (geometry.meniscusY + geometry.vesselRect.maxY) * 0.5
                    )
                    let bloomRadius = max(geometry.vesselRect.width, geometry.vesselRect.height) * 0.65
                    context.fill(
                        Path(fullRect),
                        with: .radialGradient(
                            Gradient(colors: [
                                data.accentColor.opacity(isDark ? 0.18 : 0.20),
                                .clear,
                            ]),
                            center: bloomCenter,
                            startRadius: 0,
                            endRadius: bloomRadius
                        )
                    )
                }
            }

            // 2. Liquid-glass vessel at card scale.
            LiquidGlassVessel.draw(
                in: &context,
                rect: geometry.vesselRect,
                cornerRadius: geometry.vesselCornerRadius,
                layers: geometry.vesselLayers,
                fillLevel: geometry.fillLevel,
                isDark: isDark,
                reduceTransparency: reduceTransparency
            )

            // 3. Dashed period-total brim line inside the vessel for partial scopes.
            if data.isPartialScope {
                var brimPath = Path()
                brimPath.move(to: CGPoint(x: geometry.innerRect.minX + 18, y: geometry.brimY))
                brimPath.addLine(to: CGPoint(x: geometry.innerRect.maxX - 18, y: geometry.brimY))
                context.stroke(
                    brimPath,
                    with: .color(Palette.ink2.opacity(isDark ? 0.44 : 0.38)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [8, 13])
                )
            }

            // 4. Outer card border rim.
            if !reduceTransparency {
                let rimRect = fullRect.insetBy(dx: 1.5, dy: 1.5)
                context.stroke(
                    Path(rimRect),
                    with: .color(.white.opacity(isDark ? 0.14 : 0.65)),
                    lineWidth: 3
                )
            } else {
                let rimRect = fullRect.insetBy(dx: 1, dy: 1)
                context.stroke(Path(rimRect), with: .color(Palette.hairline), lineWidth: 2)
            }
        }
    }
}

private struct ShareLiquidCardBackdrop: View {
    let accentColor: Color
    let hasUsage: Bool
    let bloomRect: CGRect
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
                let bloomCenter = CGPoint(x: bloomRect.midX, y: bloomRect.midY)
                let bloomRadius = max(bloomRect.width, bloomRect.height) * 0.65
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

// MARK: - Sheet Backdrop & Control Surfaces

private struct ShareSheetBackdrop: View {
    let theme: AppTheme
    let transparency: Double

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var opacity: Double {
        theme == .liquidGlass ? 1 - min(max(transparency, 0), 1) : 1
    }

    private static func baseAlpha(for opacity: Double, isDark: Bool) -> Double {
        let midpoint = isDark ? 0.84 : 0.88
        let value = min(max(opacity, 0), 1)
        return value <= 0.5
            ? midpoint * (value / 0.5)
            : midpoint + (1 - midpoint) * ((value - 0.5) / 0.5)
    }

    var body: some View {
        if theme == .cosmos {
            CosmosPalette.background
        } else if reduceTransparency || theme != .liquidGlass {
            Palette.solid
        } else {
            let isDark = scheme == .dark
            let warm = isDark
                ? Color(.sRGB, red: 186 / 255, green: 114 / 255, blue: 82 / 255, opacity: 0.11)
                : Color(.sRGB, red: 235 / 255, green: 198 / 255, blue: 175 / 255, opacity: 0.22)
            let cool = isDark
                ? Color(.sRGB, red: 84 / 255, green: 124 / 255, blue: 198 / 255, opacity: 0.14)
                : Color(.sRGB, red: 169 / 255, green: 194 / 255, blue: 238 / 255, opacity: 0.25)

            GeometryReader { proxy in
                let radius = max(proxy.size.width, proxy.size.height) * 0.54
                ZStack {
                    Rectangle()
                        .fill(.clear)
                        .glassEffect(in: .rect)
                    Palette.solid
                        .opacity(Self.baseAlpha(for: opacity, isDark: isDark))
                    RadialGradient(
                        colors: [warm, .clear],
                        center: UnitPoint(x: 0.24, y: 0.26),
                        startRadius: 0,
                        endRadius: radius
                    )
                    RadialGradient(
                        colors: [cool, .clear],
                        center: UnitPoint(x: 0.78, y: 0.76),
                        startRadius: 0,
                        endRadius: radius * 1.08
                    )
                }
            }
        }
    }
}

private struct ShareRoundButtonSurface: ViewModifier {
    let reduceTransparency: Bool
    let isCosmos: Bool

    func body(content: Content) -> some View {
        if isCosmos {
            content
                .background(Rectangle().fill(CosmosPalette.panel))
                .overlay(Rectangle().strokeBorder(CosmosPalette.controlRule, lineWidth: 1))
        } else if reduceTransparency {
            content
                .background { Circle().fill(Palette.cardSurface) }
                .overlay { Circle().strokeBorder(Palette.hairline, lineWidth: 1) }
        } else {
            content
                .themedGlass(.regular.interactive(), in: .circle)
        }
    }
}

private struct SharePillSurface: ViewModifier {
    let isSelected: Bool
    let reduceTransparency: Bool
    let isCosmos: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
        if isCosmos {
            content
                .background(Rectangle().fill(isSelected ? CosmosPalette.selection : CosmosPalette.panel))
                .overlay(Rectangle().strokeBorder(CosmosPalette.controlRule, lineWidth: 1))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isSelected ? CosmosPalette.accent : Color.clear)
                        .frame(height: 2)
                }
        } else if reduceTransparency {
            content
                .background { shape.fill(isSelected ? Palette.cardSurface : Palette.barTrack) }
                .overlay {
                    shape.strokeBorder(
                        isSelected ? Palette.roleAccent.opacity(0.55) : Palette.hairline,
                        lineWidth: 1
                    )
                }
        } else {
            content
                .themedGlass(.regular.interactive(), in: .rect(cornerRadius: Radius.inner))
                .overlay {
                    if isSelected {
                        shape.strokeBorder(Palette.roleAccent.opacity(0.45), lineWidth: 1)
                    }
                }
        }
    }
}

private struct ShareSegmentSurface: ViewModifier {
    let isSelected: Bool
    let reduceTransparency: Bool
    let namespace: Namespace.ID
    let effectID: String
    let isCosmos: Bool

    func body(content: Content) -> some View {
        if isCosmos {
            content
                .background(Rectangle().fill(isSelected ? CosmosPalette.selection : Color.clear))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isSelected ? CosmosPalette.accent : Color.clear)
                        .frame(height: 2)
                }
        } else if !isSelected {
            content
        } else if reduceTransparency {
            content
                .background { Capsule().fill(Palette.cardSurface) }
                .overlay { Capsule().strokeBorder(Palette.hairline, lineWidth: 1) }
        } else {
            content
                .themedGlass(.regular.interactive(), in: .capsule)
                .glassEffectID(effectID, in: namespace)
        }
    }
}

private struct CosmosShareToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Rectangle()
                    .fill(configuration.isOn ? CosmosPalette.accent : CosmosPalette.track)
                    .overlay(Rectangle().strokeBorder(CosmosPalette.controlRule, lineWidth: 1))
                Rectangle()
                    .fill(configuration.isOn ? CosmosPalette.page : CosmosPalette.ink2)
                    .frame(width: 14, height: 14)
                    .padding(3)
            }
            .frame(width: 36, height: 20)
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Toggle(configuration)
                .toggleStyle(.switch)
        }
    }
}

private struct ShareActionButtonSurface: ViewModifier {
    let isProminent: Bool
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
        if reduceTransparency {
            content
                .background {
                    shape.fill(isProminent ? Palette.roleAccent.opacity(0.18) : Palette.cardSurface)
                }
                .overlay {
                    shape.strokeBorder(
                        isProminent ? Palette.roleAccent : Palette.hairline,
                        lineWidth: 1
                    )
                }
        } else if isProminent {
            content
                .background { shape.fill(Palette.roleAccent.opacity(0.14)) }
                .themedGlass(.regular.interactive(), in: .rect(cornerRadius: Radius.inner))
                .overlay {
                    shape.strokeBorder(Palette.roleAccent.opacity(0.45), lineWidth: 1)
                }
        } else {
            content
                .themedGlass(.regular.interactive(), in: .rect(cornerRadius: Radius.inner))
        }
    }
}

@MainActor
private final class SharePickerAnchor {
    weak var view: NSView?
}

private struct SharePickerAnchorRepresentable: NSViewRepresentable {
    let anchor: SharePickerAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
