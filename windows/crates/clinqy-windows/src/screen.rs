//! Screenshots: a window's area grabbed from the screen (Clinqy's own overlay windows are excluded from capture),
//! as PNG for snaps and as a scaled JPEG with red e-id boxes for the model. The last shot's geometry maps the
//! model's x/y back to the screen.

use clinqy_core::platform::{Element, Point, Rect};
use image::{ImageBuffer, Rgba, RgbaImage};
use parking_lot::Mutex;
use tiny_skia::{Color, Paint, PathBuilder, Pixmap, Stroke, Transform};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::WindowsAndMessaging::{GetSystemMetrics, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN};

/// The whole desktop's rect (all monitors).
pub fn virtual_screen() -> Rect {
    unsafe {
        Rect::new(
            GetSystemMetrics(SM_XVIRTUALSCREEN) as f64,
            GetSystemMetrics(SM_YVIRTUALSCREEN) as f64,
            GetSystemMetrics(SM_CXVIRTUALSCREEN) as f64,
            GetSystemMetrics(SM_CYVIRTUALSCREEN) as f64,
        )
    }
}

/// Pixels of a screen area, RGBA.
pub fn capture(area: Rect) -> Option<RgbaImage> {
    let area = area.intersection(&virtual_screen());
    if area.is_empty() {
        return None;
    }
    let (x, y, w, h) = (area.x as i32, area.y as i32, area.w as i32, area.h as i32);
    unsafe {
        let screen = GetDC(None);
        let mem = CreateCompatibleDC(screen);
        let bmp = CreateCompatibleBitmap(screen, w, h);
        let old = SelectObject(mem, bmp);
        let ok = BitBlt(mem, 0, 0, w, h, screen, x, y, SRCCOPY | CAPTUREBLT).is_ok();
        let mut info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: w,
                biHeight: -h, // top-down
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut buf = vec![0u8; (w * h * 4) as usize];
        let lines = if ok { GetDIBits(mem, bmp, 0, h as u32, Some(buf.as_mut_ptr() as _), &mut info, DIB_RGB_COLORS) } else { 0 };
        SelectObject(mem, old);
        let _ = DeleteObject(bmp);
        let _ = DeleteDC(mem);
        ReleaseDC(None, screen);
        if lines == 0 {
            return None;
        }
        // BGRA → RGBA, opaque.
        for px in buf.chunks_exact_mut(4) {
            px.swap(0, 2);
            px[3] = 255;
        }
        ImageBuffer::from_raw(w as u32, h as u32, buf)
    }
}

/// True when nearly every pixel is the same (a protected or blank window).
pub fn is_blank(img: &RgbaImage) -> bool {
    let first = img.get_pixel(0, 0);
    let step = (img.width() * img.height() / 2000).max(1) as usize;
    img.pixels().step_by(step).filter(|p| *p != first).count() < 3
}

pub fn png(img: &RgbaImage) -> Vec<u8> {
    let mut out = std::io::Cursor::new(vec![]);
    let _ = img.write_to(&mut out, image::ImageFormat::Png);
    out.into_inner()
}

/// Where the last screenshot sent to the model was taken from and how big it was after scaling.
pub struct LastShot {
    pub area: Rect,
    pub width: u32,
    pub height: u32,
}

pub static LAST: Mutex<Option<LastShot>> = Mutex::new(None);

/// A point on the last screenshot (image pixels) on screen.
pub fn screen_point(x: f64, y: f64) -> Option<Point> {
    let l = LAST.lock();
    let s = l.as_ref()?;
    let (sx, sy) = (s.area.w / s.width as f64, s.area.h / s.height as f64);
    Some(Point::new(s.area.x + x * sx, s.area.y + y * sy))
}

pub fn scale() -> f64 {
    LAST.lock().as_ref().map(|s| s.area.w / s.width as f64).unwrap_or(1.0)
}

