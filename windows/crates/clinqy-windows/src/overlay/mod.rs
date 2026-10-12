//! The companion cursor: a glowing arrow that rides beside the user's pointer, flies in arcs to what it's about to
//! use, frames it, ripples on clicks and draws marks for the user. It's a click-through, never-activating layered
//! window on its own thread, kept out of screenshots and screen shares, sized each frame to what it draws.

mod draw;

use crate::com::wide;
use async_trait::async_trait;
use clinqy_core::platform::{Buddy, Mood, Point, Rect};
use std::cell::RefCell;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::{Duration, Instant};
use tiny_skia::Pixmap;
use tokio::sync::oneshot;
use windows::core::PCWSTR;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::WindowsAndMessaging::*;

enum Cmd {
    Travel(Point, Option<Rect>, oneshot::Sender<()>),
    Click,
    Mark(Rect, Option<String>, oneshot::Sender<()>),
    ClearMark,
    ClearHighlight,
    Bubble(Option<String>, f64),
    Mood(Mood),
    Typing(bool),
    Level(f32),
    Home,
    Signal(bool),
    Qa(bool),
}

const WM_WAKE: u32 = WM_APP + 1;
const TIMER: usize = 1;

pub struct Overlay {
    tx: Sender<Cmd>,
    hwnd: std::sync::atomic::AtomicIsize,
}

struct Flight {
    from: Point,
    to: Point,
    started: Instant,
    duration: f64,
    control: Point,
    done: Option<oneshot::Sender<()>>,
}

struct State {
    hwnd: HWND,
    pos: Point,
    flight: Option<Flight>,
    /// Away from the pointer (after travelling) until sent home.
    away: bool,
    frame: Option<(Rect, Instant)>,
    ripple: Option<(Point, Instant)>,
    mark: Option<(Rect, Option<String>, Instant)>,
    bubble: Option<(String, Instant, f64)>,
    signal: Option<(bool, Instant)>,
    mood: Mood,
    typing: bool,
    level: f32,
    qa: bool,
    /// Last time anything happened; the cursor fades out when idle.
    active: Instant,
    alpha: f32,
    visible_area: Option<RECT>,
    start: Instant,
}

thread_local! {
    static STATE: RefCell<Option<State>> = const { RefCell::new(None) };
    static RX: RefCell<Option<Receiver<Cmd>>> = const { RefCell::new(None) };
}

fn dpi_scale(p: Point) -> f32 {
    unsafe {
        let m = MonitorFromPoint(POINT { x: p.x as i32, y: p.y as i32 }, MONITOR_DEFAULTTONEAREST);
        let (mut x, mut y) = (96u32, 96u32);
        if GetDpiForMonitor(m, MDT_EFFECTIVE_DPI, &mut x, &mut y).is_ok() {
            x as f32 / 96.0
        } else {
            1.0
        }
    }
}

fn ease(t: f64) -> f64 {
    if t < 0.5 {
        4.0 * t * t * t
    } else {
        1.0 - (-2.0 * t + 2.0).powi(3) / 2.0
    }
}

fn home_point() -> Point {
    let c = crate::input::cursor();
    let s = dpi_scale(c) as f64;
    Point::new(c.x + 16.0 * s, c.y + 14.0 * s)
}

