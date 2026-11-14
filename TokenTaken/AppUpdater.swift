import AppKit
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import Observation
import Security
import Synchronization
import TokenTakenKit
import os

struct UpdateNotice: Equatable, Codable, Sendable {
    let version: String
    let notes: String
}

@Observable
@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    enum Phase: Equatable, Sendable {
        case idle
        case downloading(fraction: Double)
        case verifying
        case ready(AvailableUpdate)
        case installing
        case failed(message: String)
    }

    private enum Keys {
        static let justUpdated = "appUpdater.justUpdated"
        static let pendingVersion = "appUpdater.pendingVersion"
        static let pendingBuild = "appUpdater.pendingBuild"
        static let pendingNotes = "appUpdater.pendingNotes"
        static let pendingSilent = "appUpdater.pendingSilent"
    }

    private static let silentCheckInterval: TimeInterval = 5 * 60
    private static let requiredInputIdleSeconds: TimeInterval = 600
    private static let handoffTimeout: TimeInterval = 25
    nonisolated private static let appBundleName = "Token Taken.app"
    nonisolated private static let bundleIdentifier = "io.github.elijah7x.TokenTaken"

    private(set) var phase: Phase = .idle
    var canInstallSilently: @MainActor () -> Bool = { false }
    private(set) var justUpdated: UpdateNotice?

    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    @ObservationIgnored private var preparingVersion: AppVersion?
    @ObservationIgnored private var silentTimerTask: Task<Void, Never>?
    @ObservationIgnored private var powerOffObserver: NSObjectProtocol?
    @ObservationIgnored private var isPoweringOff = false
    @ObservationIgnored private var handedOff = false
    @ObservationIgnored private let logger = Logger(subsystem: "io.github.elijah7x.TokenTaken", category: "updater")

    private var updatesRoot: URL {
        AppPaths.supportDirectory.appendingPathComponent("Updates", isDirectory: true)
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Keys.justUpdated),
           let notice = try? JSONDecoder().decode(UpdateNotice.self, from: data) {
            justUpdated = notice
        }
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPoweringOff = true
            }
        }
    }

    func prepare(_ update: AvailableUpdate) {
        guard let teamID = UpdateChecker.signingTeamIdentifier(),
              let current = UpdateChecker.bundleAppVersion(.main),
              update.version > current,
              !handedOff,
              phase != .installing else {
            return
        }

        if case .ready(let ready) = phase, ready.version >= update.version {
            return
        }
        if let activeVersion = preparingVersion, activeVersion >= update.version, prepareTask != nil {
            return
        }

        prepareTask?.cancel()
        prepareTask = nil
        silentTimerTask?.cancel()
        silentTimerTask = nil

        preparingVersion = update.version
        phase = .downloading(fraction: 0)

        let folderName = Self.stagingFolderName(for: update.version)
        let stagedDir = updatesRoot.appendingPathComponent(folderName, isDirectory: true)
        let userAgentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"

        prepareTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.preparingVersion == update.version {
                    self.preparingVersion = nil
                    self.prepareTask = nil
                }
            }

            do {
                let stagedApp = stagedDir.appendingPathComponent(Self.appBundleName, isDirectory: true)
                let completeMarker = stagedDir.appendingPathComponent("install.complete")

                // Reuse a valid staged bundle if one was left ready by an earlier check.
                if FileManager.default.fileExists(atPath: stagedApp.path),
                   !FileManager.default.fileExists(atPath: completeMarker.path) {
                    do {
                        self.phase = .verifying
                        try await Self.verifyStagedApp(stagedApp, expectedVersion: update.version, teamID: teamID)
                        try Task.checkCancellation()
                        self.phase = .ready(update)
                        self.startSilentInstallTimer()
                        return
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try? FileManager.default.removeItem(at: stagedDir)
                    }
                } else if FileManager.default.fileExists(atPath: stagedDir.path) {
                    try? FileManager.default.removeItem(at: stagedDir)
                }

                try FileManager.default.createDirectory(
                    at: stagedDir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )

                let dmgURL = stagedDir.appendingPathComponent("TokenTaken-\(folderName).dmg")
                let downloader = UpdateDownloader(
                    allowedHosts: UpdateChecker.allowedDownloadHosts,
                    userAgent: "TokenTaken/\(userAgentVersion)"
                ) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.preparingVersion == update.version,
                              case .downloading = self.phase else {
                            return
                        }
                        self.phase = .downloading(fraction: fraction)
                    }
                }

                try await downloader.download(update.feed.downloadURL, to: dmgURL)
                try Task.checkCancellation()

                self.phase = .verifying
                try await Self.verifyAndExtract(
                    dmgURL: dmgURL,
                    stagedApp: stagedApp,
                    expectedSize: update.feed.size,
                    expectedSHA256: update.feed.sha256,
                    expectedVersion: update.version,
                    teamID: teamID
                )
                try Task.checkCancellation()

                self.phase = .ready(update)
                self.startSilentInstallTimer()
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: stagedDir)
                if self.preparingVersion == update.version {
                    self.phase = .idle
                }
            } catch {
                try? FileManager.default.removeItem(at: stagedDir)
                self.logger.error("Update preparation failed for \(update.version.description, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if self.preparingVersion == update.version {
                    self.phase = .failed(message: error.localizedDescription)
                }
            }
        }
    }

    func installNowAndRelaunch() {
        guard case .ready(let update) = phase, !handedOff else { return }
        performHandoff(update: update, silent: false, relaunch: true)
    }

    @discardableResult
    func installStagedOnQuit() -> Bool {
        guard case .ready(let update) = phase, !handedOff, !isPoweringOff else { return false }
        return performHandoff(update: update, silent: true, relaunch: false)
    }

    func consumeLaunchMarker() {
        let defaults = UserDefaults.standard
        let pendingVersion = defaults.string(forKey: Keys.pendingVersion)
        let pendingBuild = defaults.string(forKey: Keys.pendingBuild)
        let pendingNotes = defaults.string(forKey: Keys.pendingNotes) ?? ""

        clearPendingMarkers()

        if let pendingVersion,
           let pendingBuild,
           let pending = AppVersion(version: pendingVersion, build: pendingBuild),
           let current = UpdateChecker.bundleAppVersion(.main),
           pending == current {
            let notice = UpdateNotice(version: current.description, notes: pendingNotes)
            justUpdated = notice
            if let data = try? JSONEncoder().encode(notice) {
                defaults.set(data, forKey: Keys.justUpdated)
            }
        }

        let root = updatesRoot
        let activeFolder = preparingVersion.map(Self.stagingFolderName(for:))
        Task.detached(priority: .utility) {
            Self.removeStaleDirectories(in: root, keepingFolder: activeFolder)
        }
    }

    func dismissJustUpdated() {
        justUpdated = nil
        UserDefaults.standard.removeObject(forKey: Keys.justUpdated)
    }

    // MARK: - Silent install & handoff

    private func startSilentInstallTimer() {
        silentTimerTask?.cancel()
        silentTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(Self.silentCheckInterval), tolerance: .seconds(15))
                } catch {
                    break
                }
                guard let self, !Task.isCancelled else { break }
                guard case .ready(let update) = self.phase,
                      !self.handedOff,
                      !self.isPoweringOff else {
                    break
                }
                let idleSeconds = CGEventSource.secondsSinceLastEventType(
                    .combinedSessionState,
                    eventType: CGEventType(rawValue: ~0)!
                )
                guard idleSeconds >= Self.requiredInputIdleSeconds,
                      self.canInstallSilently() else {
                    continue
                }
                self.performHandoff(update: update, silent: true, relaunch: true)
                break
            }
        }
    }

    @discardableResult
    private func performHandoff(update: AvailableUpdate, silent: Bool, relaunch: Bool) -> Bool {
        guard let teamID = UpdateChecker.signingTeamIdentifier() else {
            phase = .failed(message: String(localized: "Updates are only supported in Developer ID signed builds."))
            return false
        }

        let destination = Bundle.main.bundleURL
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            let message = String(localized: "Token Taken cannot update itself in this folder. Move it to Applications or update manually.")
            logger.error("Handoff refused: bundle parent is not writable")
            phase = .failed(message: message)
            return false
        }

        let folderName = Self.stagingFolderName(for: update.version)
        let stagedDir = updatesRoot.appendingPathComponent(folderName, isDirectory: true)
        let stagedApp = stagedDir.appendingPathComponent(Self.appBundleName, isDirectory: true)

        do {
            let stagedInfo = try Self.validateStagedBundleSync(stagedApp, expectedVersion: update.version, teamID: teamID)
            let requirement = Self.signatureRequirement(teamID: teamID)

            let scriptURL = stagedDir.appendingPathComponent("install.sh")
            try Self.installerScript.write(to: scriptURL, atomically: true, encoding: .utf8)

            let logURL = stagedDir.appendingPathComponent("install.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let logHandle = try FileHandle(forWritingTo: logURL)
            defer { try? logHandle.close() }

            let process = Process()
            process.executableURL = URL(filePath: "/bin/sh")
            process.arguments = [
                scriptURL.path,
                String(ProcessInfo.processInfo.processIdentifier),
                stagedApp.path,
                destination.path,
                relaunch ? (silent ? "2" : "1") : "0",
                stagedInfo.marketing,
                stagedInfo.build,
                requirement,
            ]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = logHandle
            process.standardError = logHandle

            try process.run()
        } catch {
            logger.error("Update handoff failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(message: error.localizedDescription)
            return false
        }

        handedOff = true
        silentTimerTask?.cancel()
        silentTimerTask = nil
        phase = .installing

        let defaults = UserDefaults.standard
        defaults.set(update.version.marketing.map(String.init).joined(separator: "."), forKey: Keys.pendingVersion)
        defaults.set(String(update.version.build), forKey: Keys.pendingBuild)
        defaults.set(update.feed.notes, forKey: Keys.pendingNotes)
        defaults.set(silent, forKey: Keys.pendingSilent)

        if relaunch {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.handoffTimeout))
                guard let self, self.handedOff else { return }
                self.handedOff = false
                self.clearPendingMarkers()
                self.phase = .failed(message: String(localized: "The update could not restart Token Taken."))
            }
            NSApp.terminate(nil)
        }
        return true
    }

    private func clearPendingMarkers() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Keys.pendingVersion)
        defaults.removeObject(forKey: Keys.pendingBuild)
        defaults.removeObject(forKey: Keys.pendingNotes)
        defaults.removeObject(forKey: Keys.pendingSilent)
    }

    // MARK: - Verification & staging

    nonisolated private static func stagingFolderName(for version: AppVersion) -> String {
        "\(version.marketing.map(String.init).joined(separator: "."))-\(version.build)"
    }

    nonisolated private static func signatureRequirement(teamID: String) -> String {
        "anchor apple generic and identifier \"\(bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    nonisolated private static func verifyAndExtract(
        dmgURL: URL,
        stagedApp: URL,
        expectedSize: Int64,
        expectedSHA256: String,
        expectedVersion: AppVersion,
        teamID: String
    ) async throws {
        defer { try? FileManager.default.removeItem(at: dmgURL) }

        try await Task.detached(priority: .utility) {
            let attributes = try FileManager.default.attributesOfItem(atPath: dmgURL.path)
            let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            guard actualSize == expectedSize else {
                throw UpdateInstallerError(String(localized: "The downloaded update size did not match."))
            }
            let actualSHA = try sha256Hex(of: dmgURL)
            guard actualSHA == expectedSHA256 else {
                throw UpdateInstallerError(String(localized: "The downloaded update failed its checksum check."))
            }
        }.value

        try Task.checkCancellation()

        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenTakenMount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mountPoint,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(at: mountPoint)
        }

        let attach = try await runTool(
            URL(filePath: "/usr/bin/hdiutil"),
            arguments: ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path, dmgURL.path],
            timeout: 120
        )
        guard attach.status == 0 else {
            throw UpdateInstallerError(String(localized: "The downloaded disk image could not be opened."))
        }

        var detached = false
        func detachMount() async {
            guard !detached else { return }
            detached = true
            _ = try? await runTool(
                URL(filePath: "/usr/bin/hdiutil"),
                arguments: ["detach", mountPoint.path, "-force"],
                timeout: 60
            )
        }

        do {
            let sourceApp = mountPoint.appendingPathComponent(appBundleName, isDirectory: true)
            let values = try? sourceApp.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink == false else {
                throw UpdateInstallerError(String(localized: "The disk image does not contain Token Taken.app."))
            }

            if FileManager.default.fileExists(atPath: stagedApp.path) {
                try FileManager.default.removeItem(at: stagedApp)
            }

            let copy = try await runTool(
                URL(filePath: "/usr/bin/ditto"),
                arguments: [sourceApp.path, stagedApp.path],
                timeout: 300
            )
            await detachMount()

            guard copy.status == 0 else {
                throw UpdateInstallerError(String(localized: "The update could not be copied."))
            }
        } catch {
            await detachMount()
            throw error
        }

        try Task.checkCancellation()
        try await verifyStagedApp(stagedApp, expectedVersion: expectedVersion, teamID: teamID)
    }

    nonisolated private static func verifyStagedApp(
        _ stagedApp: URL,
        expectedVersion: AppVersion,
        teamID: String
    ) async throws {
        _ = try await Task.detached(priority: .utility) {
            try validateStagedBundleSync(stagedApp, expectedVersion: expectedVersion, teamID: teamID)
        }.value

        try Task.checkCancellation()

        let spctl = try await runTool(
            URL(filePath: "/usr/sbin/spctl"),
            arguments: ["--assess", "--type", "execute", stagedApp.path],
            timeout: 120
        )
        guard spctl.status == 0 else {
            throw UpdateInstallerError(String(localized: "Gatekeeper did not accept the downloaded update."))
        }
    }

    @discardableResult
    nonisolated private static func validateStagedBundleSync(
        _ stagedApp: URL,
        expectedVersion: AppVersion,
        teamID: String
    ) throws -> (marketing: String, build: String) {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(stagedApp as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            throw UpdateInstallerError(String(localized: "The downloaded app is not signed."))
        }

        let requirementText = signatureRequirement(teamID: teamID)
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            throw UpdateInstallerError(String(localized: "Could not build the update code-signing requirement."))
        }

        var cfError: Unmanaged<CFError>?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &cfError)
        guard status == errSecSuccess else {
            _ = cfError?.takeRetainedValue()
            throw UpdateInstallerError(String(localized: "The downloaded app signature is not valid for Token Taken."))
        }

        guard let bundle = Bundle(url: stagedApp),
              let marketing = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let actualVersion = AppVersion(version: marketing, build: build),
              actualVersion == expectedVersion else {
            throw UpdateInstallerError(String(localized: "The downloaded app version did not match the update feed."))
        }

        return (marketing, build)
    }

    nonisolated private static func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func removeStaleDirectories(in root: URL, keepingFolder: String?) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for entry in entries {
            if let keepingFolder, entry.lastPathComponent == keepingFolder { continue }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink == false else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private struct ToolOutput: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    nonisolated private static func runTool(
        _ executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ToolOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = Mutex(Data())
        let stderrBuffer = Mutex(Data())
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stdoutBuffer.withLock { $0.append(chunk) }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBuffer.withLock { $0.append(chunk) }
            }
        }

        let state = Mutex<(continuation: CheckedContinuation<Int32, Error>?, pid: pid_t?, finished: Bool)>((nil, nil, false))
        var timeoutTask: Task<Void, Never>?

        defer {
            timeoutTask?.cancel()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }

        let status = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { proc in
                    let pending = state.withLock { box -> CheckedContinuation<Int32, Error>? in
                        box.pid = nil
                        box.finished = true
                        defer { box.continuation = nil }
                        return box.continuation
                    }
                    pending?.resume(returning: proc.terminationStatus)
                }

                let shouldRun = state.withLock { box -> Bool in
                    guard !box.finished else { return false }
                    box.continuation = continuation
                    return true
                }
                guard shouldRun else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                do {
                    try process.run()
                    let pid = process.processIdentifier
                    let terminateEarly = state.withLock { box -> Bool in
                        if box.finished { return true }
                        box.pid = pid
                        return false
                    }
                    if terminateEarly {
                        Darwin.kill(pid, SIGTERM)
                    } else {
                        timeoutTask = Task {
                            do {
                                try await Task.sleep(for: .seconds(timeout))
                            } catch {
                                return
                            }
                            let timedOut = state.withLock { box -> (CheckedContinuation<Int32, Error>?, pid_t?) in
                                guard !box.finished else { return (nil, nil) }
                                box.finished = true
                                let pair = (box.continuation, box.pid)
                                box.continuation = nil
                                box.pid = nil
                                return pair
                            }
                            if let pid = timedOut.1 {
                                Darwin.kill(pid, SIGTERM)
                            }
                            timedOut.0?.resume(throwing: UpdateInstallerError(String(localized: "An update verification step timed out.")))
                        }
                    }
                } catch {
                    let pending = state.withLock { box -> CheckedContinuation<Int32, Error>? in
                        box.finished = true
                        defer { box.continuation = nil }
                        return box.continuation
                    }
                    pending?.resume(throwing: error)
                }
            }
        } onCancel: {
            let cancelled = state.withLock { box -> (CheckedContinuation<Int32, Error>?, pid_t?) in
                guard !box.finished else { return (nil, nil) }
                box.finished = true
                let pair = (box.continuation, box.pid)
                box.continuation = nil
                box.pid = nil
                return pair
            }
            if let pid = cancelled.1 {
                Darwin.kill(pid, SIGTERM)
            }
            cancelled.0?.resume(throwing: CancellationError())
        }

        return ToolOutput(
            status: status,
            stdout: stdoutBuffer.withLock { $0 },
            stderr: stderrBuffer.withLock { $0 }
        )
    }

    nonisolated private static let installerScript = """
    #!/bin/sh
    trap '' HUP
    PID="$1"
    NEW="$2"
    DEST="$3"
    RELAUNCH="$4"
    VERSION="$5"
    BUILD="$6"
    REQUIREMENT="$7"
    STAGING="$(dirname "$NEW")"

    mark_complete() {
      if [ -d "$STAGING" ]; then
        printf "complete\\n" > "$STAGING/install.complete"
      fi
    }

    reopen() {
      if [ "$RELAUNCH" = "1" ]; then
        open "$DEST"
      elif [ "$RELAUNCH" = "2" ]; then
        open -g "$DEST"
      fi
    }

    i=0
    while kill -0 "$PID" 2>/dev/null; do
      sleep 0.25
      i=$((i + 1))
      if [ "$i" -gt 240 ]; then
        echo "Timed out waiting for app exit"
        rm -rf "$NEW"
        mark_complete
        exit 1
      fi
    done

    /usr/bin/codesign --verify --deep --strict -R="$REQUIREMENT" "$NEW" || {
      echo "Staged app failed signature verification"
      rm -rf "$NEW"
      reopen
      mark_complete
      exit 1
    }

    ACTUAL_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$NEW/Contents/Info.plist" 2>/dev/null) || ACTUAL_VERSION=""
    ACTUAL_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$NEW/Contents/Info.plist" 2>/dev/null) || ACTUAL_BUILD=""
    if [ "$ACTUAL_VERSION" != "$VERSION" ] || [ "$ACTUAL_BUILD" != "$BUILD" ]; then
      echo "Staged app version mismatch: $ACTUAL_VERSION ($ACTUAL_BUILD) != $VERSION ($BUILD)"
      rm -rf "$NEW"
      reopen
      mark_complete
      exit 1
    fi

    BACKUP="$(dirname "$DEST")/.$(basename "$DEST").previous"
    rm -rf "$BACKUP"
    if [ -e "$DEST" ]; then
      mv "$DEST" "$BACKUP" || {
        echo "Could not move current bundle aside"
        rm -rf "$NEW"
        reopen
        mark_complete
        exit 1
      }
    fi

    if mv "$NEW" "$DEST"; then
      rm -rf "$BACKUP"
    else
      echo "Could not move staged bundle into place"
      if [ -e "$BACKUP" ]; then
        mv "$BACKUP" "$DEST"
      fi
      rm -rf "$NEW"
      reopen
      mark_complete
      exit 1
    fi

    /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
    reopen
    mark_complete
    """
}

