//! A web page as the browser extension reports it: elements with stable w-ids, values and state flags, messages,
//! visible text. Plus the compact diff between two listings that later turns send instead of the whole list.

use crate::platform::Rect;
use serde_json::Value;
use std::collections::{HashMap, HashSet};

#[derive(Clone, Debug, Default)]
pub struct PageElement {
    pub index: i64,
    pub role: String,
    pub text: String,
    /// In page viewport (CSS pixel) coordinates.
    pub rect: Rect,
    pub editable: bool,
    pub extra: String,
    /// What the element is on its page (role, name, question, frame); its w-id stays while this does.
    pub key: String,
    pub value: Option<String>,
    pub flags: HashSet<String>,
    pub question: Option<String>,
    pub placeholder: Option<String>,
    pub options: Vec<String>,
    pub dropdown: bool,
}

#[derive(Clone, Debug, Default)]
pub struct Pane {
    pub name: String,
    pub modal: bool,
    pub above: i64,
    pub below: i64,
}

#[derive(Clone, Debug, Default)]
pub struct Page {
    pub connection: u64,
    pub url: String,
    pub title: String,
    pub viewport: (f64, f64),
    pub scroll_y: f64,
    pub scroll_max: f64,
    pub headings: Vec<String>,
    pub elements: Vec<PageElement>,
    pub messages: Vec<String>,
    pub text: String,
    pub above: i64,
    pub below: i64,
    pub ready: String,
    pub problem: Option<String>,
    /// The viewport's screen rect estimated from window geometry (when Automation can't say).
    pub estimated_area: Option<Rect>,
    pub panes: Vec<Pane>,
    pub tab_id: Option<i64>,
    /// Read by tab id: commands go to that tab even in the background.
    pub pinned: bool,
    pub document_id: Option<String>,
    pub snapshot_id: Option<String>,
}

fn num(v: &Value) -> f64 {
    v.as_f64().unwrap_or(0.0)
}

impl Page {
    pub fn parse(r: &Value, connection: u64) -> Page {
        let els = r["elements"].as_array().cloned().unwrap_or_default();
        let elements = els
            .iter()
            .map(|e| {
                let mut extra: Vec<String> = vec![];
                if let Some(q) = e["q"].as_str() {
                    extra.push(format!("in “{q}”"));
                }
                if let Some(f) = e["frame"].as_str() {
                    extra.push(format!("inside {f}"));
                }
                if e["dropdown"] == true {
                    extra.push("dropdown".into());
                }
                if let Some(v) = e["value"].as_str() {
                    extra.push(format!("value={v:?}"));
                }
                if let Some(p) = e["placeholder"].as_str() {
                    if e["text"].as_str() != Some(p) {
                        extra.push(format!("placeholder={p:?}"));
                    }
                }
                if let Some(o) = e["options"].as_str() {
                    extra.push(format!("options: {o}"));
                }
                let flags: Vec<String> = ["required", "invalid", "focused", "checked", "unchecked", "selected", "disabled", "covered"]
                    .iter()
                    .filter(|f| e[**f] == true)
                    .map(|f| f.to_string())
                    .collect();
                extra.extend(flags.iter().cloned());
                if let Some(h) = e["href"].as_str() {
                    extra.push(format!("→ {h}"));
                }
                let role = e["role"].as_str().unwrap_or("?").to_string();
                let text = e["text"].as_str().unwrap_or("").to_string();
                let key = format!(
                    "{}|{}",
                    e["frame"].as_str().unwrap_or(""),
                    e["key"].as_str().map(String::from).unwrap_or_else(|| format!("{role}|{text}"))
                );
                PageElement {
                    index: e["i"].as_i64().unwrap_or(0),
                    role,
                    text,
                    rect: Rect::new(num(&e["x"]), num(&e["y"]), num(&e["w"]), num(&e["h"])),
                    editable: e["editable"] == true,
                    extra: extra.join(" "),
                    key,
                    value: e["value"].as_str().map(String::from),
                    flags: flags.into_iter().collect(),
                    question: e["q"].as_str().map(String::from),
                    placeholder: e["placeholder"].as_str().map(String::from),
                    options: e["options"].as_str().map(|o| o.split(" | ").map(String::from).collect()).unwrap_or_default(),
                    dropdown: e["dropdown"] == true,
                }
            })
            .collect();
        let panes = r["panes"]
            .as_array()
            .map(|a| {
                a.iter()
                    .map(|p| Pane {
                        name: p["name"].as_str().unwrap_or("").into(),
                        modal: p["modal"] == true,
                        above: p["above"].as_i64().unwrap_or(0),
                        below: p["below"].as_i64().unwrap_or(0),
                    })
                    .collect()
            })
            .unwrap_or_default();
        Page {
            connection,
            url: r["url"].as_str().unwrap_or("").into(),
            title: r["title"].as_str().unwrap_or("").into(),
            viewport: (r["viewport"]["w"].as_f64().unwrap_or(1.0), r["viewport"]["h"].as_f64().unwrap_or(1.0)),
            scroll_y: num(&r["scroll"]["y"]),
            scroll_max: num(&r["scroll"]["max"]),
            headings: str_list(&r["headings"]),
            elements,
            messages: str_list(&r["messages"]),
            text: r["text"].as_str().unwrap_or("").into(),
            above: r["above"].as_i64().unwrap_or(0),
            below: r["below"].as_i64().unwrap_or(0),
            ready: r["ready"].as_str().unwrap_or("complete").into(),
            problem: r["error"].as_str().map(String::from),
            estimated_area: estimate(r),
            panes,
            tab_id: r["tabId"].as_i64(),
            pinned: false,
            document_id: r["documentID"].as_str().map(String::from),
            snapshot_id: r["snapshotID"].as_str().map(String::from),
        }
    }

