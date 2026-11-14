# Token Taken for iOS

Companion iPhone app for Token Taken. It does no collection and no pricing: it reads the
report the Mac app writes to iCloud and presents it. Every screen has a working empty state,
so the app is useful the moment the Mac side turns on "Sync to iPhone".

## Generate the project

```sh
brew install xcodegen        # once
xcodegen generate --spec project.yml
open TokenTakenMobile.xcodeproj
```

Signing is automatic with an empty `DEVELOPMENT_TEAM`. Set your team in Xcode (Signing &
Capabilities) or in `project.yml` before building on a device. The simulator has no iCloud
container, so use **View sample data** there, or the bundled demo report.

- Target: `TokenTakenMobile` (iOS 26.0, Swift 6, iPhone only)
- Bundle id: `io.github.elijah7x.TokenTaken.iOS`
- iCloud container: `iCloud.io.github.elijah7x.TokenTaken` (shared with the Mac app)

## Layout

```
project.yml                              XcodeGen spec
TokenTakenMobile/
  App/        TokenTakenMobileApp.swift  @main, AppModel (@Observable state, demo toggle)
  Model/      Ranking.swift              rank wording (curve lives in Shared/UsageRank.swift)
              Comparisons.swift          comparisons.json loader and picker
              TokenFormat.swift          K/M/B and 万/亿 formatting (ported from macOS)
              ReportText.swift           month/day/relative-date/percent text
  Data/       ReportSource.swift         ReportSource protocol, states, Application Support cache
              ICloudReportSource.swift   container URL, NSMetadataQuery, download wait, coordinated read
              DemoReportSource.swift     bundled demo report
  Views/      RootView, HomeView, HomeView sections, SettingsView, EmptyStateView
  Share/      ShareCardView.swift        1080x1350 card layout
              LiquidGlassVessel.swift    Canvas vessel drawing (iOS port, no glassEffect)
              Palette.swift              colors + UIColor mixing
              ShareCardRenderer.swift    ImageRenderer at scale 2 -> PNG
              ShareSheetView.swift       preview + ShareLink
  Resources/  demo-report.json, comparisons.json, Localizable.xcstrings, Assets.xcassets
  Info.plist, TokenTakenMobile.entitlements
```

The report model is `Shared/MobileReport.swift` at the repository root, compiled into both this
app and `TokenTakenKit`; this app adds no copy of it.

`Resources/comparisons.json` is not generated with the project scaffold; the loader treats a
missing file as "hide the comparison line", so the app builds and runs without it.

## Data contract

The Mac app owns collection and writes one report per device:

```
<container>/Documents/mobile/v1/report-<deviceId>.json
```

Schema v1 (`token-taken.mobile-report`) is defined in `docs/contracts/mobile-report.md` in this
repository, and its model is `Shared/MobileReport.swift` at the repository root. Reading rules
implemented here:

- Unknown keys are ignored; a different `schemaVersion` or `kind` is rejected as `decodeFailed`.
- Dates are ISO 8601 with or without fractional seconds.
- A report whose `generatedAt` is more than 24 hours old loads as `stale` (still shown).
- A load result is one of `ok`, `stale`, `noReport`, `iCloudUnavailable`, `decodeFailed`.
  A failed refresh keeps the last good report on screen and only changes the state.
- The last good report is cached in `Application Support/TokenTakenMobile/mobile-report-v1.json`
  and shown immediately on launch, before iCloud answers.
- Reload happens on launch, whenever the scene becomes active, and on pull to refresh.
  `NSUbiquityIdentityDidChange` clears the cache and reloads, because the cached copy may
  belong to a previous iCloud account.

Ranking uses the shared `UsageRank` curve in `Shared/UsageRank.swift` (version
`rank-curve-2026-11`) on `totals.last30Days.total`; `Model/Ranking.swift` holds only the wording,
and every line is phrased as an estimate. With no tokens in the last 30 days there is no rank line.

## Share card

`ShareCardView` is a fixed 1080x1350 light-mode canvas: wordmark, period, last-30-days tokens,
rank line, one comparison line, footnote, and the liquid-glass vessel whose fill is
`last30Days / allTime`. It is rendered with `ImageRenderer` at scale 2 (2160x2700) and shared
as a PNG file through `ShareLink`. Saving to Photos happens inside the system share sheet, so
no photo-library permission is requested.

## Known unverified points

- **Container access is recorded, not yet exercised on a device.** ADR-0011 records that a
  Developer ID Mac app can hold iCloud Documents and that the container entitlement needs a
  Developer ID provisioning profile embedded in the Mac bundle (TN3125). Both apps still need
  the same container provisioned in the developer account. Until a report written by a signed
  Mac app is read on a device, `ICloudReportSource` may return `iCloudUnavailable`.
- `NSMetadataQuery` on `NSMetadataQueryUbiquitousDocumentsScope`, the 10s per-file download
  wait, and the `Documents/mobile/v1` path filter are written from the API contract but have
  not been exercised against a real Mac-written report.
- `demo-report.json` is a synthetic fixed snapshot ending 2026-11-12; the demo source skips
  the 24h staleness rule so sample data never looks broken.
- No app icon artwork yet (the catalog has an empty 1024 slot), and there are no automated
  tests in this target.
