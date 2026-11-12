import SwiftUI
import UIKit

/// Presentation tokens ported from the macOS app's `TokenTaken/Palette.swift`.
/// Dynamic colors resolve through `UITraitCollection`, so the share card can be rendered
/// with an explicit color scheme through `.environment(\.colorScheme, ...)`.
enum Palette {
    static let ink1 = Color.dynamic(light: "#131A24", dark: "#EEF2F8")
    static let ink2 = Color.dynamic(light: "#465264", dark: "#A9B5C7")
    static let ink3 = Color.dynamic(light: "#6C788A", dark: "#7B889C")

    static let solid = Color.dynamic(light: "#F4F6FA", dark: "#0D121A")
    static let cardSurface = Color.dynamic(light: "#FFFFFF", dark: "#1B212C")
    static let hairline = Color.dynamic(light: "#0F172A26", dark: "#FFFFFF26")

    static let accent = Color.dynamic(light: "#0068D6", dark: "#56A8FF")
    static let ok = Color.dynamic(light: "#178750", dark: "#3BD184")
    static let warn = Color.dynamic(light: "#B56100", dark: "#FFB340")

    private static let sourceFallback: [Color] = [
        Color.dynamic(light: "#D47353", dark: "#E4896A"),
        Color.dynamic(light: "#C8963E", dark: "#DFB059"),
        Color.dynamic(light: "#517ED1", dark: "#6D98E8"),
        Color.dynamic(light: "#C26F96", dark: "#D987AD"),
        Color.dynamic(light: "#4C9E79", dark: "#68BA93"),
        Color.dynamic(light: "#7D6EC4", dark: "#9788DE"),
    ]

    static func color(forSource id: String) -> Color {
        switch id.lowercased() {
        case "claude", "claude-code":
            return Color.dynamic(light: "#D47353", dark: "#E4896A")
        case "codex":
            return Color.dynamic(light: "#517ED1", dark: "#6D98E8")
        case "cursor":
            return Color.dynamic(light: "#2B8EA8", dark: "#49AFC9")
        case "pi":
            return Color.dynamic(light: "#C8963E", dark: "#DFB059")
        case "kimi", "kimi-code":
            return Color.dynamic(light: "#C26F96", dark: "#D987AD")
        case "zcode":
            return Color.dynamic(light: "#4C9E79", dark: "#68BA93")
        case "omp", "oh-my-pi":
            return Color.dynamic(light: "#7D6EC4", dark: "#9788DE")
        default:
            let hash = fnv1a64(id.lowercased())
            return sourceFallback[Int(hash % UInt64(sourceFallback.count))]
        }
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

extension Color {
    /// `#RRGGBB`, `#RRGGBBAA`; invalid input yields gray so a bad value stays visible.
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard (digits.count == 6 || digits.count == 8), let value = UInt32(digits, radix: 16) else {
            self = .gray
            return
        }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: digits.count == 8 ? Double(value & 0xFF) / 255 : 1
        )
    }

    static func dynamic(light: String, dark: String) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
    }

    /// Flat blend of two colors, the iOS stand-in for the macOS app's `Color.mix(with:by:)`.
    func mixed(with other: Color, by fraction: Double) -> Color {
        let amount = min(max(fraction, 0), 1)
        let first = UIColor(self)
        let second = UIColor(other)
        var red1: CGFloat = 0, green1: CGFloat = 0, blue1: CGFloat = 0, alpha1: CGFloat = 0
        var red2: CGFloat = 0, green2: CGFloat = 0, blue2: CGFloat = 0, alpha2: CGFloat = 0
        guard first.getRed(&red1, green: &green1, blue: &blue1, alpha: &alpha1),
              second.getRed(&red2, green: &green2, blue: &blue2, alpha: &alpha2)
        else { return self }
        return Color(
            .sRGB,
            red: Double(red1 + (red2 - red1) * amount),
            green: Double(green1 + (green2 - green1) * amount),
            blue: Double(blue1 + (blue2 - blue1) * amount),
            opacity: Double(alpha1 + (alpha2 - alpha1) * amount)
        )
    }
}
