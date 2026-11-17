English | [简体中文](README.zh-CN.md)

# Token Taken

A small, calm macOS app for tracking AI coding-agent token usage—with native Liquid Glass, a menu bar extra, a CLI, and a display-only iPhone companion.

## Why

Before building Token Taken, I tried several other usage trackers, only to run into the same small frustrations: numbers that never quite felt right, interfaces that got in the way, and no clean way to share a summary without taking and cropping screenshots by hand. After enough of that friction, I decided to build the small, well-crafted macOS app I actually wanted to open each day. Something quiet to glance at, faithful to native macOS, with shareable summary cards built right in.

## What it does

- **Native macOS dashboard & menu bar** — Day, week (Monday start), month, year, and all-time totals broken down by harness and model across Liquid Glass, Field, and Cosmos themes, plus a minimal menu bar extra for today's total.
- **Broad agent coverage** — Collects locally from Claude Code, Codex, Zcode, OpenCode, Kimi Code, Gemini CLI, pi, oh-my-pi, Factory Droid, Grok, Devin, Antigravity, MiniMax Code, DeepSeek Harness, DeepSeek CLI, and fx, with opt-in Cursor account collection.
- **Built-in share cards** — Renders PNG cards (copy, save, or share) scoped to your overall usage, a single harness, or a single model, with optional composition, rank, and cost estimates.
- **Multi-Mac & iPhone companion** — Opt-in iCloud Drive sync merges usage across Macs on the same Apple ID and feeds a display-only iOS 26 companion app with its own shareable Liquid Glass card.
- **`token-taken` CLI** — Reads the same local store and synced snapshots for machine-readable JSON summaries and JSON/CSV exports.

## Privacy

- **Local and read-only** — Agent logs and local databases are read locally without modification. Token Taken collects no telemetry.
- **Opt-in, aggregate-only sync** — iCloud Drive sync and the iPhone companion report are off by default. Synced data contains only aggregate usage metadata—no prompts, responses, file paths, project names, or credentials.
- **Estimated costs** — Cost figures are read-time estimates from a bundled price table, never provider bills.

## Status

Only the source code is public for now—no release has been published yet. Packaged builds are coming soon; **Star** this repository if you'd like to be notified when the first release is out.

## Building from source

Requires an Apple silicon Mac on macOS 26 or later, and Xcode. The iPhone companion lives in `ios/`. Architecture and design notes are in [`docs/`](docs/).

## License

[MIT](LICENSE). Copyright (c) 2026 elijah7x.
