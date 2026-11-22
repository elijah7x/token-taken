import AppKit
import SwiftUI
import TokenTakenKit

// Field theme (theme ID `sketchbook`): a hand-drawn farm. Plot area and plant count are proportional to
// tokens and the crop names the source or model; the scenery around the plots carries no data.

/// Plain sRGB colour that can be mixed like CSS `color-mix(in srgb, …)`.
struct FieldRGB: Hashable {
    var r: Double, g: Double, b: Double, a: Double = 1

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ hex: String, alpha: Double = 1) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x808080
        self.init(r: Double((value >> 16) & 0xFF) / 255, g: Double((value >> 8) & 0xFF) / 255, b: Double(value & 0xFF) / 255, a: alpha)
    }

    /// `self` weighted by `share`, the rest from `other`.
    func mix(_ other: FieldRGB, _ share: Double) -> FieldRGB {
        let t = min(max(share, 0), 1)
        return FieldRGB(r: r * t + other.r * (1 - t), g: g * t + other.g * (1 - t), b: b * t + other.b * (1 - t), a: a * t + other.a * (1 - t))
    }

    func opacity(_ value: Double) -> FieldRGB { FieldRGB(r: r, g: g, b: b, a: value) }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    static let white = FieldRGB("#FFFFFF")
}

struct FieldColors {
    let isDark: Bool
    let desk, paper, panel, ink, ink2, muted, rule, accent, soil, path, hedge: FieldRGB
    let sun, groundShadow, stem, sign, post, soilL, soilR: FieldRGB
    let crops: [FieldRGB]

    private static let light = FieldColors(isDark: false)
    private static let dark = FieldColors(isDark: true)

    /// Only two appearances exist, so the hex tables are parsed once instead of on every palette read.
    static func cached(isDark: Bool) -> FieldColors { isDark ? dark : light }

    init(isDark: Bool) {
        self.isDark = isDark
        if isDark {
            desk = FieldRGB("#161813"); paper = FieldRGB("#1E211C"); panel = FieldRGB("#262A23")
            ink = FieldRGB("#ECE6D6"); ink2 = FieldRGB("#D2CBB8"); muted = FieldRGB("#A9A392"); rule = FieldRGB("#3E4337")
            accent = FieldRGB("#E28A62"); soil = FieldRGB("#33342A"); path = FieldRGB("#2A2D25"); hedge = FieldRGB("#9BAE78")
            sun = FieldRGB("#E9DDB4"); groundShadow = FieldRGB("#000000", alpha: 0.32); stem = FieldRGB("#8EA06C")
            sign = FieldRGB("#3B3528"); post = FieldRGB("#A88A62"); soilL = FieldRGB("#2A2A21"); soilR = FieldRGB("#22221B")
            crops = ["#D9B465", "#AA9BD1", "#DB8E62", "#7FB0B0", "#86AA6F", "#CFC261", "#9DBB78", "#DAA0A6", "#99B6D4", "#B8B66F"].map { FieldRGB($0) }
        } else {
            desk = FieldRGB("#E7E1D2"); paper = FieldRGB("#F5F1E6"); panel = FieldRGB("#FBF8F0")
            ink = FieldRGB("#2B2A24"); ink2 = FieldRGB("#4A473D"); muted = FieldRGB("#6B675B"); rule = FieldRGB("#D9D2C0")
            accent = FieldRGB("#A94E2A"); soil = FieldRGB("#E4D8BC"); path = FieldRGB("#EFE7D3"); hedge = FieldRGB("#6A7A4F")
            sun = FieldRGB("#D9893A"); groundShadow = FieldRGB("#503E1E", alpha: 0.16); stem = FieldRGB("#6D7B4C")
            sign = FieldRGB("#F3E6C8"); post = FieldRGB("#8A6A44"); soilL = FieldRGB("#CDB98F"); soilR = FieldRGB("#B7A075")
            crops = ["#B98E34", "#8270A8", "#B9673A", "#4F7F80", "#557A41", "#A99B2E", "#6F8F4C", "#BB7C82", "#6B8DAF", "#8E8C47"].map { FieldRGB($0) }
        }
    }
}

