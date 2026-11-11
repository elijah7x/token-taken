import AppKit
import SwiftUI
import TokenTakenKit

// Presentation tokens for the Atmosphere direction.

enum Radius {
    /// Floating tray, inset 8pt from the window edge so its corners sit concentric with the window's.
    static let tray: CGFloat = 16
    static let card: CGFloat = 16
    static let inner: CGFloat = 10
    static let badge: CGFloat = 6
}

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
    // MARK: Ink hierarchy

    static let ink1 = Color(
        light: "#131A24",
        dark: "#EEF2F8",
        contrastLight: "#090E14",
        contrastDark: "#FFFFFF"
    )
    static let ink2 = Color(
        light: "#465264",
        dark: "#A9B5C7",
        contrastLight: "#283241",
        contrastDark: "#D4DCE8"
    )
    static let ink3 = Color(
        light: "#6C788A",
        dark: "#7B889C",
        contrastLight: "#465264",
        contrastDark: "#B0BCCF"
    )

    // MARK: Surfaces & borders

    static let cardSurface = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if reduceTransparency {
            return isDark
                ? NSColor(srgbRed: 24 / 255, green: 33 / 255, blue: 47 / 255, alpha: 1)
                : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        }
        return isDark
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.055)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.82)
    })

    static let sidebarSurface = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if reduceTransparency {
            return isDark
                ? NSColor(srgbRed: 20 / 255, green: 27 / 255, blue: 38 / 255, alpha: 1)
                : NSColor(srgbRed: 241 / 255, green: 244 / 255, blue: 248 / 255, alpha: 1)
        }
        return isDark
            ? NSColor(srgbRed: 18 / 255, green: 25 / 255, blue: 36 / 255, alpha: 0.72)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.60)
    })

    /// The floating tray: a lighter, nearly opaque pane lifted off the frosted base.
    static let traySurface = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            return isDark
                ? NSColor(srgbRed: 34 / 255, green: 42 / 255, blue: 55 / 255, alpha: 1)
                : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        }
        return isDark
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.075)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.78)
    })

    static let trayRim = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10)
            : NSColor(srgbRed: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 0.08)
    })

    static let barTrack = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        if isDark {
            return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: increased ? 0.16 : 0.08)
        }
        return NSColor(srgbRed: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: increased ? 0.14 : 0.065)
    })

    static let hairline = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        if isDark {
            return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: increased ? 0.30 : 0.095)
        }
        return NSColor(srgbRed: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: increased ? 0.28 : 0.085)
    })

    /// Opaque base window surface (`--win-bg`), also used under Reduce Transparency.
    static let solid = Color(light: "#F4F6FA", dark: "#0D121A")

    // MARK: Semantic roles & health

    static let roleAccent = Color(
        light: "#0068D6",
        dark: "#56A8FF",
        contrastLight: "#004FA3",
        contrastDark: "#82BEFF"
    )
    static let healthOK = Color(
        light: "#178750",
        dark: "#3BD184",
        contrastLight: "#0E6339",
        contrastDark: "#6BE0A3"
    )
    static let healthWarn = Color(
        light: "#B56100",
        dark: "#FFB340",
        contrastLight: "#8A4800",
        contrastDark: "#FFC978"
    )
    static let healthScan = Color(
        light: "#0D7490",
        dark: "#4FB0CD",
        contrastLight: "#08566B",
        contrastDark: "#7AD0E6"
    )

    static let muted = ink2
    static let accent = roleAccent
    static let liveDot = healthOK

    // MARK: Data colors

    /// Category order matches `TokenCategory.allCases`: input, cacheRead, cacheWrite, output, reasoning.
    static func color(for category: TokenCategory) -> Color {
        switch category {
        case .input:
            Color(light: "#CF6B85", dark: "#E2829B")
        case .cacheRead:
            Color(light: "#6B84D1", dark: "#859DF0")
        case .cacheWrite:
            Color(light: "#CC8B4B", dark: "#E0A160")
        case .output:
            Color(light: "#4A9D7C", dark: "#62BA96")
        case .reasoning:
            Color(light: "#8772C5", dark: "#A18CE0")
        }
    }

    private static let sourceFallbackColors: [Color] = [
        Color(light: "#D47353", dark: "#E4896A"),
        Color(light: "#C8963E", dark: "#DFB059"),
        Color(light: "#517ED1", dark: "#6D98E8"),
        Color(light: "#C26F96", dark: "#D987AD"),
        Color(light: "#4C9E79", dark: "#68BA93"),
        Color(light: "#7D6EC4", dark: "#9788DE"),
        Color(light: "#5C6C8A", dark: "#7D8EAD"),
        Color(light: "#6B9969", dark: "#86B584"),
        Color(light: "#3A93AE", dark: "#4FB0CD"),
        Color(light: "#A87B5A", dark: "#C79875"),
    ]

    /// Twelve well-separated hues ordered so `+1` collision steps jump across the color wheel.
    private static let modelPalette: [Color] = [
        Color(light: "#4677CE", dark: "#6695EA"), // cobalt blue
        Color(light: "#D27147", dark: "#E68A62"), // terracotta
        Color(light: "#389A72", dark: "#56B990"), // sea jade
        Color(light: "#8662C7", dark: "#A380E2"), // amethyst
        Color(light: "#C2912E", dark: "#DCB04C"), // goldenrod amber
        Color(light: "#2B8EA8", dark: "#49AFC9"), // cerulean teal
        Color(light: "#C85B86", dark: "#E179A2"), // berry rose
        Color(light: "#789836", dark: "#95B652"), // olive
        Color(light: "#5B63BD", dark: "#7B83DC"), // indigo
        Color(light: "#C9545C", dark: "#E3727A"), // carmine
        Color(light: "#526E8C", dark: "#7390B0"), // petrol slate
        Color(light: "#AD5CA8", dark: "#C97AC4"), // orchid
    ]

    static func color(forSource id: String) -> Color {
        switch id.lowercased() {
        case "claude", "claude-code":
            return Color(light: "#D47353", dark: "#E4896A")
        case "pi":
            return Color(light: "#C8963E", dark: "#DFB059")
        case "codex":
            return Color(light: "#517ED1", dark: "#6D98E8")
        case "kimi", "kimi-code":
            return Color(light: "#C26F96", dark: "#D987AD")
        case "zcode":
            return Color(light: "#4C9E79", dark: "#68BA93")
        case "omp", "oh-my-pi":
            return Color(light: "#7D6EC4", dark: "#9788DE")
        case "grok":
            return Color(light: "#5C6C8A", dark: "#7D8EAD")
        case "opencode":
            return Color(light: "#6B9969", dark: "#86B584")
        case "gemini", "gemini-cli":
            return Color(light: "#3A93AE", dark: "#4FB0CD")
        case "factory", "droid":
            return Color(light: "#A87B5A", dark: "#C79875")
        case "devin", "devin-cli", "devin-desktop":
            return Color(light: "#2F8F8A", dark: "#4AABA6")
        case "antigravity", "antigravity-cli", "antigravity-extension":
            return Color(light: "#A35CC0", dark: "#BD78D9")
        case "dsh":
            return Color(light: "#8F9A3A", dark: "#ABB656")
        case "fx":
            return Color(light: "#C0505A", dark: "#DB6C75")
        default:
            let hash = fnv1a64(id.lowercased())
            return sourceFallbackColors[Int(hash % UInt64(sourceFallbackColors.count))]
        }
    }

    /// Assigns distinct hues across `ids`, resolving hash collisions in sorted-ID order so colors stay stable across periods.
    static func modelColors(for ids: [String]) -> [String: Color] {
        let count = modelPalette.count
        guard count > 0, !ids.isEmpty else { return [:] }

        let uniqueSorted = Array(Set(ids)).sorted { lhs, rhs in
            let left = lhs.lowercased()
            let right = rhs.lowercased()
            return left == right ? lhs < rhs : left < right
        }

        var used = Set<Int>()
        var assigned: [String: Color] = [:]
        assigned.reserveCapacity(uniqueSorted.count)

        for id in uniqueSorted {
            if used.count == count {
                used.removeAll(keepingCapacity: true)
            }
            let start = Int(fnv1a64(id.lowercased()) % UInt64(count))
            var chosen = start
            for offset in 0..<count {
                let candidate = (start + offset) % count
                if !used.contains(candidate) {
                    chosen = candidate
                    break
                }
            }
            used.insert(chosen)
            assigned[id] = modelPalette[chosen]
        }
        return assigned
    }

    private static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

