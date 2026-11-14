# ADR-0004: Developer ID distribution

## Status

Accepted

Status note: [ADR-0013](0013-automatic-updates.md) supersedes the manual-only v0.1 update delivery decision here.

## Date

2026-11-10

## Context

- Token Taken ships outside the Mac App Store, so Gatekeeper needs Developer ID-signed and notarized distribution artifacts.
- The app contains `TokenTakenKit.framework`, the `token-taken` CLI, and the pinned tokscale executable. Every nested executable must have the hardened runtime and a secure timestamp before the app is sealed.
- Debug builds must remain usable without Developer ID credentials or access to Apple's timestamp service.
- The first notarization of a new app can take much longer than later submissions. The owner's previous first submission took nearly two days.
- Release outputs and notarization evidence must remain outside the public source tree.

## Decision

### Artifact and updates

- Distribute a notarized, stapled DMG containing `Token Taken.app` and an `/Applications` symlink. `scripts/release.sh` builds arm64 binaries, verifies the locked engine archive, signs inside out, creates the DMG (ULMO, LZMA-compressed), and submits it with `notarytool`.
- Ship arm64 only. Token Taken runs on Apple silicon Macs only ([ADR-0012](0012-apple-silicon-only.md)), and the release script fails when any bundled executable reports an architecture other than `arm64`.
- Strip release binaries to keep the download small: the app and `token-taken` use `STRIP_STYLE: all`, `TokenTakenKit.framework` uses `non-global` so its exported symbols survive, and every Release configuration keeps `DEBUG_INFORMATION_FORMAT: dwarf-with-dsym`. `scripts/release.sh` fails when the main executable still carries a local symbol table, and copies the build's dSYMs to `dSYMs/` beside the DMG under `local-packages/` so crashes stay symbolicated even though the shipped binaries have no symbols.
- Use manual downloads and updates for v0.1. Do not add Sparkle or another automatic updater in v0.1; revisit update delivery after the first release.
- Keep DerivedData, DMG staging, and release DMGs under the artifact root's `local-packages/` directory, never in the repository.
- Submit an initial Developer ID build for notarization as early as possible, even with a placeholder icon. Do not postpone the first submission for final artwork. Rebuild, notarize, and staple the final DMG before publication.

### Signing

- Use a Developer ID Application identity from the signing keychain, with `TOKEN_TAKEN_TEAM_ID` selecting the team. `TOKEN_TAKEN_SIGNING_IDENTITY` may override the default `Developer ID Application` name when a more specific identity or certificate hash is needed.
- Enable the hardened runtime for release code. Sign nested frameworks and helper executables before signing the app, following Apple's [nested-code guidance](https://developer.apple.com/library/archive/technotes/tn2206/_index.html#//apple_ref/doc/uid/DTS40007919-CH1-TNTAG13). The release script re-signs the framework, CLI, tokscale, and app in that order with `--options runtime --timestamp` and the applicable entitlements.
- In the `Bundle helper tools` build phase, a real signing identity uses `--options runtime --timestamp`. Ad-hoc signing (`-`) keeps `--timestamp=none` and omits the runtime option. Stamps in `DERIVED_FILE_DIR` record both the source and the identity used for the current helper so switching either direction between Debug and Release re-signs it.
- Give the app and CLI separate minimal entitlements files. Neither contains `com.apple.security.app-sandbox`; both entitlement dictionaries are empty.
- The CLI keeps `@executable_path/../Frameworks` in `LD_RUNPATH_SEARCH_PATHS`. From `Contents/Helpers/token-taken`, this resolves to `Contents/Frameworks/TokenTakenKit.framework`, so no external framework path or library-validation exception is required.

### Amendment 2026-11-12: iCloud container signing

