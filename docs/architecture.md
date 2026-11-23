# Token Taken architecture

Status: pre-alpha. The macOS app and CLI share a local SQLite collection and aggregation pipeline. Opt-in iCloud Drive sync is implemented; real multi-Mac acceptance is pending.

## Platform choices

- Native macOS app written in SwiftUI, with AppKit APIs where SwiftUI does not expose the required native behavior.
- Minimum macOS 26.0. Native Liquid Glass uses SwiftUI `glassEffect` or `NSGlassEffectView`; web and CSS imitations are out of scope.
- XcodeGen generates the Xcode project from `project.yml`.
- The app is non-sandboxed and distributed outside the Mac App Store with Developer ID so it can read agent logs in the user's home folder and write to iCloud Drive without CloudKit entitlements.
- Release artifacts use hardened-runtime signatures and secure timestamps on the framework, helpers, and app, signed inside out. Debug helpers remain ad-hoc without a secure timestamp.
- Distribution is a notarized, stapled DMG. Updates use a custom automatic background updater without Sparkle, verifying feed hashes, Developer ID team identity, and Gatekeeper assessment before silent install; notarization credentials come only from a keychain profile.
- A String Catalog provides English and Simplified Chinese from v1.

See [ADR-0001](decisions/0001-native-macos-app.md), [ADR-0004](decisions/0004-distribution.md), and [ADR-0013](decisions/0013-automatic-updates.md).

## Targets and layering

| Target | Responsibility | Bundle identifier |
| --- | --- | --- |
| `TokenTaken` | Main window and `MenuBarExtra` app | `io.github.elijah7x.TokenTaken` |
| `TokenTakenKit` | Shared models, local store, sync, statistics, and contracts | Shared library, no independent app bundle ID |
| `TokenTakenCLI` | Builds the `token-taken` command-line tool | `io.github.elijah7x.TokenTaken.CLI` |

Bundle identifiers may change before the first release.

```text
TokenTaken app ───────┐
                      ├──> TokenTakenKit
TokenTakenCLI ────────┘
```

- `TokenTakenKit` depends on nothing app-side.
- The app and CLI depend on `TokenTakenKit` and share its query and aggregation pipeline.
- The CLI never depends on app UI.

## Modules

### Collector

- Runs the pinned usage engine and adapts its output into Token Taken's canonical model.
- Returns `CollectionBatch` with complete-history local-day/model records, rolling 48-hour per-source records, and skipped-record counts. Daily records preserve collection-zone and raw-model identifiers; hourly instants are absolute and carry reasoning knowledge.
- tokscale handles Claude Code, Codex, Kimi Code, OpenCode, Gemini CLI, Factory Droid, DeepSeek Harness, and fx. Native Swift collectors handle Zcode, pi, oh-my-pi, Devin, Antigravity, MiniMax Code, DeepSeek CLI, and Grok; pi, oh-my-pi, Devin, Antigravity, and Grok are not also counted by tokscale. The opt-in Cursor collector is native, account-level, and never requested from the engine.
- Explicitly sets the process `TZ` to the collecting device's current IANA zone, runs offline with an isolated config directory, and uses a 300-second timeout. Graph supplies daily/model totals; concurrent per-client hourly exports have merged models and omit reasoning.
- Retains device attribution and device kinds (`mac`, `account`). Account-level usage is collected only for Cursor, only when the user opts in, and only by its native collector; its publications from several Macs collapse to one whole publication per account. Device-local sources are never cross-device deduplicated.
- Reads agent logs read-only. Raw prompts, responses, paths, project names, and credentials do not enter sync output.
- Reads client SQLite databases (`AntigravityCollector`, `CursorCollector`, `ZcodeCollector`, `DevinCollector`) directly via `SQLiteSnapshotReader` with `SQLITE_OPEN_READONLY` and a `sqlite_master` probe. When direct open or probing fails, or when an orphaned `-wal` exists without `-shm`, the reader copies the database and any existing sidecars into a private temporary directory, opens the copy read-write, and cleans up afterwards so it never writes beside client files; read and schema failures surface as unreadable records or failed collection, never as "not applicable".
- Contains no upstream parser forks beyond separately reviewed patches. Engine upgrades pin a new version and rerun contract and reconciliation checks.

