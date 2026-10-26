import XCTest
@testable import Pourtype

/// The engine with a capturing sink instead of keyEvent: nothing is posted to the system.
final class EngineTests: XCTestCase {
    struct Ev: Equatable {
        let code: CGKeyCode, down: Bool, flags: UInt64, text: String?
    }

    final class Capture {
        private let lock = NSLock()
        private var list: [(ev: Ev, t: Double)] = []
        var events: [(ev: Ev, t: Double)] { lock.withLock { list } }
        func send(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags, _ unicode: [UniChar]?) {
            let ev = Ev(code: code, down: down, flags: flags.rawValue, text: unicode.map { String(utf16CodeUnits: $0, count: $0.count) })
            lock.withLock { list.append((ev, now())) }
        }
    }

    /// The events today's engine sends for these units: one down and one up per unit, Shift+Return for a newline.
    private func expected(_ units: [String]) -> [Ev] {
        units.flatMap { u -> [Ev] in
            u == "\n" ? [Ev(code: 36, down: true, flags: CGEventFlags.maskShift.rawValue, text: nil),
                         Ev(code: 36, down: false, flags: CGEventFlags.maskShift.rawValue, text: nil)]
                      : [Ev(code: 0, down: true, flags: 0, text: u), Ev(code: 0, down: false, flags: 0, text: u)]
        }
    }

    private func type(_ units: [String], _ pace: Pace, own: OwnPace?) -> [(ev: Ev, t: Double)] {
        let cap = Capture()
        let e = Engine(units, pace, own: own, send: cap.send)
        let ended = expectation(description: "ended")
        e.onEnd = { all in XCTAssertTrue(all); ended.fulfill() }
        e.start(replace: false)
        wait(for: [ended], timeout: 10)
        XCTAssertEqual(e.index, units.count)
        return cap.events
    }

    /// The learned profile changes timing only: the same keys, in the same order, as the fixed pace; no extra key
    /// (no wrong key and no Backspace) even with the highest correction rate the fitter can produce.
    func testOwnPaceSendsExactlyTheKeysOfTheFixedPace() throws {
        let units = splitUnits(prepareText("Hi, 7 Zoo!\nok 中文 👍🏽 e\u{301}."))
        var profile = HabitFitter.fit(HabitModelTests.passageSession(), nowUtc: "t")
        profile.typos = TypoModel(letterProbability: 0.2, correctionLatency: Lognormal(medianMs: 300, sigma: 0.3), n: 9)
        let own = OwnPace(profile)
        let fixed = type(units, Pace(cps: 150, rand: 0), own: nil)
        let learned = type(units, Pace(cps: 150, rand: 0), own: own)       // sped up as far as it goes, steady
        XCTAssertEqual(fixed.map(\.ev), expected(units))
        XCTAssertEqual(learned.map(\.ev), expected(units))
        // every character key held at least the learned floor, and each key up before the next key down
        for k in stride(from: 0, to: learned.count, by: 2) where learned[k].ev.code == 0 {
            XCTAssertGreaterThanOrEqual(learned[k + 1].t - learned[k].t, HabitTuning.keyHoldFloorMs / 1000 - 0.0005)
        }
        XCTAssertEqual(zip(learned, learned.dropFirst()).filter { $0.t > $1.t }.count, 0)
    }

    /// Esc during a long learned hold: stop() returns within a few ms, the held key has come up, and nothing
    /// reaches the app after that.
    func testStopDuringALongHoldReleasesTheKeyAtOnce() {
        let profile = TypingProfile(globalDwell: Fitted(dist: Lognormal(medianMs: 250, sigma: 0), n: 50),
                                    globalFlight: Fitted(dist: Lognormal(medianMs: 200, sigma: 0), n: 50))
        let own = OwnPace(profile)
        let cap = Capture()
        let e = Engine(splitUnits("abc"), own.start, own: own, send: cap.send)
        XCTAssertEqual(own.speed(own.start), 1)
        e.start(replace: false)
        let deadline = now() + 3
        while cap.events.isEmpty && now() < deadline { usleep(1000) }
        usleep(60_000)                                                      // well inside the 250 ms hold
        let t0 = now()
        e.stop()
        XCTAssertLessThan(now() - t0, 0.05)
        XCTAssertEqual(cap.events.map(\.ev), [Ev(code: 0, down: true, flags: 0, text: "a"), Ev(code: 0, down: false, flags: 0, text: "a")])
        usleep(500_000)
        XCTAssertEqual(cap.events.count, 2)
        XCTAssertEqual(e.index, 1)
    }

    /// Reading the index and pace (the card, the arrow keys) never waits for a learned hold.
    func testReadsDoNotWaitForAHold() {
        let profile = TypingProfile(globalDwell: Fitted(dist: Lognormal(medianMs: 250, sigma: 0), n: 50),
                                    globalFlight: Fitted(dist: Lognormal(medianMs: 200, sigma: 0), n: 50))
        let own = OwnPace(profile)
        let cap = Capture()
        let e = Engine(splitUnits("ab"), own.start, own: own, send: cap.send)
        e.start(replace: false)
        let deadline = now() + 3
        while cap.events.isEmpty && now() < deadline { usleep(1000) }
        let t0 = now()
        _ = e.index; _ = e.pace
        e.adjust { $0.cps *= 1.1 }
        XCTAssertLessThan(now() - t0, 0.02)
        e.stop()
    }

    /// No profile: the hold and the delays are today's fixed-pace functions, unchanged.
    func testWithoutAProfileTheTimingIsTheFixedPace() {
        for cps in [3.0, 15, 40, 150] {
            let units = splitUnits("ab, c.\nd")
            let p = Pace(cps: cps, rand: 0)
            for u in units { XCTAssertEqual(delayAfter(u, p), u == "\n" ? NEWLINE_PAUSE + 1 / cps : 1 / cps) }
        }
        XCTAssertNil(Engine(["a"], Pace(cps: 40, rand: 0.3)).ownPace)
    }
}
