import Foundation

// Draft lines to be replaced after a copy brainstorm.
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
}
