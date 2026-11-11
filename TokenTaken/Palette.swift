import AppKit
import SwiftUI
import TokenTakenKit

// Presentation tokens for the `liquid-glass` theme (Condensation direction).
// Values follow design-archive/liquid-v1-head/y.html.

extension Color {
    /// `#RRGGBB` or `RRGGBB`; invalid input yields gray so a bad catalog entry stays visible.
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = .gray
            return
        }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Appearance-aware color. With Increase Contrast the `contrast` variant wins.
    init(light: String, dark: String, contrastLight: String? = nil, contrastDark: String? = nil) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let hex = switch (isDark, increased) {
            case (false, false): light
            case (true, false): dark
            case (false, true): contrastLight ?? light
            case (true, true): contrastDark ?? dark
            }
            return NSColor(Color(hex: hex))
        })
    }
}

enum Palette {
    /// Secondary text. Light #5B6B72 on the pastel field is about 5:1 (AA).
    static let muted = Color(light: "#5B6B72", dark: "#A6B4B8", contrastLight: "#38464C", contrastDark: "#D3DDE0")
    static let hairline = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let alpha = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.34 : 0.13
        return isDark
            ? NSColor(red: 214 / 255, green: 233 / 255, blue: 236 / 255, alpha: alpha)
            : NSColor(red: 66 / 255, green: 88 / 255, blue: 96 / 255, alpha: alpha)
    })
    static let accent = Color(light: "#4F8790", dark: "#8FC6CE")
    /// Opaque surface used whenever Reduce Transparency is on.
    static let solid = Color(light: "#F4F7F7", dark: "#202C31")
    static let liveDot = Color(hex: "#73B99A")

    /// Water strokes in the condensation field.
    static let rain = Color(light: "#7FAFBA", dark: "#CFE8EC")

    // MARK: Data colors

    /// Category order matches TokenCategory.allCases: input, cacheRead, cacheWrite, output, reasoning.
    static func color(for category: TokenCategory) -> Color {
        switch category {
        case .input: Color(hex: "#E79BB0")      // pink
        case .cacheRead: Color(hex: "#8E9FE0")  // periwinkle
        case .cacheWrite: Color(hex: "#E9AE78") // apricot
        case .output: Color(hex: "#75C2A4")     // mint
        case .reasoning: Color(hex: "#B2A2DD")  // lavender
        }
    }

    static func color(forSource id: String) -> Color {
        Color(hex: SourceCatalog.info(for: id).colorHex)
    }

    /// Models have no catalog color yet; rotate the category tones by rank as the reference does.
    static func color(forModelRank rank: Int) -> Color {
        let tones = TokenCategory.allCases
        return color(for: tones[rank % tones.count])
    }

    // MARK: Background

    /// Soft pastel spectrum (light) or its deep muted counterpart (dark).
    static func meshColors(_ scheme: ColorScheme) -> [Color] {
        let hexes = scheme == .dark
            ? ["#3A3134", "#1F2A2B", "#263948",
               "#262C2D", "#1B2628", "#1D2931",
               "#1F3129", "#19242A", "#2B2738"]
            : ["#F7E3DF", "#EEF2EC", "#DFE9F7",
               "#F2ECE7", "#ECF2EF", "#E4ECF3",
               "#E2EFE6", "#E8EDF1", "#EBE5F4"]
        return hexes.map(Color.init(hex:))
    }
}

struct WindowBackdrop: View {
    let theme: AppTheme
    let transparency: Double

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var opacity: Double {
        theme == .liquidGlass ? 1 - min(max(transparency, 0), 1) : 1
    }

    private var isTransparent: Bool {
        theme == .liquidGlass && !reduceTransparency
    }

    /// Matches Tivano's stock scrim at the midpoint, clear glass at 0 opacity,
    /// and a solid base at 1, with a linear ramp on either side.
    private static func scrim(for opacity: Double, isDark: Bool) -> Double {
        let stock = isDark ? 0.26 : 0.18
        let value = min(max(opacity, 0), 1)
        return value <= 0.5
            ? stock * (value / 0.5)
            : stock + (1 - stock) * ((value - 0.5) / 0.5)
    }

