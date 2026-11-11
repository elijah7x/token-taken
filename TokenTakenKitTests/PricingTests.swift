import XCTest
@testable import TokenTakenKit

final class PricingTests: XCTestCase {
    private let table = PriceTable.bundled

    private func cost(_ model: String, _ counts: TokenCounts) throws -> Double {
        try XCTUnwrap(table.cost(model: model, counts: counts), "expected \(model) to be fully priced")
    }

    func testVersionString() {
        XCTAssertEqual(table.version, "tokscale-4.21.0-2026-11-10+alias-v3")
        XCTAssertEqual(PriceTable.aliasTableVersion, "v3")
    }

    func testBundledVersionTracksAliasTable() {
        XCTAssertTrue(table.version.hasSuffix("+alias-" + PriceTable.aliasTableVersion), table.version)
        XCTAssertTrue(table.version.contains("+alias-v3"), table.version)
    }

    func testClaudeSonnet45UsesFirstPartyRates() throws {
        // Anthropic first-party tariff: $3.00/$15.00 per 1M, $0.30 cache read, $3.75 cache write.
        let counts = TokenCounts(input: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000, output: 1_000_000)
        let estimate = table.estimate(model: "claude-sonnet-4-5", counts: counts)
        XCTAssertEqual(estimate.usd, 3.0 + 0.3 + 3.75 + 15.0, accuracy: 1e-9)
        XCTAssertEqual(estimate.unpricedTokens, 0)
        // The Cursor spelling of the same tariff is a reviewed alias, not a separate rate.
        XCTAssertEqual(try cost("claude-4-5-sonnet", TokenCounts(input: 1_000_000)), 3.0, accuracy: 1e-9)
    }

    func testEveryAliasResolvesInBundledTable() {
        // Some targets leave cacheWrite unpriced (nil) by design, so check input and output only.
        let counts = TokenCounts(input: 1_000_000, output: 1_000_000)
        for (variant, base) in PriceTable.aliases {
            XCTAssertEqual(PriceTable.normalizedModelID(variant), base, variant)
            // A provider prefix cannot match an exact key, so this exercises the alias target.
            let estimate = table.estimate(model: "router/\(variant)", counts: counts)
            XCTAssertEqual(estimate.unpricedTokens, 0, "\(variant) does not resolve to priced rates")
            XCTAssertGreaterThan(estimate.usd, 0, variant)
        }
    }

    func testAliasKeysDoNotShadowExactEntries() {
        // Exact keys win in `rates(for:)`, so a row is billed at its own rate even when its spelling
        // is also an alias key. A prefixed spelling has no exact key and must reach the base row.
        let counts = TokenCounts(input: 1_000_000)
        for (variant, base) in PriceTable.aliases {
            XCTAssertNotEqual(variant, base)
            let fixture = PriceTable(version: "fixture", rates: [
                base: .init(input: 1, cacheRead: nil, cacheWrite: nil, output: nil),
                variant: .init(input: 2, cacheRead: nil, cacheWrite: nil, output: nil),
            ])
            XCTAssertEqual(fixture.estimate(model: variant, counts: counts).usd, 2, accuracy: 1e-9, variant)
            XCTAssertEqual(fixture.estimate(model: "router/\(variant)", counts: counts).usd, 1, accuracy: 1e-9, variant)
        }
    }

    func testFreeSuffixStaysUnpriced() throws {
        // A `:free` variant has no published tariff and must never borrow the paid base rates.
        let counts = TokenCounts(input: 1_000_000, output: 1_000_000)
        for model in ["z-ai/glm-5.2:free", "glm-5.2:free", "router/z-ai/glm-5.2:free",
                      "claude-sonnet-4-5:free"] {
            let estimate = table.estimate(model: model, counts: counts)
            XCTAssertEqual(estimate.usd, 0, model)
            XCTAssertEqual(estimate.unpricedTokens, counts.total, model)
            XCTAssertNil(table.cost(model: model, counts: counts), model)
        }
        XCTAssertEqual(PriceTable.normalizedModelID("z-ai/glm-5.2:free"), "glm-5.2:free")
        // An exact reviewed key still prices a free id; nothing else about the suffix is guessed.
        let reviewed = PriceTable(version: "fixture", rates: [
            "glm-5.2:free": .init(input: 1, cacheRead: nil, cacheWrite: nil, output: 1),
        ])
        XCTAssertEqual(try XCTUnwrap(reviewed.cost(model: "z-ai/glm-5.2:free", counts: counts)), 2, accuracy: 1e-9)
    }

    func testExactModelID() throws {
        // claude-sonnet-5-5: 2.0 in, 10.0 out, 0.1 cache read, 2.5 cache write.
        let counts = TokenCounts(input: 1_000_000, cacheRead: 2_000_000, cacheWrite: 1_000_000, output: 1_000_000)
        let estimate = table.estimate(model: "claude-sonnet-5-5", counts: counts)
        XCTAssertEqual(estimate.usd, 2.0 + 0.2 + 2.5 + 10.0, accuracy: 1e-9)
        XCTAssertEqual(estimate.unpricedTokens, 0)
        XCTAssertEqual(try cost("claude-sonnet-5-5", TokenCounts(input: 1_000_000)), 2.0, accuracy: 1e-9)
    }

    func testAliasProviderPrefix() throws {
        let counts = TokenCounts(input: 1_000_000, output: 1_000_000)
        XCTAssertEqual(try cost("anthropic/claude-sonnet-5-5", counts), 12.0, accuracy: 1e-9)
    }

