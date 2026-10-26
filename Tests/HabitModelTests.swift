import Carbon
import XCTest
@testable import Pourtype

/// The habit model. The first group ports tests/Pourtype.Core.Tests/Habits/HabitModelTests.cs from the Windows
/// port with the same inputs and numbers; the rest covers what the Mac adds.
final class HabitModelTests: XCTestCase {

    // MARK: - ported from Windows

    func testPercentileInterpolatesLikeExcelInc() {
        let v: [Double] = [1, 2, 3, 4]
        XCTAssertEqual(HabitStats.percentile(v, 0), 1)
        XCTAssertEqual(HabitStats.percentile(v, 1), 4)
        XCTAssertEqual(HabitStats.percentile(v, 0.5), 2.5, accuracy: 1e-9)
        XCTAssertEqual(HabitStats.percentile(v, 0.25), 1.75, accuracy: 1e-9)   // rank 0.75 -> 1 + 0.75 * (2 - 1)
        XCTAssertEqual(HabitStats.percentile(v, 0.75), 3.25, accuracy: 1e-9)
        XCTAssertTrue(HabitStats.percentile([], 0.5).isNaN)
        XCTAssertEqual(HabitStats.percentile([7], 0.9), 7)
    }

    func testFitUsesP50AndIqrForSigma() throws {
        let fit = try XCTUnwrap(HabitStats.fit([100, 110, 120, 130, 140]))   // P25 110, P50 120, P75 130
        XCTAssertEqual(fit.medianMs, 120, accuracy: 1e-9)
        XCTAssertEqual(fit.sigma, log(130.0 / 110.0) / 1.34898, accuracy: 1e-9)
        XCTAssertNil(HabitStats.fit([]))
        XCTAssertEqual(try XCTUnwrap(HabitStats.fit([55])).sigma, 0)          // one sample: median, zero sigma
    }

    func testSampleIsClampedToThreeSigma() {
        let dist = Lognormal(medianMs: 100, sigma: 0.5)
        // u1 tiny, u2 = 0 -> gauss ~ +6.4, far past +3 sigma -> clamped high; u2 = 0.5 -> cos(pi) = -1 -> low.
        XCTAssertEqual(dist.sampleMs(SequenceRandom(1e-9, 0.0)), 100 * exp(3 * 0.5), accuracy: 1e-6)
        XCTAssertEqual(dist.sampleMs(SequenceRandom(1e-9, 0.5)), 100 * exp(-3 * 0.5), accuracy: 1e-6)
        XCTAssertEqual(Lognormal(medianMs: 100, sigma: 0).sampleMs(SequenceRandom()), 100)   // zero sigma: no draw
    }

    func testClassOfClassesByFirstRune() {
        let cases: [(String, KeyClass)] = [("a", .letter), ("Z", .letter), ("7", .digit), (" ", .space), ("\n", .enter),
                                           (",", .punctuation), ("!", .punctuation), ("你", .other), ("\u{1F600}", .other)]
        for (unit, expected) in cases { XCTAssertEqual(KeyGeometry.classOf(unit), expected, unit) }
    }

    func testBucketOfClassifiesDigraphs() {
        XCTAssertEqual(KeyGeometry.bucketOf("e", "d"), .sameFinger)       // same hand and finger, other row
        XCTAssertEqual(KeyGeometry.bucketOf("f", "j"), .alternateHands)
        XCTAssertEqual(KeyGeometry.bucketOf("a", "s"), .sameHand)
        XCTAssertEqual(KeyGeometry.bucketOf("q", "c"), .rowJump)          // same hand, other finger, two rows apart
        XCTAssertEqual(KeyGeometry.bucketOf("a", "4"), .unknown)          // digits are off the letter map
    }

    func testMisHitNeighbourIsAnAdjacentSameHandKey() {
        XCTAssertEqual(KeyGeometry.misHitNeighbour("b"), "v")
        XCTAssertEqual(KeyGeometry.misHitNeighbour("B"), "v")             // case folded; HabitTiming restores it
        XCTAssertNotNil(KeyGeometry.misHitNeighbour("s"))
        XCTAssertNil(KeyGeometry.misHitNeighbour(" "))
        XCTAssertNil(KeyGeometry.misHitNeighbour("7"))
        XCTAssertNil(KeyGeometry.misHitNeighbour("你"))
    }

