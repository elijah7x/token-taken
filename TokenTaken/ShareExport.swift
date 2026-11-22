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
    ShareCardMetrics.visualSize(for: aspect)
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
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var previewPeriod: Period?
    @State private var scope: ShareScope = .overall
    @State private var aspect: ShareAspect = .portrait
    @State private var detail: ShareCardDetail = .top3
    @State private var showCost = false
    @State private var showRank = true
    @State private var showInscription = true
    @State private var showSignature = true
    // Field share cards only; kept for this sheet, never saved or synced.
    @State private var inscription = ""
    @State private var didSeedInscription = false
    @State private var signature = ""
    @State private var previewSummary: UsageSummary?
    @State private var scopedSummary: UsageSummary?
    @State private var previewLensBuckets: [LensBucket] = []
    @State private var loadedScopeKey: SnapshotQueryKey?
    @State private var rankTopPercent: Double?
    @State private var snapshotUnavailable = false
    @State private var cosmosSnapshot: NSImage?
    @State private var renderedCosmosSnapshotKey: CosmosShareSnapshotKey?
    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var shareAnchor = SharePickerAnchor()
    @State private var exportError: String?

    @Namespace private var periodNamespace
    @Namespace private var aspectNamespace
    @Namespace private var detailNamespace
    @FocusState private var focusedPeriod: Period?
    @FocusState private var focusedAspect: ShareAspect?
    @FocusState private var focusedDetail: ShareCardDetail?
    @FocusState private var focusedTextField: SheetTextField?

    private enum SheetTextField: Hashable {
        case inscription
        case signature
    }

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
    private var isField: Bool { settings.theme == .field }
    private var isLiquidLens: Bool { settings.theme == .liquidGlass && settings.liquidView == .lens }

    private var availableAspects: [ShareAspect] {
        ShareAspect.allCases
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
        showInscription ? inscription : ""
    }

    private var activeSignature: String {
        showSignature ? signature : ""
    }

    private var displayedRank: Double? {
        guard showRank, loadedScopeKey == snapshotQueryKey else { return nil }
        return rankTopPercent
    }

    var body: some View {
        HStack(spacing: 0) {
            previewPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)

            Rectangle()
                .fill(Palette.hairline)
                .frame(width: 1)
                .padding(.vertical, 20)

            controlColumn
                .frame(width: 308)
                .padding(20)
                .background(isCosmos ? CosmosPalette.background : Color.clear)
        }
        .frame(width: 980, height: 656)
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
            seedFieldInscriptionIfNeeded()
            focusedTextField = nil
        }
        .onChange(of: settings.theme) { _, _ in
            seedFieldInscriptionIfNeeded()
            focusedTextField = nil
        }
        .onChange(of: snapshotQueryKey, initial: true) { _, key in
            let resolved = resolveShareSnapshot(for: key)
            previewSummary = resolved.summary
            scopedSummary = resolved.scopedSummary
            previewLensBuckets = resolved.lensBuckets
            rankTopPercent = resolved.rank
            snapshotUnavailable = resolved.dataUnavailable
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

    private func seedFieldInscriptionIfNeeded() {
        guard ThemeKind.current == .field, !didSeedInscription else { return }
        didSeedInscription = true
        inscription = ShareInscriptions.random(for: settings.theme, locale: locale) ?? ""
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
            let availableWidth = max(1, proxy.size.width)
            let availableHeight = max(1, proxy.size.height)
            let scale = min(availableWidth / canvasSize.width, availableHeight / canvasSize.height)
            let scaledWidth = canvasSize.width * scale
            let scaledHeight = canvasSize.height * scale
            let cornerRadius = isCosmos ? 0 : max(12, 36 * scale)

            ShareCardView(
                data: cardData,
                aspect: effectiveAspect,
                showCost: showCost,
                detail: detail,
                theme: settings.theme,
                dimension: dimension,
                liquidView: settings.liquidView,
                lensBuckets: currentLensBuckets,
                cosmosSnapshot: currentCosmosSnapshot,
                rank: displayedRank,
                inscription: activeInscription,
                signature: activeSignature,
                dataUnavailable: snapshotUnavailable
            )
            .frame(width: canvasSize.width, height: canvasSize.height)
            .scaleEffect(scale, anchor: .center)
            .frame(width: scaledWidth, height: scaledHeight)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isCosmos ? CosmosPalette.controlRule : Palette.hairline, lineWidth: 1)
            }
            .shadow(
                color: isCosmos ? .clear : .black.opacity(reduceTransparency ? 0 : (scheme == .dark ? 0.34 : 0.10)),
                radius: 18,
                x: 0,
                y: 6
            )
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: effectiveAspect)
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
                        .foregroundStyle(Palette.ink2)
                        .frame(width: 24, height: 24)
                        .modifier(ShareRoundButtonSurface(
                            reduceTransparency: reduceTransparency,
                            isCosmos: isCosmos,
                            isField: isField
                        ))
                        .contentShape(isCosmos
                            ? AnyShape(Rectangle())
                            : (isField ? AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous)) : AnyShape(Circle())))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help(Text("Close (Esc)"))
                .accessibilityLabel(Text("Close"))
            }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scope")
                            .font(ThemeFont.make(12, weight: .semibold))
                            .foregroundStyle(Palette.ink2)

                        scopePicker
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Aspect")
                            .font(ThemeFont.make(12, weight: .semibold))
                            .foregroundStyle(Palette.ink2)

                        aspectSegmentedControl
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Detail")
                            .font(ThemeFont.make(12, weight: .semibold))
                            .foregroundStyle(Palette.ink2)

                        detailSegmentedControl
                    }

                    Rectangle()
                        .fill(Palette.hairline)
                        .frame(height: 1)

                    VStack(spacing: 8) {
                        shareToggleRow(title: "Show cost estimate", isOn: $showCost)
                        shareToggleRow(title: "Show rank", isOn: $showRank)
                        if ThemeKind.current == .field {
                            shareToggleRow(title: "Inscription", isOn: $showInscription)
                            if showInscription {
                                HStack(spacing: 6) {
                                    fieldTextRow("A short note", text: $inscription, limit: ShareInscriptions.maxLength, field: .inscription)
                                    Button {
                                        if let next = ShareInscriptions.random(for: settings.theme, locale: locale, excluding: inscription) {
                                            inscription = next
                                        }
                                    } label: {
                                        Image(systemName: "shuffle")
                                            .font(.system(size: 11.5, weight: .medium))
                                            .foregroundStyle(Palette.ink2)
                                            .frame(width: 28, height: 28)
                                    }
                                    .buttonStyle(FieldButtonStyle(horizontalPadding: 0, verticalPadding: 0))
                                    .help(Text("New inscription"))
                                    .accessibilityLabel(Text("New inscription"))
                                }
                            }
                            shareToggleRow(title: "Signature", isOn: $showSignature)
                            if showSignature {
                                fieldTextRow("Your name", text: $signature, limit: 24, field: .signature)
                            }
                        }
                    }
                }
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity, alignment: .top)

            VStack(spacing: 10) {
                if snapshotUnavailable {
                    Text("Usage for this period could not be loaded, so it can't be shared yet.")
                        .font(ThemeFont.make(11))
                        .foregroundStyle(Palette.healthWarn)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
                .disabled(snapshotUnavailable)

                sharePickerButton
                    .disabled(snapshotUnavailable)
            }
        }
    }

    private func fieldTextRow(
        _ title: LocalizedStringKey,
        text: Binding<String>,
        limit: Int,
        field: SheetTextField
    ) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.plain)
            .focused($focusedTextField, equals: field)
            .font(ThemeFont.make(13))
            .foregroundStyle(Palette.ink1)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FieldPalette.panel))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(FieldPalette.rule, lineWidth: 1))
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
                .font(ThemeFont.make(13, weight: .medium))
                .foregroundStyle(Palette.ink1)
                .lineLimit(1)
                .accessibilityHidden(true)

            Spacer(minLength: 8)

            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(GlassToggleStyle())
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
                ForEach(Array(Period.allCases.enumerated()), id: \.element.id) { index, option in
                    periodSegment(option, index: index)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Usage period"))
    }

    private func periodSegment(_ option: Period, index: Int) -> some View {
        let isSelected = activePeriod == option
        return Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                previewPeriod = option
            }
        } label: {
            Text(periodTitle(option))
                .font(ThemeFont.make(11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Palette.ink1 : Palette.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .padding(.horizontal, 3)
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(isCosmos
                    ? AnyShape(Rectangle())
                    : (isField ? AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous)) : AnyShape(Capsule())))
                .modifier(ShareSegmentSurface(
                    isSelected: isSelected,
                    reduceTransparency: reduceTransparency,
                    namespace: periodNamespace,
                    effectID: "sharePeriod",
                    isCosmos: isCosmos,
                    isField: isField,
                    showLeadingDivider: index > 0
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
                        .font(ThemeFont.make(12, weight: .semibold))
                        .foregroundStyle(Palette.ink1)
                        .lineLimit(1)
                } else {
                    Text("All harnesses")
                        .font(ThemeFont.make(12, weight: .medium))
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Palette.ink3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .modifier(SharePillSurface(
                isSelected: isSelected,
                reduceTransparency: reduceTransparency,
                isCosmos: isCosmos,
                isField: isField
            ))
            .contentShape(isCosmos
                ? AnyShape(Rectangle())
                : AnyShape(RoundedRectangle(cornerRadius: isField ? 8 : Radius.inner, style: .continuous)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .tint(Palette.roleAccent)
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
                        .font(ThemeFont.make(11.5, weight: .semibold, numeric: true))
                        .foregroundStyle(Palette.ink1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("All models")
                        .font(ThemeFont.make(12, weight: .medium))
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Palette.ink3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .modifier(SharePillSurface(
                isSelected: isSelected,
                reduceTransparency: reduceTransparency,
                isCosmos: isCosmos,
                isField: isField
            ))
            .contentShape(isCosmos
                ? AnyShape(Rectangle())
                : AnyShape(RoundedRectangle(cornerRadius: isField ? 8 : Radius.inner, style: .continuous)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .tint(Palette.roleAccent)
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
        } else if isField {
            content()
                .padding(2)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FieldPalette.paper))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(FieldPalette.rule, lineWidth: 1))
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
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    aspectSegment(option, index: index)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Aspect ratio"))
    }

    private func aspectSegment(_ option: ShareAspect, index: Int) -> some View {
        let isSelected = effectiveAspect == option
        return Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                aspect = option
            }
        } label: {
            Text(option.title)
                .font(ThemeFont.make(12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Palette.ink1 : Palette.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 30)
                .contentShape(isCosmos
                    ? AnyShape(Rectangle())
                    : (isField ? AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous)) : AnyShape(Capsule())))
                .modifier(ShareSegmentSurface(
                    isSelected: isSelected,
                    reduceTransparency: reduceTransparency,
                    namespace: aspectNamespace,
                    effectID: "shareAspect",
                    isCosmos: isCosmos,
                    isField: isField,
                    showLeadingDivider: index > 0
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

    // MARK: - Detail segmented control

    private var detailSegmentedControl: some View {
        let options = ShareCardDetail.allCases
        return segmentedContainer {
            HStack(spacing: isCosmos ? 0 : 2) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    detailSegment(option, index: index)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Detail"))
    }

    private func detailSegment(_ option: ShareCardDetail, index: Int) -> some View {
        let isSelected = detail == option
        return Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                detail = option
            }
        } label: {
            Text(option.title)
                .font(ThemeFont.make(12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Palette.ink1 : Palette.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 30)
                .contentShape(isCosmos
                    ? AnyShape(Rectangle())
                    : (isField ? AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous)) : AnyShape(Capsule())))
                .modifier(ShareSegmentSurface(
                    isSelected: isSelected,
                    reduceTransparency: reduceTransparency,
                    namespace: detailNamespace,
                    effectID: "shareDetail",
                    isCosmos: isCosmos,
                    isField: isField,
                    showLeadingDivider: index > 0
                ))
        }
        .buttonStyle(.plain)
        .focused($focusedDetail, equals: option)
        .onKeyPress(.leftArrow) {
            moveDetail(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            moveDetail(by: 1)
            return .handled
        }
        .accessibilityLabel(Text(option.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func moveDetail(by offset: Int) {
        let options = ShareCardDetail.allCases
        guard let index = options.firstIndex(of: detail) else { return }
        let nextIndex = min(max(index + offset, 0), options.count - 1)
        detail = options[nextIndex]
        focusedDetail = detail
    }

    // MARK: - Action buttons

    private func actionButtonLabel(title: LocalizedStringKey, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.ink2)
                .accessibilityHidden(true)
            Text(title)
                .font(ThemeFont.make(12.5, weight: .medium))
                .foregroundStyle(Palette.ink1)
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
        } else if isField {
            Button(action: action) {
                actionButtonLabel(title: title, symbol: symbol)
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
            }
            .buttonStyle(FieldButtonStyle())
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
                .foregroundStyle(Palette.roleAccent)
                .accessibilityHidden(true)
            Text("Share…")
                .font(ThemeFont.make(13, weight: .semibold))
                .foregroundStyle(Palette.ink1)
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
                .overlay(Rectangle().stroke(CosmosPalette.accent, lineWidth: 1))
            } else if isField {
                Button(action: presentSharePicker) {
                    shareButtonLabel
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                }
                .buttonStyle(FieldButtonStyle())
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(FieldPalette.accent, lineWidth: 1))
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
        /// True when the period's usage could not be loaded and `summary` is a placeholder, not real data.
        var dataUnavailable = false
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

    private func fallbackSummary(for period: Period) -> (summary: UsageSummary, matchesCachedData: Bool) {
        if period == model.summary.period {
            return (model.summary, true)
        }
        if period == model.todaySummary.period {
            return (model.todaySummary, true)
        }
        if let empty = try? UsageAggregator(
            store: EmptyShareUsageStore(devices: model.summary.devices),
            now: .now
        ).summary(for: period) {
            return (empty, false)
        }
        return (model.summary, false)
    }

    /// Queries summary, scoped summary, lens buckets, and 30-day rank from a single preload and query-time `now`.
    private func resolveShareSnapshot(for key: SnapshotQueryKey) -> ResolvedShareSnapshot {
        guard let context = resolveBaseStore(),
              let rows = try? UsageAggregator.preload(context.store) else {
            let fallback = fallbackSummary(for: key.period)
            return ResolvedShareSnapshot(
                summary: fallback.summary,
                scopedSummary: nil,
                lensBuckets: key.isLiquidLens && fallback.matchesCachedData ? model.lensBuckets(for: key.period) : [],
                rank: nil,
                dataUnavailable: !fallback.matchesCachedData
            )
        }

        let cachedStore = PreloadedUsageStore(rows: rows)
        let aggregator = UsageAggregator(
            store: cachedStore,
            rows: rows,
            now: context.now,
            priceTable: context.priceTable
        )
        let queriedSummary = try? aggregator.summary(for: key.period)
        let fallback = queriedSummary == nil ? fallbackSummary(for: key.period) : nil
        let resolvedSummary = queriedSummary ?? fallback!.summary
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
            rank: resolvedRank,
            dataUnavailable: fallback.map { !$0.matchesCachedData } ?? false
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
                rank: rankTopPercent,
                dataUnavailable: snapshotUnavailable
            )
        } else {
            resolved = resolveShareSnapshot(for: queryKey)
        }
        // Never export placeholder numbers as if they were this period's usage.
        guard !resolved.dataUnavailable else { return nil }
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
            detail: detail,
            theme: settings.theme,
            dimension: dimension,
            liquidView: settings.liquidView,
            lensBuckets: exportLensBuckets,
            cosmosSnapshot: exportCosmosSnapshot,
            rank: resolvedRank,
            inscription: activeInscription,
            signature: activeSignature,
            dataUnavailable: false,
            reduceTransparencyOverride: reduceTransparency,
            colorSchemeContrastOverride: colorSchemeContrast
        )
        .frame(width: canvasSize.width, height: canvasSize.height)
        .environment(\.colorScheme, settings.theme == .cosmos ? .dark : scheme)
        .environment(\.locale, locale)
        .fontDesign(settings.theme == .field ? .serif : nil)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        renderer.proposedSize = ProposedViewSize(canvasSize)

        let isDarkExport = settings.theme == .cosmos || scheme == .dark
        let appearanceName: NSAppearance.Name = if colorSchemeContrast == .increased {
            isDarkExport ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua
        } else {
            isDarkExport ? .darkAqua : .aqua
        }
        let targetAppearance = NSAppearance(named: appearanceName)
            ?? NSAppearance(named: isDarkExport ? .darkAqua : .aqua)
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

private struct EmptyShareUsageStore: UsageStore {
    let devices: [Device]
    func records() -> [UsageRecord] { [] }
    func hourly() -> [HourlyUsage] { [] }
}

// MARK: - Card Data

struct ShareCardData {
    enum Kind {
        case overall
        case source(id: String, name: String)
        case model(id: String, name: String)
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
    static let mergedStratumColor = Color(light: "#6E7D92", dark: "#8494AB")

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

    func periodDescription(locale: Locale) -> LocalizedStringKey {
        let start = summary.start
        switch summary.period {
        case .day:
            return "Today · \(start.formatted(.dateTime.locale(locale).month(.abbreviated).day()))"
        case .week:
            let today = Calendar.current.date(byAdding: .day, value: -1, to: summary.end) ?? start
            return "This week · \(start.formatted(.dateTime.locale(locale).month(.abbreviated).day()))–\(today.formatted(.dateTime.locale(locale).month(.abbreviated).day()))"
        case .month:
            return "This month · \(start.formatted(.dateTime.locale(locale).year().month(.wide)))"
        case .year:
            return "This year · \(start.formatted(.dateTime.locale(locale).year()))"
        case .all:
            return "All time · since \(start.formatted(.dateTime.locale(locale).year().month(.abbreviated).day()))"
        }
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
    func unmergedStrata(dimension: BreakdownDimension) -> [Stratum] {
        switch kind {
        case .overall:
            switch dimension {
            case .sources:
                return activeSources.map { source in
                    Stratum(
                        id: source.id,
                        label: .verbatim(source.name, monospaced: false),
                        tokens: source.counts.total,
                        color: Palette.color(forSource: source.id)
                    )
                }
            case .models:
                let models = activeModels
                let palette = Palette.modelColors(for: summary.byModel.map(\.id))
                return models.map { item in
                    Stratum(
                        id: item.id,
                        label: .verbatim(item.name, monospaced: true),
                        tokens: item.counts.total,
                        color: palette[item.id] ?? Palette.color(for: .output)
                    )
                }
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
        strata(dimension: .sources)
    }

    func strata(dimension: BreakdownDimension) -> [Stratum] {
        let limit = switch kind {
        case .overall: 5
        case .source, .model: 4
        }
        return Self.mergeTail(unmergedStrata(dimension: dimension), limit: limit)
    }

    var activeSourceCount: Int {
        activeSources.count
    }

    var activeModelCount: Int {
        activeModels.count
    }

    func detailDimension(for mainDimension: BreakdownDimension) -> BreakdownDimension {
        switch kind {
        case .overall: mainDimension
        case .source: .models
        case .model: .sources
        }
    }

    func rankedItems(dimension mainDimension: BreakdownDimension) -> [Breakdown] {
        let sceneSummary = cosmosSceneSummary
        let resolved = detailDimension(for: mainDimension)
        let raw = resolved == .sources ? sceneSummary.bySource : sceneSummary.byModel
        return raw
            .filter { $0.counts.total > 0 }
            .sorted { $0.counts.total > $1.counts.total }
    }

    /// Abbreviated period headline for L2 context, e.g. "Used in Nov" / "11 月用了".
    func shortPeriodHeadline(locale: Locale) -> String {
        switch summary.period {
        case .day:
            return String(localized: "Used today", locale: locale)
        case .week:
            return String(localized: "Used this week", locale: locale)
        case .month:
            let month = shortMonthLabel(locale: locale)
            return String(localized: "Used in \(month)", locale: locale)
        case .year:
            let year = String(Calendar.current.component(.year, from: summary.start))
            return String(localized: "Used in \(year) so far", locale: locale)
        case .all:
            return String(localized: "Used in total", locale: locale)
        }
    }

    /// Merged headline and scope counts for overall L2 context, e.g. "Used in Nov · 10 tools · 29 models".
    func overallContextText(locale: Locale) -> String {
        let headline = shortPeriodHeadline(locale: locale)
        let sourceCount = activeSourceCount
        let modelCount = activeModelCount
        guard sourceCount > 0 || modelCount > 0 else { return headline }
        let tools = String(localized: "\(sourceCount) tools", locale: locale)
        let models = String(localized: "\(modelCount) models", locale: locale)
        return "\(headline) · \(tools) · \(models)"
    }

    /// Scoped period share for L2 context, e.g. "33.6% of Nov" / "占 11 月 33.6%".
    func scopedShareDescription(locale: Locale) -> String {
        let share = Share.percent(counts.total, of: summary.total.total, locale: locale)
        switch summary.period {
        case .day:
            return String(localized: "\(share) of today", locale: locale)
        case .week:
            return String(localized: "\(share) of this week", locale: locale)
        case .month:
            let month = shortMonthLabel(locale: locale)
            return String(localized: "\(share) of \(month)", locale: locale)
        case .year:
            let yearNumber = Calendar.current.component(.year, from: summary.start)
            let year = locale.language.languageCode == .chinese ? "\(yearNumber) 年" : String(yearNumber)
            return String(localized: "\(share) of \(year)", locale: locale)
        case .all:
            return String(localized: "\(share) of all time", locale: locale)
        }
    }

    private func shortMonthLabel(locale: Locale) -> String {
        if locale.language.languageCode == .chinese {
            return "\(Calendar.current.component(.month, from: summary.start)) 月"
        }
        return summary.start.formatted(.dateTime.locale(locale).month(.abbreviated))
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

// MARK: - Unified Share Card View

@MainActor
struct ShareCardView: View {
    let data: ShareCardData
    let aspect: ShareAspect
    let showCost: Bool
    var detail: ShareCardDetail = .top3
    var theme: AppTheme = .liquidGlass
    var dimension: BreakdownDimension = .sources
    var liquidView: LiquidView = .confluence
    var lensBuckets: [LensBucket] = []
    var cosmosSnapshot: NSImage?
    var rank: Double? = nil
    var inscription = ""
    var signature = ""
    var dataUnavailable = false
    var reduceTransparencyOverride: Bool? = nil
    var colorSchemeContrastOverride: ColorSchemeContrast? = nil

    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var isDark: Bool { scheme == .dark }
    private var effectiveReduceTransparency: Bool { reduceTransparencyOverride ?? reduceTransparency }
    private var effectiveContrast: ColorSchemeContrast { colorSchemeContrastOverride ?? contrast }

    private static let cosmosCategoryColors: [TokenCategory: Color] = [
        .cacheRead: Color(hex: "#EAF2FF"),
        .input: Color(hex: "#FFF0D2"),
        .cacheWrite: Color(hex: "#E8C48E"),
        .output: Color(hex: "#D99A56"),
        .reasoning: Color(hex: "#B65A35"),
    ]

    private static let fieldInk2 = Color(
        light: "#55524A",
        dark: "#C4BDAB",
        contrastLight: "#33312B",
        contrastDark: "#E4DEC9"
    )

    private static let fieldCategoryOrder: [TokenCategory] = [
        .cacheRead, .input, .cacheWrite, .output, .reasoning,
    ]

    var body: some View {
        switch theme {
        case .cosmos:
            ShareCardLayout(
                data: data,
                aspect: aspect,
                dimension: dimension,
                detail: detail,
                showCost: showCost,
                rank: rank,
                inscription: inscription,
                signature: signature,
                dataUnavailable: dataUnavailable,
                reduceTransparency: effectiveReduceTransparency,
                skin: ShareCardSkin(
                    theme: .cosmos,
                    pageColor: CosmosPalette.page,
                    panelColor: CosmosPalette.background,
                    ink1: CosmosPalette.ink,
                    ink2: CosmosPalette.ink2,
                    ink3: CosmosPalette.ink3,
                    accent: CosmosPalette.accent,
                    rule: CosmosPalette.controlRule,
                    barTrack: CosmosPalette.track,
                    categoryOrder: CosmosScene.categoryOrder,
                    categoryColors: Self.cosmosCategoryColors,
                    uncategorizedColor: Color(hex: "#8A93A3"),
                    cornerRadius: 0,
                    showsSeriesSwatches: false,
                    fullBleedVisual: true,
                    usesLiquidAtmosphere: false
                ) {
                    CosmosPalette.page
                        .overlay {
                            if let cosmosSnapshot {
                                Image(nsImage: cosmosSnapshot)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            }
                        }
                }
            )

        case .field:
            let fieldCategoryColors = Dictionary(uniqueKeysWithValues: TokenCategory.allCases.map {
                ($0, FieldCrop.color(for: $0))
            })
            let fieldItems = data.rankedItems(dimension: dimension)
            let fieldCornerRadius = RadiusRole.card.value
            ShareCardLayout(
                data: data,
                aspect: aspect,
                dimension: dimension,
                detail: detail,
                showCost: showCost,
                rank: rank,
                inscription: inscription,
                signature: signature,
                dataUnavailable: dataUnavailable,
                reduceTransparency: effectiveReduceTransparency,
                skin: ShareCardSkin(
                    theme: .field,
                    pageColor: FieldPalette.paper,
                    panelColor: FieldPalette.panel,
                    ink1: FieldPalette.ink,
                    ink2: Self.fieldInk2,
                    ink3: FieldPalette.muted,
                    accent: FieldPalette.accent,
                    rule: FieldPalette.rule,
                    barTrack: FieldPalette.rule.opacity(0.45),
                    categoryOrder: Self.fieldCategoryOrder,
                    categoryColors: fieldCategoryColors,
                    uncategorizedColor: FieldPalette.muted.opacity(0.55),
                    cornerRadius: fieldCornerRadius,
                    showsSeriesSwatches: true,
                    fullBleedVisual: false,
                    usesLiquidAtmosphere: false
                ) {
                    if dataUnavailable || (fieldItems.isEmpty && data.isPartialScope && data.counts.total > 0) {
                        RoundedRectangle(cornerRadius: fieldCornerRadius, style: .continuous)
                            .fill(FieldPalette.panel)
                            .overlay {
                                RoundedRectangle(cornerRadius: fieldCornerRadius, style: .continuous)
                                    .strokeBorder(FieldPalette.rule, lineWidth: 1)
                            }
                            .overlay {
                                Text("Breakdown unavailable")
                                    .font(ThemeFont.make(aspect == .square ? 26 : 28, weight: .medium))
                                    .foregroundStyle(FieldPalette.muted)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        GeometryReader { proxy in
                            let slotSize = proxy.size
                            let sceneAspect = FieldSceneModel.size.width / FieldSceneModel.size.height
                            // Aspect-fill the slot and bleed past FieldLandscapeView's internal 1pt border and corners.
                            let fillWidth = max(slotSize.width, slotSize.height * sceneAspect) + 4
                            let fillHeight = fillWidth / sceneAspect

                            FieldLandscapeView(
                                items: fieldItems,
                                highlight: .constant(nil),
                                interactive: false,
                                compact: true
                            )
                            .frame(width: fillWidth, height: fillHeight)
                            .position(x: slotSize.width / 2, y: slotSize.height / 2)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: fieldCornerRadius, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: fieldCornerRadius, style: .continuous)
                                .strokeBorder(FieldPalette.rule, lineWidth: 1)
                        }
                    }
                }
            )

        case .liquidGlass:
            let liquidCategoryColors = Dictionary(uniqueKeysWithValues: TokenCategory.allCases.map {
                ($0, Palette.color(for: $0))
            })
            let uncategorized = Palette.ink3.opacity(effectiveContrast == .increased ? 0.80 : 0.45)
            ShareCardLayout(
                data: data,
                aspect: aspect,
                dimension: dimension,
                detail: detail,
                showCost: showCost,
                rank: rank,
                inscription: inscription,
                signature: signature,
                dataUnavailable: dataUnavailable,
                reduceTransparency: effectiveReduceTransparency,
                skin: ShareCardSkin(
                    theme: .liquidGlass,
                    pageColor: Palette.solid,
                    panelColor: Palette.cardSurface,
                    ink1: Palette.ink1,
                    ink2: Palette.ink2,
                    ink3: Palette.ink3,
                    accent: Palette.roleAccent,
                    rule: Palette.hairline,
                    barTrack: Palette.barTrack,
                    categoryOrder: TokenCategory.allCases,
                    categoryColors: liquidCategoryColors,
                    uncategorizedColor: uncategorized,
                    cornerRadius: RadiusRole.card.value,
                    showsSeriesSwatches: true,
                    fullBleedVisual: false,
                    usesLiquidAtmosphere: true
                ) {
                    if liquidView == .lens {
                        LensShareGraphic(
                            buckets: lensBuckets,
                            data: data,
                            dimension: dimension,
                            reduceTransparencyOverride: effectiveReduceTransparency,
                            colorSchemeContrastOverride: effectiveContrast
                        )
                    } else {
                        ShareTideVesselVisual(
                            data: data,
                            dimension: dimension,
                            isDark: isDark,
                            reduceTransparency: effectiveReduceTransparency,
                            increasedContrast: effectiveContrast == .increased
                        )
                    }
                },
                peakText: liquidView == .lens
                    ? LensShareSnapshot(buckets: lensBuckets, data: data, dimension: dimension).frozenTimeText(locale: locale)
                    : nil
            )
        }
    }
}

// MARK: - Brand App Icon Logo

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
        } else if theme == .field {
            FieldPalette.paper
        } else if reduceTransparency {
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
    let isField: Bool

    func body(content: Content) -> some View {
        if isCosmos {
            content
                .background(Rectangle().fill(CosmosPalette.panel))
                .overlay(Rectangle().strokeBorder(CosmosPalette.controlRule, lineWidth: 1))
        } else if isField {
            content
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FieldPalette.panel))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(FieldPalette.rule, lineWidth: 1))
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
    let isField: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: isField ? 8 : Radius.inner, style: .continuous)
        if isCosmos {
            content
                .background(Rectangle().fill(isSelected ? CosmosPalette.selection : CosmosPalette.panel))
                .overlay(Rectangle().strokeBorder(CosmosPalette.controlRule, lineWidth: 1))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isSelected ? CosmosPalette.accent : Color.clear)
                        .frame(height: 2)
                }
        } else if isField {
            content
                .background { shape.fill(FieldPalette.panel) }
                .overlay {
                    shape.strokeBorder(
                        isSelected ? FieldPalette.accent : FieldPalette.rule,
                        lineWidth: 1
                    )
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
    let isField: Bool
    let showLeadingDivider: Bool

    func body(content: Content) -> some View {
        if isCosmos {
            content
                .background(Rectangle().fill(isSelected ? CosmosPalette.selection : Color.clear))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isSelected ? CosmosPalette.accent : Color.clear)
                        .frame(height: 2)
                }
                .overlay(alignment: .leading) {
                    if showLeadingDivider {
                        Rectangle()
                            .fill(CosmosPalette.rule)
                            .frame(width: 1)
                    }
                }
        } else if isField {
            if isSelected {
                content
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(FieldPalette.panel)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(FieldPalette.rule, lineWidth: 1)
                    }
            } else {
                content
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

    func makeNSView(context: Context) -> ShareSheetAnchorView {
        let view = ShareSheetAnchorView(frame: .zero)
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: ShareSheetAnchorView, context: Context) {
        anchor.view = nsView
    }
}

/// Anchors `NSSharingServicePicker` and clears AppKit's automatic initial text-field selection when the sheet opens.
private final class ShareSheetAnchorView: NSView {
    private var didClearInitialFocus = false
    private weak var observedWindow: NSWindow?

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didClearInitialFocus else { return }
        if let oldWindow = observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: oldWindow)
            observedWindow = nil
        }
        guard let window else { return }
        observedWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        if window.isKeyWindow {
            clearInitialTextFieldFocus(in: window)
        }
    }

    @objc private func windowDidBecomeKey() {
        guard let window else { return }
        clearInitialTextFieldFocus(in: window)
    }

    private func clearInitialTextFieldFocus(in window: NSWindow) {
        guard !didClearInitialFocus else { return }
        didClearInitialFocus = true
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
        observedWindow = nil
        Task { @MainActor [weak window] in
            guard let window,
                  window.firstResponder is NSTextView || window.firstResponder is NSTextField
            else { return }
            window.makeFirstResponder(nil)
        }
    }
}
