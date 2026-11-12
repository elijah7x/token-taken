import Foundation

/// Ported from the macOS app's `TokenTakenKit/TokenFormat.swift`.
enum TokenFormat {
    /// Chinese units start at 万; everything else uses K/M/B.
    static func usesChineseUnits(_ locale: Locale) -> Bool {
        locale.language.languageCode?.identifier == "zh"
    }

    static func short(_ n: Int64, locale: Locale) -> String {
        usesChineseUnits(locale) ? chineseShort(n) : internationalShort(n)
    }

    static func short(_ n: Int64, chineseUnits: Bool) -> String {
        chineseUnits ? chineseShort(n) : internationalShort(n)
    }

    /// Splits `52.3亿` into `52.3` and `亿` so the unit can be set in a smaller size.
    static func split(_ formatted: String) -> (digits: String, unit: String) {
        let numeric: Set<Character> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ".", ",", "-"]
        guard let index = formatted.firstIndex(where: { !numeric.contains($0) }) else {
            return (formatted, "")
        }
        return (String(formatted[..<index]), String(formatted[index...]))
    }

    /// VoiceOver reads `B` letter by letter, so spell the magnitude out in English.
    static func spoken(_ n: Int64, locale: Locale) -> String {
        if usesChineseUnits(locale) { return chineseShort(n) }
        let compact = n.formatted(.number.notation(.compactName).locale(locale))
        guard locale.language.languageCode?.identifier == "en" else { return compact }
        for (suffix, word) in [("T", " trillion"), ("B", " billion"), ("M", " million"), ("K", " thousand")]
        where compact.hasSuffix(suffix) {
            return String(compact.dropLast()) + word
        }
        return compact
    }

    /// A comparison count: one decimal under ten, grouped integer above.
    static func comparisonCount(_ value: Double) -> String {
        if value < 10 { return String(format: "%.1f", value) }
        return grouped(Int64(value.rounded()))
    }

    static func grouped(_ value: Int64) -> String {
        groupedInteger(value.magnitude)
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

        // Round in integer space so 99_950 (`9.995万`) promotes cleanly to `10万`.
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
}
