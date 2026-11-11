# ADR-0006: Incremental collection

## Status

Accepted (2026-11-11)

## Context

Every refresh rescanned all agent logs: about 14 s and a 245 MB memory peak on a typical machine, most of it pi and omp JSONL, a Zcode database backup, and tokscale runs. Refresh is manual-first (ADR-0005, architecture refresh policy), so this delay is felt on every use.

## Decision

- Each collector keeps a small local state file under `collector-state/` in the support directory. It is never synced or exported.
- Every state carries a stamp of the viewer time zone, a collector format version, and (for tokscale) the pinned engine version. A mismatch or unreadable state means a full collection.
- pi and omp record per-file inode, size, modification time, the offset after the last complete line, and the compact per-event data the existing dedupe and aggregation need. Unchanged files reuse cached events, grown files are parsed from the saved offset, and anything else is reparsed. Output is rebuilt from all events, so it equals a full scan.
- Zcode compares fingerprints of the database and its `-wal` and `-shm` files and skips the backup when they match.
- tokscale fingerprints each client's inputs with a metadata-only walk (file count, total size, latest modification) and runs `graph` and `hourly` only for changed clients.
- A collector reports untouched sources in `CollectionBatch.unchangedSourceIDs`. The runner re-stores their cached rows through the normal path, so the 48-hour hourly window and zero coverage advance as after a fresh collection.
- New state is written through `CollectionBatch.stateCommits` only after every source of the batch was stored. Failures leave the previous state, so the next refresh collects again.

## Consequences

- A routine refresh takes well under a second for unchanged sources. The first refresh after install, an engine upgrade, a time-zone change or a format change is a full collection.
- tokscale change detection relies on its known input locations for 4.21.0. Upgrading the engine changes the stamp; any new input location must be added to the fingerprint roots.
- A file rewritten in place with identical size and modification time would be missed. Agents append to their logs, so this is accepted.
