import { useEffect, useRef } from 'react'

/** Animated film/RF grain on a tiny canvas, scaled up. `amount` 0..1. */
export function Grain({ amount, className }: { amount: number; className?: string }) {
  const ref = useRef<HTMLCanvasElement>(null)
  const amt = useRef(amount)
  amt.current = amount

  useEffect(() => {
    const canvas = ref.current
    const ctx = canvas?.getContext('2d')
    if (!canvas || !ctx) return
    const w = (canvas.width = 220)
    const h = (canvas.height = 165)
    const img = ctx.createImageData(w, h)
    let raf = 0
    let last = 0
    const draw = (now: number) => {
      raf = requestAnimationFrame(draw)
      if (now - last < 42) return // ~24 fps reads more like analog than 60
      last = now
      const a = amt.current
      const d = img.data
      for (let i = 0; i < d.length; i += 4) {
        const v = Math.random() * 255
        d[i] = d[i + 1] = d[i + 2] = v
        d[i + 3] = Math.random() < 0.5 + a * 0.5 ? 255 * (0.25 + a * 0.75) : 0
      }
      ctx.putImageData(img, 0, 0)
    }
    raf = requestAnimationFrame(draw)
    return () => cancelAnimationFrame(raf)
  }, [])

  return <canvas ref={ref} className={className} aria-hidden="true" />
}
