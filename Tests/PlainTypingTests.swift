import AppKit
import XCTest
@testable import Pourtype

/// The plain run (Secure Input, or no tap): the protections it keeps. Everything it reads or posts goes through a
/// fake system, so no key is ever posted.
final class PlainTypingTests: XCTestCase {
    static let target: pid_t = 4242

    final class FakeSystem {
        private let lock = NSLock()
        private var _front = PlainTypingTests.target, _owner = PlainTypingTests.target
        private var _trusted = true, _holding = false, _esc = false
        var front: pid_t { get { lock.withLock { _front } } set { lock.withLock { _front = newValue } } }
        var owner: pid_t { get { lock.withLock { _owner } } set { lock.withLock { _owner = newValue } } }
        var trusted: Bool { get { lock.withLock { _trusted } } set { lock.withLock { _trusted = newValue } } }
        var holding: Bool { get { lock.withLock { _holding } } set { lock.withLock { _holding = newValue } } }
        var esc: Bool { get { lock.withLock { _esc } } set { lock.withLock { _esc = newValue } } }
        let cap = EngineTests.Capture()
        let workspace = NotificationCenter()
        var routes: [pid_t?] = []
        var escHandler: (() -> Void)?
        var escTaken = 0, escGivenBack = 0

        func env(maxSeconds: Double = 60, holdLimit: Double = 4) -> PlainSession.Env {
            PlainSession.Env(trusted: { self.trusted }, frontApp: { self.front }, windowOwner: { self.owner },
                             holdsInput: { self.holding }, escDown: { self.esc },
                             sender: { pid in self.routes.append(pid); return self.cap.send },
                             takeEsc: { f in self.escHandler = f; self.escTaken += 1; return { self.escGivenBack += 1 } },
                             workspace: workspace, appName: { _ in "Target" }, maxSeconds: maxSeconds, holdLimit: holdLimit)
        }
    }

    private var sys = FakeSystem()
    override func setUp() { sys = FakeSystem() }

    /// Starts a run and returns its result (nil if it did not end within `timeout`).
    @discardableResult
    private func run(_ text: String, cps: Double = 150, timeout: Double = 5, env: PlainSession.Env? = nil,
                     during: ((PlainSession) -> Void)? = nil) throws -> TypeResult? {
        var result: TypeResult?
        let ended = expectation(description: "ended")
        let started = PlainSession.start(text: text, pace: Pace(cps: cps, rand: 0), own: nil, allowSelf: false,
                                         env: env ?? sys.env()) { r in result = r; ended.fulfill() }
        guard case .success(let s) = started else { XCTFail("did not start: \(started)"); return nil }
        during?(s)
        let w = XCTWaiter().wait(for: [ended], timeout: timeout)
        if w != .completed { s.stop("test-cleanup") }
        return result
    }

    /// Runs the main run loop until `cond` holds (or `timeout`).
    private func until(_ timeout: Double = 3, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }

    func testItNeedsAccessibility() {
        sys.trusted = false
        let r = PlainSession.start(text: "secret", pace: Pace(cps: 40, rand: 0), own: nil, allowSelf: false, env: sys.env()) { _ in }
        guard case .failure(.untrusted) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(sys.routes.isEmpty)
        XCTAssertEqual(sys.escTaken, 0)
    }

    func testItDoesNotTypeIntoPourtypeItself() {
        sys.front = getpid()
        let r = PlainSession.start(text: "secret", pace: Pace(cps: 40, rand: 0), own: nil, allowSelf: false, env: sys.env()) { _ in }
        guard case .failure(.noTarget) = r else { return XCTFail("\(r)") }
    }

    /// Every key goes to the target app's pid (CGEventPostToPid), never by the route that follows the focus;
    /// the keys are the engine's usual ones; Esc is given back at the end.
    func testTheKeysGoToTheTargetAppOnly() throws {
        let r = try XCTUnwrap(try run("pass word!"))
        XCTAssertEqual(r.reason, "done")
        XCTAssertEqual(r.typed, 10)
        XCTAssertEqual(sys.routes, [PlainTypingTests.target])
        XCTAssertEqual(sys.cap.events.compactMap { $0.ev.down ? $0.ev.text : nil }.joined(), "pass word!")
        XCTAssertEqual(sys.escTaken, 1)
        XCTAssertEqual(sys.escGivenBack, 1)
    }

