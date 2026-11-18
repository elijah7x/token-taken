import XCTest
@testable import TokenTakenKit

final class UpdateFeedTests: XCTestCase {
    private let allowedHosts: Set<String> = ["updates.example.com", "cdn.example.net"]
    private let system26 = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
    private let validHashA = String(repeating: "a", count: 64)
    private let validHashB = String(repeating: "b", count: 64)

    func testAppVersionParsingAndDescription() {
        let plain = AppVersion(version: "0.1.0", build: "29")
        XCTAssertEqual(plain?.marketing, [0, 1, 0])
        XCTAssertEqual(plain?.build, 29)
        XCTAssertEqual(plain?.description, "0.1.0 (29)")

        let withLowerV = AppVersion(version: "v0.1.0", build: "29")
        XCTAssertEqual(withLowerV, plain)

        let withUpperV = AppVersion(version: "V0.1.0", build: "29")
        XCTAssertEqual(withUpperV, plain)

        XCTAssertNil(AppVersion(version: "", build: "1"))
        XCTAssertNil(AppVersion(version: "0.1.0-beta.1", build: "1"))
        XCTAssertNil(AppVersion(version: "0..1", build: "1"))
        XCTAssertNil(AppVersion(version: "0.1.", build: "1"))
        XCTAssertNil(AppVersion(version: "vv0.1.0", build: "1"))
        XCTAssertNil(AppVersion(version: "0.1.0", build: ""))
        XCTAssertNil(AppVersion(version: "0.1.0", build: "29a"))
        XCTAssertNil(AppVersion(version: "0.1.0", build: "-1"))
    }

    func testAppVersionOrdering() throws {
        let base = try XCTUnwrap(AppVersion(version: "0.1.0", build: "28"))
        let buildBump = try XCTUnwrap(AppVersion(version: "0.1.0", build: "29"))
        XCTAssertLessThan(base, buildBump)

        let nine = try XCTUnwrap(AppVersion(version: "0.1.9", build: "100"))
        let ten = try XCTUnwrap(AppVersion(version: "0.1.10", build: "1"))
        XCTAssertLessThan(nine, ten)

        let twoParts = try XCTUnwrap(AppVersion(version: "0.1", build: "28"))
        XCTAssertEqual(twoParts, base)
        XCTAssertLessThan(twoParts, buildBump)

        let ledV = try XCTUnwrap(AppVersion(version: "v0.1.10", build: "1"))
        XCTAssertEqual(ledV, ten)
        XCTAssertGreaterThan(ledV, nine)
    }

    func testDecodeSampleFeedJSON() throws {
        let json = """
        {
          "schema_version": 1,
          "version": "0.2.0",
          "build": "42",
          "minimum_system_version": "26.0",
          "download_url": "https://updates.example.com/App-0.2.0-42.dmg",
          "sha256": "\(validHashA)",
          "size": 12345678,
          "notes": "## What's New\\n- Faster refresh",
          "published_at": "2026-11-14T10:00:00Z"
        }
        """
        let feed = try JSONDecoder().decode(UpdateFeed.self, from: Data(json.utf8))
        XCTAssertEqual(feed.schemaVersion, 1)
        XCTAssertEqual(feed.version, "0.2.0")
        XCTAssertEqual(feed.build, "42")
        XCTAssertEqual(feed.minimumSystemVersion, "26.0")
        XCTAssertEqual(feed.downloadURL.absoluteString, "https://updates.example.com/App-0.2.0-42.dmg")
        XCTAssertEqual(feed.sha256, validHashA)
        XCTAssertEqual(feed.size, 12_345_678)
        XCTAssertEqual(feed.notes, "## What's New\n- Faster refresh")
        XCTAssertEqual(feed.publishedAt, "2026-11-14T10:00:00Z")
        XCTAssertEqual(feed.appVersion, AppVersion(version: "0.2.0", build: "42"))

        let minimalJSON = """
        {
          "schema_version": 1,
          "version": "v0.2.1",
          "build": "43",
          "minimum_system_version": "26.0",
          "download_url": "https://updates.example.com/App-0.2.1-43.dmg",
          "sha256": "\(validHashB)",
          "size": 1000,
          "notes": ""
        }
        """
        let minimal = try JSONDecoder().decode(UpdateFeed.self, from: Data(minimalJSON.utf8))
        XCTAssertNil(minimal.publishedAt)
        XCTAssertEqual(minimal.notes, "")
        XCTAssertEqual(minimal.appVersion, AppVersion(version: "0.2.1", build: "43"))
    }

    func testSelectionPicksHighestValidNewerFeed() throws {
        let current = try XCTUnwrap(AppVersion(version: "0.1.0", build: "28"))
        let same = makeFeed(version: "0.1.0", build: "28")
        let older = makeFeed(version: "0.0.9", build: "99")
        let newerBuild = makeFeed(version: "0.1.0", build: "29", sha256: validHashA)
        let newerMinor = makeFeed(version: "0.2.0", build: "1", sha256: validHashB)

        let selected = UpdateFeedSelection.newest(
            [same, older, newerBuild, newerMinor],
            newerThan: current,
            systemVersion: system26,
            allowedDownloadHosts: allowedHosts
        )
        XCTAssertEqual(selected, newerMinor)
    }

