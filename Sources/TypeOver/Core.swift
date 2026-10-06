import AppKit
import Carbon

let TAG: Int64 = 0x4B545950          // eventSourceUserData on everything we post ("KTYP")
let NEWLINE_PAUSE = 0.045            // shift-return races the characters around it
let TAB_WIDTH = 4                    // a real tab would move focus out of the field
let CPS_MIN = 3.0, CPS_MAX = 150.0
let MAX_HOLD = 1800.0                // seconds; Esc ends it any time before
let KEY_ESC: Int64 = 53, KEY_LEFT: Int64 = 123, KEY_RIGHT: Int64 = 124, KEY_DOWN: Int64 = 125, KEY_UP: Int64 = 126

let DEBUG = ProcessInfo.processInfo.environment["POURTYPE_DEBUG"] != nil

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }



// MARK: - text

func prepareText(_ s: String) -> String {
    var t = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    t = t.replacingOccurrences(of: "\t", with: String(repeating: " ", count: TAB_WIDTH))
    // other control characters do odd things as keystrokes
    let kept = t.unicodeScalars.filter { $0 == "\n" || !($0.value < 0x20 || $0.value == 0x7F) }
    return String(String.UnicodeScalarView(kept))
}

/// What one keystroke carries: a grapheme cluster (an emoji with its modifiers is one),
/// split into scalars only when it is too long for one event.
func splitUnits(_ s: String) -> [String] {
    var out: [String] = []
    out.reserveCapacity(s.count)
    for ch in s {
        let u = String(ch)
        if u.utf16.count <= 16 { out.append(u) } else { for sc in u.unicodeScalars { out.append(String(sc)) } }
    }
    return out
}

// MARK: - pacing

struct Pace: Equatable {
    var cps: Double
    var rand: Double
    mutating func clamp() {
        cps = min(max(cps, CPS_MIN), CPS_MAX)
        rand = min(max(rand, 0), 1)
    }
}

let PUNCT = Set("，。！？；：、,.!?;:…")
func isPunct(_ u: String) -> Bool { u.count == 1 && PUNCT.contains(u.first!) }

func gauss() -> Double {
    let u1 = Double.random(in: Double.ulpOfOne..<1), u2 = Double.random(in: 0..<1)
    return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
}

/// Seconds from posting `u` to posting the next unit. The mean is 1/cps plus the pauses
/// below; `rand` spreads it (log-normal factor of mean 1), adds a breath after punctuation
/// and spaces and the odd hesitation. rand 0 is a metronome.
func delayAfter(_ u: String, _ p: Pace) -> Double {
    let base = 1 / p.cps, r = p.rand
    if u == "\n" { return NEWLINE_PAUSE + base }
    guard r > 0 else { return base }
    let sigma = 0.85 * r
    var d = base * exp(sigma * gauss() - sigma * sigma / 2)
    if isPunct(u) { d += base * 6 * r } else if u == " " { d += base * 1.2 * r }
    if Double.random(in: 0..<1) < 0.02 * r { d += base * Double.random(in: 8...24) * r }
    return min(max(d, 0.003), 4)
}

/// Counts from index i to the end, for the ETA.
struct Suffix {
    var punct: [Int], space: [Int], nl: [Int]
    init(_ units: [String]) {
        let n = units.count
        punct = Array(repeating: 0, count: n + 1); space = punct; nl = punct
        for i in stride(from: n - 1, through: 0, by: -1) {
            let u = units[i]
            punct[i] = punct[i + 1] + (isPunct(u) ? 1 : 0)
            space[i] = space[i + 1] + (u == " " ? 1 : 0)
            nl[i] = nl[i + 1] + (u == "\n" ? 1 : 0)
        }
    }
}

/// The expected time to type units[i...] at pace p (the mean of delayAfter, plus the
/// pause before each newline).
func etaSeconds(_ i: Int, _ n: Int, _ p: Pace, _ s: Suffix) -> Double {
    guard i < n else { return 0 }
    let base = 1 / p.cps, r = p.rand
    let rem = Double(n - i), nl = Double(s.nl[i])
    let chars = rem - nl
    return base * (rem + 6 * r * Double(s.punct[i]) + 1.2 * r * Double(s.space[i]) + 0.32 * r * r * chars)
        + nl * 2 * NEWLINE_PAUSE
}

// MARK: - keystrokes

