import Foundation

/// Fits a TypingProfile from an in-memory RawCalibration. Pure math. Whatever misses its minimum sample count is
/// left nil so the population default stands: a default is never presented as the user's own number.
enum HabitFitter {
    private struct Flight {
        let ms: Double
        let bucket: DigraphBucket
        let from: KeyClass
        let toCapital: Bool
    }

    /// nowUtc: the caller's ISO-8601 timestamp, stored as the profile's creation date.
    static func fit(_ raw: RawCalibration, nowUtc: String) -> TypingProfile {
        let keys = raw.keys

        // Dwell per class, and over all keys.
        var dwellByClass: [KeyClass: Fitted] = [:]
        for (cls, group) in Dictionary(grouping: keys, by: \.cls) {
            dwellByClass[cls] = clampDwell(group.map { $0.upMs - $0.downMs }, HabitTuning.classMinSamples)
        }
        let globalDwell = clampDwell(keys.map { $0.upMs - $0.downMs }, HabitTuning.globalMinSamples)

        // Flights (key up to the next key down) between consecutive keys, with their bucket and context.
        var flights: [Flight] = []
        for i in keys.indices.dropFirst() {
            let ms = keys[i].downMs - keys[i - 1].upMs
            guard ms > 0 else { continue }   // overlap (rollover) is not a flight the model knows
            flights.append(Flight(ms: ms, bucket: KeyGeometry.bucket(keys[i - 1].pos, keys[i].pos),
                                  from: keys[i - 1].cls, toCapital: keys[i].capital))
        }

        // Long-pause split: strip gaps far above the body median, refit, repeat; then fit the long tail.
        let split = splitLongPauses(flights.map(\.ms))
        let threshold = split.bodyMedian + HabitTuning.longPauseExtraMs
        let body = split.bodyMedian.isNaN ? flights : flights.filter { $0.ms <= threshold }

        // Buckets come only from in-word flow: from a letter or digit, not into a capital. Gaps after a space or
        // punctuation and before a capital belong to the context factors alone, so no gap is counted twice.
        let inWord = body.filter { ($0.from == .letter || $0.from == .digit) && !$0.toCapital }
        var bucketFlight: [DigraphBucket: Fitted] = [:]
        for (bucket, group) in Dictionary(grouping: inWord, by: \.bucket) where bucket != .unknown {
            bucketFlight[bucket] = clampFlight(group.map(\.ms), HabitTuning.bucketMinSamples)
        }
        let globalFlight = clampFlight(body.map(\.ms), HabitTuning.globalMinSamples)

        // Context factors, relative to the body median.
        let bodyMed = globalFlight.dist?.medianMs ?? split.bodyMedian
        let wordStart = factor(body.filter { $0.from == .space }.map(\.ms), bodyMed, HabitTuning.defaultWordStartFactor)
        let afterPunct = factor(body.filter { $0.from == .punctuation }.map(\.ms), bodyMed, HabitTuning.defaultAfterPunctuationFactor)
        let beforeCap = factor(body.filter(\.toCapital).map(\.ms), bodyMed, HabitTuning.defaultBeforeCapitalFactor)

        // Corrections: the share of letter keys that were corrected, and how long a correction took.
        var typos = TypoModel.none
        let letters = raw.letterKeyCount
        if !raw.typos.isEmpty && letters > 0 {
            let p = min(max(Double(raw.typos.count) / Double(letters), 0), 0.2)
            let lat = HabitStats.fit(raw.typos.map(\.latencyMs))?.clamped(median: 120, 2000, sigma: 0.2, 1.2)
            typos = TypoModel(letterProbability: p, correctionLatency: lat, n: raw.typos.count)
        }

        return TypingProfile(
            version: 1,
            createdUtc: nowUtc,
            sampleChars: keys.count,
            dwell: dwellByClass,
            globalDwell: globalDwell.dist == nil ? Fitted(dist: HabitTuning.defaultDwell, n: 0) : globalDwell,
            bucketFlight: bucketFlight,
            globalFlight: globalFlight.dist == nil ? Fitted(dist: HabitTuning.defaultFlight, n: 0) : globalFlight,
            wordStartFactor: wordStart,
            afterPunctuationFactor: afterPunct,
            beforeCapitalFactor: beforeCap,
            longPauseFraction: split.fraction,
            longPause: split.longPause,
            typos: typos)
    }

    private static func clampDwell(_ samples: [Double], _ min: Int) -> Fitted {
        guard samples.count >= min else { return Fitted(dist: nil, n: samples.count) }
        let fit = HabitStats.fit(samples)?.clamped(median: HabitTuning.dwellMedianLoMs, HabitTuning.dwellMedianHiMs,
                                                   sigma: HabitTuning.dwellSigmaLo, HabitTuning.dwellSigmaHi)
        return Fitted(dist: fit, n: samples.count)
    }

    private static func clampFlight(_ samples: [Double], _ min: Int) -> Fitted {
        guard samples.count >= min else { return Fitted(dist: nil, n: samples.count) }
        let fit = HabitStats.fit(samples)?.clamped(median: HabitTuning.flightMedianLoMs, HabitTuning.flightMedianHiMs,
                                                   sigma: HabitTuning.flightSigmaLo, HabitTuning.flightSigmaHi)
        return Fitted(dist: fit, n: samples.count)
    }

    /// Start from the median of all flights; a gap above median + 300 ms is a long pause; refit the median on
    /// the rest; repeat. Returns the long-pause share (capped), its distribution and the final body median.
    private static func splitLongPauses(_ flights: [Double]) -> (fraction: Double, longPause: Lognormal?, bodyMedian: Double) {
        guard flights.count >= HabitTuning.globalMinSamples else { return (0, nil, .nan) }
        var median = HabitStats.percentile(flights, 0.5)
        var body = flights
        for _ in 0..<HabitTuning.longPauseIterations {
            let thr = median + HabitTuning.longPauseExtraMs
            let next = flights.filter { $0 <= thr }
            if next.count == body.count || next.isEmpty {
                if !next.isEmpty { body = next }
                break
            }
            body = next
            median = HabitStats.percentile(body, 0.5)
        }
        let longs = flights.filter { $0 > median + HabitTuning.longPauseExtraMs }
        let fraction = min(max(Double(longs.count) / Double(flights.count), 0), HabitTuning.longPauseFractionMax)
        let dist = longs.count >= HabitTuning.hesitationMinSamples
            ? HabitStats.fit(longs)?.clamped(median: min(median, 5000), 5000, sigma: 0.2, 1.5)
            : nil
        return (fraction, dist, median)
    }

    private static func factor(_ samples: [Double], _ bodyMedian: Double, _ fallback: Double) -> Double {
        guard samples.count >= HabitTuning.classMinSamples, bodyMedian > 0 else { return fallback }
        return min(max(HabitStats.percentile(samples, 0.5) / bodyMedian, 0.5), 6.0)
    }
}
