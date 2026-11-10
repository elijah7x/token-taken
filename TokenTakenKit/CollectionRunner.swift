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
        do {
            try store.upsert(device: device)
            previous = Dictionary(try store.health().map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            return collectors.flatMap(\.sourceIDs).map {
                SourceHealth(sourceID: $0, lastAttempt: now, errorMessage: Self.message(for: error), state: .failed)
            }
        }
        let outcomes = await collectAll()
        var results: [SourceHealth] = []
        for (collector, outcome) in zip(collectors, outcomes) {
            for sourceID in collector.sourceIDs {
                let existing = previous[sourceID]
                var health: SourceHealth
                if let batch = outcome.batch {
                    do {
                        let scoped = sourceBatch(batch, sourceID: sourceID, now: now)
                        try store.replace(batch: scoped, sourceID: sourceID, deviceID: device.id)
                        health = SourceHealth(sourceID: sourceID, lastAttempt: now, lastSuccess: now,
                            recordCount: scoped.daily.count, skippedRecords: batch.skippedRecords)
                    } catch {
                        health = failedHealth(sourceID: sourceID, existing: existing, now: now,
                            message: Self.message(for: error), state: .failed)
                    }
                } else {
                    health = failedHealth(sourceID: sourceID, existing: existing, now: now,
                        message: outcome.errorMessage ?? "Collection failed", state: outcome.unavailable ? .unavailable : .failed)
                }
                do {
                    try store.record(health: health)
                } catch {
                    let prior = health.errorMessage.map { $0 + "; " } ?? ""
                    health.errorMessage = prior + "Could not persist source health: " + Self.message(for: error)
                    health.state = .failed
                }
                results.append(health)
            }
        }
        return results
    }

    private func sourceBatch(_ batch: CollectionBatch, sourceID: String, now: Date) -> CollectionBatch {
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
                    hours[start] = HourlyUsage(hourStart: start, deviceID: device.id, sourceID: sourceID,
                        counts: .zero, eventCount: 0, reasoningKnown: ["zcode", "pi", "omp"].contains(sourceID))
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

    private func failedHealth(sourceID: String, existing: SourceHealth?, now: Date, message: String, state: SourceHealth.State) -> SourceHealth {
        SourceHealth(sourceID: sourceID, lastAttempt: now, lastSuccess: existing?.lastSuccess,
            recordCount: existing?.recordCount ?? 0, errorMessage: message,
            skippedRecords: existing?.skippedRecords ?? 0, state: state)
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
