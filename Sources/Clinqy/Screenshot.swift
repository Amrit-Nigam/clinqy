import AppKit
import ScreenCaptureKit

/// Captures the target app's window and draws numbered boxes over the elements we'll offer GPT,
/// so it sees the real screen and can refer to elements by the same "e<N>" ids.
enum Screenshot {
    /// Geometry of the most recent capture, so a position on the image can be mapped back to the screen.
    nonisolated(unsafe) static var lastWindowFrame: CGRect?
    nonisolated(unsafe) static var lastImageSize: CGSize?
    /// The last annotated capture (what the model saw) and whose window it was, for click traces.
    nonisolated(unsafe) static var lastImage: CGImage?
    nonisolated(unsafe) static var lastPID: pid_t?
    /// Set when the last `annotated` capture came back blank (and nil was returned instead of an image),
    /// so the caller can tell the model why there's no screenshot rather than send a useless one.
    nonisolated(unsafe) static var lastBlank: Blankness?

    /// Longest side and byte budget for images sent to the model: bigger costs tokens and latency, not accuracy.
    static let maxSide: CGFloat = 1280
    static let maxBytes = 450_000

    /// A capture with no visual detail. All black almost always means Screen Recording permission is
    /// missing (macOS hands back empty frames instead of failing) or the window is covered/minimized.
    enum Blankness: String {
        case allBlack = "all_black", allWhite = "all_white", uniform

        var hint: String {
            switch self {
            case .allBlack: return "The screenshot came back all black: Screen Recording permission is likely missing, or the window is minimized/covered. Don't rely on the image."
            case .allWhite: return "The screenshot came back all white: the window is likely blank or still loading. Wait a moment and look again."
            case .uniform: return "The screenshot came back a single flat color with no detail: the window may be loading, covered, or on another Space."
            }
        }
    }

    /// Luminance mean/stddev on a 64×64 grayscale thumbnail; a stddev under 2 (of 255) means no detail.
    static func blankness(_ image: CGImage) -> Blankness? {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        let n = Double(pixels.count)
        let mean = pixels.reduce(0.0) { $0 + Double($1) } / n
        let std = (pixels.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / n).squareRoot()
        guard std < 2 else { return nil }
        return mean < 5 ? .allBlack : mean > 250 ? .allWhite : .uniform
    }

    /// Converts a point in the last screenshot's pixels to global screen coordinates.
    static func screenPoint(x: Double, y: Double) -> CGPoint? {
        guard let frame = lastWindowFrame, let size = lastImageSize, size.width > 0 else { return nil }
        return CGPoint(x: frame.minX + x * frame.width / size.width, y: frame.minY + y * frame.height / size.height)
    }

