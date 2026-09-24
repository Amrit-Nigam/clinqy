import AppKit
import ScreenCaptureKit

/// Captures the target app's window and draws numbered boxes over the elements we'll offer GPT,
/// so it sees the real screen and can refer to elements by the same "e<N>" ids.
enum Screenshot {
    static func annotated(app: NSRunningApplication, elements: [UIElementInfo]) async -> String? {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows
                .filter({ $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { return nil }

        let config = SCStreamConfiguration()
        let maxWidth: CGFloat = 1280
        let scale = min(1, maxWidth / window.frame.width)
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        else { return nil }

        let width = image.width, height = image.height
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
        NSGraphicsContext.restoreGraphicsState()

        guard let annotated = ctx.makeImage(),
              let jpeg = NSBitmapImageRep(cgImage: annotated)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else { return nil }
        return jpeg.base64EncodedString()
    }
}
