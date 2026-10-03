import AppKit
import PDFKit
import ScreenCaptureKit
import Vision

/// Reads what's in front of the user, from the best source available:
/// the document file behind the window (PDF, Word, RTF, text), a PDF open in the browser,
/// and — for scans, images and anything else — text recognition (OCR) on the window itself.
enum Reader {
    /// Text of the document a window has open (its AXDocument file), if it's a readable kind.
    static func documentText(of app: NSRunningApplication) async -> (name: String, text: String)? {
        guard let url = AXEngine.documentURL(of: app) else { return nil }
        return await fileText(url).map { (url.lastPathComponent, $0) }
    }

    /// Text of a local or downloadable file: PDFs through PDFKit, Word/RTF/HTML/text through AppKit.
    static func fileText(_ url: URL) async -> String? {
        var local = url
        if !url.isFileURL {
            guard let (tmp, _) = try? await URLSession.shared.download(from: url) else { return nil }
            local = tmp
        }
        if url.pathExtension.lowercased() == "pdf" || isPDF(local) {
            guard let doc = PDFDocument(url: local) else { return nil }
            let text = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n\n")
            return clean(text)
        }
        if let attributed = try? NSAttributedString(url: local, options: [:], documentAttributes: nil) {
            return clean(attributed.string)
        }
        return (try? String(contentsOf: local, encoding: .utf8)).flatMap(clean)
    }

    /// Recognizes the text on the app's frontmost window (works on scans, images, canvases, PDFs as pictures).
    static func ocr(_ app: NSRunningApplication) async -> String? {
        guard let image = await windowImage(app) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> String? in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return clean(lines.joined(separator: "\n"))
        }.value
    }

    /// Each piece of text on the app's window with where it is on screen (global top-left points, like element
    /// frames), for clicking things the Accessibility tree doesn't show (WhatsApp's chats, canvases, custom UI).
    /// `want`, when given, is boxed on its own where a line holds more (the "Archive" in "Archive chat").
    static func textBoxes(_ app: NSRunningApplication, want: String? = nil) async -> [(text: String, rect: CGRect)]? {
        guard let (image, frame) = await windowCapture(app) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> [(text: String, rect: CGRect)] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false   // labels and names, not prose
            try? VNImageRequestHandler(cgImage: image).perform([request])
            // Vision's boxes are 0…1 with the origin at the bottom left.
            let place = { (b: CGRect) in
                CGRect(x: frame.minX + b.minX * frame.width, y: frame.minY + (1 - b.maxY) * frame.height,
                       width: b.width * frame.width, height: b.height * frame.height)
            }
            var out: [(text: String, rect: CGRect)] = []
            for case let candidate? in (request.results ?? []).map({ $0.topCandidates(1).first }) {
                let line = candidate.string
                if let want, !want.isEmpty, let range = line.range(of: want, options: [.caseInsensitive, .diacriticInsensitive]),
                   range != line.startIndex..<line.endIndex, let part = try? candidate.boundingBox(for: range) {
                    out.append((String(line[range]), place(part.boundingBox)))
                }
                if let whole = try? candidate.boundingBox(for: line.startIndex..<line.endIndex) {
                    out.append((line, place(whole.boundingBox)))
                }
            }
            return out
        }.value
    }

    private static func windowImage(_ app: NSRunningApplication) async -> CGImage? {
        await windowCapture(app)?.image
    }

    /// The app's main window as an image, with its frame on screen.
    private static func windowCapture(_ app: NSRunningApplication) async -> (image: CGImage, frame: CGRect)? {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows
                .filter({ $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { return nil }
        let config = SCStreamConfiguration()
        // Full resolution: small print (phone numbers, emails) needs every pixel.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                      configuration: config) else { return nil }
        return (image, window.frame)
    }

    private static func isPDF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return handle.readData(ofLength: 5) == Data("%PDF-".utf8)
    }

    private static func clean(_ text: String) -> String? {
        let t = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(12_000))
    }
}
