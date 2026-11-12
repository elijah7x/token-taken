Status: Accepted (2026-11-12)

# ADR-0007: Ship the Field theme in v1

## Context

v1 planned to ship `liquid-glass` only and reserve `sketchbook` for later. Design exploration produced Field, a hand-drawn farm visualization, and the owner decided on 2026-11-12 to ship it in v1 as a selling point: a theme changes the whole app, not only colors.

## Decision

- Ship theme ID `sketchbook` with the display name Field alongside `liquid-glass`; keep `geek` reserved.
- Field applies app-wide: main window, Settings, menu bar extra, share card, and the Dock icon. Every glass surface becomes an opaque paper surface; type is serif.
- Encode data only in plots: area and plant count proportional to tokens at fixed density, crop as identity. Scenery, season, and day or night carry no data (`docs/contracts/themes.md`).
- Add a Follow System, Light, or Dark setting for all themes, applied through `NSApp.appearance`.
- Keep theme state for non-environment code in `ThemeRuntime`, and rebuild scenes on theme change through the existing format revision.

## Consequences

- Shared palette tokens and glass helpers branch on the active theme, so new UI must use `Palette` tokens and `themedGlass` / `themedGlassButton` rather than calling `glassEffect` directly.
- The Dock icon follows the theme at runtime; the Finder icon remains the bundle icon.
- Crop assignment is stable per source; when two items prefer the same crop in one view, the smaller takes the next free crop, so a crop can change between periods in that case.
