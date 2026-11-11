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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var scope: ShareScope = .overall
    @State private var aspect: ShareAspect = .portrait
    @State private var showCost = false
    @State private var showComposition = true
    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var shareAnchor = SharePickerAnchor()

    @Namespace private var aspectNamespace
    @FocusState private var focusedAspect: ShareAspect?

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

    private var cardData: ShareCardData {
        ShareCardData(summary: summary, scope: effectiveScope)
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

            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $showCost) {
                    Text("Show cost estimate")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.ink1)
                }
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Show cost estimate"))

                Toggle(isOn: $showComposition) {
                    Text("Show composition")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.ink1)
                }
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Show composition"))
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
            .modifier(ShareActionButtonSurface( isProminent: false, reduceTransparency: reduceTransparency))
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

    // MARK: - Rendering & Export

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
        let canvasSize = aspect.canvasSize
        let view = ShareCardView(
            data: cardData,
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
        let detail: String?
        let isMonospacedValue: Bool
    }

    let summary: UsageSummary
    let kind: Kind
    let counts: TokenCounts
    let estimatedUSD: Double

    init(summary: UsageSummary, scope: ShareScope) {
        self.summary = summary
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
                if summary.bySource.count == 1 {
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
                self.estimatedUSD = priceTable.estimate(model: item.id, counts: item.counts).usd
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

    var accentColor: Color {
        switch kind {
        case .overall:
            Palette.color(for: .cacheRead)
        case .source(let id, _):
            Palette.color(forSource: id)
        case .model(let id, _):
            Palette.modelColors(for: summary.byModel.map(\.id))[id] ?? Palette.color(for: .output)
        }
    }

    func supportingFacts(showCost: Bool) -> [SupportingFact] {
        var facts: [SupportingFact] = [
            SupportingFact(
                id: "cacheRead",
                label: "Cache read",
                value: Share.percent(counts.cacheRead, of: counts.total),
                detail: TokenFormat.short(counts.cacheRead),
                isMonospacedValue: false
            ),
            SupportingFact(
                id: "output",
                label: "Output",
                value: TokenFormat.short(counts.output),
                detail: Share.percent(counts.output, of: counts.total),
                isMonospacedValue: false
            ),
        ]

        switch kind {
        case .overall, .source:
            if let topModel = summary.byModel.first {
                facts.append(SupportingFact(
                    id: "topModel",
                    label: "Top model",
                    value: topModel.name,
                    detail: TokenFormat.short(topModel.counts.total),
                    isMonospacedValue: true
                ))
            } else if let topSource = summary.bySource.first {
                facts.append(SupportingFact(
                    id: "topSource",
                    label: "Top source",
                    value: topSource.name,
                    detail: TokenFormat.short(topSource.counts.total),
                    isMonospacedValue: false
                ))
            }
        case .model:
            if let topSource = summary.bySource.first {
                facts.append(SupportingFact(
                    id: "topSource",
                    label: "Top source",
                    value: topSource.name,
                    detail: Share.percent(counts.total, of: summary.total.total),
                    isMonospacedValue: false
                ))
            }
        }

        if showCost {
            facts.append(SupportingFact(
                id: "cost",
                label: "Cost estimate",
                value: TokenFormat.usd(estimatedUSD),
                detail: nil,
                isMonospacedValue: false
            ))
        }

        return Array(facts.prefix(4))
    }

    var categoryMix: [(category: TokenCategory, tokens: Int64, ratio: Double, color: Color)] {
        let total = counts.total
        return TokenCategory.allCases.compactMap { category in
            let value = counts[category]
            guard value > 0 else { return nil }
            return (
                category: category,
                tokens: value,
                ratio: Share.ratio(value, of: total),
                color: Palette.color(for: category)
            )
        }
    }
}

// MARK: - ShareCardView (1080x1620 portrait / 1620x1080 landscape)

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
        ZStack {
            cardBackground

            switch aspect {
            case .portrait:
                portraitLayout
            case .landscape:
                landscapeLayout
            }
        }
        .frame(width: aspect.canvasSize.width, height: aspect.canvasSize.height)
    }

    // MARK: - Layouts

    private var portraitLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader

            Spacer(minLength: 36)

            scopeBadgeRow

            heroTotalBlock
                .padding(.top, 16)

            Spacer(minLength: 36)

            vesselAndCompositionSection(vesselWidth: 220, vesselHeight: 420, horizontal: true)

            Spacer(minLength: 36)

            supportingFactsGrid(columns: 2)

            footerRow
                .padding(.top, 44)
        }
        .padding(76)
    }

    private var landscapeLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader

            Spacer(minLength: 28)

            HStack(alignment: .center, spacing: 64) {
                VStack(alignment: .leading, spacing: 0) {
                    scopeBadgeRow

                    heroTotalBlock
                        .padding(.top, 12)

                    Spacer(minLength: 28)

                    supportingFactsGrid(columns: 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                vesselAndCompositionSection(vesselWidth: 200, vesselHeight: 440, horizontal: true)
                    .frame(width: showComposition ? 560 : 240)
            }

            Spacer(minLength: 28)

            footerRow
        }
        .padding(72)
    }

    // MARK: - Card sections

    private var cardHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 14) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "#7CC8F2"), Color(hex: "#3A9BE0")],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 22, height: 22)

                Text(verbatim: "Token Taken")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Palette.ink1)
            }

            Spacer()

            Text(periodDescription)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Palette.ink2)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var scopeBadgeRow: some View {
        switch data.kind {
        case .overall:
            Text("This period overall")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Palette.ink2)

        case .source(let id, let name):
            let sourceColor = Palette.color(forSource: id)
            HStack(spacing: 18) {
                Text(verbatim: SourceMonogramBadge.monogram(for: id, name: name))
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(
                        isDark
                            ? sourceColor.mix(with: .white, by: 0.20)
                            : sourceColor.mix(with: .black, by: 0.28)
                    )
                    .frame(width: 52, height: 52)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(sourceColor.opacity(isDark ? 0.18 : 0.14))
                    }
                    .accessibilityHidden(true)

                Text(verbatim: name)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(Palette.ink1)
                    .lineLimit(1)
            }

        case .model(let id, let name):
            HStack(spacing: 14) {
                Circle()
                    .fill(data.accentColor)
                    .frame(width: 18, height: 18)
                Text(verbatim: name.isEmpty ? id : name)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.ink1)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var heroTotalBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(TokenFormat.short(data.counts.total))
                .font(.system(size: 160, weight: .bold))
                .tracking(-4)
                .foregroundStyle(Palette.ink1)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text("Token")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(Palette.ink2)
        }
    }

    private func vesselAndCompositionSection(
        vesselWidth: CGFloat,
        vesselHeight: CGFloat,
        horizontal: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: 44) {
            ShareVesselGraphic(
                mix: data.categoryMix,
                accentColor: data.accentColor,
                showComposition: showComposition,
                isDark: isDark,
                reduceTransparency: reduceTransparency
            )
            .frame(width: vesselWidth, height: vesselHeight)

            if showComposition {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(data.categoryMix, id: \.category.id) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Circle()
                                    .fill(item.color)
                                    .frame(width: 16, height: 16)

                                Text(item.category.title)
                                    .font(.system(size: 26, weight: .semibold))
                                    .foregroundStyle(Palette.ink1)
                                    .lineLimit(1)

                                Spacer(minLength: 16)

                                Text(Share.percent(item.tokens, of: data.counts.total))
                                    .font(.system(size: 26, weight: .semibold))
                                    .foregroundStyle(Palette.ink1)
                                    .monospacedDigit()
                            }

                            FullWidthProportionBar(
                                ratio: item.ratio,
                                color: item.color,
                                height: 8
                            )

                            Text("\(TokenFormat.short(item.tokens)) tokens")
                                .font(.system(size: 21, weight: .medium))
                                .foregroundStyle(Palette.ink3)
                                .monospacedDigit()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(36)
        .background {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(Palette.cardSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1.5)
        }
    }

    private func supportingFactsGrid(columns: Int) -> some View {
        let facts = data.supportingFacts(showCost: showCost)
        let gridColumns = Array(
            repeating: GridItem(.flexible(), spacing: 24, alignment: .leading),
            count: max(1, columns)
        )
        return LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 24) {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: 8) {
                    Text(fact.label)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(1)

                    Text(verbatim: fact.value)
                        .font(fact.isMonospacedValue
                            ? .system(size: 34, weight: .semibold, design: .monospaced)
                            : .system(size: 38, weight: .bold))
                        .foregroundStyle(Palette.ink1)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    if let detail = fact.detail {
                        Text(verbatim: detail)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Palette.ink3)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: 136, alignment: .topLeading)
                .background {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Palette.cardSurface)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1.5)
                }
            }
        }
    }

    private var footerRow: some View {
        VStack(spacing: 22) {
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 1.5)

            HStack(alignment: .firstTextBaseline) {
                Text("Local data · Read-only")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Palette.ink3)

                Spacer()

                Text(verbatim: Date.now.formatted(.dateTime.locale(locale).year().month(.abbreviated).day()))
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Palette.ink3)
                    .monospacedDigit()
            }
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

    @ViewBuilder
    private var cardBackground: some View {
        if reduceTransparency {
            Palette.solid
        } else {
            let warm = isDark
                ? Color(.sRGB, red: 186 / 255, green: 114 / 255, blue: 82 / 255, opacity: 0.14)
                : Color(.sRGB, red: 235 / 255, green: 198 / 255, blue: 175 / 255, opacity: 0.28)
            let cool = isDark
                ? Color(.sRGB, red: 84 / 255, green: 124 / 255, blue: 198 / 255, opacity: 0.17)
                : Color(.sRGB, red: 169 / 255, green: 194 / 255, blue: 238 / 255, opacity: 0.30)

            GeometryReader { proxy in
                let radius = max(proxy.size.width, proxy.size.height) * 0.56
                ZStack {
                    Palette.solid

                    RadialGradient(
                        colors: [warm, .clear],
                        center: UnitPoint(x: 0.22, y: 0.22),
                        startRadius: 0,
                        endRadius: radius
                    )

                    RadialGradient(
                        colors: [cool, .clear],
                        center: UnitPoint(x: 0.80, y: 0.78),
                        startRadius: 0,
                        endRadius: radius * 1.08
                    )
                }
            }
        }
    }
}

