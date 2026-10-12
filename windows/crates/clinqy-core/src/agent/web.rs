//! Actions inside web pages, through the browser extension: clicks that check themselves (a real mouse click,
//! then a click through the page, then focus + a key), typing that survives autofill, dropdowns, uploads,
//! autofill from the job profile, and the review card before a form's final Submit.

use super::act::is_form_submit;
use super::run::{ActionResult, Ctx, RunState};
use super::*;
use crate::bridge::bridge;
use crate::observation::similar;
use crate::page::{self, Page, PageElement};
use crate::platform::{Point, Rect};
use crate::reply::{Action, ActionExt};
use serde_json::json;

impl Agent {
    /// A page element by its w-id, with its rect on screen.
    pub(crate) fn web_target(&self, n: i64, ctx: &Ctx, rs: &mut RunState) -> Option<(PageElement, Rect)> {
        let (page, web) = (ctx.page.as_ref()?, ctx.web_area?);
        let el = page.element(n)?.clone();
        let (sx, sy) = (web.w / page.viewport.0, web.h / page.viewport.1);
        let rect = Rect::new(web.x + el.rect.x * sx, web.y + el.rect.y * sy, el.rect.w * sx, el.rect.h * sy);
        rs.last_target = Some(Target { kind: "web".into(), role: el.role.clone(), label: el.text.clone() });
        let clipped = rect.intersection(&web);
        Some((el, if clipped.is_empty() { rect } else { clipped }))
    }

    /// `web_target`, checked against the live page: when the page re-rendered the element past what the extension
    /// can re-find, the page is listed again and the same element used. None = it's really gone.
    async fn live_target(&self, n: i64, ctx: &mut Ctx, rs: &mut RunState) -> Option<(PageElement, Rect)> {
        let (el, rect) = self.web_target(n, ctx, rs)?;
        let page = ctx.page.clone()?;
        match bridge().perform("alive", &page, json!({"index": el.index}), 4.0).await {
            Ok(r) if r["ok"] == false => {}
            _ => return Some((el, rect)),
        }
        self.relist(ctx).await;
        let now = ctx.page.clone()?;
        let far = |e: &PageElement| (e.rect.mid_x() - el.rect.mid_x()).hypot(e.rect.mid_y() - el.rect.mid_y());
        let index = page::rematch(el.index, &page, &now).or_else(|| {
            now.elements
                .iter()
                .filter(|e| e.role == el.role && similar(&e.text, &el.text))
                .min_by(|a, b| far(a).partial_cmp(&far(b)).unwrap())
                .map(|e| e.index)
        });
        match index.and_then(|i| self.web_target(i, ctx, rs)) {
            Some(found) => {
                self.log(&format!("    w{} was re-rendered: acting on w{} ({} {:?})", el.index, found.0.index, found.0.role, found.0.text.chars().take(40).collect::<String>()));
                Some(found)
            }
            None => {
                self.log(&format!("    w{} ({} {:?}) is gone and nothing like it is listed now", el.index, el.role, el.text.chars().take(40).collect::<String>()));
                None
            }
        }
    }

    fn gone(&self, action: &Action) -> String {
        format!(
            "page element {} isn't on the page any more and nothing like it is listed now (the page changed); look again",
            action.get("id").map(|v| v.as_str().unwrap_or("?").to_string()).unwrap_or_default()
        )
    }

    /// The point to click on a page element: where it is now, on a spot nothing covers.
    async fn aim(&self, page: &Page, el: &PageElement, rect: Rect, ctx: &Ctx) -> (Point, bool) {
        let mut point = rect.center();
        let mut mouse = true;
        if let (Ok(spot), Some(web)) = (bridge().perform("locate", page, json!({"index": el.index}), 4.0).await, ctx.web_area) {
            if let Some(hit) = spot["hit"].as_bool() {
                let d = |k: &str| spot[k].as_f64();
                let (sx, sy) = (web.w / page.viewport.0, web.h / page.viewport.1);
                let px = d("px").unwrap_or(d("x").unwrap_or(0.0) + d("w").unwrap_or(0.0) / 2.0);
                let py = d("py").unwrap_or(d("y").unwrap_or(0.0) + d("h").unwrap_or(0.0) / 2.0);
                point = Point::new(web.x + px * sx, web.y + py * sy);
                mouse = hit && web.contains(point);
            }
        }
        (point, mouse)
    }

