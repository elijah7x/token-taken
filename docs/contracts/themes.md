Status: Draft v1 (2026-11-22)

# Theme contract

## Theme structure

- A theme is a complete set of design tokens for materials, colors, typography, chart styles, iconography, and motion, plus optional component skins.
- Theme IDs are `liquid-glass`, `sketchbook`, and `cosmos`. v1 ships Liquid Glass, Field (`sketchbook`), and Cosmos (宇宙); the token-based theme system exists from day one.
- A theme applies app-wide: main window, menu bar extra, Settings, and share card. The system application icon is not theme-owned: Dock, Finder, and Launchpad always use the default brand icon compiled into the bundle. Themes MUST NOT replace `NSApp.applicationIconImage` or write a custom icon to the app bundle.
- Field and Cosmos may use their bundled icon artwork for card branding without changing the system application icon. A one-time migration removes custom bundle icons left by older releases; later launches and theme changes leave the bundle untouched ([ADR-0019](../decisions/0019-stable-application-icon.md)).
- A new theme ships only when its token set is complete and its required screenshot set has been accepted.

## Theme system

- Themes define semantic roles once; feature views consume those roles and MUST NOT branch on the theme for layout.
- Every theme provides values for four role sets:
  - **Type roles**: `heroNumber`, `heroUnit`, `secondaryNumber`, `title`, `sectionHeader`, `body`, `bodyStrong`, `label`, `caption`, `numericCaption`, and `control`. Rank is fixed across themes: `heroNumber` always dominates, secondary figures such as estimated cost MUST NOT exceed the hero, and `caption` MUST NOT carry primary data.
  - **Radius roles**: `tray`, `card`, `inner`, `control`, and `badge`. Cosmos answers `0` for all five; other themes share one continuous-corner radius ladder.
  - **Chrome tokens**: tray inset, series swatches, rule width, and section rules.
  - **Surfaces**: container materials and strokes are applied through the shared themed surface helpers rather than per-theme container forks.
- Only signature visuals are theme-owned: Liquid Glass Confluence/Lens and vessel, Field farm and inscription, Cosmos Metal scene and menu bar glyph, collecting glyphs, and card brand artwork. Each renders inside a slot reserved by a shared layout.
- New features ship using roles only; introducing any per-theme layout requires a contract change first.
- Every theme presents the same sidebar hierarchy in the same order: period control, short hero total and unit, estimated cost or unpriced state, then Devices and sync notices. The tray has no persistent exact-count row or breakdown cards.
- The short total and cost use `DataHoverPopover` for on-demand detail. The total popover shows the locale-formatted exact token count. The cost popover shows the estimate disclaimer, price-table version, and any unpriced tokens excluded from the estimate. Hover reveals detail; click or keyboard activation pins it, and Escape dismisses it.
- The shared breakdown below the hero visual remains a single-column list. Its footer summarizes hidden rows and uses **Show all** / **Show less** to expand or collapse them.
- Settings uses flat, unframed sections on the themed base rather than nested trays or internal secondary rules. Section spacing is 36pt, caption-to-content spacing is 12pt, regular rows are at least 48pt tall, and action controls are 28pt tall. Repeated source, sync, version, and release-note labels appear once.

## Information integrity

- Every theme renders the same information architecture, source health, loading, empty, error, partial, stale, and unpriced states, and exactly the same numbers.
- A theme MUST NOT hide data, alter aggregation, reorder information to change its meaning, or use decoration that implies nonexistent data.
- Short totals and collapsed rows MUST NOT discard detail. The exact counts, shares, pricing caveats, and coverage states required by each view remain available in its on-demand popover or accessibility value. Missing hourly coverage and unpriced usage MUST NOT appear as measured zero usage or zero cost.
- Component skins can change presentation only. Shared behavior and statistics remain in the app and `TokenTakenKit`, not in theme code.

## Liquid Glass and accessibility

