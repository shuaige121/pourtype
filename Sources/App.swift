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

        registerHotkeys()
        NotificationCenter.default.addObserver(forName: Shortcuts.changed, object: nil, queue: .main) { [weak self] _ in
            self?.registerHotkeys()
        }
        NotificationCenter.default.addObserver(forName: Shortcuts.recording, object: nil, queue: .main) { _ in
            HotKeys.shared.unregisterAll()
        }

        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:_:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        // first run (or a run interrupted by "Quit & Reopen" while granting): the guide
        if !UserDefaults.standard.bool(forKey: "onboarding.done") || !Permissions.accessibility { openWelcome() }
        if !settings.typeHotkeyOK || !settings.grabHotkeyOK {
            Toast.shared.show(L.t("快捷键被别的 App 占用，可在设置里更换，或从菜单栏使用", "A shortcut is taken by another app: change it in Settings, or use the menu bar"),
                              seconds: 4, warn: true)
        }
    }

    private func registerHotkeys() {
        let hk = HotKeys.shared
        hk.unregisterAll()
        func reg(_ a: Action, _ f: @escaping () -> Void) -> Bool {
            let sc = Shortcuts.get(a)
            return hk.register(a.hotKeyID, key: sc.keyCode, modifiers: sc.modifiers, f)
        }
        settings.typeHotkeyOK = reg(.type) { [weak self] in self?.typeClipboard(mode: "normal") }
        settings.grabHotkeyOK = reg(.grab) { [weak self] in self?.grab() }
        settings.slowHotkeyOK = reg(.slow) { [weak self] in self?.typeClipboard(mode: "slow") }
        hk.register(4, key: 47, modifiers: controlKey | optionKey | cmdKey) { [weak self] in self?.stopPlain() }
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
        let t = Shortcuts.get(.type), g = Shortcuts.get(.grab)
        item(L.t("打出剪贴板", "Type Clipboard"), t.key.count == 1 ? t.key.lowercased() : "", t.menuModifiers, #selector(typeAction), "keyboard")
        item(L.t("截图识字", "Grab Text"), g.key.count == 1 ? g.key.lowercased() : "", g.menuModifiers, #selector(grabAction), "text.viewfinder")
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
            Toast.shared.show(L.f("安全输入中（%1$@），不锁键鼠直接输入；⌃⌥⌘. 停止",
                                  "Secure Input is on (%1$@): typing without holding input. ⌃⌥⌘. stops", holder), seconds: 3, warn: true)
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
            Toast.shared.show(L.f("已输入 %1$@ 字 · %2$@ 秒", "Typed %1$@ characters in %2$@ s", "\(r.typed)", String(format: "%.1f", r.seconds)),
                              symbol: "checkmark.circle")
        } else {
            let reason = why[r.reason] ?? r.reason
            Toast.shared.show(L.f("停在 %1$@/%2$@（%3$@）", "Stopped at %1$@/%2$@ (%3$@)", "\(r.typed)", "\(r.total)", reason),
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
            Toast.shared.show(all ? L.f("已输入 %1$@ 字 · %2$@ 秒", "Typed %1$@ characters in %2$@ s", "\(units.count)", String(format: "%.1f", now() - t0))
                                  : L.f("停在 %1$@/%2$@", "Stopped at %1$@/%2$@", "\(e.index)", "\(units.count)"),
                              symbol: all ? "checkmark.circle" : "stop.circle")
        }
        e.start(replace: false)
    }

    private func stopPlain() {
        guard let e = plain else { return }
        e.stop()
        plain = nil
        Toast.shared.show(L.f("停在 %1$@/%2$@", "Stopped at %1$@/%2$@", "\(e.index)", "\(e.units.count)"), symbol: "stop.circle")
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
                    Toast.shared.show(L.f("已复制 %1$@ 字 · %2$@ 行", "Copied %1$@ characters, %2$@ lines", "\(text.count)", "\(lines)"),
                                      symbol: "text.viewfinder")
                } catch {
                    Toast.shared.show(L.f("截图识字失败：%1$@", "Grab failed: %1$@", error.localizedDescription),
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
        let receipt = L.t("收据编号 R-7731 · 2026年10月6日\n桌面台灯 ×1    S$ 39.90\n退货期限：14 天内",
                          "Receipt R-7731 · 6 Oct 2026\nDesk lamp x1    S$ 39.90\nReturns accepted within 14 days")
        let samples: [(HistoryItem.Kind, String, String, Double)] = [
            (.grab, L.t("访客 Wi-Fi：Studio-Guest · 密码见前台卡片", "Wi-Fi: Studio-Guest · password on the card at the front desk"), L.t("照片", "Photos"), 26 * 3600),
            (.typed, L.t("订单 A-20481：已申请补发，照片已附上。", "Order A-20481: replacement requested, photos attached."), L.t("邮件", "Mail"), 5 * 3600),
            (.grab, L.t("会议改到周四下午 3 点，4B 会议室，请带上第三季度的数据。", "Meeting moved to Thursday 3 pm, room 4B. Please bring the Q3 numbers."), L.t("预览", "Preview"), 3 * 3600),
            (.typed, L.t("你好，订单 A-20481 的台灯收到时底座有裂痕。\n照片已附上，麻烦补发一个，或者给我退货标签。\n谢谢！林晓",
                         "Hi, the desk lamp from order A-20481 arrived with a cracked base.\nPhotos are attached. Could you send a replacement, or a return label?\nThanks, Alex"), "Safari", 25 * 60),
        ]
        for (kind, text, app, ago) in samples {
            store.add(HistoryItem(kind: kind, text: text, date: Date().addingTimeInterval(-ago), app: app))
        }
        store.add(HistoryItem(kind: .grab, text: receipt, date: Date().addingTimeInterval(-6 * 60), app: "Safari"), png: receiptPNG(receipt))
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
        shots.append(("history", AnyView(HistoryView(store: store, onType: { _ in }, initialSelection: store.items.first?.id)),
                      NSSize(width: 860, height: 540)))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, view, size) in shots {
                // far off screen; the window server still keeps its contents, so `screencapture -l`
                // gets the real rendering (sidebars and lists do not draw through cacheDisplay)
                let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                                 styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
                w.title = name.hasPrefix("history") ? L.t("历史记录", "History") : ""
                w.appearance = NSAppearance(named: appearance)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(origin: .zero, size: size)
                w.contentView = host
                w.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(name.hasPrefix("history") ? 1.2 : 0.6))
                let file = "\(dir)/\(name)-\(appearance == .aqua ? "light" : "dark").png"
                let shot = Process()
                shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                shot.arguments = ["-x", "-o", "-l", "\(w.windowNumber)", file]
                try? shot.run(); shot.waitUntilExit()
                if shot.terminationStatus != 0 || !FileManager.default.fileExists(atPath: file),
                   let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
                }
                w.orderOut(nil)
            }
        }
        UserDefaults.standard.set(0, forKey: "onboarding.step")
        print("rendered into \(dir)")
        exit(0)
    }
}

/// A small picture of the receipt text, as a grab's screenshot would look (for renders).
func receiptPNG(_ text: String) -> Data? {
    let size = NSSize(width: 700, height: 150)
    let img = NSImage(size: size, flipped: true) { r in
        NSColor(red: 1, green: 0.973, blue: 0.925, alpha: 1).setFill()
        NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).fill()
        var y: CGFloat = 18
        for (k, line) in text.components(separatedBy: "\n").enumerated() {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: k == 0 ? 24 : 20, weight: k == 0 ? .semibold : .regular),
                                                    .foregroundColor: NSColor(red: 0.23, green: 0.18, blue: 0.12, alpha: 1)]
            (line as NSString).draw(at: NSPoint(x: 22, y: y), withAttributes: a)
            y += k == 0 ? 44 : 36
        }
        return true
    }
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}
