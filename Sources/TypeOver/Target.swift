import AppKit
import Carbon

// MARK: - the target (frontmost app, its focused window and field)

func axAttr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}

func axString(_ e: AXUIElement, _ a: String) -> String? {
    guard let s = axAttr(e, a) as? String else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

func axFrame(_ e: AXUIElement) -> CGRect? {
    guard let pv = axAttr(e, kAXPositionAttribute), let sv = axAttr(e, kAXSizeAttribute),
          CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
    return CGRect(origin: p, size: s)
}

struct Focus {
    var window: AXUIElement?
    var windowFrame: CGRect?
    var title: String?
    var fieldFrame: CGRect?
    var field: String?
    var windowNumber: Int?      // from the window server: works where AX is refused (the sandbox)
}

/// The app's frontmost ordinary window from the window server's list (front to back,
/// layer 0 only, so menus, our veil and tooltips are skipped). The sandbox refuses AX on
/// other apps; this still works there. The title needs Screen Recording.
func frontWindow(_ pid: pid_t) -> (number: Int, frame: CGRect, title: String?)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
    for w in list {
        guard (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let n = (w[kCGWindowNumber as String] as? NSNumber)?.intValue,
              let b = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: b), r.width > 40, r.height > 40 else { continue }
        let title = (w[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (n, r, title)
    }
    return nil
}

func readFocus(_ pid: pid_t) -> Focus {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.3)
    var f = Focus()
    if let w = axAttr(app, kAXFocusedWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() {
        let win = w as! AXUIElement
        f.window = win
        f.windowFrame = axFrame(win)
        f.title = axString(win, kAXTitleAttribute)
    }
    if let e = axAttr(app, kAXFocusedUIElementAttribute), CFGetTypeID(e) == AXUIElementGetTypeID() {
        let el = e as! AXUIElement
        let role = axString(el, kAXRoleAttribute) ?? ""
        if role != "AXWindow" && role != "AXWebArea" && role != "AXApplication" {
            f.fieldFrame = axFrame(el)
            f.field = axString(el, kAXPlaceholderValueAttribute) ?? axString(el, kAXTitleAttribute)
                ?? axString(el, kAXDescriptionAttribute)
            if let s = f.field, s.count > 24 { f.field = String(s.prefix(23)) + "…" }
        }
    }
    if let w = frontWindow(pid) {
        f.windowNumber = w.number
        if f.windowFrame == nil { f.windowFrame = w.frame }
        if f.title == nil { f.title = w.title }
    }
    return f
}

/// The hole in the veil: the field when its frame looks like a field, else the window.
func holeFor(_ f: Focus, screen: CGRect) -> (rect: CGRect, radius: CGFloat)? {
    if let fr = f.fieldFrame, fr.width >= 30, fr.height >= 14 {
        let area = fr.width * fr.height
        if let w = f.windowFrame {
            let inter = fr.intersection(w)
            if inter.width * inter.height >= 0.6 * area && area < 0.6 * w.width * w.height {
                return (inter.insetBy(dx: -8, dy: -6), 10)
            }
        } else if area < 0.5 * screen.width * screen.height {
            return (fr.insetBy(dx: -8, dy: -6), 10)
        }
    }
    if let w = f.windowFrame, w.width > 40, w.height > 40 { return (w, 14) }
    return nil
}

func cgFrame(_ r: NSRect) -> CGRect {
    let ph = NSScreen.screens.first?.frame.height ?? r.height
    return CGRect(x: r.minX, y: ph - r.maxY, width: r.width, height: r.height)
}

func iconDataURL(_ icon: NSImage?) -> String? {
    guard let icon = icon else { return nil }
    let px = 96
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
    return "data:image/png;base64," + png.base64EncodedString()
}

// MARK: - input checks

func secureInputHolder() -> String? {
    guard IsSecureEventInputEnabled() else { return nil }
    let d = (CGSessionCopyCurrentDictionary() as? [String: Any]) ?? [:]
    if (d["CGSSessionScreenIsLocked"] as? Bool) == true { return "锁屏界面" }
    guard let pid = (d["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value else { return "未知程序" }
    return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
}

/// A key or mouse button down right now. Caps Lock (57) reads as down while it is on.
func userHoldsInput() -> Bool {
    for b in 0..<8 where CGEventSource.buttonState(.hidSystemState, button: CGMouseButton(rawValue: UInt32(b))!) { return true }
    for k in 0..<128 where k != 57 && CGEventSource.keyState(.hidSystemState, key: CGKeyCode(k)) { return true }
    return false
}
