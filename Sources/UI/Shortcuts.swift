import AppKit
import Carbon
import SwiftUI

// User-changeable global shortcuts. Cmd-Shift-V means "paste and match style" in many apps,
// so people must be able to move ours. Stored as Carbon key code + modifiers; shown as glyphs.

struct Shortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int          // Carbon: cmdKey | shiftKey | optionKey | controlKey
    var key: String             // what the key shows, e.g. "V"

    var display: String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey != 0 { s += "⌥" }
        if modifiers & shiftKey != 0 { s += "⇧" }
        if modifiers & cmdKey != 0 { s += "⌘" }
        return s + key
    }

    /// For NSMenuItem key equivalents.
    var menuModifiers: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & controlKey != 0 { f.insert(.control) }
        if modifiers & optionKey != 0 { f.insert(.option) }
        if modifiers & shiftKey != 0 { f.insert(.shift) }
        if modifiers & cmdKey != 0 { f.insert(.command) }
        return f
    }

    static func from(_ e: NSEvent) -> Shortcut? {
        var m = 0
        if e.modifierFlags.contains(.command) { m |= cmdKey }
        if e.modifierFlags.contains(.shift) { m |= shiftKey }
        if e.modifierFlags.contains(.option) { m |= optionKey }
        if e.modifierFlags.contains(.control) { m |= controlKey }
        // a global shortcut needs Command, Control or Option, or it would eat ordinary typing
        guard m & (cmdKey | controlKey | optionKey) != 0 else { return nil }
        let names: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                       122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10"]
        let key = names[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "?").uppercased()
        return Shortcut(keyCode: Int(e.keyCode), modifiers: m, key: key)
    }
}

enum Action: String, CaseIterable {
    case type, grab, slow

    var defaultShortcut: Shortcut {
        switch self {
        case .type: return Shortcut(keyCode: 9, modifiers: cmdKey | shiftKey, key: "V")
        case .grab: return Shortcut(keyCode: 8, modifiers: cmdKey | shiftKey, key: "C")
        case .slow: return Shortcut(keyCode: 11, modifiers: controlKey | optionKey | cmdKey, key: "B")
        }
    }

    var title: String {
        switch self {
        case .type: return L.t("打出剪贴板", "Type the clipboard")
        case .grab: return L.t("截图识字", "Grab text")
        case .slow: return L.t("慢速打出", "Type slowly")
        }
    }

    var hotKeyID: UInt32 { switch self { case .type: 1; case .grab: 2; case .slow: 3 } }
}

enum Shortcuts {
    static let changed = Notification.Name("pourtype.shortcutsChanged")
    static let recording = Notification.Name("pourtype.shortcutRecording")

    static func get(_ a: Action) -> Shortcut {
        guard let d = UserDefaults.standard.data(forKey: "shortcut.\(a.rawValue)"),
              let s = try? JSONDecoder().decode(Shortcut.self, from: d) else { return a.defaultShortcut }
        return s
    }

    static func set(_ a: Action, _ s: Shortcut?) {
        if let s, let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: "shortcut.\(a.rawValue)") }
        else { UserDefaults.standard.removeObject(forKey: "shortcut.\(a.rawValue)") }
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// Click, press the new combination; Esc cancels.
struct ShortcutRecorder: View {
    let action: Action
    let ok: Bool
    @State private var shortcut: Shortcut
    @State private var recording = false
    @State private var monitor: Any?
    @State private var refused = false

    init(action: Action, ok: Bool) {
        self.action = action
        self.ok = ok
        _shortcut = State(initialValue: Shortcuts.get(action))
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(action.title)
            Spacer()
            if !ok && !recording {
                Text(L.t("被别的 App 占用", "In use by another app")).font(.caption).foregroundStyle(.orange)
            }
            if refused {
                Text(L.t("需要带 ⌘、⌃ 或 ⌥", "Include ⌘, ⌃ or ⌥")).font(.caption).foregroundStyle(.orange)
            }
            Button(action: toggle) {
                Text(recording ? L.t("按下新快捷键…", "Press new shortcut…") : shortcut.display)
                    .font(.system(.body, design: .rounded)).monospaced()
                    .frame(minWidth: 96)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            if shortcut != action.defaultShortcut && !recording {
                Button { save(nil) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).help(L.t("恢复默认", "Restore default"))
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        refused = false
        // our own global shortcuts would swallow the keys being recorded
        NotificationCenter.default.post(name: Shortcuts.recording, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 && e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty { stop(); return nil }
            if let s = Shortcut.from(e) { save(s); stop() } else { refused = true }
            return nil
        }
    }

    private func stop() {
        let was = recording
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if was { NotificationCenter.default.post(name: Shortcuts.changed, object: nil) }
    }

    private func save(_ s: Shortcut?) {
        Shortcuts.set(action, s)
        shortcut = Shortcuts.get(action)
    }
}