The engine interface is selected by [ADR-0003](decisions/0003-usage-engine.md), refined by [ADR-0005](decisions/0005-collection-granularity.md), and governed by `docs/contracts/upstream.md`.

### Store

- Owns the local database under `~/Library/Application Support/Token Taken/`.
- SQLite schema version 8 stores `daily_usage` keyed by `(device_id, source_id, model_id, day)`, rolling 48-hour `hourly_usage` keyed by `(device_id, source_id, hour_start)`, and sparse long-term `hourly_history` keyed by `(device_id, source_id, hour_start)` (no model column, no all-zero rows; [ADR-0015](decisions/0015-hourly-history.md)), plus devices (with their `mac` or `account` kind), history epochs (with last applied collection time zone), hourly history epochs (`hourly_history_epochs`, schema version 8), and health. Counts include unpriced `uncategorized` tokens; daily rows include time zone/raw model/event count; hourly rows include event count/reasoning knowledge.
- Rebuilds usage-cache tables when migrating an older version, retaining devices and health metadata and marking health stale. Rejects newer unknown schemas. The CLI opens read-only and asks the app to migrate an old cache.
- Merges one source/device's daily history and sparse long-term hourly history and replaces its 48-hour hourly snapshot in a single transaction, writing only changed `hourly_history` rows. A serial queue, WAL, and busy timeout coordinate local access; `UsageStore.records()`, `hourly()`, and `hourlyHistory()` throw on failed reads.
- Preserves cached rows and last success on failed/unavailable collection. Source health tracks skipped records and `ok`, `unavailable`, `failed`, `stale`, and `notInstalled` states; health read/write errors remain visible through throwing reads and runner results.

See ADR-0005 for the rebuild policy. Sync snapshots, device tombstones, and merge rules follow `docs/contracts/sync.md`.

### Pricing

- Uses `PriceTable.bundled` for real usage and `PriceTable.synthetic` for synthetic previews. Maps normalized model IDs to versioned rates; uncategorized tokens remain unpriced.
- The bundled table ships inside the app and has no runtime network path. `engine/price-snapshot-*.json` is the reviewed source of truth, and `scripts/update-prices.py` regenerates `TokenTakenKit/PriceSnapshot.swift` from its newest file; `scripts/release.sh` fails the release when the generated file is stale.
- Rates are exact keys from the engine's reported prices or a vendor's published first-party tariff. Reviewed spelling variants map through the alias table; exact match wins, and a `:free` id never resolves to a paid base model.
- The bundled version is `<snapshot version>+alias-<aliasTableVersion>`, so an alias change also changes the recorded version.
- Derives cost at read time and returns the price-table version with the estimate.
- Never syncs cost and never presents an estimate as a bill.
- Keeps pricing semantics aligned with `docs/contracts/statistics.md`.

### Sync

- Uses the opt-in iCloud Drive folder `iCloud Drive/Token Taken/`, stored on disk at `~/Library/Mobile Documents/com~apple~CloudDocs/Token Taken/`. Sync is off by default.
- Gives each Mac a random UUID `deviceId` created on first launch. Hardware identifiers are not used.
- Writes only `Token Taken/v1/devices/<deviceId>/`, containing `device.json`, atomically rewritten monthly daily-history `usage-YYYY-MM.json` snapshots, and a rolling per-source `hourly.json`. Each folder has one writer. Local long-term `hourly_history` is not synced ([ADR-0015](decisions/0015-hourly-history.md)).
- Reads and merges every device folder. A removed device leaves a tombstone and does not resurrect unless the user re-enables it.
- Preserves daily local-date labels and collection zones per model; preserves absolute hourly instants per source without model attribution. Both kinds include event counts and uncategorized tokens; hourly rows preserve reasoning knowledge and explicit zero coverage. Hourly activity is never added to daily totals.
- Never cross-deduplicates device-local sources. Account-level sources (today only Cursor) are folded to one whole publication per account before totals form, so a signed-in Mac never counts the account a second time; see [ADR-0010](decisions/0010-cursor-account-usage.md).
- Never syncs prompts, responses, file paths, project or repository names, credentials, or cost.
- Defines a backend interface so local folder, S3, and WebDAV implementations can reuse the layout later. V1 ships iCloud Drive only.
- For testing and diagnostics, `TOKEN_TAKEN_SYNC_ROOT` points the app and CLI at an existing test sync folder, like `TOKEN_TAKEN_SUPPORT_DIR` overrides local support storage.