    /// The Windows SampleSession: letters held ~100 ms, flights ~130 ms, slower after a space, one long stall
    /// after the full stop and one correction per round.
    static func sampleSession(rounds: Int = 20) -> RawCalibration {
        let raw = RawCalibration()
        var t = 0.0
        for r in 0..<rounds {
            for c in "the quick brown fox. " {
                let g = String(c)
                let down = t, up = down + 100 + Double(r % 5)
                raw.add(RawKey(cls: KeyGeometry.classOf(g), unit: g, downMs: down, upMs: up))
                var flight = c == " " ? 200 + Double(r) : 120 + Double(r % 7)
                if c == "." { flight = 900 }
                t = up + flight
            }
            raw.addTypo(RawTypo(latencyMs: 280 + Double(r)))
        }
        return raw
    }

    func testFitterProducesAProfileWithTheExpectedShape() throws {
        let p = HabitFitter.fit(Self.sampleSession(), nowUtc: "2026-10-26T00:00:00.0000000Z")
        XCTAssertEqual(p.version, 1)
        XCTAssertGreaterThan(p.sampleChars, 200)
        let letter = try XCTUnwrap(p.dwell[.letter]?.dist)
        XCTAssertTrue((HabitTuning.dwellMedianLoMs...HabitTuning.dwellMedianHiMs).contains(letter.medianMs))
        XCTAssertTrue((95.0...110).contains(letter.medianMs))              // ~100 ms as recorded
        let flight = try XCTUnwrap(p.globalFlight.dist)
        XCTAssertTrue((HabitTuning.flightMedianLoMs...HabitTuning.flightMedianHiMs).contains(flight.medianMs))
        XCTAssertGreaterThan(p.wordStartFactor, 1.0)                        // the flight after a space was slower
        XCTAssertTrue((0.0...HabitTuning.longPauseFractionMax).contains(p.longPauseFraction))
        XCTAssertGreaterThan(p.longPauseFraction, 0)                        // the stall after each full stop
        XCTAssertNotNil(p.longPause)
        XCTAssertGreaterThan(p.typos.letterProbability, 0)
        XCTAssertNotNil(p.typos.correctionLatency)
    }

    func testTooFewSamplesLeaveNullSoTheDefaultStands() {
        let raw = RawCalibration()
        for i in 0..<3 { raw.add(RawKey(cls: .letter, unit: "a", downMs: Double(i) * 300, upMs: Double(i) * 300 + 100)) }
        let p = HabitFitter.fit(raw, nowUtc: "2026-10-26T00:00:00.0000000Z")
        XCTAssertNil(p.dwell[.letter]?.dist)                               // below classMinSamples
        XCTAssertEqual(p.globalDwell.dist, HabitTuning.defaultDwell)       // global below its minimum: the default
        XCTAssertEqual(p.globalFlight.dist, HabitTuning.defaultFlight)
        XCTAssertEqual(p.longPauseFraction, 0)
    }

    func testProfileDependsOnClassAndGeometryNotCharacterIdentity() {
        // Dwell by class, global dwell and the typo rate depend on class and timing only: removing the key
        // identities leaves them unchanged (only the geometry parts may differ).
        let with = Self.sampleSession()
        let nulled = RawCalibration()
        for k in with.keys { nulled.add(RawKey(cls: k.cls, unit: nil, downMs: k.downMs, upMs: k.upMs)) }
        for t in with.typos { nulled.addTypo(t) }
        let a = HabitFitter.fit(with, nowUtc: "t"), b = HabitFitter.fit(nulled, nowUtc: "t")
        XCTAssertEqual(a.dwell[.letter]?.dist, b.dwell[.letter]?.dist)
        XCTAssertEqual(a.globalDwell.dist, b.globalDwell.dist)
        XCTAssertEqual(a.typos.letterProbability, b.typos.letterProbability)
    }

    func testForUnitHoldsAtLeastTheFloorAndSchedulesTheNextKey() {
        let slow = TypingProfile(dwell: [.letter: Fitted(dist: Lognormal(medianMs: 40, sigma: 0.8), n: 50)],
                                 globalDwell: Fitted(dist: Lognormal(medianMs: 40, sigma: 0.8), n: 50),
                                 globalFlight: Fitted(dist: Lognormal(medianMs: 120, sigma: 0.5), n: 50))
        // The dwell draw is forced far negative (~3-4 ms), so the 30 ms floor applies.
        let t = HabitTiming.forUnit(slow, "a", "b", SequenceRandom(1e-9, 0.5, 0.5, 0.5, 0.99))
        XCTAssertGreaterThanOrEqual(t.dwellSeconds, HabitTuning.keyHoldFloorMs / 1000 - 1e-9)
        XCTAssertGreaterThan(t.gapSeconds, t.dwellSeconds)                 // gap = dwell + flight
    }

