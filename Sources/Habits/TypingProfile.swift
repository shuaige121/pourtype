import Foundation

/// Clamps, floors, minimum sample counts and population defaults, in one place. Milliseconds unless noted.
/// Same values as the Windows port.
enum HabitTuning {
    static let dwellMedianLoMs = 40.0, dwellMedianHiMs = 250.0, dwellSigmaLo = 0.1, dwellSigmaHi = 0.8
    static let flightMedianLoMs = 60.0, flightMedianHiMs = 600.0, flightSigmaLo = 0.2, flightSigmaHi = 1.2
    static let keyHoldFloorMs = 30.0           // a key is always held at least this long
    // Absolute caps on one replay draw, on top of the +-3 sigma clamp: no key is ever held for seconds
    // and no gap stalls the run.
    static let dwellSampleCapMs = 400.0
    static let flightSampleCapMs = 1500.0
    static let longPauseSampleCapMs = 3000.0
    static let longPauseFractionMax = 0.15
    static let longPauseExtraMs = 300.0        // a flight this far above the body median is a long pause

    static let classMinSamples = 6             // per key-class dwell, and per context factor
    static let bucketMinSamples = 8            // per geometry bucket before the global flight is used
    static let globalMinSamples = 20           // global dwell / flight, and the long-pause split
    static let hesitationMinSamples = 3        // long pauses needed before their distribution is kept

    static let longPauseIterations = 5         // strip-and-refit passes for the flight body

    // Population defaults (Dhakal et al. 2018): dwell 116 ms; inter-key interval 239 ms, so flight ~ 123 ms.
    static let defaultDwell = Lognormal(medianMs: 116, sigma: 0.30)
    static let defaultFlight = Lognormal(medianMs: 123, sigma: 0.50)
    static let defaultWordStartFactor = 1.3
    static let defaultAfterPunctuationFactor = 1.6
    static let defaultBeforeCapitalFactor = 1.0
}

/// A fitted lognormal with its sample count; a nil dist means too few samples, so the default stands.
struct Fitted: Codable, Equatable {
    var dist: Lognormal?
    var n: Int
}

/// How often the user corrected a letter during Learn my typing, and how long a correction took.
/// Numbers only, no characters. The engine never reads it: Pourtype never types a wrong key on purpose.
struct TypoModel: Codable, Equatable {
    var letterProbability: Double
    var correctionLatency: Lognormal?
    var n: Int
    static let none = TypoModel(letterProbability: 0, correctionLatency: nil, n: 0)
}

/// The user's typing habits, fitted from one Learn my typing session. Milliseconds. Saved as JSON in
/// Application Support (ProfileStore); it holds counts and distribution parameters per key class and per
/// geometry bucket, never a typed character, a timestamp or the passage.
struct TypingProfile: Codable, Equatable {
    var version = 1
    var createdUtc = ""
    var sampleChars = 0

    /// Dwell (key down to up) per key class, and over all keys.
    var dwell: [KeyClass: Fitted] = [:]
    var globalDwell = Fitted(dist: nil, n: 0)

    /// Flight (key up to the next key down) per geometry bucket, and over all keys.
    var bucketFlight: [DigraphBucket: Fitted] = [:]
    var globalFlight = Fitted(dist: nil, n: 0)

    var wordStartFactor = HabitTuning.defaultWordStartFactor
    var afterPunctuationFactor = HabitTuning.defaultAfterPunctuationFactor
    var beforeCapitalFactor = HabitTuning.defaultBeforeCapitalFactor

    /// Share of gaps that are long pauses, and their distribution.
    var longPauseFraction = 0.0
    var longPause: Lognormal?

    var typos = TypoModel.none

    /// The population-default profile.
    static let `default` = TypingProfile(globalDwell: Fitted(dist: HabitTuning.defaultDwell, n: 0),
                                         globalFlight: Fitted(dist: HabitTuning.defaultFlight, n: 0))

    /// false for a file that is not one of ours or holds numbers the model cannot use (a damaged or edited file).
    var isUsable: Bool {
        func ok(_ l: Lognormal?) -> Bool { l.map { $0.medianMs.isFinite && $0.medianMs > 0 && $0.sigma.isFinite && $0.sigma >= 0 } ?? true }
        let dists = [globalDwell.dist, globalFlight.dist, longPause] + dwell.values.map(\.dist) + bucketFlight.values.map(\.dist)
        let factors = [wordStartFactor, afterPunctuationFactor, beforeCapitalFactor]
        return version == 1 && dists.allSatisfy(ok) && factors.allSatisfy { $0.isFinite && $0 > 0 }
            && longPauseFraction.isFinite && (0...HabitTuning.longPauseFractionMax).contains(longPauseFraction)
    }
}
