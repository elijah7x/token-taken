import Foundation

public actor CollectionRunner {
    private let store: SQLiteUsageStore
    private let device: Device
    private let collectors: [any UsageCollector]

    public init(store: SQLiteUsageStore, device: Device, collectors: [any UsageCollector]) {
        self.store = store
        self.device = device
        self.collectors = collectors
    }

    public func runAll(now: Date = .now) async -> [SourceHealth] {
        let previous: [String: SourceHealth]
        // Every device's rows, so an account-scoped source can read back the rows it stored under the account id.
        let cachedDaily: [UsageRecord]
        let cachedHourly: [HourlyUsage]
        do {
            try store.upsert(device: device)
            previous = Dictionary(try store.health().map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
            cachedDaily = try store.records()
            cachedHourly = try store.hourly()
        } catch {
            let message = Self.sanitizeErrorMessage(Self.message(for: error))
            return collectors.flatMap(\.sourceIDs).map {
                SourceHealth(sourceID: $0, lastAttempt: now, errorMessage: message, state: .failed)
            }
        }
        let outcomes = await collectAll()
        // An account-scoped collector reports the device its rows belong to: the account, not this Mac (ADR-0010).
        var accountDevices: [String: Device] = [:]
        var accountUpsertErrors: [String: String] = [:]
        for (collector, outcome) in zip(collectors, outcomes) {
            guard let accountDevice = outcome.batch?.accountDevice else { continue }
            let message: String?
            do {
                try store.upsert(device: accountDevice)
                message = nil
            } catch {
                message = Self.message(for: error)
            }
            for sourceID in collector.sourceIDs {
                accountDevices[sourceID] = accountDevice
                if let message { accountUpsertErrors[sourceID] = message }
            }
        }
        var results: [SourceHealth] = []
        for (collector, outcome) in zip(collectors, outcomes) {
            var allStored = outcome.batch != nil
            for sourceID in collector.sourceIDs {
                let existing = previous[sourceID]
                let targetDeviceID = accountDevices[sourceID]?.id ?? device.id
                let cached = cachedDaily.filter { $0.deviceID == targetDeviceID && $0.sourceID == sourceID }
                let cachedHourlyRows = cachedHourly.filter { $0.deviceID == targetDeviceID && $0.sourceID == sourceID }
                let cachedCount = cached.count
                // "Unavailable" protects cached data; a missing source with nothing cached is simply not installed,
                // even if an older build recorded a successful empty collection for it.
                let hasHistory = cachedCount > 0 || !cachedHourlyRows.isEmpty
                var health: SourceHealth
                if let message = accountUpsertErrors[sourceID] {
                    health = failedHealth(sourceID: sourceID, existing: existing, cachedRecordCount: cachedCount,
                        now: now, message: message, state: .failed)
                } else if let batch = outcome.batch {
                    if batch.unchangedSourceIDs.contains(sourceID) {
                        // Unchanged inputs: the cached rows are the full-scan result; re-store them so the hourly
                        // window and zero-coverage rows advance exactly as a fresh collection would.
                        let skipped = existing?.skippedRecords ?? 0
                        let cachedBatch = CollectionBatch(
                            daily: cached,
                            hourly: cachedHourlyRows,
                            skippedRecords: skipped
                        )
                        do {
                            let scoped = sourceBatch(cachedBatch, sourceID: sourceID, deviceID: targetDeviceID, now: now)
                            try store.replace(batch: scoped, sourceID: sourceID, deviceID: targetDeviceID)
                            health = SourceHealth(sourceID: sourceID, lastAttempt: now, lastSuccess: now,
                                recordCount: scoped.daily.count, skippedRecords: skipped)
                        } catch {
                            health = failedHealth(sourceID: sourceID, existing: existing, cachedRecordCount: cachedCount,
                                now: now, message: Self.message(for: error), state: .failed)
                        }
                    } else if batch.unavailableSourceIDs.contains(sourceID) {
                        health = unavailableHealth(
                            sourceID: sourceID, existing: existing, cachedRecordCount: cachedCount,
                            hasHistory: hasHistory, now: now,
                            message: CollectorError.sourceUnavailable.errorDescription ?? "Source data is unavailable"
                        )
                    } else if let message = batch.failedSourceIDs[sourceID] {
                        health = failedHealth(sourceID: sourceID, existing: existing, cachedRecordCount: cachedCount,
                            now: now, message: message, state: .failed)
                    } else if !batch.daily.contains(where: { $0.sourceID == sourceID })
                        && !batch.hourly.contains(where: { $0.sourceID == sourceID }) {
                        // An installed source with no usage yet is healthy. Once it has history, an empty
                        // result is treated as a failure so a parser regression cannot erase stored usage.
                        health = hasHistory
                            ? failedHealth(sourceID: sourceID, existing: existing, cachedRecordCount: cachedCount,
                                now: now, message: "Collection produced no source data", state: .failed)
                            : SourceHealth(sourceID: sourceID, lastAttempt: now, lastSuccess: now,
                                recordCount: 0, skippedRecords: 0)
                    } else {
                        do {
                            let scoped = sourceBatch(batch, sourceID: sourceID, deviceID: targetDeviceID, now: now)
                            try store.replace(batch: scoped, sourceID: sourceID, deviceID: targetDeviceID,
                                authoritative: batch.authoritativeSourceIDs.contains(sourceID))
                            health = SourceHealth(sourceID: sourceID, lastAttempt: now, lastSuccess: now,
                                recordCount: scoped.daily.count, skippedRecords: batch.skippedRecords)
                        } catch {
                            health = failedHealth(sourceID: sourceID, existing: existing, cachedRecordCount: cachedCount,
                                now: now, message: Self.message(for: error), state: .failed)
                        }
                    }
                } else if outcome.unavailable {
                    health = unavailableHealth(
                        sourceID: sourceID, existing: existing, cachedRecordCount: cachedCount,
                        hasHistory: hasHistory, now: now,
                        message: outcome.errorMessage ?? "Source data is unavailable"
                    )
                } else {
                    health = failedHealth(sourceID: sourceID, existing: existing, cachedRecordCount: cachedCount,
                        now: now, message: outcome.errorMessage ?? "Collection failed", state: .failed)
                }
                if let errorMessage = health.errorMessage {
                    health.errorMessage = Self.sanitizeErrorMessage(errorMessage)
                }
                // Unavailable sources keep their cache and are left out of collector state, so they do not block it.
                if health.state == .failed { allStored = false }
                do {
                    try store.record(health: health)
                } catch {
                    let prior = health.errorMessage.map { $0 + "; " } ?? ""
                    health.errorMessage = Self.sanitizeErrorMessage(
                        prior + "Could not persist source health: " + Self.message(for: error)
                    )
                    health.state = .failed
                }
                results.append(health)
            }
            if allStored, let commits = outcome.batch?.stateCommits {
                // A failed commit only costs a full collection next time.
                for commit in commits { try? commit() }
            }
        }
        return results
    }

    private func sourceBatch(_ batch: CollectionBatch, sourceID: String, deviceID: String, now: Date) -> CollectionBatch {
        let calendar = Calendar.current
        let currentHour = calendar.dateInterval(of: .hour, for: now)!.start
        let cutoff = currentHour.addingTimeInterval(-47 * 3_600)
        var hours = Dictionary(grouping: batch.hourly.filter {
            $0.sourceID == sourceID && $0.hourStart >= cutoff && $0.hourStart <= currentHour
        }, by: \.hourStart).mapValues { rows in
            var row = rows[0]
            for other in rows.dropFirst() {
                row.counts += other.counts
                row.eventCount += other.eventCount
                row.reasoningKnown = row.reasoningKnown && other.reasoningKnown
            }
            return row
        }
        // Persist coverage as zero rows only after a complete successful read, never after a failure.
        if batch.skippedRecords == 0 {
            for offset in 0..<48 {
                let start = currentHour.addingTimeInterval(Double(-offset) * 3_600)
                if hours[start] == nil {
                    hours[start] = HourlyUsage(hourStart: start, deviceID: deviceID, sourceID: sourceID,
                        counts: .zero, eventCount: 0,
                        reasoningKnown: ["zcode", "pi", "omp", "antigravity", "mcode", "cursor"].contains(sourceID))
                }
            }
        }
        return CollectionBatch(daily: batch.daily.filter { $0.sourceID == sourceID },
            hourly: hours.values.sorted { $0.hourStart < $1.hourStart }, skippedRecords: batch.skippedRecords)
    }

    private func collectAll() async -> [Outcome] {
        let collectors = collectors
        return await withTaskGroup(of: Outcome.self) { group in
            for (index, collector) in collectors.enumerated() {
                group.addTask {
                    do {
                        return try await Outcome(index: index, batch: collector.collect(), errorMessage: nil, unavailable: false)
                    } catch {
                        let unavailable: Bool
                        if let error = error as? CollectorError, case .sourceUnavailable = error { unavailable = true }
                        else { unavailable = false }
                        return Outcome(index: index, batch: nil, errorMessage: Self.message(for: error), unavailable: unavailable)
                    }
                }
            }
            var indexed: [Int: Outcome] = [:]
            for await outcome in group { indexed[outcome.index] = outcome }
            return collectors.indices.compactMap { indexed[$0] }
        }
    }

    private func unavailableHealth(
        sourceID: String,
        existing: SourceHealth?,
        cachedRecordCount: Int,
        hasHistory: Bool,
        now: Date,
        message: String
    ) -> SourceHealth {
        guard hasHistory else {
            return SourceHealth(sourceID: sourceID, lastAttempt: now, state: .notInstalled)
        }
        return failedHealth(
            sourceID: sourceID, existing: existing, cachedRecordCount: cachedRecordCount,
            now: now, message: message, state: .unavailable
        )
    }

    private func failedHealth(
        sourceID: String,
        existing: SourceHealth?,
        cachedRecordCount: Int,
        now: Date,
        message: String,
        state: SourceHealth.State
    ) -> SourceHealth {
        SourceHealth(sourceID: sourceID, lastAttempt: now, lastSuccess: existing?.lastSuccess,
            recordCount: existing?.recordCount ?? cachedRecordCount, errorMessage: Self.sanitizeErrorMessage(message),
            skippedRecords: existing?.skippedRecords ?? 0, state: state)
    }

    public static func sanitizeErrorMessage(_ message: String) -> String {
        let trimSet = CharacterSet(charactersIn: "\"'“”‘’()[]{},;:")
        var kept: [String] = []
        var inPath = false
        for rawToken in message.split(whereSeparator: \.isWhitespace) {
            let token = String(rawToken)
            let core = token.trimmingCharacters(in: trimSet)
            let isPath = core.contains("/Users/")
                || core.hasPrefix("/")
                || core.hasPrefix("~")
                || core.hasPrefix("file://")
                || (inPath && core.contains("/"))
            if isPath {
                inPath = true
            } else {
                inPath = false
                kept.append(token)
            }
        }
        var sanitized = kept.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":-;")))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while sanitized.contains("  ") {
            sanitized = sanitized.replacingOccurrences(of: "  ", with: " ")
        }
        return sanitized.isEmpty ? "Collection failed" : sanitized
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription { return description }
        return String(describing: error)
    }

    private struct Outcome: Sendable {
        let index: Int
        let batch: CollectionBatch?
        let errorMessage: String?
        let unavailable: Bool
    }
}
