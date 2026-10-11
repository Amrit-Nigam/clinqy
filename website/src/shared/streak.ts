/**
 * The trail the real Clinqy draws behind its cursor (Buddy.swift, renderStreak):
 * a thin ribbon along the last ~0.1 s of positions, from the arrow's body
 * rather than its tip, 0 wide at the tail and 3.2 px at the head. Fainter on
 * slow drifts, a touch stronger on quick moves; nothing when barely moving.
 */
export type Pt = { x: number; y: number }

/** Longest the ribbon may get, so a sudden jump never draws a line across the screen. */
const MAX_LEN = 110

export function streak(raw: Pt[], scale = 1): { d: string; opacity: number } | null {
  let pts = raw.map((p) => ({ x: p.x + 5 * scale, y: p.y + 6 * scale }))
  // Keep only the newest MAX_LEN px, trimming the tail point onto the cut.
  let run = 0
  for (let i = pts.length - 1; i > 0; i--) {
    const seg = Math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
    if (run + seg > MAX_LEN * scale) {
      const k = (MAX_LEN * scale - run) / seg
      const cut = { x: pts[i].x + (pts[i - 1].x - pts[i].x) * k, y: pts[i].y + (pts[i - 1].y - pts[i].y) * k }
      pts = [cut, ...pts.slice(i)]
      break
    }
    run += seg
  }
  // Short runs need a midpoint or two so the taper still reads.
  while (pts.length < 4 && pts.length >= 2) {
    const a = pts[0]
    const b = pts[1]
    pts = [a, { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }, ...pts.slice(1)]
  }
  let length = 0
  for (let i = 1; i < pts.length; i++) length += Math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
  if (pts.length < 3 || length < 6 * scale) return null
  const left: Pt[] = []
  const right: Pt[] = []
  for (let i = 0; i < pts.length; i++) {
    const a = pts[Math.max(0, i - 1)]
    const b = pts[Math.min(pts.length - 1, i + 1)]
    const d = Math.max(0.001, Math.hypot(b.x - a.x, b.y - a.y))
    const w = ((1.6 * i) / (pts.length - 1)) * scale
    const n = { x: (-(b.y - a.y) / d) * w, y: ((b.x - a.x) / d) * w }
    left.push({ x: pts[i].x + n.x, y: pts[i].y + n.y })
    right.push({ x: pts[i].x - n.x, y: pts[i].y - n.y })
  }
  const all = [...left, ...right.reverse()]
  const d = 'M' + all.map((p) => `${p.x.toFixed(1)} ${p.y.toFixed(1)}`).join('L') + 'Z'
  return { d, opacity: Math.min(0.55, 0.15 + length / scale / 300) }
}

/** Keeps the last `window` ms of positions for a cursor that moves in real time. */
export class Trail {
  private pts: { p: Pt; t: number }[] = []
  constructor(private window = 100) {}
  push(p: Pt, now = performance.now()) {
    this.pts.push({ p: { ...p }, t: now })
    this.pts = this.pts.filter((q) => now - q.t <= this.window)
    return this.pts.map((q) => q.p)
  }
  clear() {
    this.pts = []
  }
}

/** Write a streak into an SVG <path>, or hide it. */
export function paint(path: SVGPathElement | null, s: ReturnType<typeof streak>) {
  if (!path) return
  if (!s) {
    path.setAttribute('d', '')
    return
  }
  path.setAttribute('d', s.d)
  path.style.opacity = String(s.opacity)
}
