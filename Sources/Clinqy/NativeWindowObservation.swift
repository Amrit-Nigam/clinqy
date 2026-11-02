import AppKit

/// One exact native window and process lifetime, selected before scanning or capturing it.
/// Keeping the AX object and WindowServer ID together prevents separate subsystems choosing different windows.
struct NativeWindowObservation: @unchecked Sendable {
    let id: UUID
    let capturedAt: Date
    let element: AXUIElement
    let frame: CGRect
    let identity: AXEngine.ProcessIdentity
    let windowID: CGWindowID
    let contentRevision: Int
    var pid: pid_t { identity.pid }

    /// Verification may follow an attached sheet, but never an unrelated window from the same application.
    func containsVerificationWindow(_ current: NativeWindowObservation) -> Bool {
        guard identity == current.identity else { return false }
        if windowID == current.windowID { return true }
        return containsElement(current.element) || current.containsElement(element)
    }

    func containsElement(_ target: AXUIElement) -> Bool {
        NativeWindowHierarchy.contains(target, root: element, parents: { node in
            let parent: AXUIElement? = AXEngine.attribute(node, kAXParentAttribute)
            let window: AXUIElement? = AXEngine.attribute(node, kAXWindowAttribute)
            return [parent, window].compactMap { $0 }
        }, equal: { CFEqual($0, $1) })
    }

    static func capture(_ app: NSRunningApplication, windowID: CGWindowID? = nil) -> NativeWindowObservation? {
        let window = windowID.flatMap { id in AXEngine.windows(of: app).first { AXEngine.windowID(of: $0) == id } }
            ?? (windowID == nil ? AXEngine.selectedWindow(of: app) : nil)
        guard let window, let id = AXEngine.windowID(of: window), let identity = AXEngine.identity(of: app),
              let frame = AXEngine.liveFrame(of: window), frame.width > 0, frame.height > 0 else { return nil }
        let result = NativeWindowObservation(id: UUID(), capturedAt: Date(), element: window, frame: frame,
                                             identity: identity, windowID: id, contentRevision: AXEngine.fingerprint(of: window))
        return result.staleness() == nil ? result : nil
    }

    func staleness(includeContent: Bool = false) -> String? {
        guard AXEngine.isSameProcess(identity) else { return "the target application restarted; look again" }
        guard AXEngine.windowID(of: element) == windowID, let now = AXEngine.liveFrame(of: element) else {
            return "the target window was closed or replaced; look again"
        }
        let geometry = ObservationGeometry(frame: frame, imageSize: CGSize(width: 1, height: 1))
        guard geometry.matches(now) else { return "the target window moved or resized; look again" }
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]] ?? []
        guard let info = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }),
              (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let serverFrame = CGRect(dictionaryRepresentation: bounds), geometry.matches(serverFrame) else {
            return "the target window identity or geometry cannot be verified; look again"
        }
        if includeContent, AXEngine.fingerprint(of: element) != contentRevision {
            return "the target window contents changed since the image was captured; look again"
        }
        return nil
    }
}
