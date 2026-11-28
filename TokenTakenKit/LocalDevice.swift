import Foundation

public enum LocalDevice {
    /// The Mac's current display name; read dynamically so renames take effect without changing the device id.
    public static var currentDisplayName: String {
        Host.current().localizedName ?? "Mac"
    }

    /// Returns a `Device` with the given fixed `id` and the Mac's current display name.
    public static func device(withID id: String) -> Device {
        Device(id: id, name: currentDisplayName)
    }

    /// Returns `true` only when `TOKEN_TAKEN_SUPPORT_DIR` is unset/empty and `url` points to the default
    /// production Application Support directory.
    public static func isDefaultProductionSupportDirectory(
        _ url: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard (environment["TOKEN_TAKEN_SUPPORT_DIR"] ?? "").isEmpty else { return false }
        let production = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Token Taken", isDirectory: true)
            .standardizedFileURL
        return url.standardizedFileURL == production
    }

    /// The id lives in the shared support folder so the app and the CLI (separate defaults domains) agree on it.
    /// Earlier builds kept it in the app's defaults; that value is adopted once for the default production folder.
    /// Custom/isolated support directories use `<supportDirectory>/device-id` exclusively so they never adopt or
    /// overwrite production `UserDefaults.standard`.
    public static func current(defaults: UserDefaults = .standard, supportDirectory: URL = AppPaths.supportDirectory) -> Device {
        let name = currentDisplayName
        let file = supportDirectory.appendingPathComponent("device-id")
        if let stored = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           UUID(uuidString: stored) != nil {
            return Device(id: stored, name: name)
        }
        let useDefaults = isDefaultProductionSupportDirectory(supportDirectory)
        let id = if useDefaults, let stored = defaults.string(forKey: "deviceID"), UUID(uuidString: stored) != nil {
            stored
        } else {
            UUID().uuidString
        }
        try? id.write(to: file, atomically: true, encoding: .utf8)
        if useDefaults {
            defaults.set(id, forKey: "deviceID")
        }
        return Device(id: id, name: name)
    }

    /// Reads the id without creating one; nil before the app's first launch.
    public static func storedID(supportDirectory: URL = AppPaths.supportDirectory) -> String? {
        let file = supportDirectory.appendingPathComponent("device-id")
        guard let stored = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              UUID(uuidString: stored) != nil else { return nil }
        return stored
    }
}
