//! `Platform` for Windows: what the agent asks of the OS, done the way a person would — the companion cursor
//! travels to the taskbar or the address bar, clicks for real, types at a human rhythm — with UI Automation to
//! read and verify, and the user's pointer and front app put back at the end of a run.

use crate::overlay::Overlay;
use crate::{apps, clipboard, input, ocr, screen, system, uia};
use async_trait::async_trait;
use clinqy_core::observation::similar;
use clinqy_core::platform::*;
use parking_lot::Mutex;
use rand::Rng;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

pub struct WindowsPlatform {
    pub buddy: Arc<Overlay>,
    run_cursor: Mutex<Option<Point>>,
    cursor_left_at: Mutex<Option<Point>>,
    run_front: Mutex<Option<isize>>,
    user_name: String,
}

async fn blocking<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> T {
    tokio::task::spawn_blocking(move || {
        crate::com::ensure();
        f()
    })
    .await
    .expect("platform task panicked")
}

fn jitter(lo: u64, hi: u64) -> u64 {
    rand::thread_rng().gen_range(lo..hi)
}

async fn sleep(ms: u64) {
    tokio::time::sleep(Duration::from_millis(ms)).await;
}

impl WindowsPlatform {
    pub fn new(buddy: Arc<Overlay>) -> WindowsPlatform {
        let user_name = system::full_user_name();
        clinqy_core::profile::set_full_name(&user_name);
        apps::warm_start_apps();
        WindowsPlatform { buddy, run_cursor: Mutex::new(None), cursor_left_at: Mutex::new(None), run_front: Mutex::new(None), user_name }
    }

    /// The window the user is looking at for `app`: a dialog over it, else its main window (still alive).
    fn live_hwnd(app: &AppRef) -> (isize, Option<isize>) {
        let main = if apps::is_window(app.hwnd) { app.hwnd } else { apps::main_window_of(app.pid).unwrap_or(app.hwnd) };
        let dialog = apps::foreground().and_then(|(m, d)| if m == main { d } else { None });
        (main, dialog)
    }

    fn shot_area(app: &AppRef) -> Option<Rect> {
        let (main, dialog) = Self::live_hwnd(app);
        // A dialog over a big window: the whole window with the dialog on it (the model sees both).
        let r = apps::window_rect(main)?;
        let r = match dialog.and_then(apps::window_rect) {
            Some(d) if !r.contains(d.center()) => d,
            _ => r,
        };
        let r = r.intersection(&screen::virtual_screen());
        (!r.is_empty()).then_some(r)
    }

    async fn effect(&self, app: &AppRef, fp: u64, fg: Option<(isize, Option<isize>)>, ms: u64) -> bool {
        let deadline = Instant::now() + Duration::from_millis(ms);
        while Instant::now() < deadline {
            sleep(60).await;
            if apps::foreground() != fg {
                return true;
            }
            if self.fingerprint(app).await != fp {
                return true;
            }
        }
        false
    }

    /// Keystrokes at a human rhythm into whatever has focus (stops if the target app loses focus).
    async fn keystrokes(&self, text: &str) -> bool {
        let n = text.chars().count();
        let base = if n > 80 {
            8.0
        } else if n > 30 {
            16.0
        } else {
            28.0
        };
        for ch in text.chars() {
            if !input::type_char(ch) {
                return false;
            }
            let mut ms = base + rand::thread_rng().gen_range(0.0..base * 0.9);
            if ch == ' ' {
                ms += base * 0.5;
            }
            if ".,!?".contains(ch) {
                ms += 60.0;
            }
            sleep(ms as u64).await;
        }
        true
    }

    fn focused_value(&self) -> Option<String> {
        uia::uia().focus().and_then(|f| f.value)
    }

    async fn landed(&self, text: &str) -> bool {
        for _ in 0..8 {
            sleep(70).await;
            match self.focused_value() {
                // A field that doesn't report its text can't be checked: trust it.
                None => return true,
                Some(v) if v.is_empty() || similar(&v, text) => return true,
                _ => {}
            }
        }
        false
    }

