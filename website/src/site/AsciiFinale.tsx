import { useEffect, useRef, useState } from 'react'

const BANNER = [
  ' ██████╗██╗     ██╗███╗   ██╗ ██████╗ ██╗   ██╗',
  '██╔════╝██║     ██║████╗  ██║██╔═══██╗╚██╗ ██╔╝',
  '██║     ██║     ██║██╔██╗ ██║██║   ██║ ╚████╔╝ ',
  '██║     ██║     ██║██║╚██╗██║██║▄▄ ██║  ╚██╔╝  ',
  '╚██████╗███████╗██║██║ ╚████║╚██████╔╝   ██║   ',
  ' ╚═════╝╚══════╝╚═╝╚═╝  ╚═══╝ ╚══▀▀═╝    ╚═╝   ',
]

const ARROW = [
  '█         ',
  '██        ',
  '█▓█       ',
  '█▓▓█      ',
  '█▓▓▓█     ',
  '█▓▓▓▓█    ',
  '█▓▓▓▓▓█   ',
  '█▓▓▓▓▓▓█  ',
  '█▓▓▓▓▓▓▓█ ',
  '█▓▓▓▓█████',
  '█▓██▓█    ',
  '██  █▓█   ',
  '█    █▓█  ',
  '      █▓█ ',
  '       ██ ',
]


/** The sign-off: the banner and the companion arrow decode in, then it clicks. */
export function AsciiFinale() {
  const ref = useRef<HTMLDivElement>(null)
  const [p, setP] = useState(0)
  const [clicked, setClicked] = useState(false)

  useEffect(() => {
    const el = ref.current
    if (!el) return
    if (matchMedia('(prefers-reduced-motion: reduce)').matches) {
      setP(1)
      setClicked(true)
      return
    }
    let raf = 0
    const io = new IntersectionObserver(
      ([e]) => {
        if (!e.isIntersecting) return
        io.disconnect()
        const t0 = performance.now()
        const tick = (now: number) => {
          const v = Math.min(1, (now - t0) / 1800)
          setP(v)
          if (v < 1) raf = requestAnimationFrame(tick)
          else setTimeout(() => setClicked(true), 250)
        }
        raf = requestAnimationFrame(tick)
      },
      { threshold: 0.35 },
    )
    io.observe(el)
    return () => {
      io.disconnect()
      cancelAnimationFrame(raf)
    }
  }, [])

  const banner = BANNER
  const arrowRows = Math.round(p * ARROW.length)

  return (
    <div className="finale-art" ref={ref} aria-label="Clinqy" role="img">
      <pre className={'finale-arrow' + (clicked ? ' is-clicked' : '')} aria-hidden="true">
        {ARROW.map((l, i) => (i < arrowRows ? l : ' '.repeat(l.length))).join('\n')}
        <span className="finale-ring" />
      </pre>
      <pre className="finale-banner" aria-hidden="true" style={{ opacity: p }}>{banner.join('\n')}</pre>
    </div>
  )
}