enum FieldPalette {
    static let paper = Color(light: "#F5F1E6", dark: "#1E211C")
    static let panel = Color(light: "#FBF8F0", dark: "#262A23")
    static let ink = Color(light: "#2B2A24", dark: "#ECE6D6", contrastLight: "#161511", contrastDark: "#FBF7EC")
    static let muted = Color(light: "#6B675B", dark: "#A9A392", contrastLight: "#454239", contrastDark: "#CFC9B8")
    static let rule = Color(light: "#D9D2C0", dark: "#3E4337", contrastLight: "#9F9680", contrastDark: "#6A725E")
    static let accent = Color(light: "#A94E2A", dark: "#E28A62", contrastLight: "#873818", contrastDark: "#F0A27D")
    static let hedge = Color(light: "#6A7A4F", dark: "#9BAE78", contrastLight: "#475531", contrastDark: "#BDD09B")
}

enum FieldCrop: Int, CaseIterable {
    case wheat, lavender, pumpkin, cabbage, tea, rapeseed, orchard, buckwheat, flax, corn

    func label(locale: Locale = .current) -> String {
        switch self {
        case .wheat: String(localized: "Wheat", locale: locale)
        case .lavender: String(localized: "Lavender", locale: locale)
        case .pumpkin: String(localized: "Pumpkins", locale: locale)
        case .cabbage: String(localized: "Cabbages", locale: locale)
        case .tea: String(localized: "Tea rows", locale: locale)
        case .rapeseed: String(localized: "Rapeseed", locale: locale)
        case .orchard: String(localized: "Orchard", locale: locale)
        case .buckwheat: String(localized: "Buckwheat", locale: locale)
        case .flax: String(localized: "Flax", locale: locale)
        case .corn: String(localized: "Corn", locale: locale)
        }
    }

    // Fixed preferences keep a source on the same crop in every period and on every surface.
    private static let preferred: [String: FieldCrop] = [
        // The ten most used sources each own a crop; the rest share one and only move aside when
        // they meet their crop's owner in the same view.
        "claude": .pumpkin, "codex": .flax, "zcode": .lavender, "omp": .buckwheat, "pi": .wheat,
        "kimi": .tea, "antigravity": .cabbage, "opencode": .rapeseed, "gemini": .orchard, "dsh": .corn,
        "grok": .orchard, "factory": .buckwheat, "devin": .rapeseed, "fx": .flax
    ]

    private static let shared: Set<String> = ["grok", "factory", "devin", "fx"]
    private static func sharesCrop(_ id: String) -> Bool { shared.contains(id) }

    private static func hashed(_ key: String) -> FieldCrop {
        var h: UInt32 = 0
        for scalar in key.unicodeScalars { h = h &* 31 &+ scalar.value }
        return FieldCrop(rawValue: Int(h % UInt32(allCases.count)))!
    }

    /// Crop per item for one view. Larger items keep their preferred crop; a later clash takes the next free one,
    /// so up to ten plots in a view never share a crop.
    static func assign(_ items: [Breakdown]) -> [String: FieldCrop] {
        var used = Set<FieldCrop>(), out: [String: FieldCrop] = [:]
        // Owners of a preferred crop claim it first, so a source keeps its crop whatever else is planted.
        let ordered = items.filter { preferred[$0.id] != nil && !sharesCrop($0.id) } + items.filter { preferred[$0.id] == nil || sharesCrop($0.id) }
        for item in ordered {
            var crop = preferred[item.id] ?? hashed(item.name)
            if used.contains(crop), used.count < allCases.count {
                var i = crop.rawValue
                while used.contains(FieldCrop(rawValue: i % allCases.count)!) { i += 1 }
                crop = FieldCrop(rawValue: i % allCases.count)!
            }
            used.insert(crop)
            out[item.id] = crop
        }
        return out
    }
}

enum FieldSeason: CaseIterable {
    case spring, summer, autumn, winter

    static func of(_ date: Date, calendar: Calendar = .current) -> FieldSeason {
        switch calendar.component(.month, from: date) {
        case 3...5: .spring
        case 6...8: .summer
        case 9...11: .autumn
        default: .winter
        }
    }
}

/// Deterministic RNG so the same field draws the same strokes on every refresh.
struct FieldRNG {
    private var h: UInt32

    init(_ seed: String) {
        var h: UInt32 = 2_166_136_261
        for byte in seed.utf8 { h = (h ^ UInt32(byte)) &* 16_777_619 }
        self.h = h
    }

    mutating func next() -> Double {
        h = h &+ 0x6D2B_79F5
        var t = h
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }
}

/// Squarified treemap: rectangle area proportional to value.
enum FieldTreemap {
    struct Plot { let index: Int; let rect: CGRect }

