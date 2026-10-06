import AppKit

// Drag a box on any screen. The screens dim, the box stays clear with its size beside it;
// Esc or a click without a drag cancels. Calls back with the box in CG coordinates
// (top-left origin, points) or nil.

final class RegionPicker {
    private var windows: [NSWindow] = []
    private var done: ((CGRect?) -> Void)?
    private var previous: NSRunningApplication?
    private var monitor: Any?

    func pick(_ done: @escaping (CGRect?) -> Void) {
        self.done = done
        previous = NSWorkspace.shared.frontmostApplication
        for s in NSScreen.screens {
            let w = PickerWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.isReleasedWhenClosed = false
            w.setFrame(s.frame, display: false)
            let v = PickerView(frame: NSRect(origin: .zero, size: s.frame.size))
            v.onDone = { [weak self, weak w] r in
                guard let self, let w else { return }
                self.finish(r.map { w.convertToScreen($0) }.map(cgFrame))
            }
            w.contentView = v
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        for w in windows { w.orderFrontRegardless() }
        // the window under the pointer takes the keys (Esc)
        let mouse = NSEvent.mouseLocation
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.push()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.finish(nil); return nil }
            return e
        }
    }

    private func finish(_ rect: CGRect?) {
        guard let done else { return }
        self.done = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        NSCursor.pop()
        for w in windows { w.orderOut(nil); w.close() }
        windows = []
        // hand the focus back to whoever had it before the picker
        previous?.activate()
        done(rect.flatMap { $0.width >= 4 && $0.height >= 4 ? $0 : nil })
    }
}

private final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class PickerView: NSView {
    var onDone: ((NSRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: NSRect? {
        guard let a = start, let b = current else { return nil }
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).integral
    }

    override func mouseDown(with e: NSEvent) { start = convert(e.locationInWindow, from: nil); current = start; needsDisplay = true }
    override func mouseDragged(with e: NSEvent) { current = convert(e.locationInWindow, from: nil); needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        current = convert(e.locationInWindow, from: nil)
        onDone?(selection)
    }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { onDone?(nil) } else { super.keyDown(with: e) } }

    override func draw(_ dirty: NSRect) {
        NSColor(white: 0, alpha: 0.28).setFill()
        bounds.fill()
        guard let r = selection, r.width > 0, r.height > 0 else {
            hint()
            return
        }
        NSGraphicsContext.current?.compositingOperation = .copy
        NSColor.clear.setFill()
        r.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSColor.white.withAlphaComponent(0.95).setStroke()
        let path = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
        path.lineWidth = 1
        path.stroke()
        let label = "\(Int(r.width)) × \(Int(r.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attrs)
        let box = NSRect(x: r.maxX - size.width - 10, y: r.minY - size.height - 10, width: size.width + 10, height: size.height + 4)
        NSColor(white: 0, alpha: 0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        label.draw(at: NSPoint(x: box.minX + 5, y: box.minY + 2), withAttributes: attrs)
    }

    private func hint() {
        let text = L.t("拖出一个框来识别文字 · Esc 取消", "Drag a box around the text · Esc to cancel") as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                                    .foregroundColor: NSColor.white.withAlphaComponent(0.92)]
        let size = text.size(withAttributes: attrs)
        let box = NSRect(x: bounds.midX - size.width / 2 - 16, y: bounds.midY - size.height / 2 - 9,
                         width: size.width + 32, height: size.height + 18)
        NSColor(white: 0, alpha: 0.55).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        text.draw(at: NSPoint(x: box.minX + 16, y: box.minY + 9), withAttributes: attrs)
    }
}
