# ADR-0019: Stable application icon

## Status

Accepted

## Date

2026-11-28

## Context

- Field and Cosmos originally changed both `NSApp.applicationIconImage` and the app bundle's Finder custom icon when the theme changed. The runtime image controlled the Dock while Finder, Launchpad, and other system surfaces read the bundle metadata, creating two icon sources that could disagree during cold launch, theme changes, and quit.
- Writing a themed `Icon\r` and its Finder metadata into a signed app bundle also polluted its code signature. Repeatedly clearing and replacing that metadata made the installed app mutate itself during ordinary appearance changes.
- The Field and Cosmos artwork is still useful as brand imagery on share cards, but card branding does not require changing the system application icon.

## Decision

- Use the default brand icon compiled into the app bundle for Liquid Glass, Field, and Cosmos on every system surface, including Dock, Finder, and Launchpad. Do not assign themed images to `NSApp.applicationIconImage`.
- Keep `ThemeAppIcon.image(for:)` for cards and other in-app brand imagery only. Theme and appearance changes no longer write application icons.
- Migrate only installations with a recognized legacy Field or Cosmos icon. Compare normalized 128×128 pixels from `NSWorkspace.icon(forFile:)` against the bundled legacy theme artwork before calling `NSWorkspace.setIcon(nil, forFile:options:)`. Preserve every unrelated custom Finder icon, including one deliberately installed by the user.
- Attempt cleanup at most once per launch and record a `UserDefaults` completion marker only after successful removal, or after confirming that no legacy theme icon is present. An unreadable comparison or failed removal remains eligible for retry on a later launch. Do not delete `Icon\r`, edit FinderInfo, remove other icon metadata directly, or re-sign the running bundle.
- This supersedes the runtime Dock and Finder icon decisions in [ADR-0007](0007-field-theme.md) and any later themed system-icon behavior. It does not change the approved Field or Cosmos card artwork.

## Consequences

- System icon presentation stays stable across cold launch, theme changes, and quit, and normal theme use no longer invalidates strict bundle-signature checks.
- Existing affected installations require one successful custom-icon removal. If the bundle is not writable, the old metadata can remain until a later launch succeeds; the app does not report the migration as complete prematurely.
- Field and Cosmos retain distinct visual identities in their scenes and cards without owning the system application icon.
