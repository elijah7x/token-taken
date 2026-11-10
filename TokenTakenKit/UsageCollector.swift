import Foundation

public protocol UsageCollector: Sendable {
    var sourceIDs: [String] { get }
    func collect() async throws -> [UsageRecord]
}

enum CollectorError: LocalizedError {
    case process(String)
    case invalidOutput(String)
    case open(String)
    case sql(String)

    var errorDescription: String? {
        switch self {
        case .process(let message), .invalidOutput(let message), .open(let message), .sql(let message):
            message
        }
    }
}

enum UsageDay {
    static func date(from string: String) -> Date? {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              string == Self.string(from: DateComponents(year: year, month: month, day: day)) else {
            return nil
        }
        return Calendar.utcGregorian.date(from: DateComponents(year: year, month: month, day: day))
    }

    static func string(from date: Date) -> String {
        let components = Calendar.utcGregorian.dateComponents([.year, .month, .day], from: date)
        return string(from: components)
    }

    static func date(milliseconds: Int64) -> Date? {
        date(from: string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000)))
    }

    private static func string(from components: DateComponents) -> String {
        guard let year = components.year, let month = components.month, let day = components.day else {
            return ""
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
