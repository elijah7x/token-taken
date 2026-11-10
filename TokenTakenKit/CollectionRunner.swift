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
        try? store.upsert(device: device)
        let previous = Dictionary(store.health().map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
        let outcomes = await collectAll()
        var results: [SourceHealth] = []

        for (collector, outcome) in zip(collectors, outcomes) {
            for sourceID in collector.sourceIDs {
                let existing = previous[sourceID]
                if let errorMessage = outcome.errorMessage {
                    let health = failedHealth(sourceID: sourceID, existing: existing, now: now, message: errorMessage)
                    try? store.record(health: health)
                    results.append(health)
                    continue
                }

                do {
                    let records = outcome.records.filter { $0.sourceID == sourceID }
                    try store.replace(records: records, sourceID: sourceID, deviceID: device.id)
                    let health = SourceHealth(
                        sourceID: sourceID,
                        lastAttempt: now,
                        lastSuccess: now,
                        recordCount: records.count
                    )
                    try store.record(health: health)
                    results.append(health)
                } catch {
                    let health = failedHealth(
                        sourceID: sourceID,
                        existing: existing,
                        now: now,
                        message: Self.message(for: error)
                    )
                    try? store.record(health: health)
                    results.append(health)
                }
            }
        }
        return results
    }

    private func collectAll() async -> [Outcome] {
        let collectors = collectors
        return await withTaskGroup(of: Outcome.self) { group in
            for (index, collector) in collectors.enumerated() {
                group.addTask {
                    do {
                        return try await Outcome(index: index, records: collector.collect())
                    } catch {
                        return Outcome(index: index, errorMessage: Self.message(for: error))
                    }
                }
            }
            var indexed: [Int: Outcome] = [:]
            for await outcome in group {
                indexed[outcome.index] = outcome
            }
            return collectors.indices.compactMap { indexed[$0] }
        }
    }

    private func failedHealth(sourceID: String, existing: SourceHealth?, now: Date, message: String) -> SourceHealth {
        SourceHealth(
            sourceID: sourceID,
            lastAttempt: now,
            lastSuccess: existing?.lastSuccess,
            recordCount: existing?.recordCount ?? 0,
            errorMessage: message
        )
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    private struct Outcome: Sendable {
        let index: Int
        let records: [UsageRecord]
        let errorMessage: String?

        init(index: Int, records: [UsageRecord]) {
            self.index = index
            self.records = records
            errorMessage = nil
        }

        init(index: Int, errorMessage: String) {
            self.index = index
            records = []
            self.errorMessage = errorMessage
        }
    }
}
