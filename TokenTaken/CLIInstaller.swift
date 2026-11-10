import AppKit
import Foundation

@MainActor
enum CLIInstaller {
    static func install() throws -> URL? {
        let executable = try bundledExecutable()
        let fileManager = FileManager.default
        let defaultDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: defaultDirectory, withIntermediateDirectories: true)

        let panel = NSOpenPanel()
        panel.directoryURL = defaultDirectory
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
            guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
                throw InstallationError.destinationOccupied
            }
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createSymbolicLink(at: destination, withDestinationURL: executable)
        return destination
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

        var errorDescription: String? {
            switch self {
            case .missingExecutable:
                String(localized: "The bundled token-taken tool was not found.")
            case .destinationOccupied:
                String(localized: "A file named token-taken already exists in the chosen folder.")
            }
        }
    }
}
