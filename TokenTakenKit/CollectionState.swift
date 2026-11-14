import Foundation

/// Small per-collector state (input fingerprints, scan offsets) kept outside the usage store.
/// Local only: never synced or exported. A missing, unreadable or mismatched file means "collect in full".
public struct CollectorStateFile<Value: Codable & Sendable>: Sendable {
    public let url: URL

    public init(directory: URL = CollectorStateFile.defaultDirectory, name: String) {
        url = directory.appendingPathComponent(name + ".json")
    }

    public static var defaultDirectory: URL {
        AppPaths.supportDirectory.appendingPathComponent("collector-state", isDirectory: true)
    }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Inputs that invalidate every collector state when they change.
public struct CollectionStamp: Codable, Hashable, Sendable {
    public var timeZoneID: String
    public var formatVersion: Int
    public var engineVersion: String?
    /// History epochs of the collector's sources. A bumped epoch changes the stamp, so unchanged inputs are re-read
    /// once and the correction rebaselines instead of the cached rows being re-stored under the new epoch.
    public var historyEpochs: [String]?

    public init(formatVersion: Int, engineVersion: String? = nil, timeZone: TimeZone = .current, sourceIDs: [String] = []) {
        self.timeZoneID = timeZone.identifier
        self.formatVersion = formatVersion
        self.engineVersion = engineVersion
        self.historyEpochs = sourceIDs.isEmpty ? nil : sourceIDs.map { "\($0)=\(HistoryEpochs.epoch(for: $0))" }
    }
}

/// Metadata-only fingerprint of a file; equal fingerprints mean the file was not rewritten.
public struct FileFingerprint: Codable, Hashable, Sendable {
    public var inode: UInt64
    public var size: UInt64
    public var modified: Double

    public init?(url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        self.inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        self.size = size
        self.modified = modified.timeIntervalSinceReferenceDate
    }
}
