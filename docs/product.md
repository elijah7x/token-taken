# Token Taken v1 product specification

Status: pre-alpha. This document defines the v1 acceptance target. The contracts under `docs/contracts/` define the corresponding data and interface rules.

## Problem

AI coding agents record token usage in different formats and locations. Using several agents or Macs makes a complete total difficult to obtain, and repeated account-scoped data can inflate that total. Existing workflows also lack a common, machine-readable view that another tool can query.

Token Taken will present a lightweight native dashboard, reconcile usage across devices, and expose the same statistics through a CLI. Cost will remain an estimate based on a versioned price table, never a bill.

## Target users

Token Taken is for anyone who uses one or more AI coding agents on a Mac, including people who do not use a terminal. A first-time user with supported local logs should be able to open the app and read a daily total without editing configuration files.

Developers and other tools can use the planned `token-taken` CLI for the same totals and data export.

## Acceptance criteria

### P1: Several Macs produce one reconcilable total

- Two or more Macs using the same Apple ID can each opt in to iCloud Drive sync. Sync is off by default.
- With sync on, the main window shows a combined total and a per-device breakdown. The attribution rules in `docs/contracts/statistics.md` must make the breakdown sum to the combined total.
- On the vetted multi-device fixture, the combined total equals all device-local usage plus account-scoped usage after cross-device deduplication. Every input event must be counted once, identified as a duplicate, or reported as rejected with a reason.
- Device-local usage remains attributed to its originating device. Account-scoped usage is deduplicated across devices under `docs/contracts/sync.md`.
- A removed device leaves a tombstone and does not reappear unless the user re-enables it.

### P2: The app is beautiful and lightweight

- The main window and menu bar extra use native Liquid Glass through SwiftUI or AppKit APIs. Web or CSS imitations do not satisfy this criterion.
- The v1 `liquid-glass` theme passes the owner's design review at supported window sizes. Primary actions are keyboard accessible and meaningful controls have accessibility labels.
- The main window supports day, month, year, and all-time views, per-model and per-source breakdowns, and per-device breakdowns when sync is on. The menu bar extra shows today's token total and a quick glance.
- English and Simplified Chinese interfaces ship through a String Catalog.
- Idle CPU stays near 0% when collection and sync are inactive (target, to confirm by measurement).
- Memory use after launch with cached data stays at or below 150 MB (target, to confirm by measurement).
- The complete app bundle, including the selected engine, stays at or below 100 MB (target, to confirm by measurement).
- Cached data appears within 1.0 second after launch on the documented reference Mac and fixture (target, to confirm by measurement).

The release check must record the reference hardware, dataset size, build configuration, and measurement method for the four numeric targets.

### P3: Numbers are accurate and reconcilable

- Before engine selection, ADR-0003's spike compares candidates against the same sanitized local samples and a manually vetted expected event ledger. Raw samples remain outside the repository.
- The fixture set covers every agent claimed for v1, Cursor usage observed from multiple Macs, and old Zcode data. Final agent coverage depends on ADR-0003.
- For those fixtures, `input`, `cacheRead`, `cacheWrite`, `output`, and `reasoning` token counts match the expected ledger exactly by source, model, hour, and device. Event counts also match after documented deduplication.
- Every total equals the sum of its displayed components. Time-period totals use the viewer's time zone and the rules in `docs/contracts/statistics.md`.
- Collection reports malformed or unsupported records instead of silently treating them as zero. A failed refresh leaves cached data identifiable as stale.
- Cost is calculated at read time from a versioned price table and labeled as an estimate. The same usage and price-table version must reproduce the same estimate.

### P4: Other tools can read the same numbers

- The `token-taken` CLI reads the same local store and uses the same `TokenTakenKit` statistics pipeline as the app. It does not depend on or launch app UI.
- For the same store, period, time zone, filters, and price-table version, CLI token counts match the app exactly. Cost estimates match under the same conditions.
- JSON output follows `docs/contracts/cli.md`, is machine-parseable, and has a documented schema version. JSON and CSV export cover v1 data export.
- Errors use documented exit codes and do not present partial output as a complete result.

Planned example:

```sh
token-taken summary --period month --by model --json
```

## v1 scope

### Collection and statistics

- Reuse a pinned open-source usage engine through a thin adapter. The candidates and spike are defined in [ADR-0003](decisions/0003-usage-engine.md).
- Target agents: Claude Code, Codex, Cursor, Zcode, OpenCode, Kimi Code, Gemini CLI, pi, oh-my-pi, Qoder, Factory Droid, and Grok CLI. Shipping coverage must be explicit and depends on the spike.
- Support device-local sources parsed from logs on the current Mac and account-scoped sources fetched from a provider account and visible from multiple Macs.
- Report uncached input as `input`, plus `cacheRead`, `cacheWrite`, `output`, and `reasoning` categories.
- Refresh on launch, periodically, and on demand, using incremental collection where the engine supports it.

### Presentation and distribution

- Ship the `liquid-glass` theme only, while keeping `geek` and `sketchbook` as theme IDs in the theme system.
- Provide the main window, per-model/source/device breakdowns described above, and a minimal menu bar extra.
- Distribute a non-sandboxed macOS app outside the Mac App Store with Developer ID. Signing, notarization, and DMG packaging follow [ADR-0004](decisions/0004-distribution.md).
- Keep local data under `~/Library/Application Support/Token Taken/`.

### Synchronization and interfaces

- Ship iCloud Drive sync for Macs on the same Apple ID. The toggle is opt-in and off by default.
- Sync UTC hourly aggregate usage metadata only. Never sync prompts, responses, file paths, project or repository names, credentials, or cost.
- Provide the `token-taken` CLI with JSON output and JSON/CSV export.
- Localize the app in English and Simplified Chinese from v1.

## v1 non-goals

- Quota or limit tracking.
- Windows or Linux support.
- Mac App Store distribution.
- Geek or Sketchbook themes.
- Non-iCloud sync backends, including local folder, S3, and WebDAV backends.
- Styled export cards. V1 export is CLI JSON/CSV.
- Team or multi-user features.
- Telemetry.

## Later roadmap

These items follow v1 and are not release commitments:

- Geek: a flat, modern, dark theme.
- Sketchbook: a hand-drawn, nature-inspired theme.
- Styled and customizable export cards in v1.x.
- Local folder, S3, and WebDAV sync behind the sync backend interface.

## Open decisions

- Engine choice, final agent coverage, timestamp granularity, and runtime packaging: [ADR-0003](decisions/0003-usage-engine.md) and `docs/contracts/upstream.md`.
- Statistics identity, deduplication keys, time-zone behavior, and price-table semantics: `docs/contracts/statistics.md`.
- Account-scoped cross-device deduplication within aggregate-only sync: ADR-0003 and `docs/contracts/sync.md`.