- `liquid-glass` uses only native SwiftUI `glassEffect` and AppKit `NSGlassEffectView` APIs for glass. CSS, web views, and custom translucency approximations MUST NOT substitute for native glass.
- Honor Reduce Transparency, Increase Contrast, and Reduce Motion in every theme.
- With Reduce Transparency, glass MUST fall back to opaque system materials while preserving hierarchy and legibility.
- Increase Contrast MUST strengthen relevant system-provided separation and text legibility; Reduce Motion MUST remove nonessential motion without removing information or state feedback.
- Keyboard focus and VoiceOver MUST expose the same data and state as pointer hover. Data popovers MUST open without a pointer and dismiss with Escape. Lens MUST support keyboard pinning, movement, range resizing, and release; VoiceOver MUST distinguish selected, upcoming, measured-zero, and missing-coverage buckets. Confluence focus MUST expose the same stream values as hover.
- Themes support light and dark appearances unless a theme is explicitly documented as dark only. A dark-only theme MUST force dark appearance in every window and the menu bar extra while selected, MUST NOT overwrite the saved appearance preference, and MUST restore that preference when another theme is selected.
- Where appearance selection is supported, the user chooses Follow System, Light, or Dark in Settings and the choice applies to every window and the menu bar extra. Text contrast MUST meet at least WCAG AA in every supported appearance and all interactive states.
- Every theme MUST preserve legibility and layout for English (`en`) and Simplified Chinese (`zh-Hans`) without changing number semantics.

## Liquid Glass views

- `liquid-glass` provides a **View** (`liquidView`) setting with two schematic thumbnail choices: **Confluence** (`confluence`, default) and **Lens** (`lens`).
- Confluence renders the period's harnesses or models flowing into the reservoir and out into token categories. Hover or keyboard focus presents a `DataHoverCard` with the stream name, short total, share of the complete period, and exact locale-formatted count. Inspection does not filter the scene or the shared summaries.
- Lens swaps only that central hero visual for a flat stacked time-bar chart with readable axes and an interactive Liquid Glass magnifier for single-bucket and contiguous-range inspection. It has no persistent three-column readout card. The surrounding tray, dimension switch, and single-column breakdown list remain shared.
- A bare whole-period composition strip sits below Lens without permanent category labels. `DataHoverPopover` reveals exact category counts and shares, including uncategorized tokens and unavailable reasoning where applicable.
- Hovering a non-future bucket presents a transient slice `DataHoverCard`; click, drag, or keyboard input pins a bucket or contiguous range. Transient overlays are pointer-transparent so they cannot intercept cross-bucket movement; slice composition becomes interactive after pinning. The overlay shows the selected time range, short and exact totals, period share or partial-hourly-coverage state, cost availability, the top three items in the active dimension, and slice composition. Release, double-click, or Escape clears the pin. Resting the magnifier on the peak does not open a slice overlay.
- Slice inspection never filters the complete-period sidebar, composition strip, or ranked breakdown. Changing period releases the pin. Lens resolves pins against available non-future buckets and updates their stored endpoints when the bucket count changes. Day + Models retains explicit missing model-detail and model-pricing notices. Missing hourly coverage remains unknown rather than zero.
- The View setting and Lens apply exclusively to `liquid-glass`; Field (`sketchbook`) and Cosmos (`cosmos`) keep their own approved scenes and do not expose or share Lens.

## Menu bar

- The menu-bar presentation follows the effective app appearance (Follow System by default), including a documented dark-only theme's forced dark appearance, and remains minimal.
- It uses the same statistics semantics as the main app and MUST NOT introduce a separate total, hidden rounding rule, or theme-dependent meaning.

## Share card