    pub fn element(&self, index: i64) -> Option<&PageElement> {
        self.elements.iter().find(|e| e.index == index)
    }

    /// The page's element list as the model reads it.
    pub fn list(&self) -> String {
        let items: Vec<String> = self.elements.iter().map(|e| e.line()).collect();
        format!("Page elements (visible part):\n{}", if items.is_empty() { "(none)".into() } else { items.join("\n") })
    }

    /// Scrolling boxes with fields out of view: "in the “Apply” dialog: 0 above, 4 below (scroll moves the dialog)".
    pub fn pane_summary(&self) -> Option<String> {
        let parts: Vec<String> = self
            .panes
            .iter()
            .filter(|p| p.above + p.below > 0)
            .map(|p| {
                let name = if p.name.is_empty() {
                    if p.modal { "the dialog".to_string() } else { "a scrolling panel".to_string() }
                } else {
                    format!("the “{}” {}", p.name, if p.modal { "dialog" } else { "panel" })
                };
                format!("in {name}: {} above, {} below{}", p.above, p.below, if p.modal { " (scroll moves the dialog)" } else { "" })
            })
            .collect();
        (!parts.is_empty()).then(|| parts.join("; "))
    }
}

impl PageElement {
    pub fn line(&self) -> String {
        format!("w{} {}: {}{}", self.index, self.role, self.text, if self.extra.is_empty() { String::new() } else { format!(" [{}]", self.extra) })
    }

    /// What identifies it across listings (never its value).
    pub fn signature(&self) -> String {
        if !self.key.is_empty() {
            return self.key.clone();
        }
        let q = self.question.clone().unwrap_or_default();
        format!("{}|{}|{q}", self.role, self.text)
    }

    pub fn has_flag(&self, f: &str) -> bool {
        self.flags.contains(f)
    }
}

fn str_list(v: &Value) -> Vec<String> {
    v.as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default()
}

/// The viewport sits at the bottom of the window, flush with its sides: window origin plus the difference between
/// outer and inner size. Screen values from the extension are CSS pixels; `dpr` scales them to physical.
fn estimate(r: &Value) -> Option<Rect> {
    let sc = &r["screen"];
    let vp = &r["viewport"];
    let (x, y, ow, oh) = (sc["x"].as_f64()?, sc["y"].as_f64()?, sc["ow"].as_f64()?, sc["oh"].as_f64()?);
    let (vw, vh) = (vp["w"].as_f64()?, vp["h"].as_f64()?);
    if vw <= 0.0 || vh <= 0.0 {
        return None;
    }
    // `zoom` is the page's devicePixelRatio: screen scaling (times page zoom, which is rarely set).
    let dpr = sc["zoom"].as_f64().unwrap_or(1.0).max(0.5);
    Some(Rect::new((x + (ow - vw).max(0.0) / 2.0) * dpr, (y + (oh - vh).max(0.0)) * dpr, vw * dpr, vh * dpr))
}

/// Same document: origin and path (a changed query or #hash on a single-page app is still the same page).
pub fn same_page(a: &str, b: &str) -> bool {
    match (url::Url::parse(a), url::Url::parse(b)) {
        (Ok(x), Ok(y)) => x.scheme() == y.scheme() && x.host_str() == y.host_str() && x.port() == y.port() && x.path() == y.path(),
        _ => a == b,
    }
}

