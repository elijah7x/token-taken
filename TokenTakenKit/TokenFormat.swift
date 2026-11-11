import Foundation

public enum TokenFormat {
    /// `1.24B`, `58.3M`, `412.5K`, `980`.
    public static func short(_ n: Int64) -> String {
        let value = Double(n)
        let magnitude = abs(value)
        // Thresholds sit at the rounding edge so 999_960 reads `1.0M` rather than `1000.0K`.
        if magnitude >= 999_950_000 { return String(format: "%.2fB", value / 1e9) }
        if magnitude >= 999_950 { return String(format: "%.1fM", value / 1e6) }
        if magnitude >= 1_000 { return String(format: "%.1fK", value / 1e3) }
        return String(n)
    }

    /// `$10,705.76`. Grouped and rounded in a fixed POSIX form, so the text is the same in
    /// every locale.
    public static func usd(_ v: Double) -> String {
        // A binary double puts 10705.755 a hair below the half cent, so round the decimal
        // spelling instead of the double. `.plain` is half away from zero, matching how the
        // price table's estimates are quoted.
        guard v.isFinite, var value = Decimal(string: String(v), locale: nil) else {
            return String(format: "$%.2f", v)
        }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        // Rounding a tiny negative amount must not leave `-$0.00`.
        if rounded == 0 { rounded = 0 }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        formatter.decimalSeparator = "."
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        guard let text = formatter.string(from: NSDecimalNumber(decimal: rounded)) else {
            return String(format: "$%.2f", v)
        }
        // The sign sits outside the currency mark so a negative total reads `-$4.20`.
        return text.hasPrefix("-") ? "-$" + String(text.dropFirst()) : "$" + text
    }

    /// VoiceOver-sized magnitude in the current locale: `4.3 billion`, `43亿`.
    public static func spoken(_ n: Int64) -> String {
        spoken(n, locale: .current)
    }

    static func spoken(_ n: Int64, locale: Locale) -> String {
        let compact = n.formatted(.number.notation(.compactName).locale(locale))
        // English compact notation abbreviates the magnitude (`4.3B`), which VoiceOver reads
        // letter by letter; spell it out. Other locales already use spoken unit words.
        guard locale.language.languageCode?.identifier == "en" else { return compact }
        for (suffix, word) in [("T", " trillion"), ("B", " billion"), ("M", " million"), ("K", " thousand")]
        where compact.hasSuffix(suffix) {
            return String(compact.dropLast()) + word
        }
        return compact
    }
}
