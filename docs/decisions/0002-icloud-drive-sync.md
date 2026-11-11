# ADR-0002: iCloud Drive sync

## Status

Accepted

Status note: [ADR-0005](0005-collection-granularity.md) supersedes the UTC-hour-by-model sync layout here with collecting-device local calendar days and a separate rolling per-source hourly snapshot; it also supersedes ADR-0003's native `pi` collector scope and legacy total-only Codex handling.

## Date

2026-11-09

## Context

- P1 requires one combined usage total across several Macs with a per-device breakdown.
- V1 targets Macs using the same Apple ID.
- Sync must be opt-in, off by default, and limited to aggregate usage metadata.
- Devices can observe the same account-scoped usage, so merging requires source-aware deduplication.

## Decision

- Ship iCloud Drive sync in v1 behind an opt-in toggle that is off by default.
- Use `iCloud Drive/Token Taken/`, stored on disk at `~/Library/Mobile Documents/com~apple~CloudDocs/Token Taken/`.
- Create `deviceId` as a random UUID on first launch. Do not use hardware identifiers.
- Give each Mac one folder, `Token Taken/v1/devices/<deviceId>/`. A Mac writes only its own folder, containing `device.json` and monthly `usage-YYYY-MM.json` snapshots.
- Rewrite each monthly snapshot atomically. Each device folder has a single writer, so devices do not edit one another's files.
- Readers merge all device folders.
- Sync UTC hourly buckets keyed by `(deviceId, sourceId, modelId, hourStartUTC)`, with `input`, `cacheRead`, `cacheWrite`, `output`, and `reasoning` token counts plus event count.
- Let each viewer re-bucket usage into its own time zone. Hourly buckets have a known limitation for non-whole-hour time zones.
- Attribute device-local sources to their originating device and never cross-deduplicate them.
- Deduplicate account-scoped sources across devices. The exact source-specific key remains open until the ADR-0003 engine spike and must be defined in `docs/contracts/statistics.md` and `docs/contracts/sync.md`.
- Write a tombstone when the user removes a device. Do not resurrect that device unless the user re-enables it.
- Never sync prompts, responses, file paths, project or repository names, credentials, or cost. Derive cost at read time.
- Put sync behind a backend interface so later backends can reuse the same folder layout.

The normative format and behavior live in `docs/contracts/sync.md` and `docs/contracts/privacy.md`.

## Consequences

- Users must enable iCloud Drive and use the same Apple ID on participating Macs. Sync freshness depends on iCloud Drive propagation.
- Single-writer folders avoid cross-device edit conflicts. Readers still need to handle missing, incomplete, stale, and tombstoned device data.
- Hourly UTC buckets reduce synced detail and permit local time-zone views, but they cannot preserve sub-hour boundaries for non-whole-hour offsets.
- The selected engine must expose timestamps at one-hour resolution or finer. This remains open pending ADR-0003.
- Aggregate-only sync must retain enough source identity for exact account-scoped deduplication. ADR-0003 and the statistics and sync contracts must resolve this before v1 acceptance.
- Cost stays local to the reader's price-table version and remains an estimate.

## Alternatives

- **CloudKit:** rejected for v1 because it adds entitlements, developer-account requirements, and more moving parts.
- **S3 or WebDAV:** deferred. Add them later behind the same backend interface and folder layout.
- **No synchronization:** rejected because it would not satisfy the owner's multi-Mac acceptance criterion.
