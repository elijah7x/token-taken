Status: Accepted (2026-11-12)

# Mobile report contract

## Purpose and scope

- An opt-in Mac setting, "Sync to iPhone", makes the Mac app publish a precomputed, aggregate-only report. The companion iOS app only displays that report: it performs no collection, no aggregation, and no pricing.
- Publishing is independent of the iCloud Drive sync toggle: with sync on, the report merges every device that Mac can read; with sync off, it contains this Mac's local usage only. Turning sync off therefore does not remove an existing report, and turning "Sync to iPhone" off stops publication.
- This contract governs the report file, its writer, and its reader. It does not change usage semantics, which remain defined in [statistics.md](statistics.md), or sync semantics, which remain defined in [sync.md](sync.md).

## Location

- The report lives in the iCloud Documents container `iCloud.io.github.elijah7x.TokenTaken`, at `Documents/mobile/v1/report-<deviceId>.json`.
- The container identifier, its availability to a Developer ID Mac app, and the iOS app's access to the same container are recorded in [ADR-0011](../decisions/0011-mobile-report.md). Only the Mac app publishes: the CLI cannot hold the restricted entitlement. Real-device acceptance of a Mac-written report on the phone is still pending.
- `deviceId` is the same random UUID the Mac uses for sync. Reinstalling the app creates a new device and therefore a new report file.

## Writer rules

- Only a Mac with "Sync to iPhone" enabled writes reports. A Mac writes only its own `report-<deviceId>.json` and never another device's file.
- Report content is the merged view of every device that Mac can currently read through the existing sync, including itself. It applies the same merge and coverage rules as [sync.md](sync.md); it does not perform additional account-scoped deduplication and must not claim any.
- The writer publishes after every successful refresh, and at least once per hour while the setting is enabled, so a report is never older than one refresh cycle plus iCloud latency.
- Each publication writes a complete temporary file in the same folder and atomically replaces the destination inside an `NSFileCoordinator` write accessor, propagating both accessor and coordination errors and removing its own temporary file on exit.
- Disabling the setting deletes the Mac's own report file through a coordinated write. It must not delete another device's report.
- A publication that has no readable usage (an empty history or a failed collection) still writes a report with empty `days` and `months` and zero totals. Unreadable devices appear as `unavailable` or `partial` in `coverage`, and totals include only readable data; unknown usage is never published as zero on a device's behalf.
- A device whose identity could not be read at all has no known last write. The writer leaves it out of `coverage` rather than publishing a fabricated timestamp; the reader treats a missing entry as unknown, never as zero usage.
- The writer validates JSON size before publication and refuses to truncate history to fit the budget.

## Reader rules

- Decode only envelopes with `schemaVersion == 1` and `kind == "token-taken.mobile-report"`. Skip any other file, including unknown versions, rather than interpreting it as v1.
- If several valid reports exist, display the one with the newest `generatedAt`. Never add report files together: each report already merges every device its writer could read.
- Show `generatedAt` to the user as the last update time. Never present the data as real time or live.
- A report whose `generatedAt` is more than 24 hours old is stale and must be labelled as such; its data is still shown. No report at all is an empty state that tells the user to enable "Sync to iPhone" on the Mac and sign in with the same Apple ID on both devices, not zero usage.
- Ignore unknown fields and unknown enum values. Missing optional fields degrade to an unknown or absent state, never to a zero total.
- The reader displays coverage as published, showing the generating Mac and each covered Mac with its status. The generating Mac is always the first `coverage.devices` entry, with `lastWriteUTC` equal to `generatedAt`; readers identify it by that position, not by name. It must not infer that a device with no entry has no usage, and must not recompute totals from `days` or `months`.

## Schema

The encoded object is a single JSON object. All token counts are non-negative integers. Dates are ISO 8601 UTC strings with second precision ending in `Z`; day and month labels are local to `timeZoneID`.

