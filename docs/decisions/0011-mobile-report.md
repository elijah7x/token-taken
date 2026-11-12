Status: Accepted (2026-11-12)

# ADR-0011: Mobile report for the iOS companion app

## Context

- A companion iOS app should let the owner see usage away from the Mac and share usage cards. It must stay small and display-only: it has no access to agent logs, the usage engine, the local SQLite store, or the price table.
- The iOS app cannot read the current `iCloud Drive/Token Taken/` folder. A sandboxed app cannot open the non-sandboxed path `~/Library/Mobile Documents/com~apple~CloudDocs/Token Taken/`; it only gets its own iCloud Documents container. The Mac app is non-sandboxed and reads that path directly ([ADR-0002](0002-icloud-drive-sync.md)).
- The Mac already computes a merged per-device view for sync ([sync.md](../contracts/sync.md)). Rebuilding that view on the phone would duplicate aggregation, coverage, and zone rules in a second implementation.
- A Developer ID, non-App-Store Mac app can hold the iCloud Documents capability; the entitlement and provisioning constraints are recorded under Verification below.

## Decision

- Add an opt-in Mac setting, "Sync to iPhone", off by default. When it is on, the Mac publishes a precomputed, aggregate-only report to the iCloud Documents container `iCloud.io.github.elijah7x.TokenTaken`, at `Documents/mobile/v1/report-<deviceId>.json`.
- The report is the merged view of every device that Mac can read through sync, including itself. The phone is display-only: it decodes one report, shows the data, and never collects, merges, or prices anything.
- Each Mac writes only its own report file and republishes after every successful refresh and at least hourly while enabled. Turning the setting off deletes that Mac's own report.
- The phone shows the report with the newest `generatedAt`, labels data older than 24 hours as stale, and shows the report's timestamp instead of implying live data.
- The report carries usage only: no cost, no prompts, responses, paths, project names, credentials, or error strings. Semantics follow [statistics.md](../contracts/statistics.md) unchanged.
- The normative file format and reader/writer rules live in [mobile-report.md](../contracts/mobile-report.md).

## Verification (2026-11-12)

- Apple's macOS capability table lists iCloud Documents for Developer ID signed apps, not only for Mac App Store distribution, so the shared container is not tied to App Store signing.
- A container entitlement is restricted: the Mac app must be signed with a Developer ID provisioning profile that carries the container, embedded in the bundle, as described in Apple's TN3125.
- A command-line tool cannot embed that profile, so only the app publishes a report. `token-taken` never writes one and keeps working without the container.
- Debug builds use empty entitlements and therefore have no container. The writer reports that state as unavailable instead of failing, and the app's own Debug runs never publish.
- Still unverified: a real-device round trip from a signed release Mac app to the sandboxed iOS app. If it fails, the document-picker fallback below applies.

## Alternatives

- **iOS reads the raw per-device sync files and recomputes:** rejected. It requires the phone to reimplement aggregation, coverage, staleness, zone placement, and pricing; it makes the phone download and validate many files across a multi-file, non-ordered publication; and it exposes per-device rows rather than the Mac's already-agreed merged view. The user's stated preference is the opposite: keep the phone light and fetch a finished report.
- **iOS folder chosen with a document picker and a stored security-scoped bookmark:** kept as a fallback if the shared container cannot be provisioned. Rejected as the default because it adds a manual folder-selection step on the phone, depends on the user choosing the right folder, and still has to handle revoked or moved bookmarks. The report format works unchanged under either access path.
- **CloudKit:** rejected for v1. It adds a second transport, record schema and versioning work, and CloudKit entitlements on both apps, while the data is a single small aggregate document that iCloud Documents already moves. It would also tempt account-scoped or ranking features into a display-only release.
- **Own server:** rejected. It needs an account system, hosting, and a new privacy surface for data that is currently device-local and opt-in. It would also conflict with the v1 network boundary in [privacy.md](../contracts/privacy.md).

## Consequences

- The Mac app needs an iCloud entitlement and a provisioning profile that carries the shared container, and the iOS app needs the same container declared. The capability table and the restricted-entitlement path are recorded under Verification; if the on-device round trip fails, the document-picker fallback applies.
- The phone's data is only as fresh as the generating Mac: it must be awake, online, and have iCloud Drive working, plus iCloud propagation latency. The 24-hour stale rule keeps that visible instead of hidden.
- A Mac that cannot read another Mac's sync folder publishes a report missing that device, and coverage names the missing device whenever its identity was readable at all. Two publishing Macs can therefore show different totals; the phone shows one report, not a sum.
- Hourly republication while the setting is on is an opt-in exception to the manual-first refresh policy in [architecture.md](../architecture.md). It stops when the setting is off.
- The report is usage-only, so the phone shows no cost. Pricing stays on the Mac under [statistics.md](../contracts/statistics.md).
- Anonymous ranking upload and any server-side benchmark are out of scope. They would send user data off-device and need their own ADR covering consent, payload, aggregation, and infrastructure.
