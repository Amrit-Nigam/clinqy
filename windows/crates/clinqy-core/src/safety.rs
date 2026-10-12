//! Guard rails enforced in code, not left to the model: confirm consequential clicks, never press session-ending
//! chords nobody asked for. A port of the Mac app's Safety, with the Windows chords.

use regex::Regex;
use std::sync::OnceLock;

/// Button words that commit money, messages or data, with the words a user would have used to ask for it.
fn risky() -> &'static Vec<(Regex, Vec<&'static str>)> {
    static R: OnceLock<Vec<(Regex, Vec<&'static str>)>> = OnceLock::new();
    R.get_or_init(|| {
        [
            (r"\b(pay|payment|pay now)\b", vec!["pay"]),
            (r"\b(buy|purchase|place (your )?order|checkout|check out|proceed to (pay|checkout))\b", vec!["buy", "order", "purchase", "checkout"]),
            (r"\b(book|confirm booking|reserve)\b", vec!["book", "reserve"]),
            (r"\b(transfer|withdraw|donate)\b", vec!["transfer", "send money", "donate"]),
            (r"\b(delete|remove|trash|erase|discard)\b", vec!["delete", "remove", "trash", "erase", "clear"]),
            (r"\b(send|reply all)\b", vec!["send", "reply", "message", "tell", "text", "email", "say"]),
            (r"\b(submit|apply|sign up|register)\b", vec!["submit", "apply", "sign up", "register"]),
            (r"\b(post|publish|tweet|share)\b", vec!["post", "publish", "tweet", "share"]),
            (r"\b(unsubscribe|cancel (my )?(subscription|order|plan)|deactivate|close account)\b", vec!["unsubscribe", "cancel"]),
        ]
        .into_iter()
        .map(|(p, v)| (Regex::new(p).unwrap(), v))
        .collect()
    })
}

/// If clicking a control labelled `label` commits something the request didn't clearly ask for, a short
/// description to confirm with the user.
pub fn needs_confirmation(label: &str, request: &str) -> Option<String> {
    let text = label.to_lowercase();
    let asked = request.to_lowercase();
    for (pattern, verbs) in risky() {
        if !pattern.is_match(&text) {
            continue;
        }
        // Asked for it, and said "don't …" about none of its words.
        let negated = verbs.iter().any(|verb| {
            Regex::new(&format!(r"\b(don['’]?t|do not|never|without|not|no)\s+(\w+\s+){{0,2}}{}", regex::escape(verb)))
                .map(|r| r.is_match(&asked))
                .unwrap_or(false)
        });
        if !negated && verbs.iter().any(|v| asked.contains(v)) {
            return None;
        }
        return Some(label.chars().take(80).collect());
    }
    None
}

/// True when a confirmation answer means yes (English, Hindi and Hinglish, like the Mac app).
pub fn is_yes(answer: &str) -> bool {
    let a = answer.to_lowercase();
    let a = a.trim();
    static NO: OnceLock<Regex> = OnceLock::new();
    let no = NO.get_or_init(|| Regex::new(r"\b(no|not|don'?t|dont|never|cancel|stop|nahi|nahin|nai|mat|rehne|rahne|ruko)\b|मत|नहीं").unwrap());
    if no.is_match(a) {
        return false;
    }
    const YES: &[&str] = &[
        "yes", "y", "ok", "okay", "sure", "go", "go ahead", "do it", "confirm", "yep", "yeah", "haan", "ha", "han", "haanji",
        "haan ji", "ha ji", "ji", "ji haan", "theek hai", "thik hai", "thik h", "sahi hai", "kar do", "kardo", "bhej do", "bhejdo",
        "chalega", "ho jaye", "हाँ", "हां", "जी", "ठीक है",
    ];
    YES.iter().any(|y| a == *y || a.starts_with(&format!("{y} ")) || a.starts_with(&format!("{y},")))
}

/// Chords that lock, sign out, shut down or kill things: (modifiers, key, words that would ask for it).
const SYSTEM_CHORDS: &[(&[&str], &str, &[&str])] = &[
    (&["win"], "l", &["lock"]),
    (&["ctrl", "alt"], "delete", &["lock", "task manager", "sign out", "log out", "logout"]),
    (&["ctrl", "alt"], "del", &["lock", "task manager", "sign out", "log out", "logout"]),
    (&["alt"], "f4", &["close", "quit", "exit", "shut down", "shutdown"]),
    (&["ctrl", "shift"], "esc", &["task manager"]),
    (&["win", "ctrl"], "f4", &["close desktop", "virtual desktop"]),
];

/// The modifiers and key of a chord, normalised ("cmd+Q" → {"ctrl"}, "q").
pub fn split_chord(combo: &str) -> (Vec<String>, String) {
    let mut mods = vec![];
    let mut key = String::new();
    for part in combo.to_lowercase().replace(' ', "").split('+').filter(|p| !p.is_empty()) {
        match part {
            "cmd" | "command" | "⌘" | "ctrl" | "control" | "⌃" => mods.push("ctrl".to_string()),
            "shift" | "⇧" => mods.push("shift".to_string()),
            "opt" | "option" | "alt" | "⌥" => mods.push("alt".to_string()),
            "win" | "windows" | "super" | "meta" => mods.push("win".to_string()),
            "escape" => key = "esc".into(),
            other => key = other.to_string(),
        }
    }
    mods.sort();
    mods.dedup();
    (mods, key)
}

/// If `combo` is a session-ending chord the request didn't ask for, why it isn't pressed.
pub fn blocked_chord(combo: &str, request: &str) -> Option<String> {
    let (mods, key) = split_chord(combo);
    let asked = request.to_lowercase();
    for (chord_mods, chord_key, words) in SYSTEM_CHORDS {
        let mut want: Vec<String> = chord_mods.iter().map(|s| s.to_string()).collect();
        want.sort();
        if want == mods && *chord_key == key {
            let wanted = words.iter().any(|w| Regex::new(&format!(r"\b{}\b", regex::escape(w))).map(|r| r.is_match(&asked)).unwrap_or(false));
            if wanted {
                return None;
            }
            return Some(format!("{combo} locks, signs out, closes or opens system screens; not pressed because the request didn't ask for that"));
        }
    }
    None
}

pub const REDACTED: &str = "«redacted»";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn confirms_unasked_commits() {
        assert!(needs_confirmation("Pay now", "find me a flight").is_some());
        assert!(needs_confirmation("Pay now", "pay the electricity bill").is_none());
        assert!(needs_confirmation("Submit", "fill the form but don't submit").is_some());
        assert!(needs_confirmation("Next", "fill the form").is_none());
    }

    #[test]
    fn yes_and_no() {
        assert!(is_yes("Yes, go ahead"));
        assert!(is_yes("haan ji"));
        assert!(!is_yes("no thanks"));
        assert!(!is_yes("haan but don't send"));
    }

    #[test]
    fn chords() {
        assert!(blocked_chord("win+l", "open notepad").is_some());
        assert!(blocked_chord("win+l", "lock my screen").is_none());
        assert!(blocked_chord("alt+f4", "close this window").is_none());
        assert!(blocked_chord("ctrl+t", "open a tab").is_none());
    }
}
