# Changelog

All notable changes to Token Taken will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Retained local long-term hourly usage history (`hourly_history`, schema 7) as the base for weekly, monthly, and yearly recaps: sparse per-source hours with floor semantics, never synced, about 2–3 MB per year for a heavy user; collectors now emit hourly rows for their whole readable history and the first collection after upgrading backfills it once ([ADR-0015](docs/decisions/0015-hourly-history.md)).

## [0.2.0] - 2026-11-20

### Added

- Added a per-model cache detail popover when clicking rows in the Models breakdown list, showing cache hit rate, input split, and estimated cache savings.
- Added `--help` / `-h` usage output (globally and per subcommand) to the `token-taken` CLI, and added CLI installation status and an **Uninstall** action in Settings.
- Bundled third-party notices (`THIRD_PARTY_NOTICES.md`) inside the macOS app and added a button to open them from Settings → About.
- Added the Liquid Glass `Lens` share card graphic (`LensShareGraphic`): when **View** is set to `Lens`, share cards render a pure-`Canvas` stacked time-bar chart with a hand-drawn glass lens capsule frozen on the peak bucket, a single peak-value pill above the lens, `Peak · {time}` in the card header, portrait (`2:3`), square (`1:1`), and landscape (`3:2`) layouts, and a Tide vessel fallback for single-model day cards where hourly buckets have no model breakdown.
- Added a **View** setting (`Confluence` or `Lens`) under the Liquid Glass theme with schematic thumbnail cards, an interactive `Lens` stacked time-bar chart and three-column glass readout card for single-bucket and contiguous-range slicing, and the theme's app icon logo on share card headers.
- 为 Liquid Glass 主题新增「视图」设置（「汇流」与「透镜」缩略图切换，默认「汇流」），提供支持单桶与区间切片探查的「透镜」时间条与三栏玻璃读数卡，并将所有主题分享卡页头的品牌小图标替换为对应主题的产品 App 图标。
- Added automatic background update checks and silent installation (`UpdateFeed`, `AppVersion`, `UpdateFeedSelection`, `UpdateChecker`, `AppUpdater`): checks the static `updates.json` feed with GitHub Releases API fallback 15 seconds after launch, every 6 hours, and on activation when stale while **Keep Token Taken up to date automatically** is enabled; verifies size, SHA-256, Developer ID team signature, version/build, and Gatekeeper assessment; installs in place after 10 minutes of idle (relaunching in the background) or on quit; shows a one-time menu bar notice after updating; and adds `scripts/make-update-feed.py` to `scripts/release.sh` ([ADR-0013](docs/decisions/0013-automatic-updates.md)).
- Added report coverage on iPhone showing which Macs the published report includes and noting that the iPhone and Macs must share the same Apple ID.
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
- Added "Sync to iPhone" (off by default): the Mac app publishes a precomputed, usage-only report (`token-taken.mobile-report` v1, no cost) to the shared iCloud Documents container `iCloud.io.github.elijah7x.TokenTaken` after each refresh and at least hourly, per the accepted mobile report contract and ADR-0011. Release builds embed a Developer ID provisioning profile for the container; Debug builds stay credential-free and cannot publish.
- Added the display-only iOS companion app in `ios/` (iOS 26), which reads the report, ranks the last 30 days against a fixed estimate table, and shares a liquid glass card with a sourced token comparison; the report model lives in `Shared/` and compiles into both apps.

### Changed

