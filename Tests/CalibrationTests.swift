import Carbon
import XCTest
@testable import Pourtype

/// Learn my typing: the recorder, and what the saved profile can and cannot hold.
final class CalibrationTests: XCTestCase {

    /// The ANSI key code that types `c` on a US layout (Shift for capitals and ':').
    static func keyCode(_ c: Character) -> UInt16 {
        if let k = KeyGeometry.ansiKeys.first(where: { $0.value == Character(c.lowercased()) })?.key { return UInt16(k) }
        let other: [Character: Int] = ["0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
                                       "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
                                       ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, ":": kVK_ANSI_Semicolon, "!": kVK_ANSI_1]
        return UInt16(other[c]!)
    }

    /// The uneven passage session fed through the recorder as key events: `swap` changes what each key typed.
    static func recordPassage(_ swap: (Character) -> Character = { $0 }) -> CalibrationRecorder {
        var state = 20261026
        func rnd() -> Int { state = (state * 1103515245 + 12345) % 2147483648; return state }
        let rec = CalibrationRecorder()
        var t = 0.0
        for (j, c) in CalibrationPassage.text.enumerated() {
            let d = Double(50 + rnd() % 150)
            var f = Double(60 + rnd() % 400)
            if j % 17 == 16 { f += 1200 }
            let code = keyCode(c)
            rec.record(keyCode: code, characters: String(swap(c)), down: true, timeMs: t)
            rec.record(keyCode: code, characters: nil, down: false, timeMs: t + d)
            t += d + f
        }
        return rec
    }

    func testRecorderFeedsTheFitterLikeTheWindowsUnitPath() {
        let viaRecorder = HabitFitter.fit(Self.recordPassage().makeRaw(), nowUtc: "t")
        let direct = HabitFitter.fit(HabitModelTests.passageSession(withTypos: false), nowUtc: "t")
        XCTAssertEqual(viaRecorder, direct)
    }

    /// Every character the user typed is replaced by a different one of the same class and case (letters and
    /// digits rotate, punctuation rotates among its own): the saved profile is byte for byte the same, so it
    /// cannot hold anything about which characters were typed.
    func testProfileIsByteIdenticalWhenEveryCharacterIsSwapped() throws {
        func rotate(_ c: Character, in set: String) -> Character? {
            let a = Array(set)
            return a.firstIndex(of: c).map { a[($0 + 1) % a.count] }
        }
        let swap: (Character) -> Character = { c in
            rotate(c, in: "abcdefghijklmnopqrstuvwxyz") ?? rotate(c, in: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
                ?? rotate(c, in: "0123456789") ?? rotate(c, in: ",.:;!?") ?? c
        }
        let typed = Self.recordPassage(), swapped = Self.recordPassage(swap)
        var changed = 0
        for c in CalibrationPassage.text where swap(c) != c { changed += 1 }
        XCTAssertEqual(changed, CalibrationPassage.text.filter { $0 != " " }.count)   // all but the spaces
        let a = try ProfileStore.encode(HabitFitter.fit(typed.makeRaw(), nowUtc: "2026-10-27T00:00:00Z"))
        let b = try ProfileStore.encode(HabitFitter.fit(swapped.makeRaw(), nowUtc: "2026-10-27T00:00:00Z"))
        XCTAssertEqual(a, b)
        XCTAssertGreaterThan(a.count, 500)
    }

    /// The saved file holds numbers under fixed names only: no field can carry a typed character.
    func testSavedProfileHoldsNoText() throws {
        let p = HabitFitter.fit(HabitModelTests.passageSession(), nowUtc: "2026-10-27T00:00:00Z")
        let json = try JSONSerialization.jsonObject(with: ProfileStore.encode(p))
        let names: Set<String> = ["version", "createdUtc", "sampleChars", "dwell", "globalDwell", "bucketFlight", "globalFlight",
                                  "wordStartFactor", "afterPunctuationFactor", "beforeCapitalFactor", "longPauseFraction",
                                  "longPause", "typos", "dist", "n", "medianMs", "sigma", "letterProbability", "correctionLatency"]
        let allowed = names.union(KeyClass.allCases.map(\.rawValue)).union(DigraphBucket.allCases.map(\.rawValue))
        var strings: [String] = []
        func walk(_ v: Any) {
            if let d = v as? [String: Any] {
                for (k, x) in d { XCTAssertTrue(allowed.contains(k), "unexpected field \(k)"); walk(x) }
            } else if let a = v as? [Any] {
                a.forEach(walk)
            } else if let s = v as? String {
                strings.append(s)
            } else {
                XCTAssertTrue(v is NSNumber, "unexpected value \(v)")
            }
        }
        walk(json)
        XCTAssertEqual(strings, ["2026-10-27T00:00:00Z"])                  // the only text: the date it was made
    }

    func testRecorderKeepsCorrectionsAndDropsRepeats() {
        let rec = CalibrationRecorder()
        func key(_ code: Int, _ ch: String, _ down: Double, _ up: Double, repeats: Bool = false) {
            rec.record(keyCode: UInt16(code), characters: ch, down: true, timeMs: down)
            if repeats { rec.record(keyCode: UInt16(code), characters: ch, down: true, isRepeat: true, timeMs: down + 500) }
            rec.record(keyCode: UInt16(code), characters: nil, down: false, timeMs: up)
        }
        key(kVK_ANSI_A, "a", 0, 90)
        key(kVK_ANSI_B, "b", 200, 290)
        key(kVK_Delete, "\u{7F}", 500, 580)
        key(kVK_Delete, "\u{7F}", 700, 780)                                 // a second Backspace: the same correction
        key(kVK_ANSI_C, "c", 1000, 1080)                                    // closes it: 1000 - 200 ms after the wrong b
        key(kVK_Space, " ", 1200, 1280)
        key(kVK_Delete, "\u{7F}", 1400, 1480)                               // after a space: not a corrected letter
        key(kVK_ANSI_D, "d", 1600, 2600, repeats: true)                    // auto-repeat: dropped
        rec.record(keyCode: UInt16(kVK_ANSI_E), characters: nil, down: false, timeMs: 2700)   // an up with no down
        let raw = rec.makeRaw()
        XCTAssertEqual(raw.keys.map(\.cls), [.letter, .letter, .backspace, .backspace, .letter, .space, .backspace])
        XCTAssertEqual(raw.typos, [RawTypo(latencyMs: 800)])
        rec.discard()
        XCTAssertEqual(rec.count, 0)
        XCTAssertTrue(rec.makeRaw().keys.isEmpty)
    }

    func testRecorderOrdersOverlappingKeysByKeyDown() {
        let rec = CalibrationRecorder()
        rec.record(keyCode: UInt16(kVK_ANSI_T), characters: "t", down: true, timeMs: 0)
        rec.record(keyCode: UInt16(kVK_ANSI_H), characters: "h", down: true, timeMs: 60)
        rec.record(keyCode: UInt16(kVK_ANSI_H), characters: nil, down: false, timeMs: 120)   // h comes up first
        rec.record(keyCode: UInt16(kVK_ANSI_T), characters: nil, down: false, timeMs: 140)
        XCTAssertEqual(rec.makeRaw().keys.map(\.downMs), [0, 60])
    }
}