    pub(crate) async fn open_url(&self, action: &Action, ctx: &mut Ctx, rs: &mut RunState) -> ActionResult {
        let Some(raw) = action.str("url") else { return ActionResult::fail("bad url") };
        let url_s = if raw.contains("://") { raw.to_string() } else { format!("https://{raw}") };
        let Ok(url) = url::Url::parse(&url_s) else { return ActionResult::fail("bad url") };
        let host = url.host_str().unwrap_or(raw).replace("www.", "");
        let line = self.begin(&format!("Go to {host}"));
        let b = bridge();
        // QA tests always load the page fresh.
        if rs.qa {
            if let Some(page) = &ctx.page {
                if page.url.starts_with(url.as_str()) || url.as_str().starts_with(&page.url) {
                    if let Some(tab) = b.active_tab(ctx.app.as_ref().map(|a| a.exe.as_str())).await {
                        b.tab_command("navigate", &tab, json!({"url": url.as_str()})).await;
                        tokio::time::sleep(Duration::from_millis(1200)).await;
                        self.refresh(ctx).await;
                        return self.end(line, ActionResult::ok(format!("reloaded {url}")));
                    }
                }
            }
        }
        if !rs.qa {
            if let Some(page) = &ctx.page {
                if page.url.contains(&host) && (url.path().len() <= 1 || page.url.contains(url.path())) {
                    return self.end(line, ActionResult::ok(format!("already on {}", page.url)));
                }
            }
        }
        // Never take over one of the user's tabs: reuse only a tab this task opened, or an empty new-tab page.
        let current_browser = ctx.app.clone().filter(|a| self.platform.is_browser(a));
        let before = match &current_browser {
            Some(a) => b.active_tab(Some(&a.exe)).await,
            None => None,
        };
        let empty = before.as_ref().map(|t| page::is_new_tab_page(&t.url)).unwrap_or(false);
        let host_of = |u: &str| url::Url::parse(u).ok().and_then(|u| u.host_str().map(|h| h.replace("www.", ""))).unwrap_or_default();
        let same_site = before.as_ref().map(|t| !host_of(&t.url).is_empty() && host_of(&t.url) == host).unwrap_or(false);
        let reuse = before.is_some() && (empty || (before.as_ref().map(|t| Some(t.id)) == Some(rs.owned_tab) && same_site));
        let browser = self.platform.open_url(url.as_str(), ctx.app.as_ref(), !reuse).await;
        rs.opened_tab = true;
        let exe = browser.as_ref().or(ctx.app.as_ref()).map(|a| a.exe.clone());
        if let (Some(before), Some(after)) = (&before, b.active_tab(exe.as_deref()).await) {
            self.log(&format!("    tab: {} · before #{} {} · now #{}", if reuse { "reused" } else { "new" }, before.id, before.url.chars().take(50).collect::<String>(), after.id));
            if !reuse && after.id == before.id && !page::is_new_tab_page(&before.url) {
                self.log("    tab: the user's tab was changed — restoring it and opening a separate tab");
                b.tab_command("goBack", &after, json!({"tabId": after.id})).await;
                rs.owned_tab = b.tab_command("newTab", &after, json!({"url": url.as_str()})).await.and_then(|r| r["id"].as_i64());
                tokio::time::sleep(Duration::from_millis(1200)).await;
            } else {
                rs.owned_tab = Some(after.id);
            }
        } else if let Some(after) = b.active_tab(exe.as_deref()).await {
            rs.owned_tab = Some(after.id);
        }
        ctx.app = browser.or_else(|| self.platform.front_app());
        self.refresh(ctx).await;
        // The typed address went astray: go there directly (only ever in our own tab).
        if let Some(page) = &ctx.page {
            if !page.url.contains(&host) {
                if let Some(tab) = b.active_tab(ctx.app.as_ref().map(|a| a.exe.as_str())).await {
                    if Some(tab.id) == rs.owned_tab {
                        b.tab_command("navigate", &tab, json!({"url": url.as_str()})).await;
                    } else {
                        rs.owned_tab = b.tab_command("newTab", &tab, json!({"url": url.as_str()})).await.and_then(|r| r["id"].as_i64());
                    }
                    tokio::time::sleep(Duration::from_millis(1200)).await;
                    self.refresh(ctx).await;
                }
            }
        }
        self.current.lock().opened_last = true;
        let name = ctx.app.as_ref().map(|a| a.name.clone()).unwrap_or_else(|| "the browser".into());
        self.end(line, ActionResult::ok(format!("opened {url} in {name}")))
    }

