import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

// MARK: - language

enum L {
    static let zh = (Locale.preferredLanguages.first ?? "").hasPrefix("zh")
    static var lang: String { zh ? "zh" : "en" }
    static func t(_ zhText: String, _ en: String) -> String { zh ? zhText : en }
}

// MARK: - preferences

enum Prefs {
    private static let d = UserDefaults.standard

    static func pace(_ mode: String) -> Pace {
        var p = mode == "slow" ? Pace(cps: 15, rand: 0.45) : Pace(cps: 40, rand: 0.3)
        if d.object(forKey: "pace.\(mode).cps") != nil { p.cps = d.double(forKey: "pace.\(mode).cps") }
        if d.object(forKey: "pace.\(mode).rand") != nil { p.rand = d.double(forKey: "pace.\(mode).rand") }
        p.clamp()
        return p
    }

    static func setPace(_ mode: String, _ p: Pace) {
        d.set((p.cps * 10).rounded() / 10, forKey: "pace.\(mode).cps")
        d.set((p.rand * 100).rounded() / 100, forKey: "pace.\(mode).rand")
    }

    static var historyEnabled: Bool {
        get { d.object(forKey: "history.enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "history.enabled") }
    }
    static var historyDays: Int {
        get { d.object(forKey: "history.days") as? Int ?? 90 }
        set { d.set(newValue, forKey: "history.days") }
    }
    static var keepScreenshots: Bool {
        get { d.object(forKey: "grab.keepScreenshots") as? Bool ?? true }
        set { d.set(newValue, forKey: "grab.keepScreenshots") }
    }
    /// Vision writes full-width punctuation on lines that look Chinese; put it back to
    /// half-width after plain ASCII.
    static var asciiPunct: Bool {
        get { d.object(forKey: "grab.asciiPunct") as? Bool ?? true }
        set { d.set(newValue, forKey: "grab.asciiPunct") }
    }
}

// MARK: - permissions

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func requestScreenRecording() { _ = CGRequestScreenCaptureAccess() }

    static func open(_ pane: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(u)
        }
    }
}

// MARK: - launch at login

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

// MARK: - global hotkeys (Carbon: works without any extra permission, also in the sandbox)

final class HotKeys {
    static let shared = HotKeys()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var installed = false

    private func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { HotKeys.shared.actions[id.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// false when another app already owns that combination.
    @discardableResult
    func register(_ id: UInt32, key: Int, modifiers: Int, _ action: @escaping () -> Void) -> Bool {
        install()
        if let r = refs[id] { UnregisterEventHotKey(r); refs[id] = nil }
        var ref: EventHotKeyRef?
        let hid = EventHotKeyID(signature: OSType(0x4B545950), id: id)
        let st = RegisterEventHotKey(UInt32(key), UInt32(modifiers), hid, GetApplicationEventTarget(), 0, &ref)
        guard st == noErr, let r = ref else { return false }
        refs[id] = r
        actions[id] = action
        return true
    }
}

// MARK: - toast: a small capsule at the top of the screen, gone after a moment

final class Toast {
    static let shared = Toast()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, symbol: String = "keyboard", seconds: Double = 1.8, warn: Bool = false) {
        hideWork?.cancel()
        let p = panel ?? makePanel()
        panel = p
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        let icon = NSImageView(image: NSImage(systemSymbolName: warn ? "exclamationmark.triangle.fill" : symbol,
                                              accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = warn ? .systemOrange : .secondaryLabelColor
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 16)
        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 17
        fx.layer?.masksToBounds = true
        fx.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
                                     stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: fx.topAnchor),
                                     stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor)])
        p.contentView = fx
        let size = stack.fittingSize
        let w = min(max(size.width, 120), 560), h = max(size.height, 34)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        p.setFrame(NSRect(x: v.midX - w / 2, y: v.maxY - h - 14, width: w, height: h), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 },
                                                 completionHandler: { if self?.panel === p, p.alphaValue == 0 { p.orderOut(nil) } })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return p
    }
}
