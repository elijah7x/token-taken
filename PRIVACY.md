# Privacy Policy

Effective date: 2026-11-18

This privacy policy applies to **Token Taken** for macOS (including the `token-taken` CLI) and **Token Taken** for iOS.

## Summary

- **No accounts:** Token Taken does not require registration or sign-in to any Token Taken service.
- **No analytics or telemetry:** Token Taken contains no analytics SDKs, usage tracking, advertising identifiers, or third-party crash reporting.
- **No developer-operated collection server:** We do not operate a server that collects, receives, or stores your token usage, prompts, responses, or personal data.

## Data processed locally on your Mac

On macOS, Token Taken reads coding-agent logs, local databases, and configuration files strictly read-only on your Mac. It never modifies or deletes your agent logs.

- **Local usage database:** Aggregated token counts (by day and model, by rolling 48-hour window, and in a sparse long-term per-source hourly history without model or content, plus local device) and source health status are stored locally in `~/Library/Application Support/Token Taken/` (`usage.sqlite`). Cost estimates are not stored in the database.
- **Bundled pricing:** Cost estimates are computed locally in memory from a price table bundled inside the app. No network request is made to fetch pricing.
- **Excluded content:** Conversation prompts, model responses, file paths, project or repository names, and credentials are never stored in Token Taken's usage database or exports. The only exception in local logs is that during macOS self-updates, the updater writes `install.sh` output to a local file (`~/Library/Application Support/Token Taken/Updates/<version>-<build>/install.log`), which can contain file paths on this Mac; this log stays local only, is never transmitted, and is deleted on the next app launch cleanup.

## Data processed locally on your iPhone

The iOS companion app (`TokenTakenMobile`) is display-only. It performs no local log collection, no aggregation, and no pricing.

- **Local cache & preference:** The iOS app caches the latest decoded mobile report locally in its Application Support directory (`mobile-report-v1.json`) for fast display on launch, and stores a single local boolean preference (`TokenTakenDemoMode` in `UserDefaults`) for the optional sample-data view.
- **Share cards:** When you choose to share a summary card on macOS or iOS, the image is rendered locally on your device and passed to the system share sheet or clipboard only at your action. The iOS app does not request Photo Library access permission.

## Optional iCloud Drive sync (macOS, off by default)

iCloud Drive sync is opt-in and disabled by default. When you enable it in Token Taken on macOS:

- Token Taken writes aggregate-only metadata to your personal iCloud Drive folder (`iCloud Drive/Token Taken/`), organized by a randomly generated per-install UUID (`deviceId`) rather than hardware identifiers.
- Synced files include:
  - `device.json`: `schemaVersion`, `deviceId`, your Mac's `displayName` (device display name), `appVersion`, `lastWriteUTC`, `tombstone`, `files` (filename-to-SHA-256 map), `sources` (sanitized per-source health: `sourceID`, `lastSuccess`, `state`, and `skippedRecords` — never diagnostic error messages), and `accounts` (`deviceId`, `displayName`, `kind`, `sources`, `collectedAtUTC`, `files`).
  - Monthly daily files (`usage-YYYY-MM.json`): `schemaVersion` and `records`, where each daily record encodes `day`, `timeZoneID`, `deviceID`, `sourceID`, `modelID`, `rawModelID`, `counts` (`input`, `cacheRead`, `cacheWrite`, `output`, `reasoning`, `uncategorized`, `cacheWrite1h`), and `eventCount`.
  - Rolling 48-hour file (`hourly.json`): `schemaVersion` and `records`, where each hourly record encodes `hourStart`, `deviceID`, `sourceID`, `counts` (`input`, `cacheRead`, `cacheWrite`, `output`, `reasoning`, `uncategorized`, `cacheWrite1h`), `eventCount`, and `reasoningKnown`.
  - Account publication files (`account-<shortID>-usage-YYYY-MM.json` and `account-<shortID>-hourly.json`): encode the same daily (`day`, `timeZoneID`, `deviceID`, `sourceID`, `modelID`, `rawModelID`, `counts` with `input`, `cacheRead`, `cacheWrite`, `output`, `reasoning`, `uncategorized`, `cacheWrite1h`, and `eventCount`) and hourly (`hourStart`, `deviceID`, `sourceID`, `counts` with `input`, `cacheRead`, `cacheWrite`, `output`, `reasoning`, `uncategorized`, `cacheWrite1h`, `eventCount`, and `reasoningKnown`) fields inside the publishing Mac's folder, keyed by the hashed `account-<source>-<hash32>` `deviceID`.
