import Foundation

public struct PriceTable: Sendable {
    /// USD per 1M tokens. Reasoning is billed at the output rate.
    public struct Rates: Hashable, Sendable {
        public let input: Double
        public let cacheRead: Double
        public let cacheWrite: Double
        public let output: Double

        public init(input: Double, cacheRead: Double, cacheWrite: Double, output: Double) {
            self.input = input
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.output = output
        }
    }

    public let version: String
    private let rates: [String: Rates]

    public init(version: String, rates: [String: Rates]) {
        self.version = version
        self.rates = rates
    }

    /// Returns nil when the model is unpriced; unpriced never means free.
    public func cost(model: String, counts: TokenCounts) -> Double? {
        guard let r = rates[model] else { return nil }
        let perMillion = Double(counts.input) * r.input
            + Double(counts.cacheRead) * r.cacheRead
            + Double(counts.cacheWrite) * r.cacheWrite
            + Double(counts.output + counts.reasoning) * r.output
        return perMillion / 1_000_000
    }

    /// Placeholder prices for synthetic data. `kimi-k3.1-pro` is left out on purpose to exercise unpriced tokens.
    public static let synthetic = PriceTable(version: "synthetic-2026-11", rates: [
        "claude-opus-5-5": Rates(input: 5, cacheRead: 0.5, cacheWrite: 6.25, output: 25),
        "claude-sonnet-5-5": Rates(input: 3, cacheRead: 0.3, cacheWrite: 3.75, output: 15),
        "gpt-6.1": Rates(input: 1.5, cacheRead: 0.15, cacheWrite: 0, output: 12),
        "gpt-6.1-mini": Rates(input: 0.3, cacheRead: 0.03, cacheWrite: 0, output: 2.4),
        "glm-5.3": Rates(input: 0.6, cacheRead: 0.11, cacheWrite: 0, output: 2.2),
        "deepseek-v4-pro": Rates(input: 0.5, cacheRead: 0.05, cacheWrite: 0, output: 2),
        "grok-5": Rates(input: 3, cacheRead: 0.75, cacheWrite: 0, output: 15),
        "gemini-3.7-flash": Rates(input: 0.3, cacheRead: 0.03, cacheWrite: 0, output: 2.5),
    ])
}
