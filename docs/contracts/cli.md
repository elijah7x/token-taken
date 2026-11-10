Status: Draft v0 (2026-11-09)

# CLI contract

## Installation and data access

- The executable is named `token-taken` and built from the `TokenTakenCLI` target. Aggregation MUST use the shared `TokenTakenKit` core.
- App settings installs the command as a symlink into a user-chosen directory on `PATH`; the app remains the owner of the symlink target.
- The CLI reads the local store at `~/Library/Application Support/Token Taken/` read-only and includes available synced-device data.
- The CLI MUST NOT perform network access, modify the store, collect agent logs, or write agent configuration. It MUST NOT request iCloud downloads itself.

## Planned v0 commands

- `summary`: aggregate usage with `--period today|month|year|all`, custom `--from` and `--to` dates in `YYYY-MM-DD`, `--by source|model|device`, and filters `--source`, `--model`, and `--device`.
- `sources`: list sources and their last read time, errors, and partial-data health.
- `models`: list normalized model IDs and their retained raw IDs.
- `devices`: list local and synced devices with their available sync health.
- `export`: export the selected aggregate with `--format json|csv`, using the same range, grouping, filtering, and numeric semantics as `summary`.
- `--synthetic` reads the bundled deterministic fixture instead of the store, for demos and tests. Its output MUST carry a `synthetic-data` warning so consumers never mistake it for real usage.
- Global flags are `--json`, `--tz <IANA>`, `--version`, and the schema selector `--schema N` described below.
- The effective time zone is the system time zone unless `--tz` supplies a valid IANA identifier. Named periods and custom date boundaries are interpreted in that zone.
- Custom range endpoints are inclusive. `--from` and `--to` define a custom range and MUST NOT be combined with `--period`; an omitted endpoint is unbounded.

## JSON envelope

- JSON output, including `export --format json`, MUST use this top-level envelope:

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-11-09T00:00:00Z",
  "timeZone": "UTC",
  "range": { "from": "2026-11-01", "to": "2026-11-09" },
  "data": {},
  "warnings": []
}
```

- `schemaVersion` is an integer; `generatedAt` is RFC 3339 UTC; `timeZone` is the effective IANA identifier.
- `range.from` and `range.to` are the effective inclusive dates, or null for an unbounded endpoint. `data` contains the command payload and `warnings` contains machine-readable warning objects.
- Token counts and event counts MUST be JSON integers, never formatted strings or floating-point values.
- Every cost aggregate uses `{estimatedUSD, priceTableVersion, unpricedTokens}`. `estimatedUSD` is a number, `priceTableVersion` identifies the applied table, and `unpricedTokens` is the integer count excluded from pricing.
- `estimatedUSD` covers priced tokens only. Consumers MUST treat positive `unpricedTokens` as an incomplete estimate, not zero cost for those tokens.
- CSV exports preserve the same counts and cost semantics; JSON formatting flags MUST NOT silently change a CSV export into JSON.

## Stability and compatibility

- Adding a response field keeps the current `schemaVersion`. Removing or renaming a field, or changing its meaning, MUST increment `schemaVersion`.
- The previous schema MUST remain selectable with `--schema N` for at least one minor release after a new schema becomes the default.
- Human-readable output is not a stable interface; scripts MUST use the versioned JSON or documented CSV interface.
- For the same store snapshot, price-table version, range, time zone, and filters, CLI and UI MUST report identical numbers. This is the binding P4 acceptance rule.

## Exit codes

- `0`: success.
- `1`: execution or data error.
- `2`: command-line usage error, including invalid dates, time zones, or schema selection.
- `3`: no store exists because the app has never run.

## Open questions

- Default summary range when neither `--period` nor custom endpoints are supplied.
- CSV column layout and the behavior of combining `--json` with `--format csv`.