- Synced files never contain prompts, responses, file paths, project or repository names, credentials, or cost figures. Long-term hourly history (`hourly_history`) stays local on your Mac and is not synced to iCloud Drive; only the rolling 48-hour `hourly.json` snapshot is synced.
- Turning iCloud Drive sync off immediately stops reading and writing sync data; previously uploaded files remain in your iCloud Drive under your control.

## Optional Sync to iPhone (macOS & iOS, off by default)

Publishing a report for the iPhone companion is opt-in and disabled by default on macOS.

- When enabled on your Mac, Token Taken writes a precomputed, aggregate-only JSON summary (`Documents/mobile/v1/report-<deviceId>.json`) to your personal Apple iCloud Documents container (`iCloud.io.github.elijah7x.TokenTaken`).
- The iPhone app reads this report directly from your own iCloud container when signed into the same Apple ID.
- The mobile report contains aggregate token totals, active day/month totals, source/model names, and device coverage names/statuses. It contains no cost figures, prompts, responses, file paths, project names, credentials, or error strings.
- Turning **Sync to iPhone** off on your Mac deletes that Mac's mobile report file from iCloud.
- Data stored in iCloud Drive and your iCloud Documents container is handled by Apple under your Apple ID and Apple's iCloud privacy and security protections, and is never accessible to us.

## Optional Cursor account collection (macOS, off by default)

Cursor account collection is opt-in and disabled by default on macOS.

- When enabled, Token Taken reads your existing Cursor session token and local account identifier in memory only from Cursor's local files on your Mac. Credentials are never written to Token Taken's store, logs, or sync output, and Keychain decryption is not attempted.
- Your Cursor session credential is sent exclusively to `https://cursor.com/api/dashboard/export-usage-events-csv?strategy=tokens` over HTTPS (allowing at most one HTTPS redirect, and only to `cursor.com` or `www.cursor.com`) to retrieve your Cursor token usage export.
- To prevent double counting the same Cursor account across multiple Macs without exposing your email or token, synced account rows are keyed by a one-way domain-separated hash of your local account identifier (`account-cursor-<hash32>`). Your email address, token, and host name are never included in sync output.

## Automatic and manual update checks (macOS release builds only)

Release builds of Token Taken for macOS include an updater controlled by the **Keep Token Taken up to date automatically** setting (enabled by default). When disabled, no automatic or background update requests are made; manual **Check for Updates** in Settings remains available at your request. Debug/ad-hoc builds and the iOS app do not check for updates.

- Each update check sends HTTPS `GET` requests in parallel to both `https://elijah.ac.cn/token-taken/updates.json` and the GitHub Releases API (`https://api.github.com/repos/elijah7x/token-taken/releases?per_page=10` on `api.github.com`). Verified update package downloads (and any download redirects) are fetched over HTTPS only from `elijah.ac.cn`, `github.com`, `objects.githubusercontent.com`, and `release-assets.githubusercontent.com`.
- Update requests send only standard HTTP request headers and `User-Agent: TokenTaken/<version>`. They do not send device identifiers, hardware identifiers, user identifiers, usage data, or account data. Standard transport metadata inherent to HTTPS (such as your IP address) is processed by the hosting server or CDN to serve the request.

## Contact

If you have questions or requests regarding this privacy policy, please open an issue in the project repository:

- <https://github.com/elijah7x/token-taken/issues>
