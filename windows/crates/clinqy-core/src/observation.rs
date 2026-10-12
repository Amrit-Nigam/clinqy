//! What the model is shown each turn: the front app, its window, the focused element, its controls (e-ids from
//! UI Automation) and, in a browser with the extension, the page (w-ids). Later turns send only what changed.

use crate::page::{self, Page};
use crate::platform::{AppRef, Dialog, Element, Platform, Rect};
use std::collections::HashMap;

#[derive(Clone, Debug, Default)]
pub struct Observation {
    pub app: Option<AppRef>,
    pub elements: Vec<Element>,
    pub fingerprint: u64,
    pub page: Option<Page>,
    pub web_area: Option<Rect>,
    pub window: String,
    pub focused: String,
    pub dialog: Option<Dialog>,
    pub is_browser: bool,
}

/// Elements as "e12 Button: Send" lines within `budget` characters; over budget, whole low-value lines go.
pub fn listing(elements: &[&Element], budget: usize) -> String {
    let lines: Vec<String> = elements
        .iter()
        .map(|e| {
            let value = e
                .value
                .as_ref()
                .filter(|v| e.is_input() && !e.label.contains(v.as_str()))
                .map(|v| format!(" = {:?}", v.chars().take(60).collect::<String>()))
                .unwrap_or_default();
            format!("{} {}: {}{value}", e.id, e.role, e.label)
        })
        .collect();
    let mut total: usize = lines.iter().map(|l| l.len() + 1).sum();
    let mut dropped = std::collections::HashSet::new();
    if total > budget {
        let mut order: Vec<usize> = (0..elements.len()).collect();
        order.sort_by_key(|&i| (priority(elements[i]), std::cmp::Reverse(i)));
        for i in order {
            if total <= budget {
                break;
            }
            dropped.insert(i);
            total -= lines[i].len() + 1;
        }
    }
    let mut text: Vec<String> = lines.iter().enumerate().filter(|(i, _)| !dropped.contains(i)).map(|(_, l)| l.clone()).collect();
    if !dropped.is_empty() {
        text.push(format!("({} less important elements not shown)", dropped.len()));
    }
    text.join("\n")
}

/// How much a line is worth when space runs out: controls over rows over loose text over groups.
pub fn priority(e: &Element) -> i32 {
    let base = match e.role.as_str() {
        "Group" | "Pane" | "Custom" => {
            if e.label.starts_with("(unlabeled") {
                0
            } else {
                1
            }
        }
        "Text" | "Image" => 1,
        "ListItem" | "DataItem" | "TreeItem" | "Header" | "HeaderItem" => 2,
        _ => 3,
    };
    if e.in_dialog {
        base + 10
    } else {
        base
    }
}

impl Observation {
    pub async fn capture(platform: &dyn Platform, preferred: Option<&AppRef>) -> Observation {
        let front = platform.front_app();
        let app = front.or_else(|| preferred.cloned());
        let Some(app) = app else { return Observation::default() };
        let is_browser = platform.is_browser(&app);
        let bridge = crate::bridge::bridge();
        let scanning = platform.scan(&app, 150);
        let (scan, page, area) = if is_browser && bridge.is_connected() {
            let paging = async {
                let mut p = bridge.snapshot(Some(&app.exe)).await;
                // Still arriving (or nothing listed on a page that isn't blocked): give it a moment, once.
                if let Some(pg) = &p {
                    if pg.ready == "loading" || (pg.elements.is_empty() && pg.problem.is_none()) {
                        tokio::time::sleep(std::time::Duration::from_millis(700)).await;
                        if let Some(again) = bridge.snapshot(Some(&app.exe)).await {
                            p = Some(again);
                        }
                    }
                }
                p
            };
            let (scan, page, area) = tokio::join!(scanning, paging, platform.web_area(&app));
            (scan, page, area)
        } else {
            (scanning.await, None, None)
        };
        let web_area = page.as_ref().and_then(|p| area.or(p.estimated_area));
        let page = if web_area.is_some() { page } else { None };
        Observation {
            app: Some(app),
            elements: scan.elements,
            fingerprint: scan.fingerprint,
            page,
            web_area,
            window: scan.window,
            focused: scan.focused,
            dialog: scan.dialog,
            is_browser,
        }
    }

