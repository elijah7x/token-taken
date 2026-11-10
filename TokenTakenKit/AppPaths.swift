import Foundation

public enum AppPaths {
    public static var supportDirectory: URL {
        let url = if let override = ProcessInfo.processInfo.environment["TOKEN_TAKEN_SUPPORT_DIR"], !override.isEmpty {
            URL(fileURLWithPath: override, isDirectory: true)
        } else {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Token Taken", isDirectory: true)
        }
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
