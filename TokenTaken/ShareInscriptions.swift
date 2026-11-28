import Foundation
import TokenTakenKit

enum ShareInscriptions {
    static let maxLength = 40

    private static let fieldKeys: [String] = [
        "share.inscription.field.1",
        "share.inscription.field.2",
        "share.inscription.field.3",
        "share.inscription.field.4",
        "share.inscription.field.5",
        "share.inscription.field.6",
        "share.inscription.field.7",
        "share.inscription.field.8",
    ]

    static func random(
        for theme: AppTheme,
        locale: Locale = .autoupdatingCurrent,
        excluding current: String? = nil
    ) -> String? {
        let keys: [String]
        switch theme {
        case .field:
            keys = fieldKeys
        case .liquidGlass, .cosmos:
            return nil
        }
        let candidates = keys.map { key in
            String(String(localized: String.LocalizationValue(key), locale: locale).prefix(maxLength))
        }
        let filtered = current.map { value in candidates.filter { $0 != value } } ?? candidates
        return (filtered.isEmpty ? candidates : filtered).randomElement()
    }

    static func automaticFootnote(
        period: Period,
        start: Date,
        rankedItems: [Breakdown],
        locale: Locale = .autoupdatingCurrent
    ) -> String? {
        let items = rankedItems
            .filter { $0.counts.total > 0 }
            .sorted { $0.counts.total > $1.counts.total }
        guard let leader = items.first else { return nil }
        let leaders = items.prefix { $0.counts.total == leader.counts.total }

        let name = leader.name.isEmpty ? leader.id : leader.name
        let names = leaders.count == 1 ? nil : leaderNames(for: Array(leaders), locale: locale)

        switch period {
        case .day:
            if let names {
                return String(localized: "In today’s token story, \(names) share the lead.", locale: locale)
            }
            return String(localized: "In today’s token story, \(name) takes the lead.", locale: locale)
        case .week:
            if let names {
                return String(localized: "In this week’s token story, \(names) share the lead.", locale: locale)
            }
            return String(localized: "In this week’s token story, \(name) takes the lead.", locale: locale)
        case .month:
            let month: String
            if locale.language.languageCode == .chinese {
                month = "\(Calendar.current.component(.month, from: start)) 月"
            } else {
                month = start.formatted(.dateTime.locale(locale).month(.wide))
            }
            if let names {
                return String(localized: "In this \(month)’s token story, \(names) share the lead.", locale: locale)
            }
            return String(localized: "In this \(month)’s token story, \(name) takes the lead.", locale: locale)
        case .year:
            let year = String(Calendar.current.component(.year, from: start))
            if let names {
                return String(localized: "In the \(year) token story, \(names) share the lead.", locale: locale)
            }
            return String(localized: "In the \(year) token story, \(name) takes the lead.", locale: locale)
        case .all:
            if let names {
                return String(localized: "Across your whole token story, \(names) share the lead.", locale: locale)
            }
            return String(localized: "Across your whole token story, \(name) takes the lead.", locale: locale)
        }
    }

    private static func leaderNames(for leaders: [Breakdown], locale: Locale) -> String {
        let names = leaders.map { $0.name.isEmpty ? $0.id : $0.name }
        if names.count == 2 {
            return String(localized: "\(names[0]) and \(names[1])", locale: locale)
        }

        let pair = String(localized: "\(names[0]), \(names[1])", locale: locale)
        let remaining = names.count - 2
        if remaining == 1 {
            return String(localized: "\(pair) and one other", locale: locale)
        }
        return String(localized: "\(pair) and \(remaining) others", locale: locale)
    }
}