See [ADR-0002](decisions/0002-icloud-drive-sync.md), superseding granularity decision [ADR-0005](decisions/0005-collection-granularity.md), and `docs/contracts/sync.md`. Daily cross-zone re-bucketing is inexact; fractional-offset boundaries and ambiguous fall-back hour labels also limit hourly attribution.

### Mobile report

- Builds one aggregate-only v1 report from the merged daily records the app already shows and publishes it, only while the opt-in "Sync to iPhone" setting is on, to `Documents/mobile/v1/report-<deviceId>.json` in the shared iCloud Documents container.
- Republishes after every successful refresh and at least hourly through a sleep-tolerant timer; turning the setting off deletes only this Mac's own report. Only the app publishes, because the CLI cannot carry the restricted iCloud entitlement.
- Carries no cost, paths, or project names. The companion iOS app is display-only: it never collects, merges, or prices.
- `TOKEN_TAKEN_MOBILE_REPORT_ROOT` points publication at an existing test folder, like `TOKEN_TAKEN_SYNC_ROOT` for sync.
- Follows `docs/contracts/mobile-report.md` and [ADR-0011](decisions/0011-mobile-report.md).

### Presentation and themes

- Provides main-window view models and SwiftUI views for day, week (Monday start), month, year, and all-time periods, with model, source, and enabled device breakdowns.
- Ships theme IDs `liquid-glass`, `sketchbook` (Field), and `cosmos` (Cosmos, 宇宙) in v1; `cosmos` replaces the reserved `geek` ID. `ThemeRuntime` mirrors the active theme for dynamic palette colors and glass helpers; changing theme rebuilds every scene. Field rendering lives in `FieldTheme.swift`, `FieldLandscapeView.swift`, and `FieldSurfaces.swift`.
- Cosmos renders its ray-marched scene through Metal and `MTKView` in `CosmosRenderer.swift`, `CosmosScene.swift`, `CosmosSceneView.swift`, and `CosmosShaders.metal`. It uses adaptive render scale, a still frame under Reduce Motion, and a dark-only appearance exception that preserves the saved light/dark preference.
- Preserves loading, empty, stale, and error states rather than displaying missing data as zero.
- Follows `docs/contracts/themes.md` for theme boundaries.

### Menu bar

- Uses `MenuBarExtra` for today's token total and a quick glance.
- Uses the same statistics pipeline as the main window and CLI.

### CLI

- Builds the `token-taken` executable in `TokenTakenCLI`.
- Exposes summaries and JSON/CSV data export through `TokenTakenKit`.
- Emits versioned JSON with documented errors and exit codes under `docs/contracts/cli.md`.
- Does not import or launch app UI.

### Updater

- `TokenTakenKit` provides `UpdateFeed`, `AppVersion`, and `UpdateFeedSelection` to decode schema-v1 `updates.json` and GitHub Releases API fallback payloads, restrict DMG downloads to allowlisted `https` hosts, and enforce strictly newer `(version, build)` progression with no rollbacks.
- `TokenTaken` provides `UpdateChecker` (scheduling checks 15 seconds after launch, every 6 hours, and on activation when the last check is over 6 hours old while **Keep Token Taken up to date automatically** is on, plus manual Check for Updates) and `AppUpdater` (downloading and verifying DMG size, SHA-256, `io.github.elijah7x.TokenTaken` Developer ID team signature, version/build match, and Gatekeeper assessment, staging the app, and installing in place on 10-minute idle when no refresh or window is in use—relaunching in the background—or on quit). Debug and ad-hoc builds never update.

