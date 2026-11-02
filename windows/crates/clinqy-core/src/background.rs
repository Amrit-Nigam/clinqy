//! Background mode: a run that works out of the user's way, in a separate headless browser (see `worker`), while they
//! keep their mouse, keyboard, clipboard and windows. This module holds the pure decisions: whether a request asks for
//! it, and which actions a background run may take at all. A background task never falls through to native input.

use crate::reply::{Action, ActionExt};
use fancy_regex::Regex;
use std::sync::OnceLock;

/// Every request runs in the background: Dashboard → Background, or BACKGROUND_TASKS=on.
pub fn always() -> bool {
    crate::config::on("BACKGROUND_TASKS", false)
}

/// Saves the Dashboard's switch (BACKGROUND_TASKS in the settings file).
pub fn set_always(on: bool) -> std::io::Result<()> {
    crate::config::set("BACKGROUND_TASKS", if on { "on" } else { "" })
}

struct Cut {
    pattern: Regex,
    wants: bool,
    /// A trailing "in the background" that's only the mode when the word before isn't what's in the background.
    guard_word: bool,
}

fn cuts() -> &'static [Cut] {
    static CUTS: OnceLock<Vec<Cut>> = OnceLock::new();
    CUTS.get_or_init(|| {
        // Words that can sit between "not" and "background": "don't use", "not as a", "do not run this in the".
        let filler = r"(?:(?:do|run|use|using|put|keep|make|go|work|it|it's|this|that|one|is|be|in|into|as|a|an|the|on|my|please|just)\s+){0,5}";
        let no = r"(?:don'?t|dont|do not|not|no|never|without|avoid)";
        let mode = r"(?:\s+(?:mode|task|job|run|tab|window|screen))?";
        let ends = r"(?=\s*(?:[,.;:!?)]|$|and\b|but\b|then\b|please\b|&))";
        let lead = r"^\(?(?:please\s+)?";
        let lead_end = r"\)?(?:[\s,.;:!-]+|$)";
        let away = r"(?:\s+(?:from|out of)\s+(?:the\s+)?(?:screen|sight|view))";
        let negative = format!(r"(?:(?:this|it)\s+is\s+|it'?s\s+)?{no}\s+{filler}(?:background|bg){mode}");
        let front = r"(?:(?:do|run|work)\s+(?:this\s+|it\s+|that\s+)?)?(?:in\s+(?:the\s+)?foreground|foreground(?:\s+mode)?|in\s+front(?:\s+of\s+me)?|visibly)";
        // "in the background" as the place to work: on its own it can be part of the task ("the people in the
        // background"), so mid-sentence it needs "do/run it" before it or "mode/task" after it.
        let do_it = r"(?:(?:please\s+|just\s+)?(?:do|run|work\s+on|handle|keep)\s+(?:this|it|that)(?:\s+one)?\s+)";
        let in_bg = r"(?:in|as|into)\s+(?:a\s+|an\s+|the\s+)?(?:background|bg)";
        let lead_join = r"[\s,.;:-]*(?:and\s+|but\s+|please\s+)*";
        let join = r"[\s,.;:-]*(?:and\s+|please\s+)*";
        let list: Vec<(String, bool, bool)> = vec![
            // Negatives first: "don't do it in the background" also contains "in the background".
            (format!("{lead}{negative}{lead_end}"), false, false),
            (format!(r"{lead_join}{negative}(?:\s+please)?{ends}"), false, false),
            (format!("{lead}{front}{lead_end}"), false, false),
            (format!(r"{lead_join}{front}(?:\s+please)?{ends}"), false, false),
            // "in the background open gmail" (spoken, no comma); a bare "background"/"bg" needs a colon or comma, so
            // "background check on …" stays a request.
            (format!("{lead}{do_it}?{in_bg}{mode}{away}?{lead_end}"), true, false),
            (r"^\(?(?:background(?:\s+(?:mode|task))?|bg)\)?\s*[,:;-]\s*".to_string(), true, false),
            (format!(r"{join}{do_it}{in_bg}{mode}{away}?(?:\s+please)?{ends}"), true, false),
            (format!(r"{join}{in_bg}\s+(?:mode|task|job)(?:\s+please)?{ends}"), true, false),
            (r"[\s,]+(?:and\s+|please\s+)*(?:in\s+(?:the\s+)?background|in\s+bg)(?:\s+please)?[\s.!]*$".to_string(), true, true),
        ];
        list.into_iter()
            .map(|(p, wants, guard_word)| Cut { pattern: Regex::new(&format!("(?i){p}")).expect("background pattern"), wants, guard_word })
            .collect()
    })
}

