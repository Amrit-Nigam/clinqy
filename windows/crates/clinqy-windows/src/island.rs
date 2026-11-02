//! The status island: the small capsule at the top of the screen while Clinqy works (orb, what it's doing, a key
//! hint), drawn natively so it can be click-through and never take focus — the Mac's IslandView, pixel for pixel:
//! a 36 pt black capsule (82%), a hairline border, a 16 pt breathing orb, 13 pt text, an 11 pt hint.
//! It stays click-through so Clinqy's own clicks reach what's under it. The user drags it through a mouse hook that
//! only sees physical presses, only while it's showing; it's back at the top centre the next time it opens.

use crate::com::wide;
use clinqy_core::platform::Mood;
use std::cell::RefCell;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::Instant;
use tiny_skia::{BlendMode, Color, FillRule, Paint, PathBuilder, Pixmap, Stroke, Transform};
use windows::core::PCWSTR;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::WindowsAndMessaging::*;

#[derive(Clone, Debug, PartialEq)]
pub struct IslandState {
    pub visible: bool,
    pub text: String,
    pub hint: String,
    pub mood: Mood,
    pub level: f32,
    /// Show the start of a long text cut ("…end") rather than its end (a live transcript).
    pub head: bool,
}

impl Default for IslandState {
    fn default() -> Self {
        IslandState { visible: false, text: String::new(), hint: String::new(), mood: Mood::Idle, level: 0.0, head: false }
    }
}

const WM_WAKE: u32 = WM_APP + 2;

/// Where the user dragged it, from its usual place.
static OFFSET: parking_lot::Mutex<(i32, i32)> = parking_lot::Mutex::new((0, 0));
/// The capsule on screen: left, top, right, bottom.
static BOUNDS: parking_lot::Mutex<(i32, i32, i32, i32)> = parking_lot::Mutex::new((0, 0, 0, 0));
/// A drag under way: where it began, and the offset then.
static DRAG: parking_lot::Mutex<Option<(POINT, (i32, i32))>> = parking_lot::Mutex::new(None);

/// The offset for the cursor at `at` in a drag that began at `from`.
fn dragged(from: POINT, offset: (i32, i32), at: POINT) -> (i32, i32) {
    (offset.0 + at.x - from.x, offset.1 + at.y - from.y)
}

unsafe extern "system" fn mouse(code: i32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if code >= 0 {
        let m = &*(lp.0 as *const MSLLHOOKSTRUCT);
        let injected = m.flags & LLMHF_INJECTED != 0 || m.dwExtraInfo == crate::input::INJECTED_TAG;
        let physical = !injected || (crate::hotkey::accept_synthetic() && m.dwExtraInfo != crate::input::INJECTED_TAG);
        let mut drag = DRAG.lock();
        match wp.0 as u32 {
            WM_LBUTTONDOWN if physical => {
                let (l, t, r, b) = *BOUNDS.lock();
                if m.pt.x >= l && m.pt.x < r && m.pt.y >= t && m.pt.y < b {
                    *drag = Some((m.pt, *OFFSET.lock()));
                    return LRESULT(1);
                }
            }
            WM_MOUSEMOVE => {
                if let Some((from, offset)) = *drag {
                    *OFFSET.lock() = dragged(from, offset, m.pt);
                }
            }
            WM_LBUTTONUP if physical && drag.is_some() => {
                *drag = None;
                return LRESULT(1);
            }
            _ => {}
        }
    }
    CallNextHookEx(None, code, wp, lp)
}

pub struct Island {
    tx: Sender<IslandState>,
    hwnd: isize,
}

struct State {
    hwnd: HWND,
    want: IslandState,
    alpha: f32,
    start: Instant,
    shown: bool,
    mouse: Option<HHOOK>,
}

thread_local! {
    static ST: RefCell<Option<State>> = const { RefCell::new(None) };
    static RX: RefCell<Option<Receiver<IslandState>>> = const { RefCell::new(None) };
}

