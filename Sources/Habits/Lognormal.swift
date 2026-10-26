import Foundation

// The typing-habit model ("Type at my own pace"): fitted from how the user types a passage in
// Settings > Learn my typing, then used for the timing of each typed character.
// Port of the Windows Core (Pourtype.Core/Habits, 2026-10-26). Pure math, no AppKit.

/// Uniform doubles in [0, 1). Injected so tests can fix the sequence.
protocol RandomSource: AnyObject {
    func nextDouble() -> Double
}

final class SystemRandom: RandomSource {
    func nextDouble() -> Double { Double.random(in: 0..<1) }
}

/// A lognormal timing distribution in milliseconds: a draw is median * exp(sigma * z), z ~ N(0, 1),
/// clamped to median * exp(+-3 sigma) so one tail draw cannot stall a run.
struct Lognormal: Codable, Equatable {
    var medianMs: Double
    var sigma: Double

    /// One draw (ms). `spread` scales sigma (1 = as fitted, 0 = the median). Draw order: gauss (2 draws);
    /// no draw when the scaled sigma is 0.
    func sampleMs(_ rng: RandomSource, spread: Double = 1) -> Double {
        let s = sigma * spread
        guard s > 0 else { return medianMs }
        let v = medianMs * exp(s * HabitStats.gauss(rng))
        return min(max(v, medianMs * exp(-3 * s)), medianMs * exp(3 * s))
    }

    /// Median and sigma clamped to the ranges; a non-finite or non-positive median, or a non-finite sigma, gives nil.
    func clamped(median lo: Double, _ hi: Double, sigma slo: Double, _ shi: Double) -> Lognormal? {
        guard medianMs.isFinite, medianMs > 0, sigma.isFinite else { return nil }
        return Lognormal(medianMs: min(max(medianMs, lo), hi), sigma: min(max(sigma, slo), shi))
    }

    /// The distribution's mean (before the +-3 sigma clamp), for speed and time-left estimates.
    var meanMs: Double { medianMs * exp(sigma * sigma / 2) }
}

/// Percentiles, the lognormal fit and the normal draw used throughout the habit model.
enum HabitStats {
    /// Box-Muller with the same mapping as the engine's gauss(): u1 = ulp + (1 - ulp) * U, u2 = U.
    /// Draw order: u1, u2.
    static func gauss(_ rng: RandomSource) -> Double {
        let u1 = Double.ulpOfOne + (1 - Double.ulpOfOne) * rng.nextDouble()
        let u2 = rng.nextDouble()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }

    /// Linear-interpolation percentile (Excel PERCENTILE.INC), p in [0, 1]. Empty gives NaN, one sample that sample.
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        if values.isEmpty { return .nan }
        if values.count == 1 { return values[0] }
        let s = values.sorted()
        let rank = min(max(p, 0), 1) * Double(s.count - 1)
        let lo = Int(rank.rounded(.down)), hi = Int(rank.rounded(.up))
        if lo == hi { return s[lo] }
        return s[lo] + (s[hi] - s[lo]) * (rank - Double(lo))
    }

    /// median = P50; sigma = ln(P75 / P25) / 1.34898 (the interquartile range of a standard normal).
    /// Needs two positive samples (one gives that sample with sigma 0); sigma is never negative.
    static func fit(_ samples: [Double]) -> Lognormal? {
        let pos = samples.filter { $0.isFinite && $0 > 0 }
        if pos.count < 2 { return pos.count == 1 ? Lognormal(medianMs: pos[0], sigma: 0) : nil }
        let p25 = percentile(pos, 0.25), p50 = percentile(pos, 0.50), p75 = percentile(pos, 0.75)
        guard p25 > 0, p75 > 0, p50 > 0 else { return nil }
        return Lognormal(medianMs: p50, sigma: max(0, log(p75 / p25) / 1.34898))
    }
}