/// The window for the model: at most 1400 px wide, red boxes on the listed elements tagged with their e-ids,
/// as base64 JPEG.
pub fn for_model(area: Rect, elements: &[Element], circled: Option<&[Point]>) -> Option<String> {
    let img = capture(area)?;
    let max_w = 1400u32;
    let img = if img.width() > max_w {
        let h = (img.height() as f64 * max_w as f64 / img.width() as f64) as u32;
        image::imageops::resize(&img, max_w, h, image::imageops::FilterType::Triangle)
    } else {
        img
    };
    let (w, h) = (img.width(), img.height());
    let s = w as f64 / area.w;
    let mut pix = Pixmap::from_vec(img.into_raw(), tiny_skia::IntSize::from_wh(w, h)?)?;
    let mut paint = Paint::default();
    paint.set_color(Color::from_rgba8(230, 30, 30, 230));
    paint.anti_alias = true;
    let stroke = Stroke { width: 1.5, ..Default::default() };
    let f = &crate::text::fonts().bold;
    for e in elements.iter().take(150) {
        let r = Rect::new((e.rect.x - area.x) * s, (e.rect.y - area.y) * s, e.rect.w * s, e.rect.h * s);
        if r.w < 4.0 || r.h < 4.0 || r.x > w as f64 || r.y > h as f64 || r.max_x() < 0.0 || r.max_y() < 0.0 {
            continue;
        }
        if let Some(rect) = tiny_skia::Rect::from_xywh(r.x as f32, r.y as f32, r.w as f32, r.h as f32) {
            pix.stroke_path(&PathBuilder::from_rect(rect), &paint, &stroke, Transform::identity(), None);
        }
        // The id in a small filled tag at the box's top-left.
        let size = 11.0;
        let tw = crate::text::measure(f, &e.id, size) + 4.0;
        if let Some(tag) = tiny_skia::Rect::from_xywh(r.x as f32, (r.y as f32 - 13.0).max(0.0), tw, 13.0) {
            pix.fill_rect(tag, &paint, Transform::identity(), None);
            crate::text::draw(&mut pix, f, &e.id, tag.x() + 2.0, tag.y() + 10.5, size, Color::WHITE);
        }
    }
    // What the user circled, drawn the way they drew it (a yellow loop).
    if let Some(pts) = circled.filter(|p| p.len() > 1) {
        let mut pb = PathBuilder::new();
        for (i, p) in pts.iter().enumerate() {
            let (x, y) = (((p.x - area.x) * s) as f32, ((p.y - area.y) * s) as f32);
            if i == 0 {
                pb.move_to(x, y)
            } else {
                pb.line_to(x, y)
            }
        }
        if let Some(path) = pb.finish() {
            let mut yellow = Paint::default();
            yellow.set_color(Color::from_rgba8(255, 214, 10, 255));
            yellow.anti_alias = true;
            let st = Stroke { width: 4.0, line_cap: tiny_skia::LineCap::Round, line_join: tiny_skia::LineJoin::Round, ..Default::default() };
            pix.stroke_path(&path, &yellow, &st, Transform::identity(), None);
        }
    }
    *LAST.lock() = Some(LastShot { area, width: w, height: h });
    let rgba: RgbaImage = ImageBuffer::from_raw(w, h, pix.take())?;
    let rgb = image::DynamicImage::ImageRgba8(rgba).to_rgb8();
    let mut out = std::io::Cursor::new(vec![]);
    let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 72);
    enc.encode_image(&rgb).ok()?;
    use base64::Engine;
    Some(base64::engine::general_purpose::STANDARD.encode(out.into_inner()))
}

pub fn _unused(_: Rgba<u8>) {}

/// The primary monitor's width in pixels.
pub fn primary_width() -> i32 {
    unsafe { windows::Win32::UI::WindowsAndMessaging::GetSystemMetrics(windows::Win32::UI::WindowsAndMessaging::SM_CXSCREEN) }
}

/// Keeps one of Clinqy's own windows out of screenshots and screen shares (so it never sees itself). Set
/// CLINQY_CAPTURABLE=1 to let them show, e.g. to take screenshots of Clinqy for docs.
pub fn hide_from_capture(hwnd: isize) {
    if std::env::var("CLINQY_CAPTURABLE").map(|v| v == "1").unwrap_or(false) {
        return;
    }
    use windows::Win32::UI::WindowsAndMessaging::{SetWindowDisplayAffinity, WDA_EXCLUDEFROMCAPTURE};
    unsafe {
        let _ = SetWindowDisplayAffinity(windows::Win32::Foundation::HWND(hwnd as _), WDA_EXCLUDEFROMCAPTURE);
    }
}
