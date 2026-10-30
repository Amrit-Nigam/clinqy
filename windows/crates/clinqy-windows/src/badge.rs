//! While a background run works out of sight: a small glowing pill in the corner of the screen, so the user knows it's
//! still busy (the Mac's WorkingBadge). It never takes focus; a click opens the live view.

use crate::com::wide;
use std::cell::RefCell;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::Instant;
use tiny_skia::{Color, LineCap, Paint, PathBuilder, Pixmap, Stroke, Transform};
use windows::core::PCWSTR;
use windows::Win32::Foundation::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::*;

const WM_WAKE: u32 = WM_APP + 3;

pub struct Badge {
    tx: Sender<Option<String>>,
    hwnd: isize,
}

struct State {
    hwnd: HWND,
    text: Option<String>,
    shown_text: String,
    alpha: f32,
    start: Instant,
    shown: bool,
    on_click: Box<dyn Fn() + Send>,
}

thread_local! {
    static ST: RefCell<Option<State>> = const { RefCell::new(None) };
    static RX: RefCell<Option<Receiver<Option<String>>>> = const { RefCell::new(None) };
}

impl Badge {
    pub fn start(on_click: impl Fn() + Send + 'static) -> Badge {
        let (tx, rx) = channel();
        let (htx, hrx) = channel::<isize>();
        let on_click: Box<dyn Fn() + Send> = Box::new(on_click);
        std::thread::Builder::new()
            .name("clinqy-badge".into())
            .spawn(move || unsafe {
                let class = wide("ClinqyBadge");
                let inst = GetModuleHandleW(None).unwrap_or_default();
                RegisterClassW(&WNDCLASSW {
                    lpfnWndProc: Some(proc_),
                    hInstance: inst.into(),
                    lpszClassName: PCWSTR(class.as_ptr()),
                    hCursor: LoadCursorW(None, IDC_HAND).unwrap_or_default(),
                    ..Default::default()
                });
                let hwnd = CreateWindowExW(
                    WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
                    PCWSTR(class.as_ptr()),
                    PCWSTR(wide("Clinqy is working").as_ptr()),
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
                ST.with(|s| *s.borrow_mut() = Some(State { hwnd, text: None, shown_text: String::new(), alpha: 0.0, start: Instant::now(), shown: false, on_click }));
                RX.with(|r| *r.borrow_mut() = Some(rx));
                let _ = htx.send(hwnd.0 as isize);
                SetTimer(hwnd, 1, 33, None);
                let mut msg = MSG::default();
                while GetMessageW(&mut msg, None, 0, 0).as_bool() {
                    let _ = TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
            })
            .expect("couldn't start the working badge");
        Badge { tx, hwnd: hrx.recv().unwrap_or(0) }
    }

    /// Shows `text` in the pill (None hides it).
    pub fn set(&self, text: Option<String>) {
        let _ = self.tx.send(text);
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
        WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
        WM_LBUTTONUP => {
            ST.with(|s| {
                if let Ok(b) = s.try_borrow() {
                    if let Some(st) = b.as_ref() {
                        (st.on_click)();
                    }
                }
            });
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wp, lp),
    }
}

fn tick() {
    let update: Option<Option<String>> = RX.with(|r| r.borrow().as_ref().and_then(|rx| rx.try_iter().last()));
    let hide = ST.with(|s| {
        let Ok(mut b) = s.try_borrow_mut() else { return None };
        let st = b.as_mut()?;
        if let Some(text) = update {
            if let Some(t) = &text {
                st.shown_text = t.clone();
            }
            st.text = text;
        }
        // Fades over a quarter of a second.
        let target = if st.text.is_some() { 1.0 } else { 0.0 };
        st.alpha += (target - st.alpha) * 0.35;
        if (st.alpha - target).abs() < 0.03 {
            st.alpha = target;
        }
        if st.alpha <= 0.0 {
            if st.shown {
                st.shown = false;
                return Some(st.hwnd);
            }
            return None;
        }
        render(st);
        None
    });
    if let Some(hwnd) = hide {
        unsafe {
            let _ = ShowWindow(hwnd, SW_HIDE);
        }
    }
}

fn render(st: &mut State) {
    let scale = crate::screen::scale() as f32;
    let f = &crate::text::fonts().bold;
    let size = 11.5 * scale;
    let text_w = crate::text::measure(f, &st.shown_text, size);
    let pad = 12.0 * scale;
    let spin = 12.0 * scale;
    let h = 30.0 * scale;
    let w = (pad * 2.0 + spin + 8.0 * scale + text_w).max(172.0 * scale).ceil();
    let m = 8.0 * scale; // Room for the glow.
    let (pw, ph) = ((w + m * 2.0) as u32, (h + m * 2.0) as u32);
    let Some(mut pix) = Pixmap::new(pw, ph) else { return };
    let mut pb = PathBuilder::new();
    crate::overlay::rounded_rect(&mut pb, m, m, w, h, h / 2.0);
    let Some(path) = pb.finish() else { return };
    let paint = |c: (u8, u8, u8, u8)| {
        let mut p = Paint::default();
        p.set_color(Color::from_rgba8(c.0, c.1, c.2, c.3));
        p.anti_alias = true;
        p
    };
    for k in 1..=4 {
        pix.stroke_path(&path, &paint((59, 130, 255, 26 / k as u8)), &Stroke { width: 3.0 * k as f32 * scale, ..Default::default() }, Transform::identity(), None);
    }
    pix.fill_path(&path, &paint((0, 0, 0, 230)), tiny_skia::FillRule::Winding, Transform::identity(), None);
    pix.stroke_path(&path, &paint((59, 130, 255, 140)), &Stroke { width: 1.0 * scale, ..Default::default() }, Transform::identity(), None);
    // The spinner: an arc going round.
    let t = st.start.elapsed().as_secs_f32();
    let (cx, cy, r) = (m + pad + spin / 2.0, m + h / 2.0, spin / 2.0);
    let begin = (t * 6.0) % std::f32::consts::TAU;
    let mut arc = PathBuilder::new();
    for i in 0..=24 {
        let a = begin + 4.2 * i as f32 / 24.0;
        let (x, y) = (cx + r * a.cos(), cy + r * a.sin());
        if i == 0 {
            arc.move_to(x, y)
        } else {
            arc.line_to(x, y)
        }
    }
    if let Some(p) = arc.finish() {
        pix.stroke_path(&p, &paint((255, 255, 255, 230)), &Stroke { width: 1.6 * scale, line_cap: LineCap::Round, ..Default::default() }, Transform::identity(), None);
    }
    crate::text::draw(&mut pix, f, &st.shown_text, m + pad + spin + 8.0 * scale, m + h / 2.0 + size * 0.36, size, Color::from_rgba8(255, 255, 255, 240));
    // Bottom right of the primary screen's work area, 12 pt in.
    let mut area = RECT::default();
    unsafe {
        let _ = SystemParametersInfoW(SPI_GETWORKAREA, 0, Some(&mut area as *mut RECT as *mut _), SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0));
    }
    let x = area.right - pw as i32 - (12.0 * scale - m) as i32;
    let y = area.bottom - ph as i32 - (12.0 * scale - m) as i32;
    let first = !st.shown;
    crate::island::blit(st.hwnd, &pix, x, y, st.alpha);
    if first {
        unsafe {
            let _ = ShowWindow(st.hwnd, SW_SHOWNOACTIVATE);
            let _ = SetWindowPos(st.hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }
        st.shown = true;
    }
}