impl Overlay {
    pub fn start() -> Overlay {
        let (tx, rx) = channel::<Cmd>();
        let (htx, hrx) = std::sync::mpsc::channel::<isize>();
        std::thread::Builder::new()
            .name("clinqy-buddy".into())
            .spawn(move || unsafe {
                let class = wide("ClinqyBuddy");
                let inst = GetModuleHandleW(None).unwrap_or_default();
                let wc = WNDCLASSW { lpfnWndProc: Some(proc_), hInstance: inst.into(), lpszClassName: PCWSTR(class.as_ptr()), ..Default::default() };
                RegisterClassW(&wc);
                let hwnd = CreateWindowExW(
                    WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
                    PCWSTR(class.as_ptr()),
                    PCWSTR(wide("Clinqy cursor").as_ptr()),
                    WS_POPUP,
                    0,
                    0,
                    1,
                    1,
                    None,
                    None,
                    inst,
                    None,
                )
                .unwrap_or_default();
                // Never in Clinqy's own screenshots or the user's screen shares.
                let _ = SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
                let now = Instant::now();
                STATE.with(|s| {
                    *s.borrow_mut() = Some(State {
                        hwnd,
                        pos: home_point(),
                        flight: None,
                        away: false,
                        frame: None,
                        ripple: None,
                        mark: None,
                        bubble: None,
                        signal: None,
                        mood: Mood::Idle,
                        typing: false,
                        level: 0.0,
                        qa: false,
                        active: now - Duration::from_secs(60),
                        alpha: 0.0,
                        visible_area: None,
                        start: now,
                    })
                });
                RX.with(|r| *r.borrow_mut() = Some(rx));
                let _ = htx.send(hwnd.0 as isize);
                SetTimer(hwnd, TIMER, 16, None);
                let mut msg = MSG::default();
                while GetMessageW(&mut msg, None, 0, 0).as_bool() {
                    let _ = TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
            })
            .expect("couldn't start the cursor overlay");
        let hwnd = hrx.recv_timeout(Duration::from_secs(5)).unwrap_or(0);
        Overlay { tx, hwnd: std::sync::atomic::AtomicIsize::new(hwnd) }
    }

    fn send(&self, c: Cmd) {
        let _ = self.tx.send(c);
        let h = self.hwnd.load(std::sync::atomic::Ordering::Relaxed);
        unsafe {
            let _ = PostMessageW(HWND(h as _), WM_WAKE, WPARAM(0), LPARAM(0));
        }
    }

    pub fn hwnd(&self) -> isize {
        self.hwnd.load(std::sync::atomic::Ordering::Relaxed)
    }
}

unsafe extern "system" fn proc_(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        WM_WAKE => {
            drain();
            tick();
            LRESULT(0)
        }
        WM_TIMER => {
            tick();
            LRESULT(0)
        }
        WM_NCHITTEST => LRESULT(HTTRANSPARENT as isize),
        _ => DefWindowProcW(hwnd, msg, wp, lp),
    }
}

fn drain() {
    let cmds: Vec<Cmd> = RX.with(|r| r.borrow().as_ref().map(|rx| rx.try_iter().collect()).unwrap_or_default());
    STATE.with(|s| {
        let mut b = s.borrow_mut();
        let Some(st) = b.as_mut() else { return };
        let now = Instant::now();
        for c in cmds {
            st.active = now;
            match c {
                Cmd::Travel(to, framing, done) => {
                    if st.alpha < 0.05 {
                        st.pos = home_point();
                    }
                    let from = st.pos;
                    let d = from.distance(to);
                    let s = dpi_scale(to) as f64;
                    // Quick for short hops, longer arcs for long ones.
                    let duration = (0.16 + d / (2600.0 * s)).min(0.55);
                    let (mx, my) = ((from.x + to.x) / 2.0, (from.y + to.y) / 2.0);
                    let (dx, dy) = (to.x - from.x, to.y - from.y);
                    let bend = (d * 0.18).min(120.0 * s);
                    let len = d.max(1.0);
                    let control = Point::new(mx - dy / len * bend, my + dx / len * bend);
                    if let Some(f) = st.flight.take() {
                        if let Some(dn) = f.done {
                            let _ = dn.send(());
                        }
                    }
                    if d < 2.0 {
                        st.pos = to;
                        let _ = done.send(());
                    } else {
                        st.flight = Some(Flight { from, to, started: now, duration, control, done: Some(done) });
                    }
                    st.frame = framing.map(|r| (r, now));
                    st.away = true;
                }
                Cmd::Click => st.ripple = Some((st.pos, now)),
                Cmd::Mark(r, label, done) => {
                    st.mark = Some((r, label, now));
                    // The cursor flies over to point at it.
                    let target = Point::new(r.x - 30.0, r.y - 24.0);
                    let from = st.pos;
                    st.flight = Some(Flight { from, to: target, started: now, duration: 0.35, control: Point::new((from.x + target.x) / 2.0, (from.y + target.y) / 2.0 - 40.0), done: None });
                    st.away = true;
                    let _ = done.send(());
                }
                Cmd::ClearMark => st.mark = None,
                Cmd::ClearHighlight => st.frame = None,
                Cmd::Bubble(text, secs) => st.bubble = text.map(|t| (t, now, secs)),
                Cmd::Mood(m) => st.mood = m,
                Cmd::Typing(on) => st.typing = on,
                Cmd::Level(l) => st.level = l,
                Cmd::Home => {
                    st.away = false;
                    st.frame = None;
                }
                Cmd::Signal(pass) => st.signal = Some((pass, now)),
                Cmd::Qa(on) => st.qa = on,
            }
        }
    });
}

