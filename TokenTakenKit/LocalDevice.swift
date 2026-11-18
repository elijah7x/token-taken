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

    /// The id lives in the shared support folder so the app and the CLI (separate defaults domains) agree on it.
    /// Earlier builds kept it in the app's defaults; that value is adopted once.
    public static func current(defaults: UserDefaults = .standard, supportDirectory: URL = AppPaths.supportDirectory) -> Device {
        let name = currentDisplayName
        let file = supportDirectory.appendingPathComponent("device-id")
        if let stored = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           UUID(uuidString: stored) != nil {
            return Device(id: stored, name: name)
        }
        let id = if let stored = defaults.string(forKey: "deviceID"), UUID(uuidString: stored) != nil {
            stored
        } else {
            UUID().uuidString
        }
        try? id.write(to: file, atomically: true, encoding: .utf8)
        defaults.set(id, forKey: "deviceID")
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
