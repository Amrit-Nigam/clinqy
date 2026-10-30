//! The windows, styled exactly like the Mac app's panels: the command bar (Spotlight-like; takes the keyboard),
//! the result card (top right; clickable but never takes focus), the status island (top centre; drawn natively in
//! `clinqy_windows::island` so it can be click-through), the Clinqy window (setup and dashboard) and the background
//! work view. The bar and card are WebView2 pages on transparent windows, so their 22 pt / 18 pt corners are the
//! Mac's; those two and the island are kept out of screenshots and shares.

use crate::app::UserEvent;
use clinqy_core::platform::Mood;
use clinqy_windows::island::{Island as NativeIsland, IslandState};
use serde_json::Value;
use tao::dpi::{LogicalSize, PhysicalPosition};
use tao::event_loop::{EventLoop, EventLoopProxy};
use tao::platform::windows::{WindowBuilderExtWindows, WindowExtWindows};
use tao::window::{Window, WindowBuilder};
use windows::Win32::Foundation::{HWND, POINT};
use windows::Win32::Graphics::Gdi::{GetMonitorInfoW, MonitorFromPoint, MONITORINFO, MONITOR_DEFAULTTONEAREST};
use windows::Win32::UI::WindowsAndMessaging::*;
use wry::{WebContext, WebView, WebViewBuilder};

const SHARED_CSS: &str = include_str!("ui/web/shared.css");
const ICONS_JS: &str = include_str!("ui/web/icons.js");
const BAR_WIDTH: f64 = 612.0;
const RESULT_WIDTH: f64 = 420.0;

fn page(html: &str) -> String {
    html.replace("/*SHARED_CSS*/", SHARED_CSS).replace("/*ICONS_JS*/", ICONS_JS)
}

/// Topmost, no taskbar button, out of screen captures; `no_activate` for windows that must never take focus.
fn style(window: &Window, no_activate: bool) {
    let hwnd = HWND(window.hwnd() as _);
    unsafe {
        clinqy_windows::screen::hide_from_capture(hwnd.0 as isize);
        let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        let mut add = (WS_EX_TOOLWINDOW.0 | WS_EX_TOPMOST.0) as isize;
        if no_activate {
            add |= WS_EX_NOACTIVATE.0 as isize;
        }
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex | add);
    }
}

/// The work area of the monitor under the pointer (physical pixels).
fn work_area() -> (i32, i32, i32, i32) {
    unsafe {
        let mut p = POINT::default();
        let _ = GetCursorPos(&mut p);
        let m = MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST);
        let mut info = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
        let _ = GetMonitorInfoW(m, &mut info);
        let r = info.rcWork;
        (r.left, r.top, r.right - r.left, r.bottom - r.top)
    }
}

fn js(view: &WebView, call: &str, v: &Value) {
    let _ = view.evaluate_script(&format!("window.clinqy && window.clinqy.{call}({v})"));
}

/// WebView2's profile lives with Clinqy's local data, not next to the exe (which may not be writable).
fn web_context() -> WebContext {
    WebContext::new(Some(clinqy_core::paths::local_dir().join("WebView2")))
}

fn transparent_window(event_loop: &EventLoop<UserEvent>, title: &str, w: f64, h: f64) -> anyhow::Result<Window> {
    Ok(WindowBuilder::new()
        .with_title(title)
        .with_decorations(false)
        .with_resizable(false)
        .with_visible(false)
        .with_transparent(true)
        .with_always_on_top(true)
        .with_skip_taskbar(true)
        .with_undecorated_shadow(false)
        .with_inner_size(LogicalSize::new(w, h))
        .build(event_loop)?)
}

pub struct Bar {
    pub window: Window,
    view: WebView,
    _context: WebContext,
}

/// The Clinqy window: setup and the dashboard, styled like the Mac app's. A regular, resizable window.
pub struct Dashboard {
    pub window: Window,
    view: WebView,
    _context: WebContext,
}