    async fn wait_new_front(&self, before: &[isize], want: &str, seconds: f64) -> Option<AppRef> {
        let started = Instant::now();
        let deadline = started + Duration::from_secs_f64(seconds);
        let want = want.to_lowercase();
        while Instant::now() < deadline {
            if let Some((main, _)) = apps::foreground() {
                if let Some(a) = apps::app_ref(main) {
                    let matches = a.name.to_lowercase().contains(&want) || want.contains(&a.name.to_lowercase()) || apps::window_title(main).to_lowercase().contains(&want);
                    // A window that merely appeared counts only after a while (an app whose window title doesn't
                    // carry its name); early on, something else popping up (an Explorer window) mustn't.
                    let fresh = !before.contains(&main)
                        && a.pid != apps::own_pid()
                        && !["searchhost.exe", "startmenuexperiencehost.exe", "shellexperiencehost.exe", "explorer.exe"].contains(&a.exe.as_str())
                        && started.elapsed() > Duration::from_millis(2500);
                    if matches || fresh {
                        // Give it a moment to put its window up.
                        sleep(250).await;
                        return apps::foreground().and_then(|(m, _)| apps::app_ref(m)).or(Some(a));
                    }
                }
            }
            sleep(100).await;
        }
        None
    }

    /// Start search, like a person: the Win key, the app's name, Enter.
    async fn start_search(&self, name: &str) -> bool {
        if let Some((_, _, rect)) = uia::uia().taskbar_buttons().into_iter().find(|(n, _, _)| n == "Start") {
            self.buddy.travel(rect.center(), Some(rect)).await;
        }
        self.buddy.click();
        if input::press_combo("win").is_err() {
            return false;
        }
        // The Start/Search panel must be in front before typing a single key.
        let mut up = false;
        for _ in 0..15 {
            sleep(80).await;
            if let Some((m, _)) = apps::foreground() {
                let exe = apps::app_ref(m).map(|a| a.exe).unwrap_or_default();
                if ["searchhost.exe", "startmenuexperiencehost.exe", "searchapp.exe", "searchui.exe"].contains(&exe.as_str()) {
                    up = true;
                    break;
                }
            }
        }
        if !up {
            let _ = input::press_combo("esc");
            return false;
        }
        sleep(250).await;
        self.buddy.set_typing(true);
        input::set_target(None);
        for ch in name.chars() {
            input::type_char(ch);
            sleep(jitter(40, 90)).await;
        }
        self.buddy.set_typing(false);
        sleep(650).await;
        input::press_combo("enter").is_ok()
    }
}

#[async_trait]
impl Platform for WindowsPlatform {
    fn front_app(&self) -> Option<AppRef> {
        let (main, _) = apps::foreground()?;
        let a = apps::app_ref(main)?;
        (a.pid != apps::own_pid()).then_some(a)
    }

    fn running_apps(&self) -> Vec<String> {
        apps::running_apps()
    }

    fn is_same_process(&self, app: &AppRef) -> bool {
        app.started == 0 || apps::start_time(app.pid) == app.started
    }

    fn is_browser(&self, app: &AppRef) -> bool {
        apps::is_browser_exe(&app.exe)
    }

    fn default_browser(&self) -> Option<String> {
        apps::default_browser()
    }

    fn user_name(&self) -> String {
        self.user_name.clone()
    }

    fn handoff(&self, from: &AppRef) -> Option<AppRef> {
        let (main, _) = apps::foreground()?;
        let a = apps::app_ref(main)?;
        (a.pid != from.pid && a.pid != apps::own_pid()).then_some(a)
    }

    async fn bring_to_front(&self, app: &AppRef) -> bool {
        let (main, dialog) = Self::live_hwnd(app);
        if apps::foreground().map(|f| f.0 == main).unwrap_or(false) {
            return true;
        }
        let target = dialog.unwrap_or(main);
        blocking(move || apps::bring_to_front(target)).await
    }

