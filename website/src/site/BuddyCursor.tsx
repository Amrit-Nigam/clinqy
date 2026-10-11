import { useEffect, useRef, useState } from 'react'
import { CursorArrow } from '../shared/Cursor'

/**
 * The clingy part: a companion arrow rides beside the visitor's pointer,
 * flies over to frame anything marked data-buddy, and floats off when idle.
 */
export function BuddyCursor({ enabled }: { enabled: boolean }) {
  const arrow = useRef<HTMLDivElement>(null)
  const frame = useRef<HTMLDivElement>(null)
  const [supported, setSupported] = useState(false)

  useEffect(() => {
    const fine = matchMedia('(pointer: fine)').matches
    const calm = matchMedia('(prefers-reduced-motion: reduce)').matches
    setSupported(fine && !calm)
  }, [])

  useEffect(() => {
    if (!enabled || !supported) return
    const pos = { x: innerWidth * 0.7, y: innerHeight * 0.4 }
    const vel = { x: 0, y: 0 }
    const mouse = { x: pos.x, y: pos.y, seen: false }
    let target: Element | null = null
    let lastMove = performance.now()
    let raf = 0

    const onMove = (e: PointerEvent) => {
      mouse.x = e.clientX
      mouse.y = e.clientY
      mouse.seen = true
      lastMove = performance.now()
      target = (e.target as Element | null)?.closest('[data-buddy]') ?? null
    }
    const onLeave = () => (target = null)

    const tick = (now: number) => {
      raf = requestAnimationFrame(tick)
      const el = arrow.current
      const fr = frame.current
      if (!el || !fr) return
      let tx = mouse.x + 18
      let ty = mouse.y + 16
      let framing = false
      if (target) {
        const r = target.getBoundingClientRect()
        tx = r.right - 10
        ty = r.bottom - 8
        framing = true
        fr.style.transform = `translate(${r.left - 6}px, ${r.top - 6}px)`
        fr.style.width = `${r.width + 12}px`
        fr.style.height = `${r.height + 12}px`
      }
      const idle = now - lastMove > 2600
      if (idle && !framing) {
        // Drift a little away and bob, like the app does when you stop.
        const s = (now - lastMove - 2600) / 1000
        tx += 40 + Math.sin(s * 1.3) * 10
        ty += -30 + Math.cos(s * 1.7) * 8
      }
      // Critically-damped-ish spring: a touch of lag reads as "following".
      const k = framing ? 0.09 : 0.14
      vel.x = (vel.x + (tx - pos.x) * k) * 0.72
      vel.y = (vel.y + (ty - pos.y) * k) * 0.72
      pos.x += vel.x
      pos.y += vel.y
      const tilt = Math.max(-14, Math.min(14, vel.x * 0.8))
      el.style.transform = `translate(${pos.x}px, ${pos.y}px) rotate(${tilt}deg)`
      el.style.opacity = mouse.seen ? '1' : '0'
      fr.style.opacity = framing ? '1' : '0'
    }

    window.addEventListener('pointermove', onMove, { passive: true })
    document.addEventListener('pointerleave', onLeave)
    raf = requestAnimationFrame(tick)
    return () => {
      cancelAnimationFrame(raf)
      window.removeEventListener('pointermove', onMove)
      document.removeEventListener('pointerleave', onLeave)
    }
  }, [enabled, supported])

  if (!supported) return null
  return (
    <>
      <div ref={frame} className="buddy-frame" aria-hidden="true" />
      <div ref={arrow} className="buddy" aria-hidden="true">
        <CursorArrow size={20} />
      </div>
    </>
  )
}
