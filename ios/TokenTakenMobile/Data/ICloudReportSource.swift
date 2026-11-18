import Foundation

/// Reads `Documents/mobile/v1/report-*.json` from the shared iCloud container the Mac app writes to.
struct ICloudReportSource: ReportSource {
    static let containerIdentifier = "iCloud.io.github.elijah7x.TokenTaken"
    static let identityChangeNotification = Notification.Name.NSUbiquityIdentityDidChange
    static let downloadTimeout: Duration = .seconds(10)

    private static let folderComponents = ["Documents", "mobile", "v1"]

    func load() async -> ReportLoad {
        // `url(forUbiquityContainerIdentifier:)` blocks, so it never runs on the main thread.
        guard let container = await Self.containerURL() else {
            return ReportLoad(report: nil, state: .iCloudUnavailable)
        }
        let folder = Self.folderComponents.reduce(container) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        let candidates = Array(await MetadataReportSearch.reportURLs(in: folder).prefix(6))
        guard !candidates.isEmpty else {
            return ReportLoad(report: nil, state: .noReport)
        }

        for url in candidates {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }

        let deadline = ContinuousClock.now.advanced(by: Self.downloadTimeout)
        let payloads: [Data?] = await withTaskGroup(of: (Int, Data?).self) { group in
            for (index, url) in candidates.enumerated() {
                group.addTask {
                    guard await Self.waitForDownload(url, deadline: deadline) else {
                        return (index, nil)
                    }
                    return (index, await Self.coordinatedRead(url))
                }
            }
            var results = [Data?](repeating: nil, count: candidates.count)
            for await (index, data) in group {
                results[index] = data
            }
            return results
        }

        var newest: MobileReport?
        var sawUnsupportedVersion = false
        var sawCorruptData = false
        for data in payloads.compactMap({ $0 }) {
            do {
                let report = try MobileReport.decode(data)
                if let current = newest {
                    if report.generatedAt > current.generatedAt { newest = report }
                } else {
                    newest = report
                }
            } catch MobileReportError.unsupportedSchemaVersion {
                sawUnsupportedVersion = true
            } catch {
                sawCorruptData = true
            }
        }

        if let newest {
            return ReportLoad(report: newest, state: ReportStateRules.state(for: newest))
        }
        if sawCorruptData {
            return ReportLoad(report: nil, state: .decodeFailed)
        }
        if sawUnsupportedVersion {
            return ReportLoad(report: nil, state: .unsupportedVersion)
        }
        return ReportLoad(report: nil, state: .downloading)
    }

    /// Bridges the identity notification into a `Void` stream, so the `Notification` value
    /// never crosses an actor boundary.
    nonisolated static func identityChangeStream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await _ in NotificationCenter.default.notifications(named: identityChangeNotification) {
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func containerURL() async -> URL? {
        let identifier = containerIdentifier
        return await Task.detached(priority: .userInitiated) {
            FileManager.default.url(forUbiquityContainerIdentifier: identifier)
        }.value
    }

    private static func waitForDownload(_ initialURL: URL, deadline: ContinuousClock.Instant) async -> Bool {
        var url = initialURL
        let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey]
        while true {
            url.removeAllCachedResourceValues()
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isUbiquitousItem != true {
                return FileManager.default.fileExists(atPath: url.path)
            }
            if values?.ubiquitousItemDownloadingStatus == .current {
                return true
            }
            if ContinuousClock.now >= deadline || Task.isCancelled {
                return false
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func coordinatedRead(_ url: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            var coordinationError: NSError?
            var data: Data?
            NSFileCoordinator().coordinate(
                readingItemAt: url,
                options: [.withoutChanges],
                error: &coordinationError
            ) { coordinatedURL in
                data = try? Data(contentsOf: coordinatedURL)
            }
            guard coordinationError == nil else { return nil }
            return data
        }.value
    }
}

/// NSMetadataQuery needs the main run loop, so the search stays on the main actor and yields while gathering.
@MainActor
private enum MetadataReportSearch {
    static func reportURLs(in folder: URL) async -> [URL] {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "report-*.json")
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        guard query.start() else { return [] }
        defer { query.stop() }

        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while query.isGathering, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(120))
        }
        query.disableUpdates()
        guard !Task.isCancelled else { return [] }

        var urls: [URL] = []
        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL
            else { continue }
            guard url.lastPathComponent.hasPrefix("report-"), url.pathExtension == "json" else { continue }
            let parent = url.deletingLastPathComponent().standardizedFileURL
            guard parent == folder.standardizedFileURL || url.path.contains("/Documents/mobile/v1/") else { continue }
            urls.append(url)
        }
        return urls
    }
}
