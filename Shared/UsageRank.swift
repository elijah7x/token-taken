import Foundation

/// Shared last-30-day usage percentile estimate curve, compiled into both `TokenTakenKit` and
/// `TokenTakenMobile`.
public enum UsageRank {
    public static let version = "rank-curve-2026-11"

    private struct Anchor: Sendable {
        let tokens: Double
        let topPercent: Double
    }

    /// Sorted ascending by token count.
    /// Anchors at 350M tokens and above reflect public usage sources; anchors below 350M are
    /// extrapolated, not measured.
    private static let anchors: [Anchor] = [
        Anchor(tokens: 100_000, topPercent: 99),
        Anchor(tokens: 1_000_000, topPercent: 97),
        Anchor(tokens: 5_000_000, topPercent: 93),
        Anchor(tokens: 20_000_000, topPercent: 85),
        Anchor(tokens: 100_000_000, topPercent: 70),
        Anchor(tokens: 350_000_000, topPercent: 50),
        Anchor(tokens: 900_000_000, topPercent: 10),
        Anchor(tokens: 2_200_000_000, topPercent: 5),
        Anchor(tokens: 5_600_000_000, topPercent: 2),
        Anchor(tokens: 8_000_000_000, topPercent: 1),
        Anchor(tokens: 13_000_000_000, topPercent: 0.5),
        Anchor(tokens: 25_000_000_000, topPercent: 0.1),
        Anchor(tokens: 50_000_000_000, topPercent: 0.05),
        Anchor(tokens: 100_000_000_000, topPercent: 0.01),
    ]

    private static let minimumTopPercent = 0.01
    private static let maximumTopPercent = 99.0
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    /// Estimated percent of users who used more tokens in their last 30 days, clamped to 0.01...99. nil when tokens <= 0.
    public static func topPercent(last30DaysTokens: Int64) -> Double? {
        guard last30DaysTokens > 0 else { return nil }
        let tokens = Double(last30DaysTokens)

        guard let lowest = anchors.first, let highest = anchors.last else { return nil }
        if tokens <= lowest.tokens { return maximumTopPercent }
        if tokens >= highest.tokens { return minimumTopPercent }

        for index in 0..<(anchors.count - 1) {
            let lower = anchors[index]
            let upper = anchors[index + 1]
            if tokens == lower.tokens { return lower.topPercent }
            if tokens == upper.tokens { return upper.topPercent }
            if tokens > lower.tokens && tokens < upper.tokens {
                let logLoTokens = log10(lower.tokens)
                let logHiTokens = log10(upper.tokens)
                let t = (log10(tokens) - logLoTokens) / (logHiTokens - logLoTokens)
                let logLoPercent = log10(lower.topPercent)
                let logHiPercent = log10(upper.topPercent)
                let interpolated = pow(10.0, logLoPercent + t * (logHiPercent - logLoPercent))
                return min(maximumTopPercent, max(minimumTopPercent, interpolated))
            }
        }

        return minimumTopPercent
    }

    /// "57.3%" for values >= 1 (one decimal, drop nothing), "0.42%" for values < 1 (two decimals), never below "0.01%". Locale-independent ASCII digits and '.'.
    public static func formatted(_ topPercent: Double) -> String {
        guard topPercent.isFinite else { return "0.01%" }
        let clamped = max(minimumTopPercent, topPercent)
        if clamped >= 1 {
            return String(format: "%.1f%%", locale: posixLocale, clamped)
        }
        return String(format: "%.2f%%", locale: posixLocale, clamped)
    }
}
