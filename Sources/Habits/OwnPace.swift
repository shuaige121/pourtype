import Foundation

/// A learned profile set up for one typing run ("Type at my own pace").
///
/// The live controls keep working around the user's own pace:
/// - Speed: the run starts at the speed the profile types at, shown on the card in chars/s (the slow shortcut
///   starts at half of it). Up/down change it as always; every learned time is scaled by start speed / speed.
/// - Rhythm: the run starts in the middle (0.5 = as learned). Left/right move it as always; it scales every
///   learned spread from 0 (steady: always the learned median, no long pauses) to twice the learned spread.
/// - Changes made during such a run are not saved as the default speed and rhythm, which belong to the fixed pace.
struct OwnPace {
    let profile: TypingProfile
    /// Mean seconds per character as learned (speed 1).
    let charSeconds: Double
    /// The chars/s that means "as learned": 1 / charSeconds, within CPS_MIN...CPS_MAX.
    let baseCps: Double
    /// The pace the run starts at.
    let start: Pace

    static let neutralRand = 0.5

    init(_ profile: TypingProfile, slow: Bool = false) {
        self.profile = profile
        let dwell = min(max((profile.globalDwell.dist ?? HabitTuning.defaultDwell).meanMs, HabitTuning.keyHoldFloorMs),
                        HabitTuning.dwellSampleCapMs)
        let flight = min((profile.globalFlight.dist ?? HabitTuning.defaultFlight).meanMs, HabitTuning.flightSampleCapMs)
        let stall = profile.longPause.map {
            max(0, min($0.meanMs, HabitTuning.longPauseSampleCapMs) - flight) * profile.longPauseFraction
        } ?? 0
        charSeconds = (dwell + flight + stall) / 1000
        baseCps = min(max(1 / charSeconds, CPS_MIN), CPS_MAX)
        var p = Pace(cps: slow ? baseCps * 0.5 : baseCps, rand: OwnPace.neutralRand)
        p.clamp()
        start = p
    }

    /// The run's own pace, or nil (today's fixed pace) when the setting is off or no usable profile is saved.
    static func forRun(mode: String, enabled: Bool, store: ProfileStore) -> OwnPace? {
        guard enabled, let profile = store.load() else { return nil }
        return OwnPace(profile, slow: mode == "slow")
    }

    /// Time multiplier: 1 at the start speed, below 1 when sped up.
    func speed(_ p: Pace) -> Double { baseCps / p.cps }
    /// Spread multiplier: 1 at the start rhythm.
    func spread(_ p: Pace) -> Double { p.rand / OwnPace.neutralRand }

    func timing(_ units: [String], _ i: Int, _ p: Pace, _ rng: RandomSource) -> UnitTiming {
        HabitTiming.forUnit(profile, units[i], i + 1 < units.count ? units[i + 1] : nil, rng,
                            speed: speed(p), spread: spread(p))
    }

    /// The expected time to type units[i...] at pace p; newlines keep the fixed pace's pauses.
    func eta(_ i: Int, _ n: Int, _ p: Pace, _ s: Suffix) -> Double {
        guard i < n else { return 0 }
        let nl = Double(s.nl[i]), chars = Double(n - i) - nl
        return chars * charSeconds * speed(p) + nl * (2 * NEWLINE_PAUSE + 1 / p.cps)
    }
}

/// The learned profile on disk: one JSON file in Application Support (inside the container in the App Store
/// build), beside the History folder and not in it, so clearing the history leaves it alone.
final class ProfileStore {
    static let shared = ProfileStore()
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Pourtype", isDirectory: true)
            .appendingPathComponent("TypingProfile.json")
    }

    /// nil when there is none, or the file is damaged or not usable.
    func load() -> TypingProfile? {
        guard let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(TypingProfile.self, from: data), p.isUsable else { return nil }
        return p
    }

    /// Replaces any earlier profile.
    func save(_ p: TypingProfile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ProfileStore.encode(p).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }

    static func encode(_ p: TypingProfile) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try e.encode(p)
    }
}
