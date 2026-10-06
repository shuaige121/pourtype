import AppKit
import SwiftUI
import WebKit
import Carbon

// Menu-bar app. cmd-shift-V types the clipboard behind a veil that holds the keyboard and
// mouse; cmd-shift-C reads the text in a dragged box; both land in a local history.

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        if CommandLine.arguments.contains("--probe") { Probe.run() }
        if CommandLine.arguments.contains("--hud-check") { HudCheck.run() }
        if let i = CommandLine.arguments.firstIndex(of: "--render-ui"), i + 1 < CommandLine.arguments.count {
            UIRender.run(dir: CommandLine.arguments[i + 1])
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var status: NSStatusItem!
    private var historyWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private let settings = SettingsModel()
    private var picker: RegionPicker?
    private var plain: Engine?               // the fallback typing (Secure Input), no veil
    private var busy: Bool { TypeSessionTracker.running || plain != nil || picker != nil }

    func applicationDidFinishLaunching(_ n: Notification) {
        // hosted unit tests: no menu, no hotkeys, no windows
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: nil)
        icon?.isTemplate = true
        status.button?.image = icon
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu

        let hk = HotKeys.shared
        let cmdShift = cmdKey | shiftKey, ctrlAltCmd = controlKey | optionKey | cmdKey
        settings.typeHotkeyOK = hk.register(1, key: 9, modifiers: cmdShift) { [weak self] in self?.typeClipboard(mode: "normal") }
        settings.grabHotkeyOK = hk.register(2, key: 8, modifiers: cmdShift) { [weak self] in self?.grab() }
        settings.slowHotkeyOK = hk.register(3, key: 11, modifiers: ctrlAltCmd) { [weak self] in self?.typeClipboard(mode: "slow") }
        hk.register(4, key: 47, modifiers: ctrlAltCmd) { [weak self] in self?.stopPlain() }

        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:_:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        // first run (or a run interrupted by "Quit & Reopen" while granting): the guide
        if !UserDefaults.standard.bool(forKey: "onboarding.done") || !Permissions.accessibility { openWelcome() }
        if !settings.typeHotkeyOK || !settings.grabHotkeyOK {
            Toast.shared.show(L.t("⌘⇧V 或 ⌘⇧C 被别的 App 占用，可以从菜单栏使用", "⌘⇧V or ⌘⇧C is taken by another app; use the menu bar"),
                              seconds: 4, warn: true)
        }
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ key: String, _ mods: NSEvent.ModifierFlags, _ action: Selector, _ symbol: String) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = self
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(i)
        }
        if plain != nil {
            item(L.t("停止输入", "Stop Typing"), ".", [.control, .option, .command], #selector(stopPlainAction), "stop.circle")
            menu.addItem(.separator())
        }
        item(L.t("打出剪贴板", "Type Clipboard"), "v", [.command, .shift], #selector(typeAction), "keyboard")
        item(L.t("截图识字", "Grab Text"), "c", [.command, .shift], #selector(grabAction), "text.viewfinder")
        item(L.t("历史记录…", "History…"), "", [], #selector(historyAction), "clock.arrow.circlepath")
        menu.addItem(.separator())
        item(L.t("设置…", "Settings…"), ",", [.command], #selector(settingsAction), "gearshape")
        item(L.t("使用指南…", "Getting Started…"), "", [], #selector(welcomeAction), "questionmark.circle")
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L.t("退出", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func typeAction() { afterMenuCloses { self.typeClipboard(mode: "normal") } }
    @objc private func grabAction() { afterMenuCloses { self.grab() } }
    @objc private func historyAction() { openHistory() }
    @objc private func settingsAction() { openSettings() }
    @objc private func welcomeAction() { openWelcome() }
    @objc private func stopPlainAction() { stopPlain() }

    /// The menu was in front; give the previous app its focus back before typing into it.
    private func afterMenuCloses(_ f: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: f)
    }

    // pourtype://type, pourtype://type-slow, pourtype://grab, pourtype://history (automation, tests)
    @objc private func handleURL(_ e: NSAppleEventDescriptor, _ r: NSAppleEventDescriptor) {
        guard let s = e.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let u = URL(string: s) else { return }
        switch u.host {
        case "type": typeClipboard(mode: "normal")
        case "type-slow": typeClipboard(mode: "slow")
        case "grab": grab()
        case "history": openHistory()
        case "settings": openSettings()
        case "welcome": openWelcome()
        case "status": writeStatus()
        default: break
        }
    }

    /// pourtype://status -> Application Support/<bundle id>/status.json (for scripts and tests).
    private func writeStatus() {
        let d: [String: Any] = ["accessibility": Permissions.accessibility, "screenRecording": Permissions.screenRecording,
                                "typeHotkey": settings.typeHotkeyOK, "grabHotkey": settings.grabHotkeyOK,
                                "slowHotkey": settings.slowHotkeyOK, "pid": Int(getpid()),
                                "time": ISO8601DateFormatter().string(from: Date())]
        let dir = HistoryStore.shared.dir.deletingLastPathComponent()
        try? json(d).data(using: .utf8)?.write(to: dir.appendingPathComponent("status.json"), options: .atomic)
    }

    // MARK: typing

    func typeClipboard(mode: String) {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        type(text, mode: mode)
    }

    func type(_ text: String, mode: String, replace: Bool = false) {
        guard !busy else { Toast.shared.show(L.t("正在输入中", "Already typing"), warn: true); return }
        let pace = Prefs.pace(mode)
        // the guide's practice box is ours: typing into ourselves is allowed only there
        let practicing = welcomeWindow?.isKeyWindow == true
        let started = TypeSession.start(text: text, pace: pace, replace: replace, lang: L.lang, allowSelf: practicing) { [weak self] r in
            TypeSessionTracker.running = false
            self?.finished(r, text: text, mode: mode, start: pace)
        }
        switch started {
        case .success:
            TypeSessionTracker.running = true
        case .failure(.empty):
            Toast.shared.show(L.t("剪贴板里没有文字", "The clipboard has no text"), symbol: "doc.on.clipboard")
        case .failure(.busy):
            Toast.shared.show(L.t("正在输入中", "Already typing"), warn: true)
        case .failure(.untrusted):
            Toast.shared.show(L.t("需要「辅助功能」权限才能打字", "Typing needs the Accessibility permission"), seconds: 3, warn: true)
            openSettings()
        case .failure(.noTarget):
            Toast.shared.show(L.t("先点一下要输入的地方", "Click into the field to type into first"), warn: true)
        case .failure(.noTap):
            Toast.shared.show(L.t("无法锁定键鼠，改为直接输入；⌃⌥⌘. 停止", "Cannot hold the keyboard; typing without it. ⌃⌥⌘. stops"), seconds: 3, warn: true)
            typePlain(text, pace: pace)
        case .failure(.secureInput(let holder)):
            Toast.shared.show(L.t("安全输入中（\(holder)），不锁键鼠直接输入；⌃⌥⌘. 停止",
                                  "Secure Input is on (\(holder)): typing without holding input. ⌃⌥⌘. stops"), seconds: 3, warn: true)
            typePlain(text, pace: pace)
        }
    }

    private func finished(_ r: TypeResult, text: String, mode: String, start: Pace) {
        if r.pace != start { Prefs.setPace(mode, r.pace) }
        let why: [String: String] = ["esc": "Esc", "focus": L.t("焦点变了", "focus moved"), "display": L.t("显示器有变化", "displays changed"),
                                     "secure_input": L.t("进入了安全输入", "Secure Input turned on"), "tap_disabled": L.t("系统停用了拦截", "the system stopped the hold"),
                                     "timeout": L.t("超时", "time limit"), "untrusted": L.t("权限被收回", "permission revoked"),
                                     "keys_held": L.t("按键没有松开", "keys were held down")]
        if r.finished {
            Toast.shared.show(L.t("已输入 \(r.typed) 字 · \(String(format: "%.1f", r.seconds)) 秒", "Typed \(r.typed) characters in \(String(format: "%.1f", r.seconds)) s"),
                              symbol: "checkmark.circle")
        } else {
            let reason = why[r.reason] ?? r.reason
            Toast.shared.show(L.t("停在 \(r.typed)/\(r.total)（\(reason)）", "Stopped at \(r.typed)/\(r.total) (\(reason))"),
                              seconds: 2.6, warn: r.reason != "esc")
        }
        if r.typed > 0 {
            HistoryStore.shared.add(HistoryItem(kind: .typed, text: text, app: r.app,
                                                outcome: r.finished ? nil : "\(r.reason) \(r.typed)/\(r.total)"))
        }
    }

    /// Secure Input (a password field) hides the keyboard from every tap, so it cannot be
    /// held: type without the veil; the menu and ctrl-alt-cmd-. stop it.
    private func typePlain(_ text: String, pace: Pace) {
        let units = splitUnits(prepareText(text))
        let e = Engine(units, pace)
        plain = e
        let t0 = now()
        e.onEnd = { [weak self] all in
            guard let self else { return }
            self.plain = nil
            Toast.shared.show(all ? L.t("已输入 \(units.count) 字 · \(String(format: "%.1f", now() - t0)) 秒", "Typed \(units.count) characters")
                                  : L.t("停在 \(e.index)/\(units.count)", "Stopped at \(e.index)/\(units.count)"),
                              symbol: all ? "checkmark.circle" : "stop.circle")
        }
        e.start(replace: false)
    }

    private func stopPlain() {
        guard let e = plain else { return }
        e.stop()
        plain = nil
        Toast.shared.show(L.t("停在 \(e.index)/\(e.units.count)", "Stopped at \(e.index)/\(e.units.count)"), symbol: "stop.circle")
    }

    // MARK: grabbing

    func grab() {
        guard !busy else { return }
        guard Permissions.screenRecording else {
            Permissions.requestScreenRecording()
            Toast.shared.show(L.t("需要「屏幕录制」权限才能截图识字", "Grab Text needs the Screen Recording permission"), seconds: 3, warn: true)
            openSettings()
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName
        let p = RegionPicker()
        picker = p
        p.pick { [weak self] rect in
            self?.picker = nil
            guard let rect else { return }
            Task { @MainActor in
                do {
                    // let the picker's windows leave the screen before the capture
                    try await Task.sleep(nanoseconds: 120_000_000)
                    let img = try await Grabber.capture(rect)
                    var text = try Grabber.recognize(img).trimmingCharacters(in: .whitespacesAndNewlines)
                    if Prefs.asciiPunct { text = Grabber.asciiPunct(text) }
                    guard !text.isEmpty else {
                        Toast.shared.show(L.t("这块区域里没有找到文字", "No text found there"), symbol: "text.viewfinder")
                        return
                    }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    HistoryStore.shared.add(HistoryItem(kind: .grab, text: text, app: front), png: Grabber.pngThumbnail(img))
                    let lines = text.components(separatedBy: "\n").count
                    Toast.shared.show(L.t("已复制 \(text.count) 字 · \(lines) 行", "Copied \(text.count) characters, \(lines) lines"),
                                      symbol: "text.viewfinder")
                } catch {
                    Toast.shared.show(L.t("截图识字失败：\(error.localizedDescription)", "Grab failed: \(error.localizedDescription)"),
                                      seconds: 3, warn: true)
                }
            }
        }
    }

    // MARK: windows

    func openHistory() {
        if historyWindow == nil {
            let view = HistoryView(store: .shared) { [weak self] text in self?.typeFromHistory(text) }
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = L.t("历史记录", "History")
            w.setContentSize(NSSize(width: 820, height: 520))
            w.isReleasedWhenClosed = false
            w.center()
            historyWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    /// Hide our window so the app the user was in comes back, then type into it.
    private func typeFromHistory(_ text: String) {
        historyWindow?.orderOut(nil)
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.type(text, mode: "normal") }
    }

    func openWelcome() {
        if welcomeWindow == nil {
            let model = OnboardingModel()
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 540),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: OnboardingView(model: model))
            model.onFinish = { [weak self, weak w] in
                w?.close()
                self?.welcomeWindow = nil
                Toast.shared.show(L.t("Pourtype 在菜单栏里，随时可用", "Pourtype is in the menu bar, ready"), symbol: "checkmark.circle")
            }
            w.center()
            welcomeWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindow?.makeKeyAndOrderFront(nil)
    }

    func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: settings)))
            w.title = L.t("设置", "Settings")
            w.styleMask.remove(.resizable)
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settings.refresh()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

enum TypeSessionTracker { static var running = false }

/// `Pourtype --probe`: what this build may do here (sandbox, permissions, event taps), then exit.
/// Creates taps disabled and destroys them at once; never holds input.
enum Probe {
    static func run() -> Never {
        func tap(_ loc: CGEventTapLocation, _ opt: CGEventTapOptions) -> Bool {
            guard let t = CGEvent.tapCreate(tap: loc, place: .headInsertEventTap, options: opt,
                                            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                                            callback: { _, _, e, _ in Unmanaged.passUnretained(e) }, userInfo: nil) else { return false }
            CGEvent.tapEnable(tap: t, enable: false)
            CFMachPortInvalidate(t)
            return true
        }
        var focusedWindow = "n/a"
        if let front = NSWorkspace.shared.frontmostApplication {
            var v: CFTypeRef?
            let st = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(front.processIdentifier),
                                                   kAXFocusedWindowAttribute as CFString, &v)
            focusedWindow = "\(front.localizedName ?? "?"): \(st.rawValue)"
        }
        let fw = NSWorkspace.shared.frontmostApplication.flatMap { frontWindow($0.processIdentifier) }
        let d: [String: Any] = [
            "sandboxed": ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
            "accessibility": AXIsProcessTrusted(),
            "postEvent": CGPreflightPostEventAccess(), "listenEvent": CGPreflightListenEventAccess(),
            "screenCapture": CGPreflightScreenCaptureAccess(),
            "tapHidActive": tap(.cghidEventTap, .defaultTap), "tapSessionActive": tap(.cgSessionEventTap, .defaultTap),
            "tapSessionListen": tap(.cgSessionEventTap, .listenOnly), "axFocusedWindow": focusedWindow,
            "frontWindowFromWindowServer": fw.map { "#\($0.number) \(Int($0.frame.width))x\(Int($0.frame.height)) title:\($0.title != nil)" } ?? "none",
        ]
        print(json(d))
        exit(0)
    }
}

/// `Pourtype --hud-check`: load the HUD in an offscreen web view and report whether its script
/// ran (it posts "loaded"). Settles whether the sandboxed build can show the HUD.
final class HudCheck: NSObject, WKScriptMessageHandler {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let c = HudCheck()
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(c, name: "hud")
        let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300), styleMask: .borderless,
                         backing: .buffered, defer: false)
        let wv = WKWebView(frame: w.contentLayoutRect, configuration: cfg)
        w.contentView = wv
        w.orderFrontRegardless()
        wv.loadFileURL(hudURL(), allowingReadAccessTo: hudURL().deletingLastPathComponent())
        Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
            print(json(["hud": "timeout", "sandboxed": ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil]))
            exit(1)
        }
        app.run()
        exit(1)
    }
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        print(json(["hud": "loaded", "message": "\(m.body)",
                    "sandboxed": ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil]))
        exit(0)
    }
}

