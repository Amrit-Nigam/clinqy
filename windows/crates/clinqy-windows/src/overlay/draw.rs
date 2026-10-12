//! Drawing the companion cursor and its marks into a pixmap (premultiplied RGBA), in screen pixels relative to
//! the overlay's top-left corner.

use clinqy_core::platform::{Mood, Point, Rect};
use tiny_skia::{Color, FillRule, LineCap, LineJoin, Paint, PathBuilder, Pixmap, Shader, Stroke, Transform};

pub fn mood_color(mood: Mood, qa: bool) -> (u8, u8, u8) {
    if qa {
        return (245, 158, 11); // amber
    }
    match mood {
        Mood::Idle | Mood::Acting => (59, 130, 246),
        Mood::Thinking => (139, 92, 246),
        Mood::Listening => (16, 185, 129),
        Mood::Success => (34, 197, 94),
        Mood::Failure => (239, 68, 68),
    }
}

fn paint(r: u8, g: u8, b: u8, a: u8) -> Paint<'static> {
    let mut p = Paint::default();
    p.set_color(Color::from_rgba8(r, g, b, a));
    p.anti_alias = true;
    p
}

/// The arrow with its tip at `tip`, scaled by `s`, with a soft glow; `pulse` 0…1 breathes the glow.
pub fn arrow(pix: &mut Pixmap, tip: Point, s: f32, rgb: (u8, u8, u8), pulse: f32, qa: bool) {
    let (x, y) = (tip.x as f32, tip.y as f32);
    if qa {
        // QA: an amber targeting reticle with a "QA" tag.
        let r = 11.0 * s;
        let mut pb = PathBuilder::new();
        pb.push_circle(x, y, r);
        let path = pb.finish().unwrap();
        let st = Stroke { width: 2.0 * s, ..Default::default() };
        pix.stroke_path(&path, &paint(rgb.0, rgb.1, rgb.2, 230), &st, Transform::identity(), None);
        for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
            let mut pb = PathBuilder::new();
            pb.move_to(x + dx * (r - 4.0 * s), y + dy * (r - 4.0 * s));
            pb.line_to(x + dx * (r + 5.0 * s), y + dy * (r + 5.0 * s));
            pix.stroke_path(&pb.finish().unwrap(), &paint(rgb.0, rgb.1, rgb.2, 230), &st, Transform::identity(), None);
        }
        let f = &crate::text::fonts().bold;
        let tw = crate::text::measure(f, "QA", 10.0 * s) + 6.0 * s;
        if let Some(tag) = tiny_skia::Rect::from_xywh(x + r + 2.0 * s, y - r - 12.0 * s, tw, 13.0 * s) {
            pix.fill_rect(tag, &paint(rgb.0, rgb.1, rgb.2, 235), Transform::identity(), None);
            crate::text::draw(pix, f, "QA", tag.x() + 3.0 * s, tag.y() + 10.5 * s, 10.0 * s, Color::WHITE);
        }
        return;
    }
    let shape = |pb: &mut PathBuilder| {
        // A classic pointer arrow, tip at (0,0), pointing up-left.
        let pts = [(0.0, 0.0), (0.0, 19.0), (4.6, 14.8), (7.9, 22.0), (11.0, 20.6), (7.8, 13.6), (13.6, 13.6)];
        pb.move_to(x + pts[0].0 * s, y + pts[0].1 * s);
        for p in &pts[1..] {
            pb.line_to(x + p.0 * s, y + p.1 * s);
        }
        pb.close();
    };
    let mut pb = PathBuilder::new();
    shape(&mut pb);
    let path = pb.finish().unwrap();
    // Glow: wide translucent strokes.
    for (w, a) in [(14.0, 18.0), (9.0, 30.0), (5.0, 55.0)] {
        let alpha = (a * (0.75 + 0.5 * pulse)) as u8;
        let st = Stroke { width: w * s, line_join: LineJoin::Round, ..Default::default() };
        pix.stroke_path(&path, &paint(rgb.0, rgb.1, rgb.2, alpha), &st, Transform::identity(), None);
    }
    // Body: a light-to-colour gradient.
    let mut p = Paint::default();
    p.anti_alias = true;
    p.shader = tiny_skia::LinearGradient::new(
        tiny_skia::Point::from_xy(x, y),
        tiny_skia::Point::from_xy(x + 10.0 * s, y + 22.0 * s),
        vec![
            tiny_skia::GradientStop::new(0.0, Color::from_rgba8(rgb.0.saturating_add(70), rgb.1.saturating_add(70), rgb.2.saturating_add(40), 255)),
            tiny_skia::GradientStop::new(1.0, Color::from_rgba8(rgb.0, rgb.1, rgb.2, 255)),
        ],
        tiny_skia::SpreadMode::Pad,
        Transform::identity(),
    )
    .unwrap_or(Shader::SolidColor(Color::from_rgba8(rgb.0, rgb.1, rgb.2, 255)));
    pix.fill_path(&path, &p, FillRule::Winding, Transform::identity(), None);
    let st = Stroke { width: 1.4 * s, line_join: LineJoin::Round, ..Default::default() };
    pix.stroke_path(&path, &paint(255, 255, 255, 240), &st, Transform::identity(), None);
}

