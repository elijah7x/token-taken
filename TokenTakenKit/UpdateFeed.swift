import Foundation

public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let marketing: [Int]
    public let build: Int

    public init?(version: String, build: String) {
        var trimmedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedVersion.hasPrefix("v") || trimmedVersion.hasPrefix("V") {
            trimmedVersion.removeFirst()
        }
        guard !trimmedVersion.isEmpty else { return nil }

        let parts = trimmedVersion.split(separator: ".", omittingEmptySubsequences: false)
        var parsedMarketing: [Int] = []
        parsedMarketing.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty,
                  part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(part) else {
                return nil
            }
            parsedMarketing.append(number)
        }

        let trimmedBuild = build.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBuild.isEmpty,
              trimmedBuild.utf8.allSatisfy({ (48...57).contains($0) }),
              let parsedBuild = Int(trimmedBuild) else {
            return nil
        }

        self.marketing = parsedMarketing
        self.build = parsedBuild
    }

    public var description: String {
        "\(marketing.map(String.init).joined(separator: ".")) (\(build))"
    }

    private var normalizedMarketing: [Int] {
        var result = marketing
        while result.last == 0 {
            result.removeLast()
        }
        return result
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.build == rhs.build && lhs.normalizedMarketing == rhs.normalizedMarketing
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(normalizedMarketing)
        hasher.combine(build)
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.marketing.count, rhs.marketing.count)
        for index in 0..<count {
            let left = index < lhs.marketing.count ? lhs.marketing[index] : 0
            let right = index < rhs.marketing.count ? rhs.marketing[index] : 0
            if left != right {
                return left < right
            }
        }
        return lhs.build < rhs.build
    }
}

public struct UpdateFeed: Decodable, Sendable, Equatable {
    public var schemaVersion: Int
    public var version: String
    public var build: String
    public var minimumSystemVersion: String
    public var downloadURL: URL
    public var sha256: String
    public var size: Int64
    public var notes: String
    public var publishedAt: String?

    public init(
        schemaVersion: Int,
        version: String,
        build: String,
        minimumSystemVersion: String,
        downloadURL: URL,
        sha256: String,
        size: Int64,
        notes: String,
        publishedAt: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.version = version
        self.build = build
        self.minimumSystemVersion = minimumSystemVersion
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.size = size
        self.notes = notes
        self.publishedAt = publishedAt
    }

    public var appVersion: AppVersion? {
        AppVersion(version: version, build: build)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case version
        case build
        case minimumSystemVersion = "minimum_system_version"
        case downloadURL = "download_url"
        case sha256
        case size
        case notes
        case publishedAt = "published_at"
    }
}

public enum UpdateFeedSelection {
    public static func newest(
        _ feeds: [UpdateFeed],
        newerThan current: AppVersion,
        systemVersion: OperatingSystemVersion,
        allowedDownloadHosts: Set<String>
    ) -> UpdateFeed? {
        let allowedHosts = Set(allowedDownloadHosts.map { $0.lowercased() })
        let currentSystem = [
            systemVersion.majorVersion,
            systemVersion.minorVersion,
            systemVersion.patchVersion,
        ]

        var groupedByVersion: [AppVersion: [(feed: UpdateFeed, minimumSystem: [Int])]] = [:]

        for feed in feeds {
            guard feed.schemaVersion == 1,
                  let version = feed.appVersion,
                  feed.downloadURL.scheme?.lowercased() == "https",
                  feed.downloadURL.port == nil || feed.downloadURL.port == 443,
                  let host = feed.downloadURL.host?.lowercased(),
                  allowedHosts.contains(host),
                  isLowercaseSHA256Hex(feed.sha256),
                  feed.size > 0,
                  let minimumSystem = parseSystemVersion(feed.minimumSystemVersion) else {
                continue
            }
            groupedByVersion[version, default: []].append((feed, minimumSystem))
        }

        var best: (version: AppVersion, feed: UpdateFeed)?
        for (version, candidates) in groupedByVersion {
            guard version > current else { continue }
            guard let highestMinimumSystem = candidates.map(\.minimumSystem).max(by: {
                compareVersionComponents($0, $1) == .orderedAscending
            }),
                  compareVersionComponents(highestMinimumSystem, currentSystem) != .orderedDescending else {
                continue
            }
            let hashes = Set(candidates.map(\.feed.sha256))
            // Conflicting checksums for the same version cannot be trusted from either source.
            guard hashes.count == 1, let chosen = candidates.first?.feed else { continue }
            if let existing = best, existing.version >= version { continue }
            best = (version, chosen)
        }
        return best?.feed
    }

    private static func isLowercaseSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func parseSystemVersion(_ raw: String) -> [Int]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        var components: [Int] = []
        components.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty,
                  part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(part) else {
                return nil
            }
            components.append(number)
        }
        return components
    }

    private static func compareVersionComponents(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }
}
