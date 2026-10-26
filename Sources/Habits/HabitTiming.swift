import Foundation

/// How long to hold one unit's key, and the time from its key down to the next unit's key down. Seconds.
struct UnitTiming: Equatable {
    var dwellSeconds: Double
    var gapSeconds: Double
}

/// Draws per-unit timing from a TypingProfile. The only randomness is the injected RandomSource.
enum HabitTiming {
    /// Dwell for `from`, and the gap to `to` (nil for the last unit: then the gap is the dwell).
    /// speed multiplies every time (1 = as learned, 0.5 = twice as fast); spread multiplies every sigma
    /// (1 = as learned, 0 = always the median) and, up to 1, the chance of a long pause. The floor and the
    /// absolute caps apply after both. With speed 1 and spread 1 this is the Windows HabitTiming.ForUnit.
    /// Draw order: dwell (2 draws), flight (2), long-pause test (1, only with a long-pause distribution and a
    /// chance above 0), and the long-pause length (2) only when it fires; a sigma scaled to 0 draws nothing.
    static func forUnit(_ profile: TypingProfile, _ from: String, _ to: String?, _ rng: RandomSource,
                        speed: Double = 1, spread: Double = 1) -> UnitTiming {
        let fromClass = KeyGeometry.classOf(from)
        let dwellMs = min(max(dwellDist(profile, fromClass).sampleMs(rng, spread: spread) * speed,
                              HabitTuning.keyHoldFloorMs), HabitTuning.dwellSampleCapMs)
        var flightMs = 0.0
        if let to {
            flightMs = flightDist(profile, from, to).sampleMs(rng, spread: spread) * contextFactor(profile, fromClass, to) * speed
            flightMs = min(flightMs, HabitTuning.flightSampleCapMs)
            let stallChance = profile.longPauseFraction * min(spread, 1)
            if let lp = profile.longPause, stallChance > 0, rng.nextDouble() < stallChance {
                let stall = min(lp.sampleMs(rng, spread: spread) * speed, HabitTuning.longPauseSampleCapMs)
                flightMs = max(flightMs, stall)   // a stall: the gap itself is long
            }
        }
        return UnitTiming(dwellSeconds: dwellMs / 1000, gapSeconds: (dwellMs + flightMs) / 1000)
    }

    private static func dwellDist(_ profile: TypingProfile, _ cls: KeyClass) -> Lognormal {
        if let d = profile.dwell[cls]?.dist { return d }
        return profile.globalDwell.dist ?? HabitTuning.defaultDwell
    }

    private static func flightDist(_ profile: TypingProfile, _ from: String, _ to: String) -> Lognormal {
        let bucket = KeyGeometry.bucketOf(from, to)
        if bucket != .unknown, let d = profile.bucketFlight[bucket]?.dist { return d }
        return profile.globalFlight.dist ?? HabitTuning.defaultFlight
    }

    private static func contextFactor(_ profile: TypingProfile, _ fromClass: KeyClass, _ to: String) -> Double {
        var f = 1.0
        if fromClass == .space { f *= profile.wordStartFactor }
        if fromClass == .punctuation { f *= profile.afterPunctuationFactor }
        if KeyGeometry.isUpperLetter(to) { f *= profile.beforeCapitalFactor }
        return f
    }

    /// Whether a habitual mis-hit would land before this unit, and on which neighbour key. Ported for parity with
    /// the Windows model and its tests. Nothing in the app calls it: the engine never types a wrong key, so the
    /// text that arrives is always exactly the clipboard. Draw order: one draw.
    static func misHit(_ profile: TypingProfile, _ unit: String, isLast: Bool, typosEnabled: Bool,
                       _ rng: RandomSource) -> Character? {
        guard typosEnabled, !isLast, profile.typos.letterProbability > 0, profile.typos.correctionLatency != nil,
              KeyGeometry.classOf(unit) == .letter, rng.nextDouble() < profile.typos.letterProbability,
              let n = KeyGeometry.misHitNeighbour(unit) else { return nil }
        return KeyGeometry.isUpperLetter(unit) ? Character(n.uppercased()) : n
    }

    /// Correction latency (seconds) of a mis-hit. Draw order: 2 draws.
    static func correctionSeconds(_ profile: TypingProfile, _ rng: RandomSource) -> Double {
        (profile.typos.correctionLatency ?? Lognormal(medianMs: 300, sigma: 0.4)).sampleMs(rng) / 1000
    }
}
