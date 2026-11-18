import Foundation

public typealias UnitStyle = TokenFormat.UnitStyle

public enum TokenFormat {
    public enum UnitStyle: String, CaseIterable, Sendable {
        case international
        case chinese
    }

    public nonisolated(unsafe) static var unitStyle: UnitStyle = .international

    /// `1.24B`, `58.3M`, `412.5K`, `980`, or `1.65亿`, `35.6万`, `9,876` in Chinese units.
    public static func short(_ n: Int64) -> String {
        switch unitStyle {
        case .international:
            internationalShort(n)
        case .chinese:
            chineseShort(n)
        }
    }

    private static func internationalShort(_ n: Int64) -> String {
        let value = Double(n)
        let magnitude = abs(value)
        // Thresholds sit at the rounding edge so 999_960 reads `1.0M` rather than `1000.0K`.
        if magnitude >= 999_950_000 { return String(format: "%.2fB", value / 1e9) }
        if magnitude >= 999_950 { return String(format: "%.1fM", value / 1e6) }
        if magnitude >= 1_000 { return String(format: "%.1fK", value / 1e3) }
        return String(n)
    }

    private static func chineseShort(_ n: Int64) -> String {
        let negative = n < 0
        let magnitude = n.magnitude

        if magnitude < 10_000 {
            let grouped = groupedInteger(magnitude)
            return negative ? "-" + grouped : grouped
        }

        // Round in decimal integer space so half-steps like 99_950 (`9.995万`) promote cleanly to `10万`.
        let rounded = roundToThreeSignificantDigits(magnitude)
        let (divisor, unit): (UInt64, String) = if rounded < 100_000_000 {
            (10_000, "万")
        } else if rounded < 1_000_000_000_000 {
            (100_000_000, "亿")
        } else {
            (1_000_000_000_000, "万亿")
        }

        let whole = rounded / divisor
        let remainder = rounded % divisor
        let numberText: String
        if remainder == 0 {
            numberText = groupedInteger(whole)
        } else {
            let width = switch divisor {
            case 10_000: 4
            case 100_000_000: 8
            default: 12
            }
            let raw = String(remainder)
            let padded = String(repeating: "0", count: width - raw.count) + raw
            var trimmed = padded[...]
            while trimmed.last == "0" {
                trimmed = trimmed.dropLast()
            }
            numberText = "\(groupedInteger(whole)).\(trimmed)"
        }
        return (negative ? "-" : "") + numberText + unit
    }

    private static func roundToThreeSignificantDigits(_ value: UInt64) -> UInt64 {
        var digits = 0
        var probe = value
        while probe > 0 {
            digits += 1
            probe /= 10
        }
        guard digits > 3 else { return value }
        var step: UInt64 = 1
        for _ in 0..<(digits - 3) {
            step *= 10
        }
        return ((value + step / 2) / step) * step
    }

    private static func groupedInteger(_ value: UInt64) -> String {
        let digits = Array(String(value))
        guard digits.count > 3 else { return String(digits) }
        var result = ""
        result.reserveCapacity(digits.count + (digits.count - 1) / 3)
        for (index, character) in digits.enumerated() {
            if index > 0, (digits.count - index).isMultiple(of: 3) {
                result.append(",")
            }
            result.append(character)
        }
        return result
    }

    /// Rounds a USD amount to two decimal places from its decimal spelling using `.plain`
    /// (half away from zero), matching `usd(_:)` so CLI JSON and UI agree on half-cent boundaries.
    public static func roundedUSD(_ value: Double) -> Decimal {
        // A binary double puts 10705.755 a hair below the half cent, so round the decimal
        // spelling instead of the double. `.plain` is half away from zero, matching how the
        // price table's estimates are quoted.
        guard value.isFinite, var decimal = Decimal(string: String(value), locale: nil) else {
            return 0
        }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, 2, .plain)
        // Rounding a tiny negative amount must not leave `-0.00`.
        if rounded == 0 { rounded = 0 }
        return rounded
    }

    /// `$10,705.76`. Grouped and rounded in a fixed POSIX form, so the text is the same in
    /// every locale.
    public static func usd(_ v: Double) -> String {
        guard v.isFinite else {
            return String(format: "$%.2f", v)
        }
        let rounded = roundedUSD(v)

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

    /// VoiceOver-sized magnitude in the current locale or selected unit style: `4.3 billion`, `1.65亿`.
    public static func spoken(_ n: Int64) -> String {
        switch unitStyle {
        case .international:
            spoken(n, locale: .current)
        case .chinese:
            chineseShort(n)
        }
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