impl Island {
    pub fn start() -> Island {
        let (tx, rx) = channel::<IslandState>();
        let (htx, hrx) = channel::<isize>();
        std::thread::Builder::new()
            .name("clinqy-island".into())
            .spawn(move || unsafe {
                let class = wide("ClinqyIsland");
                let inst = GetModuleHandleW(None).unwrap_or_default();
                RegisterClassW(&WNDCLASSW { lpfnWndProc: Some(proc_), hInstance: inst.into(), lpszClassName: PCWSTR(class.as_ptr()), ..Default::default() });
                let hwnd = CreateWindowExW(
                    WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
                    PCWSTR(class.as_ptr()),
                    PCWSTR(wide("Clinqy status").as_ptr()),
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
                crate::screen::hide_from_capture(hwnd.0 as isize);
                ST.with(|s| *s.borrow_mut() = Some(State { hwnd, want: IslandState::default(), alpha: 0.0, start: Instant::now(), shown: false, mouse: None }));
                RX.with(|r| *r.borrow_mut() = Some(rx));
                let _ = htx.send(hwnd.0 as isize);
                SetTimer(hwnd, 1, 33, None);
                let mut msg = MSG::default();
                while GetMessageW(&mut msg, None, 0, 0).as_bool() {
                    let _ = TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
            })
            .expect("couldn't start the status island");
        Island { tx, hwnd: hrx.recv().unwrap_or(0) }
    }

    /// Back to the top centre, for a new task.
    pub fn recenter(&self) {
        *OFFSET.lock() = (0, 0);
    }

    pub fn set(&self, s: IslandState) {
        let _ = self.tx.send(s);
        unsafe {
            let _ = PostMessageW(HWND(self.hwnd as _), WM_WAKE, WPARAM(0), LPARAM(0));
        }
    }
}

unsafe extern "system" fn proc_(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        WM_WAKE | WM_TIMER => {
            tick();
            LRESULT(0)
        }
        WM_NCHITTEST => LRESULT(HTTRANSPARENT as isize),
        _ => DefWindowProcW(hwnd, msg, wp, lp),
    }
}

fn tick() {
    let updates: Vec<IslandState> = RX.with(|r| r.borrow().as_ref().map(|rx| rx.try_iter().collect()).unwrap_or_default());
    ST.with(|s| {
        let mut b = s.borrow_mut();
        let Some(st) = b.as_mut() else { return };
        if let Some(last) = updates.into_iter().last() {
            st.want = last;
        }
        let target = if st.want.visible { 1.0 } else { 0.0 };
        st.alpha += (target - st.alpha) * 0.3;
        if (st.alpha - target).abs() < 0.02 {
            st.alpha = target;
        }
        if st.alpha <= 0.0 {
            if st.shown {
                unsafe {
                    let _ = ShowWindow(st.hwnd, SW_HIDE);
                    if let Some(hook) = st.mouse.take() {
                        let _ = UnhookWindowsHookEx(hook);
                    }
                }
                st.shown = false;
                *DRAG.lock() = None;
                *OFFSET.lock() = (0, 0);
                *BOUNDS.lock() = (0, 0, 0, 0);
            }
            return;
        }
        render(st);
    });
}

fn scale_at(x: i32, y: i32) -> f32 {
    unsafe {
        let m = MonitorFromPoint(POINT { x, y }, MONITOR_DEFAULTTONEAREST);
        let (mut dx, mut dy) = (96u32, 96u32);
        if GetDpiForMonitor(m, MDT_EFFECTIVE_DPI, &mut dx, &mut dy).is_ok() {
            dx as f32 / 96.0
        } else {
            1.0
        }
    }
}

/// The work area of the monitor under the pointer.
fn work_area() -> RECT {
    unsafe {
        let mut p = POINT::default();
        let _ = GetCursorPos(&mut p);
        let m = MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST);
        let mut info = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
        let _ = GetMonitorInfoW(m, &mut info);
        info.rcWork
    }
}

fn paint(r: u8, g: u8, b: u8, a: u8) -> Paint<'static> {
    let mut p = Paint::default();
    p.set_color(Color::from_rgba8(r, g, b, a));
    p.anti_alias = true;
    p
}

