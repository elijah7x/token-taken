import XCTest
@testable import TokenTakenKit

final class PricingTests: XCTestCase {
    private let table = PriceTable.bundled

    private func cost(_ model: String, _ counts: TokenCounts) throws -> Double {
        try XCTUnwrap(table.cost(model: model, counts: counts), "expected \(model) to be fully priced")
    }

    func testVersionString() {
        XCTAssertEqual(table.version, "tokscale-4.21.0-2026-11-10")
        XCTAssertEqual(PriceTable.aliasTableVersion, "v1")
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

    func testAliasEffortAndVariantSuffixes() throws {
        let counts = TokenCounts(input: 1_000_000, output: 1_000_000)
        XCTAssertEqual(try cost("claude-sonnet-5-5-high", counts), 12.0, accuracy: 1e-9)
        XCTAssertEqual(try cost("anthropic/claude-sonnet-5-5-thinking-xhigh-fast", counts), 12.0, accuracy: 1e-9)
    }

    func testAliasCloudSuffix() {
        // Resolves to the first-party deepseek/deepseek-v4.1-flash rate of 0.051 per 1M input tokens.
        let estimate = table.estimate(model: "deepseek-v4.1-flash:cloud", counts: TokenCounts(input: 1_000_000))
        XCTAssertEqual(estimate.usd, 0.051, accuracy: 1e-9)
        XCTAssertEqual(estimate.unpricedTokens, 0)
    }

    func testAliasDoesNotShadowExactKey() throws {
        // -max is a stripped variant suffix, but qwen3.7-max has its own entry at 1.475 in / 4.425 out.
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
