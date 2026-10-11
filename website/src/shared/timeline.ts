export type Key = { t: number; x: number; y: number; down?: boolean; click?: boolean }

export const clamp = (v: number, lo = 0, hi = 1) => Math.min(hi, Math.max(lo, v))
export const easeInOut = (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2)
export const easeOut = (t: number) => 1 - Math.pow(1 - t, 3)

/** Progress of t through [a, b], clamped to 0..1. */
export const span = (t: number, a: number, b: number) => clamp((t - a) / (b - a))

/** Typed-so-far slice of text between a and b. */
export const typed = (text: string, t: number, a: number, b: number) =>
  text.slice(0, Math.round(text.length * span(t, a, b)))

/**
 * Cursor position at time t. Free flights curve in an arc, like the real
 * companion; drags (down on both ends) move in a straight line.
 */
export function cursorAt(keys: Key[], t: number) {
  if (t <= keys[0].t) return { x: keys[0].x, y: keys[0].y, down: !!keys[0].down }
  for (let i = 1; i < keys.length; i++) {
    const a = keys[i - 1]
    const b = keys[i]
    if (t <= b.t) {
      const p = easeInOut(span(t, a.t, b.t))
      const dx = b.x - a.x
      const dy = b.y - a.y
      const drag = a.down && b.down
      const arc = drag ? 0 : Math.sin(p * Math.PI) * Math.min(60, Math.hypot(dx, dy) * 0.18)
      const len = Math.hypot(dx, dy) || 1
      return {
        x: a.x + dx * p + (-dy / len) * arc,
        y: a.y + dy * p + (dx / len) * arc,
        down: !!(a.down && (b.down || p < 1)),
      }
    }
  }
  const last = keys[keys.length - 1]
  return { x: last.x, y: last.y, down: !!last.down }
}

/** Most recent click key before t (for ripples), or null. */
export function lastClick(keys: Key[], t: number) {
  let hit: Key | null = null
  for (const k of keys) if (k.click && k.t <= t) hit = k
  return hit
}
