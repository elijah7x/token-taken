# ADR-0005: Collection granularity

## Status

Accepted (2026-11-10)

## Context

The pinned tokscale 4.21.0 CLI has no per-event export. `graph` supplies complete-history daily, client, and model aggregates with five token categories. Its date labels are local calendar dates, not UTC days. `hourly --json -c <client>` supplies per-source hourly aggregates with models merged and no reasoning field. Labelling graph dates UTC or inventing an hourly curve from daily totals misrepresents the available evidence.

This decision supersedes the UTC-hour-by-model and per-event-export requirements in ADR-0002 and ADR-0003. It does not establish account-scoped cross-device deduplication or expand approved network access.

## Decision

### Daily history

- Store one `UsageRecord` per `(deviceID, sourceID, modelID, day)`. `day` is a `YYYY-MM-DD` calendar-date string in the collecting device's time zone, recorded as `timeZoneID` on every row. Preserve `rawModelID`, disjoint `TokenCounts`, and `eventCount`.
- Pass `TZ=TimeZone.current.identifier` explicitly to every tokscale subprocess. Keep the isolated `TOKSCALE_CONFIG_DIR`, offline operation, and 300-second subprocess timeout. Refresh the isolated bucket-time-zone setting to the same identifier, including for installations with an old UTC setting.
- Keep complete daily history. The recorded zone describes the current collection pass, not an inferred historical location of the device. A subsequent full collection after changing zones replaces that device/source's earlier date bucketing.
- `UsageRecord.dayInterval` derives the start and exclusive end as absolute dates in the recorded zone, respecting DST.
- Model normalization trims whitespace and lowercases IDs; it does not guess provider aliases. The raw ID supplied by the collector is retained. For tokscale this is the exported `modelId`, not a promise to recover an original pre-normalization log field. If spellings collapse onto one daily key, retain a deterministic representative raw spelling.

### Unknown categories

`TokenCounts.uncategorized` represents a known total whose category split is unknown. It defaults to zero, including when decoding older counts. It participates in addition and `total`, but is not a `TokenCategory`, never receives a price, and always contributes to `unpricedTokens`. The five named categories are disjoint; separately reported reasoning included in output must be subtracted from output before storage.

### Hourly activity

- Store `HourlyUsage` per `(deviceID, sourceID, hourStart)`, without model identity. `hourStart` is an absolute instant, persisted as integer Unix seconds; rows also carry counts, `eventCount`, and `reasoningKnown`.
- Invoke `hourly --json -c <client> --since <local date two days ago>` once per tokscale client, concurrently across clients. Convert the returned local `YYYY-MM-DD HH:00` label using the same zone as collection. Set `reasoningKnown=false`; do not infer missing reasoning from daily totals or allocate it to hours.
- Retain the current local hour and 47 preceding absolute hourly intervals on a successful collection. Daily history is unaffected. A failed or unavailable source keeps its last cached rows, even when those rows have aged outside the active window; their health and missing recent coverage remain visible.
- Successful complete local reads persist explicit zero rows for otherwise absent hours in that 48-hour window. Reads with skipped records do not manufacture zero coverage. This distinguishes confirmed empty hours from absent collection.
- Zcode, pi, and oh-my-pi use native event timestamps for their hourly rows, with their own normalization and deduplication rules. pi and oh-my-pi are not also collected by tokscale.

### Queries and pricing

- Period boundaries use the viewer's calendar and time zone. Place each daily row on the same calendar-date label, without shifting it to another date. This is exact when collecting and viewing zones match. Daily aggregates cannot reconstruct exact viewer-zone day/month/year totals when zones differ; do not imply otherwise.
- The Day summary's totals, categories, costs, and model/source/device breakdowns come from daily records. Only the Day chart comes from actual hourly rows converted into viewer-local hours. There is no fabricated activity curve.
- A Day chart may differ from its daily total because tokscale hourly output omits reasoning. Cross-zone placement and incomplete hourly coverage can create additional differences; never rescale the chart to force agreement.
- DST days have their actual number of hourly intervals (including the 23-hour New York day on 2026-03-08). tokscale's offset-free repeated-hour labels cannot distinguish the two occurrences during a fall-back transition; that ambiguity is an upstream limitation. Hourly buckets also cannot be split exactly across viewer boundaries with a different fractional UTC offset.
- `SeriesPoint.isKnown=false` denotes missing hourly coverage; its numeric zero is only a placeholder, not observed zero usage. `bySource` includes a zero only when a stored row establishes coverage. A point is fully known only when every device/source contributing that day's daily data is covered.
- Use `PriceTable.bundled` for real stores and `PriceTable.synthetic` for synthetic previews. Pricing is computed at read time; uncategorized tokens remain unpriced.