/// A rounded frame around what the cursor is about to use.
pub fn frame(pix: &mut Pixmap, r: Rect, rgb: (u8, u8, u8), alpha: f32) {
    let r = r.inset(-3.0);
    let rad = 6.0f32.min((r.h / 2.0) as f32);
    let mut pb = PathBuilder::new();
    rounded(&mut pb, r.x as f32, r.y as f32, r.w as f32, r.h as f32, rad);
    let Some(path) = pb.finish() else { return };
    let st = Stroke { width: 2.0, ..Default::default() };
    pix.fill_path(&path, &paint(rgb.0, rgb.1, rgb.2, (28.0 * alpha) as u8), FillRule::Winding, Transform::identity(), None);
    pix.stroke_path(&path, &paint(rgb.0, rgb.1, rgb.2, (210.0 * alpha) as u8), &st, Transform::identity(), None);
}

fn rounded(pb: &mut PathBuilder, x: f32, y: f32, w: f32, h: f32, r: f32) {
    pb.move_to(x + r, y);
    pb.line_to(x + w - r, y);
    pb.quad_to(x + w, y, x + w, y + r);
    pb.line_to(x + w, y + h - r);
    pb.quad_to(x + w, y + h, x + w - r, y + h);
    pb.line_to(x + r, y + h);
    pb.quad_to(x, y + h, x, y + h - r);
    pb.line_to(x, y + r);
    pb.quad_to(x, y, x + r, y);
    pb.close();
}

/// An expanding ring where a click landed (`t` 0…1).
pub fn ripple(pix: &mut Pixmap, at: Point, t: f32, rgb: (u8, u8, u8), s: f32) {
    let mut pb = PathBuilder::new();
    pb.push_circle(at.x as f32, at.y as f32, (6.0 + 20.0 * t) * s);
    let Some(path) = pb.finish() else { return };
    let st = Stroke { width: 2.5 * s * (1.0 - t * 0.6), ..Default::default() };
    pix.stroke_path(&path, &paint(rgb.0, rgb.1, rgb.2, (220.0 * (1.0 - t)) as u8), &st, Transform::identity(), None);
}