    var body: some View {
        Group {
            if !isTransparent || opacity >= 0.98 {
                Palette.solid
            } else {
                let shape = ContainerRelativeShape()
                ZStack {
                    shape
                        .fill(.clear)
                        .glassEffect(in: shape)
                    MeshBackdrop.view(for: scheme)
                        .opacity(opacity)
                    shape
                        .fill(scheme == .dark ? Color.black : Color.white)
                        .opacity(Self.scrim(for: opacity, isDark: scheme == .dark))
                }
            }
        }
        .ignoresSafeArea()
        .background { BackdropWindowConfigurator(isTransparent: isTransparent) }
    }
}

/// The mesh is static and low-frequency, so it is rasterized once per scheme into a small image
/// and stretched to fill (as the mesh itself stretches), instead of a window-sized drawable.
@MainActor
private enum MeshBackdrop {
    private static let renderSize = CGSize(width: 96, height: 64)
    private static var images: [ColorScheme: Image] = [:]

    static func view(for scheme: ColorScheme) -> AnyView {
        if let image = image(for: scheme) {
            return AnyView(image.resizable().interpolation(.high))
        }
        return AnyView(mesh(scheme))
    }

    private static func image(for scheme: ColorScheme) -> Image? {
        if let image = images[scheme] { return image }
        let renderer = ImageRenderer(content: mesh(scheme).frame(width: renderSize.width, height: renderSize.height))
        renderer.scale = 1
        guard let cgImage = renderer.cgImage else { return nil }
        let image = Image(decorative: cgImage, scale: 1)
        images[scheme] = image
        return image
    }

    private static func mesh(_ scheme: ColorScheme) -> MeshGradient {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.55, 0], [1, 0],
                [0, 0.5], [0.45, 0.55], [1, 0.45],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: Palette.meshColors(scheme)
        )
    }
}

extension View {
    /// Floating tooltip surface: glass normally, an opaque Palette surface with a hairline under Reduce Transparency.
    @ViewBuilder
    func tooltipSurface(reduceTransparency: Bool, cornerRadius: CGFloat = 11) -> some View {
        if reduceTransparency {
            background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Palette.solid)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Palette.hairline)
                    }
            }
        } else {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

private struct BackdropWindowConfigurator: NSViewRepresentable {
    let isTransparent: Bool

    func makeNSView(context: Context) -> BackdropWindowView {
        let view = BackdropWindowView()
        view.isTransparent = isTransparent
        return view
    }

    func updateNSView(_ view: BackdropWindowView, context: Context) {
        view.isTransparent = isTransparent
    }
}

private final class BackdropWindowView: NSView {
    var isTransparent = false {
        didSet { applyWindowAppearance() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyWindowAppearance()
    }

    private func applyWindowAppearance() {
        guard let window else { return }
        window.isOpaque = !isTransparent
        window.backgroundColor = isTransparent
            ? NSColor.white.withAlphaComponent(0.000001)
            : NSColor(Palette.solid)
    }
}

// MARK: - Labels and formatting

extension TokenCategory {
    var title: LocalizedStringKey {
        switch self {
        case .input: "New input"
        case .cacheRead: "Cache read"
        case .cacheWrite: "Cache write"
        case .output: "Output"
        case .reasoning: "Reasoning"
        }
    }
}

extension Period {
    var title: LocalizedStringKey {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        case .all: "All"
        }
    }
}

enum Share {
    /// One decimal, as in the reference (`12.3%`). Zero total renders `0.0%`;
    /// a non-zero part that would round to `0.0%` renders `<0.1%`.
    static func percent(_ part: Int64, of total: Int64) -> String {
        let ratio = total > 0 ? Double(part) / Double(total) : 0
        if part > 0, ratio < 0.0005 {
            return "<" + 0.001.formatted(.percent.precision(.fractionLength(1)))
        }
        return ratio.formatted(.percent.precision(.fractionLength(1)))
    }

    static func ratio(_ part: Int64, of total: Int64) -> Double {
        total > 0 ? Double(part) / Double(total) : 0
    }
}
