Status: Accepted (2026-11-12)

# ADR-0008: Replace the reserved Geek theme with Cosmos

## Context

The Geek theme was renamed Cosmos (宇宙) after three exploration rounds. The owner approved scheme A3 视界 on 2026-11-12 as the final direction, with a brighter starfield. It visualizes usage as a black hole, a five-category accretion disk, orbiting bodies, and dust rather than as another chart skin.

The approved design is dark only, while the theme contract previously required every theme to support light and dark appearances. The reserved `geek` ID no longer describes the selected theme.

## Decision

- Ship theme ID `cosmos` with the display name Cosmos (宇宙); it replaces the reserved `geek` ID.
- Render the hole, disk, and bodies together with a Metal ray marcher hosted by `MTKView`. Keep the starfield ambient and brighten it as approved.
- Map the shared `UsageSummary` without changing its numbers: category shares determine radial disk-band widths in `cacheRead`, `input`, `cacheWrite`, `output`, `reasoning` order; the top six sources or models become bodies sized by relative share to the power 0.78 and moving at rates derived from tokens per hour; remaining items become dust.
- Make Cosmos a documented exception to the light-and-dark rule. While selected, force dark appearance for every window and the menu bar extra without overwriting the saved Follow System, Light, or Dark preference. Disable the appearance picker and explain the exception; restore the saved preference when another theme is selected.
- Keep the shared period picker, totals, cost, device list, and ranked breakdown outside the scene. Add compact today and 1200×630 share presentations using the same summary and current source/model dimension.

## Consequences

- The ray marcher adds sustained GPU cost. Adaptive render scale is required to protect frame time, and native performance still needs measurement against the approved reference; the WebGL prototype is not performance evidence.
- Reduce Motion renders a still frame and redraws only for state, hover, or focus changes. Values, labels, hit targets, and readouts remain available.
- Metal failure and unavailable snapshots fall back to data-first panels rather than blank scenes or missing totals.
- Shared palette tokens and glass helpers branch for Cosmos as well as Field. New UI must use those helpers so Cosmos never receives Liquid Glass surfaces or serif type.
- Cosmos has no Dock icon variant yet and keeps the default icon. Designing and accepting that variant remains an open item.
