//! What the agent acts through. Normally that's the desktop; in a background run the same calls go to the background
//! browser instead, so the agent's code doesn't branch on the mode and nothing can reach the user's mouse, keyboard,
//! clipboard or windows by accident: the desktop side is simply not called. The companion cursor likewise stays with
//! the user, quiet, instead of flying to clicks that aren't on their screen.

use crate::platform::{AppRef, Buddy, Element, FileHit, FileQuery, Focus, Mood, Platform, Point, Rect, Scan, Shot, TextBox, WindowOp};
use crate::worker::{self, worker};
use async_trait::async_trait;
use serde_json::json;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

/// Runs async worker calls from the trait's plain methods.
fn block<T>(f: impl Future<Output = T>) -> T {
    tokio::task::block_in_place(|| tokio::runtime::Handle::current().block_on(f))
}

/// The background browser, where an app goes.
pub fn worker_app() -> AppRef {
    AppRef { pid: worker().pid(), hwnd: 0, name: "the background browser".into(), exe: worker::EXE.into(), started: 0 }
}

pub struct Hands {
    desktop: Arc<dyn Platform>,
    hidden: AtomicBool,
}

impl Hands {
    pub fn new(desktop: Arc<dyn Platform>) -> Hands {
        Hands { desktop, hidden: AtomicBool::new(false) }
    }

    pub fn set_hidden(&self, on: bool) {
        self.hidden.store(on, Ordering::SeqCst);
    }

    pub fn hidden(&self) -> bool {
        self.hidden.load(Ordering::SeqCst)
    }

    /// The tab the run works in, ready to read: waits for a page that's still loading, for a few seconds.
    async fn settle(&self) {
        for _ in 0..15 {
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
            if let Some(page) = worker().snapshot(None).await {
                if page.ready != "loading" {
                    return;
                }
            }
        }
    }

    async fn browse(&self, url: &str, new_tab: bool) -> Option<AppRef> {
        let opened = if !new_tab && worker().has_tab() {
            worker().command("navigate", None, json!({"url": url})).await.map(|_| ())
        } else {
            worker().new_tab(url).await.map(|_| ())
        };
        match opened {
            Ok(()) => {
                self.settle().await;
                Some(worker_app())
            }
            Err(e) => {
                crate::log::write(&format!("    background browser: {e}"));
                None
            }
        }
    }
}

#[async_trait]
impl Platform for Hands {
    fn front_app(&self) -> Option<AppRef> {
        if self.hidden() {
            return Some(worker_app());
        }
        self.desktop.front_app()
    }
    fn running_apps(&self) -> Vec<String> {
        self.desktop.running_apps()
    }
    fn is_same_process(&self, app: &AppRef) -> bool {
        app.exe == worker::EXE || self.desktop.is_same_process(app)
    }
    fn is_browser(&self, app: &AppRef) -> bool {
        app.exe == worker::EXE || self.desktop.is_browser(app)
    }
    fn default_browser(&self) -> Option<String> {
        self.desktop.default_browser()
    }
    fn user_name(&self) -> String {
        self.desktop.user_name()
    }
    fn handoff(&self, from: &AppRef) -> Option<AppRef> {
        if self.hidden() {
            return None;
        }
        self.desktop.handoff(from)
    }
    async fn bring_to_front(&self, app: &AppRef) -> bool {
        self.hidden() || self.desktop.bring_to_front(app).await
    }
    async fn open_app(&self, name: &str) -> Option<AppRef> {
        if self.hidden() {
            // The only app a background run has is its browser (the policy has checked the name).
            return self.browse("about:blank", true).await;
        }
        self.desktop.open_app(name).await
    }
    async fn open_url(&self, url: &str, current: Option<&AppRef>, new_tab: bool) -> Option<AppRef> {
        if self.hidden() {
            return self.browse(url, new_tab).await;
        }
        self.desktop.open_url(url, current, new_tab).await
    }
    async fn window(&self, app: &AppRef, op: WindowOp, title: Option<&str>) -> (bool, String) {
        if self.hidden() {
            return (false, "not in a background run".into());
        }
        self.desktop.window(app, op, title).await
    }
    async fn menu(&self, app: &AppRef, path: &str) -> (bool, String) {
        if self.hidden() {
            return (false, "not in a background run".into());
        }
        self.desktop.menu(app, path).await
    }
    fn document_path(&self, app: &AppRef) -> Option<PathBuf> {
        if self.hidden() {
            return None;
        }
        self.desktop.document_path(app)
    }

