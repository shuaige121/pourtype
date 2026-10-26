import XCTest
@testable import Pourtype

/// "Type at my own pace": the profile file, the setting, and how the live controls map onto the profile.
final class OwnPaceTests: XCTestCase {
    // MARK: - storage

    func testProfileStoreSavesReplacesAndDeletes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProfileStore(url: dir.appendingPathComponent("TypingProfile.json"))
        XCTAssertNil(store.load())
        let first = HabitFitter.fit(HabitModelTests.sampleSession(), nowUtc: "a")
        try store.save(first)
        XCTAssertEqual(store.load(), first)
        let second = HabitFitter.fit(HabitModelTests.passageSession(), nowUtc: "b")
        try store.save(second)                                              // learning again replaces it
        XCTAssertEqual(store.load(), second)
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        try Data("{\"version\": 1, \"longPauseFraction\": 0.9}".utf8).write(to: store.url)   // damaged or edited
        XCTAssertNil(store.load())
        store.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertNil(store.load())
    }

    /// Application Support/<bundle id>/TypingProfile.json: beside History/, which Clear History empties.
    func testTheProfileIsNotInTheHistoryFolder() {
        let url = ProfileStore.shared.url                                   // a path only; nothing is read or written
        XCTAssertEqual(url.lastPathComponent, "TypingProfile.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, Bundle.main.bundleIdentifier)
        XCTAssertFalse(url.pathComponents.contains("History"))
    }

    // MARK: - own pace

    private let flat = TypingProfile(globalDwell: Fitted(dist: Lognormal(medianMs: 100, sigma: 0.3), n: 50),
                                     globalFlight: Fitted(dist: Lognormal(medianMs: 200, sigma: 0.5), n: 50),
                                     longPauseFraction: 0.1, longPause: Lognormal(medianMs: 1200, sigma: 0.3))

    func testOwnPaceMapsTheLiveControls() {
        let own = OwnPace(flat)
        XCTAssertEqual(own.start.rand, OwnPace.neutralRand)
        XCTAssertEqual(own.start.cps, own.baseCps)
        XCTAssertEqual(own.speed(own.start), 1)
        XCTAssertEqual(own.spread(own.start), 1)
        var faster = own.start; faster.cps *= 2                            // up arrow: twice as fast
        XCTAssertEqual(own.speed(faster), 0.5, accuracy: 1e-12)
        XCTAssertEqual(own.spread(Pace(cps: 10, rand: 0)), 0)               // left arrow all the way: steady
        XCTAssertEqual(OwnPace(flat, slow: true).start.cps, max(own.baseCps / 2, CPS_MIN), accuracy: 1e-12)
        // mean seconds per character: dwell mean + flight mean + the long pauses' extra
        let d = 100 * exp(0.045), f = 200 * exp(0.125), lp = (1200 * exp(0.045) - f) * 0.1
        XCTAssertEqual(own.charSeconds, (d + f + lp) / 1000, accuracy: 1e-12)
        XCTAssertEqual(own.eta(0, 10, own.start, Suffix(Array(repeating: "a", count: 10))), 10 * own.charSeconds, accuracy: 1e-9)
    }

    func testOwnPaceNeedsTheSettingAndAProfile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProfileStore(url: dir.appendingPathComponent("TypingProfile.json"))
        XCTAssertNil(OwnPace.forRun(mode: "normal", enabled: true, store: store))      // on, nothing learned yet
        try store.save(HabitFitter.fit(HabitModelTests.passageSession(), nowUtc: "t"))
        XCTAssertNil(OwnPace.forRun(mode: "normal", enabled: false, store: store))     // learned, but off
        let own = try XCTUnwrap(OwnPace.forRun(mode: "normal", enabled: true, store: store))
        XCTAssertEqual(own.profile, store.load())
        XCTAssertEqual(try XCTUnwrap(OwnPace.forRun(mode: "slow", enabled: true, store: store)).start.cps,
                       max(own.baseCps / 2, CPS_MIN), accuracy: 1e-12)
    }

    func testOwnPaceSettingIsOffByDefault() throws {
        let empty = try XCTUnwrap(UserDefaults(suiteName: "pourtype-tests-\(UUID().uuidString)"))   // read only
        XCTAssertNil(empty.object(forKey: Prefs.ownPaceKey))
        XCTAssertFalse(Prefs.ownPace(in: empty))
    }

    /// The time-left estimate stays near the mean of the gaps actually drawn (it uses the overall fit, the draws
    /// the per-bucket fits and factors).
    func testOwnPaceEtaIsNearTheDraws() {
        let profile = HabitFitter.fit(HabitModelTests.passageSession(), nowUtc: "t"), own = OwnPace(profile)
        let units = splitUnits(CalibrationPassage.text), rng = SeededRandom(7)
        var total = 0.0
        let runs = 300
        for _ in 0..<runs { for i in units.indices { total += own.timing(units, i, own.start, rng).gapSeconds } }
        let eta = own.eta(0, units.count, own.start, Suffix(units))
        XCTAssertLessThan(abs(total / Double(runs) - eta) / eta, 0.25)
    }
}
