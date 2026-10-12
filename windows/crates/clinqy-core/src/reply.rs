//! Reading the model's replies: the JSON object (tolerating code fences or prose around it, or tool-call tags
//! instead of JSON), and the first complete action of a reply that's still streaming in.

use serde_json::{json, Map, Value};

pub type Action = Map<String, Value>;

/// Pulls the reply envelope `{"say","actions","done"}` out of a reply.
pub fn parse(reply: &str) -> Option<Map<String, Value>> {
    if let (Some(start), Some(end)) = (reply.find('{'), reply.rfind('}')) {
        if start < end {
            if let Ok(Value::Object(obj)) = serde_json::from_str::<Value>(&reply[start..=end]) {
                // A bare action ({"do":"ask",…}) instead of the envelope: run it as the turn's only action.
                if obj.contains_key("do") && !obj.contains_key("actions") {
                    let mut env = Map::new();
                    env.insert("say".into(), json!(""));
                    env.insert("actions".into(), Value::Array(vec![Value::Object(obj)]));
                    env.insert("done".into(), json!(false));
                    return Some(env);
                }
                return Some(obj);
            }
            // Several objects back to back, or trailing prose with braces: try the first balanced object.
            if let Some(first) = balanced_object(&reply[start..]) {
                if let Ok(Value::Object(obj)) = serde_json::from_str::<Value>(first) {
                    return Some(obj);
                }
            }
        }
    }
    invokes(reply)
}

/// The text of the first balanced `{…}` at the start of `text` (strings and escapes respected).
fn balanced_object(text: &str) -> Option<&str> {
    let mut depth = 0i32;
    let (mut in_string, mut escaped) = (false, false);
    for (i, c) in text.char_indices() {
        if in_string {
            if escaped {
                escaped = false;
            } else if c == '\\' {
                escaped = true;
            } else if c == '"' {
                in_string = false;
            }
        } else if c == '"' {
            in_string = true;
        } else if c == '{' {
            depth += 1;
        } else if c == '}' {
            depth -= 1;
            if depth == 0 {
                return Some(&text[..=i]);
            }
        }
    }
    None
}

