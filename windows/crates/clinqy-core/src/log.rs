//! agent.log: every run, step by step (secrets masked by the caller). Same line format as the Mac app, so
//! `clinqy stats`, the MCP server and tests read it the same way. Rotated to agent.log.1 past 5 MB.

use parking_lot::Mutex;
use std::io::Write;

static LOCK: Mutex<()> = Mutex::new(());

pub fn write(line: &str) {
    let _guard = LOCK.lock();
    let path = crate::paths::agent_log();
    if std::fs::metadata(&path).map(|m| m.len() > 5_000_000).unwrap_or(false) {
        let old = path.with_extension("log.1");
        let _ = std::fs::remove_file(&old);
        let _ = std::fs::rename(&path, &old);
    }
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(f, "{line}");
    }
    if std::env::var_os("CLINQY_ECHO").is_some() {
        eprintln!("{line}");
    }
}

/// Appends one JSON line to a file in the log folder (runs.jsonl).
pub fn append_jsonl(name: &str, value: &serde_json::Value) {
    let _guard = LOCK.lock();
    let path = crate::paths::log_dir().join(name);
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(f, "{value}");
    }
}
