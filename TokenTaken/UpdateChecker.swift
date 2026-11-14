import AppKit
import Foundation
import Observation
import Security
import TokenTakenKit
import os

struct AvailableUpdate: Equatable, Sendable {
    let version: AppVersion
    let feed: UpdateFeed
}

@Observable
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    enum State: Equatable, Sendable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case failed(message: String)
        case unsupported
    }

    private enum UpdateSourceKind: Sendable {
        case staticFeed
        case githubReleases
    }

    private struct UpdateSource: Sendable {
        let kind: UpdateSourceKind
        let url: URL
    }

    // Placeholder endpoints until release hosting is finalized.
    nonisolated private static let updateSources: [UpdateSource] = [
        UpdateSource(
            kind: .staticFeed,
            url: URL(string: "https://elijah.ac.cn/token-taken/updates.json")!
        ),
        UpdateSource(
            kind: .githubReleases,
            url: URL(string: "https://api.github.com/repos/elijah7x/token-taken/releases?per_page=10")!
        ),
    ]

    nonisolated static let allowedDownloadHosts: Set<String> = [
        "elijah.ac.cn",
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    private static let initialDelay: TimeInterval = 15
    private static let checkInterval: TimeInterval = 6 * 60 * 60
    private static let checkTolerance: TimeInterval = 15 * 60
    nonisolated private static let requestTimeout: TimeInterval = 10

    private enum Keys {
        static let lastCheckedAt = "updateChecker.lastCheckedAt"
    }

    private(set) var state: State
    private(set) var lastCheckedAt: Date?
    var isChecking: Bool { state == .checking }
    var currentVersion: AppVersion? { Self.bundleAppVersion(.main) }

    @ObservationIgnored private let isSupported: Bool
    @ObservationIgnored private var automaticCheck: (@MainActor () -> Bool)?
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private let logger = Logger(subsystem: "io.github.elijah7x.TokenTaken", category: "updater")

    private init() {
        lastCheckedAt = UserDefaults.standard.object(forKey: Keys.lastCheckedAt) as? Date
        let supported = Self.signingTeamIdentifier() != nil && Self.bundleAppVersion(.main) != nil
        self.isSupported = supported
        self.state = supported ? .idle : .unsupported
    }

    func start(automatic: @escaping @MainActor () -> Bool) {
        automaticCheck = automatic
        guard isSupported, checkTask == nil else { return }

        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handleDidBecomeActive()
                }
            }
        }

        checkTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.initialDelay), tolerance: .seconds(2))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            if self.automaticCheck?() == true, !self.isChecking {
                let checkedRecently = self.lastCheckedAt.map { Date.now.timeIntervalSince($0) < 60 } ?? false
                if !checkedRecently {
                    await self.performCheck(userInitiated: false)
                }
            }

            while !Task.isCancelled {
                let delay: TimeInterval
                if let lastCheckedAt = self.lastCheckedAt {
                    let remaining = Self.checkInterval - Date.now.timeIntervalSince(lastCheckedAt)
                    delay = remaining > 0 ? remaining : Self.checkInterval
                } else {
                    delay = Self.checkInterval
                }
                do {
                    try await Task.sleep(
                        for: .seconds(delay),
                        tolerance: .seconds(Self.checkTolerance)
                    )
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                guard self.automaticCheck?() == true, !self.isChecking else { continue }
                if let lastCheckedAt = self.lastCheckedAt,
                   Date.now.timeIntervalSince(lastCheckedAt) < Self.checkInterval {
                    continue
                }
                await self.performCheck(userInitiated: false)
            }
        }
    }

    func checkNow() async {
        guard isSupported else {
            state = .unsupported
            return
        }
        await performCheck(userInitiated: true)
    }

    // MARK: - Checking

    private func handleDidBecomeActive() async {
        guard isSupported, automaticCheck?() == true, !isChecking else { return }
        let stale = lastCheckedAt.map { Date.now.timeIntervalSince($0) >= Self.checkInterval } ?? true
        if stale {
            await performCheck(userInitiated: false)
        }
    }

    private func performCheck(userInitiated: Bool) async {
        guard isSupported, let currentVersion else {
            if userInitiated { state = .unsupported }
            return
        }
        guard !isChecking else { return }

        let previousState = state
        state = .checking

        let userAgentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let results = await Self.fetchAllSources(userAgentVersion: userAgentVersion)

        guard !Task.isCancelled else {
            state = previousState
            return
        }

        let failures = results.compactMap { result -> String? in
            if case .failed(let message) = result { return message }
            return nil
        }

        if !results.isEmpty, failures.count == results.count {
            let message = failures.first ?? String(localized: "Could not check for updates.")
            logger.error("Update check failed across all sources: \(message, privacy: .public)")
            if userInitiated {
                state = .failed(message: message)
            } else {
                state = previousState
            }
            return
        }

        let allFeeds = results.flatMap { result -> [UpdateFeed] in
            if case .feeds(let feeds) = result { return feeds }
            return []
        }

        let selected = UpdateFeedSelection.newest(
            allFeeds,
            newerThan: currentVersion,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersion,
            allowedDownloadHosts: Self.allowedDownloadHosts
        )

        let now = Date.now
        lastCheckedAt = now
        UserDefaults.standard.set(now, forKey: Keys.lastCheckedAt)

        if let selected, let version = selected.appVersion {
            let update = AvailableUpdate(version: version, feed: selected)
            state = .available(update)
            if automaticCheck?() == true {
                AppUpdater.shared.prepare(update)
            }
        } else {
            state = .upToDate
        }
    }

    // MARK: - Fetching

    private enum SourceFetchResult: Sendable {
        case feeds([UpdateFeed])
        case noData
        case failed(String)
    }

    nonisolated private static func fetchAllSources(userAgentVersion: String) async -> [SourceFetchResult] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.waitsForConnectivity = false

        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let redirectDelegate = OriginPinnedRedirectDelegate()
        let userAgent = "TokenTaken/\(userAgentVersion)"

        return await withTaskGroup(of: SourceFetchResult.self, returning: [SourceFetchResult].self) { group in
            for source in updateSources {
                group.addTask {
                    await fetchSource(
                        source,
                        session: session,
                        redirectDelegate: redirectDelegate,
                        userAgent: userAgent
                    )
                }
            }

            var collected: [SourceFetchResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
    }

    nonisolated private static func fetchSource(
        _ source: UpdateSource,
        session: URLSession,
        redirectDelegate: OriginPinnedRedirectDelegate,
        userAgent: String
    ) async -> SourceFetchResult {
        var request = URLRequest(url: source.url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = requestTimeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        switch source.kind {
        case .staticFeed:
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        case .githubReleases:
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        }

        do {
            let (data, response) = try await session.data(for: request, delegate: redirectDelegate)
            guard let http = response as? HTTPURLResponse else {
                return .failed(String(localized: "Could not check for updates."))
            }
            if http.statusCode == 404 {
                return .noData
            }
            guard (200...299).contains(http.statusCode) else {
                return .failed(String(localized: "Update check failed (HTTP \(http.statusCode))."))
            }

            switch source.kind {
            case .staticFeed:
                let feed = try JSONDecoder().decode(UpdateFeed.self, from: data)
                return .feeds([feed])
            case .githubReleases:
                let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
                return .feeds(feeds(from: releases))
            }
        } catch is CancellationError {
            return .noData
        } catch let error as URLError where error.code == .cancelled {
            return .noData
        } catch is DecodingError {
            return .failed(String(localized: "Could not read update information."))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    nonisolated private static func feeds(from releases: [GitHubRelease]) -> [UpdateFeed] {
        var results: [UpdateFeed] = []
        for release in releases {
            guard !release.draft, !release.prerelease else { continue }
            for asset in release.assets {
                guard let parsed = parseAssetName(asset.name),
                      let downloadURL = URL(string: asset.browserDownloadURL) else {
                    continue
                }
                let sha256: String
                if let digest = asset.digest, digest.hasPrefix("sha256:") {
                    sha256 = String(digest.dropFirst("sha256:".count)).lowercased()
                } else {
                    sha256 = ""
                }
                results.append(
                    UpdateFeed(
                        schemaVersion: 1,
                        version: parsed.version,
                        build: parsed.build,
                        minimumSystemVersion: "26.0",
                        downloadURL: downloadURL,
                        sha256: sha256,
                        size: asset.size ?? 0,
                        notes: release.body ?? "",
                        publishedAt: release.publishedAt
                    )
                )
                break
            }
        }
        return results
    }

    nonisolated private static func parseAssetName(_ name: String) -> (version: String, build: String)? {
        let prefix = "TokenTaken-"
        let suffix = ".dmg"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        let stem = name[start..<end]
        guard let dashIndex = stem.lastIndex(of: "-") else { return nil }
        let versionPart = String(stem[..<dashIndex])
        let buildPart = String(stem[stem.index(after: dashIndex)...])
        guard AppVersion(version: versionPart, build: buildPart) != nil else { return nil }
        return (versionPart, buildPart)
    }

    // MARK: - Shared signature and bundle helpers

    nonisolated static func bundleAppVersion(_ bundle: Bundle) -> AppVersion? {
        guard let marketing = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            return nil
        }
        return AppVersion(version: marketing, build: build)
    }

    nonisolated static func signingTeamIdentifier() -> String? {
        #if DEBUG
        return nil
        #else
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String,
              !teamID.isEmpty,
              teamID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            return nil
        }
        // Require Developer ID Application signing rather than ad-hoc or Apple Development.
        let requirementText = """
        anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] \
        and certificate leaf[subject.OU] = "\(teamID)"
        """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidityWithErrors(staticCode, [], requirement, nil) == errSecSuccess else {
            return nil
        }
        return teamID
        #endif
    }
}

private final class OriginPinnedRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url,
              let redirected = request.url,
              redirected.scheme?.lowercased() == "https",
              redirected.host?.lowercased() == original.host?.lowercased(),
              redirected.port == nil || redirected.port == 443 else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let browserDownloadURL: String
        let size: Int64?
        let digest: String?

        private enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
            case digest
        }
    }

    let body: String?
    let publishedAt: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    private enum CodingKeys: String, CodingKey {
        case body
        case publishedAt = "published_at"
        case draft
        case prerelease
        case assets
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt)
        draft = try container.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        prerelease = try container.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
        assets = try container.decodeIfPresent([Asset].self, forKey: .assets) ?? []
    }
}