- Every theme uses one shared, content-driven share card narrative with a theme-owned hero visual. The card is an achievement poster, not a miniature data report.
- Share cards support landscape (`4:3`) and portrait (`3:4`). Landscape places the primary information at the top and a full-width horizontal visual band below it; portrait places the primary information at the top and a natural-height visual below it. Neither aspect uses a left/right text-and-visual split.
- Information follows this value order:
  1. **Period and total**: the selected period and the dominant hero total. A scoped card also identifies its scope without changing this order.
  2. **Independent rank**: the optional last-30-day usage-rank estimate, labeled directly as a public usage reference with its Token window and estimate disclosure. It is independent of the selected period, scope, and leading harness, MUST disclose its public-source estimate basis, and MUST NOT imply a representative user population or measured global leaderboard.
  3. **Narrative footnote**: one restrained note based on the leading harness or shared leaders in the selected period. It adds no competing total or percentage.
  4. **Compressed share evidence**: one supporting block chosen by **Detail**: **Top 3** (default), **Composition**, or **None**.
- The product name and icon appear only in the final sign-off, never as a leading header or hero. Field's personal signature is part of its inscription, not additional product branding.
- **Cost** is optional, weak metadata subordinate to the total and rank. When enabled, it retains the estimate-not-a-bill and unpriced-usage qualifications; it MUST NOT become a second hero.
- Content size and deliberate padding determine the vertical rhythm. Layout MUST NOT manufacture whitespace by centering content inside residual fixed slots or retain empty slots when optional content is omitted.
- Theme visuals use data-safe framing. Decorative scenery may bleed or crop, but data-bearing content MUST remain intact. In particular, Field MUST fit every data plot inside the visible visual area; neither the horizontal band nor the card bounds may zoom or crop away a plot.
- **Top 3** uses three equal columns with two lines per item: the harness or model name above its share of the selected period. Percentages align with their own names, never the next column, and repeated absolute token counts are omitted. **Composition** uses compact category labels and shares; **None** removes the evidence block without leaving a gap.
- The automatic harness footnote acknowledges a shared lead instead of choosing one harness by tie-break order. Overall non-empty cards omit harness/model counts and repeated period headlines; scoped cards retain their scope identification.
- A genuinely empty selected period keeps its honest zero total and shows the localized **No usage in this period** state. It has no leading-harness footnote, Top 3 rows, or composition segments. An independently available positive last-30-day rank may still appear. Unavailable data is not an empty state and MUST NOT be presented as measured zero usage.
- When rank is disabled, unavailable, or has a non-positive last-30-day total, omit the rank and its disclosure entirely; show no placeholder, fabricated percentile, or reserved rank slot. Rank semantics and formatting follow `docs/contracts/statistics.md`.
- Text MUST remain at least `24pt` after scaling on the `1080pt` short side across all aspects and themes. Long content wraps or is intentionally omitted rather than shrinking below that floor.
- All narrative, estimate, empty, shared-lead, and detail text ships in natural English (`en`) and Simplified Chinese (`zh-Hans`). Use **Harness** / **工具** terminology, preserve product and harness or model names and number semantics, and localize sentence structure rather than concatenating English fragments.

## Visual acceptance

- Acceptance requires real screenshots of the built app, not mockups, in every supported appearance—both light and dark unless the theme is documented as dark only—compared against the approved reference design.
- Screenshots MUST cover the required screens and representative loading, empty, error, and populated states; accessibility variants are required when they change material or contrast behavior.
- A new theme's screenshot set MUST use the same screens and data as the accepted reference set so information parity can be reviewed.
- Visual approval does not waive accessibility, responsive-layout, or information-integrity requirements.

## Field (`sketchbook`)

