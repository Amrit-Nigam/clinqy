import { useEffect, useRef } from 'react'

/** What Clinqy is busy with, decoding out of the noise one line at a time. */
const ACTIONS = [
  'open Safari → flights.example.com',
  'click “IndiGo 6E 2131”',
  'screenshot 370×200 → saved',
  'type “Riya Sharma”',
  'upload resume.pdf',
  'tick [x] I agree to the privacy notice',
  'ask: Pay ₹4,420 on flights.example.com?',
  'set Brightness +40 → export beach-edit.jpg',
  'launch t3.micro “tf-server” in ap-south-1',
  'message Mom: I’ll be late, stuck in traffic',
  'add event: Call with Priya, Thu 3:00 PM',
  'move invoice-sept.pdf → Downloads/PDFs',
  'find “the PDF I got from HR last week”',
  'remember: Riya prefers window seats',
  'pick “United States” from Country',
  'read page → 4 results, cheapest ₹4,420',
  'open WhatsApp from the Dock',
  'scroll Results until “Akasa QP 1104”',
]

const GLYPHS = '!<>-_\\/[]{}=+*^?#%$@&ABCDEFabcdef0123456789'
const RAMP = '.·:-=+*#'
const ARROW = ['█', '██', '█▓█', '█▓▓█', '█▓▓▓█', '█▓▓▓▓█', '█▓▓███', '██ █▓█', '    ██']

type Snip = { text: string; col: number; row: number; born: number; clicked: number; drift: number }

const rnd = (n: number) => Math.floor(Math.random() * n)
const glyph = () => GLYPHS[rnd(GLYPHS.length)]

/**
 * A full-screen ASCII field: drifting noise, Clinqy's actions decoding in and
 * out, and an ASCII cursor that flies over to click each one.
 */
