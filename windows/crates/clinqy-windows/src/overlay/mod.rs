//! The companion cursor: a small glowing triangle that rides just below-right of the user's pointer and, when
//! Clinqy acts, flies an arc to each target, frames it, clicks, types, marks things — then flies home (the Mac's
//! Buddy). It's a click-through, never-activating layered window on its own thread, kept out of screenshots and
//! screen shares, sized each frame to what it draws.

mod draw;

pub use draw::rounded as rounded_rect;

use crate::com::wide;
use async_trait::async_trait;
use clinqy_core::platform::{Buddy, Mood, Point, Rect};
use std::cell::RefCell;
use std::collections::VecDeque;
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

struct MarkState {
    rect: Rect,
    tail: Point,
    seed: f32,
    began: Instant,
    fading: Option<Instant>,
}

struct State {
    hwnd: HWND,
    pos: Point,
    trail: VecDeque<Point>,
    flight: Option<Flight>,
    /// Away from the pointer (after travelling) until sent home.
    away: bool,
    highlight: Option<Rect>,
    highlight_alpha: f32,
    ripples: Vec<(Point, Instant)>,
    mark: Option<MarkState>,
    bubble: Option<(String, Instant, f64)>,
    bubble_alpha: f32,
    flash: Option<(bool, Instant)>,
    press: Option<Instant>,
    pop: Option<Instant>,
    shake: Option<Instant>,
    mood: Mood,
    typing: bool,
    level: f32,
    qa: bool,
    color: (f32, f32, f32),
    shape_alpha: f32,
    spinner_alpha: f32,
    bars_alpha: f32,
    /// Last time anything happened; the cursor floats away when idle.
    active: Instant,
    /// 0 = beside the pointer, 1 = floated up and away.
    offstage: f32,
    last_mouse: Point,
    visible: bool,
    start: Instant,
    last_tick: Instant,
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

/// Where it rides: just below-right of the pointer (the Mac's offset, 14, 16 pt).
fn home_point() -> Point {
    let c = crate::input::cursor();
    let s = dpi_scale(c) as f64;
    Point::new(c.x + 14.0 * s, c.y + 16.0 * s)
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
                crate::screen::hide_from_capture(hwnd.0 as isize);
                let now = Instant::now();
                STATE.with(|s| {
                    *s.borrow_mut() = Some(State {
                        hwnd,
                        pos: home_point(),
                        trail: VecDeque::new(),
                        flight: None,
                        away: false,
                        highlight: None,
                        highlight_alpha: 0.0,
                        ripples: vec![],
                        mark: None,
                        bubble: None,
                        bubble_alpha: 0.0,
                        flash: None,
                        press: None,
                        pop: None,
                        shake: None,
                        mood: Mood::Idle,
                        typing: false,
                        level: 0.0,
                        qa: false,
                        color: (59.0, 130.0, 255.0),
                        shape_alpha: 1.0,
                        spinner_alpha: 0.0,
                        bars_alpha: 0.0,
                        active: now - Duration::from_secs(60),
                        offstage: 1.0,
                        last_mouse: crate::input::cursor(),
                        visible: false,
                        start: now,
                        last_tick: now,
                    })
                });
                RX.with(|r| *r.borrow_mut() = Some(rx));
                let _ = htx.send(hwnd.0 as isize);
                SetTimer(hwnd, 1, 16, None);
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
                Cmd::Travel(point, framing, done) => {
                    st.highlight = framing;
                    st.typing = false;
                    if st.offstage > 0.5 {
                        st.pos = home_point();
                    }
                    // Lands just below-right of the point, pointing at it.
                    let to = Point::new(point.x + 3.0, point.y + 3.0);
                    let from = st.pos;
                    let d = from.distance(to);
                    let s = dpi_scale(to) as f64;
                    let duration = (0.18 + d / (2400.0 * s)).min(0.6);
                    let (mx, my) = ((from.x + to.x) / 2.0, (from.y + to.y) / 2.0);
                    let (dx, dy) = (to.x - from.x, to.y - from.y);
                    let bend = (d * 0.2).min(110.0 * s);
                    let len = d.max(1.0);
                    let control = Point::new(mx - dy / len * bend, my + dx / len * bend);
                    if let Some(f) = st.flight.take() {
                        if let Some(dn) = f.done {
                            let _ = dn.send(());
                        }
                    }
                    st.away = true;
                    if d < 4.0 {
                        st.pos = to;
                        let _ = done.send(());
                    } else {
                        st.flight = Some(Flight { from, to, started: now, duration, control, done: Some(done) });
                    }
                }
                Cmd::Click => {
                    st.press = Some(now);
                    st.ripples.push((st.flight.as_ref().map(|f| f.to).unwrap_or(st.pos), now));
                }
                Cmd::Mark(r, label, done) => {
                    // The cursor parks up-left of the thing and draws the loop and an arrow from there.
                    let s = dpi_scale(r.center()) as f64;
                    let park = Point::new(r.x - 60.0 * s, r.y - 40.0 * s);
                    let from = st.pos;
                    st.flight = Some(Flight { from, to: park, started: now, duration: 0.4, control: Point::new((from.x + park.x) / 2.0, (from.y + park.y) / 2.0 - 40.0), done: None });
                    st.away = true;
                    st.mark = Some(MarkState { rect: r, tail: park, seed: (now.elapsed().subsec_nanos() % 628) as f32 / 100.0, began: now, fading: None });
                    st.bubble = label.map(|l| (l, now, 8.0));
                    let _ = done.send(());
                }
                Cmd::ClearMark => {
                    if let Some(m) = st.mark.as_mut() {
                        m.fading.get_or_insert(now);
                    }
                }
                Cmd::ClearHighlight => st.highlight = None,
                Cmd::Bubble(text, secs) => st.bubble = text.map(|t| (t, now, secs)),
                Cmd::Mood(m) => {
                    if m != st.mood {
                        if m == Mood::Failure {
                            st.shake = Some(now);
                        }
                        if m == Mood::Success {
                            st.pop = Some(now);
                        }
                    }
                    st.mood = m;
                }
                Cmd::Typing(on) => st.typing = on,
                Cmd::Level(l) => st.level = l,
                Cmd::Home => {
                    st.away = false;
                    st.highlight = None;
                }
                Cmd::Signal(pass) => {
                    st.flash = Some((pass, now));
                    if pass {
                        st.pop = Some(now)
                    } else {
                        st.shake = Some(now)
                    }
                }
                Cmd::Qa(on) => st.qa = on,
            }
        }
    });
}

