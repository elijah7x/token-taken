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

    /// `$132.26`.
    public static func usd(_ v: Double) -> String {
        String(format: "$%.2f", v)
    }
}