export function AsciiField({ running }: { running: boolean }) {
  const ref = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const canvas = ref.current
    const ctx = canvas?.getContext('2d')
    if (!canvas || !ctx) return
    const calm = matchMedia('(prefers-reduced-motion: reduce)').matches

    const FONT = 13
    const LINE = 17
    let cw = 8
    let cols = 0
    let rows = 0
    let dpr = 1
    const resize = () => {
      dpr = Math.min(2, devicePixelRatio || 1)
      canvas.width = innerWidth * dpr
      canvas.height = innerHeight * dpr
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      ctx.font = `${FONT}px "IBM Plex Mono", ui-monospace, monospace`
      ctx.textBaseline = 'top'
      cw = ctx.measureText('M').width
      cols = Math.ceil(innerWidth / cw)
      rows = Math.ceil(innerHeight / LINE)
    }
    resize()
    addEventListener('resize', resize)

    const mouse = { x: -999, y: -999 }
    const onMove = (e: PointerEvent) => {
      mouse.x = e.clientX
      mouse.y = e.clientY
    }
    addEventListener('pointermove', onMove, { passive: true })
    // Past the hero, veil the field more so long-form text stays easy to read.
    const onScroll = () =>
      document.documentElement.style.setProperty('--veil', String(Math.min(1, scrollY / (innerHeight * 0.7))))
    onScroll()
    addEventListener('scroll', onScroll, { passive: true })

    const snips: Snip[] = []
    let lastSpawn = -9999
    let next = 0
    const cur = { x: innerWidth * 0.7, y: innerHeight * 0.3, fx: 0, fy: 0, tx: 0, ty: 0, start: 0, target: null as Snip | null }
    const trail: { x: number; y: number }[] = []
    let ripple: { x: number; y: number; at: number } | null = null

    const DECODE = 800
    const HOLD = 3400
    const OUT = 600
    const LIFE = DECODE + HOLD + OUT

    function spawn(now: number) {
      const text = ACTIONS[next++ % ACTIONS.length]
      const full = '> ' + text
      // Keep to the right of the reading column on wide screens.
      const minCol = innerWidth > 900 ? Math.floor(cols * 0.42) : 1
      const maxCol = Math.max(minCol + 1, cols - full.length - 3)
      let row = 0
      for (let tries = 0; tries < 12; tries++) {
        row = 4 + rnd(Math.max(1, rows - 8))
        if (!snips.some((s) => Math.abs(s.row - row) < 2)) break
      }
      snips.push({ text: full, col: minCol + rnd(maxCol - minCol), row, born: now, clicked: 0, drift: Math.random() < 0.5 ? -1 : 1 })
    }

    function pickTarget(now: number) {
      const ready = snips.filter((s) => !s.clicked && now - s.born > DECODE && now - s.born < DECODE + HOLD - 1200)
      if (!ready.length) return
      const s = ready[rnd(ready.length)]
      cur.target = s
      cur.fx = cur.x
      cur.fy = cur.y
      cur.start = now
    }

    let raf = 0
    let last = 0
    const t0 = performance.now()

    function frame(now: number) {
      raf = requestAnimationFrame(frame)
      if (now - last < 33) return
      last = now
      const t = (now - t0) / 1000
      ctx!.clearRect(0, 0, innerWidth, innerHeight)

      // 1. Drifting noise. Mostly empty; brighter around the pointer.
      const mc = mouse.x / cw
      const mr = mouse.y / LINE
      for (let r = 0; r < rows; r++) {
        for (let c = 0; c < cols; c++) {
          let v =
            Math.sin(c * 0.07 + t * 0.5) +
            Math.sin(r * 0.17 - t * 0.35) +
            Math.sin((c + r * 2) * 0.045 + t * 0.25) +
            Math.sin(Math.hypot(c - cols * 0.7, (r - rows * 0.4) * 2) * 0.09 - t * 0.8)
          v = (v + 4) / 8
          const dm = Math.hypot(c - mc, (r - mr) * 2)
          const near = dm < 14 ? (1 - dm / 14) * 0.5 : 0
          const i = v + near
          if (i < 0.62) continue
          const k = Math.min(RAMP.length - 1, Math.floor((i - 0.62) * 22))
          ctx!.fillStyle = `rgba(240, 232, 214, ${0.05 + (i - 0.62) * 0.5 + near * 0.4})`
          ctx!.fillText(RAMP[k], c * cw, r * LINE)
        }
      }

      // 2. Actions: decode in, hold, scramble out.
      if (now - lastSpawn > 1100 && snips.length < 7) {
        spawn(now)
        lastSpawn = now
      }
      for (let i = snips.length - 1; i >= 0; i--) {
        const s = snips[i]
        const age = now - s.born
        if (age > LIFE) {
          snips.splice(i, 1)
          if (cur.target === s) cur.target = null
          continue
        }
        const shown = age < DECODE ? age / DECODE : age > DECODE + HOLD ? 1 - (age - DECODE - HOLD) / OUT : 1
        const n = Math.floor(shown * s.text.length)
        const flash = s.clicked ? Math.max(0, 1 - (now - s.clicked) / 700) : 0
        const y = s.row * LINE - (age / LIFE) * 10 * s.drift
        const text = s.clicked && now > s.clicked ? s.text + '  ✓' : s.text
        for (let j = 0; j < text.length; j++) {
          const ch = j < n || j >= s.text.length ? text[j] : j < n + 6 ? glyph() : ''
          if (!ch || ch === ' ') continue
          const isPrompt = j === 0
          const done = j >= s.text.length
          ctx!.fillStyle = isPrompt || done ? `rgba(141, 255, 176, ${0.75 * Math.min(1, shown * 1.5)})` : `rgba(240, 232, 214, ${(j < n ? 0.62 : 0.3) + flash * 0.38})`
          ctx!.fillText(ch, (s.col + j) * cw, y)
        }
      }

      // 3. The cursor: arc over to a decoded action, click it, pick the next.
      if (!cur.target) pickTarget(now)
      const tg = cur.target
      if (tg) {
        const age = now - tg.born
        const tx = (tg.col + 2) * cw
        const ty = tg.row * LINE - (age / LIFE) * 10 * tg.drift + LINE * 0.6
        const p = Math.min(1, (now - cur.start) / 900)
        const e = p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2
        const dx = tx - cur.fx
        const dy = ty - cur.fy
        const len = Math.hypot(dx, dy) || 1
        const arc = Math.sin(e * Math.PI) * Math.min(80, len * 0.2)
        cur.x = cur.fx + dx * e + (-dy / len) * arc
        cur.y = cur.fy + dy * e + (dx / len) * arc
        if (p >= 1 && !tg.clicked) {
          tg.clicked = now + 120
          ripple = { x: cur.x, y: cur.y, at: now }
        }
        if (tg.clicked && now - tg.clicked > 500) cur.target = null
      } else {
        // Idle: float gently, like the app does.
        cur.y += Math.sin(t * 1.6) * 0.4
      }
      trail.push({ x: cur.x, y: cur.y })
      if (trail.length > 14) trail.shift()
      trail.forEach((q, i) => {
        ctx!.fillStyle = `rgba(74, 140, 255, ${(i / trail.length) * 0.5})`
        ctx!.fillText('·', q.x, q.y)
      })

      if (ripple) {
        const rp = (now - ripple.at) / 600
        if (rp >= 1) ripple = null
        else {
          const rad = 4 + rp * 46
          const count = 12 + Math.floor(rp * 16)
          ctx!.fillStyle = `rgba(74, 140, 255, ${1 - rp})`
          for (let k = 0; k < count; k++) {
            const a = (k / count) * Math.PI * 2
            ctx!.fillText(rp < 0.4 ? 'o' : '·', ripple.x + Math.cos(a) * rad - cw / 2, ripple.y + Math.sin(a) * rad * 0.8 - LINE / 2)
          }
        }
      }

      ctx!.save()
      ctx!.shadowColor = 'rgba(74, 140, 255, 0.9)'
      ctx!.shadowBlur = 12
      ARROW.forEach((line, i) => {
        for (let j = 0; j < line.length; j++) {
          const ch = line[j]
          if (ch === ' ') continue
          ctx!.fillStyle = ch === '▓' ? '#2f6fe0' : '#8fb6ff'
          ctx!.fillText(ch, cur.x + j * cw, cur.y + i * (LINE - 3))
        }
      })
      ctx!.restore()
    }

    if (calm) {
      // One still frame, no motion.
      for (let i = 0; i < 5; i++) spawn(-DECODE - 100)
      frame(performance.now() + 100)
      cancelAnimationFrame(raf)
    } else if (running) {
      raf = requestAnimationFrame(frame)
    }

    return () => {
      cancelAnimationFrame(raf)
      removeEventListener('resize', resize)
      removeEventListener('pointermove', onMove)
      removeEventListener('scroll', onScroll)
    }
  }, [running])

  return (
    <div className="field" aria-hidden="true">
      <canvas ref={ref} />
      <div className="field-scrim" />
    </div>
  )
}
