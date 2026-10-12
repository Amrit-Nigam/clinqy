//! Settings: the process environment first, then `~/.config/clinqy/env` (KEY=VALUE lines), the same file and
//! format as on the Mac. The file is re-read when it changes, so edits apply without a restart.

use parking_lot::Mutex;
use std::collections::HashMap;
use std::time::SystemTime;

struct Cache {
    stamp: Option<SystemTime>,
    values: HashMap<String, String>,
}

static CACHE: Mutex<Option<Cache>> = Mutex::new(None);

pub fn parse(text: &str) -> HashMap<String, String> {
    let mut values = HashMap::new();
    for line in text.lines() {
        let trimmed = line.trim().trim_start_matches('\u{feff}');
        if trimmed.starts_with('#') {
            continue;
        }
        let Some(eq) = trimmed.find('=') else { continue };
        let key = trimmed[..eq].trim();
        let key = key.strip_prefix("export ").unwrap_or(key).trim();
        if key.is_empty() {
            continue;
        }
        let value = trimmed[eq + 1..].trim().trim_matches(|c| c == '"' || c == '\'' || c == ' ');
        values.insert(key.to_string(), value.to_string());
    }
    values
}

fn file_values() -> HashMap<String, String> {
    let path = crate::paths::env_file();
    let stamp = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
    let mut cache = CACHE.lock();
    if let Some(c) = cache.as_ref() {
        if c.stamp == stamp {
            return c.values.clone();
        }
    }
    let values = std::fs::read_to_string(&path).map(|t| parse(&t)).unwrap_or_default();
    *cache = Some(Cache { stamp, values: values.clone() });
    values
}

/// A setting, or None when it's unset or empty.
pub fn value(key: &str) -> Option<String> {
    if let Ok(v) = std::env::var(key) {
        if !v.is_empty() {
            return Some(v);
        }
    }
    file_values().get(key).filter(|v| !v.is_empty()).cloned()
}

/// On unless set to off/0/no/false.
pub fn on(key: &str, default: bool) -> bool {
    match value(key).map(|v| v.to_lowercase()) {
        Some(v) if ["off", "0", "no", "false"].contains(&v.as_str()) => false,
        Some(v) if ["on", "1", "yes", "true"].contains(&v.as_str()) => true,
        _ => default,
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn parses_env_lines() {
        let v = super::parse("# c\nA=1\n B = \"two\" \nexport C='x'\nnoeq\n=bad");
        assert_eq!(v["A"], "1");
        assert_eq!(v["B"], "two");
        assert_eq!(v["C"], "x");
        assert_eq!(v.len(), 3);
    }
}