    async fn open_app(&self, name: &str) -> Option<AppRef> {
        let name = name.trim().trim_end_matches(".exe").to_string();
        // Already running: its taskbar button, or straight to its window.
        let n2 = name.clone();
        if let Some(running) = blocking(move || apps::find_running(&n2)).await {
            if apps::foreground().map(|f| f.0 == running.hwnd).unwrap_or(false) {
                return Some(running);
            }
            let lower = running.name.to_lowercase();
            let button = blocking(move || uia::uia().taskbar_buttons().into_iter().find(|(n, _, _)| n.to_lowercase().starts_with(&lower))).await;
            if let Some((_, handle, rect)) = button {
                self.buddy.travel(rect.center(), Some(rect)).await;
                sleep(120).await;
                self.buddy.click();
                // A taskbar button with several windows opens a picker: go straight to the window instead.
                let h = running.hwnd;
                if !blocking(move || uia::uia().invoke(handle)).await || { sleep(350).await; !apps::foreground().map(|f| f.0 == h).unwrap_or(false) } {
                    let _ = input::press_combo("esc");
                    blocking(move || apps::bring_to_front(h)).await;
                }
            } else {
                let h = running.hwnd;
                blocking(move || apps::bring_to_front(h)).await;
            }
            self.buddy.clear_highlight();
            if apps::foreground().map(|f| f.0 == running.hwnd).unwrap_or(false) {
                return Some(running);
            }
        }
        // Installed: Start search like a person, falling back to launching it directly.
        let n2 = name.clone();
        let Some(installed) = blocking(move || apps::find_installed(&n2)).await else {
            // A Mac browser (from a workflow or test recorded on a Mac): the user's own browser does the same job.
            let mac_only = ["arc", "safari", "orion"];
            if mac_only.contains(&name.to_lowercase().as_str()) {
                if let Some(b) = self.default_browser().filter(|b| !mac_only.contains(&b.to_lowercase().as_str())) {
                    clinqy_core::log::write(&format!("    ({name} is a Mac browser; using {b})"));
                    return Box::pin(self.open_app(&b)).await;
                }
            }
            return None;
        };
        let before = apps::top_windows();
        let shown = installed.name.clone();
        let searched = self.start_search(&shown).await;
        if let Some(app) = self.wait_new_front(&before, &shown, if searched { 6.0 } else { 0.1 }).await {
            self.buddy.clear_highlight();
            return Some(app);
        }
        let id = installed.app_id.clone();
        blocking(move || apps::launch_app_id(&id)).await;
        let app = self.wait_new_front(&before, &shown, 10.0).await;
        self.buddy.clear_highlight();
        app
    }

