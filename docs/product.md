# Token Taken v1 product specification

Status: pre-alpha. This document defines the v1 acceptance target. The contracts under `docs/contracts/` define the corresponding data and interface rules.

## Problem

AI coding agents record token usage in different formats and locations. Using several agents or Macs makes a complete total difficult to obtain, and repeated records within an agent log can inflate that total. Existing workflows also lack a common, machine-readable view that another tool can query.

Token Taken will present a lightweight native dashboard, combine device-local usage across Macs, and expose the same statistics through a CLI. Cost will remain an estimate based on a versioned price table, never a bill.

## Target users

Token Taken is for anyone who uses one or more AI coding agents on a Mac, including people who do not use a terminal. A first-time user with supported local logs should be able to open the app and read a daily total without editing configuration files.

Developers and other tools can use the `token-taken` CLI for the same totals and data export.

## Acceptance criteria

### P1: Several Macs produce one reconcilable total

- Two or more Macs using the same Apple ID can each opt in to iCloud Drive sync. Sync is off by default.
- With sync on, the main window shows a combined total and a per-device breakdown. The attribution rules in `docs/contracts/statistics.md` must make the breakdown sum to the combined total.
- On the vetted multi-device fixture, the combined total equals the sum of device-local usage across synced devices. Every input event within a source must be counted once, identified as a within-source duplicate, or reported as rejected with a reason.
- All v1 sources are device-local and remain attributed to their originating device without cross-device deduplication under `docs/contracts/sync.md`. Account-scoped cross-device deduplication is deferred ([ADR-0005](decisions/0005-collection-granularity.md)).
- Readers and writers honor a device manifest with `tombstone: true` by excluding that device and refusing further writes to its identity (`docs/contracts/sync.md`); v1 has no UI to remove, adopt, or re-enable a device.

### P2: The app is beautiful and lightweight

- Under `liquid-glass`, the main window and menu bar extra use native Liquid Glass through SwiftUI or AppKit APIs. Web or CSS imitations do not satisfy this criterion.
- The v1 `liquid-glass` theme passes the owner's design review at supported window sizes. Primary actions are keyboard accessible and meaningful controls have accessibility labels.
- The main window supports day, week (Monday start), month, year, and all-time views, per-model and per-source breakdowns, and per-device breakdowns when sync is on. The menu bar extra shows today's token total and a quick glance.
- English and Simplified Chinese interfaces ship through a String Catalog.
- Idle CPU stays near 0% when collection and sync are inactive (target, to confirm by measurement).
- Memory use after launch with cached data stays at or below 150 MB (target, to confirm by measurement).
- The complete app bundle, including the selected engine, stays at or below 100 MB (target, to confirm by measurement).
- Cached data appears within 1.0 second after launch on the documented reference Mac and fixture (target, to confirm by measurement).

The release check must record the reference hardware, dataset size, build configuration, and measurement method for the four numeric targets.

### P3: Numbers are accurate and reconcilable

- Before engine selection, ADR-0003's spike compares candidates against the same sanitized local samples and a manually vetted expected event ledger. Raw samples remain outside the repository.
- The fixture set covers every device-local agent shipped in v1, including old and native Zcode data. Cursor and Qoder are deferred ([ADR-0003](decisions/0003-usage-engine.md), [ADR-0005](decisions/0005-collection-granularity.md)).
- For those fixtures, daily `input`, `cacheRead`, `cacheWrite`, `output`, `reasoning`, and `uncategorized` token counts and event counts match the expected ledger by source, model, local day, and device after documented deduplication, and 48-hour hourly activity rows match by source, hour, and device ([ADR-0005](decisions/0005-collection-granularity.md)).
- Every total equals the sum of its displayed components. Time-period totals use the viewer's time zone and the rules in `docs/contracts/statistics.md`.
- Collection reports malformed or unsupported records instead of silently treating them as zero. A failed refresh leaves cached data identifiable as stale.
- Cost is calculated at read time from a versioned price table and labeled as an estimate. The same usage and price-table version must reproduce the same estimate.

### P4: Other tools can read the same numbers

