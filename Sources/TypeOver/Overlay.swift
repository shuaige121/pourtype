import AppKit
import WebKit

// MARK: - the veil
//
// One window per screen, each frosted with its own WKWebView on top. The target's screen
// (the one the field overlaps most) gets the full card and the aurora rim; every other
// screen gets a small card that points toward it, so a glance at any screen says where
// the typing goes and how to stop it. A window spanning screens is cut out on each.

struct ScreenInfo {
    var frame: CGRect          // CG coordinates (top-left origin, points)
    var visible: CGRect        // without menu bar and Dock, CG coordinates
}

/// The screen a rect is on: the one it overlaps most; no rect (or no overlap): `fallback`.
func pickScreen(_ screens: [ScreenInfo], _ r: CGRect?, fallback: Int) -> Int {
    guard let r = r else { return fallback }
    var best = fallback, bestArea: CGFloat = 0
    for (k, s) in screens.enumerated() {
        let i = s.frame.intersection(r)
        let a = i.isNull ? 0 : i.width * i.height
        if a > bestArea { best = k; bestArea = a }
    }
    return best
}

/// Unit vector from one screen's centre toward another's (x right, y down, as in CSS).
func toward(_ from: CGRect, _ to: CGRect) -> CGVector {
    let dx = to.midX - from.midX, dy = to.midY - from.midY, d = hypot(dx, dy)
    return d < 1 ? CGVector(dx: 0, dy: 0) : CGVector(dx: dx / d, dy: dy / d)
}

/// The part of the hole that falls on a screen, or nil.
func holePiece(_ hole: CGRect?, on screen: CGRect) -> CGRect? {
    guard let h = hole else { return nil }
    let i = h.intersection(screen)
    return (i.isNull || i.width < 1 || i.height < 1) ? nil : i
}

final class Pane {
    let window: NSWindow
    let frost: NSVisualEffectView?
    let web: WKWebView
    let screen: ScreenInfo
    let isTarget: Bool
    var loaded = false
    init(window: NSWindow, frost: NSVisualEffectView?, web: WKWebView, screen: ScreenInfo, isTarget: Bool) {
        self.window = window; self.frost = frost; self.web = web; self.screen = screen; self.isTarget = isTarget
    }
    /// Screen-local, top-left origin (CSS pixels = points).
    func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
}

