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
        case .portrait:
            let contentWidth = size.width - hMargin * 2
            let topY: CGFloat = 636
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
        if ThemeRuntime.isField {
            FieldShareCard(data: data, aspect: aspect, showCost: showCost, showComposition: showComposition)
        } else {
            tideCard
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
            case .portrait:
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

            scopeRow
                .padding(.top, 44)

            heroBlock(numberSize: 172, unitSize: 86, tokenLabelSize: 40)
                .padding(.top, 16)

            if showCost {
                costRow(amountSize: 38, noteSize: 32)
                    .padding(.top, 12)
            }

            portraitSupportingFacts
                .padding(.top, 30)
        }
        .padding(.horizontal, geometry.horizontalMargin)
        .padding(.top, geometry.verticalMargin)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func landscapeLeftColumn(geometry: TideGeometry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            landscapeHeader

            scopeRow
                .padding(.top, 46)

            heroBlock(numberSize: 144, unitSize: 72, tokenLabelSize: 36)
                .padding(.top, 18)

            if showCost {
                costRow(amountSize: 36, noteSize: 30)
                    .padding(.top, 14)
            }

            Spacer(minLength: 24)

            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 2)

            landscapeSupportingFacts
                .padding(.top, 24)
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
        HStack(alignment: .center, spacing: 15) {
            ShareDropGlyph()
                .frame(width: 36, height: 42)
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
            HStack {
                Spacer(minLength: 0)
                Text(verbatim: dateText)
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(Palette.ink3)
                    .monospacedDigit()
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
                .themedGlass(.regular.interactive(), in: .circle)
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

    func body(content: Content) -> some View {
        if !isSelected {
            content
        } else if reduceTransparency {
            content
                .background { Capsule().fill(Palette.cardSurface) }
                .overlay { Capsule().strokeBorder(Palette.hairline, lineWidth: 1) }
        } else {
            content
                .themedGlass(.regular.interactive(), in: .capsule)
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
