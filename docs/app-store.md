# App Store Submission Guide (Token Taken for iOS)

Reference checklist and App Store Connect answers for submitting **Token Taken** (`TokenTakenMobile`, bundle ID `io.github.elijah7x.TokenTaken.iOS`).

## 1. App Information

- **App Name:** Token Taken
- **Bundle ID:** `io.github.elijah7x.TokenTaken.iOS`
- **Platform:** iOS (`26.0`+, iPhone only, portrait orientation)
- **Primary Category:** Developer Tools (matches `public.app-category.developer-tools` on macOS)
- **Secondary Category:** Productivity
- **Pricing & Availability:** Free, no In-App Purchases.
  - **Territories:** All App Store territories except China mainland for the first release, because App Store distribution in China mainland requires an app ICP filing number (revisit when one exists).
- **Marketing Copy & Metadata:** Finalized in Section 10 below (`en-US` and `zh-Hans`).

## 2. Required URLs

- **Privacy Policy URL (required):** `https://github.com/elijah7x/token-taken/blob/main/PRIVACY.md`
  - The repository (`github.com/elijah7x/token-taken`) is now public. This link points to [PRIVACY.md](../PRIVACY.md) and will be live once the `launch-fixes` branch is merged and pushed to `main`.
  - **Note on `elijah.ac.cn`:** The iOS app makes no update-feed requests (and no requests to `elijah.ac.cn` or any developer-operated server). `elijah.ac.cn` is only one of two update sources used by release builds of the Mac app, and the Mac app works with GitHub Releases alone.
- **Support URL (required):** `https://github.com/elijah7x/token-taken/issues`
- **Marketing URL (optional):** `https://github.com/elijah7x/token-taken`

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
  - **Reasoning:** The iOS app implements no custom cryptography and includes no third-party crypto libraries; it relies solely on Apple-provided HTTPS and iCloud system frameworks (`ITSAppUsesNonExemptEncryption = NO`), and no French encryption declaration is needed.

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

Confirm against any newly added App Store Connect age-rating toggles at submission time; all items above are **No / None** (**4+**).

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

## 8. `DEVELOPMENT_TEAM` Setup (`TODO (Elijah)`)

`ios/project.yml` intentionally keeps `DEVELOPMENT_TEAM: ""` in git so no personal Apple Developer Team ID is published in the repository.

To configure signing locally before archiving for TestFlight / App Store Connect (`TODO (Elijah)`):

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

- **App Icon:** `AppIcon-1024.png` is present in `ios/TokenTakenMobile/Resources/Assets.xcassets/AppIcon.appiconset/` (confirm visually in Xcode Archive / TestFlight when capturing screenshots).
- **Screenshots (`TODO (Elijah)`):**
  - App is iPhone-only (`TARGETED_DEVICE_FAMILY = 1`, portrait-only), so iPad screenshots are not required.
  - Capture portrait iPhone screenshots at App Store Connect's required 6.9" display size (and 6.5" if requested by App Store Connect) in both **English** and **Simplified Chinese** (using Demo mode or a real Mac report):
    1. Home screen top (Last 30 days hero, rank estimate, Today / This month / All time card, Last 12 months bar chart).
    2. Home screen lower section (Harnesses this month + Macs in this report coverage).
    3. Share sheet preview (`ShareSheetView` rendered card).
    4. Empty state or Settings view (optional, showing Demo mode & ranking methodology).

## 10. App Store Metadata (`en-US` and `zh-Hans`)

### English (`en-US`)

- **App Name:** `Token Taken`
- **Subtitle (25/30 chars):** `AI Coding Token Companion`
- **Promotional Text (166/170 chars):**
  `View AI coding-agent token totals published from your Mac via your own iCloud—today, this month, last 12 months, and shareable summary cards. Try sample data anytime.`
- **Keywords (92/100 chars):**
  `ai,coding,agent,usage,tracker,llm,developer,tools,icloud,companion,stats,metrics,summary,mac`
- **Description (1092 chars):**

