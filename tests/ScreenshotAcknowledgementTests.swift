import Foundation

@main struct ScreenshotAcknowledgementTests {
    static func main() {
        let current = URL(fileURLWithPath: "/tmp/clinqy-session-test/screen-2.jpg")
        func accepts(_ path: String?, _ state: String? = "DONE", _ tool: String = "view_file", _ active: Bool = true) -> Bool {
            ScreenshotAcknowledgement.matches(tool: tool, state: state, target: path, current: current, active: active)
        }
        precondition(accepts(current.path))
        precondition(accepts("/tmp/clinqy-session-test/./screen-2.jpg"))
        precondition(!accepts("/tmp/clinqy-session-test/screen-1.jpg"))
        precondition(!accepts("/tmp/clinqy-session-test-extra/screen-2.jpg"))
        precondition(!accepts(current.path, "ERROR"))
        precondition(!accepts(current.path, "ACTIVE"))
        precondition(!accepts(current.path, nil))
        precondition(accepts(current.path, "DONE", "read_file"))
        precondition(!accepts("/tmp/clinqy-session-test/screen-1.jpg", "DONE", "read_file"))
        precondition(!accepts(current.path, "ERROR", "read_file"))
        precondition(!accepts(current.path, "DONE", "view_content_chunk"))
        precondition(!accepts(current.path, "DONE", "view_file", false))
        precondition(!accepts(nil))
        precondition(!accepts("screen-2.jpg"))
        print("Screenshot acknowledgment: 14 checks passed")
    }
}
