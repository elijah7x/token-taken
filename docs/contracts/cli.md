Status: Draft v1 (2026-11-10)

# CLI contract

## Installation and data access

- The executable is named `token-taken` and built from the `TokenTakenCLI` target. Aggregation MUST use the shared `TokenTakenKit` core.
- App settings installs the command as a symlink into a user-chosen directory on `PATH`; the app remains the owner of the symlink target.
- The CLI reads the local store at `~/Library/Application Support/Token Taken/` read-only, plus synced-device snapshots when they are readable.
- The CLI MUST NOT perform network access, modify the store, collect agent logs, or write agent configuration. It MUST NOT request iCloud downloads itself.
- `--synthetic` reads the bundled deterministic fixture instead of the store and MUST add a `synthetic-data` warning so consumers never mistake it for real usage.
- Synced devices are read through `ICloudSync.readRemote` and `MergedUsageStore`. `--local-only` disables that read for every command. When the iCloud root or `v1/devices` is absent, the store is the local SQLite store alone; absence is not an error.

## Commands

```text
token-taken summary  [options]
token-taken sources  [options]
token-taken models   [options]
token-taken devices  [options]
token-taken export   [--format json|csv] [--output FILE] [options]
token-taken --version
token-taken --schema [VERSION]
```

Every command accepts the same range and filter options. `--format` and `--output` are valid only for `export`; any other command rejects them as a usage error. Unknown options and missing values are usage errors.

| Option | Meaning |
| --- | --- |
| `--period day\|month\|year\|all` | Named range ending today. Default: `month`. `day` and `today` are accepted aliases. |
| `--since YYYY-MM-DD` | Inclusive local start date. Overrides `--period`. |
| `--until YYYY-MM-DD` | Inclusive local end date. Overrides `--period`. May be combined with `--since`. |
| `--tz <IANA id>` | Viewer time zone. Default: the system zone. An invalid identifier is a usage error. |
| `--source <id>` | Repeatable source filter. |
| `--model <id>` | Repeatable filter on the normalized `modelID`. |
| `--device <id>` | Repeatable device filter. |
| `--json` | JSON output. For `export`, equal to `--format json`. |
| `--synthetic` | Read the bundled fixture instead of the store. |
| `--local-only` | Do not read synced-device folders. |
| `--schema [VERSION]` | Prints the JSON schema version and exits 0. `--schema 1` selects that schema and runs the command; any other version is a usage error. |
| `--format json\|csv` | `export` only. An explicit `csv` wins over `--json`. |
| `--output FILE` | `export` only. Writes the export to `FILE` instead of stdout. |

- Filters apply before aggregation: `--source`, `--model`, and `--device` remove daily records, so totals, breakdowns, and costs never include filtered-out rows. `--model` matches the normalized model ID, not the raw spelling.
- `--since`/`--until` and `--tz` bound the range in the viewer's calendar and zone. A daily record is selected by its own `YYYY-MM-DD` label, not by converting it to a UTC instant; this is exact only when the collecting and viewing zones match.
- `--period` and `--since`/`--until` are never an error together: the custom range wins.
- The default period is `month` for every command that selects daily records: `summary`, `models`, `devices`, and `export`.
- Named periods run from the period start through the end of today. A custom range is unbounded at an omitted end. `source`, `model`, and `device` names in table output are display labels; scripts MUST use `--json`.

### `summary`

Aggregates usage for the effective range: total counts by category, breakdowns by source, model, and device, and the estimated cost.

- Table output shows total, categories, breakdowns, and the price-table note. JSON carries the same values.
- `range.from` and `range.to` are the effective inclusive days of the named period. For a custom range they are the supplied bounds, with `null` for an omitted endpoint.
- `data.period` is the period name, or `null` when a custom range overrides it.
- Cost semantics are those in [statistics.md](statistics.md): `estimatedUSD` covers priced tokens only and `unpricedTokens` counts what no rate covered.

### `sources`

Lists local source health: ID, state, last success, daily record count, skipped records, and the last error.

- `state` is one of `ok`, `unavailable`, `notInstalled`, `failed`, or `stale`; table output renders `notInstalled` as `not installed`. The CLI applies the default 24-hour staleness rule.
- `--source` limits the listed sources. Range options and `--model`/`--device` are accepted for compatibility but do not scope health metadata, so `range` is always `{from: null, to: null}`.
- Synced-device health is not part of this list; device-level conditions appear as warnings instead.
- With no health rows the table prints `No source health recorded` and JSON returns an empty array.

### `models`

Lists normalized model IDs seen in the filtered daily records within the active range, with their retained raw IDs and token totals.

- Entries are sorted by total tokens descending, then ID.
- `rawModelIDs` is sorted and may contain more than one spelling when a collector collapsed variants onto one normalized ID.
- Empty selection prints `No usage models recorded`.

### `devices`

Lists devices that have usage in range, local devices known to the store, and readable synced devices.

- `local` is true when the device is served from the local store; false for synced snapshots.
- `state` and `lastWrite` describe sync freshness and are `null` for local devices.
- Totals follow the active filters and range.
- Empty selection prints `No devices recorded`.

### `export`

Writes one row per daily record after filtering, with no further grouping.

- `--format json` (default) puts the rows in `data.rows` inside the standard envelope.
- `--format csv` writes the documented CSV interface described below. It has no envelope and therefore no `warnings` array; warnings go to stderr.
- The default range is the current month. Use `--period all` to export complete history.
- Rows carry no cost; costs are computed per query and remain a `summary` concern.

## Synced devices