```text
Token Taken for iPhone is a display-only companion app for Token Taken on macOS. It shows the aggregate usage report that your Mac publishes to your own iCloud account—no Token Taken account, server, or manual import needed.

Check your token totals for today, this month, the last 30 days, and all time. Review a 12-month bar chart, see which coding-agent harnesses contributed this month, and check which Macs are included in the report. An estimated 30-day usage rank based on public usage references is also shown.

Export a Liquid Glass summary card as an image using the system share sheet. If you have not enabled Sync to iPhone on a Mac yet, tap View sample data to explore every screen with built-in demo data.

Token Taken for iPhone does not collect local logs, calculate costs, or send data to developer servers. It reads only the aggregate report stored in your own iCloud container under the same Apple ID, with no prompts, responses, file paths, project names, or credentials. Requires Token Taken on macOS with Sync to iPhone enabled and the same Apple ID signed in to iCloud.
```

- **What's New (Version 1.0):**

```text
Initial release of Token Taken for iPhone. View aggregate AI coding-agent token totals synced from Token Taken on your Mac via your own iCloud, inspect your 12-month chart, monthly harness breakdown, and included Macs, share a Liquid Glass summary card, or explore with built-in sample data.
```

### Simplified Chinese (`zh-Hans`)

- **App Name:** `Token Taken`
- **Subtitle (14/30 chars):** `Mac Token 用量伴侣`
- **Promotional Text (90/170 chars):**
  `通过自己的 iCloud 随时查看 Mac 版 Token Taken 同步的 AI 编程 Token 用量：今日、本月、近 12 个月趋势与分享卡片，并支持内置示例数据直接体验。`
- **Keywords (48/100 chars):**
  `AI,编程,用量,统计,开发者,效率,iCloud,伴侣,工具,大模型,代码,助手,摘要,Mac`
- **Description (501 chars):**

```text
Token Taken iPhone 版是 macOS 应用 Token Taken 的纯展示伴侣。它会直接读取你的 Mac 发布到个人 iCloud 的聚合用量报表，无需注册账号、无需第三方服务器，也无需手动导入文件。

在手机上随时查看今日、本月、近 30 天与累计 Token 总量，浏览近 12 个月用量柱状图、本月各编程工具明细，以及这份报表当前包含哪些 Mac。应用也会结合公开用量参考数据展示近 30 天的估算排名。

你可以将统计结果渲染为 Liquid Glass 分享卡片，并通过系统分享面板保存或发送。如果还没有在 Mac 上开启「同步到 iPhone」，也可以直接点击「查看示例数据」，用内置演示报表体验完整界面与分享卡功能。

Token Taken iPhone 版不会在手机端采集日志、估算费用或向开发者服务器上传数据。它仅从同一 Apple ID 下的个人 iCloud 容器读取聚合后的用量摘要，不包含提示词、回复内容、文件路径、项目名称或任何凭据。使用真实数据需配合开启了「同步到 iPhone」且登录同一 Apple ID 的 Mac 版 Token Taken。
```

- **What's New (Version 1.0):**

```text
Token Taken iPhone 版首个正式版本发布。通过你自己的 iCloud 查看由 Mac 版 Token Taken 同步的聚合 Token 用量，浏览近 12 个月趋势柱状图、本月工具明细与已包含的 Mac 列表，生成 Liquid Glass 分享卡片，或使用内置示例数据直接体验。
```

## 11. Final Remaining Steps (In Order)

Only these `TODO` items remain before submitting in App Store Connect:

1. **Configure `DEVELOPMENT_TEAM` locally** in Xcode (**Signing & Capabilities**), via `xcodebuild DEVELOPMENT_TEAM=<YOUR_TEAM_ID>`, or an untracked `.xcconfig` (Section 8).
2. **Verify Apple Developer Portal iCloud container & end-to-end sync** for `iCloud.io.github.elijah7x.TokenTaken` across `io.github.elijah7x.TokenTaken.iOS` and `io.github.elijah7x.TokenTaken` on real signed builds (Section 7).
3. **Capture final App Store screenshots** in `en-US` and `zh-Hans` at the required iPhone portrait sizes (Section 9).
4. **Fill in App Review contact name, phone number, and email** in App Store Connect (Section 6) and submit once `launch-fixes` is merged to `main` so the Privacy Policy URL resolves publicly.
