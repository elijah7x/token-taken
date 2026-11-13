# ADR-0009: Native Devin and Antigravity collectors

## Status

Accepted (2026-11-12)

## Context

Devin and Antigravity were added as tokscale clients on 2026-11-11 carrying the engine's accuracy, not a verified one ([ADR-0003](0003-usage-engine.md)). A reconciliation against the pinned engine on one Mac's real data reproduced the export to the token, then found two counting defects a local reader can fix and one reported defect that the data refutes.

### Devin: a turn was dated by its row write time

- `message_nodes.created_at` is the row write time, not the request. It trails `metadata.started_generation_at` by a median of 32 minutes and by up to 2.8 days, and the engine dates a turn as that stamp minus `metadata.metrics.total_time_ms`.
- `metadata.started_generation_at` is the generation start, i.e. the billed call. `metadata.created_at` is stamped mid-generation, and it differs from `started_generation_at` on only 9 of 8,963 kept rows (1,030,801 tokens), so picking the request instant is robust to which of the two is read.
- Re-dating by the request instant moves **2,509 of 8,963 kept rows / 302,121,664 tokens** onto a different local (Asia/Singapore) day. Month totals do not move, but two days that carry real usage read as zero today while one day carries 217.7M tokens that belong to three earlier days. Confidence: high.
- Refuted: `metadata.response_dimensions` "Input tokens" is not missing uncached input. It equals `input_tokens + cache_creation_tokens` in 22,956 of 22,956 rows, and the engine already counts `cache_creation_tokens` as cache write. Adding it would double count 3.8M tokens on the kept rows. The `input_tokens` value of 2–4 that appears only on cache-write turns costs at most 1,136 kept tokens and stays unexplained.

### Antigravity: a fixed preamble token count was billed as input

- The engine adds `usage.#1` to input on every turn, described upstream as a fixed system-prompt block.
- The field is model-determined: 9 distinct values across 93 conversations, one value per conversation in 92 of them. It is duplicated verbatim at `chatModel.#3` in 2,356 of 2,356 rows, which is a property of the prompt template, not of a request.
- The client's own per-step `transcript.jsonl` matches Σ`usage.#2` for input and Σ(`#9` + `#10`) for output exactly in 51 of 57 conversations; adding `#1` to any step breaks the match. The cached prefix is built from `#2` alone.
- Overcount: **3,183,555 input tokens** (6.6% of Antigravity input). The correction lowers the total from 240,701,091 to 237,517,536 with every day, model and category otherwise identical. Confidence: medium-high — four structural arguments, but no local record of a provider invoice exists.
- Kept: `#3 == #9 + #10` in 2,333 of 2,333 rows, so output is `#9`, reasoning is `#10`, and `#3` is never added. Response-id deduplication stays.

## Decision

- Devin and Antigravity are collected by native Swift collectors. Both read the same fields, apply the same deduplication and the same model resolution as the engine; only the fields named here change.
- Devin (`TokenTakenKit/DevinCollector.swift`, source `devin`): CLI rows from `~/.local/share/devin/cli/sessions.db` (honours `XDG_DATA_HOME`) opened read-only and streamed, plus Desktop `acp-events/*.ndjson`. The day label and hourly bucket come from `started_generation_at`, then `metadata.created_at`, then the row's `created_at`; `total_time_ms` is never subtracted. Everything else is the engine's rule: assistant rows only, `(session, request_id)` deduplicated with the lowest `row_id` kept, `num_tokens` as output only when all four counters are zero, `generation_model` before a non-`adaptive` session model, and Desktop usage whose title resolves to a session the CLI already counted dropped.
- Antigravity (source `antigravity`): input is `usage.#2` only. `usage.#1` is read and discarded so the decision is reversible in one line, `#5` is cache read, `#9` output, `#10` reasoning, `#3` never counted, and response-id deduplication is scoped once per collector run across both client trees.
- Both sources keep their token categories, model spellings and event counts, so a reconciled total differs only where this ADR says it does. Costs stay estimates from the same price table; internal Devin model ids with no reviewed price remain unpriced.
- History epochs: Devin is revision `2` and Antigravity revision `2`. Devin moves already-counted usage between days and Antigravity lowers already-counted input, so both must rebaseline recent days instead of keeping the retained-history floor ([ADR-0008](0008-retained-history.md)). Both lose the engine version suffix because they left `TokscaleCollector.defaultSourceIDs`, so an engine upgrade no longer rebaselines them.
- `devin-cli`, `devin-desktop`, `antigravity-cli` and `antigravity-extension` leave `TokscaleCollector.defaultClients` and its source map.

## Consequences

- Devin totals are unchanged (987,284,007 tokens on the reconciled sample) while 302M tokens move to the local day they were requested on. Per-day views and any daily floor now follow the request.
- Antigravity drops 3.18M input tokens, and rows that carried only `#1` disappear rather than reporting a preamble as usage.
- Devin no longer pays for the engine's 1.2 GB re-read on every change: the native collector streams the same rows, and its fingerprint covers the database, its `-wal` sibling and the Desktop event files. The `-shm` file is left out: it is shared-memory index state that changes whenever any process opens the database, not content.
- Residual uncertainty is recorded rather than resolved: whether a provider bills Antigravity's fixed preamble in a way the client never records, and why Devin reports 2–4 uncached input tokens on cache-write turns. Neither can be settled from local data.
- The native Devin path never printed prompt or response text; only the fields above are decoded, and the database is opened read-only, never with `immutable=1`.