    pub(crate) async fn web_click(&self, action: &Action, ctx: &mut Ctx, rs: &mut RunState) -> ActionResult {
        let Some(n) = super::run::web_index(action.get("id")) else { return ActionResult::fail("bad id") };
        let Some((el, rect)) = self.live_target(n, ctx, rs).await else { return ActionResult::fail(self.gone(action)) };
        let line = self.begin(&format!("Click {}", el.text.chars().take(32).collect::<String>()));
        let submits = is_form_submit(&el.text) || crate::safety::needs_confirmation(&el.text, &rs.request).is_some();
        if let Some(why) = self.approve(&el.text, &el.role, ctx, rs).await {
            return self.end(line, ActionResult::fail(why));
        }
        if let Some(app) = &ctx.app {
            self.platform.bring_to_front(app).await;
        }
        let page = ctx.page.clone().unwrap();
        let host = crate::clicks::host(&page.url);
        let b = bridge();
        let state = || async { b.perform("state", &page, json!({"index": el.index}), 3.0).await.ok().and_then(|r| r["sig"].as_str().map(String::from)) };
        let before = state().await;
        // Real mouse first (many sites ignore script clicks); each way is checked for an effect before the next.
        let (point, mut mouse) = self.aim(&page, &el, rect, ctx).await;
        let pid = ctx.app.as_ref().map(|a| a.pid).unwrap_or(0);
        if mouse {
            if let Some(why) = self.platform.hit_mismatch(point, pid) {
                self.log(&format!("    {why} — clicking through the page"));
                mouse = false;
            }
        }
        let mut order: Vec<&str> = if mouse { vec!["mouse", "script"] } else { vec!["script"] };
        if mouse && crate::clicks::prefers_script(&host) {
            order = vec!["script", "mouse"];
        }
        let (mut method, mut worked, mut tries) = (String::new(), false, 0u32);
        let (mut mouse_tried, mut mouse_worked, mut script_worked) = (false, false, false);
        for way in order {
            tries += 1;
            method = way.to_string();
            if way == "mouse" {
                mouse_tried = true;
                if let Err(why) = self.platform.click_at(point, Some(pid)).await {
                    self.log(&format!("    mouse: {why}"));
                    continue;
                }
            } else if let Err(e) = b.perform("click", &page, json!({"index": el.index}), 4.0).await {
                return self.end(line, ActionResult::fail(e.to_string()));
            }
            worked = match &before {
                None => true,
                Some(b0) => {
                    let mut w = false;
                    for k in 0..4 {
                        if state().await.as_ref() != Some(b0) {
                            w = true;
                            break;
                        }
                        if k < 3 {
                            tokio::time::sleep(Duration::from_millis(120)).await;
                        }
                    }
                    w
                }
            };
            if way == "mouse" {
                mouse_worked = worked;
            } else {
                script_worked = worked;
            }
            if worked {
                break;
            }
        }
        let keyable = ["checkbox", "radio", "switch", "tab", "option", "menuitemcheckbox", "menuitemradio", "treeitem"];
        if !worked && !submits && keyable.contains(&el.role.as_str()) {
            if let Ok(r) = b.perform("focusFor", &page, json!({"index": el.index}), 3.0).await {
                if r["focused"] == true {
                    tries += 1;
                    method = "key".into();
                    let key = if ["checkbox", "switch", "menuitemcheckbox", "radio"].contains(&el.role.as_str()) { "space" } else { "enter" };
                    let _ = self.platform.press(key);
                    tokio::time::sleep(Duration::from_millis(150)).await;
                    worked = state().await != before;
                }
            }
        }
        crate::clicks::note(&host, mouse_tried, mouse_worked, script_worked);
        self.log(&crate::clicks::line("web", &host, &method, worked, tries));
        self.buddy.clear_highlight();
        self.end(
            line,
            ActionResult::ok(format!(
                "clicked {} {:?} on the page{}",
                el.role,
                el.text.chars().take(60).collect::<String>(),
                if worked { "" } else { " (nothing on the page visibly changed, even after trying other ways to click it)" }
            )),
        )
    }

    /// A dropdown in one step: open it with a real click (typing to filter a search box), find the option by its
    /// text, click it, then check the field shows it.
    pub(crate) async fn choose(&self, action: &Action, ctx: &mut Ctx) -> ActionResult {
        let Some(want) = action.str("option").or_else(|| action.str("text")).filter(|w| !w.is_empty()).map(String::from) else {
            return ActionResult::fail("choose needs option");
        };
        let mut rs_dummy = RunState::default();
        let Some(n) = super::run::web_index(action.get("id")) else { return ActionResult::fail("bad id") };
        let Some((el, rect)) = self.live_target(n, ctx, &mut rs_dummy).await else { return ActionResult::fail(self.gone(action)) };
        let (Some(page), Some(app), Some(web)) = (ctx.page.clone(), ctx.app.clone(), ctx.web_area) else { return ActionResult::fail(self.gone(action)) };
        let line = self.begin(&format!("Choose “{}”", want.chars().take(40).collect::<String>()));
        self.platform.bring_to_front(&app).await;
        self.buddy.travel(rect.center(), Some(rect)).await;
        let b = bridge();
        let current = || async { b.perform("chosen", &page, json!({"index": el.index}), 3.0).await.ok().and_then(|r| r["value"].as_str().map(String::from)).unwrap_or_default() };
        if el.role == "select" {
            return match b.perform("fill", &page, json!({"index": el.index, "text": want}), 4.0).await {
                Ok(r) => {
                    self.buddy.clear_highlight();
                    self.end(line, ActionResult::ok(format!("chose {:?} in the dropdown", r["value"].as_str().unwrap_or(&want))))
                }
                Err(e) => self.end(line, ActionResult::fail(e.to_string())),
            };
        }
        if similar(&current().await, &want) {
            self.buddy.clear_highlight();
            return self.end(line, ActionResult::ok(format!("{want:?} was already chosen")));
        }
        if let Err(why) = self.platform.click_at(rect.center(), Some(app.pid)).await {
            return self.end(line, ActionResult::fail(why));
        }
        if el.editable {
            tokio::time::sleep(Duration::from_millis(150)).await;
            self.platform.set_target(Some(&app));
            self.platform.enter_text(&want, false).await;
            self.platform.set_target(None);
        }
        let mut option = None;
        for _ in 0..10 {
            tokio::time::sleep(Duration::from_millis(200)).await;
            if let Ok(o) = b.perform("findOption", &page, json!({"text": want, "index": el.index}), 6.0).await {
                let found = o["found"] == true;
                option = Some(o);
                if found {
                    break;
                }
            }
        }
        let picked: String;
        if let Some(o) = option.as_ref().filter(|o| o["found"] == true) {
            let (x, y, w, h) = (o["x"].as_f64().unwrap_or(0.0), o["y"].as_f64().unwrap_or(0.0), o["w"].as_f64().unwrap_or(0.0), o["h"].as_f64().unwrap_or(0.0));
            let (px, py) = (o["px"].as_f64().unwrap_or(x + w / 2.0), o["py"].as_f64().unwrap_or(y + h / 2.0));
            let (sx, sy) = (web.w / page.viewport.0, web.h / page.viewport.1);
            if let Err(why) = self.platform.click_at(Point::new(web.x + px * sx, web.y + py * sy), Some(app.pid)).await {
                let _ = self.platform.press("esc");
                return self.end(line, ActionResult::fail(why));
            }
            picked = o["text"].as_str().unwrap_or(&want).to_string();
            self.log(&crate::clicks::line("option", &crate::clicks::host(&page.url), "mouse", true, 1));
        } else if let Some(via) = self.choose_with_keys(&want, &el, &page).await {
            picked = via;
            self.log(&crate::clicks::line("option", &crate::clicks::host(&page.url), "key", true, 2));
        } else {
            let _ = self.platform.press("esc");
            self.log(&crate::clicks::line("option", &crate::clicks::host(&page.url), "none", false, 2));
            let seen: Vec<String> = option.as_ref().and_then(|o| o["options"].as_array()).map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
            return self.end(line, ActionResult::fail(format!("no option like {want:?}{}", if seen.is_empty() { " appeared".to_string() } else { format!("; the options are: {}", seen.join(" | ")) })));
        }
        tokio::time::sleep(Duration::from_millis(350)).await;
        let now = current().await;
        self.buddy.clear_highlight();
        let shows = now.to_lowercase();
        let shows = shows.trim();
        if !now.is_empty() && !similar(&now, &picked) && !shows.contains(&picked.to_lowercase()) && !picked.to_lowercase().starts_with(shows) && !similar(&now, &want) {
            return self.end(line, ActionResult::fail(format!("clicked {picked:?} but the field shows {now:?}")));
        }
        self.end(line, ActionResult::ok(format!("chose {picked:?}{}", if now.is_empty() { String::new() } else { format!(" (field shows {now:?})") })))
    }

