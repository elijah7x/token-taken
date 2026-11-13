import Foundation

public enum MobileReportPublishError: Error, Sendable, Equatable {
    case invalidDeviceId
    case reportTooLarge(Int)
    case writeFailed
}

/// Result of one publication attempt, safe to show in Settings: no paths, no error strings from the file system.
public enum MobileReportPublishStatus: Sendable, Equatable {
    /// The "Sync to iPhone" setting is off.
    case disabled
    /// The iCloud container is absent, which is normal for a build without the container entitlement.
    case unavailable
    case published(Date)
    case failed(String)

    public var lastPublished: Date? {
        if case .published(let date) = self { return date }
        return nil
    }
}

/// Writes this Mac's report into the shared iCloud Documents container.
/// Contract: `docs/contracts/mobile-report.md`. Only the app publishes: the CLI has no container entitlement.
public enum MobileReportPublisher {
    public static let containerIdentifier = "iCloud.io.github.elijah7x.TokenTaken"
    /// Folder inside the container; the iOS app reads the same path.
    public static let relativeDirectory = "Documents/mobile/v1"
    /// Contract budget for one encoded report.
    public static let maximumByteCount = 512 * 1024
    /// Test hook, matching `TOKEN_TAKEN_SYNC_ROOT`: an existing absolute folder used instead of the container.
    public static let rootEnvironmentKey = "TOKEN_TAKEN_MOBILE_REPORT_ROOT"

    // MARK: - Entry points

    /// Publishes `report` when the setting is on. Never throws: the caller shows the returned status.
    public static func publish(
        _ report: MobileReport,
        enabled: Bool,
        now: Date = .now,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> MobileReportPublishStatus {
        guard enabled else { return .disabled }
        guard let container = await containerURL(environment: environment) else { return .unavailable }
        return publish(report, into: container, now: now)
    }

    /// Synchronous write into an already resolved container, so a caller can recheck its own state
    /// after the asynchronous container lookup and before anything touches the file.
    public static func publish(_ report: MobileReport, into container: URL, now: Date = .now) -> MobileReportPublishStatus {
        do {
            try write(report, into: container)
            return .published(now)
        } catch {
            return .failed(message(for: error))
        }
    }

    /// Removes only this Mac's report file. Other devices' reports stay untouched.
    public static func stop(
        deviceId: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> MobileReportPublishStatus {
        guard let container = await containerURL(environment: environment) else { return .unavailable }
        do {
            try remove(deviceId: deviceId, from: container)
            return .disabled
        } catch {
            return .failed(message(for: error))
        }
    }

    // MARK: - Container

    /// `url(forUbiquityContainerIdentifier:)` blocks, so it never runs on the caller's thread.
    /// A nil result means this build has no iCloud documents entitlement (Debug) or iCloud is unavailable.
    public static func containerURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> URL? {
        if let override = environment[rootEnvironmentKey], !override.isEmpty {
            return existingDirectory(override)
        }
        let identifier = containerIdentifier
        return await Task.detached(priority: .utility) {
            FileManager.default.url(forUbiquityContainerIdentifier: identifier)
        }.value
    }

    public static func directory(in container: URL) -> URL {
        container.appendingPathComponent(relativeDirectory, isDirectory: true)
    }

    public static func fileURL(deviceId: String, in container: URL) throws -> URL {
        guard validDeviceID(deviceId) else { throw MobileReportPublishError.invalidDeviceId }
        return directory(in: container).appendingPathComponent("report-\(deviceId).json")
    }

    // MARK: - File access

    public static func encode(_ report: MobileReport) throws -> Data {
        let data = try MobileReport.makeEncoder().encode(report)
        // Refuse to publish rather than shrink history to fit the budget.
        guard data.count <= maximumByteCount else {
            throw MobileReportPublishError.reportTooLarge(data.count)
        }
        return data
    }

    public static func write(_ report: MobileReport, into container: URL) throws {
        let data = try encode(report)
        let destination = try fileURL(deviceId: report.generator.deviceId, in: container)
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var result: Result<Void, any Error> = .failure(MobileReportPublishError.writeFailed)
        // Synchronous coordination: use the accessor's URL and propagate both accessor and coordination errors.
        NSFileCoordinator().coordinate(writingItemAt: destination, options: [.forReplacing], error: &coordinationError) { coordinatedURL in
            result = Result {
                let temporary = coordinatedURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString).tmp")
                defer { try? manager.removeItem(at: temporary) }
                try data.write(to: temporary, options: [.withoutOverwriting])
                if manager.fileExists(atPath: coordinatedURL.path) {
                    _ = try manager.replaceItemAt(coordinatedURL, withItemAt: temporary)
                } else {
                    try manager.moveItem(at: temporary, to: coordinatedURL)
                }
            }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    public static func remove(deviceId: String, from container: URL) throws {
        let destination = try fileURL(deviceId: deviceId, in: container)
        let manager = FileManager.default
        guard manager.fileExists(atPath: destination.path) else { return }
        var coordinationError: NSError?
        var result: Result<Void, any Error> = .failure(MobileReportPublishError.writeFailed)
        NSFileCoordinator().coordinate(writingItemAt: destination, options: [.forDeleting], error: &coordinationError) { coordinatedURL in
            result = Result { try manager.removeItem(at: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    // MARK: - Helpers

    private static func message(for error: any Error) -> String {
        guard let error = error as? MobileReportPublishError else { return "Could not write the report" }
        switch error {
        case .invalidDeviceId: return "Invalid device ID"
        case .reportTooLarge: return "Report exceeds the 512 KB limit"
        case .writeFailed: return "Could not write the report"
        }
    }

    private static func existingDirectory(_ path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    private static func validDeviceID(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." && !id.contains("/") && !id.contains("\\") && !id.hasPrefix(".")
    }
}