    /// A clean, full-resolution PNG of the app's main window (what ⌃⌘⇧4 on that window would copy).
    static func windowPNG(app: NSRunningApplication) async -> Data? {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows
                .filter({ $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { return nil }
        let config = SCStreamConfiguration()
        let scale = min(2, 2000 / window.frame.width)
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func annotated(app: NSRunningApplication, elements: [UIElementInfo], circled: Annotation? = nil) async -> String? {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows
                .filter({ $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { return nil }

        lastWindowFrame = window.frame
        lastBlank = nil
        let config = SCStreamConfiguration()
        // Long side, not width: a tall narrow window would otherwise blow past the budget.
        let scale = min(1, maxSide / max(window.frame.width, window.frame.height))
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        else { return nil }
        if let blank = blankness(image) {
            lastBlank = blank
            lastImage = nil
            return nil
        }

        let width = image.width, height = image.height
        lastImageSize = CGSize(width: width, height: height)
        lastPID = app.processIdentifier
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Element frames are global top-left points; the window frame is in the same space.
        let sx = CGFloat(width) / window.frame.width, sy = CGFloat(height) / window.frame.height
        let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx
        let font = NSFont.boldSystemFont(ofSize: 11)
        for (i, el) in elements.enumerated() {
            let local = CGRect(x: (el.frame.minX - window.frame.minX) * sx,
                               y: CGFloat(height) - (el.frame.maxY - window.frame.minY) * sy,
                               width: el.frame.width * sx, height: el.frame.height * sy)
            guard local.intersects(CGRect(x: 0, y: 0, width: width, height: height)) else { continue }
            NSColor.systemRed.withAlphaComponent(0.85).setStroke()
            let box = NSBezierPath(rect: local)
            box.lineWidth = 1.5
            box.stroke()
            let tag = NSAttributedString(string: "e\(i)", attributes: [.font: font, .foregroundColor: NSColor.white])
            let size = tag.size()
            let tagRect = CGRect(x: local.minX, y: min(local.maxY, CGFloat(height) - size.height - 2),
                                 width: size.width + 4, height: size.height + 1)
            NSColor.systemRed.setFill()
            NSBezierPath(rect: tagRect).fill()
            tag.draw(at: CGPoint(x: tagRect.minX + 2, y: tagRect.minY))
        }
        // What the user circled, drawn the way they drew it.
        if let circled, let first = circled.points.first {
            let local = { (p: CGPoint) in CGPoint(x: (p.x - window.frame.minX) * sx, y: CGFloat(height) - (p.y - window.frame.minY) * sy) }
            let loop = NSBezierPath()
            loop.move(to: local(first))
            circled.points.dropFirst().forEach { loop.line(to: local($0)) }
            loop.lineWidth = 4
            loop.lineJoinStyle = .round
            NSColor.systemYellow.setStroke()
            loop.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let annotated = ctx.makeImage() else { return nil }
        lastImage = annotated
        return budgeted(annotated)?.base64EncodedString()
    }

    /// JPEG within `maxBytes`: lower quality first, then shrink (updating `lastImageSize`, so x/y the model
    /// reads off the smaller image still map back to the right screen point).
    private static func budgeted(_ image: CGImage) -> Data? {
        var image = image
        for _ in 0..<3 {
            for quality in [0.6, 0.45, 0.3] {
                guard let jpeg = NSBitmapImageRep(cgImage: image)
                    .representation(using: .jpeg, properties: [.compressionFactor: quality]) else { return nil }
                if jpeg.count <= maxBytes { return jpeg }
            }
            guard let smaller = resized(image, by: 0.75) else { return nil }
            image = smaller
            lastImageSize = CGSize(width: image.width, height: image.height)
        }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.3])
    }

    private static func resized(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let w = Int(CGFloat(image.width) * factor), h = Int(CGFloat(image.height) * factor)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Where a run's click traces go: next to history.json, one folder per run.
    static func runFolder(_ runID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clinqy/runs/\(runID)", isDirectory: true)
    }

    /// Keeps the newest `keep` runs' click traces; older folders go (they're only for chasing a recent misclick).
    static func pruneRuns(keep: Int = 20) {
        let root = runFolder("x").deletingLastPathComponent()
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]),
              dirs.count > keep else { return }
        let date = { (u: URL) in (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        for old in dirs.sorted(by: { date($0) > date($1) }).dropFirst(keep) { try? fm.removeItem(at: old) }
    }

    /// Debug trace: a red crosshair and ring at `point` (global top-left screen coordinates) on the latest
    /// screenshot of `app`'s window, saved as runs/<runID>/step<N>.jpg. Reuses the image the model saw when
    /// it's this app's and covers the point; otherwise takes a fresh capture. Returns the file, if written.
    @discardableResult
    static func saveClickTrace(app: NSRunningApplication, point: CGPoint, step: Int, runID: String) async -> URL? {
        var image = lastImage, frame = lastWindowFrame
        if image == nil || lastPID != app.processIdentifier || frame.map({ !$0.contains(point) }) ?? true {
            guard CGPreflightScreenCaptureAccess(),
                  let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let window = content.windows
                    .filter({ $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 })
                    .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            else { return nil }
            let config = SCStreamConfiguration()
            let scale = min(1, maxSide / max(window.frame.width, window.frame.height))
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                configuration: config)
            frame = window.frame
        }
        guard let image, let frame, frame.width > 0, frame.height > 0 else { return nil }
        return await Task.detached(priority: .utility) { () -> URL? in
            let width = image.width, height = image.height
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            // Screen (top-left points) → image (bottom-left pixels).
            let x = (point.x - frame.minX) * CGFloat(width) / frame.width
            let y = CGFloat(height) - (point.y - frame.minY) * CGFloat(height) / frame.height
            let arm: CGFloat = 18, radius: CGFloat = 11
            ctx.setStrokeColor(CGColor(red: 1, green: 0.15, blue: 0.1, alpha: 1))
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            ctx.move(to: CGPoint(x: x - arm, y: y)); ctx.addLine(to: CGPoint(x: x + arm, y: y))
            ctx.move(to: CGPoint(x: x, y: y - arm)); ctx.addLine(to: CGPoint(x: x, y: y + arm))
            ctx.strokePath()
            guard let marked = ctx.makeImage(),
                  let jpeg = NSBitmapImageRep(cgImage: marked).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
            else { return nil }
            let dir = runFolder(runID)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("step\(step).jpg")
            return (try? jpeg.write(to: url)) != nil ? url : nil
        }.value
    }
}
