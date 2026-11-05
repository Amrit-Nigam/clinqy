import AppKit
import Foundation

// Passive measurement only: no event tap, input posting, clipboard content, window titles, or screenshots.
// Counts changes while the test runs; these are observations, not attribution to the agent when a user is active.
guard CommandLine.arguments.count == 3 else { exit(2) }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let stop = URL(fileURLWithPath: CommandLine.arguments[2])
let ready = output.appendingPathExtension("ready")
let start = ProcessInfo.processInfo.systemUptime
var lastPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
var lastPointer = CGEvent(source: nil)?.location
var lastClipboard = NSPasteboard.general.changeCount
var frontmostChanges = 0, pointerSamplesChanged = 0, clipboardChanges = 0, samples = 0
// Screen Recording is preflighted only; the observer never triggers a permission prompt.
func visibleWindowOrder() -> [String]? {
    guard CGPreflightScreenCaptureAccess(),
          let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    return windows.compactMap { window in
        guard let layer = window[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
              let pid = window[kCGWindowOwnerPID as String] as? NSNumber,
              let id = window[kCGWindowNumber as String] as? NSNumber else { return nil }
        return "\(pid.intValue):\(id.uint32Value)"
    }
}
var lastWindowOrder = visibleWindowOrder()
var windowOrderAvailable = lastWindowOrder != nil
var windowOrderChanges = 0
var finished = false
try Data("ready".utf8).write(to: ready, options: .atomic)
let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
    samples += 1
    let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
    if pid != lastPID { frontmostChanges += 1; lastPID = pid }
    if let point = CGEvent(source: nil)?.location {
        if let previous = lastPointer, point != previous { pointerSamplesChanged += 1 }
        lastPointer = point
    }
    if let order = visibleWindowOrder() {
        if let previous = lastWindowOrder, previous != order { windowOrderChanges += 1 }
        lastWindowOrder = order
    } else { windowOrderAvailable = false; lastWindowOrder = nil }
    let clipboard = NSPasteboard.general.changeCount
    if clipboard != lastClipboard { clipboardChanges += 1; lastClipboard = clipboard }
    if FileManager.default.fileExists(atPath: stop.path) || ProcessInfo.processInfo.systemUptime - start > 7200 {
        let result: [String: Any] = ["frontmost_changes": frontmostChanges, "pointer_changed_samples": pointerSamplesChanged,
            "clipboard_change_events": clipboardChanges, "samples": samples,
            "seconds": ProcessInfo.processInfo.systemUptime - start, "sample_interval_ms": 50,
            "attribution": "unattributed-observations", "window_order": windowOrderAvailable ? windowOrderChanges as Any : NSNull(),
            "window_order_status": windowOrderAvailable ? "available" : "unavailable-permission-or-query",
            "window_order_semantics": "normal-layer onscreen PID/window-ID sequence changes; includes creation, removal and reordering; unattributed"]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output, options: .atomic)
        }
        finished = true
    }
}
while !finished { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.2)) }
timer.invalidate()
