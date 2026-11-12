Status: Implemented v1 (2026-11-11)

# Statistics contract

## Usage and token categories

- The canonical query input is aggregate records, not an exported event ledger. Collectors return `CollectionBatch(daily:hourly:skippedRecords:)` under [ADR-0005](../decisions/0005-collection-granularity.md).
- `UsageRecord` stores one collecting-device local calendar day per `(deviceID, sourceID, modelID, day)`, with `timeZoneID`, `rawModelID`, disjoint `counts`, and `eventCount`. Complete daily history is retained.
- `HourlyUsage` stores one absolute hourly instant per `(deviceID, sourceID, hourStart)`, with disjoint counts, `eventCount`, and `reasoningKnown`. Hourly models are merged; hourly data MUST NOT be added to daily data.
- `input` is uncached input. It MUST exclude tokens counted as `cacheRead` or `cacheWrite`, including when an engine reports inclusive input.
- `cacheRead` and `cacheWrite` are tokens read from and written to a provider cache. They MUST NOT also be counted as input.
- `output` excludes separately reported reasoning when the source reports reasoning inside output. `reasoning` is stored separately only when the source reports it; it MUST NOT be inferred from opaque output.
- `uncategorized` is a known total with an unknown category split, not a sixth `TokenCategory`. It defaults to zero in initialization and older Codable data, participates in addition, and is never priced.
- `cacheWrite1h` is the subset of `cacheWrite` written with a one-hour TTL. It is not a category, never enters totals or day comparisons, and is priced at the model's explicit one-hour cache-write rate, falling back to the cache-write rate when none is published.
- Total tokens are always `input + cacheRead + cacheWrite + output + reasoning + uncategorized` after normalization. An inclusive source count MUST be normalized before storage, not added twice at query time.
- Missing or unparseable data is unknown, not zero. `reasoningKnown=false` distinguishes omitted hourly reasoning from a measured zero.

## Source identity and deduplication

- Source IDs are stable lowercase kebab-case. Factory Droid is `factory`; its tokscale client selector is `droid`. Devin is `devin` (native Swift: the CLI database and Desktop ACP events), Antigravity is `antigravity` (native Swift: the CLI and extension conversation databases), MiniMax Code is `mcode`, and DeepSeek CLI is `deepseek-cli`.
- Every tokscale client of one source is requested in the same engine run, in both graph and hourly output, and a change in any of them re-collects them all. The native Antigravity collector deduplicates provider response IDs once per collection across both of its databases.
- A source is available when the root of any of its clients exists. Change detection reads file metadata (path, size, modification time) only, including a single SQLite database with its `-wal`/`-shm` siblings. The native Devin collector opens that database read-only and streams its rows, because it can exceed 1 GB.
- Native collectors deduplicate before forming aggregates using stable native IDs or documented deterministic fingerprints. Ingestion time and read order MUST NOT become event identity.
- tokscale performs its own source-specific deduplication before export; its graph and hourly output do not expose per-event dedup keys. Aggregate natural keys identify snapshot rows, not individual calls.
- Device-local sources are attributed to their collecting device and MUST NOT be cross-device deduplicated. Exact account-scoped cross-device deduplication is not supported by these aggregates. Cursor remains deferred and opt-in; do not claim account-scoped accuracy.

| Source | Collector | Reasoning and identity rules |
| --- | --- | --- |
| Claude Code | tokscale `claude` | Engine category and dedup rules; hourly reasoning unavailable |
| Codex | tokscale `codex` | Engine splits reasoning from output and handles fork replay; genuinely total-only legacy records remain a known export gap |
| Grok | tokscale `grok` | Engine category and dedup rules; hourly reasoning unavailable |
| Kimi Code | tokscale `kimi` (`~/.kimi/sessions` and `~/.kimi-code/sessions`, honours `KIMI_CODE_HOME`) | Engine category and dedup rules, including usage records; hourly reasoning unavailable |
| OpenCode | tokscale `opencode` | Engine category and dedup rules; hourly reasoning unavailable |
| Gemini CLI | tokscale `gemini` | Engine category and dedup rules; hourly reasoning unavailable |
| Factory Droid | tokscale `droid` | Engine category and dedup rules; hourly reasoning unavailable |
| Devin | native Swift | CLI `~/.local/share/devin/cli/sessions.db` (honours `XDG_DATA_HOME`) and Desktop `~/Library/Application Support/Devin/User/acp-events/*.ndjson`. Assistant rows only. `input` is `input_tokens`, `cacheWrite` is `cache_creation_tokens`, `cacheRead` is `cache_read_tokens`, `output` is `output_tokens`, `reasoning` is 0 because the provider reports none separately; `num_tokens` becomes output only when all four are zero. `(session, request_id)` is deduplicated with the lowest `row_id` kept, and a row without a request id is keyed by its `row_id`. The day and hour come from `metadata.started_generation_at`, then `metadata.created_at`, then the row's `created_at`; the write time of the row database is never used for dating. Desktop usage whose title resolves to a session the CLI already counted is dropped. Hourly reasoning unavailable |
| Antigravity | native Swift (`~/.gemini/antigravity-cli/conversations/*.db`, honours `GEMINI_CLI_HOME`, and `~/.gemini/antigravity/conversations/*.db`) | Input is `usage.#2` only; the fixed per-model preamble `usage.#1` is never counted (ADR-0009); response-ID dedup across both databases; reasoning `#10` separate from output `#9` |
| DeepSeek Harness | tokscale `dsh` (`~/.dsh/sessions`, honours `DSH_HOME`) | Engine category and dedup rules; hourly reasoning unavailable |
| fx | tokscale `fx` (`~/.fx/sessions`) | Engine category and dedup rules; hourly reasoning unavailable |
| MiniMax Code | native Swift (`message.usage` in `~/.minimax/v2/sessions/**/messages.jsonl`) | `message_id` deduplication; `input` excludes `cacheRead`; reasoning unavailable; `usage.cost` is never a cost source |
| DeepSeek CLI | native Swift | Session-level `metadata.total_tokens` only, recorded as `uncategorized` and never priced; messages carry no usage, so there is no category split and no hourly series |
| Zcode | native Swift | Completed native usage plus pre-boundary legacy assistant messages; exact cross-session copies removed; inclusive input/output split |
| pi | native Swift | Entry-ID deduplication, not response-ID-only deduplication; includes operation usage |
| oh-my-pi | native Swift | Entry-ID deduplication; reasoning tokens split from inclusive output |
| Qoder | not token-counted | Credits only; tokens unavailable |
| Cursor | deferred | Account credentials, network access, and exact account-scoped dedup require separate approval and validation |
| Amp, Warp, Trae, Antigravity desktop cache | not collected | Their tokscale clients read data synced from an online account; out of scope for device-local collection |

