import Carbon

/// Timing class of a key. A unit is classed by its single UTF-16 code unit; anything longer (CJK
/// clusters, emoji, combining marks) is .other. Backspace and Enter come from their own key events.
enum KeyClass: String, Codable, CaseIterable, CodingKeyRepresentable {
    case letter, digit, space, shift, punctuation, enter, backspace, other
}

/// How two consecutive physical keys relate on a US keyboard. Flights are fitted per bucket; .unknown when
/// either key is off the map (digits, symbols, CJK, emoji).
enum DigraphBucket: String, Codable, CaseIterable, CodingKeyRepresentable {
    case sameFinger, rowJump, sameHand, alternateHands, unknown
}

/// US-ANSI key position: row 0 = QWERTY, 1 = ASDF, 2 = ZXCV, 3 = space; hand 0 left, 1 right; finger 0...3,
/// outermost to innermost, 4 = thumb. A timing heuristic only, never the typed text.
struct KeyPos: Hashable {
    let row: Int, hand: Int, finger: Int
}

enum KeyGeometry {
    static func classOf(_ unit: String) -> KeyClass {
        if unit == "\n" { return .enter }
        if unit == " " { return .space }
        let u = Array(unit.utf16)
        guard u.count == 1, let scalar = Unicode.Scalar(u[0]) else { return .other }
        switch scalar.properties.generalCategory {
        case .lowercaseLetter, .uppercaseLetter, .titlecaseLetter:
            return .letter
        case .decimalNumber:
            return .digit
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return .punctuation
        default:
            return .other
        }
    }

    /// A single upper-case letter (decides the before-capital factor).
    static func isUpperLetter(_ unit: String?) -> Bool {
        guard let unit else { return false }
        let u = Array(unit.utf16)
        guard u.count == 1, let scalar = Unicode.Scalar(u[0]) else { return false }
        return scalar.properties.generalCategory == .uppercaseLetter
    }

    // The same rows and finger numbers as the Windows port, so both platforms bucket a digraph alike.
    private static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

    private static let us: [UInt16: KeyPos] = {
        var map: [UInt16: KeyPos] = [:]
        for (row, keys) in rows.enumerated() {
            let last = keys.utf16.count - 1
            for (i, c) in keys.utf16.enumerated() {
                let hand = i <= 4 ? 0 : 1
                map[c] = KeyPos(row: row, hand: hand, finger: hand == 0 ? min(3, i) : min(3, last - i))
            }
        }
        map[0x20] = KeyPos(row: 3, hand: 0, finger: 4)   // space: its own row, thumb
        return map
    }()

    /// The position of a single ASCII letter (either case) or space; nil for anything else.
    static func posOf(_ unit: String) -> KeyPos? {
        let u = Array(unit.utf16)
        guard u.count == 1 else { return nil }
        let c = (0x41...0x5A).contains(u[0]) ? u[0] + 0x20 : u[0]
        return us[c]
    }

    /// Mac virtual key codes (Carbon kVK_ANSI_*) of the mapped keys. These name physical positions, so a key
    /// recorded in Learn my typing lands where the engine will later look up the character it types.
    static let ansiKeys: [Int: Character] = [
        kVK_ANSI_Q: "q", kVK_ANSI_W: "w", kVK_ANSI_E: "e", kVK_ANSI_R: "r", kVK_ANSI_T: "t",
        kVK_ANSI_Y: "y", kVK_ANSI_U: "u", kVK_ANSI_I: "i", kVK_ANSI_O: "o", kVK_ANSI_P: "p",
        kVK_ANSI_A: "a", kVK_ANSI_S: "s", kVK_ANSI_D: "d", kVK_ANSI_F: "f", kVK_ANSI_G: "g",
        kVK_ANSI_H: "h", kVK_ANSI_J: "j", kVK_ANSI_K: "k", kVK_ANSI_L: "l",
        kVK_ANSI_Z: "z", kVK_ANSI_X: "x", kVK_ANSI_C: "c", kVK_ANSI_V: "v", kVK_ANSI_B: "b",
        kVK_ANSI_N: "n", kVK_ANSI_M: "m", kVK_Space: " ",
    ]

    static func pos(keyCode: Int) -> KeyPos? { ansiKeys[keyCode].flatMap { posOf(String($0)) } }

    static func bucket(_ a: KeyPos?, _ b: KeyPos?) -> DigraphBucket {
        guard let a, let b else { return .unknown }
        if a.hand != b.hand { return .alternateHands }
        if a.finger == b.finger && a.row != b.row { return .sameFinger }   // one finger, two keys: the slowest
        if abs(a.row - b.row) >= 2 { return .rowJump }
        return .sameHand
    }

    static func bucketOf(_ from: String, _ to: String) -> DigraphBucket { bucket(posOf(from), posOf(to)) }

    /// The horizontally adjacent same-hand key of a letter (lower case), for the mis-hit model only.
    static func misHitNeighbour(_ unit: String) -> Character? {
        guard let pos = posOf(unit), pos.row < 3 else { return nil }
        let row = Array(rows[pos.row])
        guard let c = unit.lowercased().first, let i = row.firstIndex(of: c) else { return nil }
        for j in [i - 1, i + 1] where j >= 0 && j < row.count {
            if let n = posOf(String(row[j])), n.hand == pos.hand { return row[j] }
        }
        return nil
    }
}