/// Compact changes from `previous` to `current` ("+ w12 button: Next", "- w7 link: Jobs", "~ w3 value … → …").
/// "" = nothing changed; None = too different for a diff to help (send the full list).
pub fn diff(previous: &Page, current: &Page) -> Option<String> {
    if previous.connection != current.connection
        || previous.tab_id != current.tab_id
        || previous.document_id != current.document_id
        || previous.problem.is_some()
        || current.problem.is_some()
        || !same_page(&previous.url, &current.url)
    {
        return None;
    }
    let old: HashMap<i64, &PageElement> = previous.elements.iter().map(|e| (e.index, e)).collect();
    let new: HashMap<i64, &PageElement> = current.elements.iter().map(|e| (e.index, e)).collect();
    let line = |e: &PageElement| {
        format!(
            "w{} {}: {}{}",
            e.index,
            e.role,
            e.text,
            if e.extra.is_empty() { String::new() } else { format!(" [{}]", e.extra.chars().take(160).collect::<String>()) }
        )
    };
    let (mut added, mut removed, mut changed) = (vec![], vec![], vec![]);
    for e in &current.elements {
        match old.get(&e.index) {
            Some(was) if was.key == e.key => {
                let mut what = vec![];
                if was.value != e.value {
                    what.push(format!("value {:?} → {:?}", was.value.clone().unwrap_or_default(), e.value.clone().unwrap_or_default()));
                }
                for flag in ["checked", "selected", "covered", "disabled", "invalid", "focused"] {
                    if was.has_flag(flag) != e.has_flag(flag) {
                        what.push(if e.has_flag(flag) { format!("now {flag}") } else { format!("no longer {flag}") });
                    }
                }
                if !what.is_empty() {
                    changed.push(format!("~ w{} {} {:?}: {}", e.index, e.role, e.text.chars().take(40).collect::<String>(), what.join(", ")));
                }
            }
            _ => added.push(format!("+ {}", line(e))),
        }
    }
    for e in &previous.elements {
        if new.get(&e.index).map(|n| n.key != e.key).unwrap_or(true) {
            removed.push(format!("- w{} {}: {}", e.index, e.role, e.text.chars().take(60).collect::<String>()));
        }
    }
    let total = previous.elements.len().max(current.elements.len());
    if total >= 6 && (added.len() + removed.len() + changed.len()) as f64 > total as f64 * 0.5 {
        return None;
    }
    let mut out: Vec<String> = removed.into_iter().chain(added).chain(changed).collect();
    if previous.headings != current.headings && !current.headings.is_empty() {
        out.push(format!("headings now: {}", current.headings.join(" | ")));
    }
    for m in &current.messages {
        if !previous.messages.contains(m) {
            out.push(format!("! message: “{m}”"));
        }
    }
    for m in &previous.messages {
        if !current.messages.contains(m) {
            out.push(format!("message gone: “{m}”"));
        }
    }
    if previous.above != current.above || previous.below != current.below {
        out.push(format!("not shown now: {} fields/buttons above, {} below", current.above, current.below));
    }
    Some(out.join("\n"))
}

/// The index in `now` of the element listed as `index` in `seen`: the same index while it's the same element,
/// else the nearest one with the same identity; None = it's gone.
pub fn rematch(index: i64, seen: &Page, now: &Page) -> Option<i64> {
    let old = seen.element(index)?;
    let want = old.signature();
    if let Some(same) = now.element(index) {
        if same.signature() == want {
            return Some(index);
        }
    }
    let far = |e: &PageElement| (e.rect.mid_x() - old.rect.mid_x()).hypot(e.rect.mid_y() - old.rect.mid_y());
    now.elements
        .iter()
        .filter(|e| e.signature() == want)
        .min_by(|a, b| far(a).partial_cmp(&far(b)).unwrap_or(std::cmp::Ordering::Equal))
        .map(|e| e.index)
}

pub fn is_new_tab_page(url: &str) -> bool {
    url.is_empty()
        || url == "about:blank"
        || ["chrome://newtab", "chrome://new-tab-page", "edge://newtab", "brave://newtab", "arc://newtab", "vivaldi://newtab", "opera://startpage"]
            .iter()
            .any(|p| url.starts_with(p))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn page(els: Value) -> Page {
        Page::parse(&json!({"url": "https://a.com/x", "title": "T", "viewport": {"w": 1000, "h": 800}, "elements": els}), 1)
    }

    #[test]
    fn diff_reports_changes() {
        let a = page(json!([{"i":0,"role":"textbox","text":"Name","key":"k0"},{"i":1,"role":"button","text":"Next","key":"k1"},
            {"i":2,"role":"link","text":"A","key":"k2"},{"i":3,"role":"link","text":"B","key":"k3"},{"i":4,"role":"link","text":"C","key":"k4"},
            {"i":5,"role":"link","text":"D","key":"k5"}]));
        let b = page(json!([{"i":0,"role":"textbox","text":"Name","key":"k0","value":"Amrit"},{"i":1,"role":"button","text":"Next","key":"k1"},
            {"i":2,"role":"link","text":"A","key":"k2"},{"i":3,"role":"link","text":"B","key":"k3"},{"i":4,"role":"link","text":"C","key":"k4"},
            {"i":6,"role":"link","text":"E","key":"k6"}]));
        let d = diff(&a, &b).unwrap();
        assert!(d.contains("- w5 link: D"));
        assert!(d.contains("+ w6 link: E"));
        assert!(d.contains("~ w0 textbox \"Name\": value \"\" → \"Amrit\""));
    }

    #[test]
    fn rematches_by_identity() {
        let a = page(json!([{"i":3,"role":"button","text":"Next","key":"n","x":10,"y":10,"w":5,"h":5}]));
        let b = page(json!([{"i":7,"role":"button","text":"Next","key":"n","x":12,"y":10,"w":5,"h":5}]));
        assert_eq!(rematch(3, &a, &b), Some(7));
    }
}
