Status: Draft v0 (2026-11-09)

# Theme contract

## Theme structure

- A theme is a complete set of design tokens for materials, colors, typography, chart styles, iconography, and motion, plus optional component skins.
- Theme IDs are `liquid-glass`, `geek`, and `sketchbook`. v1 ships `liquid-glass` and `sketchbook` (shown as Field); the token-based theme system exists from day one.
- `geek` is a later theme, not a hidden or partially selectable v1 option.
- A theme applies app-wide: main window, menu bar extra, Settings, share card, and the Dock icon.
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
- Every theme supports light and dark appearances. The user chooses Follow System, Light, or Dark in Settings; the choice applies to every window and the menu bar extra. Text contrast MUST meet at least WCAG AA in both appearances and all interactive states.
- Every theme MUST preserve legibility and layout for English (`en`) and Simplified Chinese (`zh-Hans`) without changing number semantics.

## Menu bar

- The menu-bar presentation follows the app's light/dark setting (Follow System by default) and remains minimal.
- It uses the same statistics semantics as the main app and MUST NOT introduce a separate total, hidden rounding rule, or theme-dependent meaning.

## Visual acceptance

- Acceptance requires real screenshots of the built app, not mockups, in both light and dark appearances, compared against the approved reference design.
- Screenshots MUST cover the required screens and representative loading, empty, error, and populated states; accessibility variants are required when they change material or contrast behavior.
- A new theme's screenshot set MUST use the same screens and data as the accepted reference set so information parity can be reviewed.
- Visual approval does not waive accessibility, responsive-layout, or information-integrity requirements.

## Field (`sketchbook`)

- Field draws usage as a hand-drawn farm. Each source or model is one plot; plot area and plant count are proportional to tokens at a fixed planting density, and the crop identifies the source or model.
- Only the plots carry data. River, canals, fence, buildings, trees, animals, season, and day or night are scenery and MUST NOT encode numbers. The season follows the current date and changes scenery only; crop colors never change with season.
- Each plot shows its name, short token total, and share on a sign when it fits; a plot too small for a sign gets a flag in its crop color. Exact values are always available in the list below the field and in the hover tooltip.
- A source keeps the same crop and color in every view and period. The ten most used sources each own a crop; the remaining sources share one and move to a free crop only when they meet that crop's owner in the same view. Model crops are assigned per view and may differ between periods.
- The water wheel, chimney smoke, and night fireflies move in the main window. They hold still under Reduce Motion, in the menu bar extra, and on share cards.
- The menu bar extra shows today's field with crop flags instead of signs.
- The Field share card can carry an inscription (up to 40 characters) and a signature (up to 24). Both are written on the card only and are never saved or synced.
- Field replaces every Liquid Glass surface with opaque paper surfaces, uses serif type (New York with Songti SC), and swaps the Dock icon at runtime. The Finder icon stays the bundle icon.

## Open questions

- Approved reference-design location and the final required screenshot matrix.
- Complete token values and component skins for `geek` after v1.
