# ADR-0017: Flat Settings and Field

## Status

Accepted (2026-11-28)

## Context

The Liquid information-hierarchy work established the Tivano V3 subtraction rules: use space before rules, remove repeated information, and reserve elevation for functional overlays. Settings still used large tray surfaces, internal rules, repeated source and version labels, and inconsistent control sizes. Field used framed plot signs whose numbers competed with crops and whose dark appearance reduced the whole scene's contrast.

## Decision

- Present Settings as flat sections on the themed base, with no nested trays or internal secondary rules. Use 36pt section spacing, 12pt caption spacing, rows at least 48pt tall, and 28pt action controls. Show source, sync, version, and release-note labels once.
- Keep Field's plot area, fixed planting density, crop assignment, seasons, and statistics unchanged. Remove the landscape frame, wooden number boards, and composition card. Show one level wooden name board where it fits and use flags for smaller plots. Preserve exact values in the existing plot tooltip and breakdown.
- Keep the wooden sign integrated with the landscape rather than using unframed text or a halo. Reduce scenery detail and tune light and dark appearances by region so crops remain the highest-contrast layer.
- Reuse the existing Tivano provider assets where available, retaining their source and license notices. Sources without a mapped asset keep monogram badges.
- Keep pointer inspection immediate: Lens opens on entry and closes after a short combined exit delay. Slice overlays remain interactive without losing the active bucket.

## Consequences

- Settings and Field follow the same subtraction contract as Liquid without forcing one material or scene structure onto every theme.
- Exact values, health and coverage states, keyboard focus, VoiceOver labels, and all statistics remain intact.
- Acceptance uses synthetic data on a secondary build Mac so interactive validation does not take over the owner's foreground. Light and dark appearances, minimum window sizes, hover transitions, and repeated release actions remain required visual checks.
