//! "Circle something": dims every screen and lets the user draw a loop around what they mean (Annotate.swift).
//! Esc, a right-click or a mere click cancels. Points come back in screen pixels, the space element rects use.
//! The dimming is kept out of screen captures, so the screenshot that shows the model the loop is clean.

use crate::com::wide;
use clinqy_core::platform::{Point, Rect};
use std::cell::RefCell;
use tiny_skia::{Color, FillRule, LineCap, LineJoin, Paint, PathBuilder, Pixmap, Stroke, Transform};
use windows::core::PCWSTR;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Input::KeyboardAndMouse::{ReleaseCapture, SetCapture, VK_ESCAPE};
use windows::Win32::UI::WindowsAndMessaging::*;

struct State {
    hwnd: HWND,
    area: Rect,
    path: Vec<Point>,
    drawing: bool,
    dirty: bool,
    result: Option<Option<Vec<Point>>>,
}

thread_local! {
    static ST: RefCell<Option<State>> = const { RefCell::new(None) };
}

/// Blocks until the user has drawn a loop (Some) or cancelled (None). Run it off the UI thread.
pub fn pick() -> Option<Vec<Point>> {
    std::thread::spawn(run).join().ok().flatten()
}

fn run() -> Option<Vec<Point>> {
    unsafe {
        let class = wide("ClinqyCircle");
        let inst = GetModuleHandleW(None).unwrap_or_default();
        RegisterClassW(&WNDCLASSW {
            lpfnWndProc: Some(proc_),
            hInstance: inst.into(),
            lpszClassName: PCWSTR(class.as_ptr()),
            hCursor: LoadCursorW(None, IDC_CROSS).unwrap_or_default(),
            ..Default::default()
        });
        let area = crate::screen::virtual_screen();
        let hwnd = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
            PCWSTR(class.as_ptr()),
            PCWSTR(wide("Circle what you mean").as_ptr()),
            WS_POPUP,
            area.x as i32,
            area.y as i32,
            area.w as i32,
            area.h as i32,
            None,
            None,
            inst,
            None,
        )
        .ok()?;
        crate::screen::hide_from_capture(hwnd.0 as isize);
        ST.with(|s| *s.borrow_mut() = Some(State { hwnd, area, path: vec![], drawing: false, dirty: true, result: None }));
        render();
        let _ = ShowWindow(hwnd, SW_SHOW);
        crate::apps::bring_to_front(hwnd.0 as isize);
        SetTimer(hwnd, 1, 16, None);
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
            if ST.with(|s| s.try_borrow().ok().map(|b| b.as_ref().map(|st| st.result.is_some()).unwrap_or(true)).unwrap_or(false)) {
                break;
            }
        }
        let result = ST.with(|s| s.borrow_mut().take().and_then(|st| st.result).flatten());
        let _ = DestroyWindow(hwnd);
        let _ = UnregisterClassW(PCWSTR(class.as_ptr()), inst);
        result
    }
}

fn finish(result: Option<Vec<Point>>) {
    // The borrow ends before the window calls: hiding re-enters the window procedure (WM_ACTIVATE).
    let hwnd = ST.with(|s| {
        let mut b = s.try_borrow_mut().ok()?;
        let st = b.as_mut()?;
        if st.result.is_some() {
            return None;
        }
        st.result = Some(result);
        Some(st.hwnd)
    });
    if let Some(hwnd) = hwnd {
        unsafe {
            let _ = ReleaseCapture();
            let _ = ShowWindow(hwnd, SW_HIDE);
            let _ = PostMessageW(hwnd, WM_NULL, WPARAM(0), LPARAM(0));
        }
    }
}

fn point(lp: LPARAM) -> Point {
    let (x, y) = ((lp.0 & 0xffff) as i16 as f64, ((lp.0 >> 16) & 0xffff) as i16 as f64);
    ST.with(|s| s.try_borrow().ok().and_then(|b| b.as_ref().map(|st| Point::new(st.area.x + x, st.area.y + y))).unwrap_or(Point::new(x, y)))
}