fn tick() {
    STATE.with(|s| {
        let mut b = s.borrow_mut();
        let Some(st) = b.as_mut() else { return };
        let now = Instant::now();
        // Movement.
        if let Some(f) = st.flight.as_mut() {
            let t = (now.duration_since(f.started).as_secs_f64() / f.duration).min(1.0);
            let e = ease(t);
            let u = 1.0 - e;
            st.pos = Point::new(u * u * f.from.x + 2.0 * u * e * f.control.x + e * e * f.to.x, u * u * f.from.y + 2.0 * u * e * f.control.y + e * e * f.to.y);
            st.active = now;
            if t >= 1.0 {
                if let Some(d) = f.done.take() {
                    let _ = d.send(());
                }
                st.flight = None;
            }
        } else if !st.away {
            // Ride beside the pointer, easing after it.
            let h = home_point();
            st.pos = Point::new(st.pos.x + (h.x - st.pos.x) * 0.35, st.pos.y + (h.y - st.pos.y) * 0.35);
        }
        // Expire transient effects.
        if st.ripple.map(|r| now.duration_since(r.1) > Duration::from_millis(420)).unwrap_or(false) {
            st.ripple = None;
        }
        if st.signal.map(|r| now.duration_since(r.1) > Duration::from_millis(1100)).unwrap_or(false) {
            st.signal = None;
        }
        if st.bubble.as_ref().map(|b| now.duration_since(b.1).as_secs_f64() > b.2).unwrap_or(false) {
            st.bubble = None;
        }
        if st.mark.as_ref().map(|m| now.duration_since(m.2) > Duration::from_secs(8)).unwrap_or(false) {
            st.mark = None;
        }
        // Shown while something is going on; fades out after a few idle seconds.
        let busy = st.mood != Mood::Idle || st.flight.is_some() || st.mark.is_some() || st.bubble.is_some() || st.typing || st.away;
        if busy {
            st.active = now;
        }
        let want = if now.duration_since(st.active) < Duration::from_millis(2500) { 1.0 } else { 0.0 };
        st.alpha += (want - st.alpha) * 0.18;
        if st.alpha < 0.02 && want == 0.0 {
            st.alpha = 0.0;
        }
        render(st);
    });
}

fn render(st: &mut State) {
    if st.alpha <= 0.0 {
        if st.visible_area.take().is_some() {
            unsafe {
                let _ = ShowWindow(st.hwnd, SW_HIDE);
            }
        }
        return;
    }
    let s = dpi_scale(st.pos);
    let rgb = draw::mood_color(st.mood, st.qa);
    // Bounds of everything drawn this frame.
    let pad = 40.0 * s as f64;
    let mut b = Rect::new(st.pos.x - pad, st.pos.y - pad, 2.0 * pad, 2.0 * pad);
    let mut grow = |r: Rect| {
        let (x0, y0) = (b.x.min(r.x), b.y.min(r.y));
        let (x1, y1) = (b.max_x().max(r.max_x()), b.max_y().max(r.max_y()));
        b = Rect::new(x0, y0, x1 - x0, y1 - y0);
    };
    if let Some((r, _)) = st.frame {
        grow(r.inset(-8.0));
    }
    if let Some((r, ref label, _)) = st.mark {
        grow(r.inset(-(30.0 * s as f64 + 24.0)));
        grow(Rect::new(r.x - 140.0 * s as f64, r.y - 110.0 * s as f64, 10.0, 10.0));
        if let Some(l) = label {
            let w = crate::text::measure(&crate::text::fonts().bold, l, 13.0 * s) as f64 + 40.0;
            grow(Rect::new(r.x - 60.0 * s as f64 - w, r.y - 120.0 * s as f64, w * 2.0, 40.0));
        }
    }
    if let Some((ref t, _, _)) = st.bubble {
        let (w, h) = draw::bubble_size(t, s);
        grow(Rect::new(st.pos.x, st.pos.y, w as f64, h as f64));
    }
    let b = b.intersection(&crate::screen::virtual_screen());
    let (w, h) = (b.w.ceil().max(1.0) as u32, b.h.ceil().max(1.0) as u32);
    let Some(mut pix) = Pixmap::new(w, h) else { return };
    let rel = |p: Point| Point::new(p.x - b.x, p.y - b.y);
    let relr = |r: Rect| Rect::new(r.x - b.x, r.y - b.y, r.w, r.h);
    let now = Instant::now();
    if let Some((r, _)) = st.frame {
        draw::frame(&mut pix, relr(r), rgb, 1.0);
    }
    if let Some((r, ref label, t0)) = st.mark {
        let t = (now.duration_since(t0).as_secs_f32() / 0.55).min(1.0);
        draw::mark(&mut pix, relr(r), label.as_deref(), t, s);
    }
    if let Some((p, t0)) = st.ripple {
        draw::ripple(&mut pix, rel(p), now.duration_since(t0).as_secs_f32() / 0.42, rgb, s);
    }
    if st.mood == Mood::Listening {
        draw::level_ring(&mut pix, rel(st.pos), st.level, rgb, s);
    }
    let phase = now.duration_since(st.start).as_secs_f32();
    let pulse = if st.mood == Mood::Thinking { 0.5 + 0.5 * (phase * 5.0).sin() } else { 0.4 };
    draw::arrow(&mut pix, rel(st.pos), s, rgb, pulse, st.qa);
    if st.typing {
        draw::typing_dots(&mut pix, rel(st.pos), phase, rgb, s);
    }
    if let Some((pass, t0)) = st.signal {
        draw::signal(&mut pix, rel(st.pos), pass, now.duration_since(t0).as_secs_f32(), s);
    }
    if let Some((ref t, _, _)) = st.bubble {
        draw::bubble(&mut pix, rel(st.pos), t, rgb, s);
    }
    present(st, &pix, b);
}

