Status: Draft v0 (2026-11-09)

# Sync contract

## Scope and layout

- Sync is opt-in and disabled by default. Enabling it permits iCloud Drive transfer of aggregated usage metadata only.
- The user-visible folder is `iCloud Drive/Token Taken/`; its on-disk location is `~/Library/Mobile Documents/com~apple~CloudDocs/Token Taken/`.
- The versioned layout is:

```text
Token Taken/
  v1/
    devices/
      <deviceId>/
        device.json
        usage-YYYY-MM.json
```

- `device.json` contains `deviceId`, `displayName`, `appVersion`, `schemaVersion`, `lastWriteUTC`, and a boolean tombstone flag.
- Each monthly file contains UTC hourly buckets keyed by `(deviceId, sourceId, modelId, hourStartUTC)`, with counts for `input`, `cacheRead`, `cacheWrite`, `output`, `reasoning`, and `eventCount`.
- A monthly snapshot replaces that device/month's previous snapshot. Readers MUST NOT add repeated or cumulative snapshots together.

## Ownership and identity

- Each device folder has exactly one writer: the device identified by its `deviceId`. Other devices MUST treat the folder as read-only.
- `deviceId` is a random UUID created at first launch. Hardware identifiers MUST NOT be used or derived for identity.
- Reinstalling the app creates a new device and folder. It MUST NOT silently adopt an old identity or folder.
- Bucket times come from event timestamps, never the writer's clock. `lastWriteUTC` describes freshness only and MUST NOT affect usage-time attribution.

## Write protocol

- After each collection pass, debounce sync writes rather than writing once per parsed event.
- Write a complete temporary file in the destination folder, then atomically replace the destination using `NSFileCoordinator` for coordinated iCloud access.
- Update `lastWriteUTC` only after a successful write. Readers MUST ignore temporary or incomplete files.

## Read protocol

- Enumerate all device folders and request download of iCloud placeholder files through system file coordination APIs.
- A placeholder, eviction, missing download, or unreadable file is unavailable data, never zero usage. Keep the affected device and period visibly partial.
- Only a successfully read snapshot can contribute data. Missing monthly files MUST NOT be interpreted as confirmed empty months.
- Mark a device stale when `lastWriteUTC` exceeds the configured staleness threshold; retain and label its last available data rather than dropping it.

## Merge and removal

- Device-local sources remain attributed to their device and MUST NOT be cross-device deduplicated.
- Account-scoped sources MUST be deduplicated across devices before totals are calculated. The exact key is TBD after engine spike ([ADR-0003](../decisions/0003-usage-engine.md)).
- Snapshots MUST preserve enough non-content identity metadata to perform that deduplication; category counts and `eventCount` alone are insufficient. Raw events or conversation content MUST NOT be added to accomplish it.
- A tombstoned device stays excluded even if old files reappear. It can return only through explicit re-enablement, which MUST NOT revive deleted usage implicitly.
- Schema versioning uses the `v1/` folder. A breaking layout change requires a new version folder; readers MUST NOT interpret an unknown version as v1.

## Privacy and portability

- Never sync prompts, responses, file paths, project or repository names, credentials, or cost. Sync is not a backup of raw agent logs.
- Hourly UTC buckets cannot exactly reconstruct local day, month, or year boundaries for time zones with non-whole-hour UTC offsets. This known v1 limitation MUST be disclosed when it affects synced-only results.
- Future local-folder, S3, and WebDAV backends reuse the same layout behind a list/read/write interface. Backend-specific behavior MUST NOT change statistics semantics.

## Open questions

- Account-scoped dedup key and its privacy-preserving representation in aggregated snapshots: TBD after engine spike (ADR-0003).
- Staleness threshold and placeholder-download timeout behavior.
- Explicit adoption of an old device folder after reinstall.
- How removal of an offline device is coordinated without violating single-writer folder ownership.