/// Truncates `text` to `max` px with an ellipsis (at the end, or at the start when `head`).
fn fit(font: &fontdue::Font, text: &str, size: f32, max: f32, head: bool) -> String {
    if crate::text::measure(font, text, size) <= max {
        return text.to_string();
    }
    let chars: Vec<char> = text.chars().collect();
    let (mut lo, mut hi) = (0usize, chars.len());
    while lo < hi {
        let mid = (lo + hi + 1) / 2;
        let cand: String = if head { std::iter::once('…').chain(chars[chars.len() - mid..].iter().copied()).collect() } else { chars[..mid].iter().collect::<String>() + "…" };
        if crate::text::measure(font, &cand, size) <= max {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    if head {
        std::iter::once('…').chain(chars[chars.len() - lo..].iter().copied()).collect()
    } else {
        chars[..lo].iter().collect::<String>() + "…"
    }
}

/// The breathing orb (the SwiftUI Orb's maths) centred at (cx, cy), `size` px across.
pub fn draw_orb(pix: &mut Pixmap, cx: f32, cy: f32, size: f32, mood: Mood, level: f32, t: f32) {
    let busy = matches!(mood, Mood::Thinking | Mood::Acting);
    let period = if busy { 1.4 } else { 3.0 };
    let bloom = 0.5 - 0.5 * ((t % period) / period * std::f32::consts::TAU).cos();
    let open = if mood == Mood::Listening { bloom.max((level * 1.6).min(1.0)) } else { bloom };
    let (a, b): ((u8, u8, u8), (u8, u8, u8)) = match mood {
        Mood::Idle => ((46, 212, 191), (33, 212, 237)),
        Mood::Failure => ((255, 84, 77), (255, 137, 132)),
        Mood::Success => ((51, 204, 115), (122, 222, 164)),
        _ => ((59, 130, 255), (127, 174, 255)),
    };
    let rot = t * if busy { 1.2 } else { 0.15 } + open * std::f32::consts::PI / 3.0;
    let petal = size * 0.42;
    // Glow behind the petals.
    let mut pb = PathBuilder::new();
    pb.push_circle(cx, cy, size * (0.3 + 0.3 * open));
    if let Some(p) = pb.finish() {
        pix.fill_path(&p, &paint(a.0, a.1, a.2, (40.0 + 60.0 * open) as u8), FillRule::Winding, Transform::identity(), None);
    }
    for i in 0..6 {
        let ang = rot + i as f32 * std::f32::consts::PI / 3.0;
        let c = if i % 2 == 0 { a } else { b };
        let r = petal / 2.0 * (0.45 + 0.75 * open);
        let mut pb = PathBuilder::new();
        pb.push_circle(cx + ang.cos() * size * 0.3 * open, cy + ang.sin() * size * 0.3 * open, r);
        if let Some(p) = pb.finish() {
            let mut pt = paint(c.0, c.1, c.2, 178);
            pt.blend_mode = BlendMode::Plus;
            pix.fill_path(&p, &pt, FillRule::Winding, Transform::identity(), None);
        }
    }
}

fn render(st: &mut State) {
    let area = work_area();
    let s = scale_at((area.left + area.right) / 2, area.top + 10);
    let fonts = crate::text::fonts();
    let (text_size, hint_size) = (13.0 * s, 11.0 * s);
    let pad = 14.0 * s;
    let orb = 16.0 * s;
    let gap = 10.0 * s;
    let h = 36.0 * s;
    let max_w = 556.0 * s;
    let hint_w = if st.want.hint.is_empty() { 0.0 } else { crate::text::measure(&fonts.regular, &st.want.hint, hint_size) + gap };
    let room = max_w - pad * 2.0 - orb - gap - hint_w;
    let text = fit(&fonts.bold, &st.want.text, text_size, room, st.want.head);
    let tw = crate::text::measure(&fonts.bold, &text, text_size);
    let w = (pad * 2.0 + orb + gap + tw + hint_w).ceil();
    let margin = 2.0 * s;
    let (pw, ph) = ((w + margin * 2.0) as u32, (h + margin * 2.0) as u32);
    let Some(mut pix) = Pixmap::new(pw, ph) else { return };
    // The capsule: black at 82%, a hairline of white at 8%.
    let mut pb = PathBuilder::new();
    let (x0, y0, r) = (margin, margin, h / 2.0);
    pb.move_to(x0 + r, y0);
    pb.line_to(x0 + w - r, y0);
    pb.quad_to(x0 + w, y0, x0 + w, y0 + r);
    pb.quad_to(x0 + w, y0 + h, x0 + w - r, y0 + h);
    pb.line_to(x0 + r, y0 + h);
    pb.quad_to(x0, y0 + h, x0, y0 + r);
    pb.quad_to(x0, y0, x0 + r, y0);
    pb.close();
    if let Some(path) = pb.finish() {
        pix.fill_path(&path, &paint(0, 0, 0, 209), FillRule::Winding, Transform::identity(), None);
        pix.stroke_path(&path, &paint(255, 255, 255, 20), &Stroke { width: 1.0 * s, ..Default::default() }, Transform::identity(), None);
    }
    let t = st.start.elapsed().as_secs_f32();
    draw_orb(&mut pix, x0 + pad + orb / 2.0, y0 + h / 2.0, orb, st.want.mood, st.want.level, t);
    let baseline = y0 + h / 2.0 + text_size * 0.36;
    crate::text::draw(&mut pix, &fonts.bold, &text, x0 + pad + orb + gap, baseline, text_size, Color::from_rgba8(255, 255, 255, 235));
    if !st.want.hint.is_empty() {
        crate::text::draw(&mut pix, &fonts.regular, &st.want.hint, x0 + pad + orb + gap + tw + gap, y0 + h / 2.0 + hint_size * 0.36, hint_size, Color::from_rgba8(255, 255, 255, 82));
    }
    // Centred at the top of the work area, 6 pt below its edge (the Mac's position).
    let (ox, oy) = *OFFSET.lock();
    let (x, y) = unsafe {
        let (left, top) = (GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN));
        let (right, bottom) = (left + GetSystemMetrics(SM_CXVIRTUALSCREEN), top + GetSystemMetrics(SM_CYVIRTUALSCREEN));
        (
            ((area.left + area.right) / 2 - (pw as i32) / 2 + ox).clamp(left, (right - pw as i32).max(left)),
            (area.top + (6.0 * s) as i32 + oy).clamp(top, (bottom - ph as i32).max(top)),
        )
    };
    *BOUNDS.lock() = (x, y, x + pw as i32, y + ph as i32);
    present(st, &pix, x, y);
}

fn present(st: &mut State, pix: &Pixmap, x: i32, y: i32) {
    blit(st.hwnd, pix, x, y, st.alpha);
    if !st.shown {
        unsafe {
            let _ = ShowWindow(st.hwnd, SW_SHOWNOACTIVATE);
            let _ = SetWindowPos(st.hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            st.mouse = SetWindowsHookExW(WH_MOUSE_LL, Some(mouse), GetModuleHandleW(None).unwrap_or_default(), 0).ok();
        }
        st.shown = true;
    }
}

/// Hands a pixmap to a layered window (BGRA premultiplied) at a screen position.
pub(crate) fn blit(hwnd: HWND, pix: &Pixmap, x: i32, y: i32, alpha: f32) {
    let (w, h) = (pix.width() as i32, pix.height() as i32);
    unsafe {
        let screen = GetDC(None);
        let mem = CreateCompatibleDC(screen);
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER { biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32, biWidth: w, biHeight: -h, biPlanes: 1, biBitCount: 32, biCompression: BI_RGB.0, ..Default::default() },
            ..Default::default()
        };
        let mut bits = std::ptr::null_mut();
        if let Ok(dib) = CreateDIBSection(mem, &info, DIB_RGB_COLORS, &mut bits, None, 0) {
            let dst = std::slice::from_raw_parts_mut(bits as *mut u8, (w * h * 4) as usize);
            for (d, s) in dst.chunks_exact_mut(4).zip(pix.data().chunks_exact(4)) {
                d[0] = s[2];
                d[1] = s[1];
                d[2] = s[0];
                d[3] = s[3];
            }
            let old = SelectObject(mem, dib);
            let blend = BLENDFUNCTION { BlendOp: AC_SRC_OVER as u8, BlendFlags: 0, SourceConstantAlpha: (alpha * 255.0) as u8, AlphaFormat: AC_SRC_ALPHA as u8 };
            let _ = UpdateLayeredWindow(hwnd, screen, Some(&POINT { x, y }), Some(&SIZE { cx: w, cy: h }), mem, Some(&POINT::default()), COLORREF(0), Some(&blend), ULW_ALPHA);
            SelectObject(mem, old);
            let _ = DeleteObject(dib);
        }
        let _ = DeleteDC(mem);
        ReleaseDC(None, screen);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_drag_adds_to_where_it_already_was() {
        assert_eq!(dragged(POINT { x: 100, y: 50 }, (0, 0), POINT { x: 140, y: 300 }), (40, 250));
        assert_eq!(dragged(POINT { x: 100, y: 50 }, (40, 250), POINT { x: 90, y: 50 }), (30, 250));
    }
}
