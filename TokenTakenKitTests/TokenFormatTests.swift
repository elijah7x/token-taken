import XCTest
@testable import TokenTakenKit

final class TokenFormatTests: XCTestCase {
    func testUSDGroupsThousandsAndKeepsTwoDecimals() {
        XCTAssertEqual(TokenFormat.usd(10705.755), "$10,705.76")
        XCTAssertEqual(TokenFormat.usd(1_234.5), "$1,234.50")
        XCTAssertEqual(TokenFormat.usd(132.26), "$132.26")
        XCTAssertEqual(TokenFormat.usd(999), "$999.00")
        XCTAssertEqual(TokenFormat.usd(999_999.995), "$1,000,000.00")
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
