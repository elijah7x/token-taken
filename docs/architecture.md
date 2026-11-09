# Token Taken architecture

Status: pre-alpha. No application or CLI target exists yet.

## Platform choices

- Native macOS app written in SwiftUI, with AppKit APIs where SwiftUI does not expose the required native behavior.
- Minimum macOS 26.0. Native Liquid Glass uses SwiftUI `glassEffect` or `NSGlassEffectView`; web and CSS imitations are out of scope.
- XcodeGen generates the Xcode project from `project.yml`.
- The app is non-sandboxed and distributed outside the Mac App Store with Developer ID so it can read agent logs in the user's home folder and write to iCloud Drive without CloudKit entitlements. Signing and notarization details remain open.
- A String Catalog provides English and Simplified Chinese from v1.

See [ADR-0001](decisions/0001-native-macos-app.md).

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
- Normalizes source, model, timestamp, token categories, event count, source identity, and source scope class.
- Distinguishes device-local sources from account-scoped sources for later attribution and deduplication.
- Reads agent logs read-only. Raw prompts, responses, paths, project names, and credentials do not enter sync output.
- Contains no upstream parser forks beyond separately reviewed patches. Engine upgrades pin a new version and rerun contract and reconciliation checks.

The engine interface is the integration point selected by [ADR-0003](decisions/0003-usage-engine.md) and governed by `docs/contracts/upstream.md`.

### Store

- Owns the local database under `~/Library/Application Support/Token Taken/`.
- Persists canonical usage data, source cursors where supported, device identity, tombstones, and cached metadata needed for launch and reconciliation.
- Supplies consistent reads to app and CLI through `TokenTakenKit`.
- Preserves cached data across failed refreshes and exposes freshness and error state.

The database technology, schema migrations, and app/CLI write coordination are open; see below.

### Pricing

- Maintains a versioned price table and maps normalized model IDs to prices.
- Derives cost at read time and returns the price-table version with the estimate.
- Never syncs cost and never presents an estimate as a bill.
- Keeps pricing semantics aligned with `docs/contracts/statistics.md`.

### Sync

- Uses the opt-in iCloud Drive folder `iCloud Drive/Token Taken/`, stored on disk at `~/Library/Mobile Documents/com~apple~CloudDocs/Token Taken/`. Sync is off by default.
- Gives each Mac a random UUID `deviceId` created on first launch. Hardware identifiers are not used.
- Writes only `Token Taken/v1/devices/<deviceId>/`, containing `device.json` and atomically rewritten monthly `usage-YYYY-MM.json` snapshots. Each folder has one writer.
- Reads and merges every device folder. A removed device leaves a tombstone and does not resurrect unless the user re-enables it.
- Syncs UTC hourly buckets keyed by `(deviceId, sourceId, modelId, hourStartUTC)`, with per-category token counts and event count. Viewers re-bucket into their own time zone.
- Never cross-deduplicates device-local sources. Deduplicates account-scoped sources across devices using the source-specific rule established after the engine spike.
- Never syncs prompts, responses, file paths, project or repository names, credentials, or cost.
- Defines a backend interface so local folder, S3, and WebDAV implementations can reuse the layout later. V1 ships iCloud Drive only.

See [ADR-0002](decisions/0002-icloud-drive-sync.md) and `docs/contracts/sync.md`. Non-whole-hour time zones are a known limitation of hourly buckets.

### Presentation and themes

- Provides main-window view models and SwiftUI views for day, month, year, and all-time periods, with model, source, and enabled device breakdowns.
- Ships theme ID `liquid-glass` in v1. Reserves `geek` and `sketchbook` for later themes without shipping those themes in v1.
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

## Data flow

1. The Collector invokes the pinned engine on a refresh and adapts its output into canonical records. Device-local records carry their device attribution; account-scoped records carry source identity for deduplication.
2. The Store validates and persists local records and refresh metadata. It applies the identity and statistics rules in `docs/contracts/statistics.md`.
3. When sync is enabled, Sync writes this Mac's aggregate UTC hourly buckets to its own monthly files and reads other device folders. It applies source-scope attribution, cross-device deduplication, and tombstones before producing merged input for queries.
4. `TokenTakenKit` converts stored or merged buckets into the requested period, source, model, and device groupings. Pricing adds cost estimates at read time.
5. The main window, menu bar extra, and CLI query that shared pipeline. They do not implement separate aggregation rules.

The exact account-scoped deduplication key and its representation in aggregate-only sync remain open. ADR-0003 and the statistics and sync contracts must close them without weakening P1 or P3.

## Refresh policy

- **On launch:** display cached data first, then start a refresh. Keep stale data labeled until the refresh succeeds.
- **Periodic:** refresh while the app is running. Prevent overlapping collection runs and expose the last successful refresh and any error. The default interval and pause policy are open.
- **On demand:** let the user request a refresh from the app.
- **Incremental:** use source cursors or incremental engine output when available and verified. Otherwise run a complete enough collection to prevent gaps. Never treat an unsupported incremental mode as complete.
- **Engine boundary:** ADR-0003 must establish which candidates support incremental collection and whether timestamps have event-level or at least hourly resolution.

## Open questions

| Question | Required decision point |
| --- | --- |
| Which engine ships, which agents it covers, and whether it needs a bundled runtime? | ADR-0003 and `docs/contracts/upstream.md` |
| What source event identity deduplicates Cursor and other account-scoped data across Macs, including old Zcode samples? | ADR-0003 and `docs/contracts/statistics.md` |
| How can aggregate-only hourly sync represent that identity without losing exact cross-device deduplication? | `docs/contracts/sync.md`, informed by ADR-0003 |
| Do candidate engines expose timestamps at hourly resolution or finer, and how should non-whole-hour time zones be documented? | ADR-0003, `docs/contracts/statistics.md`, and `docs/contracts/sync.md` |
| Which local database, migration policy, and app/CLI write coordination should the Store use? | A future local-store ADR before implementation |
| What periodic interval, power policy, and incremental fallback should refresh use? | A future refresh-policy ADR after ADR-0003 |
| What price-table sources, update cadence, and model aliases should Pricing use? | `docs/contracts/statistics.md` and `docs/contracts/upstream.md` |
| Which Developer ID signing, notarization, and release process should distribution use? | A future distribution ADR before release |
