# ADR-0010: Cursor account usage and account devices

## Status

Accepted (2026-11-12)

## Context

- Cursor's token usage is not on this Mac. Its own CSV export behind `cursor.com` is the only source, and every Mac signed into the same account downloads the same rows. An audit of one account on 2026-11-12 measured 2,407,805,725 tokens over 2026-08-04..2026-10-13 that Token Taken could not see at all.
- The sync layout attributes every row to the folder's one writer, and `MergedUsageStore` adds device folders together. Two Macs collecting the same account would therefore count it twice, with no way to tell the copies apart afterwards.
- `docs/contracts/sync.md` and `docs/contracts/statistics.md` forbid approximating account-level identity from `(source, day, model)` keys. That rule protects device-local sources whose rows only look alike; it does not describe data that has exactly one true value per account.
- The pinned engine reads Cursor only from a cached account export that needs Cursor credentials, and [ADR-0003](0003-usage-engine.md) left the source deferred rather than shipping a client that needs an account session.

## Decision

1. **Opt-in native collector.** `CursorCollector` is native Swift, off by default (`AppSettings.cursorAccountCollection`), and makes one network request per collection: `GET https://cursor.com/api/dashboard/export-usage-events-csv?strategy=tokens`, the account's whole history, 90-second timeout, one same-origin redirect, no date parameters and no pagination. The engine is still never asked for Cursor, so the same account cannot be collected twice.
2. **Credentials stay on this Mac.** The collector reads Cursor's own sign-in from `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (`ItemTable`, key `cursorAuth/accessToken`) through a direct read-only connection (never `immutable=1`; a private backup copy is made only if the WAL `-shm` file cannot be opened), plus the account identifier from `~/.cursor/cli-config.json`; both are used in memory only. They never enter the store, sync output, health messages, or logs. A value marked `cursor-safe-storage:` is treated as no session: no Keychain decryption is attempted.
3. **Account devices.** A new device kind distinguishes `mac` from `account`. Cursor rows are written to a synthetic device whose id is a domain-separated hash of the local account identifier (`account-cursor-<hash32>`); the identifier itself, the email, the host name, and the token never appear in an id or in sync output. The device is labelled as an account, never as this Mac or another one, and its share of a Mac-versus-Mac breakdown is not computed.
4. **Local-day labels.** Cursor rows keep the collecting Mac's local calendar day and record its IANA `timeZoneID`, like every other source. Only Macs that share a time zone produce identical labels; the deduplication below does not depend on labels matching.
5. **One whole publication per account.** Each Mac still writes only its own `v1/devices/<macId>/` folder, and publishes the account's rows as an additional record kind inside it, so the single-writer rule holds. On read, the account's publications collapse to one whole snapshot: the one collected most recently wins, a tie keeps this Mac's own copy, and a remaining tie is broken by publisher id. Rows are never merged column by column, because a synthesized row would price tokens that no collection ever measured.
6. **Authoritative export merge.** The export is a snapshot of the account, not a prunable local log, so a complete export is authoritative for every day from its earliest day onwards: those days adopt the export exactly, including downward corrections, and days before it keep their stored values. An empty, incomplete, or unparsable export writes nothing and leaves the previous history and health intact. This is a narrow exception to [ADR-0008](0008-retained-history.md), recorded in `docs/contracts/statistics.md`.
7. **Reconciliation anchor.** Before claiming coverage, compare the collected rows against the TokenTracker rows already on this Mac (`~/.tokentracker/tracker/queue.jsonl`, `source="cursor"`) folded to local days per model. `input`, `cacheRead`, and `output` must match token for token over the shared window; `cacheWrite` may differ by the CSV's two input columns not matching the provider's cache-write figure, and every difference must sit on such an event. Nothing is read from TokenTracker at runtime.

## Consequences

- The 2.4B tokens Cursor reported become visible, and two Macs on one account count it once.
- Device-local sources keep their existing attribution and still are never cross-device deduplicated, so the contracts' protection for them is unchanged.
- The account's true value assumes the same parser and model normalization on every publishing Mac. Macs on different app versions can leave two rows for one `(day, model)` and count both; the UI shows no version claim and this risk stays open rather than being hidden by fuzzy matching.
- iCloud holds one copy of the account's history per signed-in Mac. Acceptable for now; the volume is the same order as the history itself.
- Costs use the local price table only, never the CSV's `Cost` column, which is provider billing rather than token cost. Cursor's own models may stay unpriced.
- `cacheWrite` is the difference between the CSV's two input columns, which differs from the provider's own cache-write field on a small number of events.
- Turning the setting off stops collection; stored account rows stay and are no longer replaced.

## Alternatives rejected

- **Per-row deduplication with UTC day labels (the TokenTracker shape).** The same rule ported to UTC labels would also collapse rows, but UTC labels move a local-day user's evening usage onto the previous day and break the contract that daily records carry their collecting zone. Whole-publication selection at read time gets the same single count without changing how days are labelled, and it also handles Cursor revising a day downward.
- **A shared account folder that every Mac writes.** It would save duplicate payloads but needs cross-device write coordination that iCloud Drive has no lock for, and it breaks the one-writer-per-folder rule.
- **Keeping Cursor deferred.** Leaves a measured 2.4B tokens invisible indefinitely.
- **Session-level last-writer-wins (the `trae-cn` approach).** Cursor exports carry no stable session id, so there is no session to compare.
- **Requesting Cursor from the pinned engine.** The engine reads a cached account export and needs the same credentials, so it would collect the same account a second time.
