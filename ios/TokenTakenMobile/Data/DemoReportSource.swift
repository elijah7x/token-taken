import Foundation

/// Bundled synthetic report for onboarding and for screenshots.
struct DemoReportSource: ReportSource {
    func load() async -> ReportLoad {
        guard let url = Bundle.main.url(forResource: "demo-report", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let report = try? MobileReport.decode(data)
        else {
            return ReportLoad(report: nil, state: .decodeFailed)
        }
        // Demo data is synthetic, so the 24h staleness rule would only add noise.
        return ReportLoad(report: report, state: .ok)
    }
}