    /// Everything, as on a turn that shows the whole screen.
    pub fn text(&self) -> String {
        self.render(None, None)
    }

    /// The screen for the model. A diff stands in for the element or page list when the model has the last one.
    pub fn render(&self, elements_diff: Option<&str>, page_diff: Option<&str>) -> String {
        let Some(app) = &self.app else { return "No app is frontmost.".into() };
        // With the page covered by the extension, list only the browser's own controls.
        let controls: Vec<&Element> = self.elements.iter().filter(|e| self.web_area.map(|w| !w.contains(e.rect.center())).unwrap_or(true)).collect();
        let list = listing(&controls, 8000);
        let mut text = format!(
            "Frontmost app: {}{}\nWindow: {}",
            app.name,
            if self.is_browser { " (browser)" } else { "" },
            if self.window.is_empty() { "(none)" } else { &self.window }
        );
        if let Some(d) = &self.dialog {
            text += &format!(
                "\nDialog: a {} is open{} — its controls are listed first",
                d.kind,
                if d.title.is_empty() { String::new() } else { format!(": “{}”", d.title) }
            );
        }
        text += &format!("\nFocused: {}\n", self.focused);
        if let Some(diff) = elements_diff {
            text += &format!(
                "Element changes since your last look (e-ids unchanged; + new, - gone, ~ changed):\n{}",
                if diff.is_empty() { "(none)" } else { diff }
            );
        } else {
            text += &format!(
                "{}:\n{}",
                if self.page.is_some() { "Browser controls" } else { "Elements" },
                if list.is_empty() { "(none readable — ask to look)".to_string() } else { list }
            );
        }
        if let Some(p) = &self.page {
            text += &format!(
                "\n\nWeb page (via extension; use w-ids for anything on the page): {}\nURL: {}\nScroll: {} of {}",
                p.title, p.url, p.scroll_y as i64, p.scroll_max as i64
            );
            if let Some(diff) = page_diff {
                text += &format!(
                    "\nPage changes since your last look (w-ids unchanged; + new, - gone, ~ changed):\n{}",
                    if diff.is_empty() { "(none)" } else { diff }
                );
            } else {
                if !p.headings.is_empty() {
                    text += &format!("\nHeadings: {}", p.headings.join(" | "));
                }
                text += &format!("\n{}", p.list());
                if !p.messages.is_empty() {
                    text += &format!("\nMessages on the page: {}", p.messages.iter().map(|m| format!("“{m}”")).collect::<Vec<_>>().join(" · "));
                }
            }
            if p.above + p.below > 0 {
                text += &format!("\nNot shown (scroll to reach): {} fields/buttons above, {} below.", p.above, p.below);
            }
            if let Some(panes) = p.pane_summary() {
                text += &format!("\nScrolled out of view {panes}.");
            }
            if !p.text.is_empty() {
                text += &format!("\nText on screen: {}", p.text);
            }
            if p.ready == "loading" {
                text += "\n(The page is still loading.)";
            }
            if let Some(problem) = &p.problem {
                text += &format!("\n(Couldn't read the page: {problem}. Use look and click by position, or read.)");
            }
        } else if self.is_browser {
            text += "\n(Browser extension not connected: page content comes from UI Automation only. To connect it, load the extension folder from Clinqy's install folder in the browser's extensions page.)";
        }
        text
    }
}

/// The screen as changes since `before`, or None when it must be listed in full.
pub fn screen_text(obs: &Observation, before: Option<&Observation>) -> Option<String> {
    let before = before?;
    let app = obs.app.as_ref()?;
    if before.app.as_ref().map(|a| a.pid) != Some(app.pid) {
        return None;
    }
    if !(before.window == obs.window || (obs.page.is_some() && before.page.is_some())) {
        return None;
    }
    if before.dialog.as_ref().map(|d| &d.title) != obs.dialog.as_ref().map(|d| &d.title) {
        return None;
    }
    if let Some(p) = &obs.page {
        let prev = before.page.as_ref()?;
        let d = page::diff(prev, p)?;
        return Some(obs.render(None, Some(&d)));
    }
    if before.page.is_some() {
        return None;
    }
    let d = listing_update(&before.elements, &obs.elements, 40)?;
    Some(obs.render(Some(&d), None))
}

