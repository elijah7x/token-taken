import Foundation

/// One rank band. The whole table, its wording and its version live in this file.
enum RankTier: Equatable, Sendable {
    case topPercent(String)
    case aboveMedian
}

struct RankTable: Sendable {
    /// Bumped whenever thresholds or wording change, so a card's claim can be traced back.
    static let version = "rank-table-2026-11"

    struct Entry: Sendable {
        let minimumTokens: Int64
        let tier: RankTier
    }

    /// First match wins: thresholds are listed from the highest band down.
    static let entries: [Entry] = [
        Entry(minimumTokens: 100_000_000_000, tier: .topPercent("0.01%")),
        Entry(minimumTokens: 50_000_000_000, tier: .topPercent("0.05%")),
        Entry(minimumTokens: 25_000_000_000, tier: .topPercent("0.1%")),
        Entry(minimumTokens: 13_000_000_000, tier: .topPercent("0.5%")),
        Entry(minimumTokens: 8_000_000_000, tier: .topPercent("1%")),
        Entry(minimumTokens: 5_600_000_000, tier: .topPercent("2%")),
        Entry(minimumTokens: 2_200_000_000, tier: .topPercent("5%")),
        Entry(minimumTokens: 900_000_000, tier: .topPercent("10%")),
        Entry(minimumTokens: 350_000_000, tier: .aboveMedian),
    ]

    /// `nil` means no rank: the UI then shows the token count alone, with no negative wording.
    static func tier(forLast30Days total: Int64) -> RankTier? {
        entries.first { total >= $0.minimumTokens }?.tier
    }

    static func line(for tier: RankTier, locale: Locale) -> String {
        switch tier {
        case .topPercent(let percent):
            // The percent is already formatted text, so a plain substitution is enough.
            let template = String(localized: "rank.line.top", locale: locale)
            return template.replacingOccurrences(of: "%@", with: percent)
        case .aboveMedian:
            return String(localized: "rank.line.median", locale: locale)
        }
    }

    static func footnote(locale: Locale) -> String {
        String(localized: "rank.footnote", locale: locale)
    }

    static func methodology(locale: Locale) -> String {
        String(localized: "rank.methodology", locale: locale)
    }
}