/// @font-face rules for the Mac app's fonts (Geist Pixel and Geist Mono), inside the page.
fn fonts() -> String {
    use base64::Engine;
    let face = |name: &str, weight: &str, bytes: &[u8]| {
        format!(
            "@font-face{{font-family:\"{name}\";font-weight:{weight};src:url(data:font/woff2;base64,{}) format(\"woff2\")}}",
            base64::engine::general_purpose::STANDARD.encode(bytes)
        )
    };
    face("Geist Mono", "100 900", include_bytes!("../../../../website/public/fonts/GeistMono-Variable.woff2")) + &face("Geist Pixel", "400", include_bytes!("../../../../website/public/fonts/GeistPixel-Square.woff2"))
}

impl Dashboard {
    pub fn new(event_loop: &EventLoop<UserEvent>, proxy: EventLoopProxy<UserEvent>) -> anyhow::Result<Dashboard> {
        let window = WindowBuilder::new()
            .with_title("Clinqy")
            .with_visible(false)
            .with_resizable(true)
            .with_inner_size(LogicalSize::new(1000.0, 700.0))
            .with_min_inner_size(LogicalSize::new(900.0, 640.0))
            .build(event_loop)?;
        let mut context = web_context();
        let view = WebViewBuilder::with_web_context(&mut context)
            .with_html(include_str!("ui/web/app.html").replace("/*FONTS*/", &fonts()))
            .with_background_color((8, 9, 13, 255))
            .with_ipc_handler(move |req| {
                let _ = proxy.send_event(UserEvent::Dashboard(req.body().to_string()));
            })
            .build(&window)?;
        Ok(Dashboard { window, view, _context: context })
    }

    pub fn visible(&self) -> bool {
        unsafe { IsWindowVisible(HWND(self.window.hwnd() as _)).as_bool() }
    }

    pub fn present(&self, state: &Value) {
        self.update(state);
        if !self.visible() {
            let (x, y, w, h) = work_area();
            let size = self.window.outer_size();
            self.window.set_outer_position(PhysicalPosition::new(x + (w - size.width as i32) / 2, y + (h - size.height as i32) / 2));
        }
        self.window.set_visible(true);
        clinqy_windows::apps::bring_to_front(self.window.hwnd() as isize);
        self.window.set_focus();
    }

    pub fn hide(&self) {
        self.window.set_visible(false);
    }

    pub fn update(&self, state: &Value) {
        js(&self.view, "update", state);
    }

    /// Goes to "setup" or a dashboard tab.
    pub fn show_page(&self, page: &str) {
        js(&self.view, "show", &Value::String(page.to_string()));
    }

    pub fn call(&self, script: &str) {
        let _ = self.view.evaluate_script(&format!("window.clinqy && window.clinqy.{script}"));
    }
}

/// "Clinqy — background work": what the background browser shows, refreshed while it's open, with a box to steer it.
pub struct LiveView {
    pub window: Window,
    view: WebView,
    _context: WebContext,
}

impl LiveView {
    pub fn new(event_loop: &EventLoop<UserEvent>, proxy: EventLoopProxy<UserEvent>) -> anyhow::Result<LiveView> {
        let window = WindowBuilder::new()
            .with_title("Clinqy — background work")
            .with_visible(false)
            .with_resizable(true)
            .with_inner_size(LogicalSize::new(760.0, 520.0))
            .with_min_inner_size(LogicalSize::new(480.0, 360.0))
            .build(event_loop)?;
        let mut context = web_context();
        let view = WebViewBuilder::with_web_context(&mut context)
            .with_html(page(include_str!("ui/web/live.html")))
            .with_background_color((8, 9, 13, 255))
            .with_ipc_handler(move |req| {
                let _ = proxy.send_event(UserEvent::Live(req.body().to_string()));
            })
            .build(&window)?;
        Ok(LiveView { window, view, _context: context })
    }

    pub fn visible(&self) -> bool {
        unsafe { IsWindowVisible(HWND(self.window.hwnd() as _)).as_bool() }
    }

    pub fn present(&self) {
        self.window.set_visible(true);
        clinqy_windows::apps::bring_to_front(self.window.hwnd() as isize);
        self.window.set_focus();
    }