    async fn open_url(&self, url: &str, current: Option<&AppRef>, new_tab: bool) -> Option<AppRef> {
        let browser = match current.filter(|a| self.is_browser(a)) {
            Some(b) => {
                self.bring_to_front(b).await;
                Some(b.clone())
            }
            None => match self.default_browser() {
                Some(name) => self.open_app(&name).await,
                None => None,
            },
        };
        let Some(browser) = browser else {
            system::shell_open(url);
            sleep(1500).await;
            return self.front_app();
        };
        input::set_target(Some(browser.hwnd));
        let _ = input::press_combo(if new_tab { "ctrl+t" } else { "ctrl+l" });
        sleep(380).await;
        // Go where the address goes: the focused field near the top of the window.
        let window = apps::window_rect(browser.hwnd);
        let focus = uia::uia().focus();
        if let (Some(f), Some(w)) = (focus.as_ref().and_then(|f| f.rect), window) {
            if f.w > 40.0 && f.mid_y() < w.y + w.h * 0.3 {
                self.buddy.travel(Point::new(f.x + (f.w / 2.0).min(80.0), f.mid_y()), Some(f)).await;
            }
        } else if let Some(w) = window {
            self.buddy.travel(Point::new(w.mid_x(), w.y + 52.0), None).await;
        }
        let mut address = url.to_string();
        for p in ["https://www.", "https://", "http://"] {
            if let Some(rest) = address.strip_prefix(p) {
                address = rest.to_string();
                break;
            }
        }
        if address.ends_with('/') {
            address.pop();
        }
        self.buddy.set_typing(true);
        let mut typed = true;
        for ch in address.chars() {
            if !input::type_char(ch) {
                typed = false;
                break;
            }
            sleep(jitter(14, 40)).await;
        }
        self.buddy.set_typing(false);
        sleep(150).await;
        let value = self.focused_value().unwrap_or_default();
        let head: String = address.chars().take(6).collect::<String>().to_lowercase();
        if !typed || (!value.is_empty() && !value.to_lowercase().contains(&head)) {
            // The keys went astray: set the field directly, else open it through the browser.
            let set = uia::uia().focus().map(|f| uia::uia().set_value(f.handle, &address)).unwrap_or(false);
            if !set || !self.focused_value().unwrap_or_default().to_lowercase().contains(&head) {
                let _ = input::press_combo("esc");
                input::set_target(None);
                system::shell_open(url);
                sleep(900).await;
                return Some(browser);
            }
        }
        sleep(120).await;
        let _ = input::press_combo("enter");
        input::set_target(None);
        // Wait for the page to start loading rather than a fixed pause.
        let title = apps::window_title(browser.hwnd);
        for _ in 0..12 {
            sleep(100).await;
            if apps::window_title(browser.hwnd) != title {
                break;
            }
        }
        sleep(200).await;
        Some(browser)
    }

    async fn window(&self, app: &AppRef, op: WindowOp, title: Option<&str>) -> (bool, String) {
        let hwnd = match title.filter(|t| !t.is_empty()) {
            Some(t) => match apps::window_titled(app.pid, t) {
                Some(h) => h,
                None => return (false, format!("no window titled “{t}”")),
            },
            None => Self::live_hwnd(app).0,
        };
        blocking(move || apps::window_op(hwnd, op)).await
    }

    async fn menu(&self, app: &AppRef, path: &str) -> (bool, String) {
        let (main, _) = Self::live_hwnd(app);
        let p = path.to_string();
        blocking(move || uia::uia().press_menu(main, &p)).await
    }

    fn document_path(&self, app: &AppRef) -> Option<PathBuf> {
        // Some apps show the file's full path in the title ("C:\…\report.pdf - Adobe Acrobat").
        let title = apps::window_title(app.hwnd);
        let re = regex::Regex::new(r"[A-Za-z]:\\[^<>:|?*\n]+?\.[A-Za-z0-9]{2,5}\b").ok()?;
        let p = PathBuf::from(re.find(&title)?.as_str());
        p.exists().then_some(p)
    }

    async fn scan(&self, app: &AppRef, limit: usize) -> Scan {
        let (main, dialog) = Self::live_hwnd(app);
        // With the extension connected the page comes from it; without, from UI Automation (slower, but it sees).
        let browser = self.is_browser(app) && clinqy_core::bridge::bridge().is_connected();
        blocking(move || {
            let mut s = uia::uia().scan(main, dialog, browser, screen::virtual_screen(), limit);
            s.dialog = dialog.and_then(|d| uia::dialog_of(d, apps::owner(d)));
            s
        })
        .await
    }

    async fn fingerprint(&self, app: &AppRef) -> u64 {
        let (main, dialog) = Self::live_hwnd(app);
        let browser = self.is_browser(app) && clinqy_core::bridge::bridge().is_connected();
        blocking(move || uia::uia().fingerprint(dialog.unwrap_or(main), browser)).await
    }

    async fn web_area(&self, app: &AppRef) -> Option<Rect> {
        let (main, _) = Self::live_hwnd(app);
        blocking(move || uia::uia().web_area(main)).await
    }

    fn element_rect(&self, handle: u64) -> Option<Rect> {
        uia::uia().rect_of(handle)
    }

    fn element_value(&self, handle: u64) -> Option<String> {
        uia::uia().value_of(handle)
    }