// MARK: - Glass Vessel Graphic

private struct ShareVesselGraphic: View {
    let mix: [(category: TokenCategory, tokens: Int64, ratio: Double, color: Color)]
    let accentColor: Color
    let showComposition: Bool
    let isDark: Bool
    let reduceTransparency: Bool

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
            let cornerRadius = min(rect.width * 0.38, 56)
            let vesselShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .path(in: rect)

            var clipped = context
            clipped.clip(to: vesselShape)

            let headroom = max(24, rect.height * 0.10)
            let meniscusY = rect.minY + headroom
            let sag = min(14, max(8, rect.width * 0.05))
            let controlY = meniscusY + sag * 2

            // Air headspace above the meniscus.
            if reduceTransparency {
                clipped.fill(vesselShape, with: .color(Palette.solid))
            } else {
                var airBody = Path()
                airBody.move(to: CGPoint(x: rect.minX, y: rect.minY))
                airBody.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                airBody.addLine(to: CGPoint(x: rect.maxX, y: meniscusY))
                airBody.addQuadCurve(
                    to: CGPoint(x: rect.minX, y: meniscusY),
                    control: CGPoint(x: rect.midX, y: controlY)
                )
                airBody.closeSubpath()
                clipped.fill(
                    airBody,
                    with: .color(Color.white.opacity(isDark ? 0.06 : 0.48))
                )
            }

