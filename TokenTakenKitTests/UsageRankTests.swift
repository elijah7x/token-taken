import XCTest
import TokenTakenKit

final class UsageRankTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(UsageRank.version, "rank-curve-2026-11")
    }

    func testAnchorsMapExactly() {
        let anchors: [(Int64, Double)] = [
            (100_000, 99),
            (1_000_000, 97),
            (5_000_000, 93),
            (20_000_000, 85),
            (100_000_000, 70),
            (350_000_000, 50),
            (900_000_000, 10),
            (2_200_000_000, 5),
            (5_600_000_000, 2),
            (8_000_000_000, 1),
            (13_000_000_000, 0.5),
            (25_000_000_000, 0.1),
            (50_000_000_000, 0.05),
            (100_000_000_000, 0.01),
        ]

        for (tokens, expected) in anchors {
            guard let actual = UsageRank.topPercent(last30DaysTokens: tokens) else {
                XCTFail("Expected non-nil rank for \(tokens) tokens")
                continue
            }
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "Anchor mismatch for \(tokens)")
        }
    }

    func testValueBetweenAnchorsLiesStrictlyBetween() throws {
        let mid = try XCTUnwrap(UsageRank.topPercent(last30DaysTokens: 200_000_000))
        XCTAssertGreaterThan(mid, 50)
        XCTAssertLessThan(mid, 70)

        // Geometric midpoint of 100M (70%) and 400M? Use 100k (99%) and 1M (97%) -> sqrt(10^11) ~= 316228.
        let geoMidTokens = Int64((100_000.0 * 1_000_000.0).squareRoot().rounded())
        let geoMidRank = try XCTUnwrap(UsageRank.topPercent(last30DaysTokens: geoMidTokens))
        let expectedGeoRank = (99.0 * 97.0).squareRoot()
        XCTAssertEqual(geoMidRank, expectedGeoRank, accuracy: 1e-3)
    }

    func testMonotonicityOverSweep() throws {
        var probes: [Int64] = []
        var value: Double = 100_000
        while value < 100_000_000_000 {
            probes.append(Int64(value))
            value *= 1.15
        }
        probes.append(100_000_000_000)

        var previous = try XCTUnwrap(UsageRank.topPercent(last30DaysTokens: probes[0]))
        for tokens in probes.dropFirst() {
            let current = try XCTUnwrap(UsageRank.topPercent(last30DaysTokens: tokens))
            XCTAssertLessThan(current, previous, "Rank must strictly decrease at \(tokens) tokens")
            previous = current
        }
    }

    func testClampingAtBothEnds() {
        XCTAssertEqual(UsageRank.topPercent(last30DaysTokens: 1), 99)
        XCTAssertEqual(UsageRank.topPercent(last30DaysTokens: 50_000), 99)
        XCTAssertEqual(UsageRank.topPercent(last30DaysTokens: 99_999), 99)
        XCTAssertEqual(UsageRank.topPercent(last30DaysTokens: 100_000_000_001), 0.01)
        XCTAssertEqual(UsageRank.topPercent(last30DaysTokens: 500_000_000_000), 0.01)
    }

    func testZeroAndNegativeReturnNil() {
        XCTAssertNil(UsageRank.topPercent(last30DaysTokens: 0))
        XCTAssertNil(UsageRank.topPercent(last30DaysTokens: -1))
        XCTAssertNil(UsageRank.topPercent(last30DaysTokens: Int64.min))
    }

    func testFormatting() {
        XCTAssertEqual(UsageRank.formatted(57.3), "57.3%")
        XCTAssertEqual(UsageRank.formatted(8.66), "8.7%")
        XCTAssertEqual(UsageRank.formatted(1.0), "1.0%")
        XCTAssertEqual(UsageRank.formatted(0.4249), "0.42%")
        XCTAssertEqual(UsageRank.formatted(0.001), "0.01%")
        XCTAssertEqual(UsageRank.formatted(0), "0.01%")
        XCTAssertEqual(UsageRank.formatted(-5), "0.01%")
    }
}
