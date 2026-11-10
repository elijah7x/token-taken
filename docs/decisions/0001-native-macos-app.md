# ADR-0001: Native macOS app

## Status

Accepted

## Date

2026-11-09

## Context

- Token Taken needs native Liquid Glass, a main window, and a minimal menu bar extra.
- V1 targets macOS and must read agent logs in the user's home folder.
- ICloud Drive sync should work without CloudKit entitlements.
- The app should be approachable for non-technical users and expose shared logic to a CLI.

## Decision

- Build a native SwiftUI app with a minimum deployment target of macOS 26.0.
- Use native Liquid Glass APIs, including SwiftUI `glassEffect` and AppKit `NSGlassEffectView` where needed. Do not use web or CSS imitations.
- Generate the Xcode project from `project.yml` with XcodeGen.
- Ship a non-sandboxed app outside the Mac App Store with Developer ID distribution.
- Use a String Catalog for English and Simplified Chinese from v1.
- Keep shared behavior in `TokenTakenKit`; the `TokenTaken` app and `TokenTakenCLI` depend on it.

## Consequences

- V1 requires macOS 26.0 or later and does not support Windows or Linux.
- The app can read supported home-folder logs read-only and write to iCloud Drive without CloudKit entitlements.
- Native Liquid Glass is available without a compatibility material for older macOS releases.
- Developer ID signing, notarization, DMG packaging, and manual v0.1 updates follow [ADR-0004](0004-distribution.md).

## Alternatives

- **Electron, as used by Token Monitor:** rejected for v1 because a web UI would not provide the required native Liquid Glass and would add a desktop web runtime.
- **Tauri or another web UI:** rejected because the interface would still need to imitate Liquid Glass rather than use the native APIs.
- **Older macOS with a degraded material:** rejected for v1 to keep one native visual behavior and avoid maintaining a second material implementation.