    fn focus(&self, app: Option<&AppRef>) -> Option<Focus> {
        let f = uia::uia().focus()?;
        if f.pid == apps::own_pid() {
            return None;
        }
        match app {
            Some(a) if a.pid != f.pid && !self.is_browser(a) => None,
            _ => Some(f),
        }
    }

    fn dialog_in_front(&self, app: &AppRef) -> bool {
        apps::foreground().map(|(m, d)| d.is_some() && (m == app.hwnd || apps::pid_of(m) == app.pid)).unwrap_or(false)
    }

    fn hit_mismatch(&self, point: Point, pid: u32) -> Option<String> {
        let owner = uia::uia().pid_at(point.x, point.y)?;
        if owner == pid || owner == apps::own_pid() || owner == 0 {
            return None;
        }
        // Content hosted in the app's own window by another process (WebView2 apps like WhatsApp).
        if apps::root_pid_at(point.x, point.y) == Some(pid) {
            return None;
        }
        let other = apps::exe_path(owner).map(|p| apps::friendly_name(0, &p)).unwrap_or_else(|| "another app".into());
        // A browser's page can answer from a helper process of the same browser.
        let target_exe = apps::exe_path(pid).unwrap_or_default();
        if apps::exe_path(owner).unwrap_or_default() == target_exe {
            return None;
        }
        Some(format!("{other} is on top at that spot; look again before clicking"))
    }

    async fn screenshot(&self, app: &AppRef) -> Option<Shot> {
        let area = Self::shot_area(app)?;
        blocking(move || {
            let img = screen::capture(area)?;
            Some(Shot { width: img.width(), height: img.height(), png: screen::png(&img), area })
        })
        .await
    }

    async fn look(&self, app: &AppRef, elements: &[Element], circled: Option<&[Point]>) -> Option<String> {
        let area = Self::shot_area(app)?;
        let els = elements.to_vec();
        let circled = circled.map(|c| c.to_vec());
        blocking(move || screen::for_model(area, &els, circled.as_deref())).await
    }

    fn screen_point(&self, x: f64, y: f64) -> Option<Point> {
        screen::screen_point(x, y)
    }

    fn shot_scale(&self) -> f64 {
        screen::scale()
    }

    async fn ocr(&self, app: &AppRef) -> Option<Vec<TextBox>> {
        let area = Self::shot_area(app)?;
        blocking(move || {
            let img = screen::capture(area)?;
            ocr::recognize(&img, area)
        })
        .await
    }

    async fn ocr_image(&self, png: &[u8]) -> Option<String> {
        let bytes = png.to_vec();
        blocking(move || ocr::recognize_bytes(&bytes)).await
    }

    async fn selected_text(&self, app: &AppRef) -> Option<String> {
        if let Some(t) = blocking(|| uia::uia().selected_text()).await {
            return Some(t);
        }
        if self.is_browser(app) {
            return None; // the extension reads page selections
        }
        // Ctrl+C, the clipboard read, then put back.
        let saved = clipboard::text();
        let seq = clipboard::sequence();
        input::set_target(Some(app.hwnd));
        let _ = input::press_combo("ctrl+c");
        input::set_target(None);
        let mut copied = None;
        for _ in 0..12 {
            sleep(25).await;
            if clipboard::sequence() != seq {
                copied = clipboard::text().map(|t| t.trim().to_string()).filter(|t| !t.is_empty());
                break;
            }
        }
        if copied.is_some() {
            match saved {
                Some(s) => {
                    clipboard::set_text(&s, true);
                }
                None => {
                    clipboard::set_text("", true);
                }
            }
        }
        copied
    }

    async fn copy_all(&self, app: &AppRef) -> Option<String> {
        self.bring_to_front(app).await;
        input::set_target(Some(app.hwnd));
        let _ = input::press_combo("ctrl+a");
        sleep(120).await;
        input::set_target(None);
        let t = self.selected_text(app).await;
        let _ = input::press_combo("right");
        t
    }