    async fn scan(&self, app: &AppRef, limit: usize) -> Scan {
        if self.hidden() {
            // The browser's own chrome doesn't exist here; the page is everything.
            return Scan { window: "Background browser".into(), focused: "nothing".into(), ..Default::default() };
        }
        self.desktop.scan(app, limit).await
    }
    async fn fingerprint(&self, app: &AppRef) -> u64 {
        if self.hidden() {
            let page = worker().snapshot(None).await;
            let text = page.map(|p| format!("{}|{}|{}", p.url, p.title, p.elements.len())).unwrap_or_default();
            return text.bytes().fold(0xcbf29ce484222325, |h, b| (h ^ b as u64).wrapping_mul(0x100000001b3));
        }
        self.desktop.fingerprint(app).await
    }
    async fn web_area(&self, app: &AppRef) -> Option<Rect> {
        if self.hidden() {
            return worker().has_tab().then(|| Rect::new(0.0, 0.0, worker::VIEWPORT.0, worker::VIEWPORT.1));
        }
        self.desktop.web_area(app).await
    }
    fn element_rect(&self, handle: u64) -> Option<Rect> {
        if self.hidden() {
            return None;
        }
        self.desktop.element_rect(handle)
    }
    fn element_value(&self, handle: u64) -> Option<String> {
        if self.hidden() {
            return None;
        }
        self.desktop.element_value(handle)
    }
    fn focus(&self, app: Option<&AppRef>) -> Option<Focus> {
        if self.hidden() {
            return None;
        }
        self.desktop.focus(app)
    }
    fn dialog_in_front(&self, app: &AppRef) -> bool {
        !self.hidden() && self.desktop.dialog_in_front(app)
    }
    fn hit_mismatch(&self, point: Point, pid: u32) -> Option<String> {
        if self.hidden() {
            return None;
        }
        self.desktop.hit_mismatch(point, pid)
    }
    async fn screenshot(&self, app: &AppRef) -> Option<Shot> {
        if self.hidden() {
            let png = worker().png(None).await?;
            let (w, h) = worker::VIEWPORT;
            return Some(Shot { png, area: Rect::new(0.0, 0.0, w, h), width: w as u32, height: h as u32 });
        }
        self.desktop.screenshot(app).await
    }
    async fn look(&self, app: &AppRef, elements: &[Element], circled: Option<&[Point]>) -> Option<String> {
        if self.hidden() {
            return worker().picture(None, 85).await;
        }
        self.desktop.look(app, elements, circled).await
    }
    fn screen_point(&self, x: f64, y: f64) -> Option<Point> {
        if self.hidden() {
            // Pictures of the background browser are 1:1 with its page.
            return Some(Point::new(x, y));
        }
        self.desktop.screen_point(x, y)
    }
    fn shot_scale(&self) -> f64 {
        if self.hidden() {
            return 1.0;
        }
        self.desktop.shot_scale()
    }
    async fn ocr(&self, app: &AppRef) -> Option<Vec<TextBox>> {
        if self.hidden() {
            return None;
        }
        self.desktop.ocr(app).await
    }
    async fn ocr_image(&self, png: &[u8]) -> Option<String> {
        self.desktop.ocr_image(png).await
    }
    async fn selected_text(&self, app: &AppRef) -> Option<String> {
        if self.hidden() {
            return None;
        }
        self.desktop.selected_text(app).await
    }
    async fn copy_all(&self, app: &AppRef) -> Option<String> {
        if self.hidden() {
            return None;
        }
        self.desktop.copy_all(app).await
    }

    async fn click_element(&self, handle: u64, app: &AppRef, fingerprint: u64) -> Result<String, String> {
        if self.hidden() {
            return Err("desktop controls can't be used in a background run".into());
        }
        self.desktop.click_element(handle, app, fingerprint).await
    }
    async fn click_at(&self, point: Point, pid: Option<u32>) -> Result<(), String> {
        if self.hidden() {
            return worker().command("cdpClick", None, json!({"x": point.x, "y": point.y})).await.map(|_| ()).map_err(|e| e.to_string());
        }
        self.desktop.click_at(point, pid).await
    }
    async fn focus_element(&self, handle: u64, app: &AppRef) -> Result<(), String> {
        if self.hidden() {
            return Err("desktop controls can't be used in a background run".into());
        }
        self.desktop.focus_element(handle, app).await
    }
    fn invoke(&self, handle: u64) -> bool {
        !self.hidden() && self.desktop.invoke(handle)
    }
    fn set_element_value(&self, handle: u64, text: &str) -> bool {
        !self.hidden() && self.desktop.set_element_value(handle, text)
    }
    async fn type_text(&self, text: &str, app: &AppRef) -> Result<(), String> {
        if self.hidden() {
            return worker().command("cdpType", None, json!({"text": text})).await.map(|_| ()).map_err(|e| e.to_string());
        }
        self.desktop.type_text(text, app).await
    }
    async fn enter_text(&self, text: &str, code_editor: bool) {
        if self.hidden() {
            if let Err(e) = worker().command("cdpType", None, json!({"text": text})).await {
                crate::log::write(&format!("    background browser: {e}"));
            }
            return;
        }
        self.desktop.enter_text(text, code_editor).await
    }
    fn press(&self, combo: &str) -> Result<(), String> {
        if self.hidden() {
            return block(worker().command("cdpKey", None, json!({"keys": combo}))).map(|_| ()).map_err(|e| e.to_string());
        }
        self.desktop.press(combo)
    }
    fn paste(&self, text: &str) {
        if self.hidden() {
            // Inserted straight into the page: the shared clipboard isn't touched.
            let _ = block(worker().command("cdpType", None, json!({"text": text})));
            return;
        }
        self.desktop.paste(text)
    }
    fn select_all(&self) {
        if self.hidden() {
            let _ = block(worker().command("cdpKey", None, json!({"keys": "ctrl+a"})));
            return;
        }
        self.desktop.select_all()
    }
    async fn scroll(&self, app: &AppRef, up: bool) {
        if self.hidden() {
            let _ = worker().command("cdpScroll", None, json!({"x": 700, "y": 450, "dy": if up { -600 } else { 600 }})).await;
            return;
        }
        self.desktop.scroll(app, up).await
    }
    fn set_target(&self, app: Option<&AppRef>) {
        if !self.hidden() {
            self.desktop.set_target(app)
        }
    }
    fn begin_run(&self) {
        if !self.hidden() {
            self.desktop.begin_run()
        }
    }
    fn end_run(&self, keep_front_app: bool) {
        if !self.hidden() {
            self.desktop.end_run(keep_front_app)
        }
    }

