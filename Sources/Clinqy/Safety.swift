import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import Foundation

/// Guard rails enforced in code, not left to the model: confirm consequential clicks, notice live calls.
enum Safety {
    /// The broad list of button words that may commit money, messages or data. Used only to decide that a click can't
    /// confirm itself (verification); whether to ASK is the narrower `needsConfirmation`.
    private static let consequential: [String] = [
        #"\b(pay|payment|pay now)\b"#,
        #"\b(buy|purchase|place (your )?order|checkout|check out|proceed to (pay|checkout))\b"#,
        #"\b(book|confirm booking|reserve)\b"#,
        #"\b(transfer|withdraw|donate)\b"#,
        #"\b(delete|remove|trash|erase|discard)\b"#,
        #"\b(send|reply all)\b"#,
        #"\b(submit|apply|sign up|register)\b"#,
        #"\b(post|publish|tweet|share)\b"#,
        #"\b(unsubscribe|cancel (my )?(subscription|order|plan)|deactivate|close account)\b"#,
    ]

    /// True when a control's label alone says it may be irreversible or reach other people.
    static func isConsequential(_ label: String) -> Bool {
        let text = label.lowercased()
        return consequential.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// If clicking a control labelled `label` needs the user's yes under the default level, returns a short
    /// description to confirm with. Only paying/buying/booking/transferring, permanent deletion, sending to someone
    /// and public posting ask (judged with `context`: page title, URL, form fields); the request naming that action
    /// pre-authorises it. A word the request rules out ("fill it but don't submit") always asks.
    static func needsConfirmation(label: String, request: String, context: String = "") -> String? {
        guard let kind = RiskClassifier.classify(label: label, context: context) else { return nil }
        let verbs = RiskClassifier.verbs(label: label, kind: kind)
        let situation = AskingPolicy.Situation(kind: kind, preauthorized: PreAuthorization.covers(label: label, kind: kind, request: request),
                                               negated: PreAuthorization.negated(verbs, in: request))
        return AskingPolicy.shouldAsk(situation) ? String(label.prefix(80)) : nil
    }

    /// True when a confirmation answer means yes.
    static func isYes(_ answer: String) -> Bool {
        let a = answer.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // "ji nahi", "haan but don't send", "theek hai, rehne do": any no-word wins.
        if a.range(of: #"\b(no|not|don'?t|dont|never|cancel|stop|nahi|nahin|nai|mat|rehne|rahne|ruko|मत|नहीं)\b"#, options: .regularExpression) != nil { return false }
        return ["yes", "y", "ok", "okay", "sure", "go", "go ahead", "do it", "confirm", "yep", "yeah",
                // Hindi / Hinglish
                "haan", "ha", "han", "haanji", "haan ji", "ha ji", "ji", "ji haan", "theek hai", "thik hai", "thik h", "sahi hai",
                "kar do", "kardo", "bhej do", "bhejdo", "chalega", "ho jaye", "हाँ", "हां", "जी", "ठीक है"]
            .contains(where: { a == $0 || a.hasPrefix($0 + " ") || a.hasPrefix($0 + ",") })
    }

    /// True while the screen is locked (nothing on screen can be used).
    static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// True if another app is using the microphone right now (a call, a meeting).
    static var micInUse: Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    // MARK: - Secure input

    /// Pid of the process holding Secure Event Input (a focused password field, Terminal's Secure Keyboard Entry).
    static var secureInputPID: pid_t? {
        guard let pid = (CGSessionCopyCurrentDictionary() as? [String: Any])?["kCGSSessionSecureInputPID"] as? Int,
              pid > 0 else { return nil }
        return pid_t(pid)
    }

    /// Why typing mustn't happen right now, or nil. While another process holds secure input, keystrokes are
    /// headed into (or around) a password prompt, exactly where synthetic typing must never go.
    static func secureInputBlock() -> String? {
        guard let pid = secureInputPID, pid != getpid() else { return nil }
        let owner = NSRunningApplication(processIdentifier: pid)?.cleanName ?? "Another app"
        return "\(owner) has a password field focused (secure input is on), so I won't type. "
            + "Enter it yourself, or leave that field and run again."
    }

    // MARK: - Sensitive apps


    // MARK: - System chords

    /// Chords that lock, log out or force-quit: (modifiers, key, words the user would have used to ask).
    private static let systemChords: [(Set<String>, String, [String])] = [
        (["cmd", "ctrl"], "q", ["lock"]),
        (["cmd", "shift"], "q", ["log out", "logout", "log off", "sign out"]),
        (["cmd", "opt", "shift"], "q", ["log out", "logout", "log off", "sign out"]),
        (["cmd", "opt"], "esc", ["force quit", "force-quit", "forcequit"]),
    ]

    /// If `combo` is a session-ending chord the request didn't ask for, says so; nil when it may be pressed.
    static func blockedChord(_ combo: String, request: String) -> String? {
        var mods = Set<String>(), key = ""
        for part in combo.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command", "⌘": mods.insert("cmd")
            case "shift", "⇧": mods.insert("shift")
            case "opt", "option", "alt", "⌥": mods.insert("opt")
            case "ctrl", "control", "⌃": mods.insert("ctrl")
            case "escape": key = "esc"
            default: key = part
            }
        }
        let asked = request.lowercased()
        for (chordMods, chordKey, words) in systemChords where chordMods == mods && chordKey == key {
            // Whole words: "clock" or "block" isn't asking to lock the screen.
            let wanted = words.contains {
                asked.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: $0) + #"\b"#, options: .regularExpression) != nil
            }
            if wanted { return nil }
            return "\(combo) locks, logs out or force-quits; not pressed because the request didn't ask for that"
        }
        return nil
    }

    // MARK: - Redaction

    static let redactedMark = "«redacted»"

    /// True for password fields, whose value must never reach the model, logs or history.
    static func isSecureField(_ element: AXUIElement) -> Bool {
        func string(_ name: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value as? String
        }
        return string(kAXSubroleAttribute) == "AXSecureTextField" || string(kAXRoleAttribute) == "AXSecureTextField"
    }

    /// `value` as it may be shown to the model: masked for password fields.
    static func redacted(_ value: String?, of element: AXUIElement) -> String? {
        guard let value, !value.isEmpty, isSecureField(element) else { return value }
        return redactedMark
    }

    /// Same, for callers that already read the role and subrole.
    static func redacted(_ value: String?, role: String?, subrole: String?) -> String? {
        guard let value, !value.isEmpty, role == "AXSecureTextField" || subrole == "AXSecureTextField" else { return value }
        return redactedMark
    }
}
