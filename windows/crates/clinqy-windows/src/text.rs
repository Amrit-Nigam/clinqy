//! Text drawing for the overlay and annotated screenshots: Segoe UI from the Windows fonts folder, rasterised
//! with fontdue and blended into a tiny-skia pixmap.

use std::sync::OnceLock;
use tiny_skia::{Color, Pixmap};

pub struct Fonts {
    pub regular: fontdue::Font,
    pub bold: fontdue::Font,
}

pub fn fonts() -> &'static Fonts {
    static F: OnceLock<Fonts> = OnceLock::new();
    F.get_or_init(|| {
        let dir = std::env::var("WINDIR").unwrap_or_else(|_| r"C:\Windows".into()) + r"\Fonts\";
        let load = |names: &[&str]| -> fontdue::Font {
            for n in names {
                if let Ok(bytes) = std::fs::read(format!("{dir}{n}")) {
                    if let Ok(f) = fontdue::Font::from_bytes(bytes, fontdue::FontSettings::default()) {
                        return f;
                    }
                }
            }
            // Any TrueType font will do rather than none.
            let any = std::fs::read_dir(&dir).ok().and_then(|d| d.flatten().find(|e| e.path().extension().map(|x| x == "ttf").unwrap_or(false)));
            let bytes = any.and_then(|e| std::fs::read(e.path()).ok()).unwrap_or_default();
            fontdue::Font::from_bytes(bytes, fontdue::FontSettings::default()).expect("no usable font")
        };
        Fonts { regular: load(&["segoeui.ttf", "arial.ttf"]), bold: load(&["seguisb.ttf", "segoeuib.ttf", "arialbd.ttf"]) }
    })
}

/// Width of `text` at `size` px.
pub fn measure(font: &fontdue::Font, text: &str, size: f32) -> f32 {
    text.chars().map(|c| font.metrics(c, size).advance_width).sum()
}

/// Draws `text` with its baseline at (x, y).
pub fn draw(pix: &mut Pixmap, font: &fontdue::Font, text: &str, x: f32, y: f32, size: f32, color: Color) {
    let (w, h) = (pix.width() as i32, pix.height() as i32);
    let data = pix.data_mut();
    let c = color.to_color_u8();
    let mut pen = x;
    for ch in text.chars() {
        let (m, bitmap) = font.rasterize(ch, size);
        let gx = (pen + m.xmin as f32).round() as i32;
        let gy = (y - m.height as f32 - m.ymin as f32).round() as i32;
        for row in 0..m.height as i32 {
            for col in 0..m.width as i32 {
                let (px, py) = (gx + col, gy + row);
                if px < 0 || py < 0 || px >= w || py >= h {
                    continue;
                }
                let cov = bitmap[(row * m.width as i32 + col) as usize] as u32;
                if cov == 0 {
                    continue;
                }
                let a = cov * c.alpha() as u32 / 255;
                let i = ((py * w + px) * 4) as usize;
                // Premultiplied "source over".
                for (k, s) in [c.red(), c.green(), c.blue()].iter().enumerate() {
                    let src = *s as u32 * a / 255;
                    data[i + k] = (src + data[i + k] as u32 * (255 - a) / 255) as u8;
                }
                data[i + 3] = (a + data[i + 3] as u32 * (255 - a) / 255) as u8;
            }
        }
        pen += m.advance_width;
    }
}
