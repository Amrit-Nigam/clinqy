import AppKit

/// The user's own proper nouns (people, chats, apps, places) pulled from memory, used to bias speech
/// recognition toward their spellings and to fix names it still mishears ("Vaje Plus" → "Waje+").
enum NameHints {
    /// A name worth hinting, plus the misheard forms memory says it arrives as.
    struct Term: Equatable {
        var name: String
        var aliases: [String] = []
    }

    // MARK: Vocabulary (cached, rebuilt when memory.md changes)

    private static let memoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/clinqy/memory.md")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (stamp: Date?, terms: [Term])?

    /// Up to 100 names, most useful first. Cheap to call: re-reads memory only after it changes.
    static var terms: [Term] {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: memoryURL.path))?[.modificationDate] as? Date
        if let hit = lock.withLock({ cached }), hit.stamp == stamp { return hit.terms }
        let built = extract(from: Memory.facts, userName: NSFullUserName())
        lock.withLock { cached = (stamp, built) }
        return built
    }

    /// For SFSpeechRecognitionRequest.contextualStrings (Apple recommends ≤ 100).
    static var vocabulary: [String] { terms.map(\.name) }

    /// A short list for Whisper's prompt; the most important names go last (Whisper keeps the prompt's tail).
    static func promptNames(limit: Int = 30) -> [String] { Array(vocabulary.prefix(limit).reversed()) }

    /// Fixes misheard names in a finished transcript.
    static func correct(_ text: String) -> String { correct(text, terms: terms) }

    // MARK: Extraction

    /// Words that are clearly not names (sentence starters, roles, generic nouns).
    private static let notNames: Set<String> = [
        "i", "he", "she", "his", "her", "they", "we", "you", "it", "the", "a", "an", "and", "or", "in", "on", "at", "for",
        "to", "of", "with", "via", "by", "from", "when", "if", "use", "uses", "has", "is", "was", "also", "other", "friend",
        "group", "chat", "chats", "app", "mother", "father", "home", "school", "tech", "no", "yes", "current", "college",
        "applied", "internship", "intern", "past", "won", "prefers", "wants", "likes", "keeps", "total", "job", "maybe",
        "cursor", "arc", "notes", "find", "play", "continue", "anyone", "interviewing", "creative",
    ]

    /// Memory phrasing that marks a quoted string as a misheard form, not the real name.
    private static let aliasBefore = #"(?i)(says|say|mishear[a-z]*(?: the name)? as|or|heard as|transcribed as)\s*$"#
    private static let aliasAfter = #"(?i)^\s*(in voice|means)"#

    /// Pulls names from memory facts: quoted chat/contact names first, then capitalized runs ("Kumar Tanay").
    /// Pure apart from the spell checker; `isWord` says whether a lowercase word is ordinary English.
    static func extract(from facts: [String], userName: String, limit: Int = 100,
                        isWord: (String) -> Bool = NameHints.isWord) -> [Term] {
        var score: [String: Int] = [:]
        var order: [String] = []
        var aliases: [String: [String]] = [:]
        func add(_ raw: String, _ weight: Int) {
            guard let name = cleanName(raw, isWord: isWord) else { return }
            let key = name.lowercased()
            if let existing = order.first(where: { $0.lowercased() == key }) { score[existing, default: 0] += weight; return }
            order.append(name)
            score[name] = weight
        }
        add(userName, 1000)
        for fact in facts {
            let ns = fact as NSString
            var names: [String] = []
            var quotedNames: [String] = []
            var misheard: [String] = []
            let quoted = try! NSRegularExpression(pattern: #"(?<![A-Za-z])['‘“"]([^'’”"]{2,40})['’”"](?![A-Za-z])"#)
            let chatty = fact.range(of: #"(?i)whatsapp|chat|group|contact|friend|telegram"#, options: .regularExpression) != nil
            for m in quoted.matches(in: fact, range: NSRange(location: 0, length: ns.length)) {
                let inner = ns.substring(with: m.range(at: 1))
                let before = ns.substring(to: m.range.location)
                let after = ns.substring(from: m.range.location + m.range.length)
                if before.range(of: aliasBefore, options: .regularExpression) != nil
                    || after.range(of: aliasAfter, options: .regularExpression) != nil {
                    misheard.append(inner)
                } else if let name = cleanName(inner, isWord: isWord) {
                    names.append(name)
                    quotedNames.append(name)
                    add(name, chatty ? 4 : 2)
                }
            }
            // Capitalized runs outside quotes: "Kumar Tanay", "Shreyans Tatiya", "Andheri".
            var unquoted = quoted.stringByReplacingMatches(in: fact, range: NSRange(location: 0, length: ns.length), withTemplate: " , ")
            // "Anis Patini/Anish Patni has a chat 'Anish Patni'": the spelling that isn't the chat name is a misheard form.
            let slashed = try! NSRegularExpression(pattern: #"([A-Z][\w+]*(?: [A-Z][\w+]*){0,2})/([A-Z][\w+]*(?: [A-Z][\w+]*){0,2})"#)
            let us = unquoted as NSString
            for m in slashed.matches(in: unquoted, range: NSRange(location: 0, length: us.length)) {
                let pair = [us.substring(with: m.range(at: 1)), us.substring(with: m.range(at: 2))]
                guard let real = pair.first(where: quotedNames.contains), let other = pair.first(where: { $0 != real }),
                      similarity(key(other), key(real)) >= 0.6 else { continue }
                misheard.append(other)
                unquoted = unquoted.replacingOccurrences(of: us.substring(with: m.range), with: " , ")
            }
            for run in capitalizedRuns(unquoted.replacingOccurrences(of: "/", with: " , ")) {
                guard let name = cleanName(run, isWord: isWord) else { continue }
                names.append(name)
                add(name, 1)
            }
            // A misheard form belongs to the name in the same fact it sounds most like.
            for alias in misheard {
                let best = names.map { ($0, similarity(key(alias), key($0))) }.max { $0.1 < $1.1 }
                if let best, best.1 >= 0.5 {
                    aliases[best.0.lowercased(), default: []].append(alias)
                    add(best.0, 2)
                }
            }
        }
        let misheardSet = Set(aliases.values.flatMap { $0.map { $0.lowercased() } })
        return order.filter { !misheardSet.contains($0.lowercased()) }
            .enumerated().sorted { (score[$0.1] ?? 0, -$0.0) > (score[$1.1] ?? 0, -$1.0) }
            .prefix(limit)
            .map { Term(name: $0.1, aliases: aliases[$0.1.lowercased()] ?? []) }
    }

    /// Runs of capitalized words (up to 3) within a clause.
    private static func capitalizedRuns(_ text: String) -> [String] {
        var runs: [String] = []
        var current: [String] = []
        func flush() { if !current.isEmpty { runs.append(current.suffix(3).joined(separator: " ")) }; current = [] }
        for raw in text.split(whereSeparator: \.isWhitespace) {
            var token = String(raw)
            if let f = token.first, "(\"'“‘".contains(f) { flush() }
            var breaks = token.last.map { ",.;:()!?".contains($0) } ?? false
            for s in ["'s", "’s"] where token.hasSuffix(s) { token.removeLast(2); breaks = true }
            token = token.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:()!?\"'"))
            let isCap = token.first?.isUppercase == true && token.count >= 2
                && token.allSatisfy { $0.isLetter || $0 == "+" || $0 == "-" }
            if isCap { current.append(token) } else { flush() }
            if breaks { flush() }
        }
        flush()
        return runs
    }

    /// Trims ordinary words off the ends; nil unless something name-like is left.
    private static func cleanName(_ raw: String, isWord: (String) -> Bool) -> String? {
        let kept = raw.unicodeScalars.filter { CharacterSet.letters.union(.decimalDigits).contains($0) || " +*-&.".unicodeScalars.contains($0) }
        var words = String(String.UnicodeScalarView(kept)).split(separator: " ").map(String.init)
        func ordinary(_ w: String) -> Bool {
            let l = w.lowercased()
            if notNames.contains(l) { return true }
            if w.count <= 3, w == w.uppercased() { return true }   // AWS, EC2: not spoken as names
            return l.allSatisfy(\.isLetter) && isWord(l)
        }
        while let f = words.first, ordinary(f) { words.removeFirst() }
        while let l = words.last, ordinary(l) { words.removeLast() }
        guard !words.isEmpty, words.count <= 4 else { return nil }
        let name = words.joined(separator: " ")
        // File names and hyphenated phrases ("Speech-to-text") aren't names; "Amrit-Nigam" is.
        guard !name.contains("."),
              words.allSatisfy({ $0.split(separator: "-").allSatisfy { $0.first?.isUppercase == true } || !$0.contains("-") })
        else { return nil }
        guard name.count >= 3, name.first?.isLetter == true,
              words.allSatisfy({ $0.contains(where: \.isUppercase) || $0.first?.isNumber == true }),
              name.unicodeScalars.allSatisfy({ $0.value < 0x250 }) else { return nil }
        return name
    }

    // MARK: Correction

    /// Filler that never starts or ends a name span.
    private static let glue: Set<String> = [
        "a", "an", "the", "to", "on", "in", "at", "of", "for", "and", "or", "with", "my", "me", "is", "it", "that", "this",
        "him", "her", "his", "from", "by", "hi", "hey", "ok", "okay", "so", "send", "message", "open", "tell", "call", "text",
    ]

    /// Replaces spans of `text` that sound like a known name, only when the match is strong and unambiguous and the
    /// span contains a word that isn't ordinary English (so "message mom hi" is never touched).
    static func correct(_ text: String, terms: [Term], isWord: (String) -> Bool = NameHints.isWord) -> String {
        struct Token { var range: Range<String.Index>; var core: String }
        // Plain words only; URLs, emails, numbers and contractions break spans.
        var tokens: [Token?] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard !text[i].isWhitespace else { i = text.index(after: i); continue }
            var j = i
            while j < text.endIndex, !text[j].isWhitespace { j = text.index(after: j) }
            var lo = i, hi = j
            while lo < hi, !text[lo].isLetter { lo = text.index(after: lo) }
            while hi > lo, !text[text.index(before: hi)].isLetter { hi = text.index(before: hi) }
            var core = String(text[lo..<hi])
            for s in ["'s", "’s"] where core.lowercased().hasSuffix(s) {
                core.removeLast(2); hi = text.index(hi, offsetBy: -2)
            }
            let leadOK = text[i..<lo].allSatisfy { "\"'“‘(".contains($0) }
            let trailOK = text[hi..<j].allSatisfy { ".,!?;:\"'”’)".contains($0) } || text[hi..<j].lowercased() == "'s" || text[hi..<j].lowercased() == "’s"
            tokens.append(!core.isEmpty && core.allSatisfy({ $0.isLetter || $0 == "-" }) && leadOK && trailOK
                          ? Token(range: lo..<hi, core: core) : nil)
            i = j
        }
        let targets = terms.compactMap { t -> (name: String, keys: [String], words: Int)? in
            let keys = ([t.name] + t.aliases).map(key).filter { $0.count >= 5 }
            return keys.isEmpty ? nil : (t.name, keys, spoken(t.name).count)
        }
        guard !targets.isEmpty else { return text }
        let singles = Set(terms.map { $0.name.lowercased() }.filter { !$0.contains(" ") })

        struct Hit { var start: Int; var end: Int; var name: String; var sim: Double }
        var hits: [Hit] = []
        for start in tokens.indices {
            for n in 1...3 where start + n <= tokens.count {
                let span = tokens[start..<start + n]
                guard span.allSatisfy({ $0 != nil }) else { break }
                let words = span.map { $0!.core }
                let lower = words.map { $0.lowercased() }
                guard !glue.contains(lower.first!), !glue.contains(lower.last!) else { continue }
                let k = key(words.joined(separator: " "))
                guard k.count >= 4 else { continue }
                let unusual = lower.contains { !isWord($0) }
                var scored: [(name: String, sim: Double)] = []
                for t in targets where abs(t.words - n) <= 1 {
                    // Extra words holding another name said right ("Anirudh has") aren't a garbled name.
                    if n > t.words, lower.contains(where: singles.contains) { continue }
                    // Already said right (maybe in different case): leave it.
                    if lower.joined(separator: " ") == t.name.lowercased() { scored = []; break }
                    let sim = t.keys.map { similarity(k, $0) }.max() ?? 0
                    // Longer names tolerate more; merging extra words into a shorter name must be near exact.
                    let need = n > t.words ? 0.95 : min(k.count, t.keys.map(\.count).max() ?? 0) >= 7 ? 0.8 : 0.86
                    // A span of ordinary words only counts when it's the name split apart ("well found" → "Wellfound").
                    guard sim >= need, unusual || (sim == 1 && n > t.words) else { continue }
                    scored.append((t.name, sim))
                }
                scored.sort { $0.sim > $1.sim }
                guard let best = scored.first else { continue }
                if scored.count > 1, scored[1].name != best.name, best.sim - scored[1].sim < 0.08 { continue }
                hits.append(Hit(start: start, end: start + n, name: best.name, sim: best.sim))
            }
        }
        // Strongest, then shortest, matches win; overlapping ones are dropped.
        hits.sort { ($0.sim, $1.end - $1.start) > ($1.sim, $0.end - $0.start) }
        var taken = Set<Int>()
        var chosen: [Hit] = []
        for h in hits where !(h.start..<h.end).contains(where: taken.contains) {
            chosen.append(h)
            taken.formUnion(h.start..<h.end)
        }
        var out = text
        for h in chosen.sorted(by: { $0.start > $1.start }) {
            let range = tokens[h.start]!.range.lowerBound..<tokens[h.end - 1]!.range.upperBound
            out.replaceSubrange(range, with: h.name)
        }
        return out
    }

    // MARK: Sound-alike matching

    /// A name as spoken words: "Waje+" → ["waje", "plus"].
    static func spoken(_ s: String) -> [String] {
        s.lowercased().replacingOccurrences(of: "+", with: " plus ").replacingOccurrences(of: "&", with: " and ")
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// A rough sound key: spelling variants that sound alike collapse (v/w, sh/s, th/t, g/k, d/t, doubled letters).
    static func key(_ s: String) -> String {
        var t = spoken(s).joined()
        for (a, b) in [("x", "ks"), ("ph", "f"), ("ck", "k"), ("ch", "c"), ("sh", "s"), ("th", "t"), ("dh", "d"),
                       ("bh", "b"), ("kh", "k"), ("gh", "g"), ("jh", "j"), ("q", "k"), ("z", "s"), ("v", "w"),
                       ("y", "i"), ("g", "k"), ("d", "t"), ("b", "p")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        t = t.replacingOccurrences(of: "c", with: "k")
        // A trailing h after a consonant is silent in transliterated names.
        var out = ""
        for ch in t where !(ch == "h" && out.last.map { !isVowel($0) } == true) {
            if out.last != ch { out.append(ch) }
        }
        return out
    }

    private static func isVowel(_ c: Character) -> Bool { "aeiou".contains(c) }

    /// 0…1 similarity between sound keys; vowels are cheap to swap, add or drop.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        // Names start with the same sound (or both with a vowel).
        guard x[0] == y[0] || (isVowel(x[0]) && isVowel(y[0])) else { return 0 }
        func cost(_ c: Character) -> Double { isVowel(c) ? 0.5 : 1 }
        var prev = [0.0] + y.indices.map { _ in 0.0 }
        for j in y.indices { prev[j + 1] = prev[j] + cost(y[j]) }
        for i in x.indices {
            var row = [prev[0] + cost(x[i])] + y.indices.map { _ in 0.0 }
            for j in y.indices {
                let sub = x[i] == y[j] ? 0 : (isVowel(x[i]) && isVowel(y[j]) ? 0.5 : 1)
                row[j + 1] = min(prev[j] + sub, prev[j + 1] + cost(x[i]), row[j] + cost(y[j]))
            }
            prev = row
        }
        return max(0, 1 - prev[y.count] / Double(max(x.count, y.count)))
    }

    /// Ordinary English (per the system spell checker, including words the user taught it).
    static func isWord(_ word: String) -> Bool {
        let r = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false,
                                                    inSpellDocumentWithTag: 0, wordCount: nil)
        return r.location == NSNotFound
    }
}