/// Compact two-letter source monogram badge matching the Confluence chart (`22pt`, `Radius.badge`, `0.14` tint).
struct SourceMonogramBadge: View {
    let sourceID: String
    let name: String
    var size: CGFloat = 22

    @Environment(\.colorScheme) private var scheme

    private var color: Color { Palette.color(forSource: sourceID) }

    var body: some View {
        Text(verbatim: Self.monogram(for: sourceID, name: name))
            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
            .minimumScaleFactor(0.75)
            .foregroundStyle(
                scheme == .dark
                    ? color.mix(with: .white, by: 0.20)
                    : color.mix(with: .black, by: 0.28)
            )
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: Radius.badge, style: .continuous)
                    .fill(color.opacity(0.14))
            }
            .accessibilityHidden(true)
    }

    static func monogram(for id: String, name: String) -> String {
        switch id.lowercased() {
        case "claude", "claude-code": "CC"
        case "codex": "CX"
        case "zcode": "ZC"
        case "omp", "oh-my-pi": "OM"
        case "pi": "PI"
        case "kimi", "kimi-code": "KM"
        case "grok": "GK"
        case "opencode": "OC"
        case "gemini", "gemini-cli": "GM"
        case "factory", "droid": "FD"
        case "devin", "devin-cli", "devin-desktop": "DV"
        case "antigravity", "antigravity-cli", "antigravity-extension": "AG"
        case "dsh": "DS"
        case "fx": "FX"
        default: String(name.prefix(2)).uppercased()
        }
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

    /// Maps `opacity` to base fill alpha over the Liquid Glass backdrop.
    private static func baseAlpha(for opacity: Double, isDark: Bool) -> Double {
        let midpoint = isDark ? 0.82 : 0.86
        let value = min(max(opacity, 0), 1)
        return value <= 0.5
            ? midpoint * (value / 0.5)
            : midpoint + (1 - midpoint) * ((value - 0.5) / 0.5)
    }

    var body: some View {
        Group {
            if reduceTransparency || theme != .liquidGlass {
                Palette.solid
            } else if opacity >= 0.98 {
                ZStack {
                    Palette.solid
                    atmosphereGlows(scale: 1)
                }
            } else {
                let shape = ContainerRelativeShape()
                ZStack {
                    shape
                        .fill(.clear)
                        .glassEffect(in: shape)
                    shape
                        .fill(Palette.solid)
                        .opacity(Self.baseAlpha(for: opacity, isDark: scheme == .dark))
                    atmosphereGlows(scale: 0.35 + 0.65 * opacity)
                }
            }
        }
        .ignoresSafeArea()
        .background { BackdropWindowConfigurator(isTransparent: isTransparent && opacity < 0.98) }
    }

    @ViewBuilder
    private func atmosphereGlows(scale: Double) -> some View {
        let isDark = scheme == .dark
        let warm = isDark
            ? Color(.sRGB, red: 186 / 255, green: 114 / 255, blue: 82 / 255, opacity: 0.11 * scale)
            : Color(.sRGB, red: 235 / 255, green: 198 / 255, blue: 175 / 255, opacity: 0.22 * scale)
        let cool = isDark
            ? Color(.sRGB, red: 84 / 255, green: 124 / 255, blue: 198 / 255, opacity: 0.14 * scale)
            : Color(.sRGB, red: 169 / 255, green: 194 / 255, blue: 238 / 255, opacity: 0.25 * scale)

        GeometryReader { proxy in
            let radius = max(proxy.size.width, proxy.size.height) * 0.52
            ZStack {
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
        .allowsHitTesting(false)
    }
}

extension View {
    /// Floating tooltip surface: glass normally, an opaque Palette surface with a hairline under Reduce Transparency.
    @ViewBuilder
    func tooltipSurface(reduceTransparency: Bool, cornerRadius: CGFloat = Radius.inner) -> some View {
        if reduceTransparency {
            background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Palette.cardSurface)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Palette.hairline)
                    }
            }
        } else {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
    }

    /// Grounded Atmosphere card surface: `Palette.cardSurface`, `Radius.card`, 0.5pt hairline border, soft shadow.
    func atmosphereCard(reduceTransparency: Bool, isDark: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        return self
            .background { shape.fill(Palette.cardSurface) }
            .clipShape(shape)
            .overlay { shape.strokeBorder(Palette.hairline, lineWidth: 0.5) }
            .shadow(
                color: .black.opacity(reduceTransparency ? 0 : (isDark ? 0.22 : 0.04)),
                radius: 10,
                x: 0,
                y: 3
            )
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
    private static let trafficLightOffset = CGPoint(x: 6, y: 6)
    private static let trafficLightTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    private struct DefaultButtonOrigin {
        let x: CGFloat
        let topInset: CGFloat
    }

    var isTransparent = false {
        didSet { applyWindowAppearance() }
    }

    private var defaultButtonOrigins: [NSWindow.ButtonType: DefaultButtonOrigin] = [:]
    private weak var observedWindow: NSWindow?
    private weak var observedButtonSuperview: NSView?
    private var isAdjustingButtons = false

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindowObservers()
        applyWindowAppearance()
        Task { @MainActor [weak self] in
            self?.repositionWindowControls()
        }
    }

    override func layout() {
        super.layout()
        repositionWindowControls()
    }

    private func configureWindowObservers() {
        guard observedWindow !== window else { return }
        if let oldWindow = observedWindow {
            let center = NotificationCenter.default
            center.removeObserver(self, name: NSWindow.didResizeNotification, object: oldWindow)
            center.removeObserver(self, name: NSWindow.didEndLiveResizeNotification, object: oldWindow)
            center.removeObserver(self, name: NSWindow.didExitFullScreenNotification, object: oldWindow)
        }
        if let oldSuperview = observedButtonSuperview {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.frameDidChangeNotification,
                object: oldSuperview
            )
        }
        observedWindow = window
        observedButtonSuperview = nil
        defaultButtonOrigins.removeAll()

        guard let window else { return }
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(windowLayoutDidChange(_:)),
            name: NSWindow.didResizeNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowLayoutDidChange(_:)),
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowLayoutDidChange(_:)),
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )
    }

    private func observeButtonSuperviewIfNeeded(_ superview: NSView) {
        guard observedButtonSuperview !== superview else { return }
        if let oldSuperview = observedButtonSuperview {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.frameDidChangeNotification,
                object: oldSuperview
            )
        }
        observedButtonSuperview = superview
        superview.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowLayoutDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: superview
        )
    }

    @objc private func windowLayoutDidChange(_ notification: Notification) {
        repositionWindowControls()
        if notification.name == NSWindow.didExitFullScreenNotification {
            Task { @MainActor [weak self] in
                self?.repositionWindowControls()
            }
        }
    }

    private func applyWindowAppearance() {
        guard let window else { return }
        insetWindowControls(in: window)
        window.isOpaque = !isTransparent
        window.backgroundColor = isTransparent
            ? NSColor.white.withAlphaComponent(0.000001)
            : NSColor(Palette.solid)
    }

    /// An empty unified toolbar moves the traffic lights 20pt in and centres them in a 52pt band;
    /// `repositionWindowControls` shifts them a further +6pt inward and +6pt down inside the tray.
    private func insetWindowControls(in window: NSWindow) {
        if window.toolbar == nil {
            window.toolbar = NSToolbar(identifier: "TokenTakenMainWindow")
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.layoutIfNeeded()
        }
        repositionWindowControls()
    }

    private func repositionWindowControls() {
        guard !isAdjustingButtons,
              let window,
              !window.styleMask.contains(.fullScreen),
              let closeButton = window.standardWindowButton(.closeButton),
              let superview = closeButton.superview,
              superview.bounds.height >= 36
        else { return }

        observeButtonSuperviewIfNeeded(superview)

        if defaultButtonOrigins.count < Self.trafficLightTypes.count {
            for type in Self.trafficLightTypes where defaultButtonOrigins[type] == nil {
                guard let button = window.standardWindowButton(type),
                      let buttonSuperview = button.superview,
                      buttonSuperview.bounds.height >= 36
                else { continue }
                let topInset = buttonSuperview.isFlipped
                    ? button.frame.minY
                    : (buttonSuperview.bounds.height - button.frame.maxY)
                defaultButtonOrigins[type] = DefaultButtonOrigin(x: button.frame.minX, topInset: topInset)
            }
        }

        isAdjustingButtons = true
        defer { isAdjustingButtons = false }

        for type in Self.trafficLightTypes {
            guard let button = window.standardWindowButton(type),
                  let buttonSuperview = button.superview,
                  let base = defaultButtonOrigins[type]
            else { continue }
            let targetX = base.x + Self.trafficLightOffset.x
            let targetTop = base.topInset + Self.trafficLightOffset.y
            let targetY = buttonSuperview.isFlipped
                ? targetTop
                : (buttonSuperview.bounds.height - targetTop - button.frame.height)
            if abs(button.frame.origin.x - targetX) > 0.5 || abs(button.frame.origin.y - targetY) > 0.5 {
                button.setFrameOrigin(NSPoint(x: targetX, y: targetY))
            }
        }
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
        let text = ratio.formatted(.percent.precision(.fractionLength(1)))
        // Compare against the formatted zero so ties that round down (e.g. exactly 0.05%) are caught too.
        if part > 0, text == 0.0.formatted(.percent.precision(.fractionLength(1))) {
            return "<" + 0.001.formatted(.percent.precision(.fractionLength(1)))
        }
        return text
    }

    static func ratio(_ part: Int64, of total: Int64) -> Double {
        total > 0 ? Double(part) / Double(total) : 0
    }
}
