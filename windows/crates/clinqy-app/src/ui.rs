//! The two windows: the command bar (Spotlight-like; takes the keyboard) and the status island (top of the screen,
//! never takes focus, so the app being worked on stays in front). Both are WebView2 pages, rounded, and kept out
//! of screenshots and screen shares like the Mac app's panels.

use crate::app::UserEvent;
use serde_json::Value;
use tao::dpi::{LogicalSize, PhysicalPosition};
use tao::event_loop::{EventLoop, EventLoopProxy};
use tao::platform::windows::{WindowBuilderExtWindows, WindowExtWindows};
use tao::window::{Window, WindowBuilder};
use windows::Win32::Foundation::HWND;
use windows::Win32::Graphics::Dwm::{DwmSetWindowAttribute, DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND};
use windows::Win32::UI::WindowsAndMessaging::*;
use wry::{WebView, WebViewBuilder};

const BAR_HTML: &str = include_str!("ui/web/bar.html");
const ISLAND_HTML: &str = include_str!("ui/web/island.html");
const BAR_WIDTH: f64 = 660.0;
const ISLAND_WIDTH: f64 = 540.0;

fn style(window: &Window, no_activate: bool) {
    let hwnd = HWND(window.hwnd() as _);
    unsafe {
        let pref = DWMWCP_ROUND;
        let _ = DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &pref as *const _ as _, std::mem::size_of_val(&pref) as u32);
        let _ = SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
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
    use windows::Win32::Foundation::POINT;
    use windows::Win32::Graphics::Gdi::{GetMonitorInfoW, MonitorFromPoint, MONITORINFO, MONITOR_DEFAULTTONEAREST};
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

pub struct Bar {
    pub window: Window,
    view: WebView,
}

impl Bar {
    pub fn new(event_loop: &EventLoop<UserEvent>, proxy: EventLoopProxy<UserEvent>) -> anyhow::Result<Bar> {
        let window = WindowBuilder::new()
            .with_title("Clinqy")
            .with_decorations(false)
            .with_resizable(false)
            .with_visible(false)
            .with_always_on_top(true)
            .with_skip_taskbar(true)
            .with_undecorated_shadow(true)
            .with_inner_size(LogicalSize::new(BAR_WIDTH, 64.0))
            .build(event_loop)?;
        style(&window, false);
        let view = WebViewBuilder::new()
            .with_html(BAR_HTML)
            .with_background_color((23, 23, 26, 255))
            .with_ipc_handler(move |req| {
                let _ = proxy.send_event(UserEvent::Bar(req.body().to_string()));
            })
            .build(&window)?;
        Ok(Bar { window, view })
    }

    pub fn visible(&self) -> bool {
        unsafe { IsWindowVisible(HWND(self.window.hwnd() as _)).as_bool() }
    }

    pub fn show(&self, state: &Value) {
        js(&self.view, "update", state);
        if !self.visible() {
            let (x, y, w, h) = work_area();
            let scale = self.window.scale_factor();
            let bw = (BAR_WIDTH * scale) as i32;
            self.window.set_outer_position(PhysicalPosition::new(x + (w - bw) / 2, y + (h as f64 * 0.16) as i32));
        }
        self.window.set_visible(true);
        // Clinqy isn't the foreground app when the hotkey fires; this makes the bar take the keyboard.
        clinqy_windows::apps::bring_to_front(self.window.hwnd() as isize);
        self.window.set_focus();
        self.focus();
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
        self.window.set_inner_size(LogicalSize::new(BAR_WIDTH, height.clamp(64.0, 600.0)));
    }
}

pub struct Island {
    window: Window,
    view: WebView,
}

impl Island {
    pub fn new(event_loop: &EventLoop<UserEvent>, proxy: EventLoopProxy<UserEvent>) -> anyhow::Result<Island> {
        let window = WindowBuilder::new()
            .with_title("Clinqy status")
            .with_decorations(false)
            .with_resizable(false)
            .with_visible(false)
            .with_always_on_top(true)
            .with_skip_taskbar(true)
            .with_focused(false)
            .with_undecorated_shadow(true)
            .with_inner_size(LogicalSize::new(ISLAND_WIDTH, 48.0))
            .build(event_loop)?;
        style(&window, true);
        let view = WebViewBuilder::new()
            .with_html(ISLAND_HTML)
            .with_background_color((23, 23, 26, 255))
            .with_ipc_handler(move |req| {
                let _ = proxy.send_event(UserEvent::Island(req.body().to_string()));
            })
            .build(&window)?;
        Ok(Island { window, view })
    }

    fn hwnd(&self) -> HWND {
        HWND(self.window.hwnd() as _)
    }

    pub fn show(&self) {
        let visible = unsafe { IsWindowVisible(self.hwnd()).as_bool() };
        if !visible {
            let (x, y, w, _) = work_area();
            let scale = self.window.scale_factor();
            let iw = (ISLAND_WIDTH * scale) as i32;
            self.window.set_outer_position(PhysicalPosition::new(x + (w - iw) / 2, y + (8.0 * scale) as i32));
        }
        // Shown without taking focus from the app being worked on.
        unsafe {
            let _ = ShowWindow(self.hwnd(), SW_SHOWNOACTIVATE);
            let _ = SetWindowPos(self.hwnd(), HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }
    }

    pub fn hide(&self) {
        let _ = self.view.evaluate_script("window.clinqy && window.clinqy.card(false)");
        unsafe {
            let _ = ShowWindow(self.hwnd(), SW_HIDE);
        }
    }

    pub fn update(&self, state: &Value) {
        js(&self.view, "update", state);
    }

    pub fn card(&self, on: bool) {
        let _ = self.view.evaluate_script(&format!("window.clinqy && window.clinqy.card({on})"));
    }

    /// A one-line notice (a reminder, a hint) in the capsule.
    pub fn notice(&self, text: &str) {
        let v = serde_json::json!({"phase": "done", "answer": text, "running": false, "steps": []});
        js(&self.view, "update", &v);
        self.show();
    }

    pub fn resize(&self, height: f64) {
        let h = height.clamp(48.0, 480.0);
        let size = LogicalSize::new(ISLAND_WIDTH, h);
        self.window.set_inner_size(size);
    }
}
