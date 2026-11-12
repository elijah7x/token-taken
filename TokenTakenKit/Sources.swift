import Foundation

public struct SourceInfo: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Pastel accent, `#RRGGBB`.
    public let colorHex: String

    public init(id: String, name: String, colorHex: String) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }
}

public enum SourceCatalog {
    public static let all: [SourceInfo] = [
        SourceInfo(id: "claude", name: "Claude Code", colorHex: "#E98F69"),
        SourceInfo(id: "codex", name: "Codex", colorHex: "#7FA8E8"),
        SourceInfo(id: "zcode", name: "Zcode", colorHex: "#8FD3B0"),
        SourceInfo(id: "omp", name: "oh-my-pi", colorHex: "#C3A3EB"),
        SourceInfo(id: "pi", name: "pi", colorHex: "#F2CB6B"),
        SourceInfo(id: "kimi", name: "Kimi Code", colorHex: "#F29BBC"),
        SourceInfo(id: "grok", name: "Grok", colorHex: "#A7AEF4"),
        SourceInfo(id: "opencode", name: "OpenCode", colorHex: "#BFDB86"),
        SourceInfo(id: "gemini", name: "Gemini CLI", colorHex: "#7CCFD9"),
        SourceInfo(id: "factory", name: "Factory Droid", colorHex: "#D8B4A0"),
        SourceInfo(id: "devin", name: "Devin", colorHex: "#7FCFC9"),
        SourceInfo(id: "antigravity", name: "Antigravity", colorHex: "#D3A6E6"),
        SourceInfo(id: "dsh", name: "DeepSeek Harness", colorHex: "#C9D27E"),
        SourceInfo(id: "fx", name: "fx", colorHex: "#EE9AA2"),
        SourceInfo(id: "mcode", name: "MiniMax Code", colorHex: "#E0A9C4"),
        SourceInfo(id: "deepseek-cli", name: "DeepSeek CLI", colorHex: "#9DB6CE"),
    ]

    private static let byID: [String: SourceInfo] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func info(for id: String) -> SourceInfo {
        byID[id] ?? SourceInfo(id: id, name: id, colorHex: "#9AA0AE")
    }
}
