import AppKit
import ScreenCaptureKit
import Vision

// cmd-shift-C: drag a box, read the text in it on-device (Vision), copy it.

enum GrabError: Error { case noPermission, noDisplay, captureFailed(String), noText }

enum Grabber {
    static let languages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP"]

    /// The pixels inside `rect` (CG coordinates, points) from the display it overlaps most.
    static func capture(_ rect: CGRect) async throws -> CGImage {
        guard Permissions.screenRecording else { throw GrabError.noPermission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let best = content.displays.max { a, b in
            area(CGDisplayBounds(a.displayID).intersection(rect)) < area(CGDisplayBounds(b.displayID).intersection(rect))
        }
        guard let display = best else { throw GrabError.noDisplay }
        let bounds = CGDisplayBounds(display.displayID)
        let r = rect.intersection(bounds)
        guard r.width >= 1, r.height >= 1 else { throw GrabError.noDisplay }
        let mine = content.windows.filter { $0.owningApplication?.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingWindows: mine)
        let cfg = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        cfg.sourceRect = r.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        cfg.width = Int((r.width * scale).rounded())
        cfg.height = Int((r.height * scale).rounded())
        cfg.showsCursor = false
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        } catch {
            throw GrabError.captureFailed(error.localizedDescription)
        }
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    /// Recognised text, rows top to bottom, each row left to right.
    static func recognize(_ image: CGImage) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLanguages = languages
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        let lines: [(y: CGFloat, x: CGFloat, text: String)] = (req.results ?? []).compactMap { obs in
            guard let c = obs.topCandidates(1).first else { return nil }
            return (obs.boundingBox.origin.y, obs.boundingBox.origin.x, c.string)
        }
        return joinRows(lines)
    }

    /// Vision's origin is bottom-left: the top of the image has the highest y. Group into
    /// rows first, then read each row left to right.
    static func joinRows(_ lines: [(y: CGFloat, x: CGFloat, text: String)]) -> String {
        let sorted = lines.sorted { $0.y != $1.y ? $0.y > $1.y : $0.x < $1.x }
        var rows: [[(CGFloat, String)]] = []
        var rowY: CGFloat?
        for l in sorted {
            if let y = rowY, abs(l.y - y) < 0.012 { rows[rows.count - 1].append((l.x, l.text)) }
            else { rows.append([(l.x, l.text)]); rowY = l.y }
        }
        return rows.map { $0.sorted { $0.0 < $1.0 }.map { $0.1 }.joined(separator: " ") }.joined(separator: "\n")
    }

    static let fullToHalf: [Character: Character] = ["：": ":", "，": ",", "（": "(", "）": ")", "；": ";", "！": "!",
                                                     "？": "?", "％": "%", "＠": "@", "＃": "#", "＆": "&", "－": "-"]

    /// Vision renders punctuation full-width whenever the line looks Chinese. Put it back to
    /// half-width when the character before it is plain ASCII.
    static func asciiPunct(_ text: String) -> String {
        var out = Array(text)
        for i in out.indices {
            guard let half = fullToHalf[out[i]] else { continue }
            let before = out[..<i].last { !$0.isWhitespace }
            if let b = before, b.isASCII, b.isLetter || b.isNumber { out[i] = half }
        }
        return String(out)
    }

    static func pngThumbnail(_ image: CGImage, maxWidth: Int = 640) -> Data? {
        let w = image.width, h = image.height
        let s = min(1, Double(maxWidth) / Double(max(w, 1)))
        let tw = max(1, Int(Double(w) * s)), th = max(1, Int(Double(h) * s))
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let small = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: small).representation(using: .png, properties: [:])
    }
}