    pub fn hide(&self) {
        self.window.set_visible(false);
    }

    pub fn frame(&self, jpeg: &str) {
        js(&self.view, "frame", &Value::String(jpeg.to_string()));
    }

    pub fn state(&self, state: &Value) {
        js(&self.view, "state", state);
    }
}

impl Bar {
    pub fn new(event_loop: &EventLoop<UserEvent>, proxy: EventLoopProxy<UserEvent>) -> anyhow::Result<Bar> {
        let window = transparent_window(event_loop, "Clinqy", BAR_WIDTH, 300.0)?;
        style(&window, false);
        let mut context = web_context();
        let view = WebViewBuilder::with_web_context(&mut context)
            .with_html(page(include_str!("ui/web/bar.html")))
            .with_transparent(true)
            .with_background_color((0, 0, 0, 0))
            .with_ipc_handler(move |req| {
                let _ = proxy.send_event(UserEvent::Bar(req.body().to_string()));
            })
            .build(&window)?;
        Ok(Bar { window, view, _context: context })
    }

    pub fn visible(&self) -> bool {
        unsafe { IsWindowVisible(HWND(self.window.hwnd() as _)).as_bool() }
    }

    pub fn show(&self, state: &Value) {
        js(&self.view, "update", state);
        if !self.visible() {
            // Centred, a sixth of the way down the screen (the Mac's spot).
            let (x, y, w, h) = work_area();
            let bw = (BAR_WIDTH * self.window.scale_factor()) as i32;
            self.window.set_outer_position(PhysicalPosition::new(x + (w - bw) / 2, y + (h as f64 * 0.16) as i32));
        }
        self.window.set_visible(true);
        // Clinqy isn't the foreground app when the hotkey fires; this makes the bar take the keyboard.
        clinqy_windows::apps::bring_to_front(self.window.hwnd() as isize);
        self.window.set_focus();
        self.focus();
    }

    /// Whether the foreground window is the bar (or its WebView).
    pub fn has_focus(&self) -> bool {
        unsafe {
            let f = GetForegroundWindow();
            let root = GetAncestor(f, GA_ROOT);
            root.0 as isize == self.window.hwnd() as isize
        }
    }

    pub fn focus(&self) {
        let _ = self.view.focus();
        let _ = self.view.evaluate_script("window.clinqy && window.clinqy.focus()");
    }

    pub fn hide(&self) {
        self.window.set_visible(false);
    }

    pub fn clear(&self) {
        let _ = self.view.evaluate_script("window.clinqy && window.clinqy.clear()");
    }

    pub fn update(&self, state: &Value) {
        js(&self.view, "update", state);
    }

    pub fn level(&self, l: f32) {
        if self.visible() {
            let _ = self.view.evaluate_script(&format!("window.clinqy && window.clinqy.level({l})"));
        }
    }

    pub fn resize(&self, height: f64) {
        self.window.set_inner_size(LogicalSize::new(BAR_WIDTH, height.clamp(64.0, 640.0).ceil()));
    }
}

/// The result card: top right, 12 pt from the edges.
pub struct ResultPanel {
    window: Window,
    view: WebView,
    _context: WebContext,
}

impl ResultPanel {
    pub fn new(event_loop: &EventLoop<UserEvent>, proxy: EventLoopProxy<UserEvent>) -> anyhow::Result<ResultPanel> {
        let window = transparent_window(event_loop, "Clinqy result", RESULT_WIDTH, 200.0)?;
        style(&window, true);
        let mut context = web_context();
        let view = WebViewBuilder::with_web_context(&mut context)
            .with_html(page(include_str!("ui/web/result.html")))
            .with_transparent(true)
            .with_background_color((0, 0, 0, 0))
            .with_ipc_handler(move |req| {
                let _ = proxy.send_event(UserEvent::Result(req.body().to_string()));
            })
            .build(&window)?;
        Ok(ResultPanel { window, view, _context: context })
    }

    fn hwnd(&self) -> HWND {
        HWND(self.window.hwnd() as _)
    }