unsafe extern "system" fn proc_(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        WM_LBUTTONDOWN => {
            SetCapture(hwnd);
            let p = point(lp);
            ST.with(|s| {
                if let Some(st) = s.try_borrow_mut().ok().as_mut().and_then(|b| b.as_mut()) {
                    st.path = vec![p];
                    st.drawing = true;
                    st.dirty = true;
                }
            });
            LRESULT(0)
        }
        WM_MOUSEMOVE => {
            let p = point(lp);
            ST.with(|s| {
                if let Some(st) = s.try_borrow_mut().ok().as_mut().and_then(|b| b.as_mut()).filter(|st| st.drawing) {
                    if st.path.last().map(|l| l.distance(p) >= 2.0).unwrap_or(true) {
                        st.path.push(p);
                        st.dirty = true;
                    }
                }
            });
            LRESULT(0)
        }
        WM_LBUTTONUP => {
            let path = ST.with(|s| s.try_borrow_mut().ok().and_then(|mut b| b.as_mut().map(|st| std::mem::take(&mut st.path))).unwrap_or_default());
            let r = clinqy_core::agent::circle_bounds(&path);
            // A mere click isn't a circle.
            finish((path.len() > 3 && (r.w > 8.0 || r.h > 8.0)).then_some(path));
            LRESULT(0)
        }
        WM_RBUTTONDOWN => {
            finish(None);
            LRESULT(0)
        }
        WM_KEYDOWN if wp.0 as u16 == VK_ESCAPE.0 => {
            finish(None);
            LRESULT(0)
        }
        WM_ACTIVATE if (wp.0 & 0xffff) == WA_INACTIVE as usize => {
            // Clicked away to another app (or the hotkey): treat as cancel.
            if ST.with(|s| s.try_borrow().ok().and_then(|b| b.as_ref().map(|st| !st.drawing)).unwrap_or(false)) {
                finish(None);
            }
            LRESULT(0)
        }
        WM_TIMER => {
            render();
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wp, lp),
    }
}

fn render() {
    ST.with(|s| {
        let Ok(mut b) = s.try_borrow_mut() else { return };
        let Some(st) = b.as_mut().filter(|st| st.dirty && st.result.is_none()) else { return };
        // (UpdateLayeredWindow doesn't re-enter the window procedure.)
        st.dirty = false;
        let (w, h) = (st.area.w as u32, st.area.h as u32);
        let Some(mut pix) = Pixmap::new(w.max(1), h.max(1)) else { return };
        pix.fill(Color::from_rgba8(0, 0, 0, 46));
        // The hint pill near the top of the primary screen.
        let f = &crate::text::fonts().bold;
        let scale = crate::screen::scale() as f32;
        let size = 15.0 * scale;
        let hint = "Circle what you mean  ·  Esc to cancel";
        let tw = crate::text::measure(f, hint, size);
        let (ph, pw) = (size + 16.0 * scale, tw + 28.0 * scale);
        let (px, py) = ((-st.area.x) as f32 + crate::screen::primary_width() as f32 / 2.0 - pw / 2.0, (-st.area.y) as f32 + 72.0 * scale);
        let mut pb = PathBuilder::new();
        crate::overlay::rounded_rect(&mut pb, px, py, pw, ph, ph / 2.0);
        if let Some(p) = pb.finish() {
            let mut paint = Paint::default();
            paint.set_color(Color::from_rgba8(0, 0, 0, 178));
            paint.anti_alias = true;
            pix.fill_path(&p, &paint, FillRule::Winding, Transform::identity(), None);
        }
        crate::text::draw(&mut pix, f, hint, px + 14.0 * scale, py + ph / 2.0 + size * 0.36, size, Color::WHITE);
        // The loop so far, in yellow.
        if st.path.len() > 1 {
            let mut pb = PathBuilder::new();
            for (i, p) in st.path.iter().enumerate() {
                let (x, y) = ((p.x - st.area.x) as f32, (p.y - st.area.y) as f32);
                if i == 0 {
                    pb.move_to(x, y)
                } else {
                    pb.line_to(x, y)
                }
            }
            if let Some(path) = pb.finish() {
                let mut paint = Paint::default();
                paint.set_color(Color::from_rgba8(255, 214, 10, 255));
                paint.anti_alias = true;
                pix.stroke_path(&path, &paint, &Stroke { width: 4.0 * scale, line_cap: LineCap::Round, line_join: LineJoin::Round, ..Default::default() }, Transform::identity(), None);
            }
        }
        present(st.hwnd, &pix, st.area);
    });
}

fn present(hwnd: HWND, pix: &Pixmap, area: Rect) {
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
            let blend = BLENDFUNCTION { BlendOp: AC_SRC_OVER as u8, BlendFlags: 0, SourceConstantAlpha: 255, AlphaFormat: AC_SRC_ALPHA as u8 };
            let pos = POINT { x: area.x as i32, y: area.y as i32 };
            let _ = UpdateLayeredWindow(hwnd, screen, Some(&pos), Some(&SIZE { cx: w, cy: h }), mem, Some(&POINT::default()), COLORREF(0), Some(&blend), ULW_ALPHA);
            SelectObject(mem, old);
            let _ = DeleteObject(dib);
        }
        let _ = DeleteDC(mem);
        ReleaseDC(None, screen);
    }
}