final class Overlay: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private(set) var panes: [Pane] = []
    private var payload: [String: Any]
    private var hole: (rect: CGRect, radius: CGFloat)?
    private var lastHole: CGRect?
    var onReady: (() -> Void)?
    private var readyFired = false
    var target: Pane { panes.first(where: { $0.isTarget }) ?? panes[0] }
    var targetFrame: CGRect { target.screen.frame }
    var windows: [NSWindow] { panes.map { $0.window } }

    /// `offscreen`: one pane of that size far off screen, for snapshots (no frost).
    init(screens: [ScreenInfo], target: Int, hole: (rect: CGRect, radius: CGFloat)?, payload: [String: Any],
         htmlURL: URL, offscreen: Bool = false, role: String? = nil, appearance: NSAppearance? = nil) {
        self.payload = payload
        self.hole = hole
        roleOverride = role
        super.init()
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        for (k, s) in screens.enumerated() {
            let isTarget = k == target
            let size = s.frame.size
            let frame = offscreen ? NSRect(x: -20000, y: -20000, width: size.width, height: size.height)
                                  : NSRect(x: s.frame.minX, y: primaryH - s.frame.maxY, width: size.width, height: size.height)
            let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.isReleasedWhenClosed = false
            w.alphaValue = 0
            w.setFrame(frame, display: false)
            if let a = appearance { w.appearance = a }
            let root = NSView(frame: NSRect(origin: .zero, size: size))
            root.wantsLayer = true
            var fx: NSVisualEffectView?
            if !offscreen {
                let v = NSVisualEffectView(frame: root.bounds)
                v.material = .fullScreenUI
                v.blendingMode = .behindWindow
                v.state = .active                    // never key, so it would show the inactive grey
                v.autoresizingMask = [.width, .height]
                root.addSubview(v)
                fx = v
            }
            let cfg = WKWebViewConfiguration()
            cfg.userContentController.add(self, name: "hud")
            let wv = WKWebView(frame: root.bounds, configuration: cfg)
            wv.setValue(false, forKey: "drawsBackground")
            wv.autoresizingMask = [.width, .height]
            wv.navigationDelegate = self
            if let a = appearance { wv.appearance = a }
            root.addSubview(wv)
            w.contentView = root
            let pane = Pane(window: w, frost: fx, web: wv, screen: s, isTarget: isTarget)
            panes.append(pane)
            wv.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }
        setHole(hole)
    }
    private let roleOverride: String?

    private func paneFor(_ wv: WKWebView?) -> Pane? { panes.first(where: { $0.web === wv }) }

    private func holeJSON(_ p: Pane) -> Any {
        guard let h = hole, let piece = holePiece(h.rect, on: p.screen.frame) else { return NSNull() }
        let l = p.local(piece)
        return ["x": l.minX, "y": l.minY, "w": l.width, "h": l.height, "r": h.radius]
    }

    private func panePayload(_ p: Pane) -> [String: Any] {
        var d = payload
        let v = toward(p.screen.frame, targetFrame), vis = p.local(p.screen.visible)
        d["role"] = roleOverride ?? (p.isTarget ? "main" : "remote")
        d["str"] = hudStrings()
        d["toward"] = ["dx": v.dx, "dy": v.dy]
        d["screen"] = ["w": p.screen.frame.width, "h": p.screen.frame.height]
        d["safe"] = ["x": vis.minX, "y": vis.minY, "w": vis.width, "h": vis.height]
        d["hole"] = holeJSON(p)
        return d
    }

    func setHole(_ h: (rect: CGRect, radius: CGFloat)?) {
        if let a = lastHole, let b = h?.rect,
           abs(a.minX - b.minX) < 2, abs(a.minY - b.minY) < 2, abs(a.width - b.width) < 2, abs(a.height - b.height) < 2 { return }
        lastHole = h?.rect
        hole = h
        for p in panes {
            if let fx = p.frost {
                let size = p.screen.frame.size
                let l = holePiece(h?.rect, on: p.screen.frame).map { p.local($0) }, radius = h?.radius ?? 0
                fx.maskImage = NSImage(size: size, flipped: true) { r in
                    NSColor.black.setFill()
                    r.fill()
                    if let c = l {
                        NSGraphicsContext.current?.compositingOperation = .copy
                        NSColor.clear.setFill()
                        NSBezierPath(roundedRect: c, xRadius: radius, yRadius: radius).fill()
                    }
                    return true
                }
            }
            if p.loaded { js(p, "hud.hole(\(json(holeJSON(p))))") }
        }
    }

    func js(_ p: Pane, _ s: String) {
        p.web.evaluateJavaScript(s) { _, err in
            if let e = err, DEBUG { FileHandle.standardError.write("js error: \(e) in \(s.prefix(80))\n".data(using: .utf8)!) }
        }
    }

    /// To every screen's HUD.
    func js(_ s: String) { for p in panes where p.loaded { js(p, s) } }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if DEBUG { FileHandle.standardError.write("nav fail: \(error)\n".data(using: .utf8)!) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if DEBUG { FileHandle.standardError.write("nav fail: \(error)\n".data(using: .utf8)!) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let p = paneFor(webView) else { return }
        p.loaded = true
        js(p, "hud.init(\(json(panePayload(p))))")
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let d = m.body as? [String: Any], d["type"] as? String == "ready",
              paneFor(m.webView)?.isTarget == true, !readyFired else { return }
        readyFired = true
        onReady?()
    }

    func show() {
        for w in windows { w.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            for w in windows { w.animator().alphaValue = 1 }
        }
    }

    /// Break the WKUserContentController -> self cycle and let the windows and web views go.
    func teardown() {
        for p in panes {
            p.web.configuration.userContentController.removeScriptMessageHandler(forName: "hud")
            p.web.navigationDelegate = nil
            p.web.stopLoading()
            p.window.contentView = nil
            p.window.close()
        }
        panes = []
        onReady = nil
    }

    func dismiss(_ then: @escaping () -> Void) {
        js("hud.out()")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1)
            for w in windows { w.animator().alphaValue = 0 }
        }, completionHandler: {
            for w in self.windows { w.orderOut(nil) }
            then()
        })
    }
}

/// The HUD's words, from the same (zh-Hans, en) + translation tables as the rest of the app.
func hudStrings() -> [String: String] {
    [
        "typingInto": L.t("正在输入到", "Typing into"),
        "remote": L.t("正在另一块屏幕上输入到", "Typing on another display into"),
        "remaining": L.t("预计剩余", "Remaining"),
        "speed": L.t("速度", "Speed"),
        "cps": L.t("字/秒", "chars/s"),
        "rhythm": L.t("节奏", "Rhythm"),
        "steady": L.t("平稳", "Steady"),
        "random": L.t("随机", "Random"),
        "stop": L.t("停止", "Stop"),
        "sec": L.t("秒", "s"),
        "min": L.t("分", "m"),
        "chars": L.t("字", "chars"),
        "wait": L.t("松开按键后开始", "Starts when you let go"),
        "done": L.t("已完成", "Done"),
        "stopped": L.t("已停止", "Stopped"),
        "focus": L.t("焦点变了，已停止", "Focus moved, stopped"),
    ]
}
