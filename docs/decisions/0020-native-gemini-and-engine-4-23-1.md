# ADR-0020: Native Gemini CLI collector and tokscale 4.23.1

## Status

Accepted (2026-11-28)

## Context

Two double-counting issues and one change-detection gap remained under the pinned `tokscale` 4.21.0 engine ([ADR-0003](0003-usage-engine.md)):

- **OpenCode `claude-agent` overlap (`#1597`) and change detection:** Earlier `tokscale` versions could double count Claude usage routed through OpenCode's `claude-agent` integration. Upstream `tokscale` `4.23.1` (tag commit `b265e836c58f085f50a836525aa60b8d45bd8d57`) fixes `#1597`. In addition, because OpenCode databases affect Claude deduplication and attribution, Claude's file-metadata fingerprint in `TokscaleCollector` must include OpenCode SQLite databases (and their `-wal`/`-shm` siblings) so changes there trigger a fresh Claude collection rather than reusing stale cached rows.
- **Gemini CLI headless double counting and cache-inclusive input:** Gemini CLI writes session logs under `~/.gemini/tmp` (honouring `GEMINI_CLI_HOME`) and headless `gemini` directories (honouring `TOKSCALE_HEADLESS_DIR`). Headless session files can carry both per-turn message records and aggregate `stats` summaries, causing `tokscale`'s `gemini` parser to count headless sessions twice. Gemini CLI also reports cache-inclusive `input` counts that must exclude `cacheRead` to satisfy the disjoint category invariant in `docs/contracts/statistics.md`, and `tokscale` hourly JSON omits reasoning tokens.

## Decision

- **Upgrade pinned `tokscale` to `4.23.1`:** Pin `@tokscale/cli-darwin-arm64` `4.23.1` (commit `b265e836c58f085f50a836525aa60b8d45bd8d57`) in `engine/engine.lock.json` and `TokscaleCollector.engineVersion`. Keep the existing bundled price snapshot (`tokscale-4.21.0-2026-11-10+alias-v3`) unchanged until a separate price-snapshot review is performed.
- **Fingerprint OpenCode DBs for Claude:** Include OpenCode SQLite databases and `~/.claude/transcripts` in Claude's change-detection fingerprint inside `TokscaleCollector`.
- **Move Gemini CLI to native Swift (`GeminiCollector`):**
  - Collect `gemini` natively in `TokenTakenKit/GeminiCollector.swift`, reading `~/.gemini/tmp` (honouring `GEMINI_CLI_HOME`) and headless `gemini` directories (honouring `TOKSCALE_HEADLESS_DIR`) read-only, independent of whether the `tokscale` binary is installed.
  - Prefer per-turn messages over aggregate `stats` summaries so headless sessions are counted once.
  - Normalize cache-inclusive `input` by subtracting `cacheRead` so `input`, `cacheRead`, `cacheWrite`, `output`, and `reasoning` stay disjoint (`docs/contracts/statistics.md`).
  - Emit daily rows and hourly rows with `reasoningKnown = true`.
  - Remove `"gemini"` from `TokscaleCollector.defaultClients` and `TokscaleCollector.sourceMap` so the engine never collects Gemini CLI alongside `GeminiCollector`.
- **History epochs:** Removing `gemini` from `TokscaleCollector.defaultSourceIDs` changes its epoch from `1+tokscale-4.21.0` to `1`, and updating `TokscaleCollector.engineVersion` moves remaining `tokscale`-collected sources from `1+tokscale-4.21.0` to `1+tokscale-4.23.1`. Each affected source rebaselines days after its earliest reported day on the next collection ([ADR-0008](0008-retained-history.md)).

## Consequences

- Eliminates OpenCode `claude-agent` double counting (`#1597`) and prevents stale Claude caches when OpenCode databases change.
- Eliminates Gemini CLI headless 2× double counting and cache-inclusive input inflation, enables hourly reasoning for Gemini CLI, and removes Gemini CLI's runtime dependency on the `tokscale` subprocess.
- Remaining `tokscale`-collected sources and Gemini CLI rebaseline automatically on the next refresh via `HistoryEpochs` without manual cache resets.
