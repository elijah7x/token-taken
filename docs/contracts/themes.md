Status: Draft v0 (2026-11-09)

# Theme contract

## Theme structure

- A theme is a complete set of design tokens for materials, colors, typography, chart styles, iconography, and motion, plus optional component skins.
- Theme IDs are `liquid-glass`, `geek`, and `sketchbook`. v1 ships `liquid-glass` only; the token-based theme system exists from day one.
- `geek` and `sketchbook` are later themes, not hidden or partially selectable v1 options.
- A new theme ships only when its token set is complete and its required screenshot set has been accepted.

## Information integrity

- Every theme renders the same information architecture, source health, loading, empty, error, partial, stale, and unpriced states, and exactly the same numbers.
- A theme MUST NOT hide data, alter aggregation, reorder information to change its meaning, or use decoration that implies nonexistent data.
- Component skins can change presentation only. Shared behavior and statistics remain in the app and `TokenTakenKit`, not in theme code.

## Liquid Glass and accessibility

- `liquid-glass` uses only native SwiftUI `glassEffect` and AppKit `NSGlassEffectView` APIs for glass. CSS, web views, and custom translucency approximations MUST NOT substitute for native glass.
- Honor Reduce Transparency, Increase Contrast, and Reduce Motion in every theme.
- With Reduce Transparency, glass MUST fall back to opaque system materials while preserving hierarchy and legibility.
- Increase Contrast MUST strengthen relevant system-provided separation and text legibility; Reduce Motion MUST remove nonessential motion without removing information or state feedback.
- Every theme supports light and dark appearances. Text contrast MUST meet at least WCAG AA in both appearances and all interactive states.
- Every theme MUST preserve legibility and layout for English (`en`) and Simplified Chinese (`zh-Hans`) without changing number semantics.

## Menu bar

- The menu-bar presentation follows the current system appearance and remains minimal.
- It uses the same statistics semantics as the main app and MUST NOT introduce a separate total, hidden rounding rule, or theme-dependent meaning.

## Visual acceptance

- Acceptance requires real screenshots of the built app, not mockups, in both light and dark appearances, compared against the approved reference design.
- Screenshots MUST cover the required screens and representative loading, empty, error, and populated states; accessibility variants are required when they change material or contrast behavior.
- A new theme's screenshot set MUST use the same screens and data as the accepted reference set so information parity can be reviewed.
- Visual approval does not waive accessibility, responsive-layout, or information-integrity requirements.

## Open questions

- Approved reference-design location and the final required screenshot matrix.
- Complete token values and component skins for `geek` and `sketchbook` after v1.
