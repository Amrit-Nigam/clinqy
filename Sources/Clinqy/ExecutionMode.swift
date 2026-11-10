import Foundation

/// User-authored execution mode, parsed independently of app state or appended file/context data.
enum ExecutionMode {
    static func choice(_ request: inout String) -> Bool? {
        // Words that can sit between "not" and "background": "don't use", "not as a", "do not run this in the".
        let filler = #"(?:(?:do|run|use|using|put|keep|make|go|work|it|it's|this|that|one|is|be|in|into|as|a|an|the|on|my|please|just)\s+){0,5}"#
        let no = #"(?:don'?t|dont|do not|not|no|never|without|avoid)"#
        let mode = #"(?:\s+(?:mode|task|job|run|tab|window|screen))?"#
        let ends = #"(?=\s*(?:[,.;:!?)]|$|and\b|but\b|then\b|please\b|&))"#
        let lead = #"^\(?(?:please\s+)?"#
        let leadEnd = #"\)?(?:[\s,.;:!-]+|$)"#
        let away = #"(?:\s+(?:from|out of)\s+(?:the\s+)?(?:screen|sight|view))"#
        let negative = #"(?:(?:this|it)\s+is\s+|it'?s\s+)?"# + no + #"\s+"# + filler + #"(?:background|bg)"# + mode
        let front = #"(?:(?:(?:use|using|in|run\s+in)\s+)?normal\s+mode(?:\s+clinqy)?|(?:(?:do|run|work)\s+(?:this\s+|it\s+|that\s+)?)?(?:in\s+(?:the\s+)?foreground|foreground(?:\s+mode)?|in\s+front(?:\s+of\s+me)?|visibly))"#
        // "in the background" as the place to work: on its own it can be part of the task ("the people in the
        // background"), so mid-sentence it needs "do/run it" before it or "mode/task" after it.
        let doIt = #"(?:(?:please\s+|just\s+)?(?:do|run|work\s+on|handle|keep)\s+(?:this|it|that)(?:\s+one)?\s+)"#
        let inBg = #"(?:in|as|into)\s+(?:a\s+|an\s+|the\s+)?(?:background|bg)"#
        let notTask = #"(?<!people|person|man|woman|thing|things|object|objects|car|cars|tree|trees|stuff|image|photo|picture|music|noise|sound|everything|anything|someone|something)"#
        // "never switch to foreground mode", "don't use foreground", "without foreground": a constraint that rules
        // foreground out. It must never select foreground; it is removed whole (not leaving "Never switch to.").
        let switchTo = #"(?:ever\s+)?(?:(?:switch|change|go|move|flip|jump|come|fall)\s+(?:back\s+)?(?:to|into|over\s+to)\s+)?"#
        let negativeFront = no + #"\s+"# + switchTo + filler + front
        var rulesOutForeground = false
        for pattern in [lead + negativeFront + #"(?:\s+please)?"# + leadEnd,
                        #"[\s,;:-]*(?:and\s+|but\s+|please\s+)*"# + negativeFront + #"(?:\s+please)?"# + ends] {
            while let r = unquotedMatch(pattern, in: request) {
                rulesOutForeground = true
                let edge = r.lowerBound == request.startIndex || r.upperBound == request.endIndex
                request.replaceSubrange(r, with: edge ? "" : " ")
                request = tidy(request)
            }
        }
        let cut: [(String, Bool)] = [
            // Negatives first: "don't do it in the background" also contains "in the background".
            (lead + negative + leadEnd, false),
            (lead + front + leadEnd, false),
            // An explicit leading "in the background:" wins over later mentions of the mode. "in the background open
            // gmail" (spoken, no comma); a bare "background"/"bg" needs a colon or comma, so "background check on …"
            // stays a request.
            (lead + doIt + "?" + inBg + mode + away + "?" + leadEnd, true),
            (#"^\(?(?:background(?:\s+(?:mode|task))?|bg)\)?\s*[,:;-]\s*"#, true),
            (#"[\s,.;:-]*(?:and\s+|but\s+|please\s+)*"# + negative + #"(?:\s+please)?"# + ends, false),
            (#"[\s,.;:-]*(?:and\s+|but\s+|please\s+)*"# + front + #"(?:\s+please)?"# + ends, false),
            (#"[\s,.;:-]*(?:and\s+|please\s+)*"# + doIt + inBg + mode + away + "?" + #"(?:\s+please)?"# + ends, true),
            (#"[\s,.;:-]*(?:and\s+|please\s+)*"# + inBg + #"\s+(?:mode|task|job)(?:\s+please)?"# + ends, true),
            (notTask + #"[\s,]+(?:and\s+|please\s+)*(?:in\s+(?:the\s+)?background|in\s+bg)(?:\s+please)?[\s.!]*$"#, true),
        ]
        let text = request
        let unquoted = { (pattern: String) in unquotedMatch(pattern, in: text) }
        for (pattern, wants) in cut {
            guard let r = unquoted(pattern) else { continue }
            let edge = r.lowerBound == request.startIndex || r.upperBound == request.endIndex
            request.replaceSubrange(r, with: edge ? "" : " ")
            request = tidy(request)
            return wants
        }
        if rulesOutForeground { return true }
        if unquoted(#"\b(in front of me|on my screen|in the foreground|where i can see( it)?|let me (watch|see))\b"#) != nil { return false }
        return nil
    }

    /// First case-insensitive match outside quoted text (quoted text is what to type or send, never the mode).
    private static func unquotedMatch(_ pattern: String, in text: String) -> Range<String.Index>? {
        let quoted = matches(#""[^"]*"|“[^”]*”"#, in: text)
        return matches("(?i)" + pattern, in: text).first { r in !quoted.contains { $0.overlaps(r) } }
    }

    private static func tidy(_ request: String) -> String {
        request.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?<!\.)([.!?])\s*\.(?!\.)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"^[\s,.;:-]+|[\s,;:-]+$"#, with: "", options: .regularExpression)
    }

    private static func matches(_ pattern: String, in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }
}
