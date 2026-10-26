import XCTest
@testable import Pourtype

/// Returns the given values in order and counts the draws; running out fails the test.
final class SequenceRandom: RandomSource {
    private let values: [Double]
    private(set) var draws = 0
    init(_ values: Double...) { self.values = values }
    func nextDouble() -> Double {
        guard draws < values.count else {
            XCTFail("no more random values (draw \(draws + 1))")
            return 0.5
        }
        defer { draws += 1 }
        return values[draws]
    }
}

/// Deterministic uniform doubles (SplitMix64).
final class SeededRandom: RandomSource {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    func nextDouble() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}