| Field | Type | Meaning |
| --- | --- | --- |
| `schemaVersion` | integer | Report layout version. Exactly `1` in this contract. |
| `kind` | string | Exactly `token-taken.mobile-report`. |
| `generatedAt` | string | UTC instant this report was computed and written. |
| `generator` | object | Mac that wrote this file. |
| `generator.deviceId` | string | Writing Mac's sync device UUID. Matches the filename. |
| `generator.displayName` | string | Writing Mac's user-visible device name. |
| `generator.appVersion` | string | Marketing version and build of the writing app, for example `0.1.0 (12)`. |
| `timeZoneID` | string | IANA zone of the generating Mac. Every `today`, `last30Days`, `thisMonth`, `day`, and `month` value in this report is local to it. |
| `coverage.devices` | array | Every device the writer could read, including itself. Ascending by `displayName`; ties broken by `lastWriteUTC`. |
| `coverage.devices[].displayName` | string | Device name. |
| `coverage.devices[].lastWriteUTC` | string or null | That device's sync `lastWriteUTC`; `null` when no readable identity exists. |
| `coverage.devices[].status` | string | `ok`, `stale`, `partial`, or `unavailable`, with the meanings defined in [sync.md](sync.md). |
| `totals.today` | TokenSummary | Generating Mac's current local calendar day. |
| `totals.last30Days` | TokenSummary | The 30 local days ending today, inclusive. |
| `totals.thisMonth` | TokenSummary | Current local calendar month, from its first day through today. |
| `totals.allTime` | TokenSummary | All readable history. |
| `days` | array | One entry for every day with nonzero usage across all readable history, ascending by `day`. Days without usage are absent, not zero. |
| `days[].day` | string | `YYYY-MM-DD` in `timeZoneID`. |
| `days[].total` | integer | TokenSummary `total` for that day. |
| `months` | array | One entry for every month with nonzero usage, ascending by `month`. |
| `months[].month` | string | `YYYY-MM` in `timeZoneID`. |
| `months[].total` | integer | TokenSummary `total` for that month. |
| `months[].sources` | array | Every source contributing to that month, descending by `total`. |
| `months[].sources[].id` | string | Source ID from [statistics.md](statistics.md). |
| `months[].sources[].total` | integer | Tokens from that source in that month. |
| `months[].models` | array | The eight models with the largest `total` in that month, descending, plus an `other` entry when more than eight models exist. Fewer than nine models means no `other` entry. |
| `months[].models[].id` | string | Normalized model ID, or the reserved `other`. `other` is never a real model ID and holds the summed total of every model outside the top eight. |
| `months[].models[].total` | integer | Tokens from that model in that month, including uncategorized tokens recorded against it. |
| `sources` | array | Every source ID referenced anywhere in the report, ascending by `id`. |
| `sources[].id` | string | Source ID. |
| `sources[].displayName` | string | Localized display name chosen by the writer. Readers may substitute their own string for a known ID. |

### TokenSummary

| Field | Type | Meaning |
| --- | --- | --- |
| `total` | integer | Total tokens. |
| `input` | integer | Uncached input tokens. |
| `output` | integer | Output tokens, excluding separately reported reasoning. |
| `cacheRead` | integer | Cache-read tokens. |
| `cacheWrite` | integer | Cache-write tokens. |
| `reasoning` | integer | Separately reported reasoning tokens. |

`total` follows [statistics.md](statistics.md) exactly: `input + cacheRead + cacheWrite + output + reasoning + uncategorized`. Because the report omits `uncategorized` to keep the phone contract small, `total` may exceed the sum of the five component fields by the uncategorized tokens. That difference is real usage with an unknown category split, not an error or a rounding artifact. The report must not redefine `total` as the sum of the five components and must not reassign uncategorized tokens to a named component.

Within one month, the `sources` totals and the `models` totals (including `other`) each sum to `months[].total`, so uncategorized tokens are counted once in each breakdown.

### Example

The example abbreviates the arrays: it lists the last three days and two months, while a real report carries the complete `days` and `months` arrays and every source it references in `sources`.