/// Changes between two element lists, keyed by stable ref, or None when positional ids moved (a diff would send
/// clicks to the wrong place) or too much changed. "" = nothing changed.
pub fn listing_update(before: &[Element], after: &[Element], limit: usize) -> Option<String> {
    let key = |e: &Element| if e.stable.is_empty() { format!("{}|{}", e.role, e.label) } else { e.stable.clone() };
    let mut ids: HashMap<String, &str> = HashMap::new();
    for e in before {
        ids.entry(key(e)).or_insert(&e.id);
    }
    if after.iter().any(|e| ids.get(&key(e)).map(|id| *id != e.id).unwrap_or(false)) {
        return None;
    }
    let old: HashMap<String, &Element> = before.iter().map(|e| (key(e), e)).collect();
    let new: std::collections::HashSet<String> = after.iter().map(key).collect();
    let q = |s: Option<&str>| format!("'{}'", s.unwrap_or("").chars().take(50).collect::<String>());
    let mut lines = vec![];
    let mut count = 0;
    for e in after {
        match old.get(&key(e)) {
            None => {
                lines.push(format!("+ {} {} {}", e.id, e.role, q(Some(&e.label))));
                count += 1;
            }
            Some(was) => {
                let mut f = vec![];
                if was.label != e.label && !(was.value != e.value && was.label.starts_with("(unlabeled")) {
                    f.push(format!("label {}→{}", q(Some(&was.label)), q(Some(&e.label))));
                }
                if was.value != e.value {
                    f.push(format!("value {}→{}", q(was.value.as_deref()), q(e.value.as_deref())));
                }
                if !f.is_empty() {
                    lines.push(format!("~ {} {} {}", e.id, e.role, f.join(", ")));
                    count += 1;
                }
            }
        }
    }
    for e in before.iter().filter(|e| !new.contains(&key(e))) {
        lines.push(format!("- {} {} {}", e.id, e.role, q(Some(&e.label))));
        count += 1;
    }
    let total = before.len().max(after.len());
    if count > limit || (total >= 6 && count as f64 > total as f64 * 0.5) {
        return None;
    }
    Some(lines.join("\n"))
}

/// Finds an element by positional id ("e12") or stable ref.
pub fn lookup<'a>(id: &str, elements: &'a [Element]) -> Option<&'a Element> {
    let key = id.trim().trim_matches('#');
    elements.iter().find(|e| e.stable == key).or_else(|| elements.iter().find(|e| e.id.eq_ignore_ascii_case(key)))
}

/// The same control in a fresh scan: same ref, else the nearest sharing its ref base.
pub fn twin<'a>(wanted: &Element, elements: &'a [Element]) -> Option<&'a Element> {
    if !wanted.stable.is_empty() {
        if let Some(e) = elements.iter().find(|e| e.stable == wanted.stable) {
            return Some(e);
        }
    }
    let base = wanted.stable.split('~').next().unwrap_or("");
    if base.is_empty() {
        return None;
    }
    let near = |e: &Element| e.rect.center().distance(wanted.rect.center());
    elements.iter().filter(|e| e.stable.starts_with(base)).min_by(|a, b| near(a).partial_cmp(&near(b)).unwrap_or(std::cmp::Ordering::Equal))
}

/// Loose text comparison that tolerates autocorrect, case and punctuation.
pub fn similar(have: &str, want: &str) -> bool {
    let clean = |s: &str| s.to_lowercase().chars().filter(|c| c.is_alphanumeric()).collect::<Vec<char>>();
    let (w, h) = (clean(want), clean(have));
    if w.is_empty() {
        return true;
    }
    let hs: String = h.iter().collect();
    let ws: String = w.iter().collect();
    if hs.contains(&ws) {
        return true;
    }
    let tail = &h[h.len().saturating_sub(w.len())..];
    let common = w.iter().zip(tail.iter()).filter(|(a, b)| a == b).count();
    common as f64 / w.len() as f64 >= 0.85
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn similar_tolerates() {
        assert!(similar("Hello, World!", "hello world"));
        assert!(similar("anything", ""));
        assert!(!similar("abc", "xyz123"));
    }
}
