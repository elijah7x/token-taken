import AppKit
import SwiftUI

// The theme contract (docs/contracts/themes.md, "Theme system").
//
// Feature views never branch on the theme. They ask for a *role*: a type role for text, a
// surface role for a container, a radius role for a shape. Each theme answers every role once,
// here. A new feature that only uses roles adapts to every theme with no per-theme code.
// The only theme-owned views are the signature visuals (Confluence/Lens, the Field farm,
// the Cosmos scene); they sit in a slot that the shared layout reserves.

enum ThemeKind {
    case liquidGlass
    case field
    case cosmos

    /// Mirrors `ThemeRuntime`, which `AppSettings` keeps in step and which forces a full rebuild on change.
    static var current: ThemeKind {
        if ThemeRuntime.isCosmos { return .cosmos }
        if ThemeRuntime.isField { return .field }
        return .liquidGlass
    }
}

// MARK: - Typography

/// Semantic text roles. Rank is fixed across themes: `heroNumber` always dominates,
/// `secondaryNumber` is always smaller than it, and `caption` never carries primary data.
enum TypeRole {
    /// The single dominant figure of a surface (period total tokens).
    case heroNumber
    /// The unit beside the hero figure ("tokens").
    case heroUnit
    /// A supporting figure (estimated cost, a row total).
    case secondaryNumber
    /// Surface or section title ("This month · Nov 2026").
    case title
    /// Small header above a group.
    case sectionHeader
    /// Running text and row names.
    case body
    /// Emphasised running text.
    case bodyStrong
    /// Small label above or beside a figure.
    case label
    /// Notes, disclaimers, metadata.
    case caption
    /// Small figures inside rows and captions (exact counts, percentages).
    case numericCaption
    /// Text inside controls (segments, buttons).
    case control

    fileprivate var spec: (size: CGFloat, weight: Font.Weight, numeric: Bool) {
        switch self {
        case .heroNumber: (40, .bold, true)
        case .heroUnit: (13, .medium, false)
        case .secondaryNumber: (17, .semibold, true)
        case .title: (13, .semibold, false)
        case .sectionHeader: (11, .semibold, false)
        case .body: (13, .regular, false)
        case .bodyStrong: (13, .medium, false)
        case .label: (11, .regular, false)
        case .caption: (11, .regular, false)
        case .numericCaption: (11, .regular, true)
        case .control: (12, .medium, false)
        }
    }

    var defaultSize: CGFloat { spec.size }
}

enum ThemeFont {
    /// The theme's face for a role. `size` overrides the role's default size (share cards scale it).
    static func role(_ role: TypeRole, size: CGFloat? = nil) -> Font {
        let spec = role.spec
        return make(size ?? spec.size, weight: spec.weight, numeric: spec.numeric)
    }

    /// The theme's face at an explicit size. `numeric` marks figures: tabular digits in Liquid Glass
    /// and Field, the monospaced face in Cosmos. Prefer `role(_:)`; use this only for scaled layouts.
    static func make(_ size: CGFloat, weight: Font.Weight = .regular, numeric: Bool = false) -> Font {
        switch ThemeKind.current {
        case .cosmos:
            if numeric {
                return .system(size: size, weight: weight, design: .monospaced)
            }
            return .system(size: size, weight: weight)
        case .field:
            // Serif semibold reads heavy; a step lighter keeps headings quiet.
            return FieldFont.serif(size, weight: nsWeight(weight == .semibold ? .medium : weight))
                .monospacedDigit()
        case .liquidGlass:
            let font = Font.system(size: size, weight: weight)
            return numeric ? font.monospacedDigit() : font
        }
    }

    static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}

// MARK: - Shape and chrome

/// Corner roles. Cosmos is square everywhere; the other themes share one radius ladder.
enum RadiusRole {
    case tray, card, inner, control, badge

    var value: CGFloat {
        if ThemeKind.current == .cosmos { return 0 }
        switch self {
        case .tray: return Radius.tray
        case .card: return Radius.card
        case .inner: return Radius.inner
        case .control: return 8
        case .badge: return Radius.badge
        }
    }

    var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: value, style: .continuous)
    }
}

enum ThemeChrome {
    /// Gap between the window edge and the floating tray. Cosmos docks the tray flush.
    static var trayInset: CGFloat { ThemeKind.current == .cosmos ? 0 : 8 }
    /// Series rows carry a colour dot and a proportion bar, except in Cosmos, which uses ruled rows.
    static var showsSeriesSwatches: Bool { ThemeKind.current != .cosmos }
    /// Hairline width for ruled containers.
    static var ruleWidth: CGFloat { ThemeKind.current == .liquidGlass ? 0.5 : 1 }
    /// Cosmos separates rail sections with full-width rules; other themes use space alone.
    static var separatesSectionsWithRules: Bool { ThemeKind.current == .cosmos }
}