private struct UpdateInstallerError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) {
        self.message = message
    }
}

private final class UpdateDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<URL, Error>?
        var destination: URL?
        var task: URLSessionDownloadTask?
        var cancelled = false
        var lastReportedFraction: Double = -1
        var lastReportedTime: CFAbsoluteTime = 0
    }

    private let allowedHosts: Set<String>
    private let userAgent: String
    private let onProgress: @Sendable (Double) -> Void
    private let state = Mutex(State())

    init(
        allowedHosts: Set<String>,
        userAgent: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.userAgent = userAgent
        self.onProgress = onProgress
    }

    func download(_ url: URL, to destination: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.networkServiceType = .background
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 1800
        configuration.waitsForConnectivity = false

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                    let task = session.downloadTask(with: request)
                    let shouldStart = state.withLock { box -> Bool in
                        guard !box.cancelled else { return false }
                        box.continuation = continuation
                        box.destination = destination
                        box.task = task
                        return true
                    }
                    if shouldStart {
                        task.resume()
                    } else {
                        task.cancel()
                        continuation.resume(throwing: CancellationError())
                    }
                }
                try Task.checkCancellation()
            } onCancel: {
                self.cancel()
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func cancel() {
        let pending = state.withLock { box -> (URLSessionDownloadTask?, CheckedContinuation<URL, Error>?) in
            box.cancelled = true
            let result = (box.task, box.continuation)
            box.task = nil
            box.continuation = nil
            return result
        }
        pending.0?.cancel()
        pending.1?.resume(throwing: CancellationError())
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = state.withLock { box -> CheckedContinuation<URL, Error>? in
            defer {
                box.continuation = nil
                box.task = nil
            }
            return box.continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let redirected = request.url,
              redirected.scheme?.lowercased() == "https",
              redirected.port == nil || redirected.port == 443,
              let host = redirected.host?.lowercased(),
              allowedHosts.contains(host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        let now = CFAbsoluteTimeGetCurrent()
        let shouldReport = state.withLock { box -> Bool in
            guard !box.cancelled, box.continuation != nil else { return false }
            let delta = abs(fraction - box.lastReportedFraction)
            guard fraction >= 1 || delta >= 0.01 || (now - box.lastReportedTime) >= 0.05 else {
                return false
            }
            box.lastReportedFraction = fraction
            box.lastReportedTime = now
            return true
        }
        if shouldReport {
            onProgress(fraction)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let completed = state.withLock { box -> (CheckedContinuation<URL, Error>, Result<URL, Error>)? in
            guard !box.cancelled,
                  let continuation = box.continuation,
                  let destination = box.destination else {
                return nil
            }
            defer {
                box.continuation = nil
                box.task = nil
            }
            if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return (
                    continuation,
                    .failure(UpdateInstallerError(String(localized: "Update download failed (HTTP \(http.statusCode)).")))
                )
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                return (continuation, .success(destination))
            } catch {
                return (continuation, .failure(error))
            }
        }
        if let (continuation, result) = completed {
            continuation.resume(with: result)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(UpdateInstallerError(error.localizedDescription)))
        }
    }
}