    func testSelectionRejectsNotNewerThanCurrent() throws {
        let current = try XCTUnwrap(AppVersion(version: "0.1.0", build: "29"))
        let same = makeFeed(version: "0.1.0", build: "29")
        let olderBuild = makeFeed(version: "0.1.0", build: "28")
        let olderVersion = makeFeed(version: "0.0.9", build: "100")

        XCTAssertNil(UpdateFeedSelection.newest(
            [same, olderBuild, olderVersion],
            newerThan: current,
            systemVersion: system26,
            allowedDownloadHosts: allowedHosts
        ))
    }

    func testSelectionRejectsInvalidSchemaVersion() throws {
        let current = try XCTUnwrap(AppVersion(version: "0.1.0", build: "1"))
        let schemaZero = makeFeed(schemaVersion: 0)
        let schemaTwo = makeFeed(schemaVersion: 2)

        XCTAssertNil(UpdateFeedSelection.newest(
            [schemaZero, schemaTwo],
            newerThan: current,
            systemVersion: system26,
            allowedDownloadHosts: allowedHosts
        ))
    }

    func testSelectionRejectsUnparsableVersionOrBuild() throws {
        let current = try XCTUnwrap(AppVersion(version: "0.1.0", build: "1"))
        let badVersion = makeFeed(version: "0.2.0-rc1")
        let badBuild = makeFeed(build: "abc")

        XCTAssertNil(UpdateFeedSelection.newest(
            [badVersion, badBuild],
            newerThan: current,
            systemVersion: system26,
            allowedDownloadHosts: allowedHosts
        ))
    }

    func testSelectionRejectsNonHTTPSDownloadURL() throws {
        let current = try XCTUnwrap(AppVersion(version: "0.1.0", build: "1"))
        let httpFeed = makeFeed(downloadURL: URL(string: "http://updates.example.com/App.dmg")!)
        let fileFeed = makeFeed(downloadURL: URL(string: "file:///tmp/App.dmg")!)

        XCTAssertNil(UpdateFeedSelection.newest(
            [httpFeed, fileFeed],
            newerThan: current,
            systemVersion: system26,
            allowedDownloadHosts: allowedHosts
        ))
    }

    func testSelectionRejectsDisallowedHost() throws {
        let current = try XCTUnwrap(AppVersion(version: "0.1.0", build: "1"))
        let untrusted = makeFeed(downloadURL: URL(string: "https://untrusted.example.org/App.dmg")!)

        XCTAssertNil(UpdateFeedSelection.newest(
            [untrusted],
            newerThan: current,
            systemVersion: system26,
            allowedDownloadHosts: allowedHosts
        ))
    }

    func testSelectionRejectsInvalidSHA256() throws {
        let current = try XCTUnwrap(AppVersion(version: "0.1.0", build: "1"))
        let shortHash = makeFeed(sha256: String(repeating: "a", count: 63))
        let uppercaseHash = makeFeed(sha256: String(repeating: "A", count: 64))
        let nonHexHash = makeFeed(sha256: String(repeating: "g", count: 64))

        XCTAssertNil(UpdateFeedSelection.newest(
            [shortHash, uppercaseHash, nonHexHash],
            newerThan: current,
            systemVersion: system26,
            allowedDownloadHosts: allowedHosts
        ))
    }

    func testSelectionRejectsNonPositiveSize() throws {
        let current = try XCTUnwrap(AppVersion(version: "0.1.0", build: "1"))
        let zeroSize = makeFeed(size: 0)
        let negativeSize = makeFeed(size: -512)

        XCTAssertNil(UpdateFeedSelection.newest(
            [zeroSize, negativeSize],
            newerThan: current,
            systemVersion: system26,
            allowedDownloadHosts: allowedHosts
        ))
    }

    func testSelectionRejectsHigherMinimumSystemVersion() throws {
        let current = try XCTUnwrap(AppVersion(version: "0.1.0", build: "1"))
        let tooHighMinor = makeFeed(minimumSystemVersion: "26.1")
        let tooHighMajor = makeFeed(minimumSystemVersion: "27.0")
        let unparsableOS = makeFeed(minimumSystemVersion: "26.x")

        XCTAssertNil(UpdateFeedSelection.newest(
            [tooHighMinor, tooHighMajor, unparsableOS],
            newerThan: current,
            systemVersion: system26,
            allowedDownloadHosts: allowedHosts
        ))

        let exactMatch = makeFeed(minimumSystemVersion: "26.0")
        XCTAssertEqual(
            UpdateFeedSelection.newest(
                [exactMatch],
                newerThan: current,
                systemVersion: system26,
                allowedDownloadHosts: allowedHosts
            ),
            exactMatch
        )
    }