- Release now shares the iCloud Documents container `iCloud.io.github.elijah7x.TokenTaken` described in [ADR-0011](0011-mobile-report.md). `TokenTaken/TokenTaken.entitlements` declares `CloudDocuments` with the container and ubiquity container identifiers, and replaces the empty app entitlement dictionary above for Release. It still grants no app sandbox, no CloudKit environment, and no key-value storage.
- iCloud entitlements are only valid on a Developer ID build together with a provisioning profile, so the app target's Release configuration signs with `TokenTaken/TokenTaken.entitlements` and the installed Developer ID profile named `TokenTaken Developer ID`. Xcode embeds that profile in the bundle and `scripts/release.sh` refuses to package an app without it.
- Renew the profile when it expires or when the container, capabilities, or Developer ID certificate change, then rebuild and re-notarize. `TOKEN_TAKEN_PROVISIONING_PROFILE` overrides the profile name for a release run.
- Debug keeps `TokenTaken/TokenTakenDebug.entitlements` (an empty dictionary) and an empty profile specifier, so a Debug build still needs no Apple credentials or provisioning profile.
- Whether a notarized, non-sandboxed Developer ID app can actually use this container is still unverified; if it cannot, the document-picker fallback in ADR-0011 applies and this entitlement can be dropped again.

### Notarization and credentials

- Authenticate `notarytool` only with `NOTARY_PROFILE` and `--keychain-profile`. Apple IDs, app-specific passwords, API keys, and signing private keys must not appear in the script, environment files, or Git. Create the keychain profile interactively before running a release.
- Use `scripts/release.sh all --no-wait` for the early submission. A run with `--wait` staples the DMG after acceptance; a no-wait run prints the `xcrun stapler staple` command to use after acceptance.
- A successful submission is not a successful notarization. Publish only the final accepted and stapled DMG.

### Tokscale runtime evidence

The lock file pins tokscale 4.21.0 from `@tokscale/cli-darwin-arm64`.

- The upstream [root package at v4.21.0](https://github.com/junhoyeo/tokscale/blob/v4.21.0/package.json) builds `tokscale-cli` with Cargo. Bun builds the JavaScript package launcher; that launcher is not the vendored executable.
- The Darwin package metadata points directly to `bin/tokscale`. Inspection of the locally installed arm64 4.21.0 artifact found a Mach-O executable, only system libraries in its load commands, and no existing entitlements. It is not a Bun or Node single-file executable.
- Therefore tokscale receives the normal hardened runtime and secure timestamp without `com.apple.security.cs.allow-jit`, `com.apple.security.cs.allow-unsigned-executable-memory`, or `com.apple.security.cs.disable-library-validation`. No tokscale-specific entitlements file is generated.
- Only the arm64 artifact is vendored; no x64 artifact is downloaded and no universal binary is assembled ([ADR-0012](0012-apple-silicon-only.md)). The release check must confirm that tokscale still launches and notarizes without runtime exceptions when the engine version or packaging changes. The npm package's optional `libFoundationModels.dylib` is not currently vendored; if it is bundled later, it must also be signed before the app and reassessed.

## Consequences

- Releases require XcodeGen, a valid Developer ID identity, a notarytool keychain profile, network access for secure timestamps and notarization, and a final stapling step after acceptance.
- Debug builds remain ad-hoc and do not need Apple's timestamp service.
- Manual v0.1 updates avoid updater signing, feed hosting, and update-security work, but users must check for and install new releases themselves.
- Stripped binaries cannot be symbolized without the dSYMs kept beside the DMG, so those files must survive with the release they belong to.
- Changing an engine, adding nested code, or adding a runtime entitlement requires another signing and notarization review.

## Alternatives

- **Mac App Store and sandboxing:** rejected because the app needs the non-sandboxed home-folder access established in ADR-0001.
- **Ad-hoc or unsigned release artifacts:** rejected because they do not provide the required Developer ID and Gatekeeper distribution path.
- **Sparkle in v0.1:** deferred to keep the first release pipeline small; this is not a permanent rejection.
- **ZIP as the primary artifact:** rejected in favor of one DMG that can be notarized and stapled for an approachable drag-to-Applications install. The DMG is LZMA-compressed (ULMO) rather than zlib (UDZO) because the smaller download outweighs the slower mount.
- **Blanket JIT and library-validation exceptions:** rejected because the pinned native tokscale evidence does not justify weakening the hardened runtime.