            let liquidHeight = max(1, rect.maxY - meniscusY)
            var liquidMask = Path()
            liquidMask.move(to: CGPoint(x: rect.minX, y: meniscusY))
            liquidMask.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: meniscusY),
                control: CGPoint(x: rect.midX, y: controlY)
            )
            liquidMask.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            liquidMask.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            liquidMask.closeSubpath()

            var liquidContext = clipped
            liquidContext.clip(to: liquidMask)

            if showComposition && !mix.isEmpty {
                let ratioSum = max(0.0001, mix.reduce(0) { $0 + $1.ratio })
                var currentY = meniscusY
                for (index, entry) in mix.enumerated() {
                    let bandHeight = index == mix.count - 1
                        ? (rect.maxY - currentY)
                        : liquidHeight * CGFloat(entry.ratio / ratioSum)
                    let bandRect = CGRect(
                        x: rect.minX,
                        y: currentY,
                        width: rect.width,
                        height: max(0, bandHeight + 1)
                    )
                    if reduceTransparency {
                        liquidContext.fill(Path(bandRect), with: .color(entry.color.opacity(isDark ? 0.65 : 0.58)))
                    } else {
                        liquidContext.fill(
                            Path(bandRect),
                            with: .linearGradient(
                                Gradient(colors: [
                                    entry.color.opacity(isDark ? 0.52 : 0.46),
                                    entry.color.opacity(isDark ? 0.74 : 0.68),
                                ]),
                                startPoint: CGPoint(x: bandRect.midX, y: bandRect.minY),
                                endPoint: CGPoint(x: bandRect.midX, y: bandRect.maxY)
                            )
                        )
                    }
                    if index > 0 {
                        var divider = Path()
                        divider.move(to: CGPoint(x: rect.minX, y: currentY))
                        divider.addLine(to: CGPoint(x: rect.maxX, y: currentY))
                        liquidContext.stroke(
                            divider,
                            with: .color(.white.opacity(isDark ? 0.22 : 0.45)),
                            lineWidth: 1.5
                        )
                    }
                    currentY += bandHeight
                }
            } else {
                let fill = CGRect(x: rect.minX, y: meniscusY, width: rect.width, height: liquidHeight)
                liquidContext.fill(
                    Path(fill),
                    with: .linearGradient(
                        Gradient(colors: [
                            accentColor.opacity(isDark ? 0.36 : 0.32),
                            accentColor.opacity(isDark ? 0.64 : 0.58),
                        ]),
                        startPoint: CGPoint(x: rect.midX, y: meniscusY),
                        endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                    )
                )
            }

            // Meniscus lens highlight at the top of the liquid.
            let topColor = (showComposition ? mix.first?.color : nil) ?? accentColor
            let lensHalfHeight: CGFloat = 4
            var meniscusLine = Path()
            meniscusLine.move(to: CGPoint(x: rect.minX, y: meniscusY + lensHalfHeight))
            meniscusLine.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: meniscusY + lensHalfHeight),
                control: CGPoint(x: rect.midX, y: controlY + lensHalfHeight)
            )
            clipped.stroke(meniscusLine, with: .color(topColor.opacity(0.55)), lineWidth: 2)

            var meniscusLens = Path()
            meniscusLens.move(to: CGPoint(x: rect.minX, y: meniscusY - lensHalfHeight))
            meniscusLens.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: meniscusY - lensHalfHeight),
                control: CGPoint(x: rect.midX, y: controlY - lensHalfHeight)
            )
            meniscusLens.addLine(to: CGPoint(x: rect.maxX, y: meniscusY + lensHalfHeight))
            meniscusLens.addQuadCurve(
                to: CGPoint(x: rect.minX, y: meniscusY + lensHalfHeight),
                control: CGPoint(x: rect.midX, y: controlY + lensHalfHeight)
            )
            meniscusLens.closeSubpath()
            clipped.fill(meniscusLens, with: .color(.white.opacity(0.55)))

            // Left rim specular highlight.
            if !reduceTransparency {
                let highlightRect = CGRect(
                    x: rect.minX + 14,
                    y: rect.minY + 12,
                    width: 6,
                    height: max(1, rect.height - 24)
                )
                let highlight = RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .path(in: highlightRect)
                clipped.fill(
                    highlight,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: .white.opacity(0), location: 0),
                            .init(color: .white.opacity(0.45), location: 0.15),
                            .init(color: .white.opacity(0.45), location: 0.85),
                            .init(color: .white.opacity(0), location: 1),
                        ]),
                        startPoint: CGPoint(x: highlightRect.midX, y: highlightRect.minY),
                        endPoint: CGPoint(x: highlightRect.midX, y: highlightRect.maxY)
                    )
                )
            }

            let rimColor = isDark ? Color.white.opacity(0.18) : Palette.ink1.opacity(0.12)
            context.stroke(vesselShape, with: .color(rimColor), lineWidth: 2)
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