    pub fn show(&self, card: &Value) {
        js(&self.view, "update", card);
        let (x, y, w, _) = work_area();
        let s = self.window.scale_factor();
        let pw = (RESULT_WIDTH * s) as i32;
        self.window.set_outer_position(PhysicalPosition::new(x + w - pw - (12.0 * s) as i32, y + (12.0 * s) as i32));
        unsafe {
            let _ = ShowWindow(self.hwnd(), SW_SHOWNOACTIVATE);
            let _ = SetWindowPos(self.hwnd(), HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }
    }

    pub fn hide(&self) {
        unsafe {
            let _ = ShowWindow(self.hwnd(), SW_HIDE);
        }
    }

    pub fn resize(&self, height: f64) {
        self.window.set_inner_size(LogicalSize::new(RESULT_WIDTH, height.clamp(60.0, 640.0).ceil()));
    }
}

/// The status island (native, click-through).
pub struct Island {
    native: NativeIsland,
    last: parking_lot::Mutex<IslandState>,
}

impl Island {
    pub fn new() -> Island {
        Island { native: NativeIsland::start(), last: parking_lot::Mutex::new(IslandState::default()) }
    }

    /// The capsule's content from the agent's state (IslandView's rules).
    pub fn update(&self, s: &Value, visible: bool) {
        let hotkey = s["hotkey"].as_str().unwrap_or("Ctrl+Alt");
        let listening = s["listening"] == true;
        let talk = s["talkKey"].as_str().unwrap_or("");
        let paused = s["running"] == true && s["paused"] == true;
        let text = if listening {
            s["transcript"].as_str().filter(|t| !t.is_empty()).map(String::from).unwrap_or_else(|| {
                if s["followUp"] == true {
                    "Anything else? I'm listening…".into()
                } else if !talk.is_empty() {
                    format!("Listening… let go of {talk} to send")
                } else {
                    "Listening…".into()
                }
            })
        } else if s["recording"] == true {
            format!("Watching you… do the task, then {hotkey} or ■ to stop")
        } else if s["transcribing"] == true {
            "Transcribing…".into()
        } else if let Some(n) = s["notice"].as_str() {
            n.to_string()
        } else if let Some(q) = s["question"]["text"].as_str() {
            format!("Needs your input: {q}")
        } else if let Some(t) = s["review"]["title"].as_str() {
            format!("Check before I submit: {t}")
        } else if paused {
            format!("Paused · {}", s["narration"].as_str().filter(|t| !t.is_empty()).unwrap_or("between steps"))
        } else if s["running"] == true {
            s["narration"].as_str().filter(|t| !t.is_empty()).unwrap_or("Thinking…").to_string()
        } else {
            s["answer"].as_str().filter(|t| !t.is_empty()).or(s["narration"].as_str().filter(|t| !t.is_empty())).unwrap_or("Thinking…").to_string()
        };
        let hint = if paused {
            format!("{hotkey} to resume or stop")
        } else if s["running"] == true {
            if s["dry"] == true {
                "dry run · ■ to stop".to_string()
            } else {
                format!("{hotkey} to add · ■ to stop")
            }
        } else {
            String::new()
        };
        let mood = if listening {
            Mood::Listening
        } else if paused {
            Mood::Idle
        } else {
            match s["phase"].as_str().unwrap_or("idle") {
                "thinking" => Mood::Thinking,
                "acting" => Mood::Acting,
                "done" => Mood::Success,
                "failed" => Mood::Failure,
                "listening" => Mood::Listening,
                _ => Mood::Idle,
            }
        };
        let state = IslandState { visible, text, hint, mood, level: s["level"].as_f64().unwrap_or(0.0) as f32, head: listening };
        let mut last = self.last.lock();
        if *last != state {
            *last = state.clone();
            self.native.set(state);
        }
    }

    pub fn hide(&self) {
        let mut last = self.last.lock();
        if last.visible {
            last.visible = false;
            self.native.set(last.clone());
        }
    }

    pub fn level(&self, l: f32) {
        let mut last = self.last.lock();
        if last.visible && last.mood == Mood::Listening {
            last.level = l;
            self.native.set(last.clone());
        }
    }
}
