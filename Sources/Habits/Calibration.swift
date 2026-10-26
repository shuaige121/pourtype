import AppKit
import Carbon

/// Records key timing inside one text view of ours for Learn my typing. It uses an AppKit local event monitor,
/// which sees only events sent to this app's own windows: no extra permission, works in the App Sandbox, and
/// nothing typed in any other app or field is seen. It only listens; every event goes on unchanged.
///
/// Kept per key, in memory only: class, physical position (from the key code), whether it made a capital,
/// down and up time. Not kept: the characters. Left out: auto-repeat, shortcuts with Command or Control,
/// modifier keys on their own, and events Pourtype posted itself.
final class CalibrationRecorder {
    private struct Down {
        let cls: KeyClass, pos: KeyPos?, capital: Bool, ms: Double
        var repeated = false
    }

    private var keys: [RawKey] = []
    private var typos: [RawTypo] = []
    private var pending: [UInt16: Down] = [:]
    private var last: (cls: KeyClass, ms: Double)?
    private var wrongDownMs: Double?       // a correction in progress: the wrong letter's down time
    private var monitor: Any?

    /// The only view whose keys are recorded (when it is the first responder of its window).
    weak var field: NSView?
    var onChange: (() -> Void)?

    /// Keystrokes recorded so far.
    var count: Int { keys.count }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
            self?.handle(e)
            return e
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        pending = [:]
    }

    /// Drops everything recorded.
    func discard() {
        keys = []
        typos = []
        pending = [:]
        last = nil
        wrongDownMs = nil
        onChange?()
    }

    private func handle(_ e: NSEvent) {
        guard let f = field, let w = f.window, e.window === w, w.firstResponder === f else { return }
        if e.cgEvent?.getIntegerValueField(.eventSourceUserData) == TAG { return }   // typed by Pourtype itself
        let down = e.type == .keyDown
        if down && !e.modifierFlags.intersection([.command, .control]).isEmpty { return }   // a shortcut
        record(keyCode: e.keyCode, characters: down ? e.characters : nil, down: down, isRepeat: down && e.isARepeat,
               timeMs: e.timestamp * 1000)
    }

    /// One key event (times in ms, monotonic). The characters only decide the class and capital flag here and
    /// are not kept.
    func record(keyCode: UInt16, characters: String?, down: Bool, isRepeat: Bool = false, timeMs: Double) {
        if !down {
            guard let d = pending.removeValue(forKey: keyCode), !d.repeated, timeMs > d.ms else { return }
            keys.append(RawKey(cls: d.cls, pos: d.pos, capital: d.capital, downMs: d.ms, upMs: timeMs))
            onChange?()
            return
        }
        if isRepeat {
            pending[keyCode]?.repeated = true   // a held key is not a fresh press: drop it at its key up
            return
        }
        let cls: KeyClass
        switch Int(keyCode) {
        case kVK_Delete: cls = .backspace
        case kVK_Return, kVK_ANSI_KeypadEnter: cls = .enter
        default: cls = KeyGeometry.classOf(characters ?? "")
        }
        // A correction: Backspace right after a letter opens it, the next key that is not Backspace closes it.
        if cls == .backspace {
            if wrongDownMs == nil, let l = last, l.cls == .letter { wrongDownMs = l.ms }
        } else if let w = wrongDownMs {
            typos.append(RawTypo(latencyMs: timeMs - w))
            wrongDownMs = nil
        }
        last = (cls, timeMs)
        pending[keyCode] = Down(cls: cls, pos: KeyGeometry.pos(keyCode: Int(keyCode)),
                                capital: KeyGeometry.isUpperLetter(characters), ms: timeMs)
    }

    /// The recording in key-down order, for the fitter.
    func makeRaw() -> RawCalibration {
        let raw = RawCalibration()
        for k in keys.enumerated().sorted(by: { ($0.element.downMs, $0.offset) < ($1.element.downMs, $1.offset) }) {
            raw.add(k.element)
        }
        for t in typos { raw.addTypo(t) }
        return raw
    }
}