### Store, health, and interfaces

- Public collector API: `CollectionBatch(daily: [UsageRecord] = [], hourly: [HourlyUsage] = [], skippedRecords: Int = 0)`; `UsageCollector: Sendable` requires `sourceIDs: [String]` and `collect() async throws -> CollectionBatch`. A missing source location throws public `CollectorError.sourceUnavailable` rather than returning an empty snapshot. `UsageDay.string(from: Date, in: TimeZone) -> String` and `UsageDay.date(from: String, in: TimeZone = .current) -> Date?` provide date-label conversion.
- SQLite schema version 2 replaces `usage` with `daily_usage` and `hourly_usage`. Daily columns are `device_id`, `source_id`, `model_id`, `raw_model_id`, `day`, `time_zone`, `input`, `cache_read`, `cache_write`, `output`, `reasoning`, `uncategorized`, `event_count`; its primary key is `(device_id, source_id, model_id, day)`. Hourly columns are `device_id`, `source_id`, `hour_start`, the same six count fields, `event_count`, `reasoning_known`; its primary key is `(device_id, source_id, hour_start)`.
- On an older schema, transactionally drop/recreate usage tables because the cache can be rebuilt. Keep devices and health metadata, add `skipped_records` and `state` to health, and mark preserved health stale until recollection. Reject unknown newer schemas; a read-only CLI asks the user to open the app for migration rather than migrating.
- `replace(batch:sourceID:deviceID:)` replaces daily and hourly snapshots for that source/device in one transaction. Invalid or conflicting inserts roll back both tables. `UsageStore` exposes throwing `records()` and `hourly()` reads.
- `SourceHealth` states are `ok`, `unavailable`, `notInstalled`, `failed`, and `stale`; skipped records independently indicate partial data. The current default freshness threshold is 24 hours. Failed/unavailable collection never replaces data. Store and health-write errors are returned through runner results rather than suppressed; `health()` reads throw.
- `CollectionRunner.runAll(now:) async -> [SourceHealth]` returns collection and persistence errors in its results. `SQLiteUsageStore.health() throws -> [SourceHealth]` exposes read failures. `SourceHealth.State` is public; `markingStale(now:after:)` derives freshness without losing failure/unavailable states. `UsageAggregator` accepts an optional explicit `priceTable` for deterministic fixtures, otherwise choosing the real/synthetic table by store type.
- `AppModel.dataIssues` exposes `failed`, `unavailable`, `stale`, `skippedRecords`, `devices`, `count`, and `isPartial` without changing views. Rendering unknown-hour gaps and exposing this summary are presentation work.

## Codex total-only gap

Read-only inspection of the upstream reference (workspace package version 4.21.0 in `Cargo.toml`), specifically `crates/tokscale-core/src/sessions/codex.rs`, shows `CodexTotals::from_usage` reads input, output, cached input, and reasoning, but not `total_tokens`. The token-count path filters out zero-category results after `into_tokens()`. Thus records containing only a positive `total_tokens` and no usable category counters are not exported as known uncategorized totals. `total_tokens` is also used for fork-inheritance checks, not as a category allocation.

This is a known gap against ADR-0003's preservation goal. Adding `uncategorized` makes the canonical model capable of representing such records, but does not recover them from aggregate-only CLI output. No token count or category split is invented. Distinguish these records from upstream comments using “total-only” to mean a `total_token_usage` object that still contains category counters. Recovering genuinely total-only legacy data needs a separately reconciled adapter or upstream change.

## Consequences

- Daily history preserves model and reasoning detail; the last 48 hours preserve honest per-source activity shape, not per-model hourly attribution.
- Sync must carry separate daily and hourly record kinds, preserve collection zones and reasoning knowledge, and never add hourly counts to daily counts.
- Aggregate-only data cannot perform exact account-scoped cross-device deduplication. Cursor remains deferred; no timestamp/export work is hidden in this release.
- Source reconciliation and real runtime acceptance remain required. Synthetic fixtures and tests define intended behavior but do not establish accuracy on private logs.
