# ADR-0003: Usage engine

## Status

Accepted (2026-11-10)

Status note: [ADR-0005](0005-collection-granularity.md) supersedes UTC day bucketing, the split `pi` collector, and CLI recovery of legacy total-only Codex rows: daily records use the collecting device's local time zone, the native `pi` collector handles all `pi` usage, and genuinely total-only legacy Codex rows remain an unrecovered export gap (`uncategorized` in the model).

## Date

2026-11-09

## Context

- Token Taken needs collectors, parsers, and pricing for Claude Code, Codex, Cursor, Zcode, OpenCode, Kimi Code, Gemini CLI, pi, oh-my-pi, Qoder, Factory Droid, and Grok CLI. Final coverage depends on this decision.
- The owner wants to reuse mature open-source implementations, pin the selected engine version, and keep a thin adapter.
- The owner's brief credits TokenTracker with good handling of old Zcode data and Cursor multi-device deduplication, and suggests that tokscale covers more channels. Neither claim has been verified against the same local samples.
- Sync requires timestamps at one-hour resolution or finer. Exact account-scoped deduplication also needs stable source identity.
- Token Monitor remains a reference for synchronization and history, not proof that a candidate engine supplies those capabilities.

## Decision

Use a combined engine: pinned official tokscale as the base, with source rules ported from TokenTracker where tokscale is wrong on real data. Both are MIT.

- **Base:** official tokscale, one pinned native binary per architecture, run as a subprocess with `--offline` and an isolated `TOKSCALE_CONFIG_DIR` inside the app's Application Support folder. Day buckets pinned to UTC. Used for Claude Code, Codex (category split and fork-replay dedup), Grok, Kimi Code, OpenCode, Gemini CLI, Factory Droid, and pi operation records (compaction, branch summary, tool results).
- **Ported rules (Swift, in the adapter):**
  - Zcode: native `model_usage` from the first completed native request, legacy assistant `message` tokens before that boundary, exact cross-session copies removed, inclusive input/output split into disjoint categories.
  - pi assistant usage: dedup by entry id, never by `responseId` alone (short provider ids collide).
  - oh-my-pi: read `reasoningTokens` as a breakdown inside output.
  - Codex legacy total-only records: keep as "total known, categories unknown".
- **Not counted as tokens:** Qoder records carry credits only; show activity, mark tokens unavailable.
- **Cursor:** deferred; needs account credentials and network, so it is opt-in and not part of v1 collection until separately approved. Superseded 2026-11-12: [ADR-0010](0010-cursor-account-usage.md) accepts an opt-in native Cursor collector.
- **Gap to close upstream or in the adapter:** tokscale has no per-event export. The adapter needs UTC-timestamped records with dedup keys for sync; first choice is an upstream `events --json` contribution, fallback a recorded local patch.

The spike requirements below remain the acceptance bar for each source before it is marked supported.

## Spike requirements

The spike must:

- Keep raw usage samples in the artifact root under `private-artifacts/samples/`; commit only synthetic or sanitized fixtures and public-safe results.
- Establish a manually vetted expected event ledger, including Cursor usage seen from multiple Macs and old Zcode data.
- Reconcile `input`, `cacheRead`, `cacheWrite`, `output`, `reasoning`, and event counts by source, model, timestamp, and device.
- Account for every fixture event as counted, deduplicated, or rejected with a reason.
- Record agent coverage, timestamp granularity, incremental-refresh support, source identity, price-table behavior, bundle size, runtime dependencies, and upgrade constraints.
- Verify license notices at the exact candidate revision under `docs/contracts/upstream.md` and `THIRD_PARTY_NOTICES.md`.

Selection criteria:

- Coverage of the target agents.
- Reconciliation accuracy, especially Cursor multi-Mac deduplication and old Zcode data.
- Event-level or hourly timestamp granularity.
- Stable source identity for account-scoped cross-device deduplication.
- Bundle size and runtime dependencies.
- Upgrade cost and the stability of output contracts.
- License compatibility and asset notices.

## Static study (2026-11-09)

Code reading only; nothing was built or run. Candidates read at official tokscale `82613d2f`, Javis603/tokscale `d3df620b`, TokenTracker `0397a2cd`, and Token Monitor `2e551134`. These findings narrow the spike; they do not verify accuracy.

- **tokscale (official):** parsers for every target agent except Qoder. Cursor is read only from an account-API cache that needs Cursor credentials. Ships as one native binary per architecture with no Node runtime. JSON output is aggregate only (per model, month, hour, or day); there is no per-event export. Hourly JSON omits `reasoning`. Day and hour buckets use a pinned local time zone, and no UTC event timestamps are exposed. Pricing comes from LiteLLM, OpenRouter, and models.dev with an `--offline` mode; caches are written under the user's tokscale config directory.
- **Javis603/tokscale:** 19 patches not upstreamed. The only target-relevant addition is a Qoder CN parser, which does not cover the global Qoder layout. Not recommended as the base.
- **TokenTracker:** collectors for all twelve target agents, including current Qoder. Stores 30-minute UTC buckets. Stitches legacy and native Zcode history. Reads Cursor from the account CSV export and deduplicates across devices by keeping one whole row per (source, bucket, model). Needs Node 20+; collectors are monolithic and not a standalone module. Telemetry is on by default and must be disabled. React Bits assets are MIT + Commons Clause.
- **Token Monitor sync:** reference only for its atomic write sequence (temp file, fsync, rename, directory fsync). Its hostname-based device IDs, whole-device snapshots, local-day keys, and tombstones that a later revision can override conflict with ADR-0002.

## Local reconciliation, round 1 (2026-11-09)

Both engines ran offline on one Mac's real data (Cursor excluded). Raw samples and evidence stay outside the repository.

