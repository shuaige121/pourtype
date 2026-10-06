import XCTest
@testable import Pourtype

final class CoreTests: XCTestCase {
    func testPrepareText() {
        XCTAssertEqual(prepareText("a\r\nb\rc\td"), "a\nb\nc    d")
        XCTAssertEqual(prepareText("x\u{07}y\u{7F}z\u{0C}"), "xyz")
    }

    func testUnits() {
        let u = splitUnits(prepareText("中文，emoji 👨‍👩‍👧 é\u{301}\n"))
        XCTAssertEqual(u, ["中", "文", "，", "e", "m", "o", "j", "i", " ", "👨‍👩‍👧", " ", "é\u{301}", "\n"])
    }

    func testPaceClamp() {
        var p = Pace(cps: 1000, rand: 7); p.clamp()
        XCTAssertEqual(p.cps, CPS_MAX); XCTAssertEqual(p.rand, 1)
        p = Pace(cps: 0.1, rand: -1); p.clamp()
        XCTAssertEqual(p.cps, CPS_MIN); XCTAssertEqual(p.rand, 0)
    }

    /// The ETA must be the mean of the delays actually used (Monte Carlo).
    func testEtaMatchesDelays() {
        let sample = splitUnits("这是一段测试文字，包含标点。And some English words, too!\n第二行。")
        let s = Suffix(sample)
        for pace in [Pace(cps: 40, rand: 0.3), Pace(cps: 15, rand: 0.9), Pace(cps: 120, rand: 0)] {
            let runs = 4000
            var total = 0.0
            for _ in 0..<runs {
                for x in sample { total += delayAfter(x, pace) + (x == "\n" ? NEWLINE_PAUSE : 0) }
            }
            let mean = total / Double(runs), eta = etaSeconds(0, sample.count, pace, s)
            XCTAssertLessThan(abs(mean - eta) / eta, 0.03, "cps \(pace.cps) rand \(pace.rand)")
        }
        XCTAssertEqual(etaSeconds(sample.count, sample.count, Pace(cps: 40, rand: 0.3), s), 0)
    }

    func testScreens() {
        let A = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visible: .zero)
        let B = ScreenInfo(frame: CGRect(x: 1512, y: -200, width: 2560, height: 1440), visible: .zero)
        let C = ScreenInfo(frame: CGRect(x: 0, y: -1440, width: 2560, height: 1440), visible: .zero)
        XCTAssertEqual(pickScreen([A, B], CGRect(x: 1700, y: 100, width: 400, height: 100), fallback: 0), 1)
        XCTAssertEqual(pickScreen([A, B], CGRect(x: 1300, y: 100, width: 300, height: 100), fallback: 1), 0)
        XCTAssertEqual(pickScreen([A, C], CGRect(x: 100, y: -500, width: 300, height: 80), fallback: 0), 1)
        XCTAssertEqual(pickScreen([A, B], nil, fallback: 1), 1)
        XCTAssertGreaterThan(toward(A.frame, B.frame).dx, 0.9)
        XCTAssertLessThan(toward(A.frame, C.frame).dy, -0.8)
        let span = CGRect(x: 1400, y: 100, width: 300, height: 100)
        XCTAssertEqual(holePiece(span, on: A.frame), CGRect(x: 1400, y: 100, width: 112, height: 100))
        XCTAssertNil(holePiece(span, on: C.frame))
    }

    func testOcrRowsAndPunctuation() {
        // two rows; the second row's pieces arrive right-to-left
        let lines: [(y: CGFloat, x: CGFloat, text: String)] = [(0.2, 0.5, "world"), (0.8, 0.1, "第一行"), (0.205, 0.1, "hello")]
        XCTAssertEqual(Grabber.joinRows(lines), "第一行\nhello world")
        XCTAssertEqual(Grabber.asciiPunct("Price：10，中文：好"), "Price:10,中文：好")
    }

    func testHistoryStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(dir: dir)
        store.add(HistoryItem(kind: .grab, text: "第一条 alpha", app: "Safari"), png: Data([0x89, 0x50]))
        store.add(HistoryItem(kind: .typed, text: "second beta", app: "Notes"))
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.search("ALPHA").map(\.text), ["第一条 alpha"])
        XCTAssertEqual(store.search("notes").count, 1)
        // survives a reload
        XCTAssertEqual(HistoryStore(dir: dir).items.map(\.text), ["second beta", "第一条 alpha"])
        let img = try XCTUnwrap(store.imageURL(store.items[1]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: img.path))
        store.clear()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: img.path))
    }

    func testShortcuts() {
        XCTAssertEqual(Action.type.defaultShortcut.display, "⇧⌘V")
        XCTAssertEqual(Action.slow.defaultShortcut.display, "⌃⌥⌘B")
        let key = "shortcut.grab"
        let before = UserDefaults.standard.data(forKey: key)
        defer { UserDefaults.standard.set(before, forKey: key) }
        Shortcuts.set(.grab, Shortcut(keyCode: 1, modifiers: 256 | 2048, key: "S"))   // cmdKey | optionKey
        XCTAssertEqual(Shortcuts.get(.grab).display, "⌥⌘S")
        Shortcuts.set(.grab, nil)
        XCTAssertEqual(Shortcuts.get(.grab), Action.grab.defaultShortcut)
    }
}