    async fn click_element(&self, handle: u64, app: &AppRef, fingerprint: u64) -> Result<String, String> {
        let rect = self.element_rect(handle).ok_or("that control isn't on screen any more; look again")?;
        self.buddy.travel(rect.center(), Some(rect)).await;
        sleep(70).await;
        self.buddy.click();
        let fg = apps::foreground();
        if blocking(move || uia::uia().invoke(handle)).await && self.effect(app, fingerprint, fg, 300).await {
            return Ok("axpress".into());
        }
        let point = uia::uia().clickable_point(handle).map(|(x, y)| Point::new(x, y)).filter(|p| rect.contains(*p)).unwrap_or(rect.center());
        if let Some(why) = self.hit_mismatch(point, app.pid) {
            return Err(why);
        }
        blocking(move || input::click(point)).await;
        Ok("real".into())
    }

    async fn click_at(&self, point: Point, pid: Option<u32>) -> Result<(), String> {
        if let Some(pid) = pid {
            if let Some(why) = self.hit_mismatch(point, pid) {
                return Err(why);
            }
        }
        self.buddy.travel(point, None).await;
        sleep(60).await;
        self.buddy.click();
        blocking(move || input::click(point)).await;
        Ok(())
    }

    async fn focus_element(&self, handle: u64, app: &AppRef) -> Result<(), String> {
        let rect = self.element_rect(handle).ok_or("that field isn't on screen any more; look again")?;
        self.buddy.travel(rect.center(), Some(rect)).await;
        sleep(80).await;
        self.buddy.click();
        if let Some(why) = self.hit_mismatch(rect.center(), app.pid) {
            // Something covers it: focusing through Automation alone is still safe.
            if uia::uia().set_focus(handle) {
                return Ok(());
            }
            return Err(why);
        }
        let c = rect.center();
        blocking(move || input::click(c)).await;
        let _ = blocking(move || uia::uia().set_focus(handle)).await;
        sleep(120).await;
        if !uia::uia().focus().map(|f| f.text_input).unwrap_or(true) {
            blocking(move || input::click(c)).await;
            sleep(150).await;
        }
        Ok(())
    }

    fn invoke(&self, handle: u64) -> bool {
        uia::uia().invoke(handle)
    }

    fn set_element_value(&self, handle: u64, text: &str) -> bool {
        uia::uia().set_value(handle, text)
    }

    async fn type_text(&self, text: &str, app: &AppRef) -> Result<(), String> {
        input::set_target(Some(app.hwnd));
        let r = async {
            let has_text = self.focused_value().map(|v| !v.is_empty()).unwrap_or(false);
            // Browser editors whose text Automation can't see (Google Docs): paste once, fast.
            if self.is_browser(app) && uia::uia().focus().map(|f| f.value.is_none()).unwrap_or(true) {
                self.paste(text);
                return Ok(());
            }
            // Long text is pasted (typing 2,000 characters takes minutes).
            if text.chars().count() > 300 {
                if has_text {
                    self.select_all();
                    sleep(60).await;
                }
                self.paste(text);
                return if self.landed(text).await { Ok(()) } else { Err("the text didn't land in the field".to_string()) };
            }
            if text.contains('\n') {
                self.select_all();
                sleep(80).await;
                self.enter_text(text, false).await;
                return if self.landed(text).await { Ok(()) } else { Err("the text didn't land in the field".to_string()) };
            }
            if has_text {
                self.select_all();
                sleep(60).await;
            }
            if !self.keystrokes(text).await {
                return Err("the app lost focus while typing, so I stopped".to_string());
            }
            if self.landed(text).await {
                return Ok(());
            }
            // Retry by pasting, replacing (never appending to) what's there.
            self.select_all();
            sleep(60).await;
            self.paste(text);
            if self.landed(text).await {
                return Ok(());
            }
            Err(format!("the text didn't land (the field shows {:?})", self.focused_value().unwrap_or_default().chars().take(60).collect::<String>()))
        }
        .await;
        input::set_target(None);
        r
    }

