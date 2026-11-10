Status: Draft v1 (2026-11-10)

# Statistics contract

## Usage and token categories

- The canonical query input is aggregate records, not an exported event ledger. Collectors return `CollectionBatch(daily:hourly:skippedRecords:)` under [ADR-0005](../decisions/0005-collection-granularity.md).
- `UsageRecord` stores one collecting-device local calendar day per `(deviceID, sourceID, modelID, day)`, with `timeZoneID`, `rawModelID`, disjoint `counts`, and `eventCount`. Complete daily history is retained.
- `HourlyUsage` stores one absolute hourly instant per `(deviceID, sourceID, hourStart)`, with disjoint counts, `eventCount`, and `reasoningKnown`. Hourly models are merged; hourly data MUST NOT be added to daily data.
- `input` is uncached input. It MUST exclude tokens counted as `cacheRead` or `cacheWrite`, including when an engine reports inclusive input.
- `cacheRead` and `cacheWrite` are tokens read from and written to a provider cache. They MUST NOT also be counted as input.
- `output` excludes separately reported reasoning when the source reports reasoning inside output. `reasoning` is stored separately only when the source reports it; it MUST NOT be inferred from opaque output.
- `uncategorized` is a known total with an unknown category split, not a sixth `TokenCategory`. It defaults to zero in initialization and older Codable data, participates in addition, and is never priced.
- Total tokens are always `input + cacheRead + cacheWrite + output + reasoning + uncategorized` after normalization. An inclusive source count MUST be normalized before storage, not added twice at query time.
- Missing or unparseable data is unknown, not zero. `reasoningKnown=false` distinguishes omitted hourly reasoning from a measured zero.

## Source identity and deduplication

- Source IDs are stable lowercase kebab-case. Factory Droid is `factory`; its tokscale client selector is `droid`.
- Native collectors deduplicate before forming aggregates using stable native IDs or documented deterministic fingerprints. Ingestion time and read order MUST NOT become event identity.
- tokscale performs its own source-specific deduplication before export; its graph and hourly output do not expose per-event dedup keys. Aggregate natural keys identify snapshot rows, not individual calls.
- Device-local sources are attributed to their collecting device and MUST NOT be cross-device deduplicated. Exact account-scoped cross-device deduplication is not supported by these aggregates. Cursor remains deferred and opt-in; do not claim account-scoped accuracy.

| Source | Collector | Reasoning and identity rules |
| --- | --- | --- |
| Claude Code | tokscale `claude` | Engine category and dedup rules; hourly reasoning unavailable |
| Codex | tokscale `codex` | Engine splits reasoning from output and handles fork replay; genuinely total-only legacy records remain a known export gap |
| Grok | tokscale `grok` | Engine category and dedup rules; hourly reasoning unavailable |
| Kimi Code | tokscale `kimi` | Engine category and dedup rules, including usage records; hourly reasoning unavailable |
| OpenCode | tokscale `opencode` | Engine category and dedup rules; hourly reasoning unavailable |
| Gemini CLI | tokscale `gemini` | Engine category and dedup rules; hourly reasoning unavailable |
| Factory Droid | tokscale `droid` | Engine category and dedup rules; hourly reasoning unavailable |
| Zcode | native Swift | Completed native usage plus pre-boundary legacy assistant messages; exact cross-session copies removed; inclusive input/output split |
| pi | native Swift | Entry-ID deduplication, not response-ID-only deduplication; includes operation usage |
| oh-my-pi | native Swift | Entry-ID deduplication; reasoning tokens split from inclusive output |
| Qoder | not token-counted | Credits only; tokens unavailable |
| Cursor | deferred | Account credentials, network access, and exact account-scoped dedup require separate approval and validation |

These rules describe the collection design, not acceptance of every source as reconciled. Source coverage and intentional deviations remain governed by [ADR-0003](../decisions/0003-usage-engine.md).

## Time, models, and series

