Status: Draft v1 (2026-11-10); sync transport is not implemented.

# Sync contract

## Scope and layout

- Sync is opt-in and disabled by default. Enabling it permits iCloud Drive transfer of aggregate usage metadata only.
- The user-visible folder is `iCloud Drive/Token Taken/`; its on-disk location is `~/Library/Mobile Documents/com~apple~CloudDocs/Token Taken/`.
- The unreleased v1 layout is:

```text
Token Taken/
  v1/
    devices/
      <deviceId>/
        device.json
        usage-YYYY-MM.json
        hourly.json
```

- `device.json` contains `deviceId`, `displayName`, `appVersion`, `schemaVersion`, `lastWriteUTC`, and a boolean tombstone flag.
- Each monthly usage file contains daily records keyed by `(deviceID, sourceID, modelID, day)`, partitioned by the record's `YYYY-MM` date label, not UTC month. Records retain `day` (`YYYY-MM-DD`), `timeZoneID`, normalized `modelID`, `rawModelID`, counts (`input`, `cacheRead`, `cacheWrite`, `output`, `reasoning`, `uncategorized`), and `eventCount`.
- `hourly.json` is a separate rolling activity snapshot keyed by `(deviceID, sourceID, hourStart)`. `hourStart` is an absolute UTC instant; each row retains counts, `eventCount`, and `reasoningKnown`. It has no model field. Successful local collection retains the current collecting-device hour and 47 preceding absolute hourly intervals per source. A failed source may retain older cached rows, which MUST remain visibly stale/unavailable rather than treated as current coverage.
- Daily files hold complete history. Hourly rows describe activity shape only and MUST NOT be added to daily totals or used to replace missing daily history. This replaces the earlier draft's UTC-hour-by-model layout under [ADR-0005](../decisions/0005-collection-granularity.md); no released sync format is being silently migrated.
- A monthly snapshot replaces that device/month's previous snapshot; an hourly snapshot replaces that device's previous rolling hourly snapshot. Readers MUST NOT add repeated or cumulative snapshots together.

## Ownership and identity

- Each device folder has exactly one writer: the device identified by its `deviceId`. Other devices MUST treat it as read-only.
- `deviceId` is a random UUID created at first launch. Hardware identifiers MUST NOT be used or derived for identity.
- Reinstalling the app creates a new device and folder. It MUST NOT silently adopt an old identity or folder.
- Daily labels and their zone come from collection; hourly instants come from source timestamps or conversion of engine-local hourly labels using that same zone. `lastWriteUTC` describes freshness only and MUST NOT affect usage-time attribution.
- Every daily row retains its collection zone. A full recollection after a device-zone change replaces its earlier daily bucketing; it does not infer the device's historical physical location.

## Write protocol

- Debounce writes after each collection pass, not once per parsed event.
- Write a complete temporary file in the destination folder, then atomically replace the destination using `NSFileCoordinator` for coordinated iCloud access.
- Update `lastWriteUTC` only after a successful write. Readers MUST ignore temporary or incomplete files.
- Publish consistent record-kind snapshots; publication ordering and recovery for a multi-file collection generation require an implementation contract before sync is enabled.

## Read protocol and coverage

- Enumerate device folders and request download of iCloud placeholder files through system file coordination APIs.
- Placeholder, eviction, missing download, unreadable file, or absent record kind is unavailable data, never zero usage. Keep the affected device and period visibly partial.
- Only a successfully read snapshot contributes data. Missing monthly files MUST NOT be interpreted as confirmed empty months.
- Complete successful local reads publish explicit zero hourly rows to establish coverage in the last 48 hours. Missing hourly rows, partial reads with skipped records, or failure establish no new zero coverage. Preserve `reasoningKnown=false`; omitted reasoning is unknown, not measured zero.
- Mark a device stale when `lastWriteUTC` exceeds the configured threshold; retain and label its last available data. Per-source coverage MUST NOT be inferred solely from device freshness, because individual collectors can fail.
- Failed/unavailable local collection keeps both cached record kinds. Do not replace another device's previously readable cache with an unreadable or incomplete download.

## Merge and removal

- Device-local sources remain attributed to their device and MUST NOT be cross-device deduplicated.
- The current aggregates do not contain per-event identity and cannot support exact account-scoped cross-device deduplication. Do not approximate it with `(source, day, model)` or `(source, hour)` keys, or claim the result is exact. Cursor remains deferred until a privacy-preserving identity contract and collection path are separately accepted.
- No prompts, responses, conversation content, or raw events may be added to recover account-scoped identity.
- A tombstoned device stays excluded even if old files reappear. It can return only through explicit re-enablement, which MUST NOT revive deleted usage implicitly.
- Schema versioning uses the `v1/` folder. Once v1 ships, a breaking layout change requires a new version folder; readers MUST NOT interpret an unknown version as v1.

## Time and statistics limitations

- Viewer day/month/year boundaries use the viewer's calendar and time zone. Daily records are placed on their original calendar-date labels without shifting them. This is exact when the collecting and viewer zones match; different-zone daily aggregates cannot be re-bucketed exactly into viewer-local periods. Disclose this limitation when synced data comes from another zone.
- Day totals, categories, breakdowns, and pricing use daily records. The Day chart uses absolute hourly rows converted into viewer-local hours and may differ: tokscale hourly output has no reasoning field, cross-zone daily labels can select a different interval, and coverage can be partial. Never spread daily counts across fabricated hours or force the chart to equal the daily total.
- DST charts have the actual day's hourly interval count. Offset-free tokscale local hour labels cannot distinguish repeated fall-back hours. Different fractional UTC offsets can put viewer boundaries inside a source hour; aggregates cannot split those buckets exactly.
- Unknown hourly points (`SeriesPoint.isKnown=false`) are gaps, not confirmed zero. Preserve source-level coverage and reasoning knowledge across sync.

## Privacy and portability

- Never sync prompts, responses, file paths, project or repository names, credentials, or cost. Sync is not a backup of raw logs. Model IDs and aggregate usage are allowed; diagnostic error strings MUST NOT be synced because they can contain private paths or content.
- `uncategorized` is a known total with an unknown split, participates in totals, and is never priced. Pricing remains local and versioned.
- Future local-folder, S3, and WebDAV backends reuse this layout behind a list/read/write interface. Backend behavior MUST NOT change statistics semantics.

## Open questions

- Privacy-preserving account-scoped identity, still unsupported by the current export.
- Transport implementation, multi-file generation consistency, per-source health serialization without private errors, placeholder-download timeout, and configurable staleness. Local source-health currently defaults to 24 hours.
- Explicit adoption of an old device folder after reinstall.
- Coordinating removal of an offline device without violating single-writer ownership.