- Updated `token-taken` CLI cost rounding to match the macOS app, and prevented the CLI from creating data directories or database files before the app's first launch.
- Restricted Cursor account usage export to HTTPS-only redirects on `cursor.com` / `www.cursor.com`, and migrated legacy device-local Cursor rows to the account device so historical totals remain intact without double counting.
- Tightened macOS update feed and package checks (HTTPS-only feed and download hosts, version/build validation, Developer ID team signature, and Gatekeeper assessment).
- Refreshed `Today` automatically when crossing midnight so day rollovers update without waiting for the next scheduled collection.
- Replaced the legacy double-T menu bar template glyph (`MenuBarGlyph`) with a solid coin and cut-out T glyph matching the coin app icon.
- 将菜单栏默认模板图标（`MenuBarGlyph`）由早期“双 T”字形替换为与主图标一致的实心圆币镂空 T 图形。
- Replaced the iOS discrete rank-band table with the shared `UsageRank` log-log interpolation curve (`rank-curve-2026-11`) over last-30-day tokens across all harnesses, adding extrapolated anchors below 350M down to 100k (top 99%), unified `top X%` formatting, and updated estimate footnote wording.
- Renamed user-facing "Source" / "Sources" (`来源`) UI labels to "Harness" / "Harnesses" (`工具`) while preserving `source` identifiers in the data model, CLI, and report schemas.
- Updated the [privacy contract](docs/contracts/privacy.md) to allow automatic update checks and verified DMG downloads from allowlisted `https` hosts with only standard request headers and `User-Agent: TokenTaken/<version>`, and amended [ADR-0004](docs/decisions/0004-distribution.md) via [ADR-0013](docs/decisions/0013-automatic-updates.md).
- Remote Macs with partial data now show "Partial" instead of "Unavailable", and issue counts in the status note and sidebar banner are split by state (`unavailable`, `partial`, `stale`), falling back to an `incomplete` count when states are mixed.
- Sync settings now explain that all Macs and the iPhone must share the same Apple ID, and switching Apple ID clears cached remote Mac data and re-reads from the new account.
- Token Taken now runs on Apple silicon Macs only: the app, `TokenTakenKit`, `token-taken`, and the bundled `tokscale` engine are built and checked as arm64 alone (ADR-0012), which makes the download smaller.
- Date Devin turns by the request stamp (`metadata.started_generation_at`) instead of the row write time, and count Antigravity input as new input only: 302M Devin tokens move to the local day they were requested on, and Antigravity no longer bills its fixed per-model preamble (3.18M tokens). Both history epochs are now `2`, so recent days rebaseline (ADR-0009).
- Devin is no longer requested from the pinned `tokscale` engine (`devin-cli` and `devin-desktop` leave its client list); Antigravity also leaves it now that its native collector counts it.
- Keep counted daily usage when an agent prunes or rotates its own logs: a collection now replaces a day only when its total is not smaller, keeps stored days the batch no longer reports, and rebaselines days after the earliest reported day when a source's history epoch or the collection time zone changes (`history_epochs`, schema version 3).
- Ship the price table inside the app: the bundled version is now `<snapshot>+alias-<n>` (currently `tokscale-4.21.0-2026-11-10+alias-v3`), so alias-table changes also change the version recorded with every cost estimate.
- Price Claude Sonnet 4.5 from Anthropic's first-party tariff ($3.00/$15.00 per 1M, $0.30 cache read, $3.75 cache write) instead of the reseller row tokscale matched, and keep `claude-4-5-sonnet` as an alias with the same tariff.
- Keep a `:free` model suffix out of alias lookup: a free variant stays unpriced unless the snapshot carries an exact reviewed key for it.
- Streamed `pi` and `oh-my-pi` session JSONL scanning with minimal decoding and bounded retention to reduce collector peak memory use.
- Split Confluence into static and Core Animation particle layers, hid particles while ribbons spring to new data, and paused hero animation when the window is inactive to keep idle app CPU near zero.
- Release builds strip their binaries and the DMG is now LZMA-compressed, so the download is smaller; the matching dSYMs are kept beside the package.
- Much lower idle CPU with the main window open: animations pause while the window is covered or in the background.
- Switching between Sources and Models settles noticeably faster.
- Launching skips a fresh collection when the last one is under 15 minutes old, so the first numbers appear sooner.

### Fixed

- Grok is now collected natively from session update logs and no longer double counts an inference that appears in both Grok Build logs ([ADR-0014](docs/decisions/0014-native-grok.md)).
- Preserved historical daily usage across system time-zone changes instead of shrinking stored days (schema v6 collection-zone tracking).
- Cancelled refreshes no longer mark sources as failed, and missing or invalid collection-engine status is now surfaced in the UI.
- Improved Cosmos menu bar readability on light macOS menu bars.
- Included uncategorized tokens (such as DeepSeek CLI) in dashboard charts and share cards, stopped displaying unpriced tokens as `$0` on share cards, and surfaced share export errors instead of failing silently.
- Fixed iPhone companion dates west of UTC, sped up iCloud report loading with local caching and faster discovery, and clarified downloading, unsupported-version, and error states.
- Fresh installs now recover synced Macs within seconds instead of after a relaunch.
- A refresh can no longer hang forever when the `tokscale` engine stops responding.
