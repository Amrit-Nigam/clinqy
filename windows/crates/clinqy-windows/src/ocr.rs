//! Text recognition with Windows' own OCR (Windows.Media.Ocr): on-device, in the user's languages. Returns lines
//! and words with their screen rects, for clicking text that UI Automation doesn't list and for reading scans.

use crate::com;
use clinqy_core::platform::{Rect, TextBox};
use image::RgbaImage;
use windows::Graphics::Imaging::{BitmapAlphaMode, BitmapPixelFormat, SoftwareBitmap};
use windows::Media::Ocr::OcrEngine;
use windows::Security::Cryptography::CryptographicBuffer;

fn engine() -> Option<OcrEngine> {
    OcrEngine::TryCreateFromUserProfileLanguages().ok().or_else(|| {
        let lang = windows::Globalization::Language::CreateLanguage(&windows::core::HSTRING::from("en-US")).ok()?;
        OcrEngine::TryCreateFromLanguage(&lang).ok()
    })
}

/// Lines and words in `img`, which shows the screen area `area` (1:1 pixels).
pub fn recognize(img: &RgbaImage, area: Rect) -> Option<Vec<TextBox>> {
    com::ensure();
    let max = OcrEngine::MaxImageDimension().unwrap_or(10000);
    // Small text reads better a little larger; huge images must come down to the engine's limit.
    let scale = if img.width().max(img.height()) > max {
        max as f64 / img.width().max(img.height()) as f64
    } else if img.width() < 1600 {
        2.0
    } else {
        1.0
    };
    let work = if (scale - 1.0).abs() > 0.01 {
        image::imageops::resize(img, (img.width() as f64 * scale) as u32, (img.height() as f64 * scale) as u32, image::imageops::FilterType::Triangle)
    } else {
        img.clone()
    };
    let (w, h) = (work.width() as i32, work.height() as i32);
    let mut bgra = work.into_raw();
    for px in bgra.chunks_exact_mut(4) {
        px.swap(0, 2);
    }
    let buffer = CryptographicBuffer::CreateFromByteArray(&bgra).ok()?;
    let bitmap = SoftwareBitmap::CreateCopyWithAlphaFromBuffer(&buffer, BitmapPixelFormat::Bgra8, w, h, BitmapAlphaMode::Premultiplied).ok()?;
    let result = engine()?.RecognizeAsync(&bitmap).ok()?.get().ok()?;
    let mut out = vec![];
    let to_screen = |x: f32, y: f32, ww: f32, hh: f32| Rect::new(area.x + x as f64 / scale, area.y + y as f64 / scale, ww as f64 / scale, hh as f64 / scale);
    for line in result.Lines().ok()? {
        let text = line.Text().map(|t| t.to_string()).unwrap_or_default();
        let mut words = vec![];
        let (mut x0, mut y0, mut x1, mut y1) = (f32::MAX, f32::MAX, f32::MIN, f32::MIN);
        if let Ok(ws) = line.Words() {
            for word in ws {
                let (Ok(r), Ok(t)) = (word.BoundingRect(), word.Text()) else { continue };
                x0 = x0.min(r.X);
                y0 = y0.min(r.Y);
                x1 = x1.max(r.X + r.Width);
                y1 = y1.max(r.Y + r.Height);
                words.push(TextBox { text: t.to_string(), rect: to_screen(r.X, r.Y, r.Width, r.Height) });
            }
        }
        if x0 < x1 {
            out.push(TextBox { text, rect: to_screen(x0, y0, x1 - x0, y1 - y0) });
        }
        // Words too, so one word of a longer line can be clicked.
        if words.len() > 1 {
            out.extend(words);
        }
    }
    Some(out)
}

/// The text of an image file's bytes (PNG/JPEG), lines joined.
pub fn recognize_bytes(bytes: &[u8]) -> Option<String> {
    let img = image::load_from_memory(bytes).ok()?.to_rgba8();
    let area = Rect::new(0.0, 0.0, img.width() as f64, img.height() as f64);
    let boxes = recognize(&img, area)?;
    // Only the lines (words repeat them).
    let mut lines: Vec<&TextBox> = vec![];
    for b in &boxes {
        if !lines.iter().any(|l| l.rect.intersects(&b.rect) && l.text.contains(&b.text)) {
            lines.push(b);
        }
    }
    Some(lines.iter().map(|b| b.text.as_str()).collect::<Vec<_>>().join("\n"))
}
