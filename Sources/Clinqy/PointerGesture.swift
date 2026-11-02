import Foundation

/// A bounded pointer sequence shared by native and CDP delivery. Coordinates are resolved against an
/// observation before constructing it; this type never chooses or retries a target.
struct PointerGesture {
    enum Kind: String, CaseIterable { case hover, right_click, double_click, drag }
    struct Point: Equatable { let x: Double; let y: Double }
    struct Event {
        enum Phase { case move, down, up }
        let phase: Phase
        let point: Point
        let right: Bool
        let held: Bool
        let count: Int
        var cdp: [String: Any] {
            ["type": phase == .move ? "mouseMoved" : phase == .down ? "mousePressed" : "mouseReleased",
             "x": point.x, "y": point.y, "button": phase == .move && !held ? "none" : right ? "right" : "left",
             "buttons": held ? (right ? 2 : 1) : 0, "clickCount": count]
        }
    }
    let kind: Kind
    let start: Point
    let end: Point
    let events: [Event]

    init?(kind: Kind, start: Point, end: Point? = nil) {
        let destination = end ?? start
        guard [start.x, start.y, destination.x, destination.y].allSatisfy(\.isFinite),
              kind != .drag || end != nil else { return nil }
        self.kind = kind; self.start = start; self.end = destination
        let right = kind == .right_click
        var events = [Event(phase: .move, point: start, right: false, held: false, count: 0)]
        if kind == .drag {
            events.append(Event(phase: .down, point: start, right: false, held: true, count: 1))
            for step in 1...12 {
                let fraction = Double(step) / 12
                events.append(Event(phase: .move, point: Point(x: start.x + (destination.x - start.x) * fraction,
                                                            y: start.y + (destination.y - start.y) * fraction),
                                    right: false, held: true, count: 0))
            }
            events.append(Event(phase: .up, point: destination, right: false, held: false, count: 1))
        } else if kind != .hover {
            for count in 1...(kind == .double_click ? 2 : 1) {
                events.append(Event(phase: .down, point: start, right: right, held: true, count: count))
                events.append(Event(phase: .up, point: start, right: right, held: false, count: count))
            }
        }
        self.events = events
    }
}
