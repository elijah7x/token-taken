# ADR-0015: Long-term hourly history

## Status

Accepted (2026-11-22)

## Context

Future weekly, monthly, and yearly recaps need hour-of-day usage facts—such as the latest hour the user was still using AI or how many late-night days occurred—across months or years. Existing storage cannot answer these questions:

- `hourly_usage` is a rolling 48-hour snapshot replaced on every refresh, so older hourly rows are discarded as the window advances.
- Re-reading agent logs on demand cannot recover historical hours because agents prune their own logs (for example, Claude Code deletes transcripts older than 30 days).
- Recording minute-level timestamps, per-model hourly rows, or raw events would add unnecessary granularity and storage risk without helping recap facts. Hour-level per-source aggregates are sufficient and carry no prompts, responses, paths, or model dimension.

## Decision

- Add a new `hourly_history` table in `SQLiteUsageStore`, migrating schema version 6 to 7 in place with no data loss.
- Columns match `hourly_usage`: `(device_id, source_id, hour_start)` primary key with `hour_start` in INTEGER Unix seconds, `input`, `cache_read`, `cache_write`, `output`, `reasoning`, `uncategorized`, `event_count`, and `reasoning_known`. No model column, no minute granularity, and no content.
- Store sparsely: never persist empty hours (`total == 0` and `eventCount == 0`); a zero-token hour with events, such as a Cursor request billed at zero tokens, is kept. `hourly_usage` keeps its rolling 48-hour snapshot and explicit zero-coverage semantics completely unchanged.
- `CollectionRunner` keeps building the 48-hour `hourly` window exactly as before and additionally extracts `hourlyHistory` from each collector batch: all rows of that source with `hourStart <= currentHour`, merged per `hourStart` (summing token counts and `eventCount`, ANDing `reasoningKnown`) and dropping empty hours.
- Merge `hourly_history` in the same SQLite transaction as `daily_usage` inside `SQLiteUsageStore.replace`:
  - Normal merge applies per-hour floor semantics mirroring [ADR-0008](0008-retained-history.md), using hour total `input + cacheRead + cacheWrite + output + reasoning + uncategorized`: an hour present in both batch and store is replaced only when the batch total is larger, or equal with an `eventCount` that is not smaller; stored hours absent from the batch are kept; batch-only hours are inserted.
  - Hours are absolute time, so a collection time-zone change never rebaselines `hourly_history`. Only a history epoch change applied from a complete read (`skippedRecords == 0`) does: hours strictly after the earliest batch hour adopt the batch exactly (stored hours after that hour absent from the batch are deleted), while earlier hours up to and including the earliest batch hour keep the floor rule.
  - A read with skipped records always uses the floor rule, never lowering or deleting hours.
  - For authoritative account-scoped snapshots from a complete read ([ADR-0010](0010-cursor-account-usage.md)), hours at or after the earliest batch hour adopt the batch exactly (absent hours after it deleted) and earlier hours are kept.
  - Compare candidate rows against stored column values first and write only rows that actually changed, so steady-state refreshes perform near-zero writes.
  - The cached re-store path for unchanged inputs (`appliesEpoch == false`) does not touch `hourly_history`.
- Maintenance paths—including `migrateAccountDevice` and unused account-device cleanup—handle `hourly_history` alongside `hourly_usage`.
- Expose `hourlyHistory() throws -> [HourlyUsage]` on `SQLiteUsageStore` and `MergedUsageStore` (returning local store rows only while history is unsynced), with a default empty implementation on `UsageStore` so other conformers compile unchanged. Existing UI, aggregator, CLI export, iCloud sync, and mobile report paths remain unchanged.
- Collectors emit hourly rows for their whole readable history (tokscale `hourly --since 2020-01-01`; native collectors no longer cut at 47 hours). `CollectionStamp.hourlyRange` (currently `1`) is part of every collector's stamp, so the first collection after upgrading re-reads unchanged inputs once and backfills history; raise it if the emitted hourly range widens again.
- Storage budget and retention: each sparse row is roughly ~100 bytes including its primary-key B-tree index. A heavy user with 5 sources x ~12 active hours/day produces ~22k rows/year, or ~2–3 MB/year. Because growth is modest and bounded, no retention cap is imposed.

## Consequences

- `hourly_history` is local-only and is not synced over iCloud Drive or published in the mobile report. A multi-Mac recap covers only this Mac until a separate sync decision is made.
- tokscale-backed sources remain hour-precise only (with no sub-hour timestamps and no hourly reasoning breakdown).
- Diff-checked writes and skipping `hourly_history` on cached unchanged re-stores keep refresh latency and SQLite write amplification near zero in steady state.
- Any future purge or deletion of a `(device, source)` must clear `hourly_history` together with `daily_usage`, `hourly_usage`, and `history_epochs`.
