Status: Implemented v1 (2026-11-14)

# Privacy contract

## Local-first collection

- Usage data is collected and stored locally first in `~/Library/Application Support/Token Taken/`; a network connection is not required for local statistics.
- Agent logs, databases, configuration, and credentials are read-only inputs. The app, engine adapter, and CLI MUST NOT modify, move, or delete them.
- Collection MUST be limited to the locations and APIs required for enabled sources. Enabling sync does not enable additional source collection.

## Network boundaries

- The price table is bundled with the app. v1 makes no network request to fetch or refresh prices; a new table ships with a new release ([statistics.md](statistics.md)).
- v1 network access is allowed only for:
  - account-scoped source APIs after explicit opt-in for that source;
  - iCloud Drive through system services after sync opt-in; and
  - update checks and verified DMG downloads as bounded below.
- Automatic updates are controlled by the **Keep Token Taken up to date automatically** setting (enabled by default):
  - When on, the app checks for updates 15 seconds after launch, every 6 hours, and on app activation when the last check is more than 6 hours old.
  - When off, the app MUST NOT make automatic or background update requests; manual **Check for Updates** in Settings > About remains available on user action.
  - Debug and ad-hoc builds MUST NOT perform automatic update checks or install updates.
- Update requests are restricted to:
  - an HTTPS `GET` to the static update feed `https://elijah.ac.cn/token-taken/updates.json`, with fallback to the GitHub Releases API for `elijah7x/token-taken`; and
  - an HTTPS `GET` to download the release DMG from the feed's `download_url`, restricted to `https` URLs on the allowed hosts `elijah.ac.cn`, `github.com`, `objects.githubusercontent.com`, and `release-assets.githubusercontent.com`.
- Data leaving the machine on update requests is limited strictly to standard HTTPS request headers plus `User-Agent: TokenTaken/<version>` (and standard transport metadata inherent to HTTPS). Update requests MUST NOT send device identifiers, hardware identifiers, user identifiers, usage data, or account data.
- Downloaded updates MUST pass byte-size and SHA-256 verification against the feed, strict `(version, build)` progression with no rollbacks, code-signature validation for `io.github.elijah7x.TokenTaken` signed by the running app's Developer ID team, version/build matching against the feed, and Gatekeeper assessment before installation.
- No other outbound product traffic is permitted in v1. Engine behavior MUST NOT bypass these boundaries.
- There MUST be no telemetry, analytics, or third-party crash reporting.
- Account API access and iCloud sync are independent choices; enabling one MUST NOT implicitly enable the other.

## Credentials and output

- Any credential required by a source MUST be stored in Keychain. Credentials MUST NOT enter the local usage store, sync files, logs, CLI output, exports, or fixtures.
- Where an opt-in account source reads a supported client's existing session (such as Cursor), Token Taken reads it read-only in memory only and MUST NOT store, sync, or log it (see [ADR-0010](../decisions/0010-cursor-account-usage.md)).
- App logs, CLI output, and exports MUST NOT contain prompts, responses, or file paths.
- Errors shown to users should identify the affected source and operation without echoing sensitive record contents.
- Source-reported cost may be stored locally where supported, but MUST NOT be synced; sync restrictions are defined in [sync.md](sync.md).

## Fixture policy

- Repository fixtures MUST be synthetic or sanitized. Sanitization MUST remove conversation content, credentials, personal identifiers, file paths, and project or repository names while preserving the fields needed for reconciliation.
- Raw usage samples live only in the artifact root's `private-artifacts/samples/`, outside the repository.
- Raw samples MUST NOT be committed, packaged, exported, or synced. Public-repository fixtures MUST be traceable to their synthetic source or sanitization procedure.

## Open questions

- None.
