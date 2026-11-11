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
    case landscape

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .portrait: "Portrait 2:3"
        case .landscape: "Landscape 3:2"
        }
    }

    var canvasSize: CGSize {
        switch self {
        case .portrait: CGSize(width: 1080, height: 1620)
        case .landscape: CGSize(width: 1620, height: 1080)
        }
    }
}

// MARK: - Share & Export Sheet

struct ShareExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(RefreshCoordinator.self) private var refreshCoordinator: RefreshCoordinator?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var scope: ShareScope = .overall
    @State private var aspect: ShareAspect = .portrait
    @State private var showCost = false
    @State private var showComposition = true
    @State private var scopedSummary: UsageSummary?
    @State private var loadedScopeKey: ScopeQueryKey?
    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var shareAnchor = SharePickerAnchor()

    @Namespace private var aspectNamespace
    @FocusState private var focusedAspect: ShareAspect?

    private struct ScopeQueryKey: Equatable {
        let scope: ShareScope
        let period: Period
        let start: Date
        let end: Date
        let totalTokens: Int64
        let syncEnabled: Bool
        let remoteCount: Int
    }

    private var summary: UsageSummary { model.summary }

    private var effectiveScope: ShareScope {
        switch scope {
        case .overall:
            return .overall
        case .source(let id):
            return summary.bySource.contains(where: { $0.id == id }) ? scope : .overall
        case .model(let id):
            return summary.byModel.contains(where: { $0.id == id }) ? scope : .overall
        }
    }

    private var scopeQueryKey: ScopeQueryKey {
        ScopeQueryKey(
            scope: effectiveScope,
            period: summary.period,
            start: summary.start,
            end: summary.end,
            totalTokens: summary.total.total,
            syncEnabled: settings.syncEnabled,
            remoteCount: refreshCoordinator?.remoteSnapshots.count ?? 0
        )
    }

    private var cardData: ShareCardData {
        ShareCardData(
            summary: summary,
            scope: effectiveScope,
            scopedSummary: loadedScopeKey == scopeQueryKey ? scopedSummary : nil
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            previewPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)

            Rectangle()
                .fill(Palette.hairline)
                .frame(width: 1)
                .padding(.vertical, 20)

            controlColumn
                .frame(width: 268)
                .padding(24)
        }
        .frame(width: 720, height: 560)
        .background {
            ShareSheetBackdrop(
                theme: settings.theme,
                transparency: settings.interfaceTransparency
            )
        }
        .onChange(of: scopeQueryKey, initial: true) { _, key in
            scopedSummary = resolveScopedSummary(for: key.scope)
            loadedScopeKey = key
        }
        .onExitCommand {
            dismiss()
        }
        .onDisappear {
            copyResetTask?.cancel()
        }
    }

    // MARK: - Left preview pane

    private var previewPane: some View {
        GeometryReader { proxy in
            let canvasSize = aspect.canvasSize
            let availableWidth = max(1, proxy.size.width - 8)
            let availableHeight = max(1, proxy.size.height - 8)
            let scale = min(availableWidth / canvasSize.width, availableHeight / canvasSize.height)
            let scaledWidth = canvasSize.width * scale
            let scaledHeight = canvasSize.height * scale
            let cornerRadius = max(12, 36 * scale)

            ShareCardView(
                data: cardData,
                aspect: aspect,
                showCost: showCost,
                showComposition: showComposition
            )
            .frame(width: canvasSize.width, height: canvasSize.height)
            .scaleEffect(scale, anchor: .center)
            .frame(width: scaledWidth, height: scaledHeight)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            }
            .shadow(
                color: .black.opacity(reduceTransparency ? 0 : (scheme == .dark ? 0.34 : 0.10)),
                radius: 18,
                x: 0,
                y: 6
            )
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: aspect)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Share card preview"))
        .accessibilityValue(Text("\(cardData.scopeDisplayTitle), \(TokenFormat.spoken(cardData.counts.total)) tokens"))
    }

    // MARK: - Right control column

    private var controlColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                Text("Share")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.ink1)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.ink2)
                        .frame(width: 24, height: 24)
                        .modifier(ShareRoundButtonSurface(reduceTransparency: reduceTransparency))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help(Text("Close (Esc)"))
                .accessibilityLabel(Text("Close"))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Scope")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink2)

                scopePicker
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Aspect")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink2)

                aspectSegmentedControl
            }

            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 1)

            VStack(spacing: 8) {
                shareToggleRow(title: "Show cost estimate", isOn: $showCost)
                shareToggleRow(title: "Show composition", isOn: $showComposition)
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

    private func shareToggleRow(
        title: LocalizedStringKey,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
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

    // MARK: - Scope picker (Overall + Sources menu + Models menu)

    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                scope = .overall
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: effectiveScope == .overall ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(effectiveScope == .overall ? Palette.roleAccent : Palette.ink3)
                        .accessibilityHidden(true)

                    Text("This period overall")
                        .font(.system(size: 12.5, weight: effectiveScope == .overall ? .semibold : .medium))
                        .foregroundStyle(Palette.ink1)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    Text(TokenFormat.short(summary.total.total))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.ink2)
                        .monospacedDigit()
                }
                .padding(.horizontal, 11)
                .frame(height: 30)
                .frame(maxWidth: .infinity)
                .modifier(SharePillSurface(
                    isSelected: effectiveScope == .overall,
                    reduceTransparency: reduceTransparency
                ))
                .contentShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("This period overall"))
            .accessibilityAddTraits(effectiveScope == .overall ? .isSelected : [])

            HStack(spacing: 8) {
                sourceScopeMenu
                modelScopeMenu
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Scope"))
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
                        .foregroundStyle(Palette.ink1)
                        .lineLimit(1)
                } else {
                    Text("Source")
                        .font(.system(size: 12, weight: .medium))
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
            .modifier(SharePillSurface(isSelected: isSelected, reduceTransparency: reduceTransparency))
            .contentShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(summary.bySource.isEmpty)
        .opacity(summary.bySource.isEmpty ? 0.45 : 1)
        .accessibilityLabel(Text("Source scope"))
        .accessibilityValue(Text(verbatim: selectedSourceBreakdown?.name ?? ""))
    }

    private var modelScopeMenu: some View {
        let isSelected = selectedModelBreakdown != nil
        return Menu {
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
                        .foregroundStyle(Palette.ink1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Model")
                        .font(.system(size: 12, weight: .medium))
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
            .modifier(SharePillSurface(isSelected: isSelected, reduceTransparency: reduceTransparency))
            .contentShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(summary.byModel.isEmpty)
        .opacity(summary.byModel.isEmpty ? 0.45 : 1)
        .accessibilityLabel(Text("Model scope"))
        .accessibilityValue(Text(verbatim: selectedModelBreakdown?.name ?? ""))
    }

    // MARK: - Aspect segmented control

    private var aspectSegmentedControl: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(ShareAspect.allCases) { option in
                    aspectSegment(option)
                }
            }
            .padding(2)
        }
        .frame(maxWidth: .infinity)
        .background(Capsule().fill(Palette.barTrack))
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: reduceTransparency ? 1 : 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Aspect ratio"))
    }

    private func aspectSegment(_ option: ShareAspect) -> some View {
        let isSelected = aspect == option
        return Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                aspect = option
            }
        } label: {
            Text(option.title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Palette.ink1 : Palette.ink2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 26)
                .contentShape(Capsule())
                .modifier(ShareSegmentSurface(
                    isSelected: isSelected,
                    reduceTransparency: reduceTransparency,
                    namespace: aspectNamespace
                ))
        }
        .buttonStyle(.plain)
        .focused($focusedAspect, equals: option)
        .onKeyPress(.leftArrow) {
            aspect = .portrait
            focusedAspect = .portrait
            return .handled
        }
        .onKeyPress(.rightArrow) {
            aspect = .landscape
            focusedAspect = .landscape
            return .handled
        }
        .accessibilityLabel(Text(option.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Action buttons

    private func actionButton(
        title: LocalizedStringKey,
        symbol: String,
        accessibilityLabel: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.ink1)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .modifier(ShareActionButtonSurface(isProminent: false, reduceTransparency: reduceTransparency))
            .contentShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var sharePickerButton: some View {
        Button(action: presentSharePicker) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.roleAccent)
                    .accessibilityHidden(true)
                Text("Share…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink1)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .modifier(ShareActionButtonSurface(isProminent: true, reduceTransparency: reduceTransparency))
            .contentShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            SharePickerAnchorRepresentable(anchor: shareAnchor)
        }
        .accessibilityLabel(Text("Share…"))
    }

    // MARK: - Scoped summary & export

    /// Resolves per-source models or per-model sources outside `body` so rendering never queries SQLite per frame.
    private func resolveScopedSummary(for targetScope: ShareScope) -> UsageSummary? {
        let filter: UsageFilter
        switch targetScope {
        case .overall:
            return nil
        case .source(let id):
            filter = UsageFilter(sources: [id])
        case .model(let id):
            filter = UsageFilter(models: [id])
        }

        let isSynthetic = summary.cost.priceTableVersion == PriceTable.synthetic.version
        let baseStore: (any UsageStore)?
        let now: Date
        if let refreshCoordinator {
            baseStore = settings.syncEnabled
                ? MergedUsageStore(local: refreshCoordinator.store, remote: refreshCoordinator.remoteSnapshots)
                : refreshCoordinator.store
            now = .now
        } else if isSynthetic {
            baseStore = SyntheticUsageStore()
            now = SyntheticUsageStore.defaultToday
        } else {
            baseStore = nil
            now = .now
        }

        guard let baseStore else { return nil }
        let filtered = FilteredUsageStore(store: baseStore, filter: filter)
        let priceTable = isSynthetic ? PriceTable.synthetic : PriceTable.bundled
        return try? UsageAggregator(store: filtered, now: now, priceTable: priceTable)
            .summary(for: summary.period)
    }

    private var defaultFileName: String {
        let periodLabel: String = switch summary.period {
        case .day: String(localized: "Today")
        case .week: String(localized: "This week")
        case .month: String(localized: "This month")
        case .year: String(localized: "This year")
        case .all: String(localized: "All time")
        }
        let scopeSuffix: String = switch effectiveScope {
        case .overall:
            String(localized: "Overall")
        case .source:
            cardData.scopeDisplayTitle
        case .model:
            cardData.scopeDisplayTitle
        }
        let sanitizedScope = scopeSuffix
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "Token Taken - \(periodLabel) - \(sanitizedScope).png"
    }

    private func renderPNGData() -> Data? {
        let resolvedScoped = loadedScopeKey == scopeQueryKey
            ? scopedSummary
            : resolveScopedSummary(for: effectiveScope)
        let exportData = ShareCardData(
            summary: summary,
            scope: effectiveScope,
            scopedSummary: resolvedScoped
        )
        let canvasSize = aspect.canvasSize
        let view = ShareCardView(
            data: exportData,
            aspect: aspect,
            showCost: showCost,
            showComposition: showComposition
        )
        .frame(width: canvasSize.width, height: canvasSize.height)
        .environment(\.colorScheme, scheme)
        .environment(\.locale, locale)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        renderer.proposedSize = ProposedViewSize(canvasSize)

        let targetAppearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
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
        guard let pngData = renderPNGData() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)

        didCopy = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }

    private func saveCardAsPNG() {
        guard let pngData = renderPNGData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultFileName
        if panel.runModal() == .OK, let url = panel.url {
            try? pngData.write(to: url, options: .atomic)
        }
    }

    private func presentSharePicker() {
        guard let pngData = renderPNGData(), let anchorView = shareAnchor.view else { return }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenTakenShare", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent(defaultFileName)
        do {
            try pngData.write(to: fileURL, options: .atomic)
            let picker = NSSharingServicePicker(items: [fileURL])
            picker.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        } catch {
            return
        }
    }
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

    private static let overallSkyColor = Color(light: "#3A9BE0", dark: "#5BB2F0")
    private static let mergedStratumColor = Color(light: "#6E7D92", dark: "#8494AB")

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

        case .source(let id):
            if let source = summary.bySource.first(where: { $0.id == id }) {
                self.kind = .source(id: source.id, name: source.name)
                self.counts = source.counts
                if let scopedSummary {
                    self.estimatedUSD = scopedSummary.cost.estimatedUSD
                } else if summary.bySource.count == 1 {
                    self.estimatedUSD = summary.cost.estimatedUSD
                } else {
                    self.estimatedUSD = summary.cost.estimatedUSD * Share.ratio(source.counts.total, of: summary.total.total)
                }
            } else {
                self.kind = .overall
                self.counts = summary.total
                self.estimatedUSD = summary.cost.estimatedUSD
            }

        case .model(let id):
            if let item = summary.byModel.first(where: { $0.id == id }) {
                self.kind = .model(id: item.id, name: item.name)
                self.counts = item.counts
                if let scopedSummary {
                    self.estimatedUSD = scopedSummary.cost.estimatedUSD
                } else {
                    self.estimatedUSD = priceTable.estimate(model: item.id, counts: item.counts).usd
                }
            } else {
                self.kind = .overall
                self.counts = summary.total
                self.estimatedUSD = summary.cost.estimatedUSD
            }
        }
    }

    var scopeDisplayTitle: String {
        switch kind {
        case .overall:
            String(localized: "This period overall")
        case .source(_, let name):
            name
        case .model(_, let name):
            name
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

    /// Stratified layers sorted descending by token count (index 0 is thickest at the bottom).
    var strata: [Stratum] {
        switch kind {
        case .overall:
            let items = activeSources.map { source in
                Stratum(
                    id: source.id,
                    label: .verbatim(source.name, monospaced: false),
                    tokens: source.counts.total,
                    color: Palette.color(forSource: source.id)
                )
            }
            return Self.mergeTail(items, limit: 5)

        case .source:
            let models = resolvedModelsForSource
            guard !models.isEmpty else {
                return categoryStrata
            }
            let palette = Palette.modelColors(for: summary.byModel.map(\.id) + models.map(\.id))
            let items = models.map { item in
                Stratum(
                    id: item.id,
                    label: .verbatim(item.name, monospaced: true),
                    tokens: item.counts.total,
                    color: palette[item.id] ?? Palette.color(for: .output)
                )
            }
            return Self.mergeTail(items, limit: 4)

        case .model:
            let sources = resolvedSourcesForModel
            guard !sources.isEmpty else {
                return categoryStrata
            }
            let items = sources.map { source in
                Stratum(
                    id: source.id,
                    label: .verbatim(source.name, monospaced: false),
                    tokens: source.counts.total,
                    color: Palette.color(forSource: source.id)
                )
            }
            return Self.mergeTail(items, limit: 4)
        }
    }

    /// Exactly 3 supporting facts matching the Tide Line mockup for each scope.
    var supportingFacts: [SupportingFact] {
        switch kind {
        case .overall:
            let sourceCount = activeSources.count
            let modelCount = activeModels.count
            let topSourceName = activeSources.first?.name ?? "—"
            return [
                SupportingFact(
                    id: "sourcesModels",
                    label: "Sources · models",
                    value: "\(sourceCount) · \(modelCount)",
                    isMonospacedValue: false
                ),
                SupportingFact(
                    id: "cacheRead",
                    label: "Cache read",
                    value: Share.percent(counts.cacheRead, of: counts.total),
                    isMonospacedValue: false
                ),
                SupportingFact(
                    id: "topSource",
                    label: "Top source",
                    value: topSourceName,
                    isMonospacedValue: false
                ),
            ]

        case .source:
            let middleFact: SupportingFact = if let topModel = resolvedModelsForSource.first {
                SupportingFact(
                    id: "topModel",
                    label: "Top model",
                    value: topModel.name,
                    isMonospacedValue: true
                )
            } else {
                SupportingFact(
                    id: "output",
                    label: "Output",
                    value: TokenFormat.short(counts.output),
                    isMonospacedValue: false
                )
            }
            return [
                SupportingFact(
                    id: "periodShare",
                    label: periodShareFactLabel,
                    value: Share.percent(counts.total, of: summary.total.total),
                    isMonospacedValue: false
                ),
                middleFact,
                SupportingFact(
                    id: "cacheRead",
                    label: "Cache read",
                    value: Share.percent(counts.cacheRead, of: counts.total),
                    isMonospacedValue: false
                ),
            ]

        case .model:
            let middleFact: SupportingFact = if let topSource = resolvedSourcesForModel.first {
                SupportingFact(
                    id: "topSource",
                    label: "Top source",
                    value: topSource.name,
                    isMonospacedValue: false
                )
            } else {
                SupportingFact(
                    id: "output",
                    label: "Output",
                    value: TokenFormat.short(counts.output),
                    isMonospacedValue: false
                )
            }
            return [
                SupportingFact(
                    id: "periodShare",
                    label: periodShareFactLabel,
                    value: Share.percent(counts.total, of: summary.total.total),
                    isMonospacedValue: false
                ),
                middleFact,
                SupportingFact(
                    id: "cacheRead",
                    label: "Cache read",
                    value: Share.percent(counts.cacheRead, of: counts.total),
                    isMonospacedValue: false
                ),
            ]
        }
    }

    private var periodShareFactLabel: LocalizedStringKey {
        switch summary.period {
        case .day: "Of today"
        case .week: "Of this week"
        case .month: "Of this month"
        case .year: "Of this year"
        case .all: "Of all time"
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
        TokenCategory.allCases
            .compactMap { category -> Stratum? in
                let value = counts[category]
                guard value > 0 else { return nil }
                return Stratum(
                    id: category.rawValue,
                    label: .localized(category.title),
                    tokens: value,
                    color: Palette.color(for: category)
                )
            }
            .sorted { $0.tokens > $1.tokens }
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
        let labelMidY: CGFloat?
    }

    let canvasSize: CGSize
    let horizontalMargin: CGFloat
    let verticalMargin: CGFloat
    let brimY: CGFloat
    let brimHeight: CGFloat
    let liquidHeight: CGFloat
    let meniscusY: CGFloat
    let waveAmplitude: CGFloat
    let wavelength: CGFloat
    let strataTotalTokens: Int64
    let bands: [Band]
    let footerSubmerged: Bool

    init(data: ShareCardData, aspect: ShareAspect, showComposition: Bool) {
        let size = aspect.canvasSize
        self.canvasSize = size
        switch aspect {
        case .portrait:
            self.horizontalMargin = 84
            self.verticalMargin = 76
        case .landscape:
            self.horizontalMargin = 80
            self.verticalMargin = 72
        }

        let brimFraction: CGFloat = aspect == .portrait ? 0.52 : 0.48
        let brimH = size.height * brimFraction
        self.brimHeight = brimH
        self.brimY = size.height - brimH

        let fillHeight: CGFloat
        if data.counts.total <= 0 {
            fillHeight = 0
        } else if data.isPartialScope {
            fillHeight = min(brimH, max(28, brimH * CGFloat(data.periodShareRatio)))
        } else {
            fillHeight = brimH
        }
        self.liquidHeight = fillHeight
        let topY = size.height - fillHeight
        self.meniscusY = topY
        let amp: CGFloat = fillHeight > 0 ? 10 : 0
        self.waveAmplitude = amp
        self.wavelength = size.width / 1.6

        let footerBaselineApprox = size.height - verticalMargin - 14
        self.footerSubmerged = fillHeight > 0 && footerBaselineApprox > topY + 12

        let strata = data.strata
        let sum = strata.reduce(Int64(0)) { $0 + $1.tokens }
        self.strataTotalTokens = max(sum, data.counts.total)

        guard showComposition, fillHeight > 0, !strata.isEmpty, sum > 0 else {
            self.bands = []
            return
        }

        let minBandHeight = min(8, fillHeight / CGFloat(max(1, strata.count * 2)))
        var heights = strata.map { item in
            max(minBandHeight, fillHeight * CGFloat(Double(item.tokens) / Double(sum)))
        }
        let excess = heights.reduce(0, +) - fillHeight
        if excess > 0 {
            let slack = heights.reduce(CGFloat(0)) { $0 + max(0, $1 - minBandHeight) }
            if slack > 0 {
                heights = heights.map { h in
                    let room = max(0, h - minBandHeight)
                    return h - excess * (room / slack)
                }
            }
        }

        let footerSafeCeiling = size.height - verticalMargin - 44
        let minLabelBandHeight: CGFloat = aspect == .portrait ? 62 : 54

        var cursorY = size.height
        var built: [Band] = []
        built.reserveCapacity(strata.count)
        for (index, item) in strata.enumerated() {
            let bandMaxY = cursorY
            let bandMinY = index == strata.count - 1 ? topY : (cursorY - heights[index])
            cursorY = bandMinY

            let safeTop = max(bandMinY, topY + amp + 8)
            let safeBottom = min(bandMaxY, footerSafeCeiling)
            let labelMidY = (safeBottom - safeTop) >= minLabelBandHeight
                ? (safeTop + safeBottom) / 2
                : nil

            built.append(Band(
                id: item.id,
                stratum: item,
                minY: bandMinY,
                maxY: bandMaxY,
                labelMidY: labelMidY
            ))
        }
        self.bands = built
    }

    func waveY(at x: CGFloat, phase: CGFloat = 0.6) -> CGFloat {
        meniscusY + waveAmplitude * sin((x / wavelength) * 2 * .pi + phase)
    }
}

struct ShareCardView: View {
    let data: ShareCardData
    let aspect: ShareAspect
    let showCost: Bool
    let showComposition: Bool

    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var isDark: Bool { scheme == .dark }

    var body: some View {
        let geometry = TideGeometry(data: data, aspect: aspect, showComposition: showComposition)

        ZStack(alignment: .topLeading) {
            ShareTideVesselCanvas(
                data: data,
                geometry: geometry,
                showComposition: showComposition,
                isDark: isDark,
                reduceTransparency: reduceTransparency
            )

            switch aspect {
            case .portrait:
                portraitTopContent(geometry: geometry)
            case .landscape:
                landscapeTopContent(geometry: geometry)
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

    // MARK: - Top content layouts

    private func portraitTopContent(geometry: TideGeometry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader

            scopeRow
                .padding(.top, 64)

            heroBlock(numberSize: 180, unitSize: 90, tokenLabelSize: 42)
                .padding(.top, 20)

            if showCost {
                costRow(amountSize: 40, noteSize: 33)
                    .padding(.top, 16)
            }

            portraitSupportingFacts
                .padding(.top, 40)
        }
        .padding(.horizontal, geometry.horizontalMargin)
        .padding(.top, geometry.verticalMargin)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func landscapeTopContent(geometry: TideGeometry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader

            HStack(alignment: .top, spacing: 56) {
                VStack(alignment: .leading, spacing: 0) {
                    scopeRow

                    heroBlock(numberSize: 148, unitSize: 74, tokenLabelSize: 38)
                        .padding(.top, 18)

                    if showCost {
                        costRow(amountSize: 36, noteSize: 30)
                            .padding(.top, 14)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                landscapeSupportingFacts
                    .frame(width: 480)
                    .padding(.top, 4)
            }
            .padding(.top, 46)
        }
        .padding(.horizontal, geometry.horizontalMargin)
        .padding(.top, geometry.verticalMargin)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Header, Scope, Hero, Cost, Supporting Facts

    private var cardHeader: some View {
        HStack(alignment: .center, spacing: 24) {
            HStack(alignment: .center, spacing: 15) {
                ShareDropGlyph()
                    .frame(width: 36, height: 42)
                    .accessibilityHidden(true)

                Text(verbatim: "Token Taken")
                    .font(.system(size: 35, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(Palette.ink1)
            }

            Spacer(minLength: 20)

            Text(periodDescription)
                .font(.system(size: 33, weight: .medium))
                .foregroundStyle(Palette.ink2)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private var scopeRow: some View {
        HStack(alignment: .center, spacing: 18) {
            Circle()
                .fill(data.accentColor)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)

            Group {
                switch data.kind {
                case .overall:
                    Text("All sources")
                case .source(_, let name):
                    Text("Source · \(name)")
                case .model(let id, let name):
                    let modelDisplay = name.isEmpty ? id : name
                    let monoModel = Text(verbatim: modelDisplay)
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    Text("Model · \(monoModel)")
                }
            }
            .font(.system(size: 35, weight: .semibold))
            .foregroundStyle(Palette.ink2)
            .lineLimit(1)
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

    private func costRow(amountSize: CGFloat, noteSize: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(verbatim: TokenFormat.usd(data.estimatedUSD))
                .font(.system(size: amountSize, weight: .semibold))
                .foregroundStyle(Palette.ink1)
                .monospacedDigit()

            Text("estimate, not a bill")
                .font(.system(size: noteSize, weight: .regular))
                .foregroundStyle(Palette.ink2)
        }
        .lineLimit(1)
    }

    private var portraitSupportingFacts: some View {
        HStack(alignment: .top, spacing: 32) {
            ForEach(data.supportingFacts) { fact in
                VStack(alignment: .leading, spacing: 8) {
                    Text(fact.label)
                        .font(.system(size: 29, weight: .medium))
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(1)

                    Text(verbatim: fact.value)
                        .font(fact.isMonospacedValue
                            ? .system(size: 38, weight: .semibold, design: .monospaced)
                            : .system(size: 42, weight: .semibold))
                        .foregroundStyle(Palette.ink1)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
        let labelHeight: CGFloat = 38
        let brimLabelBottomY = geometry.brimY - 14
        let shareText = Share.percent(data.counts.total, of: data.summary.total.total)
        let footerCeiling = geometry.canvasSize.height - geometry.verticalMargin - 44

        // When the tide approaches the brim (> ~92%), lift the left share badge onto the brim baseline
        // so text is never squeezed between the dashed brim line and the meniscus.
        let shareBottomY: CGFloat = if geometry.meniscusY - geometry.brimY >= 64 {
            min(geometry.meniscusY - 16, footerCeiling)
        } else {
            brimLabelBottomY
        }

        ZStack(alignment: .topLeading) {
            HStack {
                Spacer(minLength: 0)
                brimPeriodTotalText
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, geometry.horizontalMargin)
            .frame(width: geometry.canvasSize.width, height: labelHeight, alignment: .bottomTrailing)
            .offset(y: brimLabelBottomY - labelHeight)

            HStack {
                Text(verbatim: shareText)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Palette.ink2)
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, geometry.horizontalMargin)
            .frame(width: geometry.canvasSize.width, height: labelHeight, alignment: .bottomLeading)
            .offset(y: shareBottomY - labelHeight)
        }
    }

    private func inlineStrataLabels(geometry: TideGeometry) -> some View {
        let nameSize: CGFloat = aspect == .portrait ? 34 : 31
        let valueSize: CGFloat = aspect == .portrait ? 31 : 28
        let rowHeight: CGFloat = 46

        return ZStack(alignment: .topLeading) {
            ForEach(geometry.bands) { band in
                if let midY = band.labelMidY {
                    HStack(alignment: .firstTextBaseline, spacing: 24) {
                        stratumNameText(band.stratum.label, size: nameSize)
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 16)

                        Text(verbatim: "\(Share.percent(band.stratum.tokens, of: geometry.strataTotalTokens)) · \(TokenFormat.short(band.stratum.tokens))")
                            .font(.system(size: valueSize, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.92))
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .shadow(color: .black.opacity(reduceTransparency ? 0 : 0.18), radius: 3, x: 0, y: 1)
                    .padding(.horizontal, geometry.horizontalMargin)
                    .frame(width: geometry.canvasSize.width, height: rowHeight, alignment: .center)
                    .offset(y: midY - rowHeight / 2)
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
                    ? .system(size: size - 1, weight: .semibold, design: .monospaced)
                    : .system(size: size, weight: .semibold))
        case .localized(let key):
            Text(key)
                .font(.system(size: size, weight: .semibold))
        }
    }

    private func footerDateOverlay(geometry: TideGeometry) -> some View {
        let dateText = Date.now.formatted(.dateTime.locale(locale).year().month(.abbreviated).day())
        let inkColor: Color = geometry.footerSubmerged
            ? Color.white.opacity(isDark ? 0.78 : 0.86)
            : Palette.ink3

        return VStack {
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                Text(verbatim: dateText)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(inkColor)
                    .monospacedDigit()
                    .shadow(
                        color: .black.opacity(geometry.footerSubmerged && !reduceTransparency ? 0.16 : 0),
                        radius: 2,
                        x: 0,
                        y: 1
                    )
            }
            .padding(.horizontal, geometry.horizontalMargin)
            .padding(.bottom, geometry.verticalMargin)
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

// MARK: - Wordmark Droplet Glyph & Full-Card Tide Vessel Canvas

private struct ShareDropGlyph: View {
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

private struct ShareTideVesselCanvas: View {
    let data: ShareCardData
    let geometry: TideGeometry
    let showComposition: Bool
    let isDark: Bool
    let reduceTransparency: Bool

    var body: some View {
        Canvas { context, size in
            let fullRect = CGRect(origin: .zero, size: size)

            // 1. Base vessel surface & soft warm/cool atmosphere glows.
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
            }

            // 2. Dashed period-total brim line for single source / single model scopes.
            if data.isPartialScope {
                var brimPath = Path()
                brimPath.move(to: CGPoint(x: geometry.horizontalMargin, y: geometry.brimY))
                brimPath.addLine(to: CGPoint(x: size.width - geometry.horizontalMargin, y: geometry.brimY))
                context.stroke(
                    brimPath,
                    with: .color(Palette.ink2.opacity(isDark ? 0.42 : 0.36)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [8, 13])
                )
            }

            // 3. Rising liquid, back wave, stratified bands (or single tint), and meniscus.
            if geometry.liquidHeight > 0 {
                let topLayerColor = (showComposition ? geometry.bands.last?.stratum.color : nil) ?? data.accentColor

                if !reduceTransparency {
                    let glowRect = CGRect(
                        x: 0,
                        y: geometry.meniscusY - 180,
                        width: size.width,
                        height: 360
                    )
                    context.fill(
                        Path(glowRect),
                        with: .radialGradient(
                            Gradient(colors: [data.accentColor.opacity(isDark ? 0.26 : 0.28), .clear]),
                            center: CGPoint(x: size.width * 0.5, y: geometry.meniscusY),
                            startRadius: 0,
                            endRadius: size.width * 0.68
                        )
                    )

                    let backWave = waveClosedPath(in: size, phase: 2.4, verticalOffset: -16)
                    context.fill(backWave, with: .color(topLayerColor.opacity(isDark ? 0.24 : 0.22)))
                }

                let frontClip = waveClosedPath(in: size, phase: 0.6, verticalOffset: 0)
                var liquidContext = context
                liquidContext.clip(to: frontClip)

                if showComposition && !geometry.bands.isEmpty {
                    for (index, band) in geometry.bands.enumerated() {
                        let isTopBand = index == geometry.bands.count - 1
                        let drawMinY = isTopBand ? (geometry.meniscusY - geometry.waveAmplitude - 16) : band.minY
                        let bandRect = CGRect(
                            x: 0,
                            y: drawMinY,
                            width: size.width,
                            height: max(0, band.maxY - drawMinY + 1.5)
                        )
                        let pigmented = band.stratum.color.mix(with: .black, by: isDark ? 0.16 : 0.08)
                        let fillOpacity = reduceTransparency ? 1.0 : (isDark ? 0.84 : 0.85)
                        liquidContext.fill(Path(bandRect), with: .color(pigmented.opacity(fillOpacity)))

                        if index > 0 {
                            var divider = Path()
                            divider.move(to: CGPoint(x: 0, y: band.maxY))
                            divider.addLine(to: CGPoint(x: size.width, y: band.maxY))
                            liquidContext.stroke(
                                divider,
                                with: .color(.white.opacity(isDark ? 0.30 : 0.42)),
                                lineWidth: 2
                            )
                        }
                    }
                } else {
                    let fillStartY = geometry.meniscusY - geometry.waveAmplitude - 16
                    let fillRect = CGRect(
                        x: 0,
                        y: fillStartY,
                        width: size.width,
                        height: size.height - fillStartY
                    )
                    if reduceTransparency {
                        let solidTint = data.accentColor.mix(with: .black, by: 0.18)
                        liquidContext.fill(Path(fillRect), with: .color(solidTint))
                    } else {
                        let topTint = data.accentColor.mix(with: .white, by: isDark ? 0.06 : 0.12)
                        let deepTint = data.accentColor.mix(with: .black, by: isDark ? 0.18 : 0.10)
                        liquidContext.fill(
                            Path(fillRect),
                            with: .linearGradient(
                                Gradient(colors: [
                                    topTint.opacity(isDark ? 0.78 : 0.80),
                                    deepTint.opacity(isDark ? 0.88 : 0.88),
                                ]),
                                startPoint: CGPoint(x: size.width / 2, y: geometry.meniscusY),
                                endPoint: CGPoint(x: size.width / 2, y: size.height)
                            )
                        )
                    }
                }

                if !reduceTransparency {
                    let sheenStartY = geometry.meniscusY - geometry.waveAmplitude - 16
                    let sheenRect = CGRect(
                        x: 0,
                        y: sheenStartY,
                        width: size.width,
                        height: size.height - sheenStartY
                    )
                    liquidContext.fill(
                        Path(sheenRect),
                        with: .linearGradient(
                            Gradient(stops: [
                                .init(color: .white.opacity(isDark ? 0.22 : 0.30), location: 0),
                                .init(color: .white.opacity(0), location: 0.35),
                                .init(color: .black.opacity(0.10), location: 1),
                            ]),
                            startPoint: CGPoint(x: size.width / 2, y: sheenStartY),
                            endPoint: CGPoint(x: size.width / 2, y: size.height)
                        )
                    )
                }

                let meniscusStroke = waveOpenPath(in: size, phase: 0.6, verticalOffset: 0)
                context.stroke(
                    meniscusStroke,
                    with: .color(.white.opacity(reduceTransparency ? 0.55 : (isDark ? 0.68 : 0.84))),
                    lineWidth: 3.5
                )
            }

            // 4. Left glass vessel refraction highlight & inner rim.
            if !reduceTransparency {
                let refractionRect = CGRect(
                    x: 24,
                    y: 52,
                    width: 10,
                    height: max(1, size.height - 104)
                )
                let refractionPath = Capsule().path(in: refractionRect)
                context.fill(
                    refractionPath,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: .white.opacity(0), location: 0),
                            .init(color: .white.opacity(isDark ? 0.20 : 0.44), location: 0.14),
                            .init(color: .white.opacity(isDark ? 0.14 : 0.30), location: 0.86),
                            .init(color: .white.opacity(0), location: 1),
                        ]),
                        startPoint: CGPoint(x: refractionRect.midX, y: refractionRect.minY),
                        endPoint: CGPoint(x: refractionRect.midX, y: refractionRect.maxY)
                    )
                )

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

    private func waveOpenPath(in size: CGSize, phase: CGFloat, verticalOffset: CGFloat) -> Path {
        var path = Path()
        let step: CGFloat = 12
        var x: CGFloat = 0
        var isFirst = true
        while x <= size.width {
            let y = geometry.waveY(at: x, phase: phase) + verticalOffset
            if isFirst {
                path.move(to: CGPoint(x: x, y: y))
                isFirst = false
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
            x += step
        }
        let endY = geometry.waveY(at: size.width, phase: phase) + verticalOffset
        path.addLine(to: CGPoint(x: size.width, y: endY))
        return path
    }

    private func waveClosedPath(in size: CGSize, phase: CGFloat, verticalOffset: CGFloat) -> Path {
        var path = waveOpenPath(in: size, phase: phase, verticalOffset: verticalOffset)
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
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
        if reduceTransparency || theme != .liquidGlass {
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

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background { Circle().fill(Palette.cardSurface) }
                .overlay { Circle().strokeBorder(Palette.hairline, lineWidth: 1) }
        } else {
            content
                .glassEffect(.regular.interactive(), in: .circle)
        }
    }
}

private struct SharePillSurface: ViewModifier {
    let isSelected: Bool
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
        if reduceTransparency {
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
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Radius.inner))
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

    func body(content: Content) -> some View {
        if !isSelected {
            content
        } else if reduceTransparency {
            content
                .background { Capsule().fill(Palette.cardSurface) }
                .overlay { Capsule().strokeBorder(Palette.hairline, lineWidth: 1) }
        } else {
            content
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("shareAspect", in: namespace)
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
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Radius.inner))
                .overlay {
                    shape.strokeBorder(Palette.roleAccent.opacity(0.45), lineWidth: 1)
                }
        } else {
            content
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Radius.inner))
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
