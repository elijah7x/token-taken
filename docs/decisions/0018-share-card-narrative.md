# ADR-0018: Share card narrative

## Status

Accepted (2026-11-28)

## Context

The share card had become a small data report: product branding led the header, a text column carried several levels of readouts, and landscape placed the visual beside that column. The structure competed with the usage story, narrowed the signature visual, and encouraged fixed slots whose leftover space was centered rather than composed. Field also needed framing that preserved every data plot instead of treating the farm as disposable scenery.

The share experience should read as an achievement poster. Its primary facts, optional context, visual, and evidence need a clear value order without changing usage statistics or making an estimated rank look like a measured leaderboard.

## Decision

### Achievement narrative and aspect layouts

- Use this information order: selected period and hero total; independent last-30-day estimated rank; one restrained note based on the selected period's leading harness or shared leaders; compressed share evidence. Product name and icon appear only in the final sign-off.
- Keep **Cost** optional and visually weak, with its estimate and unpriced-usage qualifications intact. Keep **Detail** as **Top 3** (default), **Composition**, or **None**. Top 3 shows names and shares without repeating absolute token counts; the automatic note acknowledges shared leaders instead of inventing a unique winner. Overall non-empty cards omit harness/model counts and repeated period headlines.
- For landscape (`4:3`), place primary information at the top and a full-width horizontal visual band below it. For portrait (`3:4`), place primary information at the top and a natural-height visual below it. Remove the landscape left/right split in both layout and acceptance expectations.
- Reject the old landscape split because it gives the readout column equal structural weight to the achievement visual, reduces the visual's width, and makes the poster read as a dashboard export. Fixed text and visual columns also create residual boxes whose centered whitespace is an artifact rather than intentional composition.
- Size content-driven sections from their contents and deliberate padding. Omitting rank, cost, footnote, or detail removes its space; no empty fixed slot or centered remnant preserves the old report grid.

### Automatic note and Field inscription

- Generate the shared narrative footnote from the leading harness in the selected period. It is editorial context for the displayed achievement, not another aggregate, rank, or claim about productivity.
- Field's optional inscription is the theme-specific, editable replacement for that same footnote. Show the automatic note by default without random seeding. A user-entered or manually rerolled inscription and signature replace it; disabling the custom inscription returns to the automatic note. Never print both footnotes.
- Keep Field's inscription and signature ephemeral, card-only, and unsynced. A custom inscription may be expressive rather than tool-derived; it does not alter the facts or evidence elsewhere on the card.

### Safe visual framing

- Fit each theme visual by its data-safe content, not by filling a slot at any cost. Decorative backgrounds and scenery may bleed or crop; data-bearing geometry must remain intact.
- The landscape band is a horizontal composition constraint, not permission to zoom through data. Field must contain every data plot within the visible farm area in both aspects. Portrait uses the visual's natural height rather than stretching it to fill leftover space.

### Rank, empty states, and language constraints

- Calculate rank only with `UsageRank` over combined last-30-day tokens across all harnesses, using the versioned public-reference estimate curve in `docs/contracts/statistics.md`. Never derive it from the selected period, selected scope, Top 3 leader, or composition, and never present it as a measured global leaderboard.
- Keep rank optional. Disablement, unavailable data, or a non-positive last-30-day total removes the rank and disclosure without a placeholder or empty slot. No anonymous ranking upload or server-side benchmark is introduced.
- A genuinely empty selected period shows an honest zero total and the localized empty message, with no harness note or fabricated detail rows. This does not invalidate an independently available positive last-30-day rank. Unavailable data remains distinct from measured zero.
- Preserve the `24pt` minimum after scaling at the `1080pt` short side. Wrap or omit optional content instead of shrinking below the floor. Ship natural English and Simplified Chinese for narrative, estimate, empty, shared-lead, and detail text, preserving **Harness** / **工具** terminology and number semantics.

## Consequences

- Share cards lead with a portable achievement and its theme visual rather than reproducing the dashboard. Branding and secondary metadata stop competing with the total and estimated rank.
- Landscape gains a wider signature visual, while portrait avoids stretched visuals and slot-driven whitespace. Real exported screenshots remain necessary to approve the composition in both aspects and languages.
- Field gains safe plot framing and one editable footnote channel without persisting personal copy. Other themes keep the automatic note without acquiring Field's inscription controls.
- Ranking, totals, cost estimation, aggregation, sync, and privacy semantics do not change. `docs/contracts/themes.md` carries the binding presentation contract, and `docs/contracts/statistics.md` remains authoritative for rank calculation and disclosure.
