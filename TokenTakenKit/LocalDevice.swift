import Foundation

public enum LocalDevice {
    public static func current(defaults: UserDefaults = .standard) -> Device {
        if let id = defaults.string(forKey: "deviceID") {
            return Device(id: id, name: Host.current().localizedName ?? "Mac")
        }
        let id = UUID().uuidString
        defaults.set(id, forKey: "deviceID")
        return Device(id: id, name: Host.current().localizedName ?? "Mac")
    }
}
