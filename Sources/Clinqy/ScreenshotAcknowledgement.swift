import Foundation

/// File-reference vision must acknowledge this image, never a neighboring or previous file.
enum ScreenshotAcknowledgement {
    // agy 1.4.12 read_file renders images (verified with an isolated random-code PNG).
    // Tool events expose completion and path, not the image payload; require exact current image.
    static func matches(tool: String, state: String?, target: String?, current: URL?, active: Bool) -> Bool {
        guard active, ["view_file", "read_file"].contains(tool), state == "DONE", let target, let current,
              target.hasPrefix("/") else { return false }
        return URL(fileURLWithPath: target).standardizedFileURL.resolvingSymlinksInPath().path
            == current.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
