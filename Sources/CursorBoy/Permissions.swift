import AppKit
import ApplicationServices

/// Every macOS permission CursorBoy uses, with a way to request each and check its status.
enum Permissions {
    struct Item {
        let name: String
        let why: String
        let granted: () -> Bool
        let request: () -> Void
        let settingsURL: String
    }

    static let all: [Item] = [
        Item(name: "Accessibility",
             why: "Read buttons and fields in other apps, click and type",
             granted: { AXIsProcessTrusted() },
             request: { AXEngine.requestTrust() },
             settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
        Item(name: "Send input events",
             why: "Post mouse clicks and keystrokes",
             granted: { CGPreflightPostEventAccess() },
             request: { _ = CGRequestPostEventAccess() },
             settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
        Item(name: "Screen Recording",
             why: "See window contents and titles (for apps without accessibility info)",
             granted: { CGPreflightScreenCaptureAccess() },
             request: { _ = CGRequestScreenCaptureAccess() },
             settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
        Item(name: "Automation (System Events)",
             why: "Let agy control apps with AppleScript",
             granted: { automationStatus() == noErr },
             request: { requestAutomation() },
             settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
    ]

    static var allGranted: Bool { all.allSatisfy { $0.granted() } }

    /// Requests each missing permission in turn; macOS shows its own prompt for each.
    static func requestMissing() {
        for item in all where !item.granted() { item.request() }
    }

    private static let systemEventsID = "com.apple.systemevents"

    private static func automationStatus(askIfNeeded: Bool = false) -> OSStatus {
        // System Events must be running for the check to return a real answer.
        if NSRunningApplication.runningApplications(withBundleIdentifier: systemEventsID).isEmpty {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: systemEventsID) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: config)
                usleep(300_000)
            }
        }
        var target = AEAddressDesc()
        let status: OSStatus = systemEventsID.withCString { ptr in
            AECreateDesc(typeApplicationBundleID, ptr, strlen(ptr), &target)
            defer { AEDisposeDesc(&target) }
            return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, askIfNeeded)
        }
        return status
    }

    private static func requestAutomation() {
        DispatchQueue.global().async { _ = automationStatus(askIfNeeded: true) }
    }
}