/// Where keystrokes go. A pid sends them to that app only (CGEventPostToPid): if another app
/// takes the focus mid-run, the keys cannot reach it, however late the switch is noticed
/// (measured 2026-10-06: ~0.7 s and 21 keys while a launching app took the front).
/// nil = the system's normal route (the HID tap), for callers without a target.
var keyTarget: pid_t?

func keyEvent(_ code: CGKeyCode, _ down: Bool, flags: CGEventFlags = [], unicode: [UniChar]? = nil) {
    guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return }
    e.flags = flags
    if var u = unicode { e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u) }
    e.setIntegerValueField(.eventSourceUserData, value: TAG)
    if let pid = keyTarget { e.postToPid(pid) } else { e.post(tap: .cghidEventTap) }
}

func strike(_ code: CGKeyCode, flags: CGEventFlags = [], unicode: [UniChar]? = nil, gap: Double) {
    keyEvent(code, true, flags: flags, unicode: unicode)
    if gap > 0 { usleep(UInt32(gap * 1e6)) }
    keyEvent(code, false, flags: flags, unicode: unicode)
}

/// Types on its own thread. Every post happens under the lock and after a stop check,
/// so once stop() returns nothing more reaches the app.
final class Engine {
    let units: [String]
    private let utf16: [[UniChar]]
    private let lock = NSLock()
    private var _stop = false
    private var _index = 0
    private var _pace: Pace
    var onEnd: ((Bool) -> Void)?           // on main; true = typed everything
    /// Asked right before a keystroke (at most every 25 ms): is the target still in front?
    /// The "another app activated" notification arrives late (measured 2026-10-06: 22 keys
    /// went out after an app switch), so the typing thread checks the window server itself.
    var focusGuard: (() -> Bool)?
    var onFocusLost: (() -> Void)?         // on main
    private var lastGuard = 0.0

    init(_ units: [String], _ pace: Pace) {
        self.units = units
        utf16 = units.map { Array($0.utf16) }
        _pace = pace
    }

    var index: Int { lock.withLock { _index } }
    var pace: Pace { lock.withLock { _pace } }
    func adjust(_ f: (inout Pace) -> Void) { lock.withLock { f(&_pace); _pace.clamp() } }
    func stop() { lock.withLock { _stop = true } }

    func start(replace: Bool) {
        let t = Thread { [self] in run(replace) }
        t.qualityOfService = .userInteractive
        t.start()
    }

    private var stopped: Bool { lock.withLock { _stop } }

    private func wait(until deadline: Double) -> Bool {
        while true {
            if stopped { return false }
            let rem = deadline - now()
            if rem <= 0 { return true }
            usleep(UInt32(min(rem, 0.008) * 1e6))
        }
    }

    private func post(_ body: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _stop { return false }
        body()
        return true
    }

    private func stillFront() -> Bool {
        guard let g = focusGuard else { return true }
        let t = now()
        if t - lastGuard < 0.025 { return true }
        lastGuard = t
        return g()
    }

    private func run(_ replace: Bool) {
        let done = { (all: Bool) in DispatchQueue.main.async { self.onEnd?(all) } }
        let lost = { () -> Void in
            self.stop()
            DispatchQueue.main.async { self.onFocusLost?() }
        }
        if replace {
            guard post({ strike(0, flags: .maskCommand, gap: 0.008) }), wait(until: now() + 0.15) else { return done(false) }
        }
        var next = now()
        for i in 0..<units.count {
            guard wait(until: next) else { return done(false) }
            guard stillFront() else { lost(); return done(false) }
            let u = units[i], p = pace
            if u == "\n" {
                guard wait(until: now() + NEWLINE_PAUSE) else { return done(false) }
                guard stillFront() else { lost(); return done(false) }
                let t = now()
                guard post({ strike(36, flags: .maskShift, gap: 0.006); _index = i + 1 }) else { return done(false) }
                next = t + delayAfter(u, p)
            } else {
                let t = now(), gap = min(0.006, 0.35 / p.cps)
                guard post({ strike(0, unicode: utf16[i], gap: gap); _index = i + 1 }) else { return done(false) }
                next = t + delayAfter(u, p)
            }
        }
        done(true)
    }
}

func json(_ v: Any) -> String {
    guard JSONSerialization.isValidJSONObject([v]),
          let d = try? JSONSerialization.data(withJSONObject: [v]), let s = String(data: d, encoding: .utf8) else { return "null" }
    return String(s.dropFirst().dropLast())
}
