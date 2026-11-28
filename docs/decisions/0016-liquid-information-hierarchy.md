# ADR-0016: Liquid information hierarchy

## Status

Accepted (owner-approved Tivano V3 structure, 2026-11-27)

## Context

The Liquid Glass dashboard repeated the same period and slice facts in a persistent exact-count row, a three-column Lens readout card, chart labels, and the breakdown list. The persistent Lens card also competed with the time chart for vertical space. The owner approved the Tivano V3 subtraction contract to give the complete period one clear reading surface and move inspection detail into transient surfaces.

The redesign must preserve the existing statistics and all state distinctions. Short formatting cannot hide exact counts, a missing price cannot imply zero cost, and hourly inspection cannot turn missing coverage into measured zero. Keyboard, VoiceOver, English, Simplified Chinese, and the accessibility material variants remain acceptance requirements. Field and Cosmos keep their approved signature visuals.

## Decision

### Shared hierarchy and subtraction contract

- The shared tray contains the period control, a short hero total with its unit, estimated cost or an unpriced notice, Devices, and sync notices. Remove the persistent exact-count row and permanent breakdown cards from the tray.
- The dashboard presents one complete-period summary and one active hero visual above the shared single-column breakdown. The breakdown footer aggregates hidden rows and offers **Show all** and **Show less**.
- Show exact values on demand. `DataHoverPopover` presents the exact locale-formatted total, the estimate disclaimer, the price-table version, and any unpriced tokens excluded from the estimate. Hover reveals the popover; click or keyboard activation pins it; Escape dismisses it.
- Use `DataHoverCard` for the common floating readout. It supplies the shared width, padding, and Reduce Transparency-aware surface. Lens slice overlays and Confluence stream tooltips use this card, while summary values and the Lens whole-period composition use `DataHoverPopover`.

### Lens presentation and state boundaries

- Replace the fixed three-column readout card with a flat stacked time-bar chart, readable axes, and an interactive Liquid Glass magnifier. Place a bare whole-period composition strip below the chart. Its popover supplies exact category counts and shares without permanent labels.
- Resting the magnifier on the peak bucket provides visual emphasis only. It does not open a slice overlay or change any total.
- Hovering a non-future bucket opens a transient single-bucket `DataHoverCard`. Clicking, dragging, or using the keyboard pins a bucket or contiguous range. The overlay shows the selected time range, short and exact totals, period share or partial-coverage state, cost availability, the top three items in the active dimension, and slice composition. Release, double-click, and Escape clear the pin.
- Keep slice inspection separate from period filtering. The sidebar, whole-period composition strip, ranked breakdown, and hero aggregate inputs continue to describe the complete selected period while a slice is visible. A slice query must not rewrite those summaries or their denominators.
- Release the pin on a period change. Resolve existing pins against available non-future buckets and update their stored endpoints when the bucket count changes. Day + Models keeps total-only hourly bars and states that model detail and model pricing are unavailable. Missing hourly coverage remains explicit and never becomes a measured zero.

### Pricing and coverage notices

- Keep a lightweight unpriced state or information icon beside cost. Unpriced usage still contributes to token totals, and an absent rate does not establish a zero price. The on-demand explanation identifies excluded unpriced tokens, labels cost as an estimate rather than a bill, and names the price-table version.
- Preserve partial, stale, empty, error, and unavailable states in the same hierarchy. Do not add a permanent pricing panel or coverage banner when a compact notice plus an accessible detail surface conveys the state.

### Accessibility and acceptance

- Every pointer inspection path has a keyboard and VoiceOver equivalent. Data popovers open without a pointer and dismiss with Escape. Lens supports keyboard movement, pinning, range resizing, and release; its bucket elements expose time, total, leading items, selection, upcoming time, and missing coverage. Confluence focus exposes the same stream values as hover.
- Reduce Motion removes nonessential transitions, Reduce Transparency replaces glass detail surfaces with opaque materials, and Increase Contrast strengthens separation without changing statistics or removing state feedback.
- Ship natural English and Simplified Chinese strings for the new controls and floating readouts. Reuse existing catalog keys and retain keys still used by the menu bar, share cards, Field, and Cosmos. Keep English product and model names unchanged.
- Accept the structure using real screenshots of the built app at supported window sizes. Cover both languages, supported appearances, populated and representative loading/empty/error/partial/stale/unpriced states, hover and pinned slices, keyboard focus, and the Reduce Motion, Reduce Transparency, and Increase Contrast variants that alter presentation.

## Consequences

- Users see fewer repeated numbers and gain more room for the time chart. Exact values and pricing qualifications remain available without leaving the dashboard.
- The complete-period summary stays stable during hover and pinned inspection, so users can compare a slice with its period total without mistaking the slice for a global filter. Hourly slices retain the documented granularity, time-zone, and coverage limits and can differ from daily aggregates.
- A small unpriced notice continues to warn that the estimate is incomplete. Users can inspect the excluded amount and price-table version when needed.
- Shared hover components keep Lens, Confluence, and summary detail behavior aligned. Changes to those components must preserve keyboard, VoiceOver, and reduced-material behavior across every caller.
- The Tivano V3 structure changes shared information hierarchy only. It does not revise Field's farm, Cosmos's Metal scene, their icon rules, or any aggregation and pricing semantics. `docs/contracts/themes.md` carries the binding presentation contract.