/// A hand-drawn loop around `r`, an arrow coming in from the upper left, and a label; `t` 0…1 draws it in.
pub fn mark(pix: &mut Pixmap, r: Rect, label: Option<&str>, t: f32, s: f32) {
    let (cx, cy) = (r.mid_x() as f32, r.mid_y() as f32);
    let (rx, ry) = ((r.w as f32 / 2.0 + 12.0 * s).max(18.0 * s), (r.h as f32 / 2.0 + 10.0 * s).max(14.0 * s));
    let col = (250, 204, 21);
    // The loop: an ellipse drawn a little past a full turn, slightly wobbly, revealed over time.
    let sweep = (std::f32::consts::TAU * 1.08) * t.min(1.0);
    let mut pb = PathBuilder::new();
    let steps = 64;
    for i in 0..=steps {
        let a = -2.2 + sweep * i as f32 / steps as f32;
        let wob = 1.0 + 0.04 * (a * 3.0).sin();
        let (px, py) = (cx + rx * wob * a.cos(), cy + ry * wob * a.sin());
        if i == 0 {
            pb.move_to(px, py);
        } else {
            pb.line_to(px, py);
        }
    }
    if let Some(path) = pb.finish() {
        let st = Stroke { width: 3.2 * s, line_cap: LineCap::Round, line_join: LineJoin::Round, ..Default::default() };
        pix.stroke_path(&path, &paint(0, 0, 0, 70), &Stroke { width: 6.0 * s, ..st.clone() }, Transform::identity(), None);
        pix.stroke_path(&path, &paint(col.0, col.1, col.2, 245), &st, Transform::identity(), None);
    }
    if t < 0.6 {
        return;
    }
    // The arrow, from up-left of the loop to its edge.
    let (ex, ey) = (cx - rx * 0.72, cy - ry * 0.72);
    let (sx, sy) = (ex - 46.0 * s, ey - 38.0 * s);
    let mut pb = PathBuilder::new();
    pb.move_to(sx, sy);
    pb.quad_to(sx + 8.0 * s, ey - 4.0 * s, ex, ey);
    let st = Stroke { width: 3.0 * s, line_cap: LineCap::Round, ..Default::default() };
    if let Some(path) = pb.finish() {
        pix.stroke_path(&path, &paint(col.0, col.1, col.2, 245), &st, Transform::identity(), None);
    }
    let mut head = PathBuilder::new();
    head.move_to(ex, ey);
    head.line_to(ex - 11.0 * s, ey - 2.0 * s);
    head.move_to(ex, ey);
    head.line_to(ex - 3.0 * s, ey - 11.0 * s);
    if let Some(path) = head.finish() {
        pix.stroke_path(&path, &paint(col.0, col.1, col.2, 245), &st, Transform::identity(), None);
    }
    if let Some(label) = label.filter(|l| !l.is_empty()) {
        let f = &crate::text::fonts().bold;
        let size = 13.0 * s;
        let tw = crate::text::measure(f, label, size);
        let (bx, by) = (sx - tw / 2.0 - 8.0 * s, sy - 26.0 * s);
        let mut pb = PathBuilder::new();
        rounded(&mut pb, bx, by, tw + 16.0 * s, 22.0 * s, 8.0 * s);
        if let Some(path) = pb.finish() {
            pix.fill_path(&path, &paint(24, 24, 27, 235), FillRule::Winding, Transform::identity(), None);
            pix.stroke_path(&path, &paint(col.0, col.1, col.2, 255), &Stroke { width: 1.5 * s, ..Default::default() }, Transform::identity(), None);
        }
        crate::text::draw(pix, f, label, bx + 8.0 * s, by + 15.5 * s, size, Color::WHITE);
    }
}

/// A speech bubble below-right of the cursor.
pub fn bubble(pix: &mut Pixmap, at: Point, text: &str, rgb: (u8, u8, u8), s: f32) {
    let f = &crate::text::fonts().regular;
    let size = 12.0 * s;
    let tw = crate::text::measure(f, text, size);
    let (bx, by) = (at.x as f32 + 20.0 * s, at.y as f32 + 24.0 * s);
    let mut pb = PathBuilder::new();
    rounded(&mut pb, bx, by, tw + 18.0 * s, 22.0 * s, 11.0 * s);
    if let Some(path) = pb.finish() {
        pix.fill_path(&path, &paint(24, 24, 27, 230), FillRule::Winding, Transform::identity(), None);
        pix.stroke_path(&path, &paint(rgb.0, rgb.1, rgb.2, 220), &Stroke { width: 1.2 * s, ..Default::default() }, Transform::identity(), None);
    }
    crate::text::draw(pix, f, text, bx + 9.0 * s, by + 15.0 * s, size, Color::from_rgba8(240, 240, 245, 255));
}