/// Words that are what's in the background ("blur the people in the background"), not the place to work.
const IN_THE_PICTURE: &[&str] = &[
    "people", "person", "man", "woman", "thing", "things", "object", "objects", "car", "cars", "tree", "trees", "stuff", "image", "photo", "picture",
    "music", "noise", "sound", "everything", "anything", "someone", "something",
];

fn spans(pattern: &str, text: &str) -> Vec<(usize, usize)> {
    let Ok(re) = regex::Regex::new(pattern) else { return vec![] };
    re.find_iter(text).map(|m| (m.start(), m.end())).collect()
}

fn overlaps(a: (usize, usize), b: (usize, usize)) -> bool {
    a.0 < b.1 && b.0 < a.1
}

/// The first match of a mode phrase outside quotes (quoted text is what to type or send, never the mode).
fn unquoted(cut: &Cut, text: &str, quoted: &[(usize, usize)]) -> Option<(usize, usize)> {
    let mut at = 0;
    while at <= text.len() {
        let m = cut.pattern.find_from_pos(text, at).ok().flatten()?;
        let span = (m.start(), m.end());
        let word_before = text[..m.start()].rsplit(|c: char| !c.is_alphanumeric()).next().unwrap_or("").to_lowercase();
        if !quoted.iter().any(|q| overlaps(*q, span)) && !(cut.guard_word && IN_THE_PICTURE.contains(&word_before.as_str())) {
            return Some(span);
        }
        // On past this match, to the next character boundary.
        at = m.end().max(at + 1);
        while at < text.len() && !text.is_char_boundary(at) {
            at += 1;
        }
    }
    None
}