```json
{
  "schemaVersion": 1,
  "kind": "token-taken.mobile-report",
  "generatedAt": "2026-11-12T09:41:07Z",
  "generator": {
    "deviceId": "6F1C2A0E-3B4D-4E8A-9C21-0B7D5E9A1F34",
    "displayName": "Elijah's MacBook Pro",
    "appVersion": "0.1.0 (12)"
  },
  "timeZoneID": "Asia/Shanghai",
  "coverage": {
    "devices": [
      {
        "displayName": "Elijah's MacBook Pro",
        "lastWriteUTC": "2026-11-12T09:40:52Z",
        "status": "ok"
      },
      {
        "displayName": "Elijah's Mac mini",
        "lastWriteUTC": "2026-11-11T02:12:31Z",
        "status": "stale"
      }
    ]
  },
  "totals": {
    "today": {
      "total": 1284399,
      "input": 214880,
      "output": 186402,
      "cacheRead": 802117,
      "cacheWrite": 61000,
      "reasoning": 20000
    },
    "last30Days": {
      "total": 41188731,
      "input": 7012440,
      "output": 5981330,
      "cacheRead": 25610460,
      "cacheWrite": 1984501,
      "reasoning": 600000
    },
    "thisMonth": {
      "total": 8211903,
      "input": 1402770,
      "output": 1195660,
      "cacheRead": 5100000,
      "cacheWrite": 398473,
      "reasoning": 115000
    },
    "allTime": {
      "total": 193548201,
      "input": 33102114,
      "output": 28190344,
      "cacheRead": 120211877,
      "cacheWrite": 9214866,
      "reasoning": 2829000
    }
  },
  "days": [
    { "day": "2026-11-10", "total": 902331 },
    { "day": "2026-11-11", "total": 1104833 },
    { "day": "2026-11-12", "total": 1284399 }
  ],
  "months": [
    {
      "month": "2026-10",
      "total": 30994128,
      "sources": [
        { "id": "claude", "total": 21002211 },
        { "id": "codex", "total": 9991917 }
      ],
      "models": [
        { "id": "claude-sonnet-4-5", "total": 16400332 },
        { "id": "gpt-5-codex", "total": 9991917 },
        { "id": "other", "total": 4601879 }
      ]
    },
    {
      "month": "2026-11",
      "total": 8211903,
      "sources": [
        { "id": "claude", "total": 6120044 },
        { "id": "codex", "total": 2091859 }
      ],
      "models": [
        { "id": "claude-sonnet-4-5", "total": 5400231 },
        { "id": "gpt-5-codex", "total": 2091859 },
        { "id": "other", "total": 719813 }
      ]
    }
  ],
  "sources": [
    { "id": "claude", "displayName": "Claude Code" },
    { "id": "codex", "displayName": "Codex" }
  ]
}
```

## Privacy

- The report carries the same exclusions as [sync.md](sync.md): no prompts, responses, conversation content, file paths, project or repository names, credentials, diagnostic error strings, or raw event data.
- The report MUST NOT contain cost, prices, price-table versions, or any cost-derived value. Cost stays on the Mac.
- Device display names are the only user-chosen strings in the report; they are the same names already published by sync.
- The report is readable by any process or person with access to the user's iCloud Documents container. Nothing in the report may be added on the assumption that the container is private beyond that access.

## Size and versioning

- A single encoded report MUST stay under 512 KiB. Complete day history and capped monthly breakdowns keep a decade of usage well inside that budget; the writer verifies the encoded size before writing.
- Fitting the budget MUST NOT drop days or months. If the layout can no longer fit real data, the format changes instead.
- Adding optional fields that older readers can ignore keeps `schemaVersion: 1` and the `v1` path. Renaming, removing, retyping, or reinterpreting a field, or changing `total` semantics, requires a new `mobile/v2/` path and a new `schemaVersion`; readers MUST NOT interpret an unknown version as v1.
- Report and sync versions advance independently. A report may merge sync data from a different schema version only if the Mac's own sync reader accepts it.

## Open questions

- Real-device acceptance: a Developer ID Mac writing the shared container and a sandboxed iOS app reading it. The capability and entitlement path are recorded in ADR-0011; the on-device round trip has not been exercised.
- Whether the iOS app shows every Mac's report or only the newest, and how a user with two Macs publishing different merged views should be told the difference.
- Anonymous ranking upload is out of scope here and requires its own ADR.