/// Size a bubble needs, for the overlay's bounds.
pub fn bubble_size(text: &str, s: f32) -> (f32, f32) {
    (crate::text::measure(&crate::text::fonts().regular, text, 12.0 * s) + 60.0 * s, 60.0 * s)
}

/// Typing: three small dots bobbing beside the arrow.
pub fn typing_dots(pix: &mut Pixmap, at: Point, phase: f32, rgb: (u8, u8, u8), s: f32) {
    for i in 0..3 {
        let y = at.y as f32 + 26.0 * s - 3.0 * s * ((phase * 6.0 + i as f32 * 0.9).sin().max(0.0));
        let x = at.x as f32 + 18.0 * s + i as f32 * 6.0 * s;
        let mut pb = PathBuilder::new();
        pb.push_circle(x, y, 2.2 * s);
        if let Some(path) = pb.finish() {
            pix.fill_path(&path, &paint(rgb.0, rgb.1, rgb.2, 230), FillRule::Winding, Transform::identity(), None);
        }
    }
}

/// Listening: a ring that grows with the voice level.
pub fn level_ring(pix: &mut Pixmap, at: Point, level: f32, rgb: (u8, u8, u8), s: f32) {
    let mut pb = PathBuilder::new();
    pb.push_circle(at.x as f32 + 6.0 * s, at.y as f32 + 10.0 * s, (16.0 + 14.0 * level.min(1.0)) * s);
    if let Some(path) = pb.finish() {
        pix.stroke_path(&path, &paint(rgb.0, rgb.1, rgb.2, (90.0 + 140.0 * level.min(1.0)) as u8), &Stroke { width: 2.0 * s, ..Default::default() }, Transform::identity(), None);
    }
}

/// A check or a cross popping beside the cursor (QA results).
pub fn signal(pix: &mut Pixmap, at: Point, pass: bool, t: f32, s: f32) {
    let (x, y) = (at.x as f32 + 24.0 * s + if pass { 0.0 } else { 3.0 * s * (t * 40.0).sin() }, at.y as f32 - 6.0 * s);
    let scale = s * if pass { 0.6 + 0.4 * (t * 3.0).min(1.0) } else { 1.0 };
    let col = if pass { (34, 197, 94) } else { (239, 68, 68) };
    let mut pb = PathBuilder::new();
    pb.push_circle(x, y, 10.0 * scale);
    if let Some(path) = pb.finish() {
        pix.fill_path(&path, &paint(col.0, col.1, col.2, (240.0 * (1.0 - (t - 0.7).max(0.0) / 0.3)) as u8), FillRule::Winding, Transform::identity(), None);
    }
    let mut pb = PathBuilder::new();
    if pass {
        pb.move_to(x - 4.5 * scale, y);
        pb.line_to(x - 1.0 * scale, y + 3.5 * scale);
        pb.line_to(x + 5.0 * scale, y - 4.0 * scale);
    } else {
        pb.move_to(x - 4.0 * scale, y - 4.0 * scale);
        pb.line_to(x + 4.0 * scale, y + 4.0 * scale);
        pb.move_to(x + 4.0 * scale, y - 4.0 * scale);
        pb.line_to(x - 4.0 * scale, y + 4.0 * scale);
    }
    if let Some(path) = pb.finish() {
        pix.stroke_path(&path, &paint(255, 255, 255, 255), &Stroke { width: 2.2 * scale, line_cap: LineCap::Round, ..Default::default() }, Transform::identity(), None);
    }
}