fn approach(v: &mut f32, target: f32, rate: f32, dt: f32) {
    *v += (target - *v) * (dt * rate).min(1.0);
}

fn tick() {
    STATE.with(|s| {
        let mut b = s.borrow_mut();
        let Some(st) = b.as_mut() else { return };
        let now = Instant::now();
        let dt = now.duration_since(st.last_tick).as_secs_f32().min(0.1);
        st.last_tick = now;
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
            let h = home_point();
            st.pos = Point::new(st.pos.x + (h.x - st.pos.x) * 0.35, st.pos.y + (h.y - st.pos.y) * 0.35);
        }
        st.trail.push_back(st.pos);
        while st.trail.len() > 9 {
            st.trail.pop_front();
        }
        // The mouse moving wakes it; idle, it floats away (the Mac's "floats away when you're idle").
        let mouse = crate::input::cursor();
        let user_moved = mouse.distance(st.last_mouse) > 1.0;
        st.last_mouse = mouse;
        let busy = st.mood != Mood::Idle || st.flight.is_some() || st.mark.is_some() || st.bubble.is_some() || st.typing || st.away;
        if busy {
            st.active = now;
        }
        let recently = now.duration_since(st.active) < Duration::from_millis(2500);
        if user_moved && recently {
            st.active = now;
        }
        approach(&mut st.offstage, if recently { 0.0 } else { 1.0 }, if recently { 10.0 } else { 3.0 }, dt);
        // Colour toward the mood (a QA check flashes green or red).
        let mut want = draw::mood_color(st.mood, st.qa);
        if let Some((ok, at)) = st.flash {
            if now.duration_since(at) < Duration::from_millis(700) {
                want = draw::mood_color(if ok { Mood::Success } else { Mood::Failure }, false);
            } else {
                st.flash = None;
            }
        }
        let k = (dt * 8.0).min(1.0);
        st.color = (st.color.0 + (want.0 as f32 - st.color.0) * k, st.color.1 + (want.1 as f32 - st.color.1) * k, st.color.2 + (want.2 as f32 - st.color.2) * k);
        // Which face shows: triangle, spinner (thinking) or bars (listening).
        approach(&mut st.shape_alpha, if matches!(st.mood, Mood::Thinking | Mood::Listening) { 0.0 } else { 1.0 }, 12.0, dt);
        approach(&mut st.spinner_alpha, if st.mood == Mood::Thinking { 1.0 } else { 0.0 }, 12.0, dt);
        approach(&mut st.bars_alpha, if st.mood == Mood::Listening { 1.0 } else { 0.0 }, 12.0, dt);
        approach(&mut st.highlight_alpha, if st.highlight.is_some() { 1.0 } else { 0.0 }, 12.0, dt);
        approach(&mut st.bubble_alpha, if st.bubble.is_some() { 1.0 } else { 0.0 }, 14.0, dt);
        st.ripples.retain(|r| now.duration_since(r.1) < Duration::from_millis(550));
        if st.bubble.as_ref().map(|b| now.duration_since(b.1).as_secs_f64() > b.2).unwrap_or(false) {
            st.bubble = None;
        }
        if let Some(m) = &st.mark {
            let done = m.fading.map(|f| now.duration_since(f) > Duration::from_millis(400)).unwrap_or(false);
            if done || now.duration_since(m.began) > Duration::from_secs(9) {
                st.mark = None;
            }
        }
        render(st, now);
    });
}

