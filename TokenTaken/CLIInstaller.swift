import AppKit
import Foundation

@MainActor
enum CLIInstaller {
    enum Status: Equatable {
        case installed(URL)
        case broken(URL)
        case notInstalled
    }

    struct InstallResult {
        let destination: URL
        let exportPATHLine: String?
    }

    private static let installedPathDefaultsKey = "cliInstalledSymlinkPath"

    static func currentStatus(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Status {
        var firstBroken: URL?
        for candidate in candidateDestinations(fileManager: fileManager, environment: environment, defaults: defaults) {
            guard let attributes = try? fileManager.attributesOfItem(atPath: candidate.path),
                  attributes[.type] as? FileAttributeType == .typeSymbolicLink,
                  pointsIntoTokenTakenApp(candidate, fileManager: fileManager) else {
                continue
            }
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return .installed(candidate)
            }
            if firstBroken == nil {
                firstBroken = candidate
            }
        }
        if let firstBroken {
            return .broken(firstBroken)
        }
        return .notInstalled
    }

    static func install() throws -> InstallResult? {
        guard !isRunningFromReadOnlyDiskImage() else {
            throw InstallationError.runningFromDiskImage
        }
        let executable = try bundledExecutable()
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let localDirectory = home.appendingPathComponent(".local", isDirectory: true)
        let defaultDirectory = localDirectory.appendingPathComponent("bin", isDirectory: true)

        let panel = NSOpenPanel()
        if fileManager.fileExists(atPath: defaultDirectory.path) {
            panel.directoryURL = defaultDirectory
        } else if fileManager.fileExists(atPath: localDirectory.path) {
            panel.directoryURL = localDirectory
        } else {
            panel.directoryURL = home
        }
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Install Here")
        panel.message = String(localized: "Choose a folder for the token-taken symlink.")
        guard panel.runModal() == .OK, let directory = panel.url else { return nil }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("token-taken")
        if let attributes = try? fileManager.attributesOfItem(atPath: destination.path) {
            guard attributes[.type] as? FileAttributeType == .typeSymbolicLink,
                  pointsIntoTokenTakenApp(destination, fileManager: fileManager) else {
                throw InstallationError.destinationOccupied
            }
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createSymbolicLink(at: destination, withDestinationURL: executable)
        UserDefaults.standard.set(destination.standardizedFileURL.path, forKey: installedPathDefaultsKey)

        let exportPATHLine = isDirectoryInPATH(directory) ? nil : exportPATHCommand(for: directory, fileManager: fileManager)
        return InstallResult(destination: destination, exportPATHLine: exportPATHLine)
    }

    @discardableResult
    static func uninstall(at destination: URL, fileManager: FileManager = .default, defaults: UserDefaults = .standard) throws -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: destination.path),
              attributes[.type] as? FileAttributeType == .typeSymbolicLink,
              pointsIntoTokenTakenApp(destination, fileManager: fileManager) else {
            return false
        }
        try fileManager.removeItem(at: destination)
        if let recorded = defaults.string(forKey: installedPathDefaultsKey),
           URL(fileURLWithPath: recorded).standardizedFileURL == destination.standardizedFileURL {
            defaults.removeObject(forKey: installedPathDefaultsKey)
        }
        return true
    }

    @discardableResult
    static func uninstall() throws -> URL? {
        switch currentStatus() {
        case .installed(let url), .broken(let url):
            guard try uninstall(at: url) else { return nil }
            return url
        case .notInstalled:
            return nil
        }
    }

    private static func candidateDestinations(
        fileManager: FileManager,
        environment: [String: String],
        defaults: UserDefaults
    ) -> [URL] {
        var directories: [URL] = []
        if let recorded = defaults.string(forKey: installedPathDefaultsKey), !recorded.isEmpty {
            let recordedURL = URL(fileURLWithPath: recorded).standardizedFileURL
            if recordedURL.lastPathComponent == "token-taken" {
                directories.append(recordedURL.deletingLastPathComponent())
            }
        }
        let home = fileManager.homeDirectoryForCurrentUser
        directories.append(home.appendingPathComponent(".local/bin", isDirectory: true))
        directories.append(URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true))
        directories.append(URL(fileURLWithPath: "/usr/local/bin", isDirectory: true))

        for entry in (environment["PATH"] ?? "").split(separator: ":") where !entry.isEmpty {
            let expanded = NSString(string: String(entry)).expandingTildeInPath
            directories.append(URL(fileURLWithPath: expanded, isDirectory: true))
        }

        var seen = Set<String>()
        var destinations: [URL] = []
        for directory in directories {
            let destination = directory.appendingPathComponent("token-taken").standardizedFileURL
            if seen.insert(destination.path).inserted {
                destinations.append(destination)
            }
        }
        return destinations
    }

    private static func pointsIntoTokenTakenApp(_ symlinkURL: URL, fileManager: FileManager) -> Bool {
        guard let rawTarget = try? fileManager.destinationOfSymbolicLink(atPath: symlinkURL.path) else {
            return false
        }
        let directTarget = URL(fileURLWithPath: rawTarget, relativeTo: symlinkURL.deletingLastPathComponent()).standardizedFileURL
        if isInsideTokenTakenBundle(directTarget) {
            return true
        }
        let resolvedTarget = symlinkURL.resolvingSymlinksInPath().standardizedFileURL
        return isInsideTokenTakenBundle(resolvedTarget)
    }

    private static func isInsideTokenTakenBundle(_ url: URL) -> Bool {
        let components = url.pathComponents
        guard let appIndex = components.firstIndex(of: "Token Taken.app") else {
            return false
        }
        return appIndex + 1 < components.count
    }

    private static func isRunningFromReadOnlyDiskImage(
        bundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) -> Bool {
        let standardized = bundleURL.standardizedFileURL
        let resolved = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let isUnderVolumes = standardized.path.hasPrefix("/Volumes/") || resolved.path.hasPrefix("/Volumes/")
        guard isUnderVolumes else { return false }
        if let values = try? resolved.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
           values.volumeIsReadOnly == true {
            return true
        }
        return !fileManager.isWritableFile(atPath: resolved.path)
    }

    private static func isDirectoryInPATH(
        _ directory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let target = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let entries = (environment["PATH"] ?? "").split(separator: ":")
        return entries.contains { rawEntry in
            let expanded = NSString(string: String(rawEntry)).expandingTildeInPath
            let candidate = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
            return candidate == target
        }
    }

    private static func exportPATHCommand(for directory: URL, fileManager: FileManager) -> String {
        let homePath = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        let dirPath = directory.standardizedFileURL.path
        let pathExpr: String
        if dirPath == homePath {
            pathExpr = "$HOME"
        } else if dirPath.hasPrefix(homePath + "/") {
            let relative = String(dirPath.dropFirst(homePath.count + 1))
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "$", with: "\\$")
            pathExpr = "$HOME/\(relative)"
        } else {
            pathExpr = dirPath
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "$", with: "\\$")
        }
        return "export PATH=\"\(pathExpr):$PATH\""
    }

    private static func bundledExecutable() throws -> URL {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/token-taken"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/token-taken"),
        ]
        guard let executable = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) else {
            throw InstallationError.missingExecutable
        }
        return executable
    }

    private enum InstallationError: LocalizedError {
        case missingExecutable
        case destinationOccupied
        case runningFromDiskImage

        var errorDescription: String? {
            switch self {
            case .missingExecutable:
                String(localized: "The bundled token-taken tool was not found.")
            case .destinationOccupied:
                String(localized: "A file named token-taken already exists in the chosen folder.")
            case .runningFromDiskImage:
                String(localized: "Move Token Taken to your Applications folder before installing the command-line tool.")
            }
        }
    }
}
