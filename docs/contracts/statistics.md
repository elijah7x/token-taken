Status: Draft v0 (2026-11-09)

# Statistics contract

## Usage and token categories

- Usage consists of normalized model-usage events from supported sources. Each event retains its source, model, event timestamp, token categories, and deduplication identity.
- `input` is uncached input. It MUST exclude every token counted as `cacheRead` or `cacheWrite`, including when an engine reports an inclusive input total.
- `cacheRead` is tokens read from a provider cache; `cacheWrite` is tokens written to a provider cache. A cached token MUST NOT also be counted as `input`.
- `output` is the source's normalized output count. A per-source `outputIncludesReasoning` flag records whether that count already includes reasoning.
- `reasoning` is kept separate only when the source reports it separately. It MUST NOT be inferred or split out of an opaque output total.
- Total tokens are `input + cacheRead + cacheWrite + output + reasoning` when `outputIncludesReasoning` is false. When it is true, total tokens are `input + cacheRead + cacheWrite + output`; `reasoning` remains a breakdown of output and MUST NOT be added again.
- Missing or unparseable data is unknown, not zero. A source cannot be marked supported until its category and reasoning semantics are known.

## Event identity and deduplication

- The adapter MUST use a stable native message or request ID when available. Otherwise it MUST derive a deterministic hash from documented stable event fields.
- Keys MUST be namespaced by source and the relevant device or account scope. Ingestion time, read order, and other volatile fields MUST NOT affect the key.
- Device-local events are deduplicated only within their device. Account-scoped events are deduplicated across devices before aggregation.
- Source IDs are stable lowercase kebab-case. The final supported-source list and every `TBD` below are **TBD after engine spike (ADR-0003)**.

| Source | Scope class | Dedup key | Reasoning handling | Reports cost? |
| --- | --- | --- | --- | --- |
| Claude Code | TBD | TBD | TBD | TBD |
| Codex | TBD | TBD | TBD | TBD |
| Cursor | TBD | TBD | TBD | TBD |
| Zcode | TBD | TBD | TBD | TBD |
| OpenCode | TBD | TBD | TBD | TBD |
| Kimi Code | TBD | TBD | TBD | TBD |
| Gemini CLI | TBD | TBD | TBD | TBD |
| pi | TBD | TBD | TBD | TBD |
| oh-my-pi | TBD | TBD | TBD | TBD |
| Qoder | TBD | TBD | TBD | TBD |
| Factory Droid | TBD | TBD | TBD | TBD |
| Grok CLI | TBD | TBD | TBD | TBD |

## Time and models

- Event timestamps and stored aggregation buckets MUST use UTC.
- Day, month, and year boundaries use the viewer's current IANA time zone, including daylight-saving transitions. All-time covers all available data without a start boundary.
- v1 has day, month, year, and all-time views; it MUST NOT present a week view.
- Every model record retains both a normalized model ID and the source's raw model ID. Alias mappings MUST come from a versioned alias table; an alias update MUST NOT discard the raw ID.

## Cost

- Estimated cost is the sum of category token counts multiplied by the applicable rates in a versioned price table. Record the price-table source and version with the calculation.
- Historical estimates MUST be recomputed when the price table updates. The displayed result MUST identify the price-table version actually used.
- An unpriced model or category is `unpriced`, never zero-cost. Its token count contributes to `unpricedTokens`, and the estimate covers only the priced portion.
- Source-reported actual cost is a separate, explicitly labelled value. It MUST NOT be merged with, overwritten by, or presented as the token-derived estimate.
- Cost UI MUST include the wording “estimate, not a bill” where estimates are presented.

## Reconciliation and source health

- For every supported source, category and total usage on the same sanitized sample set MUST match the pinned engine selected in [ADR-0003](../decisions/0003-usage-engine.md).
- Every intentional deviation MUST be recorded with its reason and reconciliation evidence; an unexplained mismatch blocks support for that source.
- Expose each source's last read time, errors, and partial-data state. Failed, stale, unavailable, and incomplete reads MUST remain visible to the user.
- Missing intervals MUST NOT be silently filled, interpolated, or converted to zero.

## Open questions

- Per-source identity, scope, reasoning, and native-cost behavior: TBD after engine spike (ADR-0003).
- Price-table provider, update mechanism, and alias-table location: TBD after engine spike (ADR-0003).
