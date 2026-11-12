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
    static let ink = Color(light: "#2B2A24", dark: "#ECE6D6")
    static let muted = Color(light: "#6B675B", dark: "#A9A392")
    static let rule = Color(light: "#D9D2C0", dark: "#3E4337")
    static let accent = Color(light: "#A94E2A", dark: "#E28A62")
    static let hedge = Color(light: "#6A7A4F", dark: "#9BAE78")
}

enum FieldCrop: Int, CaseIterable {
    case wheat, lavender, pumpkin, cabbage, tea, rapeseed, orchard, buckwheat, flax, corn

    func label(chinese: Bool) -> String {
        switch self {
        case .wheat: chinese ? "麦田" : "Wheat"
        case .lavender: chinese ? "薰衣草" : "Lavender"
        case .pumpkin: chinese ? "南瓜地" : "Pumpkins"
        case .cabbage: chinese ? "卷心菜" : "Cabbages"
        case .tea: chinese ? "茶垄" : "Tea rows"
        case .rapeseed: chinese ? "油菜花" : "Rapeseed"
        case .orchard: chinese ? "果园" : "Orchard"
        case .buckwheat: chinese ? "荞麦" : "Buckwheat"
        case .flax: chinese ? "亚麻" : "Flax"
        case .corn: chinese ? "玉米" : "Corn"
        }
    }

    // Fixed preferences keep a source on the same crop in every period and on every surface.
    private static let preferred: [String: FieldCrop] = [
        "claude": .pumpkin, "codex": .flax, "zcode": .lavender, "omp": .buckwheat, "pi": .wheat,
        "kimi": .tea, "grok": .cabbage, "opencode": .rapeseed, "gemini": .orchard,
        "factory": .corn, "devin": .wheat, "antigravity": .lavender, "dsh": .corn, "fx": .rapeseed
    ]

    private static func hashed(_ key: String) -> FieldCrop {
        var h: UInt32 = 0
        for scalar in key.unicodeScalars { h = h &* 31 &+ scalar.value }
        return FieldCrop(rawValue: Int(h % UInt32(allCases.count)))!
    }

    /// Crop per item for one view. Larger items keep their preferred crop; a later clash takes the next free one,
    /// so up to ten plots in a view never share a crop.
    static func assign(_ items: [Breakdown]) -> [String: FieldCrop] {
        var used = Set<FieldCrop>(), out: [String: FieldCrop] = [:]
        for item in items {
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
        let total = values.reduce(0, +)
        guard total > 0 else { return [] }
        var nodes = values.enumerated().filter { $0.element > 0 }
            .sorted { $0.element > $1.element }
            .map { (index: $0.offset, area: $0.element / total * size.width * size.height) }
        var rect = CGRect(origin: .zero, size: size), row: [(index: Int, area: Double)] = [], out: [Plot] = []

        func worst(_ r: [(index: Int, area: Double)], _ side: Double) -> Double {
            guard !r.isEmpty else { return .infinity }
            let sum = r.reduce(0) { $0 + $1.area }, mx = r.map(\.area).max()!, mn = r.map(\.area).min()!
            return max(side * side * mx / (sum * sum), sum * sum / (side * side * mn))
        }
        func place(_ r: [(index: Int, area: Double)]) {
            let sum = r.reduce(0) { $0 + $1.area }
            if rect.width >= rect.height {
                let cw = sum / rect.height
                var y = rect.minY
                for n in r { let h = n.area / cw; out.append(Plot(index: n.index, rect: CGRect(x: rect.minX, y: y, width: cw, height: h))); y += h }
                rect = CGRect(x: rect.minX + cw, y: rect.minY, width: rect.width - cw, height: rect.height)
            } else {
                let rh = sum / rect.width
                var x = rect.minX
                for n in r { let w = n.area / rh; out.append(Plot(index: n.index, rect: CGRect(x: x, y: rect.minY, width: w, height: rh))); x += w }
                rect = CGRect(x: rect.minX, y: rect.minY + rh, width: rect.width, height: rect.height - rh)
            }
        }
        while !nodes.isEmpty {
            let side = min(rect.width, rect.height)
            if worst(row + [nodes[0]], side) <= worst(row, side) { row.append(nodes.removeFirst()) } else { place(row); row = [] }
        }
        if !row.isEmpty { place(row) }
        return out
    }
}

// MARK: - App icon

/// The 田 icon: four unequal plots split by a cross of paths, like the main window.
struct FieldAppIcon: View {
    let isDark: Bool

    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 100
            let c = FieldColors(isDark: isDark)
            let bg = Path(roundedRect: CGRect(x: 8 * s, y: 8 * s, width: 84 * s, height: 84 * s), cornerRadius: 19 * s, style: .continuous)
            ctx.fill(bg, with: .color((isDark ? FieldRGB("#23271F") : FieldRGB("#F3EEDF")).color))
            ctx.stroke(bg, with: .color(c.rule.color), lineWidth: 1.2 * s)
            let plots: [(CGRect, Int)] = [
                (CGRect(x: 20, y: 20, width: 34, height: 32), 0), (CGRect(x: 58, y: 20, width: 22, height: 32), 1),
                (CGRect(x: 20, y: 56, width: 34, height: 24), 4), (CGRect(x: 58, y: 56, width: 22, height: 24), 2)
            ]
            for (rect, crop) in plots {
                let r = CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s)
                ctx.fill(Path(roundedRect: r, cornerRadius: 4 * s), with: .color(c.crops[crop].mix(c.paper, 0.85).color))
                var rows = Path()
                var y = r.minY + 4 * s
                while y < r.maxY - 2 * s { rows.move(to: CGPoint(x: r.minX + 3 * s, y: y)); rows.addLine(to: CGPoint(x: r.maxX - 3 * s, y: y)); y += 5 * s }
                ctx.stroke(rows, with: .color(c.crops[crop].mix(.white, 0.55).color), style: StrokeStyle(lineWidth: 1.4 * s, lineCap: .round))
            }
            var sprout = Path()
            sprout.move(to: CGPoint(x: 37 * s, y: 46 * s)); sprout.addLine(to: CGPoint(x: 37 * s, y: 34 * s))
            ctx.stroke(sprout, with: .color(c.stem.color), style: StrokeStyle(lineWidth: 2 * s, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: 37 * s, y: 29 * s, width: 9 * s, height: 5 * s)), with: .color(c.stem.color))
            ctx.fill(Path(ellipseIn: CGRect(x: 29 * s, y: 31 * s, width: 8 * s, height: 4.5 * s)), with: .color(c.stem.color))
            ctx.fill(Path(ellipseIn: CGRect(x: 66 * s, y: 26 * s, width: 7 * s, height: 7 * s)), with: .color(c.sun.color))
        }
        .frame(width: 512, height: 512)
    }
}

@MainActor
enum FieldAppIconSwitcher {
    /// The Dock icon follows the theme. The Finder icon stays the bundle icon.
    static func apply(_ theme: AppTheme) {
        guard let app = NSApp else { return }
        switch theme {
        case .liquidGlass:
            app.applicationIconImage = nil
        case .field:
            let isDark = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let renderer = ImageRenderer(content: FieldAppIcon(isDark: isDark))
            renderer.scale = 2
            if let image = renderer.nsImage { app.applicationIconImage = image }
        }
    }
}