/// What the request itself says about where to work, typed or spoken, whatever the switch is: true for "in the
/// background: …", "do it in the background, …", "… as a background task"; false for "don't use background",
/// "foreground: …", "… in front of me". None when it says nothing. Phrases that only choose the mode are taken off;
/// ones that are part of the task ("… on my screen") stay in.
pub fn choice(request: &mut String) -> Option<bool> {
    let text = request.clone();
    let quoted = spans(r#""[^"]*"|“[^”]*”"#, &text);
    for cut in cuts() {
        let Some((start, end)) = unquoted(cut, &text, &quoted) else { continue };
        let edge = start == 0 || end == text.len();
        let mut out = format!("{}{}{}", &text[..start], if edge { "" } else { " " }, &text[end..]);
        out = regex::Regex::new(r"\s+([,.;:!?])").unwrap().replace_all(&out, "$1").into_owned();
        out = regex::Regex::new(r"^[\s,.;:-]+|[\s,;:-]+$").unwrap().replace_all(&out, "").into_owned();
        *request = out;
        return Some(cut.wants);
    }
    let foreground = regex::Regex::new(r"(?i)\b(in front of me|on my screen|in the foreground|where i can see( it)?|let me (watch|see))\b").unwrap();
    if foreground.find_iter(&text).any(|m| !quoted.iter().any(|q| overlaps(*q, (m.start(), m.end())))) {
        return Some(false);
    }
    None
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Route {
    /// Needs no window at all: files, PDFs, memory, questions.
    Api,
    /// In the background browser.
    Browser,
    /// Can't be done out of the user's way; they decide.
    Attention(String),
}

/// Which browsers `open_app` may mean in a background run (it opens a blank page in the background browser).
const BROWSERS: &[&str] = &["chrome", "google chrome", "edge", "microsoft edge", "msedge", "brave", "browser"];

/// Pure capability routing: anything not known to be isolated needs the user's say-so.
pub fn route(action: &Action, has_worker_page: bool) -> Route {
    let kind = action.kind();
    let attention = |why: &str| Route::Attention(why.to_string());
    let web_id = action.str("id").map(|i| i.to_lowercase().starts_with('w')).unwrap_or(false);
    let worker_only = || if has_worker_page { Route::Browser } else { attention("This action needs a page in the background browser. Open its URL first.") };
    match kind.as_str() {
        "open_url" => Route::Browser,
        "open_app" => {
            let name = action.str("name").unwrap_or("").to_lowercase();
            if BROWSERS.contains(&name.as_str()) {
                Route::Browser
            } else if name.contains("explorer") {
                attention("Use the files action to find, list, rename or move files without opening File Explorer.")
            } else {
                attention("This task needs a desktop app. Its input can't be kept away from yours in background mode.")
            }
        }
        "click" | "type" | "choose" | "fill" => {
            let on_a_picture = kind == "click" && !action.contains_key("id") && action.contains_key("x");
            if has_worker_page && (web_id || on_a_picture || (!action.contains_key("id") && kind == "type")) {
                Route::Browser
            } else {
                attention("There's no page of mine to act on here, and I won't use your active window.")
            }
        }
        "key" => {
            let keys = action.str("keys").unwrap_or("").to_lowercase().replace(' ', "");
            let commands = ["cmd", "command", "meta", "super", "win", "ctrl", "control", "alt", "option"];
            if commands.iter().any(|c| keys.contains(&format!("{c}+"))) && !["cmd+a", "command+a", "meta+a", "ctrl+a", "control+a"].contains(&keys.as_str()) {
                attention("This shortcut can reach shared browser or system state. Use page fields, direct uploads or file tools instead.")
            } else if has_worker_page {
                Route::Browser
            } else {
                attention("There's no page of mine for this key to go to.")
            }
        }
        "read" | "extract" => {
            if action.contains_key("path") || action.contains_key("file") {
                Route::Api
            } else if has_worker_page {
                Route::Browser
            } else {
                attention("Give a file path or open a page in the background browser. I won't read your foreground document.")
            }
        }
        "files" => {
            if ["show", "reveal"].contains(&action.str("op").unwrap_or("").to_lowercase().as_str()) {
                attention("Revealing files opens File Explorer on your desktop. I can give you their paths in the results instead.")
            } else {
                Route::Api
            }
        }
        "table" => {
            if action.str("to").unwrap_or("csv").eq_ignore_ascii_case("csv") {
                Route::Api
            } else {
                attention("Write a CSV file in background mode. Spreadsheet windows and the shared clipboard need the foreground.")
            }
        }
        "wait" if !action.contains_key("for") => Route::Api,
        "upload" | "autofill" | "review" | "scroll" | "tab" | "look" | "snap" | "wait" => worker_only(),
        "pdf" => {
            let mut paths: Vec<String> = action.get("files").and_then(|f| f.as_array()).map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect()).unwrap_or_default();
            paths.extend(action.string("file"));
            let office = ["doc", "docx", "csv", "ppt", "pptx", "xls", "xlsx"];
            if paths.iter().any(|p| p.rsplit('.').next().map(|e| office.contains(&e.to_lowercase().as_str())).unwrap_or(false)) {
                attention("This conversion opens an Office app. Use foreground mode for it.")
            } else {
                Route::Api
            }
        }
        "think" | "dictionary" | "remember_answer" | "calendar" | "media" | "application" | "remember" | "recall" | "event" | "reminder" | "ask" | "show" | "assert" | "schedule" => Route::Api,
        "email" => {
            if action.flag("draft") {
                attention("A draft opens a mail window. Use foreground mode to review it there.")
            } else {
                Route::Api
            }
        }
        "shell" | "applescript" => attention("Arbitrary scripts can change your desktop or shared input. Use the files, PDF, media or other supported actions in background mode."),
        _ => attention("This action needs desktop access and can't run safely in background mode."),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn said(text: &str) -> (Option<bool>, String) {
        let mut s = text.to_string();
        let c = choice(&mut s);
        (c, s)
    }

    #[test]
    fn asking_for_the_background() {
        assert_eq!(said("in the background: open gmail"), (Some(true), "open gmail".into()));
        assert_eq!(said("in the background open gmail"), (Some(true), "open gmail".into()));
        assert_eq!(said("bg: check my orders"), (Some(true), "check my orders".into()));
        assert_eq!(said("find flights to Mumbai, do it in the background"), (Some(true), "find flights to Mumbai".into()));
        assert_eq!(said("summarise this page as a background task"), (Some(true), "summarise this page".into()));
        assert_eq!(said("open gmail in the background"), (Some(true), "open gmail".into()));
    }

    #[test]
    fn asking_for_the_foreground() {
        assert_eq!(said("don't use background, open gmail"), (Some(false), "open gmail".into()));
        assert_eq!(said("open gmail, not in the background"), (Some(false), "open gmail".into()));
        assert_eq!(said("foreground: open gmail"), (Some(false), "open gmail".into()));
        assert_eq!(said("open gmail in front of me"), (Some(false), "open gmail".into()));
        // Part of the task, so it stays in.
        assert_eq!(said("show it on my screen"), (Some(false), "show it on my screen".into()));
    }

    #[test]
    fn tasks_that_only_mention_it() {
        for t in ["change the text, not the background color", "blur the people in the background", "background check on Raj", "set the desktop background to blue", r#"message him: "do it in the background""#] {
            assert_eq!(said(t), (None, t.to_string()), "{t}");
        }
    }

    fn action(v: serde_json::Value) -> Action {
        v.as_object().unwrap().clone()
    }

    #[test]
    fn nothing_reaches_the_desktop() {
        let denied = [
            json!({"do": "open_app", "name": "File Explorer"}),
            json!({"do": "open_app", "name": "Notepad"}),
            json!({"do": "shell"}),
            json!({"do": "paste_snaps"}),
            json!({"do": "files", "op": "reveal"}),
            json!({"do": "key", "keys": "ctrl+v"}),
            json!({"do": "key", "keys": "win+r"}),
            json!({"do": "key", "keys": "alt+f4"}),
            json!({"do": "table", "to": "clipboard"}),
            json!({"do": "click", "id": "e2"}),
            json!({"do": "window"}),
            json!({"do": "menu"}),
            json!({"do": "pdf", "file": "a.docx"}),
            json!({"do": "email", "draft": true}),
            json!({"do": "something_new"}),
        ];
        for a in denied {
            assert!(matches!(route(&action(a.clone()), true), Route::Attention(_)), "{a}");
        }
    }

    #[test]
    fn what_a_background_run_may_do() {
        assert_eq!(route(&action(json!({"do": "files", "op": "list"})), false), Route::Api);
        assert_eq!(route(&action(json!({"do": "read", "path": "a.txt"})), false), Route::Api);
        assert_eq!(route(&action(json!({"do": "open_url", "url": "x"})), false), Route::Browser);
        assert_eq!(route(&action(json!({"do": "open_app", "name": "Edge"})), false), Route::Browser);
        assert_eq!(route(&action(json!({"do": "type", "id": "w2"})), true), Route::Browser);
        assert_eq!(route(&action(json!({"do": "type"})), true), Route::Browser);
        assert_eq!(route(&action(json!({"do": "key", "keys": "ctrl+a"})), true), Route::Browser);
        assert_eq!(route(&action(json!({"do": "key", "keys": "enter"})), true), Route::Browser);
        assert!(matches!(route(&action(json!({"do": "key", "keys": "enter"})), false), Route::Attention(_)));
        assert!(matches!(route(&action(json!({"do": "click", "id": "w2"})), false), Route::Attention(_)));
    }
}
