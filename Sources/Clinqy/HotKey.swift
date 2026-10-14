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
    private let wanted: NSEvent.ModifierFlags
    var enabled = true

    private static let relevant: NSEvent.ModifierFlags = [.control, .option, .command, .shift, .function]

    init(spec: String = "ctrl+alt", onPress: @escaping () -> Void, onRelease: @escaping () -> Void,
         onOtherKey: @escaping () -> Void = {}) {
        self.onPress = onPress
        self.onRelease = onRelease
        self.onOtherKey = onOtherKey
        var flags: NSEvent.ModifierFlags = []
        for part in spec.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "ctrl", "control": flags.insert(.control)
            case "alt", "option", "opt": flags.insert(.option)
            case "shift": flags.insert(.shift)
            case "cmd", "command": flags.insert(.command)
            default: break
            }
        }
        wanted = flags.isEmpty ? [.control, .option] : flags
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
        guard enabled else { down = false; spoiled = false; return }
        if type == .keyDown {
            // Another key during the chord: it's someone else's shortcut.
            if down, !spoiled { spoiled = true; onOtherKey() }
            return
        }
        let mods = flags.intersection(Self.relevant)
        if !down, mods == wanted {
            down = true
            spoiled = false
            onPress()
        } else if down, mods != wanted {
            down = false
            if !spoiled { onRelease() }
        }
    }

    deinit {
        let ms = monitors
        DispatchQueue.main.async { ms.forEach { NSEvent.removeMonitor($0) } }
    }
}

@MainActor
final class PushToTalkHotKey {
    private let modifiers: NSEvent.ModifierFlags
    private let key: String
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var monitors: [Any] = []
    private var down = false
    var enabled = true

    init?(spec: String, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        let parts = spec.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.last, parts.count >= 2 else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part {
            case "ctrl", "control": flags.insert(.control)
            case "alt", "option", "opt": flags.insert(.option)
            case "shift": flags.insert(.shift)
            case "cmd", "command": flags.insert(.command)
            default: return nil
            }
        }
        guard !flags.isEmpty, key == "space" || key.count == 1 ||
                (key.first == "f" && Int(key.dropFirst()).map { (1...12).contains($0) } == true) else { return nil }
        self.key = key
        modifiers = flags
        self.onPress = onPress
        self.onRelease = onRelease
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            let type = e.type, flags = e.modifierFlags, key = Self.keyName(e)
            MainActor.assumeIsolated { self?.handle(type, flags, key) }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            let type = e.type, flags = e.modifierFlags, key = Self.keyName(e)
            MainActor.assumeIsolated { self?.handle(type, flags, key) }
            return e
        }) { monitors.append(monitor) }
    }

    private func handle(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags, _ pressedKey: String?) {
        guard enabled else { down = false; return }
        let relevant = flags.intersection([.control, .option, .command, .shift])
        if type == .keyDown, !down, relevant == modifiers, pressedKey == key {
            down = true
            onPress()
        } else if down && ((type == .keyUp && pressedKey == key) || (type == .flagsChanged && relevant != modifiers)) {
            down = false
            onRelease()
        }
    }

    private static func keyName(_ event: NSEvent) -> String? {
        let functionKeys: [UInt16: String] = [122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
                                               98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12"]
        if let functionKey = functionKeys[event.keyCode] { return functionKey }
        if let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty {
            return chars == " " ? "space" : chars
        }
        return nil
    }

    deinit {
        let ms = monitors
        DispatchQueue.main.async { ms.forEach { NSEvent.removeMonitor($0) } }
    }
}
