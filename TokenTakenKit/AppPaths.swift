import Foundation

public enum AppPaths {
    /// Resolves the support directory path without creating it on disk.
    public static var supportDirectoryLocation: URL {
        if let override = ProcessInfo.processInfo.environment["TOKEN_TAKEN_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Token Taken", isDirectory: true)
    }

    /// Resolves the SQLite store URL without creating the support directory on disk.
    public static var databaseLocation: URL {
        supportDirectoryLocation.appendingPathComponent("usage.sqlite")
    }

    public static var supportDirectory: URL {
        let url = supportDirectoryLocation
        createDirectory(at: url)
        return url
    }

    public static var databaseURL: URL {
        supportDirectory.appendingPathComponent("usage.sqlite")
    }

    public static var tokscaleConfigDirectory: URL {
        let url = supportDirectory
            .appendingPathComponent("engine/tokscale", isDirectory: true)
        createDirectory(at: url)
        return url
    }

    private static func createDirectory(at url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
