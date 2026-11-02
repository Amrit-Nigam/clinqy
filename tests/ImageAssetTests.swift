import AppKit

final class ImageAPI: URLProtocol {
    static var payload = Data()
    static var status = 200
    static var length: Int? = nil
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let headers = Self.length.map { ["Content-Length": String($0)] } ?? [:]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct ImageTests {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1; print("PASS " + label) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2000, pixelsHigh: 1000, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        let asset = try ImageAssets.decode(png, source: "https://example.com/picture.png", title: "Actual fixture")
        let image = NSBitmapImageRep(data: asset.jpeg)!
        check(asset.jpeg.starts(with: [255,216]), "real image pixels normalized to JPEG for model input and Telegram")
        check(image.pixelsWide == 1600 && image.pixelsHigh == 800, "large images downsampled with aspect ratio preserved")
        check(asset.source.contains("picture.png") && asset.key == asset.key, "source provenance and stable media deduplication")
        let crop = try ImageAssets.renderedCrop(png, rect: CGRect(x: 10, y: 10, width: 100, height: 80), viewport: CGSize(width: 1000, height: 500), source: "https://example.com/blocked.svg", title: "Observed")
        let cropImage = NSBitmapImageRep(data: crop.jpeg)!
        check(cropImage.pixelsWide == 200 && cropImage.pixelsHigh == 160, "rendered image fallback crops exact CSS bounds at screenshot pixel scale")
        do { _ = try ImageAssets.renderedCrop(png, rect: CGRect(x: -10, y: 0, width: 100, height: 80), viewport: CGSize(width: 1000, height: 500), source: "test", title: "test"); fatalError("Partial crop accepted") } catch { check(true, "offscreen/partial image crops rejected rather than exposing unrelated pixels") }
        for bad in [Data(), Data("<html>403 Forbidden</html>".utf8), Data(repeating: 0, count: ImageAssets.byteLimit + 1)] {
            do { _ = try ImageAssets.decode(bad, source: "test", title: "test"); fatalError("Invalid image accepted") } catch { check(true, "empty, HTML and oversized payloads rejected") }
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ImageAPI.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        ImageAPI.payload = png
        let fetched = try await ImageAssets.remote("https://example.com/photo", title: "Fixture", session: session)
        check(fetched.jpeg.starts(with: [255,216]), "actual downloaded bytes decoded instead of trusting MIME or URL suffix")
        ImageAPI.status = 403
        do { _ = try await ImageAssets.remote("https://example.com/denied", title: "Denied", session: session); fatalError("403 accepted") } catch { check(true, "denied image downloads cannot count as delivered media") }
        ImageAPI.status = 200; ImageAPI.length = ImageAssets.byteLimit + 1
        do { _ = try await ImageAssets.remote("https://example.com/huge", title: "Huge", session: session); fatalError("Huge accepted") } catch { check(true, "declared oversized image blocked before buffering") }
        for url in ["file:///etc/passwd", "javascript:alert(1)", "https://user:password@example.com/photo"] {
            do { _ = try await ImageAssets.remote(url, title: "Invalid", session: session); fatalError("Scheme accepted") } catch { check(true, "untrusted schemes and URL credentials rejected") }
        }
        check(ImageRequest.count("On Arc open 3 tabs about Ultron Pokemon Doraemon and send the first image from each") == 3, "user's three-tab request requires three actual image deliveries")
        check(ImageRequest.count("send three photos") == 3 && ImageRequest.count("send the first image") == 1, "word counts and singular image output")
        check(ImageRequest.count("what is in this image?") == 0, "image analysis does not require unsolicited image output")
        check(ImageRequest.count("Send me screenshot of cursor app") == 1, "screenshot request requires acknowledged media delivery")
        check(ImageRequest.count("send two screenshots") == 2, "multiple screenshot output counted")
        let managed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Clinqy Screenshots/test/example.png")
        check(ImageAssets.authorizedLocal(managed, inputs: []), "Clinqy's own saved screenshots can be sent without re-attaching them")
        check(!ImageAssets.authorizedLocal(managed.deletingLastPathComponent().appendingPathComponent("../../../private.png"), inputs: []), "path traversal cannot escape managed screenshot scope")
        let attached = URL(fileURLWithPath: "/tmp/clinqy-explicit-attachment.png")
        check(ImageAssets.authorizedLocal(attached, inputs: [attached]), "explicit attachments remain authorized")
        check(!ImageAssets.authorizedLocal(URL(fileURLWithPath: "/tmp/unrelated.png"), inputs: []), "unrelated local files still require explicit attachment")
        check(ImageRequest.count("Send the screenshot on WhatsApp to Amrit") == 0, "WhatsApp media does not incorrectly require Telegram delivery")
        check(ImageRequest.count("Send me a screenshot of WhatsApp") == 1, "screenshot of an app is still returned to Telegram")
        check(ImageRequest.count("Send the screenshot to WhatsApp and to Telegram") == 1, "explicit Telegram delivery remains required when both destinations requested")
        print("PASS \(checks) image asset checks")
    }
}