- `day` is a `YYYY-MM-DD` label in the collecting device's zone, not a UTC timestamp. Every daily record MUST retain its IANA `timeZoneID`. Explicitly pass that identifier as `TZ` to tokscale subprocesses.
- `UsageDay.string(from:in:)` labels native timestamped events in the collecting zone. `UsageRecord.dayInterval` resolves start and exclusive end in that zone, including DST.
- Day, month, year, and all-time boundaries use the viewer's calendar and time zone. Place daily rows on their original calendar-date labels without shifting dates. This is exact only when collection and viewer zones match. Cross-zone aggregates cannot reconstruct exact viewer-local period boundaries; this limitation MUST be disclosed for synced or moved-device data.
- v1 has day, month, year, and all-time views; it MUST NOT present a week view.
- Model IDs are trimmed and lowercased without guessing aliases. Retain the raw exported model ID; for tokscale, the pre-engine original ID is not recoverable from the export. Further aliases require versioned mappings and MUST NOT discard the retained raw ID. A collapsed key retains a deterministic representative raw spelling.
- The Day summary's totals, categories, costs, and breakdowns use daily records. Its chart uses actual hourly rows, never a synthetic redistribution of daily totals. The chart may omit reasoning for tokscale sources and differ from the daily total; never rescale it to hide that difference.
- Request hourly output per tokscale client since the local date two days ago. On successful refresh, keep the current hour and 47 preceding absolute hourly intervals per device/source. Retain stale cached rows after failure rather than erasing them.
- A complete successful local collection establishes coverage for those 48 hours, including explicit zero rows for hours with no activity. A partial read with skipped records MUST NOT manufacture zero coverage. An unavailable or failed read establishes no new coverage.
- Hourly series use the viewer's local hours and actual DST day length (23/24/25 hours where applicable). A missing hour is unknown: `SeriesPoint.isKnown=false` and absent `bySource` keys denote missing coverage, not confirmed zero; a numeric total of zero in such a point is only a placeholder. Fully known points require coverage for all device/source pairs contributing the day's daily rows.
- tokscale's local hourly labels have no UTC offset; repeated fall-back hours cannot be distinguished reliably. Hourly aggregates cannot be split exactly when viewer-zone boundaries fall inside an original hour, including different fractional UTC offsets. Daily cross-zone labels and hourly absolute-time attribution can therefore disagree beyond the reasoning difference.
- Synthetic previews may derive deterministic hourly fixture rows, but the production aggregator MUST NOT fabricate an activity curve.

## Cost

- Estimated cost is the sum of priced category tokens multiplied by rates in a versioned price table. Use `PriceTable.bundled` for real data and `PriceTable.synthetic` only for synthetic stores. Record the price-table version with each estimate.
- Historical estimates MUST be recomputed when the table updates. The displayed result MUST identify the version actually used.
- An unpriced model or category is `unpriced`, never zero-cost. `uncategorized` always contributes to `unpricedTokens`, even for a model with priced named categories. The estimate covers only the priced portion.
- Source-reported actual cost is separate, explicitly labelled, and MUST NOT be merged with or presented as the token-derived estimate. tokscale's cost field is not canonical pricing input.
- Cost UI MUST include “estimate, not a bill”.

## Reconciliation and source health

- Every supported source MUST be reconciled on sanitized samples against the selected engine and native ledger where applicable. Record intentional deviations and evidence; unexplained mismatches block support.
- `SourceHealth` exposes `lastAttempt`, `lastSuccess`, `recordCount` (daily rows), `skippedRecords`, `errorMessage`, and state `ok`, `unavailable`, `failed`, or `stale`.
- Missing source locations throw `CollectorError.sourceUnavailable`. Failed or unavailable collectors MUST preserve both cached tables and the previous last-success timestamp. Only a successful collection replaces snapshots. Skipped records are a partial-data condition even when state is `ok`.
- The default stale threshold is 24 hours since last success. Preserve unavailable/failed states rather than overwriting them with stale. Surface database and health-write errors through collection results; health reads throw rather than masquerading as an empty health list.
- `AppModel.dataIssues` exposes failed/unavailable/stale source counts, skipped records, and `isPartial` for presentation. Storage/read errors also make that summary partial.
- Missing intervals MUST NOT be interpolated or silently converted to zero.

## Open questions

- Recovering genuinely total-only legacy Codex data: the pinned engine does not expose it as uncategorized usage; see ADR-0005's source inspection. No recovery counts are assumed.
- Exact privacy-preserving account-scoped cross-device deduplication remains unsupported.
- Price-table update delivery and versioned alias-table expansion require their own implementation contracts.
