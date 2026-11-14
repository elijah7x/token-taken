import Foundation

/// Localized rank wording helpers built on `UsageRank`.
enum Ranking {
    static func line(forLast30Days tokens: Int64, locale: Locale) -> String? {
        guard let percent = UsageRank.topPercent(last30DaysTokens: tokens) else {
            return nil
        }
        let template = String(localized: "rank.line.top", locale: locale)
        return template.replacingOccurrences(of: "%@", with: UsageRank.formatted(percent))
    }

    static func footnote(locale: Locale) -> String {
        String(localized: "rank.footnote", locale: locale)
    }

    static func methodology(locale: Locale) -> String {
        String(localized: "rank.methodology", locale: locale)
    }
}
