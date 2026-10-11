import { createElement, useEffect, useRef, useState } from 'react'

const GLYPHS = '!<>-_\\/[]{}=+*^?#%$@&0123456789'
const noise = (s: string) => s.replace(/\S/g, () => GLYPHS[Math.floor(Math.random() * GLYPHS.length)])

type Props = { text: string; as?: keyof JSX.IntrinsicElements; className?: string; id?: string; start?: boolean }

/**
 * Text that decodes out of random glyphs the first time it scrolls into view.
 * In a monospace face every glyph is the same width, so nothing reflows.
 */
export function Scramble({ text, as = 'span', className, id, start = true }: Props) {
  const ref = useRef<HTMLElement>(null)
  const [shown, setShown] = useState(() => noise(text))
  const [seen, setSeen] = useState(false)

  useEffect(() => {
    if (matchMedia('(prefers-reduced-motion: reduce)').matches) {
      setShown(text)
      return
    }
    const el = ref.current
    if (!el) return
    const io = new IntersectionObserver(([e]) => e.isIntersecting && setSeen(true), { threshold: 0.4 })
    io.observe(el)
    return () => io.disconnect()
  }, [text])

  useEffect(() => {
    if (!seen || !start) return
    let raf = 0
    const t0 = performance.now()
    const dur = 500 + text.length * 22
    const tick = (now: number) => {
      const p = Math.min(1, (now - t0) / dur)
      const n = Math.floor(p * text.length)
      setShown(text.slice(0, n) + noise(text.slice(n)))
      if (p < 1) raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [seen, start, text])

  return createElement(as, { ref, className, id, 'aria-label': text }, <span aria-hidden="true">{shown}</span>)
}
