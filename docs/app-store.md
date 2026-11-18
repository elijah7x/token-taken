# App Store Submission Guide (Token Taken for iOS)

Reference checklist and App Store Connect answers for submitting **Token Taken** (`TokenTakenMobile`, bundle ID `io.github.elijah7x.TokenTaken.iOS`).

## 1. App Information

- **App Name:** Token Taken
- **Bundle ID:** `io.github.elijah7x.TokenTaken.iOS`
- **Platform:** iOS (`26.0`+, iPhone only, portrait orientation)
- **Primary Category suggestion:** Developer Tools (matches `public.app-category.developer-tools` on macOS)
- **Secondary Category suggestion:** Utilities or Productivity (`TODO (Elijah)`: choose preferred secondary category or leave unset)
- **Pricing & Availability:** `TODO (Elijah)`: set price (Free expected, no In-App Purchases) and distribution territories in App Store Connect.
- **Marketing Copy & Metadata:** `TODO (Elijah)`: finalize App Store subtitle, promotional text, description, keywords, and release notes in English (`en-US`) and Simplified Chinese (`zh-Hans`).

## 2. Required URLs

- **Privacy Policy URL (required):** Must resolve to a live, publicly accessible web page before submission.
  - The privacy policy text lives at [PRIVACY.md](../PRIVACY.md).
  - **Important:** The repository (`elijah7x/token-taken`) is currently private, so a raw GitHub link to `PRIVACY.md` will fail App Store Review validation until the repository is made public or `PRIVACY.md` is hosted at a public URL.
  - `TODO (Elijah)`: publish `PRIVACY.md` at a public URL (for example under `https://elijah.ac.cn/token-taken/...` or after making the repository public) and enter that URL in App Store Connect.
- **Support URL (required):** `TODO (Elijah)`: provide a live public support page or `https://github.com/elijah7x/token-taken/issues` once the repository is public.
- **Marketing URL (optional):** `TODO (Elijah)`: add if desired.

## 3. App Privacy ("Nutrition Label")

- **Do you or your third-party partners collect data from this app?**
  - **No, we do not collect data from this app** (**Data Not Collected**).
- **Reasoning (grounded in the iOS target code):**
  - `TokenTakenMobile` is display-only and contains no accounts, no analytics, no telemetry, no advertising SDKs, and no third-party crash reporting.
  - The app makes no outbound network requests to developer-operated or third-party servers. It only reads `Documents/mobile/v1/report-*.json` from the user's own iCloud Documents container (`iCloud.io.github.elijah7x.TokenTaken`) via Apple system APIs (`FileManager`, `NSMetadataQuery`, `NSFileCoordinator`), caches the decoded report locally in Application Support, and stores the sample-data toggle boolean (`TokenTakenDemoMode`) in `UserDefaults.standard`.
  - Share cards are rendered locally to PNG in the app's temporary directory and handed to the system `ShareLink` sheet without requesting Photo Library permission.
  - Under Apple's App Privacy definitions, data kept strictly on-device or in the user's private iCloud container (inaccessible to the developer) is not "collected".
- **Privacy Manifest (`ios/TokenTakenMobile/Resources/PrivacyInfo.xcprivacy`):**
  - `NSPrivacyTracking`: `false`
  - `NSPrivacyTrackingDomains`: empty
  - `NSPrivacyCollectedDataTypes`: empty
  - `NSPrivacyAccessedAPITypes`:
    - `NSPrivacyAccessedAPICategoryUserDefaults` — `CA92.1` (app-only `TokenTakenDemoMode` setting in `AppModel.swift`)
    - `NSPrivacyAccessedAPICategoryFileTimestamp` — `C617.1` (`NSMetadataItemFSContentChangeDateKey` sort descriptor in `ICloudReportSource.swift`)

## 4. Export Compliance

- **`Info.plist`:** `ITSAppUsesNonExemptEncryption` is set to `false` (`NO`).
- **App Store Connect question ("Does your app use encryption?"):**
  - Answer **No** (or **Yes, using only standard OS/Apple encryption exempt from export compliance documentation**, depending on the current App Store Connect wording).
  - **Reasoning:** The iOS app implements no custom cryptography and includes no third-party crypto libraries; it relies solely on Apple's iOS and iCloud system frameworks.
  - `TODO (Elijah)`: verify whether any French encryption declaration prompt appears in App Store Connect for your distribution regions.

## 5. Age Rating Questionnaire

Recommended answers (all **No / None**, resulting in **4+**):

- Cartoon or Fantasy Violence: None
- Realistic Violence: None
- Prolonged Graphic or Sadistic Realistic Violence: None
- Profanity or Crude Humor: None
- Mature or Suggestive Themes: None
- Horror or Fear Themes: None
- Medical or Treatment Information: None
- Alcohol, Tobacco, or Drug Use or References: None
- Simulated Gambling: None
- Sexual Content or Nudity: None
- Graphic Sexual Content and Nudity: None
- Unrestricted Web Access: No
- Gambling or Contests: No
- User-Generated Content / Messaging / Social features: No

