# ADR-0014: Native Grok collector

## Status

Accepted (2026-11-20)

## Context

Grok was collected through the pinned `tokscale` 4.21.0 engine ([ADR-0003](0003-usage-engine.md)). On 2026-11-19, `tokscale` 4.21.0 counted one Grok Build inference twice.

- Grok Build writes per-session `updates.jsonl` transcripts (alongside `summary.json`, `events.jsonl`, and `signals.json`) under `~/.grok/sessions` and also writes an aggregate event stream at `~/.grok/logs/unified.jsonl`.
- In `tokscale` 4.21.0, `prefer_unified_log_messages` attempts to deduplicate `unified.jsonl` records against legacy session `updates.jsonl` rows by exact `(session_id, timestamp, total_tokens)` or multi-call aggregate match. When a single-call turn (`message_count == 1`) emitted `shell.turn.inference_done` in `unified.jsonl` with a timestamp differing by 398 ms from the matching `turn_completed` record in `updates.jsonl`, the deduplication check failed to match them and kept both records.
- Across all 26 other Grok days verified in reconciliation, reading only the session `updates.jsonl` tree (and sibling session metadata/signals) matched the engine's totals exactly.

## Decision

- Grok (`TokenTakenKit/GrokCollector.swift`, source `grok`) is collected natively in Swift, independent of whether the `tokscale` binary is installed.
- `GrokCollector` reads `$GROK_HOME/sessions/**/updates.jsonl` (default `~/.grok/sessions`) read-only and deliberately ignores `$GROK_HOME/logs/unified.jsonl`. Missing `$GROK_HOME` / `~/.grok` throws `CollectorError.sourceUnavailable`.
- Counting reproduces the verified independent ledger rules:
  - **Categories and normalization:** reads `turn_completed` `params.update.usage` counters (`inputTokens`, `cachedReadTokens`, `cachedWriteTokens`, `outputTokens`, `reasoningTokens`, and their snake-case/provider aliases). When `totalTokens` is absent or equals `raw_in + raw_out`, `cachedReadTokens` is subtracted from `input` and `reasoningTokens` is subtracted from `output` so categories remain disjoint (`docs/contracts/statistics.md`).
  - **Event counts and retransmission dedup:** reads `modelCalls` / `model_calls` / `modelCallCount` (or sums per-model `modelUsage` call counts, defaulting to `1`). Within a session file, `turn_completed` rows sharing a `promptId` / `prompt_id` are deduplicated, keeping the row with the largest total tokens.
  - **Fallback and compaction reconciliation:** tracks `user_message_chunk` turns and cumulative `totalTokens` deltas as fallback `input` rows (only keeping turns newer than the latest `turn_completed` usage row, or when no `turn_completed` rows exist). When no `turn_completed` usage rows exist in a session, `signals.json` compaction totals (`totalTokensBeforeCompaction`, `totalTokens`, `contextTokensUsed`) reconcile any uncovered remainder.
  - **Model and time resolution:** resolves models from per-update metadata, then single-entry `usage.modelUsage` (for `turn_completed`), `summary.json`, `events.jsonl` (first 500 lines), `signals.json`, and finally `grok-unknown`; resolves timestamps from `agentTimestampMs` / `timestamp` / `ts`, then `summary.json` / `events.jsonl`, then `updates.jsonl` mtime. Emits daily rows per `(local day, model)` and 48-hour hourly rows with `reasoningKnown = true`.
- `"grok"` is removed from `TokscaleCollector.defaultClients` and `TokscaleCollector.sourceMap`. Because `HistoryEpochs.epoch(for:)` drops the `+tokscale-<engineVersion>` suffix whenever a source leaves `TokscaleCollector.defaultSourceIDs`, Grok's stored epoch changes automatically from `1+tokscale-4.21.0` to `1` without bumping `HistoryEpochs.revisions`.

## Consequences

- Eliminates the `unified.jsonl` versus `updates.jsonl` double count and removes Grok's dependency on the external `tokscale` binary.
- Data recorded only in `logs/unified.jsonl`, such as subagent breakdowns absent from session `updates.jsonl` files, is not counted.
- Stored Grok daily history rebaselines automatically on the next collection after the earliest reported day via the `HistoryEpochs` suffix change ([ADR-0008](0008-retained-history.md)).