- Unless `--local-only` is set, the CLI reads `<iCloud root>/v1/devices` when it exists and merges readable device snapshots through `MergedUsageStore`. A missing root, missing `v1/devices`, or unreadable placeholder is not an error.
- The local device folder is excluded from the remote set so this Mac is never counted twice.
- Synced totals are attributed to their collecting device. The current aggregates cannot deduplicate the same account across devices; the CLI MUST NOT claim account-scoped accuracy.

## JSON envelope

All JSON output, including `export --format json`, uses one envelope:

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-11-09T00:00:00Z",
  "timeZone": "Asia/Shanghai",
  "range": { "from": "2026-11-01", "to": "2026-11-09" },
  "data": {},
  "warnings": []
}
```

- `schemaVersion` is an integer; `generatedAt` is RFC 3339 UTC; `timeZone` is the effective IANA identifier.
- `range.from` and `range.to` are the effective inclusive dates, or `null` for an unbounded endpoint or a command whose payload is not range-scoped. `--period all` therefore reports a `null` start; table output still shows the earliest contributing day.
- Token counts and event counts are JSON integers, never formatted strings or floating-point values.
- Every cost aggregate uses `{estimatedUSD, priceTableVersion, unpricedTokens}`. See [statistics.md](statistics.md).
- `data` payloads:

```json
// summary
{ "period": "month", "total": { "input": 0, "cacheRead": 0, "cacheWrite": 0, "output": 0, "reasoning": 0, "uncategorized": 0, "total": 0 },
  "bySource": [{ "id": "claude", "name": "Claude Code", "input": 0, "cacheRead": 0, "cacheWrite": 0, "output": 0, "reasoning": 0, "uncategorized": 0, "total": 0 }],
  "byModel": [], "byDevice": [],
  "cost": { "estimatedUSD": 0.0, "priceTableVersion": "prices-2026-11", "unpricedTokens": 0 } }

// sources
{ "sources": [{ "id": "claude", "lastSuccess": "2026-11-09T00:00:00Z", "records": 120,
                "skippedRecords": 0, "state": "ok", "error": null }] }

// models
{ "models": [{ "id": "claude-sonnet-4-5", "rawModelIDs": ["claude-sonnet-4-5"],
               "input": 0, "cacheRead": 0, "cacheWrite": 0, "output": 0, "reasoning": 0,
               "uncategorized": 0, "total": 0 }] }

// devices
{ "devices": [{ "id": "…", "name": "MacBook Pro", "local": true, "lastWrite": null,
                "state": null, "total": 0 }] }

// export
{ "rows": [{ "day": "2026-11-09", "timeZoneID": "Asia/Shanghai", "deviceID": "…",
             "sourceID": "claude", "modelID": "claude-sonnet-4-5", "rawModelID": "claude-sonnet-4-5",
             "input": 0, "cacheRead": 0, "cacheWrite": 0, "output": 0, "reasoning": 0,
             "uncategorized": 0, "total": 0, "eventCount": 0 }] }
```

## CSV export

RFC 4180 CSV with a header row. The line terminator is CRLF, the field separator is a comma, and a field is quoted only when it contains a comma, quote, CR, or LF; embedded quotes are doubled. Text fields beginning with `=`, `+`, `-`, `@`, tab, or CR are prefixed with one apostrophe before escaping; numeric fields are unchanged.

```text
day,timeZoneID,deviceID,sourceID,modelID,rawModelID,input,cacheRead,cacheWrite,output,reasoning,uncategorized,total,eventCount
```

- One line per exported daily record, in `day`, `deviceID`, `sourceID`, `modelID`, `rawModelID` order.
- `total` is `input + cacheRead + cacheWrite + output + reasoning + uncategorized`.
- CSV is an export interface, not a stable reporting API: columns are fixed by this contract and new columns are added at the end.

## Warnings

Warnings are machine-readable objects with a stable `code` and a human-readable `message`. JSON output carries them in `warnings`; table output prints `warning [code]: message` lines to stderr. Warnings never change the exit code to failure for otherwise successful data.

| Code | Condition |
| --- | --- |
| `source-failed` | A source's last collection failed. |
| `source-unavailable` | A source's location is unavailable. |
| `source-stale` | A source has no successful collection within the freshness threshold (default 24 hours). |
| `partial-data` | A source skipped records; its data is partial even when state is `ok`. |
| `device-stale` | A synced device's last write exceeds the freshness threshold. |
| `device-partial` | A synced device snapshot is incomplete. |
| `device-unavailable` | A synced device snapshot is unreadable or failed to download. |
| `synthetic-data` | The output comes from the bundled fixture, not real usage. |

## Stability and compatibility

- Adding a response field keeps the current `schemaVersion`. Removing or renaming a field, or changing its meaning, MUST increment `schemaVersion`.
- The previous schema MUST remain selectable with `--schema N` for at least one minor release after a new schema becomes the default. Only schema 1 exists today.
- Human-readable output is not a stable interface; scripts MUST use the versioned JSON or documented CSV interface.
- For the same store snapshot, price-table version, range, time zone, and filters, CLI and UI MUST report identical numbers. This is the binding P4 acceptance rule.

## Exit codes

- `0`: success, including success with warnings.
- `1`: execution or data error, including an unreadable store or an unwritable `--output` path.
- `2`: command-line usage error, including invalid dates, time zones, schema selection, formats, or unknown options.
- `3`: no store exists because the app has never run.

## Open questions

- Whether export should gain cost columns, and whether a future schema should stream rows instead of buffering them.
- Behavior when combining `--json` with `--format csv`: the explicit CSV format wins today, but this is not yet exercised by scripts.
