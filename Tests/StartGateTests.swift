import AppKit
import XCTest
@testable import Pourtype

/// When a run starts typing after ⌘⇧V: once the veil is up and the keys are let go, not when the HUD card has
/// loaded. The session's own clock is replayed here (its 30 ms tick, the veil's fade-in, the card's ready
/// message, the fallback timer), so the start time is measured without holding any input.
final class StartGateTests: XCTestCase {
    static let veilFadeIn = 0.14                 // Overlay.show's fade-in

    /// The old rule, for the before/after numbers: the card reported ready, or 1.2 s passed.
    static func before(_ elapsed: Double, _ hudReady: Bool, _ holding: Bool) -> Bool { (hudReady || elapsed >= 1.2) && !holding }

    /// The first moment typing may begin. veilUp/hudReady: when those events arrive (nil = never);
    /// release: when the last key comes up.
    static func begin(veilUp: Double?, hudReady: Double?, release: Double,
                      rule: ((Double, Bool, Bool) -> Bool)? = nil) -> Double {
        var times = Set(stride(from: 0.03, through: 6, by: 0.03).map { ($0 * 1000).rounded() / 1000 })
        times.insert(StartGate.fallback)
        times.insert(1.2)
        if let v = veilUp { times.insert(v) }
        if let h = hudReady { times.insert(h) }
        for t in times.sorted() {
            var g = StartGate()
            g.veilUp = veilUp.map { t >= $0 } ?? false
            g.hudReady = hudReady.map { t >= $0 } ?? false
            let open = rule.map { $0(t, g.hudReady, t < release) } ?? g.open(elapsed: t, holdingInput: t < release)
            if open { return t }
        }
        return .infinity
    }

    /// First run of the day: the card takes 0.9 s to load, the keys come up after 0.1 s.
    func testTypingStartsWhenTheVeilIsUpNotWhenTheCardHasLoaded() {
        let after = Self.begin(veilUp: Self.veilFadeIn, hudReady: 0.9, release: 0.1)
        let before = Self.begin(veilUp: Self.veilFadeIn, hudReady: 0.9, release: 0.1, rule: Self.before)
        print(String(format: "START_GATE slow card: before %.2f s, after %.2f s", before, after))
        XCTAssertEqual(before, 0.9, accuracy: 0.001)
        XCTAssertLessThanOrEqual(after, Self.veilFadeIn + 0.001)
    }

    /// The card never reports ready and the fade-in's completion never comes: the fallback is 0.2 s, not 1.2 s.
    func testTheFallbackIsAboutAFifthOfASecond() {
        XCTAssertEqual(StartGate.fallback, 0.2, accuracy: 0.0001)
        let after = Self.begin(veilUp: nil, hudReady: nil, release: 0)
        let before = Self.begin(veilUp: nil, hudReady: nil, release: 0, rule: Self.before)
        print(String(format: "START_GATE no card, no fade-in event: before %.2f s, after %.2f s", before, after))
        XCTAssertEqual(before, 1.2, accuracy: 0.001)
        XCTAssertEqual(after, 0.2, accuracy: 0.001)
    }

    /// Keys still down: it waits for them, as before (nothing may reach the app while the shortcut is held).
    func testItStillWaitsForTheKeysToBeLetGo() {
        let after = Self.begin(veilUp: Self.veilFadeIn, hudReady: 0.3, release: 0.75)
        XCTAssertGreaterThanOrEqual(after, 0.75)
        XCTAssertLessThan(after, 0.75 + 0.031)
        var g = StartGate()
        g.veilUp = true
        g.hudReady = true
        XCTAssertFalse(g.open(elapsed: 10, holdingInput: true))
    }

    /// The real HUD page in this process, off screen (never shown): how long its first and second loads take
    /// until the card is ready. The old rule waited for this before the first key; the new one does not.
    func testMeasureTheCardLoad() throws {
        var lines: [String] = []
        for run in 1...2 {
            let t0 = now()
            var loaded: Double?, ready: Double?
            let units = splitUnits("Measure the card")
            let payload: [String: Any] = [
                "units": units, "preview": false, "lang": "en", "reduceMotion": true,
                "target": ["app": "Test", "title": "", "field": "", "icon": ""],
                "state": ["i": 0, "cps": 40, "rand": 0.3, "eta": 1, "held": ["up": false, "down": false, "left": false, "right": false],
                          "nudge": 0, "phase": "typing"],
            ]
            let o = Overlay(screens: [ScreenInfo(frame: CGRect(x: 0, y: 0, width: 900, height: 600), visible: CGRect(x: 0, y: 0, width: 900, height: 600))],
                            target: 0, hole: nil, payload: payload, htmlURL: hudURL(), offscreen: true)
            o.onLoaded = { loaded = loaded ?? now() - t0 }
            o.onReady = { ready = ready ?? now() - t0 }
            let end = Date().addingTimeInterval(10)
            while ready == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            o.teardown()
            let l = try XCTUnwrap(loaded, "the HUD page did not load"), r = ready ?? .infinity
            let before = Self.begin(veilUp: Self.veilFadeIn, hudReady: r, release: 0.1, rule: Self.before)
            let after = Self.begin(veilUp: Self.veilFadeIn, hudReady: r, release: 0.1)
            lines.append(String(format: "run %d: page loaded %.0f ms, card ready %.0f ms -> first key at %.0f ms before, %.0f ms after",
                                run, l * 1000, r * 1000, before * 1000, after * 1000))
            XCTAssertLessThanOrEqual(after, before)
        }
        print("HUD_MEASURE " + lines.joined(separator: "; "))
    }
}