    func testForUnitCapsAnExtremeDrawInAbsoluteTime() {
        let wild = TypingProfile(globalDwell: Fitted(dist: Lognormal(medianMs: 250, sigma: 0.8), n: 50),
                                 globalFlight: Fitted(dist: Lognormal(medianMs: 600, sigma: 1.2), n: 50))
        // gauss ~ +6.4 for both draws: far past +3 sigma, then the absolute caps.
        let t = HabitTiming.forUnit(wild, "a", "b", SequenceRandom(1e-9, 0.0, 1e-9, 0.0))
        XCTAssertEqual(t.dwellSeconds, HabitTuning.dwellSampleCapMs / 1000, accuracy: 1e-6)
        XCTAssertEqual(t.gapSeconds, (HabitTuning.dwellSampleCapMs + HabitTuning.flightSampleCapMs) / 1000, accuracy: 1e-6)
    }

    func testForUnitWithNoNextKeyHasZeroFlight() {
        let t = HabitTiming.forUnit(.default, "a", nil, SeededRandom(1))
        XCTAssertEqual(t.dwellSeconds, t.gapSeconds, accuracy: 1e-9)       // no next key: the gap is the dwell
    }

    func testMisHitRespectsTheGuards() {
        let p = HabitFitter.fit(Self.sampleSession(), nowUtc: "t")
        XCTAssertNil(HabitTiming.misHit(p, "b", isLast: false, typosEnabled: false, SequenceRandom(0.0)))
        XCTAssertNil(HabitTiming.misHit(p, "b", isLast: true, typosEnabled: true, SequenceRandom(0.0)))
        XCTAssertNil(HabitTiming.misHit(p, " ", isLast: false, typosEnabled: true, SequenceRandom(0.0)))
        XCTAssertEqual(HabitTiming.misHit(p, "b", isLast: false, typosEnabled: true, SequenceRandom(0.0)), "v")
        XCTAssertEqual(HabitTiming.misHit(p, "B", isLast: false, typosEnabled: true, SequenceRandom(0.0)), "V")
        XCTAssertNil(HabitTiming.misHit(p, "b", isLast: false, typosEnabled: true, SequenceRandom(0.99)))
    }

    // MARK: - exact numbers (reference: a line-by-line Python copy of the Windows HabitFitter.cs)

    private func assertFit(_ f: Fitted?, _ median: Double?, _ sigma: Double?, _ n: Int,
                           file: StaticString = #filePath, line: UInt = #line) {
        guard let f else { return XCTFail("missing fit", file: file, line: line) }
        XCTAssertEqual(f.n, n, file: file, line: line)
        guard let median, let sigma else { return XCTAssertNil(f.dist, file: file, line: line) }
        guard let d = f.dist else { return XCTFail("no distribution", file: file, line: line) }
        XCTAssertEqual(d.medianMs, median, accuracy: 1e-9 * median, file: file, line: line)
        XCTAssertEqual(d.sigma, sigma, accuracy: 1e-9, file: file, line: line)
    }

