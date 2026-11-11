import Foundation
import Observation

@Observable
@MainActor
final class UpdateChecker {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case noRelease
        case failed(message: String)
    }

    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/elijah7x/token-taken/releases/latest"
    )!

    private(set) var state: State = .idle

    var isChecking: Bool { state == .checking }

    func check(bundle: Bundle = .main, session: URLSession = .shared) async {
        guard state != .checking else { return }
        state = .checking

        var request = URLRequest(url: Self.latestReleaseURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("TokenTaken", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                state = .failed(message: String(localized: "Could not check for updates."))
                return
            }
            if http.statusCode == 404 {
                state = .noRelease
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                state = .failed(message: String(localized: "Update check failed (HTTP \(http.statusCode))."))
                return
            }

            let release = try JSONDecoder().decode(GitHubLatestRelease.self, from: data)
            let remoteVersion = Self.stripLeadingV(release.tagName)
            guard !remoteVersion.isEmpty, release.htmlURL.scheme?.lowercased() == "https" else {
                state = .failed(message: String(localized: "Could not check for updates."))
                return
            }

            let currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
            let currentBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

            if Self.isNewer(remoteTag: remoteVersion, thanVersion: currentVersion, build: currentBuild) {
                state = .available(version: remoteVersion, url: release.htmlURL)
            } else {
                state = .upToDate
            }
        } catch is CancellationError {
            state = .idle
        } catch let error as URLError where error.code == .cancelled {
            state = .idle
        } catch is DecodingError {
            state = .failed(message: String(localized: "Could not check for updates."))
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    nonisolated static func stripLeadingV(_ tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    nonisolated static func isNewer(remoteTag: String, thanVersion currentVersion: String, build currentBuild: String) -> Bool {
        let remote = ParsedVersion(tag: remoteTag)
        let current = ParsedVersion(version: currentVersion, build: currentBuild)

        let coreOrder = compareIntComponents(remote.core, current.core)
        if coreOrder != .orderedSame {
            return coreOrder == .orderedDescending
        }

        let prereleaseOrder = comparePrerelease(remote.prerelease, current.prerelease)
        if prereleaseOrder != .orderedSame {
            return prereleaseOrder == .orderedDescending
        }

        guard let remoteBuild = remote.build, !remoteBuild.isEmpty else {
            return false
        }
        let localBuild = current.build ?? "0"
        return remoteBuild.compare(localBuild, options: .numeric) == .orderedDescending
    }

    nonisolated private static func compareIntComponents(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right {
                return left < right ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    nonisolated private static func comparePrerelease(_ lhs: [String]?, _ rhs: [String]?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil):
            return .orderedSame
        case (nil, .some):
            return .orderedDescending
        case (.some, nil):
            return .orderedAscending
        case (let left?, let right?):
            let count = min(left.count, right.count)
            for index in 0..<count {
                let a = left[index]
                let b = right[index]
                if a == b { continue }
                switch (Int(a), Int(b)) {
                case (let ai?, let bi?):
                    return ai < bi ? .orderedAscending : .orderedDescending
                case (.some, nil):
                    return .orderedAscending
                case (nil, .some):
                    return .orderedDescending
                case (nil, nil):
                    return a < b ? .orderedAscending : .orderedDescending
                }
            }
            if left.count == right.count { return .orderedSame }
            return left.count < right.count ? .orderedAscending : .orderedDescending
        }
    }
}

private struct GitHubLatestRelease: Decodable, Sendable {
    let tagName: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

private struct ParsedVersion {
    let core: [Int]
    let prerelease: [String]?
    let build: String?

    init(tag: String) {
        let plusParts = tag.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        let withoutBuild = String(plusParts[0])
        build = plusParts.count > 1 ? String(plusParts[1]) : nil

        let dashParts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        core = dashParts[0].split(separator: ".").map { Int($0) ?? 0 }
        prerelease = dashParts.count > 1 ? dashParts[1].split(separator: ".").map(String.init) : nil
    }

    init(version: String, build: String) {
        let parsed = ParsedVersion(tag: UpdateChecker.stripLeadingV(version))
        self.core = parsed.core
        self.prerelease = parsed.prerelease
        let trimmedBuild = build.trimmingCharacters(in: .whitespacesAndNewlines)
        self.build = trimmedBuild.isEmpty ? parsed.build : trimmedBuild
    }
}