    static func layout(_ values: [Double], in size: CGSize) -> [Plot] {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return [] }
        let valid = values.enumerated().filter { $0.element > 0 && $0.element.isFinite }
        let total = valid.reduce(0.0) { $0 + $1.element }
        guard total > 0, total.isFinite else { return [] }
        var nodes = valid
            .sorted { $0.element > $1.element }
            .map { (index: $0.offset, area: $0.element / total * size.width * size.height) }
        var rect = CGRect(origin: .zero, size: size), row: [(index: Int, area: Double)] = [], out: [Plot] = []

        func worst(_ r: [(index: Int, area: Double)], _ side: Double) -> Double {
            guard !r.isEmpty, side > 0, side.isFinite else { return .infinity }
            let sum = r.reduce(0) { $0 + $1.area }, mx = r.map(\.area).max()!, mn = r.map(\.area).min()!
            guard sum > 0, mn > 0 else { return .infinity }
            return max(side * side * mx / (sum * sum), sum * sum / (side * side * mn))
        }
        func place(_ r: [(index: Int, area: Double)]) {
            guard !r.isEmpty, rect.width > 0, rect.height > 0 else { return }
            let sum = r.reduce(0) { $0 + $1.area }
            guard sum > 0 else { return }
            if rect.width >= rect.height {
                let cw = min(rect.width, sum / rect.height)
                guard cw > 0 else { return }
                var y = rect.minY
                for n in r { let h = n.area / cw; out.append(Plot(index: n.index, rect: CGRect(x: rect.minX, y: y, width: cw, height: h))); y += h }
                rect = CGRect(x: rect.minX + cw, y: rect.minY, width: max(0, rect.width - cw), height: max(0, rect.height))
            } else {
                let rh = min(rect.height, sum / rect.width)
                guard rh > 0 else { return }
                var x = rect.minX
                for n in r { let w = n.area / rh; out.append(Plot(index: n.index, rect: CGRect(x: x, y: rect.minY, width: w, height: rh))); x += w }
                rect = CGRect(x: rect.minX, y: rect.minY + rh, width: max(0, rect.width), height: max(0, rect.height - rh))
            }
        }
        while !nodes.isEmpty {
            let side = min(rect.width, rect.height)
            guard side > 0, side.isFinite else { break }
            if row.isEmpty || worst(row + [nodes[0]], side) <= worst(row, side) {
                row.append(nodes.removeFirst())
            } else {
                place(row)
                row = []
            }
        }
        if !row.isEmpty { place(row) }
        return out
    }
}

// MARK: - App icon

/// Themes with their own artwork (Field and Cosmos) ship it as a bundled icns, so every size, including the
/// simplified 16 and 32 pt cuts, reaches the Dock and Finder. Liquid Glass uses the bundle's AppIcon.
@MainActor
enum ThemeAppIcon {
    private static let fieldImage = bundledIcon("FieldAppIcon")
    private static let cosmosImage = bundledIcon("CosmosAppIcon")

    private static func bundledIcon(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "icns").flatMap(NSImage.init(contentsOf:))
    }

    static func image(for theme: AppTheme) -> NSImage? {
        switch theme {
        case .field: fieldImage
        case .cosmos: cosmosImage
        case .liquidGlass: nil
        }
    }

    /// Last icon written to the bundle: nil means not yet written this launch.
    private static var bundleIconKey: String?

    /// The Dock icon follows the theme. Stage Manager, Finder and Launchpad read the bundle's icon rather than
    /// `applicationIconImage`, so the same image is also set as the bundle's custom icon and cleared for other themes.
    static func apply(_ theme: AppTheme) {
        guard let app = NSApp else { return }
        let image = image(for: theme)
        app.applicationIconImage = image
        setBundleIcon(image, key: image == nil ? "default" : theme.rawValue)
    }

    /// A custom icon is Finder metadata on the bundle; it fails `codesign --strict` but not Gatekeeper or launch checks.
    /// Writing fails quietly when the bundle isn't writable, which leaves the shipped icon in place.
    private static func setBundleIcon(_ image: NSImage?, key: String) {
        guard key != bundleIconKey else { return }
        bundleIconKey = key
        let path = Bundle.main.bundlePath
        if image == nil, !FileManager.default.fileExists(atPath: path + "/Icon\r") { return }
        NSWorkspace.shared.setIcon(image, forFile: path, options: [])
    }
}
