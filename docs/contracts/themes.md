Status: Draft v0 (2026-11-09)

# Theme contract

## Theme structure

- A theme is a complete set of design tokens for materials, colors, typography, chart styles, iconography, and motion, plus optional component skins.
- Theme IDs are `liquid-glass`, `sketchbook`, and `cosmos`. v1 ships Liquid Glass, Field (`sketchbook`), and Cosmos (宇宙); the token-based theme system exists from day one.
- A theme applies app-wide: main window, menu bar extra, Settings, and share card. A Dock icon variant is optional and must be documented by the theme.
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
- Themes support light and dark appearances unless a theme is explicitly documented as dark only. A dark-only theme MUST force dark appearance in every window and the menu bar extra while selected, MUST NOT overwrite the saved appearance preference, and MUST restore that preference when another theme is selected.
- Where appearance selection is supported, the user chooses Follow System, Light, or Dark in Settings and the choice applies to every window and the menu bar extra. Text contrast MUST meet at least WCAG AA in every supported appearance and all interactive states.
- Every theme MUST preserve legibility and layout for English (`en`) and Simplified Chinese (`zh-Hans`) without changing number semantics.

## Menu bar

- The menu-bar presentation follows the effective app appearance (Follow System by default), including a documented dark-only theme's forced dark appearance, and remains minimal.
- It uses the same statistics semantics as the main app and MUST NOT introduce a separate total, hidden rounding rule, or theme-dependent meaning.

## Visual acceptance

- Acceptance requires real screenshots of the built app, not mockups, in every supported appearance—both light and dark unless the theme is documented as dark only—compared against the approved reference design.
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
- Field replaces every Liquid Glass surface with opaque paper surfaces, uses serif type (New York with Songti SC), and swaps the Dock and Finder icon at runtime to the bundled `FieldAppIcon.icns` (a hand-drawn coin whose T is a tree).

## Cosmos (`cosmos`)

- Cosmos (宇宙) is the approved A3 视界 design. A Metal ray marcher hosted by `MTKView` draws the black hole, accretion disk, and bodies in one scene; the brighter starfield is ambient and carries no usage data.
- The five disk bands are contiguous radial bands whose widths encode category shares in `cacheRead`, `input`, `cacheWrite`, `output`, `reasoning` order. Their colors are `#EAF2FF`, `#FFF0D2`, `#E8C48E`, `#D99A56`, and `#B65A35` respectively.
- The top six sources or models become bodies. Relative share to the power 0.78 determines size, tokens per hour determines orbital speed, and stable identity selects the surface variant. Exact orbital angle is not a data dimension. Items after the top six become dust; dust point count represents item count, not tokens.
- The scene includes labels, hover readouts, category legend, dust label, and flow caption. The shared period picker, totals, cost, devices, and ranked top-four list with Show all remain outside it, preserving the same statistics and controls as other themes.
- The menu bar extra shows today's compact Cosmos scene when today has usage. The share card offers the same scope (overall, one source, one model), aspect (2:3, 1:1, 3:2), cost and composition options as the other themes. Wide cards put the scene left of the info panel; square and tall cards put it above. A scoped card renders the scope's breakdown along the other dimension (a source shows its models, a model its sources). The card shows period totals, estimated cost with the existing disclaimer when enabled, the top three items, and the five-category composition when enabled; an unavailable snapshot falls back to a plain dark panel.
- Cosmos uses system sans type, monospaced tabular figures for numeric readouts, and opaque dark panels. It does not use Liquid Glass, serif type, or Field's custom period picker; its period picker, segmented controls, toggles and buttons are square, bordered Cosmos controls, and breakdown rows carry no per-item color dots.
- Adaptive render scale limits GPU cost. Reduce Motion renders a still frame without removing data or interactions. Metal failure leaves the surrounding usage data and ranked list available.
- Cosmos is dark only: it disables the Light/Dark/Follow System control, shows an explanation, and forces dark appearance without changing the saved preference. It swaps the Dock and Finder icon at runtime to the bundled `CosmosAppIcon.icns`, the same coin as a dark mass pressing a glowing spacetime grid into a gravity well.

## Open questions

- Approved reference-design location and the final required screenshot matrix.
- Cosmos native performance acceptance.