- Field draws usage as a hand-drawn farm. Each source or model is one plot; plot area and plant count are proportional to tokens at a fixed planting density, and the crop identifies the source or model.
- Only the plots carry data. River, canals, fence, buildings, trees, animals, season, and day or night are scenery and MUST NOT encode numbers. The season follows the current date and changes scenery only; crop colors never change with season.
- Each plot shows one level wooden, single-line name board when it fits; a plot too small for the board gets a pennant in its crop color. Boards carry no token total or share and do not rotate randomly. Exact values are always available in the list below the field and in the temporary paper hover tooltip.
- A source keeps the same crop and color in every view and period. The ten most used sources each own a crop; the remaining sources share one and move to a free crop only when they meet that crop's owner in the same view. Model crops are assigned per view and may differ between periods.
- The water wheel, chimney smoke, and night fireflies move in the main window. They hold still under Reduce Motion, in the menu bar extra, and on share cards.
- Below the field, a bare composition strip shows the five token categories (plus uncategorized when present) without a panel, border, or extra horizontal inset; its track and legend share the plot list's horizontal axis. Exact category counts remain available through each item's help and accessibility value. The plot list keeps the shared breakdown details: the model cache detail popover and "Mainly from" lines.
- The menu bar extra shows today's field with crop flags instead of signs.
- The Field share card uses the same single narrative-footnote position as other themes, with the automatic note shown by default and no automatic random seeding. A user-entered or manually rerolled inscription and signature replace the automatic note; disabling the custom inscription returns to it. The card MUST NOT print both footnotes. The inscription (up to 40 characters) and signature (up to 24) are written on the card only and are never saved or synced.
- Field replaces every Liquid Glass surface with opaque paper surfaces, uses serif type (New York with Songti SC), and uses the shared themed period picker unframed, with only Field's furrow under the selected period. Its bundled `FieldAppIcon.icns` (a hand-drawn coin whose T is a tree) remains available for card branding and never replaces the Dock, Finder, or Launchpad icon.
- Field controls have no resting card or border; hover and press add only a light paper wash. The dimension switch uses bare text with a furrow for selection, and round controls have no resting outline. Keyboard focus retains a visible outline, and removing decorative chrome MUST NOT remove list-to-scene highlighting or any accessibility label, value, or hint.

## Cosmos (`cosmos`)

- Cosmos (宇宙) is the approved A3 视界 design. A Metal ray marcher hosted by `MTKView` draws the black hole, accretion disk, and bodies in one scene; the brighter starfield is ambient and carries no usage data.
- The disk consists of five contiguous radial bands whose widths encode category shares in `cacheRead`, `input`, `cacheWrite`, `output`, `reasoning` order—colored `#EAF2FF`, `#FFF0D2`, `#E8C48E`, `#D99A56`, and `#B65A35` respectively—plus an optional sixth outermost neutral band (`#8A93A3`) shown only when uncategorized tokens are greater than zero.
- The top six sources or models become bodies. Relative share to the power 0.78 determines size, tokens per hour determines orbital speed, and stable identity selects the surface variant. Exact orbital angle is not a data dimension. Items after the top six become dust; dust point count represents item count, not tokens.
- The scene includes labels, hover readouts, category legend, dust label, and flow caption. The shared period picker, totals, cost, devices, and ranked top-four list with Show all remain outside it, preserving the same statistics and controls as other themes.
- The menu bar extra shows today's compact Cosmos scene when today has usage. On the shared share card, Cosmos renders its scene in the hero visual slot (falling back to a plain dark panel if a snapshot is unavailable), and a scoped card renders the scope's breakdown along the other dimension (a source shows its models, a model its sources).
- Cosmos uses system sans type, monospaced tabular figures for numeric readouts, and opaque dark panels. It does not use Liquid Glass or serif type; the shared period picker, segmented controls, toggles, and buttons take Cosmos's square, bordered styling, and breakdown rows carry no per-item color dots.
- Adaptive render scale limits GPU cost. Reduce Motion renders a still frame without removing data or interactions. Metal failure leaves the surrounding usage data and ranked list available.
- Cosmos is dark only: it disables the Light/Dark/Follow System control, shows an explanation, and forces dark appearance without changing the saved preference. Its bundled `CosmosAppIcon.icns`, the same coin as a dark mass pressing a glowing spacetime grid into a gravity well, remains available for card branding and never replaces the Dock, Finder, or Launchpad icon.

## Open questions

- Approved reference-design location and the final required screenshot matrix.
- Cosmos native performance acceptance.
