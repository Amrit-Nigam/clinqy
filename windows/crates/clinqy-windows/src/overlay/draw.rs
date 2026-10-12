//! Drawing the companion cursor and its marks, to the Mac's spec (Buddy.swift): a small solid triangle in the
//! accent blue with a soft glow, a spinning arc while thinking, five bars while listening, click ripples, a
//! focus ring around what it's about to use, a hand-drawn loop and arrow for marks, a dark capsule bubble.
//! Coordinates are pixels relative to the overlay's top-left; `s` is the monitor's scale (1.0 at 96 DPI).

use clinqy_core::platform::{Mood, Point, Rect};
use tiny_skia::{Color, FillRule, LineCap, LineJoin, Paint, Path, PathBuilder, Pixmap, Stroke, Transform};

/// Palette.rgba(for:) and the QA amber.
pub fn mood_color(mood: Mood, qa: bool) -> (u8, u8, u8) {
    match mood {
        Mood::Failure => (255, 84, 77),
        Mood::Success => (51, 204, 115),
        _ if qa => (255, 158, 10),
        _ => (59, 130, 255),
    }
}

fn paint(c: (u8, u8, u8), a: f32) -> Paint<'static> {
    let mut p = Paint::default();
    p.set_color(Color::from_rgba8(c.0, c.1, c.2, (a.clamp(0.0, 1.0) * 255.0) as u8));
    p.anti_alias = true;
    p
}

/// A soft glow behind a path: widening translucent strokes (CALayer's shadow with radius `r`).
fn glow(pix: &mut Pixmap, path: &Path, c: (u8, u8, u8), r: f32, strength: f32) {
    for k in 1..=4 {
        let w = r * k as f32 / 2.0;
        let st = Stroke { width: w, line_join: LineJoin::Round, line_cap: LineCap::Round, ..Default::default() };
        pix.stroke_path(path, &paint(c, strength * 0.16 / k as f32), &st, Transform::identity(), None);
    }
}

/// The triangle, tip at `tip` (the system cursor's stance), `scale` for presses and pops, `alpha` to fade.
pub fn triangle(pix: &mut Pixmap, tip: Point, s: f32, c: (u8, u8, u8), scale: f32, alpha: f32) {
    let k = s * scale;
    let (x, y) = (tip.x as f32, tip.y as f32);
    let mut pb = PathBuilder::new();
    pb.move_to(x, y);
    pb.line_to(x, y + 19.0 * k);
    pb.line_to(x + 5.2 * k, y + 14.2 * k);
    pb.line_to(x + 13.6 * k, y + 14.2 * k);
    pb.close();
    let Some(path) = pb.finish() else { return };
    glow(pix, &path, c, 6.0 * s, 0.85 * alpha);
    pix.fill_path(&path, &paint(c, alpha), FillRule::Winding, Transform::identity(), None);
    pix.stroke_path(&path, &paint(c, alpha), &Stroke { width: 2.0 * s, line_join: LineJoin::Round, ..Default::default() }, Transform::identity(), None);
}

/// QA: a targeting reticle with a "QA" tag.
pub fn reticle(pix: &mut Pixmap, tip: Point, s: f32, c: (u8, u8, u8), alpha: f32) {
    let (x, y) = (tip.x as f32 + 4.0 * s, tip.y as f32 + 4.0 * s);
    let r = 8.0 * s;
    let mut pb = PathBuilder::new();
    pb.push_circle(x, y, r);
    for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
        pb.move_to(x + dx * (r - 3.0 * s), y + dy * (r - 3.0 * s));
        pb.line_to(x + dx * (r + 4.0 * s), y + dy * (r + 4.0 * s));
    }
    let Some(path) = pb.finish() else { return };
    glow(pix, &path, c, 6.0 * s, 0.9 * alpha);
    pix.stroke_path(&path, &paint(c, alpha), &Stroke { width: 2.0 * s, line_cap: LineCap::Round, ..Default::default() }, Transform::identity(), None);
    let f = &crate::text::fonts().bold;
    let tw = crate::text::measure(f, "QA", 9.0 * s) + 8.0 * s;
    if let Some(tag) = tiny_skia::Rect::from_xywh(x + 16.0 * s, y - 22.0 * s, tw, 13.0 * s) {
        let mut pb = PathBuilder::new();
        pb.push_rect(tag);
        if let Some(p) = pb.finish() {
            pix.fill_path(&p, &paint(c, alpha), FillRule::Winding, Transform::identity(), None);
        }
        crate::text::draw(pix, f, "QA", tag.x() + 4.0 * s, tag.y() + 10.0 * s, 9.0 * s, Color::from_rgba8(255, 255, 255, (alpha * 255.0) as u8));
    }
}

