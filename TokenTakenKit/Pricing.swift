import Foundation

public struct PriceTable: Sendable {
    /// USD per 1M tokens. A nil rate means that category is unpriced for the model, never free.
    /// Reasoning is billed at the output rate.
    public struct Rates: Hashable, Sendable {
        public let input: Double?
        public let cacheRead: Double?
        public let cacheWrite: Double?
        /// Anthropic's published 1-hour cache-write tariff; nil for every other provider.
        public let cacheWrite1h: Double?
        public let output: Double?

        public init(input: Double?, cacheRead: Double?, cacheWrite: Double?, cacheWrite1h: Double? = nil, output: Double?) {
            self.input = input
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.cacheWrite1h = cacheWrite1h
            self.output = output
        }
    }

    /// Versioned alias table used for lookups that miss an exact key. Bump it whenever the
    /// mappings or rules in `normalizedModelID(_:)` change; `PriceTable.bundled` folds it into
    /// its version, so every alias change also changes the recorded price-table version.
    public static let aliasTableVersion = "v3"

    public let version: String
    private let rates: [String: Rates]
    private let aliasRates: [String: Rates]

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
        self.aliasRates = indexed
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
        // `cacheWrite1h` is a subset of `cacheWrite`: split it out and bill it at the explicit 1-hour
        // rate, falling back to the cache-write rate when the table has none. The clamp keeps a row that
        // claims more 1-hour writes than cache writes from charging for tokens it does not have.
        let oneHour = min(max(counts.cacheWrite1h, 0), counts.cacheWrite)
        price(counts.cacheWrite - oneHour, r.cacheWrite)
        price(oneHour, r.cacheWrite1h ?? r.cacheWrite)
        price(counts.output, r.output)
        price(counts.reasoning, r.output)
        return (perMillion / 1_000_000, unpriced)
    }

    /// Thin wrapper over `estimate(model:counts:)`: nil as soon as any token in `counts` is unpriced.
    public func cost(model: String, counts: TokenCounts) -> Double? {
        let result = estimate(model: model, counts: counts)
        return result.unpricedTokens == 0 ? result.usd : nil
    }

    /// Estimated USD saved by cache reads compared with paying the uncached `input` rate:
    /// `Double(counts.cacheRead) * (inputRate - cacheReadRate) / 1_000_000`.
    /// This is a read-side saving only and does not subtract cache-write premiums.
    /// Returns `nil` when the model has no entry or either `input` or `cacheRead` rate is `nil`,
    /// and returns `0` when both rates exist and `counts.cacheRead == 0`.
    public func cacheSavings(model: String, counts: TokenCounts) -> Double? {
        guard let r = rates(for: model),
              let inputRate = r.input,
              let cacheReadRate = r.cacheRead else {
            return nil
        }
        if counts.cacheRead == 0 { return 0 }
        return Double(counts.cacheRead) * (inputRate - cacheReadRate) / 1_000_000
    }

    /// Alias table v3: lowercase, drop the provider prefix up to the last `/` and any `:` suffix,
    /// then apply only reviewed variant mappings. Unknown variant suffixes remain unpriced.
    /// A `:free` suffix is kept, so a free variant never resolves to a paid model; it prices only
    /// from an exact key. Exact snapshot keys take precedence over aliases.
    public static func normalizedModelID(_ id: String) -> String {
        var alias = baseModelID(id)
        // Free tiers carry no tariff of their own, and the base model's rates do not describe them.
        if alias.hasSuffix(":free") { return alias }
        if let colon = alias.firstIndex(of: ":") { alias = String(alias[alias.startIndex..<colon]) }
        return aliases[alias] ?? alias
    }

    /// Observed variants in engine/price-snapshot-2026-11-10.json; no suffix guessing. Internal so
    /// tests can check that every alias still resolves against the bundled table.
    static let aliases: [String: String] = [
        "claude-4-5-sonnet": "claude-sonnet-4-5",
        "claude-fable-5-1-medium": "claude-fable-5-1",
        "claude-fable-5-1-thinking-high": "claude-fable-5-1",
        "claude-fable-5-1-thinking-medium": "claude-fable-5-1",
        "claude-fable-5-1-thinking-xhigh": "claude-fable-5-1",
        "claude-opus-4-8-thinking-high": "claude-opus-4-8",
        "claude-opus-5-5-medium": "claude-opus-5-5",
        "claude-opus-5-5-xhigh": "claude-opus-5-5",
        "claude-opus-5-low": "claude-opus-5",
        "claude-opus-5-thinking-high": "claude-opus-5",
        "composer-2.5-fast": "composer-2.5",
        "cursor-grok-4.5-high": "cursor-grok-4.5",
        "cursor-grok-4.5-high-fast": "cursor-grok-4.5",
        "cursor-grok-4.6-high": "cursor-grok-4.6",
        "cursor-grok-4.6-high-fast": "cursor-grok-4.6",
        "cursor-grok-4.6-xhigh": "cursor-grok-4.6",
        "gemini-3.5-flash-high": "gemini-3.5-flash",
        "gemini-3.8-flash-n": "gemini-3.8-flash",
        "gemini-3.8-flash-tiered": "gemini-3.8-flash",
        "gemini-4-argon-c": "gemini-4-argon",
        "gemini-4-argon-trial": "gemini-4-argon",
        "gpt-5-6-sol-medium": "gpt-5.6-sol",
        "gpt-5.6-luna-high": "gpt-5.6-luna",
        "gpt-5.6-sol-medium": "gpt-5.6-sol",
        "gpt-6-astra-low": "gpt-6-astra",
        "grok-4.7-xhigh": "grok-4.7",
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
        return rates[alias] ?? aliasRates[alias]
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
