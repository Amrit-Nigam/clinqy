import AppKit

/// A modifier-only hotkey: Control + Option pressed together, with nothing else.
/// Reports press and release (for tap vs. hold). If any other key is pressed while they're held, the chord
/// belongs to some other shortcut (e.g. ⌃⌥← in a window manager), so it's reported as `onOtherKey` instead.
@MainActor
final class HotKey {
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private let onOtherKey: () -> Void
    private var monitors: [Any] = []
    private var down = false
    private var spoiled = false

    private static let wanted: NSEvent.ModifierFlags = [.control, .option]
    private static let relevant: NSEvent.ModifierFlags = [.control, .option, .command, .shift, .function]

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void, onOtherKey: @escaping () -> Void = {}) {
        self.onPress = onPress
        self.onRelease = onRelease
        self.onOtherKey = onOtherKey
        // Global: while other apps are active. Local: while our own panel is key.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] e in
            let type = e.type, flags = e.modifierFlags
            MainActor.assumeIsolated { self?.handle(type, flags) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] e in
            let type = e.type, flags = e.modifierFlags
            MainActor.assumeIsolated { self?.handle(type, flags) }
            return e
        }) { monitors.append(m) }
    }

    private func handle(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags) {
        if type == .keyDown {
            // Another key during the chord: it's someone else's shortcut.
            if down, !spoiled { spoiled = true; onOtherKey() }
            return
        }
        let mods = flags.intersection(Self.relevant)
        if !down, mods == Self.wanted {
            down = true
            spoiled = false
            onPress()
        } else if down, mods != Self.wanted {
            down = false
            if !spoiled { onRelease() }
        }
    }

    deinit {
        let ms = monitors
        DispatchQueue.main.async { ms.forEach { NSEvent.removeMonitor($0) } }
    }
}