These rules describe the collection design, not acceptance of every source as reconciled. Source coverage and intentional deviations remain governed by [ADR-0003](../decisions/0003-usage-engine.md).

## Time, models, and series

- `day` is a `YYYY-MM-DD` label in the collecting device's zone, not a UTC timestamp. Every daily record MUST retain its IANA `timeZoneID`. Explicitly pass that identifier as `TZ` to tokscale subprocesses.
- `UsageDay.string(from:in:)` labels native timestamped events in the collecting zone. `UsageRecord.dayInterval` resolves start and exclusive end in that zone, including DST.
- Day, week, month, year, and all-time boundaries use the viewer's calendar and time zone. Week runs from Monday `00:00` through the end of today regardless of locale `firstWeekday`. Place daily rows on their original calendar-date labels without shifting dates. This is exact only when collection and viewer zones match: each Mac's daily records use that Mac's local calendar day, so a merged day can mix zones. This limitation is documented in `README.md` and `README.zh-CN.md`, and CLI JSON output MUST report the viewer `timeZone`.
- v1 has day, week (Monday start, 7 daily buckets Monday–Sunday with future days marked), month, year, and all-time views.
- Model IDs are trimmed and lowercased without guessing aliases. Retain the raw exported model ID; for tokscale, the pre-engine original ID is not recoverable from the export. Further aliases require versioned mappings and MUST NOT discard the retained raw ID. A collapsed key retains a deterministic representative raw spelling.
- The Day summary's totals, categories, costs, and breakdowns use daily records. Its chart uses actual hourly rows, never a synthetic redistribution of daily totals. The chart may omit reasoning for tokscale sources and differ from the daily total; never rescale it to hide that difference.
- Request hourly output per source, with all of its tokscale clients in one run, since the local date two days ago. On successful refresh, keep the current hour and 47 preceding absolute hourly intervals per device/source. Retain stale cached rows after failure rather than erasing them.
- A complete successful local collection establishes coverage for those 48 hours, including explicit zero rows for hours with no activity. A partial read with skipped records MUST NOT manufacture zero coverage. An unavailable or failed read establishes no new coverage.
- Hourly series use the viewer's local hours and actual DST day length (23/24/25 hours where applicable). A missing hour is unknown: `SeriesPoint.isKnown=false` and absent `bySource` keys denote missing coverage, not confirmed zero; a numeric total of zero in such a point is only a placeholder. Fully known points require coverage for all device/source pairs contributing the day's daily rows.
- tokscale's local hourly labels have no UTC offset; repeated fall-back hours cannot be distinguished reliably. Hourly aggregates cannot be split exactly when viewer-zone boundaries fall inside an original hour, including different fractional UTC offsets. Daily cross-zone labels and hourly absolute-time attribution can therefore disagree beyond the reasoning difference.
- Synthetic previews may derive deterministic hourly fixture rows, but the production aggregator MUST NOT fabricate an activity curve.

## Cost