    /// Another app's window comes to the front: the typing thread sees it before the next key and stops.
    func testItStopsWhenTheFrontWindowChangesOwner() throws {
        let r = try XCTUnwrap(try run(String(repeating: "a", count: 60), cps: 20) { _ in
            self.until { self.sys.cap.events.count >= 6 }
            self.sys.owner = 777
        })
        XCTAssertEqual(r.reason, "focus")
        XCTAssertLessThan(r.typed, 60)
        XCTAssertLessThanOrEqual(sys.cap.events.count, 2 * r.typed)
        XCTAssertEqual(sys.escGivenBack, 1)
    }

    /// The frontmost app changes (seen by the poll): stop.
    func testItStopsWhenTheFrontmostAppChanges() throws {
        let r = try XCTUnwrap(try run(String(repeating: "a", count: 60), cps: 20) { _ in
            self.until { self.sys.cap.events.count >= 6 }
            self.sys.front = 777
        })
        XCTAssertEqual(r.reason, "focus")
        XCTAssertLessThan(r.typed, 60)
    }

    /// Another app activates (the notification): stop.
    func testItStopsWhenAnotherAppActivates() throws {
        let r = try XCTUnwrap(try run(String(repeating: "a", count: 60), cps: 20) { _ in
            self.until { self.sys.cap.events.count >= 6 }
            self.sys.workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                                    userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        })
        XCTAssertEqual(r.reason, "focus")
        XCTAssertLessThan(r.typed, 60)
    }

    func testItStopsAtTheTimeLimit() throws {
        let t0 = now()
        let r = try XCTUnwrap(try run(String(repeating: "a", count: 100), cps: 10, env: sys.env(maxSeconds: 0.3)))
        XCTAssertEqual(r.reason, "timeout")
        XCTAssertLessThan(now() - t0, 1)
        XCTAssertLessThan(r.typed, 100)
    }

    func testItStopsWhenAccessibilityIsTakenAway() throws {
        let r = try XCTUnwrap(try run(String(repeating: "a", count: 60), cps: 20) { _ in
            self.until { self.sys.cap.events.count >= 4 }
            self.sys.trusted = false
        })
        XCTAssertEqual(r.reason, "untrusted")
        XCTAssertLessThan(r.typed, 60)
    }

    /// Esc (the hotkey taken for the run): stop at once; nothing reaches the app afterwards; Esc is given back.
    func testEscStopsIt() throws {
        var countAtStop = -1
        let r = try XCTUnwrap(try run(String(repeating: "a", count: 60), cps: 20) { _ in
            self.until { self.sys.cap.events.count >= 6 }
            let esc = try? XCTUnwrap(self.sys.escHandler)
            esc?()
            countAtStop = self.sys.cap.events.count
        })
        XCTAssertEqual(r.reason, "esc")
        usleep(300_000)
        XCTAssertEqual(sys.cap.events.count, countAtStop)
        XCTAssertEqual(sys.escGivenBack, 1)
    }

    /// Esc's key state is polled too, in case its hotkey does not fire.
    func testEscKeyStateAlsoStopsIt() throws {
        let r = try XCTUnwrap(try run(String(repeating: "a", count: 60), cps: 20) { _ in
            self.until { self.sys.cap.events.count >= 6 }
            self.sys.esc = true
        })
        XCTAssertEqual(r.reason, "esc")
    }

    /// The shortcut's keys are still down: nothing is typed until they are let go (or the hold limit passes).
    func testItWaitsForTheKeysToBeLetGo() throws {
        sys.holding = true
        var released = 0.0
        let r = try XCTUnwrap(try run("ok") { _ in
            self.until(0.3) { false }
            XCTAssertTrue(self.sys.cap.events.isEmpty)
            released = now()
            self.sys.holding = false
        })
        XCTAssertEqual(r.reason, "done")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(sys.cap.events.first).t, released)
        sys = FakeSystem()
        sys.holding = true
        let held = try XCTUnwrap(try run("ok", env: sys.env(holdLimit: 0.2)))
        XCTAssertEqual(held.reason, "keys_held")
        XCTAssertTrue(sys.cap.events.isEmpty)
    }
}
