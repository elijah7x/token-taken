# Changelog

All notable changes to Token Taken will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Added opt-in Cursor account collection: a native collector reads Cursor's own sign-in on this Mac, downloads the account's usage export once per refresh, and writes it to an `account` device so several signed-in Macs count the account once (ADR-0010). Device kinds (`mac`, `account`) follow into the store, the synced-device views, the summary breakdowns, and `token-taken devices` (`kind`, with `local` never true for an account).

- Initialized the project specification, architecture, decision records, and contracts.
- Added a Developer ID release pipeline with hardened-runtime signing, DMG packaging, and notarization; v0.1 updates are manual.
- Added the app icon (a staggered stack of blue glass coins on a pale plate, with dedicated 16 and 32 pt renders) and a matching menu bar template glyph.
- Added usage collectors combining the pinned `tokscale` 4.21.0 subprocess (`claude`, `codex`, `grok`, `kimi`, `opencode`, `gemini`, `droid`) with native Swift collectors for Zcode (online SQLite backup, native `model_usage`, and pre-boundary legacy assistant messages), `pi`, and `oh-my-pi` (entry-ID deduplication, reasoning split from output, and operation records).
- Added the local SQLite usage store at schema version 2 with `daily_usage` and `hourly_usage` tables, transactional per-source snapshot replacement, and source health tracking (`ok`, `notInstalled`, `unavailable`, `failed`, `stale`, and skipped-record counts).
- Added `TokenTakenKit` statistics and read-time cost estimation across disjoint token categories (`input`, `cacheRead`, `cacheWrite`, `output`, `reasoning`) plus unpriced `uncategorized` totals, using bundled price table `tokscale-4.21.0-2026-11-10+alias-v3` and model alias table `v3`.
- Added opt-in iCloud Drive sync (`v1` snapshot layout) with single-writer per-device folders, SHA-256-verified `device.json` manifests, monthly local-day usage files, rolling 48-hour hourly activity files, tombstones, and `MergedUsageStore` multi-device aggregation.
- Added the `token-taken` CLI (`summary`, `sources`, `models`, `devices`, `export`) with `--period day|week|month|year|all`, custom date ranges, viewer time zone selection, source/model/device filters, `--local-only`, `--synthetic`, schema-versioned JSON output (`schemaVersion: 1`), and RFC 4180 CSV export.
- Added the native Liquid Glass macOS app with the Confluence hero, Condensation activity view, Monday-start week period, menu bar extra, in-window Settings (sources, synced Macs, appearance, launch at login, and CLI symlink installation), and English and Simplified Chinese localization via a String Catalog.
- Added manual-first refresh with launch collection and a fixed 4-hour sleep-tolerant fallback timer.
- Added `scripts/update-prices.py`, which regenerates `TokenTakenKit/PriceSnapshot.swift` offline from the newest `engine/price-snapshot-*.json` (stdlib only, runs on the macOS system Python 3.9). `--check` reports drift, and `scripts/release.sh` now fails a release when the generated table is stale.

- Added the Field theme (theme ID `sketchbook`): a hand-drawn farm where each source or model is a plot whose area and plant count follow tokens, with ten crops, seasonal scenery, day and night skies, serif type, paper surfaces in place of Liquid Glass, a Field share card, and a 田 Dock icon.
- Added a Follow System, Light, or Dark setting that applies to every window and the menu bar extra, including sessions that only open the menu bar extra.
- Field: a turning water wheel, drifting chimney smoke, and night fireflies (still under Reduce Motion), today's field in the menu bar extra, crop flags on plots too small for a sign, fixed crops per source across views, and an inscription and signature on the share card.
- Added the Cosmos theme (宇宙, theme ID `cosmos`): a Metal ray-marched black hole with a five-category accretion disk, orbiting sources or models, and dust; opaque dark surfaces, a compact menu-bar scene, a share card with the usual scope, aspect, cost and composition options, and a still frame under Reduce Motion. Cosmos forces dark appearance while selected without overwriting the saved appearance preference.
- Added native Swift collectors for Devin (request-level metrics in `~/.local/share/devin/cli/sessions.db` plus Desktop ACP events), Antigravity (per-conversation databases under `~/.gemini`), MiniMax Code (`message.usage` in `~/.minimax/v2/sessions`, deduplicated by `message_id`), and DeepSeek CLI (session-level totals only, stored as unpriced `uncategorized` tokens). Settings lists their data locations and the source catalogue carries `mcode` and `deepseek-cli`.

### Changed

- Date Devin turns by the request stamp (`metadata.started_generation_at`) instead of the row write time, and count Antigravity input as new input only: 302M Devin tokens move to the local day they were requested on, and Antigravity no longer bills its fixed per-model preamble (3.18M tokens). Both history epochs are now `2`, so recent days rebaseline (ADR-0009).
- Devin is no longer requested from the pinned `tokscale` engine (`devin-cli` and `devin-desktop` leave its client list); Antigravity also leaves it now that its native collector counts it.
- Keep counted daily usage when an agent prunes or rotates its own logs: a collection now replaces a day only when its total is not smaller, keeps stored days the batch no longer reports, and rebaselines days after the earliest reported day when a source's history epoch or the collection time zone changes (`history_epochs`, schema version 3).
- Ship the price table inside the app: the bundled version is now `<snapshot>+alias-<n>` (currently `tokscale-4.21.0-2026-11-10+alias-v3`), so alias-table changes also change the version recorded with every cost estimate.
- Price Claude Sonnet 4.5 from Anthropic's first-party tariff ($3.00/$15.00 per 1M, $0.30 cache read, $3.75 cache write) instead of the reseller row tokscale matched, and keep `claude-4-5-sonnet` as an alias with the same tariff.
- Keep a `:free` model suffix out of alias lookup: a free variant stays unpriced unless the snapshot carries an exact reviewed key for it.
- Streamed `pi` and `oh-my-pi` session JSONL scanning with minimal decoding and bounded retention to reduce collector peak memory use.
- Split Confluence into static and Core Animation particle layers, hid particles while ribbons spring to new data, and paused hero animation when the window is inactive to keep idle app CPU near zero.