    func testFitMatchesTheReferenceOnTheWindowsSampleSession() throws {
        let p = HabitFitter.fit(Self.sampleSession(), nowUtc: "t")
        XCTAssertEqual(p.sampleChars, 420)
        XCTAssertEqual(Set(p.dwell.keys), [.letter, .space, .punctuation])
        assertFit(p.dwell[.letter], 102, 0.1, 320)
        assertFit(p.dwell[.space], 102, 0.1, 80)
        assertFit(p.dwell[.punctuation], 102, 0.1, 20)
        assertFit(p.globalDwell, 102, 0.1, 420)
        XCTAssertEqual(Set(p.bucketFlight.keys), [.alternateHands, .rowJump, .sameHand, .sameFinger])
        assertFit(p.bucketFlight[.alternateHands], 123, 0.2, 240)
        assertFit(p.bucketFlight[.rowJump], 123, 0.2, 20)
        assertFit(p.bucketFlight[.sameHand], 123, 0.2, 20)
        assertFit(p.bucketFlight[.sameFinger], 123, 0.2, 20)
        assertFit(p.globalFlight, 124, 0.2, 399)
        XCTAssertEqual(p.wordStartFactor, 1.685483870967742, accuracy: 1e-12)
        XCTAssertEqual(p.afterPunctuationFactor, 1.6)                      // every after-stop gap was a stall
        XCTAssertEqual(p.beforeCapitalFactor, 1.0)
        XCTAssertEqual(p.longPauseFraction, 0.0477326968973747, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(p.longPause), Lognormal(medianMs: 900, sigma: 0.2))
        XCTAssertEqual(p.typos.letterProbability, 0.0625, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(p.typos.correctionLatency), Lognormal(medianMs: 289.5, sigma: 0.2))
        XCTAssertEqual(p.typos.n, 20)
    }

    /// The real passage with uneven integer timings (an LCG both the Swift test and the Python reference use),
    /// every 17th gap a stall: no number here sits on a clamp.
    static func passageSession(withTypos: Bool = true) -> RawCalibration {
        var state = 20261026
        func rnd() -> Int { state = (state * 1103515245 + 12345) % 2147483648; return state }
        let raw = RawCalibration()
        var t = 0.0
        for (j, c) in CalibrationPassage.text.enumerated() {
            let d = Double(50 + rnd() % 150)
            var f = Double(60 + rnd() % 400)
            if j % 17 == 16 { f += 1200 }
            raw.add(RawKey(cls: KeyGeometry.classOf(String(c)), unit: String(c), downMs: t, upMs: t + d))
            t += d + f
        }
        for _ in 0..<5 {
            let lat = Double(200 + rnd() % 600)
            if withTypos { raw.addTypo(RawTypo(latencyMs: lat)) }
        }
        return raw
    }

    func testFitMatchesTheReferenceOnAnUnevenSession() throws {
        XCTAssertEqual(CalibrationPassage.text.count, 334)
        let p = HabitFitter.fit(Self.passageSession(), nowUtc: "t")
        XCTAssertEqual(p.sampleChars, 334)
        assertFit(p.dwell[.letter], 129, 0.4136789987274692, 245)
        assertFit(p.dwell[.space], 127, 0.36904804240179956, 68)
        assertFit(p.dwell[.digit], 145, 0.3604831167622004, 9)
        assertFit(p.dwell[.punctuation], 115, 0.2412358970738098, 12)
        assertFit(p.globalDwell, 127, 0.3952283207787212, 334)
        assertFit(p.bucketFlight[.rowJump], 300, 0.8105908828653434, 47)
        assertFit(p.bucketFlight[.sameHand], 274, 0.5200687760272426, 68)
        assertFit(p.bucketFlight[.alternateHands], 272, 0.5967438217738692, 103)
        assertFit(p.bucketFlight[.sameFinger], nil, nil, 7)                 // below bucketMinSamples: null
        assertFit(p.globalFlight, 273, 0.6261017979644165, 314)
        XCTAssertEqual(p.wordStartFactor, 0.8644688644688645, accuracy: 1e-12)
        XCTAssertEqual(p.afterPunctuationFactor, 1.2783882783882783, accuracy: 1e-12)
        XCTAssertEqual(p.beforeCapitalFactor, 0.717948717948718, accuracy: 1e-12)
        XCTAssertEqual(p.longPauseFraction, 0.057057057057057055, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(p.longPause), Lognormal(medianMs: 1454, sigma: 0.2))
        XCTAssertEqual(p.typos.letterProbability, 0.02040816326530612, accuracy: 1e-12)
        let lat = try XCTUnwrap(p.typos.correctionLatency)
        XCTAssertEqual(lat.medianMs, 659)
        XCTAssertEqual(lat.sigma, 0.2496445720180227, accuracy: 1e-12)
    }

    // MARK: - Mac key codes

