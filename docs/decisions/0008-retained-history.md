# ADR-0008: Retained history

## Status

Accepted (2026-11-12)

## Context

The store replaced every `daily_usage` row of a `(device, source)` with the new batch on each successful collection. Agents prune their own logs: Claude Code deletes transcripts older than 30 days, and tokscale's message cache drops a Claude transcript's entry once the file is gone and it holds nothing that the live file had lost. A day that had already been counted therefore shrank or vanished on the next scan. Measured on this machine, Claude 2026-10-12 fell from 24,069,630 to 5,580,911 tokens and 2026-10-13 from 55,105,152 to 37,794,947, a silent loss of 35,798,924 tokens with no evidence trail. Every other source has the same exposure: tokscale reports the live file set for all its clients except Claude's partial retention, and native collectors rebuild from files and database rows that the agent may have deleted.

## Decision

- Daily history is a floor. A collection never loses already-counted usage, and never counts the same usage twice.
- A day total is `input + cacheRead + cacheWrite + output + reasoning + uncategorized` summed over all model rows of that `(device, source, day)`.
- Normal merge, per day: a day present in both the batch and the store is replaced only when the batch total is not smaller. A smaller day keeps its stored rows whole, including every model row and `eventCount`; a stored day absent from the batch is kept; a day only in the batch is inserted. Stored and batch rows are never mixed within one day, so a model rename cannot leave a stale row behind.
- Rebaseline merge applies when the source's history epoch changed or a non-empty daily batch's collection time zone key (sorted distinct `timeZoneID` values joined by `,`) differs from the non-null stored collection zone for that device/source. With `E` the earliest day in the batch, days after `E` adopt the batch exactly and stored days after `E` that the batch no longer reports are deleted; days up to and including `E` keep the normal rule. When a non-empty daily batch is applied, the new epoch and collection zone key are stored.
- `TokenTakenKit/HistoryEpochs.swift` is the registry: every source starts at revision `1`, and tokscale-collected sources append the pinned engine version (`1+tokscale-4.21.0`). Raise a source's revision in a release that intentionally lowers or moves already-counted usage, such as a deduplication or date-attribution fix, or after upgrading the pinned engine.
- The applied epoch and collection time zone key are persisted per `(device_id, source_id)` in `history_epochs` (introduced in schema version 3, migrated in place from version 2; nullable `time_zone` added in schema version 6, migrated in place from version 5). A missing row means the first run after the upgrade: record the current epoch and zone key and use the normal merge, so existing data is protected immediately. A `NULL` `time_zone` on a row migrated to schema version 6 means no zone rebaseline on that run; record the new zone key instead.
- An epoch and zone key are applied and recorded only by a real collection with a non-empty daily batch. When the runner re-stores cached rows for unchanged inputs (or receives an empty daily batch with hourly rows) it neither rebaselines nor records the current epoch/zone, and every collector's collection stamp includes its sources' epochs, so a bump re-reads unchanged inputs once (added 2026-11-14 after build 28 recorded Devin's revision 3 without applying it).
- Hourly rows keep their snapshot semantics: the 48-hour window is replaced by each successful collection. Daily merge and hourly replacement share one transaction.
- `daily_usage` remains the resolved view, so readers, aggregation, CLI export and iCloud sync publication are unchanged.

## Consequences

- An agent pruning its logs can no longer shrink stored history. A deliberate downward correction needs an epoch bump; without one, no day is lowered automatically.
- A rebaseline only reaches days after the earliest day the batch still reports. Days at or before that date keep the higher stored total, so a correction that also removed its newest evidence stays a floor until an epoch bump accompanies a collection that still reports those days.
- A collection time-zone change rebaselines recent days instead of re-bucketing all history, so days at or before the earliest reported day keep their earlier labels and zone.
- The stored epoch is per device and source, so a rebuilt cache or a second Mac starts from the normal merge; an explicit user purge must delete the rows and their epoch together, otherwise the next collection keeps treating the surviving epoch as applied.
- `SourceHealth.recordCount` still reports the collected snapshot's row count, which can be smaller than the number of retained rows for a source whose logs were pruned.
