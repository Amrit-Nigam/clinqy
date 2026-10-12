//! How clicks go, per site or app: one agent.log line per click (what `clinqy stats` adds up), and which way of
//! clicking to try first on a site where real mouse clicks keep doing nothing (click-hints.json).

use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::OnceLock;

/// "    click: web github.com mouse ok 1"
pub fn line(kind: &str, place: &str, method: &str, worked: bool, tries: u32) -> String {
    let w = if place.is_empty() { "-".to_string() } else { place.replace(' ', "_") };
    format!("    click: {kind} {w} {method} {} {tries}", if worked { "ok" } else { "nochange" })
}

pub fn host(url: &str) -> String {
    url::Url::parse(url).ok().and_then(|u| u.host_str().map(|h| h.replace("www.", ""))).unwrap_or_default()
}

#[derive(Serialize, Deserialize, Default, Clone, Copy)]
struct Tally {
    #[serde(rename = "mouseMiss", default)]
    mouse_miss: u32,
    #[serde(rename = "mouseWin", default)]
    mouse_win: u32,
    #[serde(rename = "scriptWin", default)]
    script_win: u32,
}

fn path() -> std::path::PathBuf {
    crate::paths::data_dir().join("click-hints.json")
}

fn tallies() -> &'static Mutex<HashMap<String, Tally>> {
    static T: OnceLock<Mutex<HashMap<String, Tally>>> = OnceLock::new();
    T.get_or_init(|| Mutex::new(std::fs::read_to_string(path()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()))
}

/// The site ignores real mouse clicks but takes clicks through the page: start with those there.
pub fn prefers_script(host: &str) -> bool {
    if host.is_empty() {
        return false;
    }
    let t = tallies().lock().get(host).copied().unwrap_or_default();
    t.script_win >= 2 && t.mouse_miss >= 2 && t.mouse_miss > t.mouse_win
}

pub fn note(host: &str, mouse_tried: bool, mouse_worked: bool, script_worked: bool) {
    if host.is_empty() || !(mouse_tried || script_worked) {
        return;
    }
    let mut all = tallies().lock();
    let t = all.entry(host.to_string()).or_default();
    if mouse_tried {
        if mouse_worked {
            t.mouse_win += 1
        } else {
            t.mouse_miss += 1
        }
    }
    if script_worked {
        t.script_win += 1;
    }
    if t.mouse_miss + t.mouse_win + t.script_win > 40 {
        *t = Tally { mouse_miss: t.mouse_miss / 2, mouse_win: t.mouse_win / 2, script_win: t.script_win / 2 };
    }
    if let Ok(s) = serde_json::to_string(&*all) {
        let _ = std::fs::write(path(), s);
    }
}