    func testSelectionDropsBothOnConflictingSHA256ForSameVersion() throws {
        let current = try XCTUnwrap(AppVersion(version: "0.1.0", build: "1"))
        let feedA = makeFeed(
            version: "0.2.0",
            build: "10",
            downloadURL: URL(string: "https://updates.example.com/App.dmg")!,
            sha256: validHashA
        )
        let feedB = makeFeed(
            version: "v0.2.0",
            build: "10",
            downloadURL: URL(string: "https://cdn.example.net/App.dmg")!,
            sha256: validHashB
        )

        XCTAssertNil(UpdateFeedSelection.newest(
            [feedA, feedB],
            newerThan: current,
            systemVersion: system26,
            allowedDownloadHosts: allowedHosts
        ))

        let safeLower = makeFeed(version: "0.1.5", build: "5", sha256: validHashA)
        XCTAssertEqual(
            UpdateFeedSelection.newest(
                [feedA, feedB, safeLower],
                newerThan: current,
                systemVersion: system26,
                allowedDownloadHosts: allowedHosts
            ),
            safeLower
        )

        let matchingMirror = makeFeed(
            version: "0.2.0",
            build: "10",
            downloadURL: URL(string: "https://cdn.example.net/App.dmg")!,
            sha256: validHashA
        )
        XCTAssertEqual(
            UpdateFeedSelection.newest(
                [feedA, matchingMirror],
                newerThan: current,
                systemVersion: system26,
                allowedDownloadHosts: allowedHosts
            ),
            feedA
        )
    }

    func testSelectionAllowsNilOr443PortAndRejectsOtherPorts() throws {
        let current = try XCTUnwrap(AppVersion(version: "0.1.0", build: "1"))
        let customPort = makeFeed(downloadURL: URL(string: "https://updates.example.com:8443/App.dmg")!)
        let port80 = makeFeed(downloadURL: URL(string: "https://updates.example.com:80/App.dmg")!)

        XCTAssertNil(UpdateFeedSelection.newest(
            [customPort, port80],
            newerThan: current,
            systemVersion: system26,
            allowedDownloadHosts: allowedHosts
        ))

        let explicit443 = makeFeed(downloadURL: URL(string: "https://updates.example.com:443/App.dmg")!)
        XCTAssertEqual(
            UpdateFeedSelection.newest(
                [explicit443],
                newerThan: current,
                systemVersion: system26,
                allowedDownloadHosts: allowedHosts
            ),
            explicit443
        )
    }

    func testSelectionRejectsVersionGroupIfAnySourceExceedsSystemVersion() throws {
        let current = try XCTUnwrap(AppVersion(version: "0.1.0", build: "1"))
        let staticFeed27 = makeFeed(
            version: "0.2.0",
            build: "10",
            minimumSystemVersion: "27.0",
            downloadURL: URL(string: "https://updates.example.com/App-0.2.0-10.dmg")!,
            sha256: validHashA
        )
        let githubFallback26 = makeFeed(
            version: "0.2.0",
            build: "10",
            minimumSystemVersion: "26.0",
            downloadURL: URL(string: "https://cdn.example.net/App-0.2.0-10.dmg")!,
            sha256: validHashA
        )

        XCTAssertNil(UpdateFeedSelection.newest(
            [staticFeed27, githubFallback26],
            newerThan: current,
            systemVersion: system26,
            allowedDownloadHosts: allowedHosts
        ))
        XCTAssertNil(UpdateFeedSelection.newest(
            [githubFallback26, staticFeed27],
            newerThan: current,
            systemVersion: system26,
            allowedDownloadHosts: allowedHosts
        ))

        let compatibleLower = makeFeed(
            version: "0.1.5",
            build: "5",
            minimumSystemVersion: "26.0",
            sha256: validHashB
        )
        XCTAssertEqual(
            UpdateFeedSelection.newest(
                [githubFallback26, staticFeed27, compatibleLower],
                newerThan: current,
                systemVersion: system26,
                allowedDownloadHosts: allowedHosts
            ),
            compatibleLower
        )
    }

    private func makeFeed(
        schemaVersion: Int = 1,
        version: String = "0.2.0",
        build: String = "10",
        minimumSystemVersion: String = "26.0",
        downloadURL: URL = URL(string: "https://updates.example.com/App-0.2.0-10.dmg")!,
        sha256: String? = nil,
        size: Int64 = 1024,
        notes: String = "Release notes"
    ) -> UpdateFeed {
        UpdateFeed(
            schemaVersion: schemaVersion,
            version: version,
            build: build,
            minimumSystemVersion: minimumSystemVersion,
            downloadURL: downloadURL,
            sha256: sha256 ?? validHashA,
            size: size,
            notes: notes,
            publishedAt: "2026-11-14T10:00:00Z"
        )
    }
}