/// Thinking: an arc spinning around the triangle's body.
pub fn spinner(pix: &mut Pixmap, tip: Point, s: f32, c: (u8, u8, u8), t: f32, alpha: f32) {
    let (cx, cy) = (tip.x as f32 + 9.0 * s, tip.y as f32 + 9.0 * s);
    let r = 9.0 * s;
    let start = (t * 9.0) % std::f32::consts::TAU;
    let sweep = (0.22 + 0.14 * ((t * 4.0).sin() + 1.0)) * std::f32::consts::TAU;
    let mut pb = PathBuilder::new();
    let steps = 32;
    for i in 0..=steps {
        let a = start + sweep * i as f32 / steps as f32;
        let (px, py) = (cx + r * a.cos(), cy + r * a.sin());
        if i == 0 {
            pb.move_to(px, py)
        } else {
            pb.line_to(px, py)
        }
    }
    let Some(path) = pb.finish() else { return };
    glow(pix, &path, c, 5.0 * s, 0.8 * alpha);
    pix.stroke_path(&path, &paint(c, alpha), &Stroke { width: 2.6 * s, line_cap: LineCap::Round, ..Default::default() }, Transform::identity(), None);
}

/// Listening: five bars dancing with the voice.
pub fn bars(pix: &mut Pixmap, tip: Point, s: f32, c: (u8, u8, u8), t: f32, level: f32, alpha: f32) {
    let (cx, cy) = (tip.x as f32 + 9.0 * s, tip.y as f32 + 9.0 * s);
    for i in 0..5 {
        let wave = ((t * 11.0 + i as f32 * 1.3).sin() + 1.0) / 2.0;
        let k = if i == 2 { 1.0 } else if i == 1 || i == 3 { 0.8 } else { 0.55 };
        let h = (4.0 + (3.0 + level * 16.0) * wave * k) * s;
        let x = cx - 12.0 * s + i as f32 * 5.0 * s;
        if let Some(r) = tiny_skia::Rect::from_xywh(x, cy - h / 2.0, 3.0 * s, h) {
            let mut pb = PathBuilder::new();
            pb.push_rect(r);
            if let Some(p) = pb.finish() {
                glow(pix, &p, c, 4.0 * s, 0.7 * alpha);
                pix.fill_path(&p, &paint(c, alpha), FillRule::Winding, Transform::identity(), None);
            }
        }
    }
}

/// The focus ring around what the cursor is about to use: rounded, accent stroke at 90%, 6% fill, glow.
pub fn frame(pix: &mut Pixmap, r: Rect, s: f32, c: (u8, u8, u8), alpha: f32) {
    let r = r.inset(-5.0);
    let corner = 9.0f32.min((r.h / 2.0) as f32);
    let mut pb = PathBuilder::new();
    rounded(&mut pb, r.x as f32, r.y as f32, r.w as f32, r.h as f32, corner);
    let Some(path) = pb.finish() else { return };
    pix.fill_path(&path, &paint(c, 0.06 * alpha), FillRule::Winding, Transform::identity(), None);
    glow(pix, &path, c, 8.0 * s, 0.8 * alpha);
    pix.stroke_path(&path, &paint(c, 0.9 * alpha), &Stroke { width: 2.0 * s, ..Default::default() }, Transform::identity(), None);
}

