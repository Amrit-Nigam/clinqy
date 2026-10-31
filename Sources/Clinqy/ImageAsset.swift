import AppKit
import ImageIO
import CryptoKit

/// Actual image bytes, normalized before visual input or Telegram output. Never treat a URL or description as a delivered photo.
struct ImageAsset {
    let jpeg: Data
    let source: String
    let title: String
    var key: String { SHA256.hash(data: Data(source.utf8) + jpeg).map { String(format: "%02x", $0) }.joined() }
}
enum ImageRequest {
    static func wantsOutput(_ text: String) -> Bool {
        // This count is for media returned to Telegram. A WhatsApp/email attachment is a separate native goal.
        let external = text.range(of: #"(?i)\b(on|via|through|to|using)\s+(?:the\s+)?(whatsapp|imessage|messages|slack|discord|email|mail)\b"#, options: .regularExpression) != nil
        let telegram = text.range(of: #"(?i)\b(to|via|on|in)\s+telegram\b|\bback here\b"#, options: .regularExpression) != nil
        if external && !telegram { return false }
        return text.range(of: #"(?is)\b(send|share|give|show|return|deliver)\b.{0,180}\b(images?|photos?|pictures?|screenshots?|screen\s*shots?|screengrabs?)\b"#, options: .regularExpression) != nil
    }
    static func count(_ text: String) -> Int {
        guard wantsOutput(text) else { return 0 }
        let names = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10]
        guard let regex = try? NSRegularExpression(pattern: #"(?i)\b([1-9][0-9]?|one|two|three|four|five|six|seven|eight|nine|ten)\s+(?:browser\s+)?(?:tabs?|images?|photos?|pictures?|screenshots?|screen\s*shots?|screengrabs?)\b"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { return 1 }
        return min(32, Int(text[range]) ?? names[String(text[range]).lowercased()] ?? 1)
    }
}
enum ImageAssets {
    static let byteLimit = 10 * 1024 * 1024
    static func decode(_ data: Data, source: String, title: String) throws -> ImageAsset {
        guard !data.isEmpty, data.count <= byteLimit,
              let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumb = CGImageSourceCreateThumbnailAtIndex(image, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            throw failure("The source did not contain a supported image. No photo was sent.")
        }
        let rep = NSBitmapImageRep(cgImage: thumb)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.86]), jpeg.count < byteLimit else {
            throw failure("Couldn't prepare this image for delivery.")
        }
        return ImageAsset(jpeg: jpeg, source: source, title: title)
    }
    /// Fallback for authenticated/CDN/SVG images: crop only the observed, fully visible image from its owned tab.
    static func renderedCrop(_ data: Data, rect: CGRect, viewport: CGSize, source: String, title: String) throws -> ImageAsset {
        guard viewport.width > 0, viewport.height > 0,
              [rect.minX, rect.minY, rect.width, rect.height, viewport.width, viewport.height].allSatisfy(\.isFinite),
              rect.width >= 32, rect.height >= 32, rect.minX >= 0, rect.minY >= 0,
              rect.maxX <= viewport.width, rect.maxY <= viewport.height,
              let container = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(container, 0, nil) else {
            throw failure("The image isn't fully visible for a safe rendered capture. Scroll it into view and try again.")
        }
        let crop = CGRect(x: rect.minX * CGFloat(image.width) / viewport.width, y: rect.minY * CGFloat(image.height) / viewport.height,
                          width: rect.width * CGFloat(image.width) / viewport.width, height: rect.height * CGFloat(image.height) / viewport.height)
        guard let pixels = image.cropping(to: crop), let jpeg = NSBitmapImageRep(cgImage: pixels).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            throw failure("Couldn't capture the observed image.")
        }
        return try decode(jpeg, source: source, title: title + " (rendered image)")
    }
    static func authorizedLocal(_ url: URL, inputs: [URL]) -> Bool {
        let file = url.resolvingSymlinksInPath().standardizedFileURL
        if inputs.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL == file }) { return true }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [home.appendingPathComponent("Pictures/Clinqy Screenshots"), home.appendingPathComponent("Library/Application Support/Clinqy/Clinqy Screenshots")]
        return roots.contains { file.path.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path + "/") }
    }
    static func local(_ url: URL) throws -> ImageAsset {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= byteLimit else { throw failure("The image is empty or exceeds 10 MB.") }
        return try decode(Data(contentsOf: url), source: url.path, title: url.lastPathComponent)
    }
    static func remote(_ source: String, title: String, session: URLSession? = nil) async throws -> ImageAsset {
        guard let url = URL(string: source), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else {
            throw failure("Only observed HTTP(S) image sources can be downloaded.")
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        let client = session ?? URLSession(configuration: config)
        defer { if session == nil { client.invalidateAndCancel() } }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await client.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.expectedContentLength <= byteLimit else { throw failure("The image download was denied or too large. No photo was sent.") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < byteLimit else { throw failure("The image exceeds 10 MB. No photo was sent.") }
            data.append(byte)
        }
        return try decode(data, source: source, title: title)
    }
    static func failure(_ text: String) -> NSError { NSError(domain: "ClinqyImage", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