`TODO (Elijah)`: verify against any newly added App Store Connect age-rating toggles at submission time.

## 6. App Review Notes

Paste and adapt the following in App Store Connect under **App Review Information > Notes**:

```text
Token Taken for iOS is a display-only companion app for Token Taken for macOS.

How it works:
- When a user enables "Sync to iPhone" in Token Taken on their Mac, the Mac app writes an aggregate-only JSON report to the user's private iCloud Documents container (iCloud.io.github.elijah7x.TokenTaken).
- The iPhone app reads that report from the same Apple ID's iCloud container and displays usage totals, monthly charts, harness breakdowns, Mac coverage status, and a shareable summary card.

How to review without a paired Mac:
- On launch without an existing iCloud report, the app presents an empty state with a "View sample data" button.
- Tap "View sample data" (or open Settings via the top-right gear icon and turn on "Demo mode") to inspect the complete dashboard, 12-month chart, harness breakdown, Mac coverage card, and Share Sheet card export using the bundled synthetic report.
- No account login or credentials are required.
```

- `TODO (Elijah)`: fill in App Review contact first/last name, phone number, and email address in App Store Connect.

## 7. iCloud Container & Capability Checklist

- **Container identifier:** `iCloud.io.github.elijah7x.TokenTaken`
- **Entitlements (`ios/TokenTakenMobile/TokenTakenMobile.entitlements`):**
  - `com.apple.developer.icloud-services`: `CloudDocuments`
  - `com.apple.developer.icloud-container-identifiers`: `iCloud.io.github.elijah7x.TokenTaken`
  - `com.apple.developer.ubiquity-container-identifiers`: `iCloud.io.github.elijah7x.TokenTaken`
- **`Info.plist`:**
  - `NSUbiquitousContainers` -> `iCloud.io.github.elijah7x.TokenTaken` (`NSUbiquitousContainerIsDocumentScopePublic = false`, `NSUbiquitousContainerSupportedFolderLevels = Any`)
- **Apple Developer Portal verification (`TODO (Elijah)`):**
  - [ ] Confirm App ID `io.github.elijah7x.TokenTaken.iOS` is registered under your Apple Developer Team with **iCloud** enabled (**Include CloudKit support** not required; **iCloud Documents** enabled).
  - [ ] Confirm container `iCloud.io.github.elijah7x.TokenTaken` is registered and assigned to **both** `io.github.elijah7x.TokenTaken.iOS` (iOS) and `io.github.elijah7x.TokenTaken` (macOS).
  - [ ] Exercise an end-to-end real-device test where a signed macOS build with **Sync to iPhone** enabled writes a report and the iOS TestFlight/device build reads it (still unverified per `docs/contracts/mobile-report.md` and `ios/README.md`).

## 8. `DEVELOPMENT_TEAM` Setup

`ios/project.yml` intentionally keeps `DEVELOPMENT_TEAM: ""` in git so no personal Apple Developer Team ID is published in the repository.

To configure signing locally before archiving for TestFlight / App Store Connect:

1. Generate the Xcode project:
   ```sh
   cd ios
   xcodegen generate --spec project.yml
   ```
2. Choose one of the following local-only options (do not commit your Team ID):
   - **Xcode GUI:** Open `ios/TokenTakenMobile.xcodeproj`, select the **TokenTakenMobile** target -> **Signing & Capabilities**, and pick your Team.
   - **CLI build/archive:** Pass `DEVELOPMENT_TEAM=<YOUR_TEAM_ID>` to `xcodebuild`, or supply an untracked `.xcconfig` outside git via `-xcconfig`.
3. Confirm `MARKETING_VERSION` (`0.1.0`) and `CURRENT_PROJECT_VERSION` (`1`) in `ios/project.yml` match your App Store Connect build record before uploading.

## 9. Screenshot & Asset Checklist

- **App Icon:** `AppIcon-1024.png` is present in `ios/TokenTakenMobile/Resources/Assets.xcassets/AppIcon.appiconset/` (`TODO (Elijah)`: do a final visual check in Xcode Archive / TestFlight).
- **Screenshots (`TODO (Elijah)`):**
  - App is iPhone-only (`TARGETED_DEVICE_FAMILY = 1`, portrait-only), so iPad screenshots are not required.
  - Capture portrait iPhone screenshots at App Store Connect's required 6.9" display size (and 6.5" if requested by App Store Connect) in both **English** and **Simplified Chinese** (using Demo mode or a real Mac report):
    1. Home screen top (Last 30 days hero, rank estimate, Today / This month / All time card, Last 12 months bar chart).
    2. Home screen lower section (Harnesses this month + Macs in this report coverage).
    3. Share sheet preview (`ShareSheetView` rendered card).
    4. Empty state or Settings view (optional, showing Demo mode & ranking methodology).
