import AppKit
import SwiftUI
import TokenTakenKit

/// The active theme for code that draws outside the SwiftUI environment (dynamic `NSColor` providers, glass helpers).
/// `AppSettings` keeps it in step with `theme` and bumps `formatRevision` so every scene rebuilds on a change.
enum ThemeRuntime {
    nonisolated(unsafe) static var isField = false
    nonisolated(unsafe) static var isCosmos = false
}

/// Bare text control with a paper wash only while hovered or pressed.
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
        @State private var isHovered = false

        var body: some View {
            let shape = RadiusRole.control.shape
            let showsWash = isEnabled && (isHovered || configuration.isPressed)
            configuration.label
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background {
                    shape.fill(FieldPalette.panel.opacity(showsWash ? (configuration.isPressed ? 0.95 : 0.7) : 0))
                }
                .contentShape(shape)
                .onHover { isHovered = $0 }
                .opacity(isEnabled ? (configuration.isPressed ? 0.92 : 1) : 0.45)
        }
    }
}

private struct FieldControlPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var fieldControlPressed: Bool {
        get { self[FieldControlPressedKey.self] }
        set { self[FieldControlPressedKey.self] = newValue }
    }
}

struct FieldPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.fieldControlPressed, configuration.isPressed)
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
            let shape = RadiusRole.control.shape
            configuration.label
                .foregroundStyle(CosmosPalette.ink2)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background {
                    shape.fill(configuration.isPressed && isEnabled ? CosmosPalette.selection : CosmosPalette.background)
                }
                .overlay { shape.stroke(CosmosPalette.controlRule, lineWidth: ThemeChrome.ruleWidth) }
                .contentShape(shape)
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

enum PeriodSelectionIndicator {
    case furrow
    case bar
}

extension ThemeChrome {
    /// Active indicator drawn beneath the selected segment in `ThemedPeriodPicker`.
    static var periodIndicator: PeriodSelectionIndicator {
        switch ThemeKind.current {
        case .field: .furrow
        case .cosmos, .liquidGlass: .bar
        }
    }

    /// Whether the period picker sits in a bordered container with a filled selected segment.
    /// Field answers no: bare serif titles with only the furrow under the selection.
    static var framesPeriodPicker: Bool { ThemeKind.current != .field }
}

/// Shared period picker for non-Liquid Glass themes, driven by `ThemeFont.role(.control)`, `RadiusRole.control`,
/// and `ThemeChrome.periodIndicator`.
struct ThemedPeriodPicker: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focusedPeriod: Period?

    private var framed: Bool { ThemeChrome.framesPeriodPicker }

    var body: some View {
        let shape = RadiusRole.control.shape
        HStack(spacing: 0) {
            ForEach(Array(Period.allCases.enumerated()), id: \.element.id) { index, period in
                let selected = model.period == period
                Button {
                    model.period = period
                } label: {
                    Text(period.title)
                        .font(framed ? ThemeFont.role(.control) : ThemeFont.make(15))
                        // English titles ("Month") must not wrap inside the narrow tray.
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(selected ? Palette.ink1 : Palette.ink3)
                        .padding(.horizontal, 2)
                        .padding(.top, framed ? 0 : 4)
                        .padding(.bottom, framed ? 0 : 9)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(selected && framed ? Palette.barTrack : .clear)
                        .overlay(alignment: .bottom) {
                            selectionIndicator
                                .opacity(selected ? 1 : 0)
                        }
                        .overlay(alignment: .leading) {
                            if ThemeChrome.separatesSectionsWithRules, index > 0 {
                                Rectangle()
                                    .fill(Palette.hairline)
                                    .frame(width: ThemeChrome.ruleWidth)
                            }
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
        .background { if framed { shape.fill(Palette.traySurface) } }
        .clipShape(framed ? AnyShape(shape) : AnyShape(Rectangle()))
        .overlay { if framed { shape.strokeBorder(Palette.hairline, lineWidth: ThemeChrome.ruleWidth) } }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Usage period"))
    }

    @ViewBuilder
    private var selectionIndicator: some View {
        switch ThemeChrome.periodIndicator {
        case .furrow:
            FieldFurrow()
                .stroke(Palette.roleAccent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .frame(height: 5)
                .padding(.horizontal, 6)
                .padding(.bottom, 1)
        case .bar:
            Rectangle()
                .fill(Palette.roleAccent)
                .frame(height: 2)
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