/// The first action of a reply still being written, once that action is complete (`"actions":[{…}` closed).
pub fn first_action_in_partial(text: &str) -> Option<Action> {
    let re = regex::Regex::new(r#""actions"\s*:\s*\["#).unwrap();
    let m = re.find(text)?;
    let rest = text[m.end()..].trim_start();
    if !rest.starts_with('{') {
        return None;
    }
    let object = balanced_object(rest)?;
    match serde_json::from_str::<Value>(object) {
        Ok(Value::Object(a)) if a.get("do").map(|d| d.is_string()).unwrap_or(false) => Some(a),
        _ => None,
    }
}

/// Tool-call tags instead of JSON (`<invoke name="scroll"><parameter name="dir">up</parameter>…`): each is an action.
pub fn invokes(reply: &str) -> Option<Map<String, Value>> {
    let block = regex::Regex::new(r#"(?s)<invoke name="([A-Za-z_]+)"\s*/?>(.*?)(?:</invoke>|$)"#).ok()?;
    let param = regex::Regex::new(r#"(?s)<parameter name="([A-Za-z_]+)">(.*?)</parameter>"#).ok()?;
    let mut actions = vec![];
    let (mut done, mut say) = (false, String::new());
    for m in block.captures_iter(reply) {
        let name = m[1].to_string();
        let body = m.get(2).map(|b| b.as_str()).unwrap_or("");
        let mut action = Map::new();
        action.insert("do".into(), json!(name));
        for p in param.captures_iter(body) {
            let raw = p[2].trim();
            let v = serde_json::from_str::<Value>(raw).unwrap_or_else(|_| json!(raw));
            action.insert(p[1].to_string(), v);
        }
        if name == "done" || name == "finish" {
            done = true;
            say = action.get("say").or_else(|| action.get("text")).and_then(|v| v.as_str()).unwrap_or(&say).to_string();
            continue;
        }
        actions.push(Value::Object(action));
    }
    if actions.is_empty() && !done {
        return None;
    }
    let mut env = Map::new();
    env.insert("say".into(), json!(say));
    env.insert("actions".into(), Value::Array(actions));
    env.insert("done".into(), json!(done));
    Some(env)
}

/// Sorted-key JSON for comparing actions.
pub fn canonical(action: &Action) -> String {
    fn sort(v: &Value) -> Value {
        match v {
            Value::Object(m) => {
                let mut keys: Vec<_> = m.keys().collect();
                keys.sort();
                let mut out = Map::new();
                for k in keys {
                    out.insert(k.clone(), sort(&m[k]));
                }
                Value::Object(out)
            }
            Value::Array(a) => Value::Array(a.iter().map(sort).collect()),
            other => other.clone(),
        }
    }
    sort(&Value::Object(action.clone())).to_string()
}

/// Small accessors so action handlers read like the Mac code.
pub trait ActionExt {
    fn str(&self, key: &str) -> Option<&str>;
    fn string(&self, key: &str) -> Option<String> {
        self.str(key).map(String::from)
    }
    fn num(&self, key: &str) -> Option<f64>;
    fn flag(&self, key: &str) -> bool;
    fn list(&self, key: &str) -> Vec<String>;
    fn kind(&self) -> String;
}

impl ActionExt for Action {
    fn str(&self, key: &str) -> Option<&str> {
        self.get(key).and_then(|v| v.as_str())
    }
    fn num(&self, key: &str) -> Option<f64> {
        match self.get(key)? {
            Value::Number(n) => n.as_f64(),
            Value::String(s) => s.trim().parse().ok(),
            _ => None,
        }
    }
    fn flag(&self, key: &str) -> bool {
        match self.get(key) {
            Some(Value::Bool(b)) => *b,
            Some(Value::String(s)) => s == "true",
            _ => false,
        }
    }
    fn list(&self, key: &str) -> Vec<String> {
        match self.get(key) {
            Some(Value::Array(a)) => a.iter().filter_map(|v| v.as_str().map(String::from)).collect(),
            Some(Value::String(s)) => vec![s.clone()],
            _ => vec![],
        }
    }
    fn kind(&self) -> String {
        self.str("do").unwrap_or("").to_lowercase()
    }
}

/// An action written compactly for logs and notes: `click w12`, `type "hello" → e3`.
pub fn brief(a: &Action) -> String {
    let kind = a.kind();
    let target = a.get("id").map(|v| v.as_str().map(String::from).unwrap_or_else(|| v.to_string()));
    let text = a.str("text").map(|t| format!(" {:?}", t.chars().take(40).collect::<String>()));
    let other = a
        .str("url")
        .or_else(|| a.str("name"))
        .or_else(|| a.str("keys"))
        .or_else(|| a.str("option"))
        .or_else(|| a.str("dir"))
        .or_else(|| a.str("question"))
        .map(|s| format!(" {}", s.chars().take(60).collect::<String>()));
    format!("{kind}{}{}{}", target.map(|t| format!(" {t}")).unwrap_or_default(), text.unwrap_or_default(), other.unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_fenced_json() {
        let r = parse("```json\n{\"say\":\"hi\",\"actions\":[{\"do\":\"look\"}],\"done\":false}\n```").unwrap();
        assert_eq!(r["say"], "hi");
        assert_eq!(r["actions"][0]["do"], "look");
    }

    #[test]
    fn bare_action_becomes_envelope() {
        let r = parse(r#"{"do":"ask","question":"Which?"}"#).unwrap();
        assert_eq!(r["actions"][0]["do"], "ask");
        assert_eq!(r["done"], false);
    }

    #[test]
    fn partial_first_action() {
        let t = r#"{"say":"Opening","actions":[{"do":"open_url","url":"https://x.com"},{"do":"cl"#;
        let a = first_action_in_partial(t).unwrap();
        assert_eq!(a["url"], "https://x.com");
        assert!(first_action_in_partial(r#"{"say":"x","actions":[{"do":"open_url","url":"htt"#).is_none());
    }

    #[test]
    fn invoke_tags() {
        let r = parse(r#"<invoke name="scroll"><parameter name="dir">up</parameter></invoke><invoke name="done"><parameter name="say">ok</parameter></invoke>"#).unwrap();
        assert_eq!(r["actions"][0]["dir"], "up");
        assert_eq!(r["done"], true);
        assert_eq!(r["say"], "ok");
    }

    #[test]
    fn strings_with_braces() {
        let t = r#"{"say":"a } b","actions":[{"do":"type","text":"{x}"}],"done":false} trailing {junk"#;
        let r = parse(t).unwrap();
        assert_eq!(r["actions"][0]["text"], "{x}");
    }
}