pub fn rounded(pb: &mut PathBuilder, x: f32, y: f32, w: f32, h: f32, r: f32) {
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

/// A click: a ring growing from 3 to 25 pt and fading over 0.55 s (`t` 0…1).
pub fn ripple(pix: &mut Pixmap, at: Point, s: f32, c: (u8, u8, u8), t: f32) {
    let r = (3.0 + (1.0 - (1.0 - t).powi(3)) * 22.0) * s;
    let mut pb = PathBuilder::new();
    pb.push_circle(at.x as f32, at.y as f32, r);
    let Some(path) = pb.finish() else { return };
    pix.stroke_path(&path, &paint(c, 0.9 * (1.0 - t)), &Stroke { width: 2.0 * s, ..Default::default() }, Transform::identity(), None);
}

/// A thin tapered ribbon along the last positions while moving.
pub fn streak(pix: &mut Pixmap, trail: &[Point], s: f32, c: (u8, u8, u8), alpha: f32) {
    if trail.len() < 3 {
        return;
    }
    let pts: Vec<(f32, f32)> = trail.iter().map(|p| (p.x as f32 + 5.0 * s, p.y as f32 + 6.0 * s)).collect();
    let length: f32 = pts.windows(2).map(|w| ((w[1].0 - w[0].0).powi(2) + (w[1].1 - w[0].1).powi(2)).sqrt()).sum();
    if length < 6.0 * s {
        return;
    }
    let n = pts.len();
    let (mut left, mut right) = (vec![], vec![]);
    for i in 0..n {
        let (a, b) = (pts[i.saturating_sub(1)], pts[(i + 1).min(n - 1)]);
        let d = ((b.0 - a.0).powi(2) + (b.1 - a.1).powi(2)).sqrt().max(0.001);
        let w = 1.6 * s * i as f32 / (n - 1) as f32;
        let (nx, ny) = (-(b.1 - a.1) / d * w, (b.0 - a.0) / d * w);
        left.push((pts[i].0 + nx, pts[i].1 + ny));
        right.push((pts[i].0 - nx, pts[i].1 - ny));
    }
    let mut pb = PathBuilder::new();
    pb.move_to(left[0].0, left[0].1);
    for p in left.iter().skip(1).chain(right.iter().rev()) {
        pb.line_to(p.0, p.1);
    }
    pb.close();
    if let Some(path) = pb.finish() {
        pix.fill_path(&path, &paint(c, alpha * (0.15 + length / (300.0 * s)).min(0.55)), FillRule::Winding, Transform::identity(), None);
    }
}

/// The marker: a slightly wobbly, overlapping loop drawn like a pen stroke, then a bowed arrow in from `tail`
/// (where the cursor parks). `age` in seconds draws it in; `fade` 0…1.
pub fn mark(pix: &mut Pixmap, r: Rect, tail: Point, seed: f32, age: f32, fade: f32, s: f32, c: (u8, u8, u8)) {
    let ease = |x: f32| 1.0 - (1.0 - x.clamp(0.0, 1.0)).powi(3);
    let (cx, cy) = (r.mid_x() as f32, r.mid_y() as f32);
    let (rx, ry) = ((r.w as f32 / 2.0 + 16.0 * s).max(26.0 * s), (r.h as f32 / 2.0 + 12.0 * s).max(20.0 * s));
    let st = Stroke { width: 3.2 * s, line_cap: LineCap::Round, line_join: LineJoin::Round, ..Default::default() };
    let shown = ease(age / 0.6);
    let steps = 90;
    let mut pb = PathBuilder::new();
    let upto = (steps as f32 * shown) as usize;
    for i in 0..=upto {
        let t = i as f32 / steps as f32;
        let a = seed + t * 1.12 * std::f32::consts::TAU;
        let wob = 1.0 + 0.035 * (3.0 * a + seed).sin() + 0.05 * t;
        let (px, py) = (cx + a.cos() * rx * wob, cy + a.sin() * ry * wob);
        if i == 0 {
            pb.move_to(px, py)
        } else {
            pb.line_to(px, py)
        }
    }
    if let Some(path) = pb.finish() {
        glow(pix, &path, c, 7.0 * s, 0.9 * fade);
        pix.stroke_path(&path, &paint(c, fade), &st, Transform::identity(), None);
    }
    let arrow = ease((age - 0.5) / 0.35);
    if arrow <= 0.0 {
        return;
    }
    let (tx, ty) = (tail.x as f32, tail.y as f32);
    let (dx, dy) = (tx - cx, ty - cy);
    let len = ((dx / rx).powi(2) + (dy / ry).powi(2)).sqrt().max(0.001);
    let tip = (cx + dx / len * 1.12, cy + dy / len * 1.12);
    let start = (tx + (tip.0 - tx) * 0.12, ty + (tip.1 - ty) * 0.12);
    let mid = ((start.0 + tip.0) / 2.0, (start.1 + tip.1) / 2.0);
    let (nx, ny) = (-(tip.1 - start.1), tip.0 - start.0);
    let nl = (nx * nx + ny * ny).sqrt().max(1.0);
    let ctrl = (mid.0 + nx / nl * 28.0 * s, mid.1 + ny / nl * 28.0 * s);
    let mut pb = PathBuilder::new();
    let steps = 24;
    let upto = (steps as f32 * arrow) as usize;
    for i in 0..=upto {
        let t = i as f32 / steps as f32;
        let u = 1.0 - t;
        let (px, py) = (u * u * start.0 + 2.0 * u * t * ctrl.0 + t * t * tip.0, u * u * start.1 + 2.0 * u * t * ctrl.1 + t * t * tip.1);
        if i == 0 {
            pb.move_to(px, py)
        } else {
            pb.line_to(px, py)
        }
    }
    let head = ease((age - 0.82) / 0.15);
    if head > 0.0 {
        let heading = (tip.1 - ctrl.1).atan2(tip.0 - ctrl.0);
        for side in [-1.0f32, 1.0] {
            let a = heading + std::f32::consts::PI - side * 0.5;
            pb.move_to(tip.0 + a.cos() * 13.0 * s * head, tip.1 + a.sin() * 13.0 * s * head);
            pb.line_to(tip.0, tip.1);
        }
    }
    if let Some(path) = pb.finish() {
        glow(pix, &path, c, 7.0 * s, 0.9 * fade);
        pix.stroke_path(&path, &paint(c, fade), &st, Transform::identity(), None);
    }
}

/// The bubble: a 28 pt capsule (white at 8%… on near-black, 92%) with an accent border, text 12 pt, below-right
/// of the cursor; `pop` scales it in.
pub fn bubble(pix: &mut Pixmap, at: Point, text: &str, s: f32, c: (u8, u8, u8), pop: f32, alpha: f32) {
    let f = &crate::text::fonts().regular;
    let size = 12.0 * s;
    let h = 28.0 * s * pop;
    let w = ((crate::text::measure(f, text, size) + 24.0 * s) * pop).max(h);
    let (x, y) = (at.x as f32 + 16.0 * s, at.y as f32 + 18.0 * s);
    let mut pb = PathBuilder::new();
    rounded(&mut pb, x, y, w, h, h / 2.0);
    if let Some(path) = pb.finish() {
        pix.fill_path(&path, &paint((20, 20, 20), 0.92 * alpha), FillRule::Winding, Transform::identity(), None);
        pix.stroke_path(&path, &paint(c, 0.45 * alpha), &Stroke { width: 0.8 * s, ..Default::default() }, Transform::identity(), None);
    }
    if pop > 0.9 {
        crate::text::draw(pix, f, text, x + 12.0 * s, y + 18.5 * s, size, Color::from_rgba8(255, 255, 255, (alpha * 235.0) as u8));
    }
}

pub fn bubble_size(text: &str, s: f32) -> (f32, f32) {
    (crate::text::measure(&crate::text::fonts().regular, text, 12.0 * s) + 60.0 * s, 56.0 * s)
}
