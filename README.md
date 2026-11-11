**English** · [简体中文](README.zh-CN.md)

# Token Taken

A small, beautiful token-usage dashboard for macOS with native Liquid Glass.

**Status: Pre-alpha (v0.1.0 in development).**

## v1 features

- Day, week (Monday start), month, year, and all-time totals, with per-model and per-source breakdowns.
- One combined total across several Macs, with per-device breakdowns when iCloud Drive sync is on. Each Mac's daily records use that Mac's local calendar day, so a merged day can mix time zones.
- A minimal menu bar extra showing today's token total and a quick glance.
- A native Liquid Glass theme, with a theme system designed for later Geek and Sketchbook themes.
- A `token-taken` CLI with JSON output and JSON/CSV data export.
- English and Simplified Chinese app interfaces through a String Catalog.
- Cost estimates from a versioned price table (`tokscale-4.21.0-2026-11-10+alias-v3`). Estimates are not bills.

Supported device-local sources in v1: Claude Code, Codex, Zcode, oh-my-pi, pi, Kimi Code, Grok, OpenCode, Gemini CLI, and Factory Droid. Cursor and Qoder are deferred; see [ADR-0003](docs/decisions/0003-usage-engine.md) and [ADR-0005](docs/decisions/0005-collection-granularity.md).

## Privacy

The v1 design is local-first:

- Token Taken reads supported agent logs read-only.
- iCloud Drive sync is opt-in and off by default.
- Sync contains aggregate usage metadata only. It excludes prompts, responses, file paths, project names, credentials, and cost.
- Token Taken has no telemetry.

See the [privacy contract](docs/contracts/privacy.md) and [sync contract](docs/contracts/sync.md).

## Requirements

- macOS 26.0 or later

## CLI

`token-taken` queries the same local store and optional iCloud Drive device snapshots as the app:

```sh
token-taken summary --period week
token-taken models --period month --json
token-taken export --format csv --period all
```

The [CLI contract](docs/contracts/cli.md) defines the output schema, filters, warnings, and exit codes.

## Documentation

- [Product specification](docs/product.md)
- [Architecture](docs/architecture.md)
- Decisions: [native macOS app](docs/decisions/0001-native-macos-app.md), [iCloud Drive sync](docs/decisions/0002-icloud-drive-sync.md), [usage engine](docs/decisions/0003-usage-engine.md), [Developer ID distribution](docs/decisions/0004-distribution.md), [collection granularity](docs/decisions/0005-collection-granularity.md), [incremental collection](docs/decisions/0006-incremental-collection.md)
- [Contracts index](docs/contracts/README.md)
- Contract details: [statistics](docs/contracts/statistics.md), [CLI](docs/contracts/cli.md), [sync](docs/contracts/sync.md), [privacy](docs/contracts/privacy.md), [upstream reuse](docs/contracts/upstream.md), [themes](docs/contracts/themes.md)
- [Changelog](CHANGELOG.md)

## Acknowledgements

Token Taken uses these MIT-licensed projects as references:

- [tokscale](https://github.com/junhoyeo/tokscale): collection, parsing, pricing, and JSON CLI design.
- [TokenTracker](https://github.com/xiufengsun/TokenTracker): Node collectors and local API design.
- [Token Monitor](https://github.com/Javis603/token-monitor): synchronization and history design.

Token Taken bundles the pinned `tokscale` 4.21.0 binary and a `tokscale`-derived price snapshot (`tokscale-4.21.0-2026-11-10+alias-v3`). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for license notices, including the separate license exclusion for TokenTracker's React Bits assets.

## License

[MIT](LICENSE). Copyright (c) 2026 elijah7x.