    /// Picks a dropdown option with the arrow keys when the list can't be clicked.
    async fn choose_with_keys(&self, want: &str, el: &PageElement, page: &Page) -> Option<String> {
        let b = bridge();
        if b.perform("focusFor", page, json!({"index": el.index}), 3.0).await.ok()?["focused"] != true {
            return None;
        }
        let (mut last, mut repeats) = (String::new(), 0);
        for k in 0..60 {
            let _ = self.platform.press("down");
            tokio::time::sleep(Duration::from_millis(70)).await;
            let r = b.perform("activeOption", page, json!({"index": el.index, "want": want}), 3.0).await.ok()?;
            let text = r["text"].as_str().unwrap_or("").to_string();
            if text.is_empty() {
                if k >= 2 {
                    return None;
                }
                continue;
            }
            if r["score"].as_f64().unwrap_or(0.0) >= 0.5 {
                let _ = self.platform.press("enter");
                return Some(text);
            }
            repeats = if text == last { repeats + 1 } else { 0 };
            if repeats >= 2 {
                return None;
            }
            last = text;
        }
        None
    }

    pub(crate) async fn web_type(&self, action: &Action, ctx: &mut Ctx) -> ActionResult {
        let Some(text) = action.str("text").map(String::from) else { return ActionResult::fail("type needs text") };
        let mut rs_dummy = RunState::default();
        let Some(n) = super::run::web_index(action.get("id")) else { return ActionResult::fail("bad id") };
        let Some((el, rect)) = self.live_target(n, ctx, &mut rs_dummy).await else { return ActionResult::fail(self.gone(action)) };
        let (Some(page), Some(app)) = (ctx.page.clone(), ctx.app.clone()) else { return ActionResult::fail(self.gone(action)) };
        let submit = action.flag("submit");
        let line = self.begin(&format!("Type “{}”", text.chars().take(40).collect::<String>()));
        self.platform.bring_to_front(&app).await;
        self.buddy.travel(rect.center(), Some(rect)).await;
        self.buddy.click();
        let b = bridge();
        if el.role == "select" {
            return match b.perform("fill", &page, json!({"index": el.index, "text": text}), 4.0).await {
                Ok(r) => {
                    self.buddy.clear_highlight();
                    self.end(line, ActionResult::ok(format!("chose {:?} in the dropdown", r["value"].as_str().unwrap_or(&text))))
                }
                Err(e) => self.end(line, ActionResult::fail(e.to_string())),
            };
        }
        // Keep the browser's autocomplete list from opening over the field, then click into it for real.
        let _ = b.perform("prepare", &page, json!({"index": el.index}), 3.0).await;
        if let Err(why) = self.platform.click_at(rect.center(), Some(app.pid)).await {
            return self.end(line, ActionResult::fail(why));
        }
        tokio::time::sleep(Duration::from_millis(150)).await;
        let is_active = || async { b.perform("isActive", &page, json!({"index": el.index}), 3.0).await.ok().map(|r| r["active"] == true).unwrap_or(false) };
        let mut ready = is_active().await;
        if !ready {
            let _ = b.perform("focus", &page, json!({"index": el.index}), 3.0).await;
            tokio::time::sleep(Duration::from_millis(100)).await;
            ready = is_active().await;
        }
        if !ready {
            // Still no caret: set the text directly.
            let Ok(r) = b.perform("fill", &page, json!({"index": el.index, "text": text}), 4.0).await else {
                return self.end(line, ActionResult::fail(format!("{} isn't a text box", el.text.chars().take(30).collect::<String>())));
            };
            if submit {
                let _ = self.platform.press("enter");
                tokio::time::sleep(Duration::from_millis(500)).await;
            }
            self.buddy.clear_highlight();
            return self.end(
                line,
                ActionResult::ok(format!(
                    "set {:?} in {} {:?}{}",
                    r["value"].as_str().unwrap_or(&text).chars().take(60).collect::<String>(),
                    el.role,
                    el.text.chars().take(40).collect::<String>(),
                    if submit { " and pressed Enter" } else { "" }
                )),
            );
        }
        let old = b.perform("value", &page, json!({"index": el.index}), 3.0).await.ok().and_then(|r| r["value"].as_str().map(String::from)).unwrap_or_default();
        if !old.is_empty() {
            let _ = b.perform("fill", &page, json!({"index": el.index, "text": ""}), 3.0).await;
        }
        let active = b.perform("activeValue", &page, json!({}), 3.0).await.ok();
        let is_code = active.as_ref().map(|a| a["code"] == true).unwrap_or(false);
        self.buddy.set_typing(true);
        self.platform.set_target(Some(&app));
        self.platform.enter_text(&text, is_code).await;
        self.platform.set_target(None);
        self.buddy.set_typing(false);
        // Keys queue up in the browser: wait until the field shows them.
        let mut value = None;
        for _ in 0..12 {
            value = b.perform("value", &page, json!({"index": el.index}), 3.0).await.ok().and_then(|r| r["value"].as_str().map(String::from));
            if value.as_deref().map(|v| similar(v, &text)).unwrap_or(false) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        if !is_code {
            if let Some(v) = &value {
                if !similar(v, &text) || v.chars().count() > text.chars().count() + 3 {
                    let _ = b.perform("fill", &page, json!({"index": el.index, "text": text}), 4.0).await;
                }
            }
        }
        // Browser autofill can rewrite fields filled a moment ago: put back anything that changed.
        ctx.typed.retain(|t| t.0 != el.index);
        ctx.typed.push((el.index, text.clone()));
        for (index, expected) in ctx.typed.clone() {
            if index == el.index {
                continue;
            }
            if let Ok(r) = b.perform("value", &page, json!({"index": index}), 3.0).await {
                if r["value"].as_str().map(|v| v.trim() != expected).unwrap_or(false) {
                    let _ = b.perform("fill", &page, json!({"index": index, "text": expected}), 3.0).await;
                }
            }
        }
        if submit {
            tokio::time::sleep(Duration::from_millis(120)).await;
            let _ = self.platform.press("enter");
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
        self.buddy.clear_highlight();
        let editor = active.as_ref().and_then(|a| a["editorKind"].as_str()).map(|k| format!(" (a {k} code editor: it may re-indent)")).unwrap_or_default();
        self.end(
            line,
            ActionResult::ok(format!(
                "typed {:?} into {} {:?}{editor}{}",
                text.chars().take(60).collect::<String>(),
                el.role,
                el.text.chars().take(40).collect::<String>(),
                if submit { " and pressed Enter" } else { "" }
            )),
        )
    }

    /// `type` with no id on a web page: into the page field with the caret, or (failing that) whatever native
    /// field or dialog has focus.
    pub(crate) async fn type_focused_page(&self, action: &Action, ctx: &mut Ctx) -> ActionResult {
        let (Some(text), Some(page), Some(app)) = (action.str("text").map(String::from), ctx.page.clone(), ctx.app.clone()) else {
            return ActionResult::fail("type needs text");
        };
        let submit = action.flag("submit");
        let line = self.begin(&format!("Type “{}”", text.chars().take(40).collect::<String>()));
        self.platform.bring_to_front(&app).await;
        let b = bridge();
        let before = b.perform("activeValue", &page, json!({}), 3.0).await.ok();
        let editable = before.as_ref().map(|v| v["editable"] == true).unwrap_or(false);
        if !editable {
            let page_focused = before.as_ref().map(|v| v["hasFocus"] == true).unwrap_or(false);
            let r = self.type_outside_page(&text, submit, &app, page_focused, ctx).await;
            self.buddy.clear_highlight();
            return self.end(line, r);
        }
        if before.as_ref().and_then(|v| v["value"].as_str()).map(|v| !v.is_empty()).unwrap_or(false) {
            self.platform.set_target(Some(&app));
            self.platform.select_all();
            self.platform.set_target(None);
            tokio::time::sleep(Duration::from_millis(60)).await;
        }
        let editor = before.as_ref().and_then(|v| v["editorKind"].as_str()).map(String::from);
        self.buddy.set_typing(true);
        self.platform.set_target(Some(&app));
        // Document editors (Google Docs) take the caret into an iframe: paste the whole text there.
        if before.as_ref().map(|v| v["frame"] == true).unwrap_or(false) {
            self.platform.paste(&text);
        } else {
            self.platform.enter_text(&text, before.as_ref().map(|v| v["code"] == true).unwrap_or(false)).await;
        }
        self.platform.set_target(None);
        self.buddy.set_typing(false);
        if let Ok(v) = b.perform("activeValue", &page, json!({}), 3.0).await {
            if let Some(value) = v["value"].as_str() {
                if !similar(value, &text) || value.chars().count() > text.chars().count() + 3 {
                    if let Ok(r) = b.perform("fillActive", &page, json!({"text": text}), 3.0).await {
                        if r["skipped"] == true {
                            if let Some(shows) = r["value"].as_str().filter(|s| !similar(s, &text)) {
                                self.buddy.clear_highlight();
                                return self.end(
                                    line,
                                    ActionResult::fail(format!(
                                        "the {} editor shows {:?}, not the text typed (auto-indent or auto-closed brackets?). Fix what differs rather than typing it all again",
                                        editor.clone().unwrap_or_else(|| "code".into()),
                                        shows.chars().take(200).collect::<String>()
                                    )),
                                );
                            }
                        }
                    }
                }
            }
        }
        if submit {
            tokio::time::sleep(Duration::from_millis(120)).await;
            let _ = self.platform.press("enter");
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
        self.buddy.clear_highlight();
        let into = editor.map(|e| format!("the focused code editor ({e})")).unwrap_or_else(|| "the focused field".into());
        self.end(line, ActionResult::ok(format!("typed {:?} into {into}{}", text.chars().take(60).collect::<String>(), if submit { " and pressed Enter" } else { "" })))
    }

    /// Keys for something the page can't see: a native field (address bar, a file dialog's File name box) or a
    /// focused page control that isn't a text box.
    async fn type_outside_page(&self, text: &str, submit: bool, app: &AppRef, page_focused: bool, ctx: &mut Ctx) -> ActionResult {
        let mut focus = self.platform.focus(None);
        for _ in 0..8 {
            if focus.as_ref().map(|f| f.text_input).unwrap_or(false) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(80)).await;
            focus = self.platform.focus(None);
        }
        let pressed = if submit { " and pressed Enter" } else { "" };
        let send = |pid_own: bool| async move {
            if pid_own {
                self.platform.set_target(Some(app));
            }
            if text.chars().count() > 80 {
                self.platform.paste(text);
            } else {
                self.platform.enter_text(text, false).await;
            }
            if submit {
                tokio::time::sleep(Duration::from_millis(120)).await;
                let _ = self.platform.press("enter");
                tokio::time::sleep(Duration::from_millis(500)).await;
            }
            self.platform.set_target(None);
        };
        if let Some(f) = focus.clone().filter(|f| f.text_input) {
            if f.secure {
                return ActionResult::fail("a password field has focus; I won't type there. Ask the user to enter it, or type with the field's id if they gave you the value");
            }
            let own = f.pid == app.pid;
            self.buddy.set_typing(true);
            if f.value.as_deref().map(|v| !v.is_empty()).unwrap_or(false) {
                self.platform.select_all();
                tokio::time::sleep(Duration::from_millis(60)).await;
            }
            send(own).await;
            self.buddy.set_typing(false);
            if !submit {
                if let Some(now) = self.platform.element_value(f.handle) {
                    if !similar(&now, text) {
                        self.platform.set_element_value(f.handle, text);
                    }
                }
            }
            ctx.fingerprint = self.platform.fingerprint(app).await;
            return ActionResult::ok(format!(
                "typed {:?} into the focused {} ({}){pressed}",
                text.chars().take(60).collect::<String>(),
                f.role,
                if own { "outside the page" } else { "a system dialog" }
            ));
        }
        if page_focused {
            if let Some(page) = bridge().snapshot(Some(&app.exe)).await {
                if let Some(el) = page.elements.iter().find(|e| e.has_flag("focused")).cloned() {
                    ctx.page = Some(page);
                    self.buddy.set_typing(true);
                    send(true).await;
                    self.buddy.set_typing(false);
                    return ActionResult::ok(format!(
                        "sent the keys {:?} to the focused {} {:?} (not a text box, so the result isn't checked){pressed}",
                        text.chars().take(60).collect::<String>(),
                        el.role,
                        el.text.chars().take(40).collect::<String>()
                    ));
                }
            }
        }
        if !page_focused && (self.platform.dialog_in_front(app) || focus.as_ref().map(|f| f.pid != app.pid).unwrap_or(false)) {
            self.buddy.set_typing(true);
            send(false).await;
            self.buddy.set_typing(false);
            ctx.fingerprint = self.platform.fingerprint(app).await;
            return ActionResult::ok(format!("typed {:?} into the dialog in front (no text field in it had focus; check it took){pressed}", text.chars().take(60).collect::<String>()));
        }
        ActionResult::fail("nothing here can take the text: no text box on the page or in a dialog has focus. Type with the field's id, or click the field first (look if it isn't listed)")
    }

    pub(crate) async fn web_point(&self, action: &Action, ctx: &mut Ctx, rs: &mut RunState) -> ActionResult {
        let Some(n) = super::run::web_index(action.get("id")) else { return ActionResult::fail("bad id") };
        let Some((el, rect)) = self.web_target(n, ctx, rs) else { return ActionResult::fail(format!("page element w{n} not found; look again")) };
        let line = self.begin(&format!("Show {}", el.text.chars().take(32).collect::<String>()));
        self.buddy.mark(rect, action.str("label")).await;
        self.current.lock().linger = 3.5;
        self.end(line, ActionResult::ok("marked it on screen with a circle and arrow"))
    }

    pub(crate) async fn web_scroll(&self, action: &Action, ctx: &mut Ctx) -> ActionResult {
        let up = action.str("dir").map(|d| d.eq_ignore_ascii_case("up")).unwrap_or(false);
        let line = self.begin(if up { "Scroll up" } else { "Scroll down" });
        if let Some(web) = ctx.web_area {
            self.buddy.travel(web.center(), None).await;
        }
        if let Some(page) = &ctx.page {
            let _ = bridge().perform("scroll", page, json!({"dy": if up { -600 } else { 600 }}), 4.0).await;
        }
        tokio::time::sleep(Duration::from_millis(450)).await;
        self.end(line, ActionResult::ok(if up { "scrolled up" } else { "scrolled down" }))
    }

    /// Straight into the page's upload field (no file picker); else through the site's own button; else the
    /// Windows file picker it opens, driven like a person would.
    pub(crate) async fn upload(&self, action: &Action, ctx: &mut Ctx) -> ActionResult {
        let Some(path) = action.str("file").or_else(|| action.str("path")) else { return ActionResult::fail("upload needs file") };
        let file = crate::paths::expand(path);
        let Ok(data) = std::fs::read(&file) else { return ActionResult::fail(format!("can't read {}", file.display())) };
        if data.len() >= 15_000_000 {
            return ActionResult::fail(format!("{} is too big to upload this way ({} MB)", file.display(), data.len() / 1_000_000));
        }
        let mut rs_dummy = RunState::default();
        let mut target = None;
        if let Some(n) = super::run::web_index(action.get("id")) {
            match self.live_target(n, ctx, &mut rs_dummy).await {
                Some(t) => target = Some(t),
                None => return ActionResult::fail(self.gone(action)),
            }
        }
        let page = ctx.page.clone().unwrap();
        let name = file.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let line = self.begin(&format!("Upload {name}"));
        use base64::Engine;
        let args = json!({"index": target.as_ref().map(|t| t.0.index).unwrap_or(-1), "name": name, "type": crate::files::mime(&file),
                          "data": base64::engine::general_purpose::STANDARD.encode(&data)});
        let b = bridge();
        let why = match b.perform("upload", &page, args.clone(), 20.0).await {
            Ok(r) if r["ok"] == true => {
                tokio::time::sleep(Duration::from_millis(800)).await;
                let holds: Vec<String> = r["files"].as_array().map(|a| a.iter().filter_map(|f| f.as_str().map(String::from)).collect()).unwrap_or_default();
                return self.end(line, ActionResult::ok(format!("attached {name} to the upload field (now holds: {})", holds.join(", "))));
            }
            Ok(_) => "the page didn't take the file".to_string(),
            Err(e) => e.to_string(),
        };
        let Some((el, rect)) = target else {
            return self.end(line, ActionResult::fail(format!("{why} — give the id of the site's upload button (upload goes through it), or click it if it opens its own picker (Google Forms uses Google Drive)")));
        };
        if let Ok(r) = b.perform("uploadVia", &page, args, 20.0).await {
            if r["ok"] == true {
                tokio::time::sleep(Duration::from_millis(800)).await;
                self.log("    upload: through the page's own button");
                let holds: Vec<String> = r["files"].as_array().map(|a| a.iter().filter_map(|f| f.as_str().map(String::from)).collect()).unwrap_or_default();
                return self.end(line, ActionResult::ok(format!("attached {name} through {:?} (now holds: {})", el.text.chars().take(40).collect::<String>(), holds.join(", "))));
            }
        }
        if let Some(app) = ctx.app.clone() {
            if let Some(r) = self.upload_through_picker(&file, rect.center(), &app).await {
                return self.end(line, r);
            }
        }
        self.end(
            line,
            ActionResult::fail(format!(
                "{why}. Clicking {:?} didn't ask for a file or open the file picker — if it opened the site's own menu or picker (Google Drive, Dropbox…), choose its \"from this device\" option there",
                el.text.chars().take(40).collect::<String>()
            )),
        )
    }

    /// The Windows Open dialog: its File name box takes a full path, then Enter.
    async fn upload_through_picker(&self, file: &std::path::Path, point: Point, app: &AppRef) -> Option<ActionResult> {
        self.platform.click_at(point, Some(app.pid)).await.ok()?;
        let mut up = false;
        for _ in 0..20 {
            tokio::time::sleep(Duration::from_millis(150)).await;
            if self.platform.dialog_in_front(app) {
                up = true;
                break;
            }
        }
        if !up {
            return None;
        }
        self.log("    upload: through the Windows file picker");
        tokio::time::sleep(Duration::from_millis(400)).await;
        // alt+n puts the caret in the File name box of the standard Open dialog.
        let _ = self.platform.press("alt+n");
        tokio::time::sleep(Duration::from_millis(200)).await;
        self.platform.paste(&file.display().to_string());
        tokio::time::sleep(Duration::from_millis(300)).await;
        let _ = self.platform.press("enter");
        for _ in 0..15 {
            tokio::time::sleep(Duration::from_millis(200)).await;
            if !self.platform.dialog_in_front(app) {
                tokio::time::sleep(Duration::from_millis(600)).await;
                return Some(ActionResult::ok(format!(
                    "chose {} in the file picker the site opened (check the page shows it)",
                    file.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
                )));
            }
        }
        Some(ActionResult::fail(format!("the file picker is still open after entering {}; look at it (the site may not accept that type)", file.display())))
    }

    /// Reads every answer on the page's form and shows it as a card.
    pub(crate) async fn review_form(&self, ctx: &mut Ctx, rs: &mut RunState) -> ActionResult {
        let page = ctx.page.clone().unwrap();
        let line = self.begin("Review the form");
        let Ok(r) = bridge().perform("review", &page, json!({}), 8.0).await else { return self.end(line, ActionResult::fail("no form fields found on this page")) };
        let items = r["items"].as_array().cloned().unwrap_or_default();
        if items.is_empty() {
            return self.end(line, ActionResult::fail("no form fields found on this page"));
        }
        rs.reviewed_form = true;
        let missing: Vec<String> = r["missing"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
        let cards: Vec<crate::history::CardItem> = items
            .iter()
            .map(|i| {
                let (q, a) = (i["q"].as_str().unwrap_or("?").to_string(), i["answer"].as_str().unwrap_or("").to_string());
                let flag = a.is_empty().then(|| if i["required"] == true { "⚠️ required — empty".to_string() } else { "(empty)".to_string() });
                crate::history::CardItem { title: q, subtitle: (!a.is_empty()).then_some(a), detail: flag, link: None }
            })
            .collect();
        let messages: Vec<String> = r["messages"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
        let note = format!(
            "{}{}",
            if missing.is_empty() { "All required questions are answered.".to_string() } else { format!("⚠️ {} required unanswered: {}", missing.len(), missing.join("; ")) },
            if messages.is_empty() { String::new() } else { format!("\nPage says: {}", messages.join(" · ")) }
        );
        let card = ResultCard {
            title: format!("Check before submitting: {}", r["title"].as_str().unwrap_or("form").chars().take(50).collect::<String>()),
            text: note.clone(),
            items: cards,
        };
        self.current.lock().run_result = Some(card.clone());
        self.show_card(card);
        let summary: Vec<String> = items
            .iter()
            .map(|i| format!("- {}: {}", i["q"].as_str().unwrap_or("?"), i["answer"].as_str().filter(|a| !a.is_empty()).unwrap_or("(empty)")))
            .collect();
        self.end(line, ActionResult::ok(format!("review shown to the user. {note}\n{}", summary.join("\n"))))
    }

    /// The form's answers before its final Submit: Submit or Edit. None = no form (or an unattended/dry/test run).
    pub(crate) async fn review_before_submit(&self, page: &Page, rs: &mut RunState) -> Option<bool> {
        if rs.qa || rs.dry || (rs.test && !rs.review_in_tests) {
            return None;
        }
        let r = bridge().perform("review", page, json!({}), 8.0).await.ok()?;
        let pairs: Vec<(String, String)> = r["items"]
            .as_array()?
            .iter()
            .filter_map(|i| {
                let q = i["q"].as_str().filter(|q| !q.is_empty())?;
                Some((q.to_string(), i["answer"].as_str().unwrap_or("").to_string()))
            })
            .collect();
        if pairs.len() < 2 {
            return None;
        }
        rs.reviewed_form = true;
        let title: String = r["title"].as_str().unwrap_or(&page.title).chars().take(70).collect();
        let (ok, note) = self.review_card(&title, pairs).await;
        *self.last_review_note.lock() = if ok { None } else { note };
        self.progress();
        if ok {
            rs.user_confirmed = true;
        }
        Some(ok)
    }

    /// Fills every visible field the job profile answers, each a real, checked step; never submits.
    pub(crate) async fn autofill(self: &Arc<Self>, ctx: &mut Ctx, rs: &mut RunState) -> ActionResult {
        let Some(page) = ctx.page.clone() else { return ActionResult::fail("autofill needs a web page") };
        let profile = crate::profile::current();
        let plan = crate::profile::plan(&page, |q| crate::profile::answer(q, &profile));
        self.log(&format!("  autofill: {} to fill, {} open", plan.steps.len(), plan.open.len()));
        let (mut filled, mut failed) = (vec![], vec![]);
        for step in plan.steps {
            if !self.added.lock().is_empty() {
                break;
            }
            let mut action = step.action.clone();
            if let (Some(n), Some(now)) = (super::run::web_index(action.get("id")), ctx.page.clone()) {
                match page::rematch(n, &page, &now) {
                    Some(id) => {
                        action.insert("id".into(), json!(format!("w{id}")));
                    }
                    None => {
                        failed.push(format!("{} (the field went away)", step.question));
                        continue;
                    }
                }
            }
            rs.last_target = None;
            let r = Box::pin(self.perform(&action, ctx, rs)).await;
            if r.ok {
                filled.push(format!("{} → {}", step.question, step.answer.chars().take(60).collect::<String>()));
                if !rs.dry {
                    self.record_trace(&action, rs.last_target.clone());
                }
            } else {
                failed.push(format!("{}: {}", step.question, r.summary.replace("FAILED: ", "").chars().take(120).collect::<String>()));
            }
            if ctx.page.is_some() && !rs.dry {
                self.relist(ctx).await;
            }
        }
        let mut summary = if filled.is_empty() {
            "nothing on screen that the profile answers".to_string()
        } else {
            format!("filled {} from the profile:\n{}", filled.len(), filled.iter().map(|f| format!("- {f}")).collect::<Vec<_>>().join("\n"))
        };
        if !failed.is_empty() {
            summary += &format!("\ncouldn't fill (do these yourself):\n{}", failed.iter().map(|f| format!("- {f}")).collect::<Vec<_>>().join("\n"));
        }
        if !plan.open.is_empty() {
            summary += &format!(
                "\nnot in the profile (fill from memory/resume, or ask the user once; remember_answer what they say):\n{}",
                plan.open.iter().map(|f| format!("- {f}")).collect::<Vec<_>>().join("\n")
            );
        }
        if plan.uploads > 0 {
            summary += &format!("\n{} upload field{} here: upload the resume yourself.", plan.uploads, if plan.uploads == 1 { "" } else { "s" });
        }
        if let Some(now) = &ctx.page {
            if now.below > 0 {
                summary += &format!("\n{} more fields/buttons below: scroll, then autofill again.", now.below);
            }
        }
        if filled.is_empty() && !failed.is_empty() {
            ActionResult::fail(summary)
        } else {
            ActionResult::ok(summary)
        }
    }
}
