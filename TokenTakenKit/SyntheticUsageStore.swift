import Foundation

/// Placeholder usage for UI and CLI development until the collector exists. Contains no real usage.
public struct SyntheticUsageStore: UsageStore {
    /// 2026-11-09 09:30 UTC: the same calendar date in Asia and the Americas, with today partly elapsed.
    public static let defaultToday: Date = Calendar.utcGregorian.date(
        from: DateComponents(year: 2026, month: 11, day: 9, hour: 9, minute: 30)
    )!

    public let devices: [Device]
    private let generated: [UsageRecord]

    public init(seed: UInt64 = 20261109, today: Date = SyntheticUsageStore.defaultToday) {
        devices = Self.profiles.map(\.device)
        generated = Self.generate(seed: seed, today: today)
    }

    public func records() -> [UsageRecord] { generated }

    // MARK: - Generation

    private struct Profile {
        let device: Device
        let firstDay: DateComponents
        /// Average tokens per weekday at the start of the data.
        let dailyVolume: Double
        let sources: [(id: String, weight: Double)]
    }

    private static let profiles: [Profile] = [
        Profile(
            device: Device(id: "air", name: "MacBook Air"),
            firstDay: DateComponents(year: 2026, month: 3, day: 15),
            dailyVolume: 9_000_000,
            sources: [("claude", 0.40), ("codex", 0.25), ("zcode", 0.10), ("pi", 0.08), ("omp", 0.07), ("kimi", 0.05), ("gemini", 0.05)]
        ),
        Profile(
            device: Device(id: "studio", name: "Mac Studio"),
            firstDay: DateComponents(year: 2026, month: 3, day: 15),
            dailyVolume: 10_000_000,
            sources: [("claude", 0.35), ("codex", 0.30), ("opencode", 0.12), ("omp", 0.10), ("grok", 0.08), ("kimi", 0.05)]
        ),
        Profile(
            device: Device(id: "mini", name: "Mac mini"),
            firstDay: DateComponents(year: 2026, month: 7, day: 1),
            dailyVolume: 6_000_000,
            sources: [("codex", 0.50), ("opencode", 0.30), ("gemini", 0.20)]
        ),
    ]

    private static let models: [String: [(id: String, share: Double)]] = [
        "claude": [("claude-opus-5-5", 0.65), ("claude-sonnet-5-5", 0.35)],
        "codex": [("gpt-6.1", 0.70), ("gpt-6.1-mini", 0.30)],
        "zcode": [("glm-5.3", 1)],
        "pi": [("claude-sonnet-5-5", 0.50), ("deepseek-v4-pro", 0.50)],
        "omp": [("claude-opus-5-5", 0.50), ("gpt-6.1", 0.30), ("glm-5.3", 0.20)],
        "kimi": [("kimi-k3.1-pro", 1)],
        "grok": [("grok-5", 1)],
        "opencode": [("deepseek-v4-pro", 0.60), ("glm-5.3", 0.40)],
        "gemini": [("gemini-3.7-flash", 1)],
    ]

    private static func generate(seed: UInt64, today: Date) -> [UsageRecord] {
        let utc = Calendar.utcGregorian
        let firstDay = utc.date(from: DateComponents(year: 2026, month: 3, day: 15))!
        let lastDay = utc.startOfDay(for: today)
        let todayFraction = min(max(today.timeIntervalSince(lastDay) / 86_400, 0), 1)
        let dayCount = max(utc.dateComponents([.day], from: firstDay, to: lastDay).day ?? 0, 1)
        let deviceStarts = profiles.map { utc.date(from: $0.firstDay)! }

        var rng = SplitMix64(seed: seed)
        var records: [UsageRecord] = []
        var day = firstDay
        var dayIndex = 0

        while day <= lastDay {
            let growth = 0.8 + 0.45 * Double(dayIndex) / Double(dayCount)
            let weekday = utc.component(.weekday, from: day)
            let weekend = (weekday == 1 || weekday == 7) ? 0.55 : 1.0
            let spike = rng.unit() < 0.05 ? 1.6 : 1.0
            let elapsed = day == lastDay ? todayFraction : 1.0

            for (profile, start) in zip(profiles, deviceStarts) where day >= start {
                let deviceVolume = profile.dailyVolume * growth * weekend * spike * elapsed * (0.7 + 0.6 * rng.unit())
                for source in profile.sources {
                    // Minor tools are not used every day.
                    if source.weight < 0.1, rng.unit() < 0.3 { continue }
                    let sourceVolume = deviceVolume * source.weight * (0.6 + 0.8 * rng.unit())
                    for model in models[source.id] ?? [] {
                        let tokens = sourceVolume * model.share
                        guard tokens >= 1 else { continue }
                        records.append(UsageRecord(
                            day: day,
                            deviceID: profile.device.id,
                            sourceID: source.id,
                            modelID: model.id,
                            counts: mix(tokens: tokens, model: model.id, rng: &rng)
                        ))
                    }
                }
            }
            day = utc.date(byAdding: .day, value: 1, to: day)!
            dayIndex += 1
        }
        return records
    }

    /// About 90% cache read, 5% input, 2% output, under 1% reasoning; cache writes only for Claude models.
    private static func mix(tokens: Double, model: String, rng: inout SplitMix64) -> TokenCounts {
        func jitter(_ share: Double) -> Int64 { Int64((tokens * share * (0.85 + 0.3 * rng.unit())).rounded()) }
        let input = jitter(0.05)
        let cacheWrite = model.hasPrefix("claude-") ? jitter(0.02) : 0
        let output = jitter(0.02)
        let reasoning = jitter(0.006)
        let cacheRead = max(Int64(tokens.rounded()) - input - cacheWrite - output - reasoning, 0)
        return TokenCounts(input: input, cacheRead: cacheRead, cacheWrite: cacheWrite, output: output, reasoning: reasoning)
    }
}

/// SplitMix64, implemented here so output never changes with the standard library's generators.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }
}