    func testMacKeyCodesLandInTheSameBuckets() {
        XCTAssertEqual(KeyGeometry.ansiKeys.count, 27)                       // 26 letters and space
        let chars = Array("abcdefghijklmnopqrstuvwxyz ")
        for (code, c) in KeyGeometry.ansiKeys {
            XCTAssertEqual(KeyGeometry.pos(keyCode: code), KeyGeometry.posOf(String(c)), "key code \(code)")
        }
        let code = Dictionary(uniqueKeysWithValues: KeyGeometry.ansiKeys.map { ($0.value, $0.key) })
        for a in chars {
            for b in chars {
                XCTAssertEqual(KeyGeometry.bucket(KeyGeometry.pos(keyCode: code[a]!), KeyGeometry.pos(keyCode: code[b]!)),
                               KeyGeometry.bucketOf(String(a), String(b)), "\(a)\(b)")
            }
        }
        XCTAssertEqual(KeyGeometry.posOf("Q"), KeyGeometry.pos(keyCode: kVK_ANSI_Q))
        XCTAssertNil(KeyGeometry.pos(keyCode: kVK_ANSI_1))
        XCTAssertNil(KeyGeometry.pos(keyCode: kVK_ANSI_Period))
    }

    /// The finger numbers exactly as the Windows map assigns them, so both platforms bucket alike. On the home and
    /// bottom rows the right hand is numbered one key off standard touch typing (j, k, l, n, m); kept as Windows has it.
    func testFingerMapMatchesWindows() {
        func fingers(_ row: String) -> [Int] { row.map { KeyGeometry.posOf(String($0))!.finger } }
        XCTAssertEqual(fingers("qwertyuiop"), [0, 1, 2, 3, 3, 3, 3, 2, 1, 0])
        XCTAssertEqual(fingers("asdfghjkl"), [0, 1, 2, 3, 3, 3, 2, 1, 0])
        XCTAssertEqual(fingers("zxcvbnm"), [0, 1, 2, 3, 3, 1, 0])
        XCTAssertEqual(KeyGeometry.posOf(" "), KeyPos(row: 3, hand: 0, finger: 4))
    }

    // MARK: - speed and spread (the live controls)

    private let flat = TypingProfile(globalDwell: Fitted(dist: Lognormal(medianMs: 100, sigma: 0.3), n: 50),
                                     globalFlight: Fitted(dist: Lognormal(medianMs: 200, sigma: 0.5), n: 50),
                                     longPauseFraction: 0.1, longPause: Lognormal(medianMs: 1200, sigma: 0.3))

    func testSpeedAndSpreadOfOneAreTheWindowsDraw() {
        let draws: [Double] = [0.3, 0.7, 0.2, 0.9, 0.05, 0.4, 0.6]
        let a = HabitTiming.forUnit(flat, "a", "b", SequenceRandom(draws[0], draws[1], draws[2], draws[3], draws[4], draws[5], draws[6]))
        let b = HabitTiming.forUnit(flat, "a", "b", SequenceRandom(draws[0], draws[1], draws[2], draws[3], draws[4], draws[5], draws[6]),
                                    speed: 1, spread: 1)
        XCTAssertEqual(a, b)
    }

    func testSpeedScalesTimeAndSpreadZeroIsTheMedian() {
        let r = SequenceRandom()                                            // spread 0: no draw at all
        let steady = HabitTiming.forUnit(flat, "a", "b", r, spread: 0)
        XCTAssertEqual(r.draws, 0)
        XCTAssertEqual(steady.dwellSeconds, 0.100, accuracy: 1e-12)
        XCTAssertEqual(steady.gapSeconds, 0.300, accuracy: 1e-12)
        let fast = HabitTiming.forUnit(flat, "a", "b", SequenceRandom(), speed: 0.5, spread: 0)
        XCTAssertEqual(fast.dwellSeconds, 0.050, accuracy: 1e-12)
        XCTAssertEqual(fast.gapSeconds, 0.150, accuracy: 1e-12)
        let fastest = HabitTiming.forUnit(flat, "a", nil, SequenceRandom(), speed: 0.01, spread: 0)
        XCTAssertEqual(fastest.dwellSeconds, HabitTuning.keyHoldFloorMs / 1000, accuracy: 1e-12)   // the floor holds
        let slowest = HabitTiming.forUnit(flat, "a", "b", SequenceRandom(), speed: 20, spread: 0)
        XCTAssertEqual(slowest.dwellSeconds, HabitTuning.dwellSampleCapMs / 1000, accuracy: 1e-12)  // and the caps
        XCTAssertEqual(slowest.gapSeconds, (HabitTuning.dwellSampleCapMs + HabitTuning.flightSampleCapMs) / 1000, accuracy: 1e-12)
    }
}
