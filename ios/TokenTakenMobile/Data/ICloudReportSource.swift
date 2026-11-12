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
        let candidates = await MetadataReportSearch.reportURLs(in: folder)
        guard !candidates.isEmpty else {
            return ReportLoad(report: nil, state: .noReport)
        }

        var newest: MobileReport?
        var sawReadableData = false
        var sawUndecodableData = false
        for url in candidates.prefix(6) {
            guard let data = await Self.readData(at: url) else { continue }
            sawReadableData = true
            guard let report = try? MobileReport.decode(data) else {
                sawUndecodableData = true
                continue
            }
            if let current = newest {
                if report.generatedAt > current.generatedAt { newest = report }
            } else {
                newest = report
            }
        }

        if let newest {
            return ReportLoad(report: newest, state: ReportStateRules.state(for: newest))
        }
        // Files exist but nothing downloaded in time: not an error, just nothing readable yet.
        let state: ReportState = (sawReadableData || sawUndecodableData) ? .decodeFailed : .noReport
        return ReportLoad(report: nil, state: state)
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

    private static func readData(at url: URL) async -> Data? {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        guard await waitForDownload(url) else { return nil }
        return await coordinatedRead(url)
    }

    private static func waitForDownload(_ url: URL, timeout: Duration = downloadTimeout) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey]
        while ContinuousClock.now < deadline {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isUbiquitousItem != true {
                return FileManager.default.fileExists(atPath: url.path)
            }
            if values?.ubiquitousItemDownloadingStatus == .current {
                return true
            }
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
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
        while query.isGathering, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(120))
        }
        query.disableUpdates()

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
