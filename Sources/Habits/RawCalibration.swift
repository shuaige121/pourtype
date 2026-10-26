import Foundation

/// One keystroke recorded in Learn my typing. In memory only, never written. It holds the key's class, its
/// physical position (from the key code) and whether it made a capital, never the character itself.
struct RawKey: Equatable {
    var cls: KeyClass
    var pos: KeyPos?
    var capital: Bool
    var downMs: Double
    var upMs: Double

    init(cls: KeyClass, pos: KeyPos?, capital: Bool, downMs: Double, upMs: Double) {
        self.cls = cls
        self.pos = pos
        self.capital = capital
        self.downMs = downMs
        self.upMs = upMs
    }

    /// A key described by the unit it would type on a US layout (tests, and the Windows-style grapheme input).
    init(cls: KeyClass, unit: String?, downMs: Double, upMs: Double) {
        self.init(cls: cls, pos: unit.flatMap(KeyGeometry.posOf), capital: KeyGeometry.isUpperLetter(unit),
                  downMs: downMs, upMs: upMs)
    }
}

/// A correction made during Learn my typing: a letter, then Backspace. Only the latency is kept
/// (wrong key down to the corrected key down); which letters is never stored.
struct RawTypo: Equatable {
    var latencyMs: Double
}

/// The in-memory recording handed to the fitter. Never written to disk; the fitted TypingProfile is the only
/// thing that is saved.
final class RawCalibration {
    private(set) var keys: [RawKey] = []
    private(set) var typos: [RawTypo] = []

    /// Keystrokes of class letter: the denominator of the typo rate.
    var letterKeyCount: Int { keys.reduce(0) { $0 + ($1.cls == .letter ? 1 : 0) } }

    func add(_ key: RawKey) {
        // a key with no positive hold is not a fresh press
        guard key.upMs - key.downMs > 0 else { return }
        keys.append(key)
    }

    func addTypo(_ typo: RawTypo) {
        if typo.latencyMs > 0 { typos.append(typo) }
    }
}