- The `token-taken` CLI reads the same local store and uses the same `TokenTakenKit` statistics pipeline as the app. It does not depend on or launch app UI.
- For the same store, period, time zone, filters, and price-table version, CLI token counts match the app exactly. Cost estimates match under the same conditions.
- JSON output follows `docs/contracts/cli.md`, is machine-parseable, and has a documented schema version. JSON and CSV export cover v1 data export.
- Errors use documented exit codes and do not present partial output as a complete result.

Example:

```sh
token-taken models --period month --json
```

## v1 scope

### Collection and statistics

- Reuse the pinned `tokscale` 4.21.0 usage engine through a thin adapter, combined with native Swift collectors where required by [ADR-0003](decisions/0003-usage-engine.md) and [ADR-0005](decisions/0005-collection-granularity.md).
- Target agents: Claude Code, Codex, Zcode, OpenCode, Kimi Code, Gemini CLI, pi, oh-my-pi, Factory Droid, Grok CLI, Devin (CLI and desktop), Antigravity (CLI and IDE extension), DeepSeek Harness, and fx; Cursor (account credentials, network access, and cross-device deduplication) and Qoder (credits only, no token counts) are deferred ([ADR-0003](decisions/0003-usage-engine.md), [ADR-0005](decisions/0005-collection-granularity.md)).
- All v1 sources are device-local and parsed from logs or databases on the current Mac. Account-scoped sources fetched from a provider account and deduplicated across Macs are deferred.
- Report uncached input as `input`, plus `cacheRead`, `cacheWrite`, `output`, and `reasoning` categories, with `uncategorized` for known totals whose category split is unavailable ([ADR-0005](decisions/0005-collection-granularity.md)).
- Refresh on launch, on demand, and with a fixed 4-hour fallback while running, with no user-configurable interval, to keep background cost minimal (owner decision 2026-11-10); use incremental collection where the engine supports it.

### Presentation and distribution

- Ship the `liquid-glass` and Field (`sketchbook`) themes, with a Follow System, Light, or Dark setting, while keeping `geek` as a reserved theme ID (owner decision 2026-11-12, [ADR-0007](decisions/0007-field-theme.md)).
- Provide the main window, per-model/source/device breakdowns described above, and a minimal menu bar extra.
- Distribute a non-sandboxed macOS app outside the Mac App Store with Developer ID. Signing, notarization, and DMG packaging follow [ADR-0004](decisions/0004-distribution.md).
- Keep local data under `~/Library/Application Support/Token Taken/`.

### Synchronization and interfaces

- Ship iCloud Drive sync for Macs on the same Apple ID. The toggle is opt-in and off by default.
- Sync aggregate usage metadata only: monthly files of daily records per collecting-device local calendar day, time zone, source, and model, plus a rolling snapshot of the last 48 hours of per-source hourly rows and sanitized device/source health metadata (`docs/contracts/sync.md`). Never sync prompts, responses, file paths, project or repository names, credentials, diagnostic error messages, or cost.
- Provide the `token-taken` CLI with JSON output and JSON/CSV export.
- Localize the app in English and Simplified Chinese from v1.

## v1 non-goals

- Quota or limit tracking.
- Windows or Linux support.
- Mac App Store distribution.
- The Geek theme.
- Non-iCloud sync backends, including local folder, S3, and WebDAV backends.
- Styled export cards. V1 export is CLI JSON/CSV.
- Team or multi-user features.
- Telemetry.

## Later roadmap

These items follow v1 and are not release commitments:

- Geek: a flat, modern, dark theme.
- Styled and customizable export cards in v1.x.
- Local folder, S3, and WebDAV sync behind the sync backend interface.

## Open decisions

- Engine upgrade verification and recovery of legacy total-only Codex records: [ADR-0003](decisions/0003-usage-engine.md), [ADR-0005](decisions/0005-collection-granularity.md), and `docs/contracts/upstream.md`.
- Price-table delivery (resolved 2026-11-11): prices ship bundled with no runtime network access, refreshed by `scripts/update-prices.py` before each release with the version and alias rules in `docs/contracts/statistics.md`.
- Privacy-preserving account-scoped cross-device deduplication, device removal/adoption UI, and real multi-Mac iCloud Drive acceptance: [ADR-0005](decisions/0005-collection-granularity.md) and `docs/contracts/sync.md`.