/// Hands the pixmap to the layered window (BGRA premultiplied), at its screen position.
fn present(st: &mut State, pix: &Pixmap, b: Rect) {
    let (w, h) = (pix.width() as i32, pix.height() as i32);
    unsafe {
        let screen = GetDC(None);
        let mem = CreateCompatibleDC(screen);
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER { biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32, biWidth: w, biHeight: -h, biPlanes: 1, biBitCount: 32, biCompression: BI_RGB.0, ..Default::default() },
            ..Default::default()
        };
        let mut bits = std::ptr::null_mut();
        let Ok(dib) = CreateDIBSection(mem, &info, DIB_RGB_COLORS, &mut bits, None, 0) else {
            let _ = DeleteDC(mem);
            ReleaseDC(None, screen);
            return;
        };
        let dst = std::slice::from_raw_parts_mut(bits as *mut u8, (w * h * 4) as usize);
        for (d, s) in dst.chunks_exact_mut(4).zip(pix.data().chunks_exact(4)) {
            d[0] = s[2];
            d[1] = s[1];
            d[2] = s[0];
            d[3] = s[3];
        }
        let old = SelectObject(mem, dib);
        let blend = BLENDFUNCTION { BlendOp: AC_SRC_OVER as u8, BlendFlags: 0, SourceConstantAlpha: (st.alpha.clamp(0.0, 1.0) * 255.0) as u8, AlphaFormat: AC_SRC_ALPHA as u8 };
        let pos = POINT { x: b.x as i32, y: b.y as i32 };
        let size = SIZE { cx: w, cy: h };
        let src = POINT { x: 0, y: 0 };
        let _ = UpdateLayeredWindow(st.hwnd, screen, Some(&pos), Some(&size), mem, Some(&src), COLORREF(0), Some(&blend), ULW_ALPHA);
        SelectObject(mem, old);
        let _ = DeleteObject(dib);
        let _ = DeleteDC(mem);
        ReleaseDC(None, screen);
        if st.visible_area.is_none() {
            let _ = ShowWindow(st.hwnd, SW_SHOWNOACTIVATE);
            let _ = SetWindowPos(st.hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }
        st.visible_area = Some(RECT { left: pos.x, top: pos.y, right: pos.x + w, bottom: pos.y + h });
    }
}

#[async_trait]
impl Buddy for Overlay {
    async fn travel(&self, to: Point, framing: Option<Rect>) {
        let (tx, rx) = oneshot::channel();
        self.send(Cmd::Travel(to, framing, tx));
        let _ = tokio::time::timeout(Duration::from_millis(900), rx).await;
    }
    fn click(&self) {
        self.send(Cmd::Click);
    }
    async fn mark(&self, rect: Rect, label: Option<&str>) {
        let (tx, rx) = oneshot::channel();
        self.send(Cmd::Mark(rect, label.map(String::from), tx));
        let _ = rx.await;
        tokio::time::sleep(Duration::from_millis(600)).await;
    }
    fn clear_mark(&self) {
        self.send(Cmd::ClearMark);
    }
    fn clear_highlight(&self) {
        self.send(Cmd::ClearHighlight);
    }
    fn bubble(&self, text: Option<&str>, seconds: f64) {
        self.send(Cmd::Bubble(text.map(String::from), seconds));
    }
    fn set_mood(&self, mood: Mood) {
        self.send(Cmd::Mood(mood));
    }
    fn set_typing(&self, on: bool) {
        self.send(Cmd::Typing(on));
    }
    fn set_level(&self, level: f32) {
        self.send(Cmd::Level(level));
    }
    fn go_home(&self) {
        self.send(Cmd::Home);
    }
    fn signal(&self, pass: bool) {
        self.send(Cmd::Signal(pass));
    }
    fn set_qa(&self, on: bool) {
        self.send(Cmd::Qa(on));
    }
}
