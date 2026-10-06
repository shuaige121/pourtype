import AppKit
import Carbon

// One run of "type this text": hold the user's keyboard and mouse at the HID level, veil
// every display except the target field, type, then give the input back. Esc stops; the
// arrow keys change speed and rhythm. One session at a time (the tap callback is global).

struct TypeResult {
    let reason: String          // done, esc, focus, display, tap_disabled, secure_input, untrusted, timeout, keys_held, cancelled
    let typed: Int
    let total: Int
    let seconds: Double
    let app: String
    let pace: Pace
    var finished: Bool { reason == "done" }
}

enum TypeStartError: Error {
    case empty, busy, secureInput(String), untrusted, noTarget, noTap
}

private weak var gSession: TypeSession?

private let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        gSession?.tapDisabled()
        return Unmanaged.passUnretained(event)
    }
    if event.getIntegerValueField(.eventSourceUserData) == TAG { return Unmanaged.passUnretained(event) }
    guard let s = gSession, s.holding else { return Unmanaged.passUnretained(event) }
    return s.userEvent(type, event) ? nil : Unmanaged.passUnretained(event)
}

final class TypeSession {
    enum Phase { case waiting, typing, draining, ending }

    /// Check everything that can be checked before anything is shown, then start.
    static func start(text: String, pace: Pace, replace: Bool, lang: String,
                      onFinish: @escaping (TypeResult) -> Void) -> Result<TypeSession, TypeStartError> {
        if gSession != nil { return .failure(.busy) }
        let units = splitUnits(prepareText(text))
        if units.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { return .failure(.empty) }
        if let holder = secureInputHolder() { return .failure(.secureInput(holder)) }
        guard AXIsProcessTrusted() else { return .failure(.untrusted) }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != getpid() else { return .failure(.noTarget) }

        let focus = readFocus(front.processIdentifier)
        let screens = NSScreen.screens.map { ScreenInfo(frame: cgFrame($0.frame), visible: cgFrame($0.visibleFrame)) }
        let mainIndex = NSScreen.main.flatMap { m in NSScreen.screens.firstIndex(of: m) } ?? 0
        let target = pickScreen(screens, focus.fieldFrame ?? focus.windowFrame, fallback: mainIndex)
        let payload: [String: Any] = [
            "units": units, "preview": false, "lang": lang,
            "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "target": ["app": front.localizedName ?? "?", "title": focus.title ?? "", "field": focus.field ?? "",
                       "icon": iconDataURL(front.icon) ?? ""],
            "state": ["i": 0, "cps": pace.cps, "rand": pace.rand, "eta": etaSeconds(0, units.count, pace, Suffix(units)),
                      "held": ["up": false, "down": false, "left": false, "right": false], "nudge": 0, "phase": "typing"],
        ]
        let session = TypeSession(units: units, pace: pace, replace: replace, front: front, focus: focus, onFinish: onFinish)
        guard session.makeTap() else { return .failure(.noTap) }
        session.overlay = Overlay(screens: screens, target: target, hole: holeFor(focus, screen: screens[target].frame),
                                  payload: payload, htmlURL: hudURL())
        gSession = session
        session.begin()
        return .success(session)
    }

    private(set) var phase = Phase.waiting
    fileprivate(set) var holding = false
    let engine: Engine
    private let suffix: Suffix
    private let replace: Bool
    private let pid: pid_t
    private let appName: String
    private let startWindow: AXUIElement?
    private let startWindowNumber: Int?
    private var overlay: Overlay!
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private let onFinish: (TypeResult) -> Void
    private var keepAlive: TypeSession?

    private var hudReady = false
    private let waitStarted = now()
    private var typingStarted = 0.0
    private var held: [Int64: Double] = [:]      // arrow keycode -> when it went down
    private var lastRamp = now()
    private var nudges = 0
    private var moveAccum = 0.0
    private var reason: String?
    private var timers: [Timer] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var lastHud = ""
    private var phaseName = "typing"
    private let axQueue = DispatchQueue(label: "typeover.ax")
    private let screenFrames = NSScreen.screens.map { $0.frame }
    private var axBusy = false

    private init(units: [String], pace: Pace, replace: Bool, front: NSRunningApplication, focus: Focus,
                 onFinish: @escaping (TypeResult) -> Void) {
        engine = Engine(units, pace)
        suffix = Suffix(units)
        self.replace = replace
        pid = front.processIdentifier
        appName = front.localizedName ?? "?"
        startWindow = focus.window
        startWindowNumber = focus.windowNumber
        self.onFinish = onFinish
    }

    // MARK: tap

    private func makeTap() -> Bool {
        let types: [UInt32] = [1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 14, 18, 19, 20, 22, 23, 24, 25, 26, 27, 29, 30, 31, 32, 34, 37]
        var mask: UInt64 = 0
        for t in types { mask |= 1 << UInt64(t) }
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: tapCallback, userInfo: nil) else { return false }
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        tap = t
        tapSource = src
        return true
    }

    private func closeTap() {
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        if let s = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        CFMachPortInvalidate(t)
        tap = nil
        tapSource = nil
    }

    /// One of the user's events while holding. true = drop it. Runs in the tap callback:
    /// flags and counters only.
    fileprivate func userEvent(_ type: CGEventType, _ e: CGEvent) -> Bool {
        let key = e.getIntegerValueField(.keyboardEventKeycode)
        let rep = e.getIntegerValueField(.keyboardEventAutorepeat) != 0
        switch phase {
        case .waiting:
            // releases of what was held when we started go through, so no key stays stuck
            switch type {
            case .keyUp, .flagsChanged, .leftMouseUp, .rightMouseUp, .otherMouseUp: return false
            case .keyDown where key == KEY_ESC && !rep: stop("esc"); return true
            case .keyDown: nudges += 1; return true
            default: return true
            }
        case .typing:
            switch type {
            case .keyDown:
                if key == KEY_ESC { if !rep { stop("esc") } }
                else if [KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT].contains(key) { if !rep { arrowDown(key) } }
                else { nudges += 1 }
            case .keyUp:
                held[key] = nil
            case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
                nudges += 1
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                moveAccum += hypot(e.getDoubleValueField(.mouseEventDeltaX), e.getDoubleValueField(.mouseEventDeltaY))
                if moveAccum > 60 { moveAccum = 0; nudges += 1 }
            default: break
            }
            return true
        case .draining, .ending:
            if type == .keyUp { held[key] = nil }
            return true
        }
    }

    fileprivate func tapDisabled() {
        // the system stopped the tap: input is reaching apps again, so typing must stop too
        guard holding else { return }
        holding = false
        stop("tap_disabled")
    }

    private func arrowDown(_ k: Int64) {
        guard held[k] == nil else { return }
        held[k] = now()
        engine.adjust { p in
            switch k {
            case KEY_UP: p.cps *= 1.1
            case KEY_DOWN: p.cps /= 1.1
            case KEY_RIGHT: p.rand += 0.05
            default: p.rand -= 0.05
            }
        }
    }

    /// Holding an arrow: after 0.22 s it ramps, speed x3.3 per second, rhythm 50 % per second.
    private func ramp() {
        let t = now(), dt = min(t - lastRamp, 0.05)
        lastRamp = t
        guard phase == .typing, !held.isEmpty else { return }
        engine.adjust { p in
            for (k, since) in held where t - since > 0.22 {
                switch k {
                case KEY_UP: p.cps *= exp(1.2 * dt)
                case KEY_DOWN: p.cps /= exp(1.2 * dt)
                case KEY_RIGHT: p.rand += 0.5 * dt
                default: p.rand -= 0.5 * dt
                }
            }
        }
    }

    // MARK: flow

    private func begin() {
        keepAlive = self
        holding = true
        CGEvent.tapEnable(tap: tap!, enable: true)
        overlay.onReady = { [weak self] in self?.hudReady = true; self?.maybeBegin() }
        overlay.show()
        every(0.03) { [weak self] in self?.waitTick() }
        every(1 / 30) { [weak self] in self?.pushHud() }
        every(1 / 60) { [weak self] in self?.ramp() }
        every(0.1) { [weak self] in self?.watchFocus() }
        every(0.25) { [weak self] in self?.watchAX() }
        every(0.25) { [weak self] in self?.watchInput() }
        once(1.2) { [weak self] in
            guard let s = self, !s.hudReady else { return }
            s.hudReady = true
            s.maybeBegin()
        }
        once(MAX_HOLD) { [weak self] in self?.stop("timeout") }
        engine.onEnd = { [weak self] all in if all { self?.stop("done") } }
        keyTarget = pid
        // Whatever owned the front window when we started must still own it before each
        // keystroke (a popover target may sit above another app's window: compare, don't assume).
        let startOwner = frontWindowOwner()
        engine.focusGuard = { frontWindowOwner() == startOwner }
        engine.onFocusLost = { [weak self] in self?.stop("focus") }

        // a display added, removed or rearranged: the veil no longer matches the screens
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in
            guard let s = self else { return }
            if NSScreen.screens.map({ $0.frame }) != s.screenFrames { s.stop("display") }
        }
        // another app coming to the front stops it at once (the 0.1 s poll is the backstop)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification) { [weak self] n in
            let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let s = self, a?.processIdentifier != s.pid, s.phase == .typing { s.stop("focus") }
        }
    }

    private func every(_ s: Double, _ f: @escaping () -> Void) {
        let t = Timer(timeInterval: s, repeats: true) { _ in f() }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    private func once(_ s: Double, _ f: @escaping () -> Void) {
        let t = Timer(timeInterval: s, repeats: false) { _ in f() }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    private func observe(_ c: NotificationCenter, _ name: Notification.Name, _ f: @escaping (Notification) -> Void) {
        observers.append((c, c.addObserver(forName: name, object: nil, queue: .main, using: f)))
    }

    private func waitTick() {
        guard phase == .waiting else { return }
        if now() - waitStarted > 0.15 { phaseName = "wait" }
        if now() - waitStarted > 4 { return stop("keys_held") }
        maybeBegin()
    }

    private func maybeBegin() {
        guard phase == .waiting, hudReady, !userHoldsInput() else { return }
        phase = .typing
        phaseName = "typing"
        typingStarted = now()
        engine.start(replace: replace)
    }

    private func watchFocus() {
        guard phase == .typing else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { stop("focus") }
    }

    /// The focused window must stay the one we started in; the field's frame moves the hole.
    private func watchAX() {
        guard phase == .typing || phase == .waiting, !axBusy else { return }
        axBusy = true
        let pid = self.pid, screen = overlay.targetFrame
        axQueue.async { [weak self] in
            let f = readFocus(pid)
            DispatchQueue.main.async {
                guard let s = self else { return }
                s.axBusy = false
                guard s.phase == .typing || s.phase == .waiting else { return }
                if let a = s.startWindow, let b = f.window, !CFEqual(a, b) { return s.stop("focus") }
                // no AX (the sandbox): the window server's frontmost window of the app must not change
                if s.startWindow == nil, let a = s.startWindowNumber, let b = f.windowNumber, a != b { return s.stop("focus") }
                if let h = holeFor(f, screen: screen) { s.overlay.setHole(h) }
            }
        }
    }

    private func watchInput() {
        guard phase == .typing || phase == .waiting else { return }
        if secureInputHolder() != nil { holding = false; stop("secure_input") }
        else if !AXIsProcessTrusted() { holding = false; stop("untrusted") }
    }

    private func pushHud() {
        guard phase != .ending else { return }
        let i = engine.index, p = engine.pace, n = engine.units.count
        let heldNow = ["up": held[KEY_UP] != nil, "down": held[KEY_DOWN] != nil,
                       "left": held[KEY_LEFT] != nil, "right": held[KEY_RIGHT] != nil]
        let state: [String: Any] = ["i": i, "cps": (p.cps * 10).rounded() / 10, "rand": (p.rand * 100).rounded() / 100,
                                    "eta": (etaSeconds(i, n, p, suffix) * 2).rounded() / 2, "held": heldNow,
                                    "nudge": nudges, "phase": phaseName]
        let s = json(state)
        guard s != lastHud else { return }
        lastHud = s
        overlay.js("hud.update(\(s))")
    }

    /// Stop typing (or finish), then give the input back: first wait until the user has let
    /// go of every key (an arrow still held would otherwise auto-repeat into the app).
    func stop(_ why: String) {
        guard phase == .waiting || phase == .typing else { return }
        engine.stop()
        reason = why
        held = [:]
        phase = .draining
        phaseName = why == "done" ? "done" : (why == "focus" ? "focus" : "stopped")
        pushHud()
        let t0 = now()
        let drain = Timer(timeInterval: 0.02, repeats: true) { [weak self] t in
            guard let s = self else { t.invalidate(); return }
            if !s.holding || !userHoldsInput() || now() - t0 > 1.5 {
                t.invalidate()
                s.release()
            }
        }
        RunLoop.main.add(drain, forMode: .common)
    }

    private func release() {
        guard phase == .draining else { return }
        phase = .ending
        holding = false
        closeTap()
        keyTarget = nil
        for t in timers { t.invalidate() }
        timers = []
        for (c, o) in observers { c.removeObserver(o) }
        observers = []
        let p = engine.pace
        let result = TypeResult(reason: reason ?? "?", typed: engine.index, total: engine.units.count,
                                seconds: typingStarted > 0 ? now() - typingStarted : 0, app: appName, pace: p)
        // a short beat so "done" / "stopped" can be read, then out
        let linger = reason == "done" ? 0.18 : (reason == "focus" ? 0.6 : 0.3)
        DispatchQueue.main.asyncAfter(deadline: .now() + linger) {
            self.overlay.dismiss {
                self.overlay.teardown()
                if gSession === self { gSession = nil }
                self.keepAlive = nil
                self.onFinish(result)
            }
        }
    }
}

func hudURL() -> URL {
    Bundle.main.url(forResource: "hud", withExtension: "html")!
}
