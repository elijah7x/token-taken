Status: Implemented v1 (2026-11-10); real multi-Mac iCloud acceptance remains pending.

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
        account-<32hex>-usage-YYYY-MM.json
        account-<32hex>-hourly.json
```

- Every JSON envelope carries `schemaVersion: 1`. JSON object keys are sorted; daily rows are sorted by day/device/source/model, hourly rows by instant/device/source, and source health by source ID. Dates are ISO 8601 UTC strings with second precision.
- `device.json` contains `deviceId`, `displayName`, `appVersion`, `schemaVersion`, `lastWriteUTC`, a boolean `tombstone`, a `files` dictionary mapping record-kind filenames to SHA-256 hashes of their exact bytes, `sources`, and `accounts`.
- Each `sources` entry contains only `sourceID`, `lastSuccess`, `state`, and `skippedRecords`. Never serialize the local diagnostic/error message. This exposes source failures and partial reads independently of a recent device write.
- Monthly and hourly envelopes contain `schemaVersion` and a `records` array. The manifest is authoritative: unreferenced historical files and temporary files never contribute data. An empty daily manifest is an explicitly published empty daily history, not evidence inferred from missing files.
- Each monthly usage file contains daily records keyed by `(deviceID, sourceID, modelID, day)`, partitioned by the record's `YYYY-MM` date label, not UTC month. Records retain `day` (`YYYY-MM-DD`), `timeZoneID`, normalized `modelID`, `rawModelID`, counts (`input`, `cacheRead`, `cacheWrite`, `output`, `reasoning`, `uncategorized`), and `eventCount`.
- `hourly.json` is a separate rolling activity snapshot keyed by `(deviceID, sourceID, hourStart)`. `hourStart` is an absolute UTC instant; each row retains counts, `eventCount`, and `reasoningKnown`. It has no model field. Publication includes only the current collecting-device hour and 47 preceding absolute hourly intervals per source. Local storage may retain older rows after failure, but these aged-out rows are not published; sanitized source health and missing recent hourly coverage expose the failure.
- Daily files hold complete history. Hourly rows describe activity shape only and MUST NOT be added to daily totals or used to replace missing daily history. This replaces the earlier draft's UTC-hour-by-model layout under [ADR-0005](../decisions/0005-collection-granularity.md); no released sync format is being silently migrated.
- A monthly snapshot replaces that device/month's previous snapshot; an hourly snapshot replaces that device's previous rolling hourly snapshot. Readers MUST NOT add repeated or cumulative snapshots together.

## Account publications

- Account-scoped sources are fetched from an account, not from the local machine, so every Mac signed into the same account parses the same rows. Their rows belong to a synthetic account device (`account-<source>-<32 lowercase hex>`), never to the collecting Mac.
- The Mac that collects an account source publishes that account's full history as an additional record kind inside its own device folder: `account-<32hex>-usage-YYYY-MM.json` (the `DailySyncSnapshot` envelope) and `account-<32hex>-hourly.json` (the `HourlySyncSnapshot` envelope). The `<32hex>` suffix is the account device ID's trailing 32 hex characters and MUST match it.
- `device.json` lists those files in an `accounts` array, never in the top-level `files` dictionary. Each entry carries `deviceId`, `displayName`, `kind` (`"account"`), `sources`, `collectedAtUTC`, and its own `files` hash dictionary. The split keeps the top-level record-kind whitelist unchanged, so a reader that predates account publications ignores them instead of rejecting the whole device.
- `collectedAtUTC` is the latest successful collection time of that account's published sources, from the publishing Mac's local source health. A Mac with no successful account collection publishes nothing for that account; stale account files on disk stay unreferenced and never contribute.
- Account rows retain the daily and hourly row shapes, with `deviceID` set to the account device ID and `day`/`hourStart` labelled in UTC by the collector. Identical bytes are not rewritten, and withdrawing an account publication follows the ordinary rules: the manifest drops the files, previously written files remain on disk and are ignored.
- A publication is usable only if every listed file is readable, hash-valid, and internally valid: `kind` is `"account"`, each declared source is account-scoped, every row's `deviceID` equals the publication's `deviceId`, every row's `sourceID` is one of its declared sources, daily rows match their month file, and hourly `(sourceID, hourStart)` pairs are unique. Any unreadable, undownloaded, mismatched, or missing file makes that publication unusable — omitted entirely, never published as an empty or partial history — and never affects the Mac's own rows in the same folder.

## Ownership and identity

- Each device folder has exactly one writer: the device identified by its `deviceId`. Other devices MUST treat it as read-only.
- `deviceId` is a random UUID created at first launch. Hardware identifiers MUST NOT be used or derived for identity.
- Reinstalling the app creates a new device and folder. It MUST NOT silently adopt an old identity or folder.
- Daily labels and their zone come from collection; hourly instants come from source timestamps or conversion of engine-local hourly labels using that same zone. `lastWriteUTC` describes freshness only and MUST NOT affect usage-time attribution.
- Every daily row retains its collection zone. A full recollection after a device-zone change replaces its earlier daily bucketing; it does not infer the device's historical physical location.

## Write protocol

- After a collection pass with at least one successfully persisted source, capture immutable daily/hourly data off the main actor before admitting another refresh. Debounce publication by one second, not once per parsed event. A dedicated worker actor serializes app reads and writes off the main actor.
- Publish only rows belonging to the local device ID, plus account rows of the account devices this Mac collected (see *Account publications*); never write another device's folder. Read the previous identity first and refuse unreadable, unknown-version, or tombstoned identities rather than reviving them.
- Encode every current month and the rolling hourly snapshot. Compare exact bytes with the existing file and write only changed payloads, preserving unchanged monthly modification times.
- Write a complete hidden temporary file in the destination folder, then atomically replace (or initially move into) the destination inside an `NSFileCoordinator` write accessor. Propagate both accessor errors and coordination errors. Remove this operation's temporary file on exit. Apple's [synchronous coordination API](https://developer.apple.com/documentation/foundation/nsfilecoordinator/coordinate(writingitemat:options:error:byaccessor:)) requires using the accessor's URL and handling the case where the accessor never runs.
- Publish `device.json` last, with the new hashes and `lastWriteUTC`, only after every payload write succeeds. A failed publication leaves the previous manifest in place. A later attempt compares/repairs the payloads and republishes the manifest.
- iCloud does not guarantee multi-file arrival order. Readers validate each payload against the manifest. All referenced months must be available and valid before any daily history from that publication contributes; hourly is independently validated. Readers never mix daily months from different publications.
- Previously written months that no longer belong to the snapshot may remain on disk, but are removed from the manifest and ignored. This avoids reviving removed usage through old files.
- Turning sync off immediately stops merging and cancels queued publication. A synchronous coordinated write already in progress may finish. Disabling sync does not remove previously uploaded data.

## Read protocol and coverage

- Enumerate other device folders, excluding the local ID. Request download with [`FileManager.startDownloadingUbiquitousItem(at:)`](https://developer.apple.com/documentation/foundation/filemanager/startdownloadingubiquitousitem(at:)) for hidden `.icloud` placeholders or non-current ubiquitous items, and return unavailable immediately rather than waiting or polling; when a device's `device.json` is unavailable, the reader also requests downloads for every hidden `.icloud` placeholder in that device folder. When any remote Mac reads as `unavailable` or `partial` (not `stale`), the app schedules remote-only re-reads after 10 seconds, 30 seconds, 2 minutes and 10 minutes while any remote remains `unavailable` or `partial`, then waits for the normal refresh schedule; the backoff resets once no remote is `unavailable` or `partial`, on any non-retry read, or on a full refresh. Reads of available regular files use `NSFileCoordinator`.
- Placeholder, eviction, missing download, unreadable file, or absent record kind is unavailable data, never zero usage. Keep the affected device and period visibly partial.
- Only a successfully read snapshot contributes data. Missing monthly files MUST NOT be interpreted as confirmed empty months.
- Complete successful local reads publish explicit zero hourly rows to establish coverage in the last 48 hours. Missing hourly rows, partial reads with skipped records, or failure establish no new zero coverage. Preserve `reasoningKnown=false`; omitted reasoning is unknown, not measured zero.
- `RemoteDeviceStatus.State` is `ok`, `stale`, `partial`, or `unavailable`. A missing/unreadable identity is unavailable with an unknown last-write time. An unreadable daily or hourly record kind is partial if the other kind remains available, and unavailable if neither is available. Payload hash mismatches count as unreadable data. Unknown schema versions skip the device entirely.
- Readers drop hourly rows outside the writer's current-hour-and-preceding-47-hours window. Aged or future rows are not an availability failure and do not make the device partial. Writers validate an existing identity's minimal schema header before decoding its v1 fields and reject unknown identity schemas.
- A readable device is stale when `lastWriteUTC` is more than 24 hours old; available data remains included. Otherwise, failed/unavailable/stale source health, missing last-success timestamps, or skipped records make the device partial. Device freshness never establishes source-level coverage. Staleness is fixed at 24 hours in v1, not configurable.
- Failed/unavailable local collection keeps both cached record kinds. During the app session, a previously readable remote snapshot is retained when a subsequent read is not `ok`, and labelled using the new status. The reader API itself is stateless; the app cache is in memory, not a durable offline replica. A missing iCloud Drive root retains cached snapshots as unavailable. Unknown versions and readable tombstones are excluded, not cached back into the merge.

- The CLI reads synced devices without requesting iCloud downloads (`ICloudSync.readRemote(..., requestDownloads: false)`); files not yet downloaded count as unavailable, never zero. The app requests downloads.

## Merge and removal

- Device-local sources remain attributed to their device and MUST NOT be cross-device deduplicated. Summing two Macs' `claude` or `codex` rows is correct: each row came from that Mac's own logs.
- Account-scoped sources are the exception, and the exception is about data ownership rather than a guessed identity. Deduplication is whole-publication: for each account device ID, at most one publication contributes, chosen by latest `collectedAtUTC`, then the local store, then the lowest publisher device ID. The unchosen publications' daily and hourly rows — including the local store's own rows for that account when a peer wins — are excluded entirely.
- Whole-publication selection is required because an account history has exactly one authority. Rows in different publications describe the same CSV export at different collection times; mixing them picks rows from different exports and can double count or resurrect deleted rows. Selecting one publication keeps daily and hourly consistent with each other and with the export it came from.
- This is not the forbidden approximation. A `(source, day, model)` or `(source, hour)` key is still not a valid way to collapse rows from different Macs' local sources, and MUST NOT be used to infer account identity from machine-local history. Account rows are already attributed to an account device by the collector; a publication is the same export re-published, not a guess about which Mac produced it.
- `MergedUsageStore` therefore keeps three parts: local rows that are not account rows, one publication per account device ID as described above, and each remote Mac's rows filtered to its own `deviceID`. Its `devices` list holds local devices, remote Mac devices, and each account device exactly once.
- No prompts, responses, conversation content, or raw events may be added to recover account-scoped identity.
- A device whose readable identity has `tombstone: true` is excluded even if its old payload files remain or reappear. The writer refuses that identity. v1 has no removal, adoption, or re-enablement UI; rolling back the identity file itself cannot be detected by this stateless transport.
- Schema versioning uses the `v1/` folder. Once v1 ships, a breaking layout change requires a new version folder; readers MUST NOT interpret an unknown version as v1.

## Time and statistics limitations

- Viewer day/month/year boundaries use the viewer's calendar and time zone. Daily records are placed on their original calendar-date labels without shifting them. This is exact when the collecting and viewer zones match: each Mac's daily records use that Mac's local calendar day, so a merged day can mix zones. This limitation is documented in `README.md` and `README.zh-CN.md`, and CLI JSON output MUST report the viewer `timeZone`.
- Day totals, categories, breakdowns, and pricing use daily records. The Day chart uses absolute hourly rows converted into viewer-local hours and may differ: tokscale hourly output has no reasoning field, cross-zone daily labels can select a different interval, and coverage can be partial. Never spread daily counts across fabricated hours or force the chart to equal the daily total.
- DST charts have the actual day's hourly interval count. Offset-free tokscale local hour labels cannot distinguish repeated fall-back hours. Different fractional UTC offsets can put viewer boundaries inside a source hour; aggregates cannot split those buckets exactly.
- Unknown hourly points (`SeriesPoint.isKnown=false`) are gaps, not confirmed zero. Preserve source-level coverage and reasoning knowledge across sync.

## Privacy and portability

- Never sync prompts, responses, file paths, project or repository names, credentials, or cost. Sync is not a backup of raw logs. Model IDs and aggregate usage are allowed; diagnostic error strings MUST NOT be synced because they can contain private paths or content.
- `uncategorized` is a known total with an unknown split, participates in totals, and is never priced. Pricing remains local and versioned.
- `SyncBackend(root:)` exposes `list(_:)`, `read(_:)`, and `write(_:to:)` over an explicit root URL. Paths cannot escape the root, including through symlinks. Tests use temporary directories only. Future S3 and WebDAV implementations must preserve statistics semantics.
- `ICloudSync.defaultRoot` resolves the user-visible `Token Taken` folder only when the parent iCloud Drive folder already exists; it returns `nil` otherwise and never creates the parent Drive folder.
- `ICloudSync.write(local:device:root:appVersion:health:now:)` publishes local snapshots. `readRemote(root:excludingDeviceID:)` returns device metadata, daily/hourly rows, and status; an overload accepts `now` for deterministic freshness tests.
- `MergedUsageStore(local:remote:)` implements `UsageStore`, adds local and remote Mac rows without cross-device deduplication, resolves account rows to one publication per account device ID, and exposes remote display names through `devices`. Duplicate remote IDs and IDs already present in the local device catalog are ignored. It never stores remote rows in the local collection database.
- The persisted app `syncEnabled` preference defaults to false. Enabling reads remotes immediately; refresh reads remotes before collection and after publication. Disabling uses the plain local store. Settings lists other Macs, relative last-write times, stale/unavailable indicators, and missing iCloud Drive. Partial devices use the unavailable label for their incomplete coverage. `AppModel.remoteDevices` exposes statuses; remote problems also contribute to `dataIssues`.

## Open questions

- Durable remote offline caching of account publications, and account-scoped identity for sources whose export exposes no stable account ID.
- A durable remote offline cache, download-completion notifications, configurable staleness, and identity rollback protection are deferred. Current reads never wait for placeholder downloads; freshness is fixed at 24 hours.
- Real multi-Mac validation of coordination, eviction/download behavior, interrupted publication recovery, and opt-out during an in-flight write remains required.
- Explicit adoption of an old device folder after reinstall.
- Coordinating removal of an offline device without violating single-writer ownership.
