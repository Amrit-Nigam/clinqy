//! Recording runs as offline replay fixtures (REPLAY_RECORD=on): the page snapshots the extension sent plus the
//! model's reply for each turn, in the Mac app's fixture format (Logs/replays/*.json).

use parking_lot::Mutex;
use serde_json::{json, Value};

struct Recording {
    request: String,
    turns: Vec<Value>,
    page: Option<Value>,
}

static CURRENT: Mutex<Option<Recording>> = Mutex::new(None);

fn enabled() -> bool {
    crate::config::on("REPLAY_RECORD", false)
}

pub fn begin(request: &str) {
    *CURRENT.lock() = enabled().then(|| Recording { request: request.into(), turns: vec![], page: None });
}

pub fn record_page(page: &Value) {
    if let Some(r) = CURRENT.lock().as_mut() {
        r.page = Some(page.clone());
    }
}

pub fn turn(reply: &str, ms: u64) {
    if let Some(r) = CURRENT.lock().as_mut() {
        let page = r.page.take();
        r.turns.push(json!({"page": page, "reply": reply, "ms": ms}));
    }
}

pub fn end(ok: bool) {
    let Some(r) = CURRENT.lock().take() else { return };
    if r.turns.is_empty() {
        return;
    }
    let dir = crate::paths::log_dir().join("replays");
    let _ = std::fs::create_dir_all(&dir);
    let name = chrono::Local::now().format("%Y-%m-%d %H.%M.%S").to_string();
    let v = json!({"request": r.request, "ok": ok, "turns": r.turns, "expect": {}});
    let _ = std::fs::write(dir.join(format!("{name}.json")), serde_json::to_string_pretty(&v).unwrap_or_default());
}
