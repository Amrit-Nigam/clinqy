import CoreAudio
import CoreGraphics
import Foundation

/// Guard rails enforced in code, not left to the model: confirm consequential clicks, notice live calls.
enum Safety {
    /// Button words that commit money, messages or data: (pattern, word the user would have used to ask for it).
    private static let risky: [(String, [String])] = [
        (#"\b(pay|payment|pay now)\b"#, ["pay"]),
        (#"\b(buy|purchase|place (your )?order|checkout|check out|proceed to (pay|checkout))\b"#, ["buy", "order", "purchase", "checkout"]),
        (#"\b(book|confirm booking|reserve)\b"#, ["book", "reserve"]),
        (#"\b(transfer|withdraw|donate)\b"#, ["transfer", "send money", "donate"]),
        (#"\b(delete|remove|trash|erase|discard)\b"#, ["delete", "remove", "trash", "erase", "clear"]),
        (#"\b(send|reply all)\b"#, ["send", "reply", "message", "tell", "text", "email", "say"]),
        (#"\b(submit|apply|sign up|register)\b"#, ["submit", "apply", "sign up", "register"]),
        (#"\b(post|publish|tweet|share)\b"#, ["post", "publish", "tweet", "share"]),
        (#"\b(unsubscribe|cancel (my )?(subscription|order|plan)|deactivate|close account)\b"#, ["unsubscribe", "cancel"]),
    ]

    /// If clicking a control labelled `label` would commit something the request didn't clearly ask for,
    /// returns a short description to confirm with the user.
    static func needsConfirmation(label: String, request: String) -> String? {
        let text = label.lowercased()
        let asked = request.lowercased()
        for (pattern, verbs) in risky where text.range(of: pattern, options: .regularExpression) != nil {
            // They asked for exactly this — and didn't say "don't …" / "without …" about it.
            let wanted = verbs.contains { verb in
                asked.contains(verb) && asked.range(of: #"\b(don'?t|do not|never|without|not|no)\s+(\w+\s+){0,2}"# + NSRegularExpression.escapedPattern(for: verb),
                                                    options: .regularExpression) == nil
            }
            if wanted { return nil }
            return String(label.prefix(80))
        }
        return nil
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
}
