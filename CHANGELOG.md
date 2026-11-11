# Changelog

All notable changes to Token Taken will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initialized the project specification, architecture, decision records, and contracts.
- Added a Developer ID release pipeline with hardened-runtime signing, DMG packaging, and notarization; v0.1 updates are manual.
- Added the app icon (paired measuring-cup TT on a glass plate, with dedicated 16 and 32 pt renders) and a matching menu bar template glyph.
- Added usage collectors combining the pinned `tokscale` 4.21.0 subprocess (`claude`, `codex`, `grok`, `kimi`, `opencode`, `gemini`, `droid`) with native Swift collectors for Zcode (online SQLite backup, native `model_usage`, and pre-boundary legacy assistant messages), `pi`, and `oh-my-pi` (entry-ID deduplication, reasoning split from output, and operation records).
- Added the local SQLite usage store at schema version 2 with `daily_usage` and `hourly_usage` tables, transactional per-source snapshot replacement, and source health tracking (`ok`, `notInstalled`, `unavailable`, `failed`, `stale`, and skipped-record counts).
- Added `TokenTakenKit` statistics and read-time cost estimation across disjoint token categories (`input`, `cacheRead`, `cacheWrite`, `output`, `reasoning`) plus unpriced `uncategorized` totals, using bundled price table `tokscale-4.21.0-2026-11-10+alias-v3` and model alias table `v3`.
- Added opt-in iCloud Drive sync (`v1` snapshot layout) with single-writer per-device folders, SHA-256-verified `device.json` manifests, monthly local-day usage files, rolling 48-hour hourly activity files, tombstones, and `MergedUsageStore` multi-device aggregation.
- Added the `token-taken` CLI (`summary`, `sources`, `models`, `devices`, `export`) with `--period day|week|month|year|all`, custom date ranges, viewer time zone selection, source/model/device filters, `--local-only`, `--synthetic`, schema-versioned JSON output (`schemaVersion: 1`), and RFC 4180 CSV export.
- Added the native Liquid Glass macOS app with the Confluence hero, Condensation activity view, Monday-start week period, menu bar extra, in-window Settings (sources, synced Macs, appearance, launch at login, and CLI symlink installation), and English and Simplified Chinese localization via a String Catalog.
- Added manual-first refresh with launch collection and a fixed 4-hour sleep-tolerant fallback timer.
- Added `scripts/update-prices.py`, which regenerates `TokenTakenKit/PriceSnapshot.swift` offline from the newest `engine/price-snapshot-*.json` (stdlib only, runs on the macOS system Python 3.9). `--check` reports drift, and `scripts/release.sh` now fails a release when the generated table is stale.

### Changed

- Ship the price table inside the app: the bundled version is now `<snapshot>+alias-<n>` (currently `tokscale-4.21.0-2026-11-10+alias-v3`), so alias-table changes also change the version recorded with every cost estimate.
- Price Claude Sonnet 4.5 from Anthropic's first-party tariff ($3.00/$15.00 per 1M, $0.30 cache read, $3.75 cache write) instead of the reseller row tokscale matched, and keep `claude-4-5-sonnet` as an alias with the same tariff.
- Keep a `:free` model suffix out of alias lookup: a free variant stays unpriced unless the snapshot carries an exact reviewed key for it.
- Streamed `pi` and `oh-my-pi` session JSONL scanning with minimal decoding and bounded retention to reduce collector peak memory use.
- Split Confluence into static and Core Animation particle layers, hid particles while ribbons spring to new data, and paused hero animation when the window is inactive to keep idle app CPU near zero.