- Claude Code, Codex, Grok, Kimi Code, oh-my-pi, and OpenCode totals agree within 0.02%. Kimi Code: one call with only a `usage.record` and no `step.end` is counted by tokscale and missed by TokenTracker.
- Zcode: TokenTracker matched an independent SQL rebuild on all 67 days. tokscale reads only the native `model_usage` table and misses all legacy history (about 88% of this sample). The correct rule: native `model_usage` from the first completed native request; legacy assistant `message` tokens before that boundary; exact cross-session copies removed; inclusive input/output split into the five disjoint categories.
- Category semantics differ even when totals match: for Codex, TokenTracker keeps reasoning inside output while tokscale splits it out. The adapter must normalize to `docs/contracts/statistics.md`.
- pi differs by 1.6%: tokscale deduplicates by `responseId`, and short Ollama ids collide across different calls, so it undercounts assistant usage; TokenTracker's entry-id dedup matches the raw records. tokscale additionally counts operation records (about 4.6M) that TokenTracker ignores.
- oh-my-pi: raw `reasoningTokens` (2.6M) sit inside output; tokscale reports 0 reasoning. Claude's one-day gap was a 90-second snapshot difference. Qoder records contain credits but zero tokens.
- Cold full scan: tokscale 12.5 s and 700 MB peak RSS; TokenTracker 23 s and 1.6 GB. Warm runs: 0.7 s and 100 MB, versus 0.9 s and 320 MB.

Leading hypothesis before round 1 (superseded by the Decision): option A with a small, recorded tokscale patch or adapter step that exposes UTC-timestamped events with dedup keys, plus Zcode and Cursor semantics ported from TokenTracker. Option B remains the comparison baseline for numbers.

## Added tokscale clients (2026-11-11)

The pinned engine (4.21.0, `b26c433d`) already parses these device-local clients; the adapter now requests them. No reconciliation round has been run for them, so they carry the engine's accuracy, not a verified one.

- Devin: `devin-cli` (request-level metrics in `~/.local/share/devin/cli/sessions.db`) and `devin-desktop` (`~/Library/Application Support/Devin/User/acp-events`), one source `devin`. Devin's own models (`swe-2`, `swe-2-high`, `compactor`) have no entry in the price table and stay unpriced, never zero-cost.
- Antigravity: `antigravity-cli` and `antigravity-extension` (per-conversation SQLite databases under `~/.gemini`), one source `antigravity`. The engine deduplicates the family by provider response ID only across clients requested in the same run, so the adapter always requests both together.
- DeepSeek Harness (`dsh`, `~/.dsh/sessions`) and fx (`fx`, `~/.fx/sessions`).
- Kimi Code's `~/.kimi-code/sessions` (engine client `kimi`) now participates in availability and change detection.
- Not added: clients that read data synced from an online account (Cursor, Amp, Warp, Trae, and the Antigravity desktop cache under the tokscale config directory).
- Devin's database can exceed 1 GB. Change detection uses file metadata only; when it changes, the engine re-reads it, which raises that refresh's cost.

## Native Devin and Antigravity (2026-11-12)

Devin and Antigravity move off the engine to native Swift collectors; [ADR-0009](0009-native-devin-antigravity.md) records the evidence and the rules this section keeps. The engine no longer requests `devin-cli` or `devin-desktop`, and Devin's history epoch is raised. `antigravity-cli` and `antigravity-extension` stay in the engine's client list until the native Antigravity collector replaces them; both collectors report the same source id, so they must never run in the same release. Nothing else above changes: native collectors still deduplicate before aggregating, still report through `SourceHealth`, and are still bounded by the reconciliation bar in this ADR.

## Cursor account usage (2026-11-12)

Cursor is no longer deferred. [ADR-0010](0010-cursor-account-usage.md) accepts a native, opt-in Swift collector that reads Cursor's own sign-in on this Mac, downloads the account's usage export once per collection, and writes it to an account device so two Macs on one account count it once. The engine still never requests Cursor, so the source is never collected twice. The rest of this ADR stands: the engine's client list, its pinned version, and the reconciliation bar in `docs/contracts/statistics.md`.

## Consequences

- Engine-dependent agent coverage, packaging, refresh behavior, and sync timestamp support remain open.
- The selected engine will be pinned and isolated behind the Collector adapter. Upgrades require contract checks and reconciliation against representative samples.
- The spike must show whether aggregate-only sync can retain the identity needed for exact account-scoped deduplication. `docs/contracts/sync.md` and `docs/contracts/statistics.md` must record the result.
- A candidate that cannot reconcile required samples must not be described as accurate for those sources. Any coverage exclusion must be explicit in the v1 scope.
- Runtime and bundle-size targets cannot be assessed until the candidate and packaging method are known.

## Alternatives

### A: Pinned tokscale CLI subprocess and adapter

Run a pinned tokscale CLI binary as a subprocess and adapt its JSON output. The spike must identify the exact upstream repository and version or commit, distinguish official output from fork patches, and verify channel coverage, timestamps, identity, and pricing fields. Do not assume that an npm package provides a directly importable library API.

### B: TokenTracker Node collectors

Integrate the Node collector code behind the same adapter. The spike must measure the extraction and runtime cost, verify the local API boundary, and test old Zcode and Cursor multi-device claims. Review the pinned files and assets separately; React Bits assets have a separate license and must not be copied.

### C: Swift-native parsers

Implement parsers directly in Swift behind the same model. This removes a subprocess or Node runtime but creates the largest parser-maintenance burden and forfeits some reuse benefits. Choose it only if the spike demonstrates that the reuse candidates cannot meet the coverage or reconciliation requirements, and record the new maintenance scope before accepting this ADR.
