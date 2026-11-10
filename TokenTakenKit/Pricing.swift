import Foundation

public struct PriceTable: Sendable {
    /// USD per 1M tokens. A nil rate means that category is unpriced for the model, never free.
    /// Reasoning is billed at the output rate.
    public struct Rates: Hashable, Sendable {
        public let input: Double?
        public let cacheRead: Double?
        public let cacheWrite: Double?
        public let output: Double?

        public init(input: Double?, cacheRead: Double?, cacheWrite: Double?, output: Double?) {
            self.input = input
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.output = output
        }
    }

    /// Versioned alias table used for lookups that miss an exact key. Bump it with the price version
    /// whenever the rules in `normalizedModelID(_:)` change.
    public static let aliasTableVersion = "v1"

    public let version: String
    private let rates: [String: Rates]
    private let aliases: [String: Rates]

    public init(version: String, rates: [String: Rates]) {
        self.version = version
        self.rates = rates
        // Index every key under its alias so variant ids can find the base entry. Preference order
        // among keys sharing one alias: a key that only needed a provider prefix or case fold removed
        // first, then the shortest, then lexicographic, so a list price beats a reseller or variant rate.
        var indexed: [String: Rates] = [:]
        for key in rates.keys.sorted(by: { lhs, rhs in
            (Self.aliasRank(lhs), lhs.count, lhs) < (Self.aliasRank(rhs), rhs.count, rhs)
        }) {
            let alias = Self.normalizedModelID(key)
            if indexed[alias] == nil { indexed[alias] = rates[key] }
        }
        self.aliases = indexed
    }

    /// Priced portion of the counts in USD plus the token count no rate covered. A model with no
    /// entry is entirely unpriced: it yields zero dollars and every token reported as unpriced.
    public func estimate(model: String, counts: TokenCounts) -> (usd: Double, unpricedTokens: Int64) {
        guard let r = rates(for: model) else {
            let tokens = counts.input + counts.cacheRead + counts.cacheWrite
                + counts.output + counts.reasoning + counts.uncategorized
            return (0, tokens)
        }
        var perMillion = 0.0
        // `uncategorized` has no price category, so it is unpriced by definition.
        var unpriced: Int64 = counts.uncategorized
        func price(_ tokens: Int64, _ rate: Double?) {
            if let rate {
                perMillion += Double(tokens) * rate
            } else {
                unpriced += tokens
            }
        }
        price(counts.input, r.input)
        price(counts.cacheRead, r.cacheRead)
        price(counts.cacheWrite, r.cacheWrite)
        price(counts.output, r.output)
        price(counts.reasoning, r.output)
        return (perMillion / 1_000_000, unpriced)
    }

    /// Thin wrapper over `estimate(model:counts:)`: nil as soon as any token in `counts` is unpriced.
    public func cost(model: String, counts: TokenCounts) -> Double? {
        let result = estimate(model: model, counts: counts)
        return result.unpricedTokens == 0 ? result.usd : nil
    }

    /// Alias table v1: how a model id written by an agent log maps onto a price-snapshot key.
    ///
    /// Lowercases the id, drops the provider prefix up to the last `/`, drops a `:` suffix such as
    /// `:cloud` or `:batch`, then peels effort and variant suffixes until none applies: `-low`,
    /// `-medium`, `-high`, `-xhigh`, `-max`, `-fast`, `-thinking`, `-thinking-<effort>`, `-n`,
    /// `-tiered`, `-trial`, `-c`.
    ///
    /// Exact keys are matched before this runs, so a name that only looks like a suffix survives:
    /// `qwen3.7-max` is priced from its own entry even though it also normalizes to `qwen3.7`.
    public static func normalizedModelID(_ id: String) -> String {
        var alias = baseModelID(id)
        if let colon = alias.firstIndex(of: ":") { alias = String(alias[alias.startIndex..<colon]) }
        while let suffix = variantSuffixes.first(where: { alias.hasSuffix($0) && alias.count > $0.count }) {
            alias.removeLast(suffix.count)
        }
        return alias
    }

    private static let variantSuffixes = [
        "-thinking", "-xhigh", "-medium", "-high", "-low",
        "-fast", "-tiered", "-trial", "-max", "-n", "-c",
    ]

    /// Lowercase and drop the provider prefix, which the alias table treats as a routing detail.
    private static func baseModelID(_ id: String) -> String {
        let lowered = id.lowercased()
        guard let slash = lowered.lastIndex(of: "/") else { return lowered }
        return String(lowered[lowered.index(after: slash)...])
    }

    private static func aliasRank(_ key: String) -> Int {
        normalizedModelID(key) == baseModelID(key) ? 0 : 1
    }

    private func rates(for model: String) -> Rates? {
        if let exact = rates[model] { return exact }
        let alias = Self.normalizedModelID(model)
        return rates[alias] ?? aliases[alias]
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
