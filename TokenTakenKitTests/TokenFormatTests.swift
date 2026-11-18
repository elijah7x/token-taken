import XCTest
@testable import TokenTakenKit

final class TokenFormatTests: XCTestCase {
    override func tearDown() {
        TokenFormat.unitStyle = .international
        super.tearDown()
    }

    func testInternationalShortIsUnchanged() {
        TokenFormat.unitStyle = .international
        XCTAssertEqual(TokenFormat.short(0), "0")
        XCTAssertEqual(TokenFormat.short(980), "980")
        XCTAssertEqual(TokenFormat.short(-980), "-980")
        XCTAssertEqual(TokenFormat.short(1_000), "1.0K")
        XCTAssertEqual(TokenFormat.short(9_999), "10.0K")
        XCTAssertEqual(TokenFormat.short(99_950), "100.0K")
        XCTAssertEqual(TokenFormat.short(412_500), "412.5K")
        XCTAssertEqual(TokenFormat.short(999_960), "1.0M")
        XCTAssertEqual(TokenFormat.short(58_300_000), "58.3M")
        XCTAssertEqual(TokenFormat.short(1_240_000_000), "1.24B")
        XCTAssertEqual(TokenFormat.short(-1_240_000_000), "-1.24B")
    }

    func testChineseShortBandBoundariesAndRounding() {
        TokenFormat.unitStyle = .chinese

        XCTAssertEqual(TokenFormat.short(0), "0")
        XCTAssertEqual(TokenFormat.short(980), "980")
        XCTAssertEqual(TokenFormat.short(9_876), "9,876")
        XCTAssertEqual(TokenFormat.short(9_999), "9,999")
        XCTAssertEqual(TokenFormat.short(-9_876), "-9,876")

        XCTAssertEqual(TokenFormat.short(10_000), "1万")
        XCTAssertEqual(TokenFormat.short(10_500), "1.05万")
        XCTAssertEqual(TokenFormat.short(35_000), "3.5万")
        XCTAssertEqual(TokenFormat.short(99_949), "9.99万")
        XCTAssertEqual(TokenFormat.short(99_950), "10万")
        XCTAssertEqual(TokenFormat.short(356_000), "35.6万")
        XCTAssertEqual(TokenFormat.short(3_560_000), "356万")
        XCTAssertEqual(TokenFormat.short(35_600_000), "3,560万")
        XCTAssertEqual(TokenFormat.short(99_949_999), "9,990万")
        XCTAssertEqual(TokenFormat.short(99_950_000), "1亿")
        XCTAssertEqual(TokenFormat.short(-35_000), "-3.5万")

        XCTAssertEqual(TokenFormat.short(100_000_000), "1亿")
        XCTAssertEqual(TokenFormat.short(165_000_000), "1.65亿")
        XCTAssertEqual(TokenFormat.short(1_650_000_000), "16.5亿")
        XCTAssertEqual(TokenFormat.short(16_500_000_000), "165亿")
        XCTAssertEqual(TokenFormat.short(165_000_000_000), "1,650亿")
        XCTAssertEqual(TokenFormat.short(999_500_000_000), "1万亿")
        XCTAssertEqual(TokenFormat.short(-165_000_000), "-1.65亿")

        XCTAssertEqual(TokenFormat.short(1_000_000_000_000), "1万亿")
        XCTAssertEqual(TokenFormat.short(1_600_000_000_000), "1.6万亿")
    }

    func testChineseSpokenUsesChineseUnits() {
        TokenFormat.unitStyle = .chinese
        XCTAssertEqual(TokenFormat.spoken(165_000_000), "1.65亿")
        XCTAssertEqual(TokenFormat.spoken(35_000), "3.5万")
        XCTAssertEqual(TokenFormat.spoken(9_876), "9,876")
        XCTAssertEqual(TokenFormat.spoken(0), "0")
    }

    func testUSDGroupsThousandsAndKeepsTwoDecimals() {
        XCTAssertEqual(TokenFormat.usd(10705.755), "$10,705.76")
        XCTAssertEqual(TokenFormat.usd(1_234.5), "$1,234.50")
        XCTAssertEqual(TokenFormat.usd(132.26), "$132.26")
        XCTAssertEqual(TokenFormat.usd(999), "$999.00")
        XCTAssertEqual(TokenFormat.usd(999_999.995), "$1,000,000.00")
    }

    func testRoundedUSDHalfCentBoundary() {
        XCTAssertEqual(TokenFormat.roundedUSD(10705.755), Decimal(string: "10705.76"))
        XCTAssertEqual(TokenFormat.roundedUSD(10705.754), Decimal(string: "10705.75"))
        XCTAssertEqual(TokenFormat.roundedUSD(-10705.755), Decimal(string: "-10705.76"))
        XCTAssertEqual(TokenFormat.roundedUSD(0.005), Decimal(string: "0.01"))
        XCTAssertEqual(TokenFormat.roundedUSD(-0.001), 0)
        XCTAssertEqual(TokenFormat.roundedUSD(.nan), 0)
    }

    func testUSDZeroAndNegatives() {
        XCTAssertEqual(TokenFormat.usd(0), "$0.00")
        XCTAssertEqual(TokenFormat.usd(-4.2), "-$4.20")
        XCTAssertEqual(TokenFormat.usd(-1_234.5), "-$1,234.50")
        XCTAssertEqual(TokenFormat.usd(-0.001), "$0.00")
    }

    func testSpokenEnglishSpellsTheMagnitude() {
        let value = TokenFormat.spoken(4_330_000_000, locale: Locale(identifier: "en_US"))
        XCTAssertFalse(value.isEmpty)
        for letter in ["B", "M", "K"] {
            XCTAssertFalse(value.hasSuffix(letter), value)
        }
        XCTAssertTrue(value.contains("billion"), value)
    }

    func testSpokenCurrentLocaleIsNotEmpty() {
        XCTAssertFalse(TokenFormat.spoken(4_330_000_000).isEmpty)
        XCTAssertFalse(TokenFormat.spoken(0).isEmpty)
    }
}
