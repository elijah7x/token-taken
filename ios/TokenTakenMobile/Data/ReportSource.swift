import Foundation

enum ReportState: String, Sendable, Equatable {
    case ok
    case stale
    case noReport
    case iCloudUnavailable
    case decodeFailed
}

struct ReportLoad: Sendable, Equatable {
    let report: MobileReport?
    let state: ReportState
}

protocol ReportSource: Sendable {
    func load() async -> ReportLoad
}

enum ReportStateRules {
    static let staleInterval: TimeInterval = 24 * 60 * 60

    static func isStale(_ generatedAt: Date, now: Date = .now) -> Bool {
        generatedAt < now.addingTimeInterval(-staleInterval)
    }

    static func state(for report: MobileReport, now: Date = .now) -> ReportState {
        isStale(report.generatedAt, now: now) ? .stale : .ok
    }
}

/// Last good report, kept so the screen has numbers before iCloud answers.
struct ReportCache: Sendable {
    let fileURL: URL

    init(fileManager: FileManager = .default) {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        fileURL = base
            .appendingPathComponent("TokenTakenMobile", isDirectory: true)
            .appendingPathComponent("mobile-report-v1.json", isDirectory: false)
    }

    func read() -> ReportLoad? {
        guard let data = try? Data(contentsOf: fileURL),
              let report = try? MobileReport.decode(data)
        else { return nil }
        return ReportLoad(report: report, state: ReportStateRules.state(for: report))
    }

    /// Best effort: a failed cache write only costs the fast path on next launch.
    func write(_ report: MobileReport) {
        guard let data = try? MobileReport.makeEncoder().encode(report) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic])
        } catch {}
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
