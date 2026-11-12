import Foundation

/// One "52.3亿 tokens ≈ N novels" line. `zh`/`en` each contain `{n}` once.
struct Comparison: Codable, Sendable, Equatable {
    let id: String
    let unitTokens: Double
    let zh: String
    let en: String
    let source: String
    let note: String
}

struct ComparisonLine: Sendable, Equatable {
    let text: String
    let source: String
}

struct ComparisonCatalog: Sendable {
    let entries: [Comparison]

    /// Missing or unreadable file returns `nil`, and the UI hides the line entirely.
    static func load(bundle: Bundle = .main) -> ComparisonCatalog? {
        guard let url = bundle.url(forResource: "comparisons", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Comparison].self, from: data),
              !entries.isEmpty
        else { return nil }
        return ComparisonCatalog(entries: entries)
    }

    /// Only items whose count lands between 1 and 10,000 make sense to a reader.
    func pick(tokens: Int64, locale: Locale) -> ComparisonLine? {
        let chinese = TokenFormat.usesChineseUnits(locale)
        var candidates: [(entry: Comparison, count: Double)] = []
        for entry in entries where entry.unitTokens > 0 {
            let count = Double(tokens) / entry.unitTokens
            if count >= 1, count <= 10_000 {
                candidates.append((entry, count))
            }
        }
        guard let pick = candidates.randomElement() else { return nil }
        let template = chinese ? pick.entry.zh : pick.entry.en
        let text = template.replacingOccurrences(of: "{n}", with: TokenFormat.comparisonCount(pick.count))
        return ComparisonLine(text: text, source: pick.entry.source)
    }
}