    func testExplicitAliasesResolveAgainstBaseRates() throws {
        let aliases = [
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
        let counts = TokenCounts(input: 1_000_000, output: 1_000_000)
        for (alias, base) in aliases {
            let baseTable = PriceTable(version: "fixture", rates: [
                base: .init(input: 2, cacheRead: nil, cacheWrite: nil, output: 3),
            ])
            XCTAssertEqual(PriceTable.normalizedModelID(alias), base)
            let model = "router/provider/\(alias.uppercased()):cloud"
            let estimate = baseTable.estimate(model: model, counts: counts)
            XCTAssertEqual(estimate.usd, 5, accuracy: 1e-9, model)
            XCTAssertEqual(estimate.unpricedTokens, 0, model)
        }
    }

    func testUnknownVariantsStayUnpriced() {
        let counts = TokenCounts(input: 1_000_000, output: 250_000)
        for model in ["gpt-5.5-max", "gpt-5.5-c", "gpt-5.5-n", "gpt-5.5-fast",
                      "claude-sonnet-5-5-high", "claude-sonnet-5-5-thinking-xhigh-fast",
                      "claude-opus-5-5-medium-fast"] {
            let estimate = table.estimate(model: model, counts: counts)
            XCTAssertEqual(estimate.usd, 0, model)
            XCTAssertEqual(estimate.unpricedTokens, counts.total, model)
            XCTAssertNil(table.cost(model: model, counts: counts), model)
        }
    }

    func testAliasCloudSuffix() {
        // Resolves to the first-party deepseek/deepseek-v4.1-flash rate of 0.051 per 1M input tokens.
        let estimate = table.estimate(model: "deepseek-v4.1-flash:cloud", counts: TokenCounts(input: 1_000_000))
        XCTAssertEqual(estimate.usd, 0.051, accuracy: 1e-9)
        XCTAssertEqual(estimate.unpricedTokens, 0)
    }

    func testAliasDoesNotShadowExactKey() throws {
        // The model name includes -max; it is not a generic effort alias.
        XCTAssertEqual(PriceTable.normalizedModelID("qwen3.7-max"), "qwen3.7-max")
        XCTAssertEqual(
            try cost("qwen3.7-max", TokenCounts(input: 1_000_000, output: 1_000_000)),
            1.475 + 4.425,
            accuracy: 1e-9
        )
    }

    func testUnknownModelIsFullyUnpriced() {
        let counts = TokenCounts(input: 10, cacheRead: 20, cacheWrite: 30, output: 40, reasoning: 50, uncategorized: 60)
        let estimate = table.estimate(model: "no-such-model-99", counts: counts)
        XCTAssertEqual(estimate.usd, 0)
        XCTAssertEqual(estimate.unpricedTokens, 210)
        XCTAssertNil(table.cost(model: "no-such-model-99", counts: counts))
    }

    func testDroppedSnapshotEntriesAreUnpriced() {
        XCTAssertNil(table.cost(model: "k3.1-pro", counts: TokenCounts(input: 1_000_000)))
        XCTAssertNil(table.cost(model: "swe-2-max", counts: TokenCounts(input: 1_000_000)))
        XCTAssertNil(table.cost(model: "swe-2-medium", counts: TokenCounts(input: 1_000_000)))
    }

    func testNullCacheRateUnpricesOnlyThatCategory() throws {
        // gemini-3.7-flash: 0.75 in, 3.75 out, 0.075 cache read, cache write unpriced.
        let estimate = table.estimate(model: "gemini-3.7-flash", counts: TokenCounts(input: 1_000_000, cacheWrite: 500))
        XCTAssertEqual(estimate.usd, 0.75, accuracy: 1e-9)
        XCTAssertEqual(estimate.unpricedTokens, 500)
        XCTAssertNil(table.cost(model: "gemini-3.7-flash", counts: TokenCounts(cacheWrite: 500)))
        XCTAssertEqual(try cost("gemini-3.7-flash", TokenCounts(input: 1_000_000)), 0.75, accuracy: 1e-9)
    }

    func testReasoningBilledAtOutputRate() {
        // claude-sonnet-5-5 output rate is 10.0.
        let estimate = table.estimate(model: "claude-sonnet-5-5", counts: TokenCounts(output: 250_000, reasoning: 750_000))
        XCTAssertEqual(estimate.usd, 10.0, accuracy: 1e-9)
        XCTAssertEqual(estimate.unpricedTokens, 0)
    }

    func testUncategorizedTokensAreNeverPriced() {
        let counts = TokenCounts(input: 1_000_000, uncategorized: 42)
        let estimate = table.estimate(model: "claude-sonnet-5-5", counts: counts)
        XCTAssertEqual(estimate.usd, 2.0, accuracy: 1e-9)
        XCTAssertEqual(estimate.unpricedTokens, 42)
        XCTAssertNil(table.cost(model: "claude-sonnet-5-5", counts: counts))
    }

    func testSyntheticTableIsUnchanged() throws {
        XCTAssertEqual(try XCTUnwrap(PriceTable.synthetic.cost(model: "claude-sonnet-5-5", counts: TokenCounts(input: 1_000_000))), 3, accuracy: 1e-9)
        XCTAssertNil(PriceTable.synthetic.cost(model: "kimi-k3.1-pro", counts: TokenCounts(input: 1_000_000)))
    }
}
