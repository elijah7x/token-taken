# ADR-0013: Automatic updates

## Status

Accepted

## Date

2026-11-14

## Context

- Token Taken distributes outside the Mac App Store as an unsandboxed, Developer ID-signed and notarized macOS app ([ADR-0004](0004-distribution.md)).
- [ADR-0004](0004-distribution.md) deferred automatic updates for v0.1 to keep the initial release pipeline small, leaving only manual Check for Updates.
- Post-release iteration is expected to be frequent, so silent background updates are needed to deliver fixes and features without requiring users to download DMGs manually.
- Adopting Sparkle 2 would introduce a third-party dependency and require managing a separate EdDSA key pair alongside Apple Developer ID code signing.
- Feed hosting and public GitHub releases are not set up yet, so the update endpoints must serve as placeholders until the mirror and public releases exist.

## Decision

- Implement a custom in-app updater without Sparkle, mirroring a design already proven in another of the owner's apps. Sparkle remains a future option if requirements change.
- **Setting and schedule:** Provide the **Keep Token Taken up to date automatically** setting, enabled by default. When enabled, `UpdateChecker` checks 15 seconds after launch, every 6 hours, and on app activation when the last check is more than 6 hours old. When disabled, no automatic network requests are made; manual **Check for Updates** in Settings > About continues to work.
- **Requests and privacy:** Perform HTTPS `GET` requests to the static feed `https://elijah.ac.cn/token-taken/updates.json` with fallback to the GitHub Releases API for `elijah7x/token-taken`. Send only standard request headers plus `User-Agent: TokenTaken/<version>`, with no device identifiers, usage data, or account data. Download the DMG over `https` only from allowlisted hosts: `elijah.ac.cn`, `github.com`, `objects.githubusercontent.com`, and `release-assets.githubusercontent.com`.
- **Feed schema v1:** Publish `updates.json` as `snake_case` JSON containing `schema_version` (`1`), `version`, `build`, `minimum_system_version`, `download_url`, `sha256` (lowercase hex), `size` (bytes), `notes` (Markdown), and optional `published_at` (ISO 8601). `UpdateFeedSelection` accepts only updates that are strictly newer by `(version, build)`, disallowing rollbacks.
- **Verification:** Before installing, `AppUpdater` verifies the downloaded DMG's byte `size` and `sha256` against the feed, verifies that the staged app passes code-signature validation for bundle identifier `io.github.elijah7x.TokenTaken` signed by the same Developer ID team as the running app, confirms the staged app's version and build match the feed, and runs Gatekeeper assessment. Debug and ad-hoc builds never update.
- **Silent installation and UI:** When a staged update is ready, `AppUpdater` installs it while the user has been idle for 10 minutes, no refresh is running, and no app window is in use, then relaunches in the background; otherwise it installs when the user quits. Replacing the app at its existing bundle path preserves the `token-taken` CLI symlink. After an update completes, the menu bar popover shows a one-time `Updated to <version>` notice with a link to the release notes.
- **Release tooling:** Add `scripts/make-update-feed.py` (Python 3 stdlib only) to generate schema-v1 `updates.json` from a DMG, and invoke it in `scripts/release.sh` after notarization and stapling using `TOKEN_TAKEN_UPDATE_BASE_URL` (defaulting to `https://elijah.ac.cn/token-taken/releases/v<version>-<build>`) and optional `TOKEN_TAKEN_RELEASE_NOTES`. No upload step is added to `scripts/release.sh`.

## Consequences

- Users on Developer ID builds receive automatic background checks and silent updates without manual DMG downloads, third-party updater dependencies, or separate EdDSA key management.
- [docs/contracts/privacy.md](../contracts/privacy.md) is updated to permit automatic update checks and verified DMG downloads from the allowlisted hosts when the setting is on.
- Debug and ad-hoc builds do not self-update, and downgrades are blocked by strict `(version, build)` ordering.
- Preserving the bundle path keeps the CLI symlink working across updates.

## Alternatives rejected

- **Sparkle 2:** Deferred (not permanently rejected). Because the app is unsandboxed and already Developer ID signed and notarized, a custom updater avoids a third-party dependency and a separate EdDSA key.
- **Manual-only updates:** Rejected because expected post-release iteration speed makes automatic background delivery preferable to requiring manual checks and installs.

## Open items

- Feed hosting (`https://elijah.ac.cn/token-taken/updates.json`) and public GitHub releases (`elijah7x/token-taken`) are not provisioned yet; both sources remain placeholders until the mirror and public releases exist. Uploading artifacts and feeds is out of scope for this change.