    async fn enter_text(&self, text: &str, code_editor: bool) {
        if !text.contains('\n') {
            self.keystrokes(text).await;
            return;
        }
        for (i, line) in text.split('\n').enumerate() {
            if i > 0 {
                let _ = input::press_combo("shift+enter");
                sleep(50).await;
            }
            let line = if code_editor { line.trim_start() } else { line };
            if !self.keystrokes(line).await {
                return;
            }
        }
        if code_editor {
            // The editor's auto-indent has had its say; now make it exactly right.
            sleep(200).await;
            self.select_all();
            sleep(60).await;
            self.paste(text);
            sleep(150).await;
        }
    }

    fn press(&self, combo: &str) -> Result<(), String> {
        input::press_combo(combo)
    }

    fn paste(&self, text: &str) {
        let saved = clipboard::text();
        clipboard::set_text(text, true);
        let _ = input::press_combo("ctrl+v");
        std::thread::sleep(Duration::from_millis(250));
        if let Some(s) = saved {
            clipboard::set_text(&s, true);
        }
    }

    fn select_all(&self) {
        let _ = input::press_combo("ctrl+a");
    }

    async fn scroll(&self, app: &AppRef, up: bool) {
        let Some(r) = apps::window_rect(Self::live_hwnd(app).0) else { return };
        let p = r.center();
        self.buddy.travel(p, None).await;
        for _ in 0..4 {
            input::scroll(p, if up { 3 } else { -3 });
            sleep(60).await;
        }
        *self.cursor_left_at.lock() = Some(input::cursor());
        sleep(200).await;
    }

    fn set_target(&self, app: Option<&AppRef>) {
        input::set_target(app.map(|a| a.hwnd));
    }

    fn begin_run(&self) {
        *self.run_cursor.lock() = Some(input::cursor());
        *self.cursor_left_at.lock() = None;
        *self.run_front.lock() = apps::foreground().map(|f| f.0).filter(|h| apps::pid_of(*h) != apps::own_pid());
    }

    fn end_run(&self, keep_front_app: bool) {
        input::release_all();
        input::set_target(None);
        if let (Some(start), Some(left)) = (*self.run_cursor.lock(), *self.cursor_left_at.lock()) {
            if input::cursor().distance(left) <= 2.0 {
                input::set_cursor(start);
            }
        }
        if !keep_front_app {
            if let Some(h) = self.run_front.lock().take() {
                if apps::is_window(h) && apps::foreground().map(|f| f.0 != h).unwrap_or(true) {
                    std::thread::spawn(move || {
                        crate::com::ensure();
                        apps::bring_to_front(h);
                    });
                }
            }
        }
        *self.run_cursor.lock() = None;
        *self.cursor_left_at.lock() = None;
    }

    fn clipboard_text(&self) -> Option<String> {
        clipboard::text()
    }

    fn set_clipboard_text(&self, text: &str) {
        clipboard::set_text(text, false);
    }

    fn set_clipboard_png(&self, png: &[u8]) -> bool {
        clipboard::set_png(png)
    }

    fn clipboard_files(&self) -> Vec<PathBuf> {
        clipboard::files()
    }

    fn clipboard_sequence(&self) -> u32 {
        clipboard::sequence()
    }

    async fn search_files(&self, query: &FileQuery) -> Vec<FileHit> {
        let q = query.clone();
        blocking(move || system::search_files(&q)).await
    }

    fn trash(&self, paths: &[PathBuf]) -> Result<usize, String> {
        system::trash(paths)
    }

    fn mic_in_use(&self) -> bool {
        system::mic_in_use()
    }

    fn screen_locked(&self) -> bool {
        system::screen_locked()
    }

    async fn shell(&self, command: &str, timeout_secs: u64) -> (i32, String) {
        system::powershell(command, timeout_secs).await
    }

    fn reveal(&self, paths: &[PathBuf]) {
        system::reveal(paths)
    }

    fn open_path(&self, path: &Path) -> bool {
        system::shell_open(&path.display().to_string())
    }

    fn open_url_direct(&self, url: &str) -> bool {
        system::shell_open(url)
    }
}
