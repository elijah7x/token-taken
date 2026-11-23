Status: Draft v1 (2026-11-22)

# Theme contract

## Theme structure

- A theme is a complete set of design tokens for materials, colors, typography, chart styles, iconography, and motion, plus optional component skins.
- Theme IDs are `liquid-glass`, `sketchbook`, and `cosmos`. v1 ships Liquid Glass, Field (`sketchbook`), and Cosmos (宇宙); the token-based theme system exists from day one.
- A theme applies app-wide: main window, menu bar extra, Settings, and share card. A Dock icon variant is optional and must be documented by the theme.
- A new theme ships only when its token set is complete and its required screenshot set has been accepted.

## Theme system

- Themes define semantic roles once; feature views consume those roles and MUST NOT branch on the theme for layout.
- Every theme provides values for four role sets:
  - **Type roles**: `heroNumber`, `heroUnit`, `secondaryNumber`, `title`, `sectionHeader`, `body`, `bodyStrong`, `label`, `caption`, `numericCaption`, and `control`. Rank is fixed across themes: `heroNumber` always dominates, secondary figures such as estimated cost MUST NOT exceed the hero, and `caption` MUST NOT carry primary data.
  - **Radius roles**: `tray`, `card`, `inner`, `control`, and `badge`. Cosmos answers `0` for all five; other themes share one continuous-corner radius ladder.
  - **Chrome tokens**: tray inset, series swatches, rule width, and section rules.
  - **Surfaces**: container materials and strokes are applied through the shared themed surface helpers rather than per-theme container forks.
- Only signature visuals are theme-owned: Liquid Glass Confluence/Lens and vessel, Field farm and inscription, Cosmos Metal scene and menu bar glyph, collecting glyphs, and app icons. Each renders inside a slot reserved by a shared layout.
- New features ship using roles only; introducing any per-theme layout requires a contract change first.
- Every theme presents the same sidebar hierarchy in the same order: period title, hero total, exact count, cost, and notices.

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

## Liquid Glass views

- `liquid-glass` provides a **View** (`liquidView`) setting with two schematic thumbnail choices: **Confluence** (`confluence`, default) and **Lens** (`lens`).
- Confluence renders the period's harnesses or models flowing into the reservoir and out into token categories. Lens swaps only that central hero visual for a fixed-height three-column glass readout card above a stacked time-bar chart with an interactive Liquid Glass magnifier for single-bucket and contiguous-range inspection, keeping the surrounding tray, dimension switch, and breakdown list unchanged.
- The View setting and Lens apply exclusively to `liquid-glass`; Field (`sketchbook`) and Cosmos (`cosmos`) keep their own approved scenes and do not expose or share Lens.

## Menu bar

- The menu-bar presentation follows the effective app appearance (Follow System by default), including a documented dark-only theme's forced dark appearance, and remains minimal.
- It uses the same statistics semantics as the main app and MUST NOT introduce a separate total, hidden rounding rule, or theme-dependent meaning.

## Share card

- Every theme uses one shared share card layout with a theme-owned hero visual slot.
- Portrait and square cards place the hero visual on top; landscape cards place it on the left.
- The text column follows a fixed hierarchy:
  - **Header**: app identity and period label.
  - **L1**: hero total, plus an optional estimated cost line.
  - **L2**: one context line, plus an optional rank line with its inline estimate disclaimer.
  - **L3**: one supporting block chosen by a **Detail** control: **Top 3** (default), **Composition**, or **None**.
- Field additionally supports its optional inscription and signature within the shared layout.
- Text MUST remain at least `24pt` on the `1080pt` short side across all aspects and themes.

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
- Below the field, a paper composition strip shows the five token categories (plus uncategorized when present), and the plot list keeps the shared breakdown details: the model cache detail popover and "Mainly from" lines.
- The menu bar extra shows today's field with crop flags instead of signs.
- The Field share card can carry an inscription (up to 40 characters) and a signature (up to 24). Both are written on the card only and are never saved or synced.
- Field replaces every Liquid Glass surface with opaque paper surfaces, uses serif type (New York with Songti SC), uses the shared themed period picker unframed, with only Field's furrow under the selected period, and swaps the Dock and Finder icon at runtime to the bundled `FieldAppIcon.icns` (a hand-drawn coin whose T is a tree).

## Cosmos (`cosmos`)

- Cosmos (宇宙) is the approved A3 视界 design. A Metal ray marcher hosted by `MTKView` draws the black hole, accretion disk, and bodies in one scene; the brighter starfield is ambient and carries no usage data.
- The disk consists of five contiguous radial bands whose widths encode category shares in `cacheRead`, `input`, `cacheWrite`, `output`, `reasoning` order—colored `#EAF2FF`, `#FFF0D2`, `#E8C48E`, `#D99A56`, and `#B65A35` respectively—plus an optional sixth outermost neutral band (`#8A93A3`) shown only when uncategorized tokens are greater than zero.
- The top six sources or models become bodies. Relative share to the power 0.78 determines size, tokens per hour determines orbital speed, and stable identity selects the surface variant. Exact orbital angle is not a data dimension. Items after the top six become dust; dust point count represents item count, not tokens.
- The scene includes labels, hover readouts, category legend, dust label, and flow caption. The shared period picker, totals, cost, devices, and ranked top-four list with Show all remain outside it, preserving the same statistics and controls as other themes.
- The menu bar extra shows today's compact Cosmos scene when today has usage. On the shared share card, Cosmos renders its scene in the hero visual slot (falling back to a plain dark panel if a snapshot is unavailable), and a scoped card renders the scope's breakdown along the other dimension (a source shows its models, a model its sources).
- Cosmos uses system sans type, monospaced tabular figures for numeric readouts, and opaque dark panels. It does not use Liquid Glass or serif type; the shared period picker, segmented controls, toggles, and buttons take Cosmos's square, bordered styling, and breakdown rows carry no per-item color dots.
- Adaptive render scale limits GPU cost. Reduce Motion renders a still frame without removing data or interactions. Metal failure leaves the surrounding usage data and ranked list available.
- Cosmos is dark only: it disables the Light/Dark/Follow System control, shows an explanation, and forces dark appearance without changing the saved preference. It swaps the Dock and Finder icon at runtime to the bundled `CosmosAppIcon.icns`, the same coin as a dark mass pressing a glowing spacetime grid into a gravity well.

## Open questions

- Approved reference-design location and the final required screenshot matrix.
- Cosmos native performance acceptance.
