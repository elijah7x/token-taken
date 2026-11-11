Status: Draft v0 (2026-11-09)

# Privacy contract

## Local-first collection

- Usage data is collected and stored locally first in `~/Library/Application Support/Token Taken/`; a network connection is not required for local statistics.
- Agent logs, databases, configuration, and credentials are read-only inputs. The app, engine adapter, and CLI MUST NOT modify, move, or delete them.
- Collection MUST be limited to the locations and APIs required for enabled sources. Enabling sync does not enable additional source collection.

## Network boundaries

- The price table is bundled with the app. v1 makes no network request to fetch or refresh prices; a new table ships with a new release ([statistics.md](statistics.md)).
- v1 network access is allowed only for:
  - account-scoped source APIs after explicit opt-in for that source; and
  - iCloud Drive through system services after sync opt-in.
- No other outbound product traffic is permitted in v1. Engine behavior MUST NOT bypass these boundaries.
- There MUST be no telemetry, analytics, or third-party crash reporting.
- Account API access and iCloud sync are independent choices; enabling one MUST NOT implicitly enable the other.

## Credentials and output

- Any credential required by a source MUST be stored in Keychain. Credentials MUST NOT enter the local usage store, sync files, logs, CLI output, exports, or fixtures.
- App logs, CLI output, and exports MUST NOT contain prompts, responses, or file paths.
- Errors shown to users should identify the affected source and operation without echoing sensitive record contents.
- Source-reported cost may be stored locally where supported, but MUST NOT be synced; sync restrictions are defined in [sync.md](sync.md).

## Fixture policy

- Repository fixtures MUST be synthetic or sanitized. Sanitization MUST remove conversation content, credentials, personal identifiers, file paths, and project or repository names while preserving the fields needed for reconciliation.
- Raw usage samples live only in the artifact root's `private-artifacts/samples/`, outside the repository.
- Raw samples MUST NOT be committed, packaged, exported, or synced. Public-repository fixtures MUST be traceable to their synthetic source or sanitization procedure.

## Open questions

- Account-scoped API endpoints, credential types, and per-source permission prompts: TBD after engine spike (ADR-0003).