    fn clipboard_text(&self) -> Option<String> {
        if self.hidden() {
            return None;
        }
        self.desktop.clipboard_text()
    }
    fn set_clipboard_text(&self, text: &str) {
        if !self.hidden() {
            self.desktop.set_clipboard_text(text)
        }
    }
    fn set_clipboard_png(&self, png: &[u8]) -> bool {
        !self.hidden() && self.desktop.set_clipboard_png(png)
    }
    fn clipboard_files(&self) -> Vec<PathBuf> {
        if self.hidden() {
            return vec![];
        }
        self.desktop.clipboard_files()
    }
    fn clipboard_sequence(&self) -> u32 {
        self.desktop.clipboard_sequence()
    }

    async fn search_files(&self, query: &FileQuery) -> Vec<FileHit> {
        self.desktop.search_files(query).await
    }
    fn trash(&self, paths: &[PathBuf]) -> Result<usize, String> {
        self.desktop.trash(paths)
    }

    fn mic_in_use(&self) -> bool {
        // A call doesn't matter: nothing happens on the user's screen.
        !self.hidden() && self.desktop.mic_in_use()
    }
    fn screen_locked(&self) -> bool {
        !self.hidden() && self.desktop.screen_locked()
    }
    async fn shell(&self, command: &str, timeout_secs: u64) -> (i32, String) {
        self.desktop.shell(command, timeout_secs).await
    }
    fn reveal(&self, paths: &[PathBuf]) {
        if !self.hidden() {
            self.desktop.reveal(paths)
        }
    }
    fn open_path(&self, path: &Path) -> bool {
        !self.hidden() && self.desktop.open_path(path)
    }
    fn open_url_direct(&self, url: &str) -> bool {
        !self.hidden() && self.desktop.open_url_direct(url)
    }
}

/// The companion cursor. In a background run it stays quiet beside the user's pointer.
pub struct QuietBuddy {
    real: Arc<dyn Buddy>,
    quiet: AtomicBool,
}

impl QuietBuddy {
    pub fn new(real: Arc<dyn Buddy>) -> QuietBuddy {
        QuietBuddy { real, quiet: AtomicBool::new(false) }
    }

    pub fn set_quiet(&self, on: bool) {
        self.quiet.store(on, Ordering::SeqCst);
        if on {
            self.real.clear_highlight();
            self.real.clear_mark();
            self.real.go_home();
            self.real.set_mood(Mood::Idle);
        }
    }

    fn quiet(&self) -> bool {
        self.quiet.load(Ordering::SeqCst)
    }
}

#[async_trait]
impl Buddy for QuietBuddy {
    async fn travel(&self, to: Point, framing: Option<Rect>) {
        if !self.quiet() {
            self.real.travel(to, framing).await
        }
    }
    fn click(&self) {
        if !self.quiet() {
            self.real.click()
        }
    }
    async fn mark(&self, rect: Rect, label: Option<&str>) {
        if !self.quiet() {
            self.real.mark(rect, label).await
        }
    }
    fn clear_mark(&self) {
        self.real.clear_mark()
    }
    fn clear_highlight(&self) {
        self.real.clear_highlight()
    }
    fn bubble(&self, text: Option<&str>, seconds: f64) {
        if !self.quiet() {
            self.real.bubble(text, seconds)
        }
    }
    fn set_mood(&self, mood: Mood) {
        // Listening is the user holding the talk key, whatever the run is doing.
        if !self.quiet() || matches!(mood, Mood::Listening | Mood::Idle) {
            self.real.set_mood(mood)
        }
    }
    fn set_typing(&self, on: bool) {
        if !self.quiet() {
            self.real.set_typing(on)
        }
    }
    fn set_level(&self, level: f32) {
        self.real.set_level(level)
    }
    fn go_home(&self) {
        self.real.go_home()
    }
    fn signal(&self, pass: bool) {
        if !self.quiet() {
            self.real.signal(pass)
        }
    }
    fn set_qa(&self, on: bool) {
        self.real.set_qa(on)
    }
}