## Data flow

1. Collectors return daily and hourly batches with device attribution. Missing locations throw `sourceUnavailable`, never a successful empty snapshot.
2. The runner merges each successful source/device's daily history and sparse long-term hourly history and replaces its 48-hour hourly snapshot transactionally, then records source health. Complete reads establish 48 hours of explicit hourly coverage; partial reads do not invent missing zero rows. Failures preserve cached data.
3. Opt-in sync (off by default) writes daily history and a separate rolling hourly snapshot to this Mac's folder and reads other device folders, preserving single-writer ownership and tombstones. An account-level source's rows are published inside that folder and collapse to one whole publication per account when read; device-local sources keep per-device attribution.
4. `TokenTakenKit` applies viewer-calendar period boundaries to original daily date labels for totals and breakdowns, without shifting them. The Day chart instead reads actual hourly rows in viewer-local hours, including DST and coverage gaps; it can differ from the daily total because hourly reasoning is unavailable or zones/coverage differ. Pricing adds versioned estimates at read time.
5. The main window, menu bar extra, and CLI query that shared pipeline. They do not implement separate aggregation rules.

Approximating an account-level source from device-local aggregates remains unsupported: account identity comes from the source itself (Cursor's own account device), not from `(source, day, model)` keys. ADR-0005 and the statistics/sync contracts record where that boundary sits.

## Refresh policy

- **On launch:** display cached data first, then start a refresh. Keep stale data labeled until the refresh succeeds.
- **On demand (manual-first):** let the user refresh from the main window (`Cmd-R`), menu bar extra, or Settings. There is no user-configurable refresh interval, keeping background work minimal (owner decision 2026-11-10).
- **Fallback:** run an automatic fallback refresh every 4 hours through a single sleep-tolerant timer (`>= 10` minute tolerance), skipping when a refresh is already running and refreshing on wake from sleep if more than 4 hours have passed since the last success. Collection is incremental per ADR-0006: unchanged sources keep their stored rows and only changed inputs are re-read. No other periodic background work runs, except the opt-in hourly iPhone-report timer in the Mobile report module, which stops when its setting is off, and the 6-hour automatic update check when **Keep Token Taken up to date automatically** is on. Sync reads happen with each refresh, except that a remote Mac read as `unavailable` or `partial` (not `stale`) triggers a remote-only re-read after 10 seconds, 30 seconds, 2 minutes and 10 minutes, then returns to the normal schedule. Independent source collectors run concurrently and expose last success and errors; `AppModel.dataIssues` summarizes failed/unavailable/stale sources and skipped records, and source health becomes stale by default after 24 hours.
- **Incremental:** use source cursors or incremental engine output when available and verified. Otherwise run a complete enough collection to prevent gaps. Never treat an unsupported incremental mode as complete.
- **Engine boundary:** ADR-0005 accepts complete daily history and rolling per-source hourly exports without a per-event export. Model-level hourly attribution and recovery of Codex total-only legacy records are not available.

## Open questions

| Question | Required decision point |
| --- | --- |
| Can a future privacy-preserving identity export enable exact account-scoped deduplication of device-local sources? | ADR-0005 and `docs/contracts/sync.md`; account-level sources already collapse per account ([ADR-0010](decisions/0010-cursor-account-usage.md)) |

Engine selection, collection granularity, and incremental refresh are resolved by [ADR-0003](decisions/0003-usage-engine.md), [ADR-0005](decisions/0005-collection-granularity.md), and [ADR-0006](decisions/0006-incremental-collection.md); sync publication and bundled pricing follow `docs/contracts/sync.md` and `docs/contracts/statistics.md`; Developer ID signing, notarization, and release mechanics are resolved by [ADR-0004](decisions/0004-distribution.md).