/// `Pourtype --render-ui DIR`: draw the windows offscreen into PNGs (light and dark) for design
/// review, without showing anything. POURTYPE_LANG=en|zh picks the language.
@MainActor enum UIRender {
    static func run(dir: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pourtype-render-\(getpid())")
        let store = HistoryStore(dir: tmp)
        for (k, t) in [("grab", L.t("收据编号 R-7731 · 2026年10月6日\n桌面台灯 ×1    S$ 39.90", "Receipt R-7731 · 6 Oct 2026\nDesk lamp x1    S$ 39.90")),
                       ("typed", L.t("你好，订单 A-20481 的台灯收到时底座有裂痕。", "Hi, the desk lamp from order A-20481 arrived with a cracked base.")),
                       ("grab", L.t("会议改到周四下午 3 点，4B 会议室。", "Meeting moved to Thursday 3 pm, room 4B."))] {
            store.add(HistoryItem(kind: k == "grab" ? .grab : .typed, text: t, app: "Safari"))
        }
        var shots: [(String, AnyView, NSSize)] = []
        for step in 0...3 {
            let m = OnboardingModel()
            m.freeze(accessibility: false, screenRecording: false)
            m.step = step
            shots.append(("welcome-\(step)", AnyView(OnboardingView(model: m)), NSSize(width: 680, height: 540)))
            if step == 3 {
                let done = OnboardingModel()
                done.freeze(accessibility: true, screenRecording: true)
                done.step = 3
                done.practice = done.sample
                shots.append(("welcome-3-done", AnyView(OnboardingView(model: done)), NSSize(width: 680, height: 540)))
            }
        }
        shots.append(("settings", AnyView(SettingsView(model: SettingsModel())), NSSize(width: 520, height: 760)))
        shots.append(("history", AnyView(HistoryView(store: store, onType: { _ in })), NSSize(width: 820, height: 520)))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, view, size) in shots {
                let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                                 styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                w.appearance = NSAppearance(named: appearance)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(origin: .zero, size: size)
                w.contentView = host
                w.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                let file = "\(dir)/\(name)-\(appearance == .aqua ? "light" : "dark").png"
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
                w.orderOut(nil)
            }
        }
        UserDefaults.standard.set(0, forKey: "onboarding.step")
        print("rendered into \(dir)")
        exit(0)
    }
}
