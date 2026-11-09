**English** · [简体中文](README.zh-CN.md)

# Token Taken

A small, beautiful token-usage dashboard for macOS with native Liquid Glass.

**Status: Pre-alpha: specification phase, nothing to install yet.**

## Planned v1 features

- Day, month, year, and all-time totals, with per-model and per-source breakdowns.
- One combined total across several Macs, with per-device breakdowns when iCloud sync is on.
- A minimal menu bar extra showing today's token total.
- A native Liquid Glass theme, with a theme system designed for later Geek and Sketchbook themes.
- A `token-taken` CLI with JSON output and JSON/CSV data export.
- English and Simplified Chinese app interfaces through a String Catalog.
- Cost estimates from a versioned price table. Estimates are not bills.

Agent coverage remains open until the engine spike in [ADR-0003](docs/decisions/0003-usage-engine.md).

## Privacy

The v1 design is local-first:

- Token Taken reads supported agent logs read-only.
- iCloud Drive sync is opt-in and off by default.
- Sync contains aggregate usage metadata only. It excludes prompts, responses, file paths, project names, credentials, and cost.
- Token Taken has no telemetry.

See the [privacy contract](docs/contracts/privacy.md) and [sync contract](docs/contracts/sync.md).

## Requirements

- macOS 26.0 or later

## Planned CLI preview

The CLI does not exist yet. The planned interface includes commands such as:

```sh
token-taken summary --period month --by model --json
```

The [CLI contract](docs/contracts/cli.md) defines the planned output and error behavior.

## Documentation

- [Product specification](docs/product.md)
- [Architecture](docs/architecture.md)
- Decisions: [native macOS app](docs/decisions/0001-native-macos-app.md), [iCloud Drive sync](docs/decisions/0002-icloud-drive-sync.md), [usage engine](docs/decisions/0003-usage-engine.md)
- [Contracts index](docs/contracts/README.md)
- Contract details: [statistics](docs/contracts/statistics.md), [CLI](docs/contracts/cli.md), [sync](docs/contracts/sync.md), [privacy](docs/contracts/privacy.md), [upstream reuse](docs/contracts/upstream.md), [themes](docs/contracts/themes.md)
- [Changelog](CHANGELOG.md)

## Acknowledgements

Token Taken uses these MIT-licensed projects as references:

- [tokscale](https://github.com/junhoyeo/tokscale): collection, parsing, pricing, and JSON CLI design.
- [TokenTracker](https://github.com/xiufengsun/TokenTracker): Node collectors and local API design.
- [Token Monitor](https://github.com/Javis603/token-monitor): synchronization and history design.

No upstream code or binaries are bundled yet. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), including the separate license for TokenTracker's React Bits assets.

## License

[MIT](LICENSE). Copyright (c) 2026 elijah7x.