fn render(st: &mut State, now: Instant) {
    let o = st.offstage;
    if o > 0.99 && st.mark.is_none() && st.highlight_alpha < 0.01 {
        if st.visible {
            unsafe {
                let _ = ShowWindow(st.hwnd, SW_HIDE);
            }
            st.visible = false;
        }
        return;
    }
    let s = dpi_scale(st.pos);
    let c = (st.color.0 as u8, st.color.1 as u8, st.color.2 as u8);
    let t = now.duration_since(st.start).as_secs_f32();
    // Where the face is drawn: floating up as it fades, shaking on failure, bobbing while typing.
    let mut p = st.pos;
    p.y -= 42.0 * (o * o) as f64 * s as f64;
    if let Some(sh) = st.shake {
        let a = now.duration_since(sh).as_secs_f32();
        if a < 0.45 {
            p.x += ((a * 55.0).sin() * 6.0 * (1.0 - a / 0.45) * s) as f64;
        }
    }
    if st.typing {
        p.y += ((t * 14.0).sin() * 1.5 * s) as f64;
    }
    let mut scale = 1.0;
    if let Some(pr) = st.press {
        let a = now.duration_since(pr).as_secs_f32();
        if a < 0.26 {
            scale *= 1.0 - 0.25 * (a / 0.26 * std::f32::consts::PI).sin();
        }
    }
    if let Some(pp) = st.pop {
        let a = now.duration_since(pp).as_secs_f32();
        if a < 0.5 {
            scale *= 1.0 + 0.3 * (a / 0.5 * std::f32::consts::PI).sin();
        }
    }
    let shrink = 1.0 - 0.35 * o;
    // Bounds of everything drawn.
    let pad = 48.0 * s as f64;
    let mut b = Rect::new(p.x - pad, p.y - pad, 2.0 * pad, 2.0 * pad);
    let mut grow = |r: Rect| {
        let (x0, y0) = (b.x.min(r.x), b.y.min(r.y));
        let (x1, y1) = (b.max_x().max(r.max_x()), b.max_y().max(r.max_y()));
        b = Rect::new(x0, y0, x1 - x0, y1 - y0);
    };
    if let Some(h) = st.highlight {
        grow(h.inset(-24.0));
    }
    for (rp, _) in &st.ripples {
        grow(Rect::new(rp.x - 40.0, rp.y - 40.0, 80.0, 80.0));
    }
    for tp in &st.trail {
        grow(Rect::new(tp.x - 10.0, tp.y - 10.0, 30.0, 30.0));
    }
    if let Some(m) = &st.mark {
        let ext = 40.0 * s as f64;
        grow(m.rect.inset(-ext));
        grow(Rect::new(m.tail.x - ext, m.tail.y - ext, 2.0 * ext, 2.0 * ext));
    }
    if let Some((ref text, _, _)) = st.bubble {
        let (w, h) = draw::bubble_size(text, s);
        grow(Rect::new(p.x, p.y, w as f64, h as f64));
    }
    let b = b.intersection(&crate::screen::virtual_screen());
    let (w, h) = (b.w.ceil().max(1.0) as u32, b.h.ceil().max(1.0) as u32);
    let Some(mut pix) = Pixmap::new(w, h) else { return };
    let rel = |q: Point| Point::new(q.x - b.x, q.y - b.y);
    let relr = |r: Rect| Rect::new(r.x - b.x, r.y - b.y, r.w, r.h);
    let face = 1.0 - o;
    if let Some(h) = st.highlight {
        draw::frame(&mut pix, relr(h), s, c, st.highlight_alpha * face.max(0.5));
    }
    if st.flight.is_some() {
        let trail: Vec<Point> = st.trail.iter().map(|q| rel(*q)).collect();
        draw::streak(&mut pix, &trail, s, c, face);
    }
    for (rp, at) in &st.ripples {
        draw::ripple(&mut pix, rel(*rp), s, c, now.duration_since(*at).as_secs_f32() / 0.55);
    }
    if let Some(m) = &st.mark {
        let fade = m.fading.map(|f| (1.0 - now.duration_since(f).as_secs_f32() / 0.4).max(0.0)).unwrap_or(1.0);
        draw::mark(&mut pix, relr(m.rect), rel(m.tail), m.seed, now.duration_since(m.began).as_secs_f32(), fade, s, c);
    }
    let rp = rel(p);
    let face_scale = scale * (0.7 + 0.3 * st.shape_alpha) * shrink;
    if st.qa {
        draw::reticle(&mut pix, rp, s, c, st.shape_alpha * face);
    } else if st.shape_alpha > 0.01 {
        draw::triangle(&mut pix, rp, s, c, face_scale, st.shape_alpha * face);
    }
    if st.spinner_alpha > 0.01 {
        draw::spinner(&mut pix, rp, s, c, t, st.spinner_alpha * face);
    }
    if st.bars_alpha > 0.01 {
        draw::bars(&mut pix, rp, s, c, t, st.level, st.bars_alpha * face);
    }
    if let Some((ref text, at, _)) = st.bubble {
        let age = (now.duration_since(at).as_secs_f32() / 0.35).min(1.0);
        let pop = 0.6 + 0.4 * (1.0 - (1.0 - age).powi(3)) + 0.06 * (age * std::f32::consts::PI).sin();
        draw::bubble(&mut pix, rp, text, s, c, pop, st.bubble_alpha * face.max(0.6));
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
        let blend = BLENDFUNCTION { BlendOp: AC_SRC_OVER as u8, BlendFlags: 0, SourceConstantAlpha: 255, AlphaFormat: AC_SRC_ALPHA as u8 };
        let pos = POINT { x: b.x as i32, y: b.y as i32 };
        let _ = UpdateLayeredWindow(st.hwnd, screen, Some(&pos), Some(&SIZE { cx: w, cy: h }), mem, Some(&POINT::default()), COLORREF(0), Some(&blend), ULW_ALPHA);
        SelectObject(mem, old);
        let _ = DeleteObject(dib);
        let _ = DeleteDC(mem);
        ReleaseDC(None, screen);
        if !st.visible {
            let _ = ShowWindow(st.hwnd, SW_SHOWNOACTIVATE);
            let _ = SetWindowPos(st.hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            st.visible = true;
        }
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
        tokio::time::sleep(Duration::from_millis(1000)).await;
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

#[cfg(test)]
mod tests {
    use super::draw;
    use clinqy_core::platform::{Mood, Point, Rect};

    /// Renders every mark the cursor draws, for eyeballing: CLINQY_DRAW_OUT=<file.png> cargo test draws_marks
    #[test]
    fn draws_marks() {
        let mut pix = tiny_skia::Pixmap::new(520, 260).unwrap();
        pix.fill(tiny_skia::Color::from_rgba8(30, 30, 34, 255));
        let c = draw::mood_color(Mood::Acting, false);
        draw::frame(&mut pix, Rect::new(30.0, 30.0, 120.0, 34.0), 1.0, c, 1.0);
        draw::triangle(&mut pix, Point::new(120.0, 58.0), 1.0, c, 1.0, 1.0);
        draw::ripple(&mut pix, Point::new(120.0, 58.0), 1.0, c, 0.4);
        draw::spinner(&mut pix, Point::new(200.0, 40.0), 1.0, c, 0.7, 1.0);
        draw::bars(&mut pix, Point::new(260.0, 40.0), 1.0, c, 0.3, 0.6, 1.0);
        draw::reticle(&mut pix, Point::new(320.0, 40.0), 1.0, draw::mood_color(Mood::Acting, true), 1.0);
        draw::mark(&mut pix, Rect::new(330.0, 150.0, 120.0, 40.0), Point::new(260.0, 120.0), 0.7, 2.0, 1.0, 1.0, c);
        draw::bubble(&mut pix, Point::new(30.0, 150.0), "Clicking Submit", 1.0, c, 1.0, 1.0);
        if let Ok(out) = std::env::var("CLINQY_DRAW_OUT") {
            pix.save_png(out).unwrap();
        }
        assert!(pix.data().chunks_exact(4).any(|p| p[2] > 200 && p[0] < 120));
    }
}