- Estimated cost is the sum of priced category tokens multiplied by rates in a versioned price table. Use `PriceTable.bundled` for real data and `PriceTable.synthetic` only for synthetic stores. Record the price-table version with each estimate.
- Historical estimates MUST be recomputed when the table updates. The displayed result MUST identify the version actually used.
- An unpriced model or category is `unpriced`, never zero-cost. `uncategorized` always contributes to `unpricedTokens`, even for a model with priced named categories. The estimate covers only the priced portion.
- Rates are the pinned engine's reported prices or a vendor's published first-party tariff. Subscription-inclusive and reseller rates MUST NOT be added.
- Source-reported actual cost is separate, explicitly labelled, and MUST NOT be merged with or presented as the token-derived estimate. tokscale's cost field is not canonical pricing input.
- Cost UI MUST include “estimate, not a bill”.

### Price-table delivery

- The price table ships inside the app bundle. v1 makes no network request for prices; a new table arrives only with a new release ([privacy.md](privacy.md)).
- `engine/price-snapshot-*.json` is the reviewed source of truth and records each matched key, dataset, and unpriced category. The newest file by date name is generated into `TokenTakenKit/PriceSnapshot.swift`.
- `scripts/update-prices.py` performs that generation from the repository root. It uses only the Python 3.9 standard library and never fetches anything.
- A maintainer refreshes the snapshot and regenerates the Swift table before each release. `python3 scripts/update-prices.py --check` exits 1 with a one-line message when the committed file is stale, and `scripts/release.sh` runs it before `xcodegen generate`.
- The bundled version is `<snapshot version>+alias-<aliasTableVersion>`, for example `tokscale-4.21.0-2026-11-10+alias-v3`, so an alias-table change also changes the version recorded with every estimate.

### Alias admission

- A canonical vendor model with a published tariff enters the snapshot as an exact key.
- A spelling variant with an identical tariff may become an alias entry, and that change MUST bump `PriceTable.aliasTableVersion`.
- A distinct tier with its own tariff, a `:free` id, and local or synthetic ids MUST NOT be aliased. They stay unpriced unless the snapshot carries their exact reviewed key.
- Exact match wins over the alias table, so a bundled key is never shadowed by an alias target. A `:free` suffix is never dropped, so a free variant cannot resolve to a paid base model.

## Reconciliation and source health

- Every supported source MUST be reconciled on sanitized samples against the selected engine and native ledger where applicable. Record intentional deviations and evidence; unexplained mismatches block support.
- `SourceHealth` exposes `lastAttempt`, `lastSuccess`, `recordCount` (daily rows), `skippedRecords`, `errorMessage`, and state `ok`, `unavailable`, `notInstalled`, `failed`, or `stale`.
- Missing source locations throw `CollectorError.sourceUnavailable`. Failed or unavailable collectors MUST preserve both cached tables and the previous last-success timestamp. A successful collection replaces the 48-hour hourly snapshot and merges daily history under the retained-history rules below. Skipped records are a partial-data condition even when state is `ok`.
- The default stale threshold is 24 hours since last success. Preserve unavailable/failed states rather than overwriting them with stale. Surface database and health-write errors through collection results; health reads throw rather than masquerading as an empty health list.
- `AppModel.dataIssues` exposes `failed`, `unavailable`, and `stale` source counts, `skippedRecords`, `devices`, `count`, and `isPartial` for presentation. Storage/read errors also make that summary partial.
- Missing intervals MUST NOT be interpolated or silently converted to zero.

### Retained history

Daily history is a floor, not a snapshot ([ADR-0008](../decisions/0008-retained-history.md)). Agents prune, rotate and rewrite their own logs, so a later collection can report less than an earlier one. Counted usage MUST NOT be lost when that happens, and nothing may be counted twice.

- A day total is `input + cacheRead + cacheWrite + output + reasoning + uncategorized` summed over every model row of that `(deviceID, sourceID, day)`.
- A day present in both the batch and the store is replaced only when the batch total is not smaller. A smaller day keeps its stored rows whole, including every model row and `eventCount`. A stored day the batch no longer reports is kept, and a day only the batch reports is inserted. Stored and batch rows are never mixed within one day, so a renamed model cannot leave a stale row behind and no day is counted twice.
- A rebaseline replaces that rule when the source's history epoch changed or the batch's collection time zone differs from a stored row's `timeZoneID` for that device/source. With `E` the earliest day in the batch, days after `E` adopt the batch exactly, including deleting stored days it no longer reports; days up to and including `E` keep the floor rule. The new epoch is stored on success.
- History epochs are a Token Taken constant, not engine state: every source starts at revision `1`, and tokscale-collected sources append the pinned engine version (`1+tokscale-4.21.0`). A release raises a source's revision only when it intentionally lowers or moves already-counted usage, such as a deduplication or date-attribution fix.
- The last applied epoch is stored per `(deviceID, sourceID)` in `history_epochs` (schema version 3). A missing row is the first run after the upgrade: record the current epoch and use the normal merge, so existing rows are protected immediately and are never rebaselined unseen.
- Daily merge and hourly replacement happen in one transaction. Reading, sync publication and aggregation need no change because `daily_usage` remains the resolved view.

## Open questions

- Recovering genuinely total-only legacy Codex data: the pinned engine does not expose it as uncategorized usage; see ADR-0005's source inspection. No recovery counts are assumed.
- Exact privacy-preserving account-scoped cross-device deduplication remains unsupported.
