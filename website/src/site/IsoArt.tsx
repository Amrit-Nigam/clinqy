import { ReactNode, useEffect, useId, useRef, useState } from 'react'
import { smooth, span } from '../shared/timeline'

/**
 * Small isometric scenes, one per idea: the loop every request runs, the gate before anything you can't
 * take back, and setup in one paste. Line art with blue hatching; Clinqy's triangle cursor does the work.
 * Each scene only animates while it's on screen, and holds still for reduced motion.
 */

const C = Math.cos(Math.PI / 6)
const S = 0.5
/** World (x right-down, y left-down, z up) to screen. */
const P = (x: number, y: number, z = 0): [number, number] => [(x - y) * C, (x + y) * S - z]
const pts = (...p: [number, number, number][]) => p.map(([x, y, z]) => P(x, y, z).join(',')).join(' ')

/** Scene progress 0..1, ~30 fps, only while visible. */
function usePhase(period: number) {
  const ref = useRef<SVGSVGElement>(null)
  const [phase, setPhase] = useState(0.62)
  useEffect(() => {
    const el = ref.current
    if (!el || matchMedia('(prefers-reduced-motion: reduce)').matches) return
    let raf = 0
    let last = 0
    let visible = false
    const t0 = performance.now()
    const tick = (now: number) => {
      if (!visible) return
      raf = requestAnimationFrame(tick)
      if (now - last < 32) return
      last = now
      setPhase(((now - t0) % period) / period)
    }
    const io = new IntersectionObserver(([e]) => {
      visible = e.isIntersecting
      cancelAnimationFrame(raf)
      if (visible) raf = requestAnimationFrame(tick)
    })
    io.observe(el)
    return () => {
      io.disconnect()
      cancelAnimationFrame(raf)
    }
  }, [period])
  return [ref, phase] as const
}

type Ids = { hatch: string; hatchRed: string; dots: string }

function Defs({ ids }: { ids: Ids }) {
  return (
    <defs>
      <pattern id={ids.hatch} width="4" height="4" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
        <line x1="0" y1="0" x2="0" y2="4" className="iso-hatch" />
      </pattern>
      <pattern id={ids.hatchRed} width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(-45)">
        <line x1="0" y1="0" x2="0" y2="6" className="iso-hatch-red" />
      </pattern>
      <pattern id={ids.dots} width="12" height="12" patternUnits="userSpaceOnUse">
        <circle cx="1" cy="1" r="0.9" className="iso-dot" />
      </pattern>
    </defs>
  )
}

function useIds(): Ids {
  const u = useId().replace(/:/g, '')
  return { hatch: `h${u}`, hatchRed: `r${u}`, dots: `d${u}` }
}

/**
 * A box: top, right (+x) and front (+y) faces, the three you can see. `top` and `front` draw on those faces
 * in flat coordinates (top: x across, y down the face; front: x across, y downward from the top edge).
 */
function Box(props: {
  x: number
  y: number
  z?: number
  w: number
  d: number
  h: number
  topFill?: string
  className?: string
  top?: ReactNode
  front?: ReactNode
}) {
  const { x, y, z = 0, w, d, h, topFill, className = '', top, front } = props
  const zt = z + h
  const [tx, ty] = P(x, y, zt)
  const [fx, fy] = P(x, y + d, zt)
  return (
    <g className={className}>
      <polygon points={pts([x + w, y, zt], [x + w, y + d, zt], [x + w, y + d, z], [x + w, y, z])} className="iso-side" />
      <polygon points={pts([x, y + d, zt], [x + w, y + d, zt], [x + w, y + d, z], [x, y + d, z])} className="iso-side iso-side-front" />
      <polygon points={pts([x, y, zt], [x + w, y, zt], [x + w, y + d, zt], [x, y + d, zt])} className="iso-face" style={topFill ? { fill: topFill } : undefined} />
      {top && <g transform={`matrix(${C} ${S} ${-C} ${S} ${tx} ${ty})`}>{top}</g>}
      {front && <g transform={`matrix(${C} ${S} 0 1 ${fx} ${fy})`}>{front}</g>}
    </g>
  )
}

/** Clinqy's triangle (Buddy.swift, no stem) with a name tag, in screen space. */
function Cursor({ at, name, color, press = 0, opacity = 1 }: { at: [number, number]; name: string; color: string; press?: number; opacity?: number }) {
  return (
    <g transform={`translate(${at[0]} ${at[1]}) scale(${1 - press * 0.14})`} style={{ opacity }}>
      <path d="M0 0 L0 19 L5.2 14.2 L13.6 14.2 Z" fill={color} stroke="#0b0c11" strokeWidth="1.2" strokeLinejoin="round" />
      <g transform="translate(10 18)">
        <rect width={name.length * 6.4 + 12} height="16" rx="3" fill={color} />
        <text x="6" y="11.5" className="iso-tag">
          {name}
        </text>
      </g>
    </g>
  )
}

function Ripple({ at, age }: { at: [number, number]; age: number }) {
  if (age <= 0 || age >= 1) return null
  return <ellipse cx={at[0]} cy={at[1]} rx={6 + age * 26} ry={(6 + age * 26) * 0.5} className="iso-ripple" style={{ opacity: 1 - age }} />
}

/** The steps a scene acts out, as one row under the drawing; the current one lights up. */
function Steps({ items, active }: { items: string[]; active: number }) {
  return (
    <ol className="iso-steps">
      {items.map((t, i) => (
        <li key={t} className={i === active ? 'is-active' : undefined}>
          <span>{String(i + 1).padStart(2, '0')}</span> {t}
        </li>
      ))}
    </ol>
  )
}

const lerp = (a: number, b: number, t: number) => a + (b - a) * t

/* ───────────────────────── 1. The loop ───────────────────────── */

export function HowArt() {
  const [ref, phase] = usePhase(10000)
  const ids = useIds()
  // Four stations on a square track; the request travels between them.
  const st = [
    [0, 0],
    [170, 0],
    [170, 170],
    [0, 170],
  ] as const
  const k = Math.floor(phase * 4)
  const local = phase * 4 - k
  const travel = smooth(span(local, 0, 0.35))
  const from = st[(k + 3) % 4]
  const to = st[k]
  const packet: [number, number, number] = [lerp(from[0], to[0], travel), lerp(from[1], to[1], travel), 58 + Math.sin(phase * 40) * 2]
  const dwell = span(local, 0.35, 1)
  const active = local > 0.35 ? k : -1

  // ASK: keys press twice.
  const keyPress = active === 0 ? Math.max(0, Math.sin(dwell * Math.PI * 4)) : 0
  // LOOK: a scan line sweeps the screen.
  const scan = active === 1 ? dwell : 0
  // ACT: the cursor comes down and presses.
  const actIn = active === 2 ? smooth(span(dwell, 0, 0.4)) : 0
  const pressAge = active === 2 ? span(dwell, 0.42, 0.7) : -1
  const btnPress = active === 2 && dwell > 0.4 && dwell < 0.55 ? 1 : 0
  // CHECK: the beacon lights.
  const lit = active === 3 ? smooth(span(dwell, 0, 0.25)) : 0

  const btnTop = P(170, 170, 28 - btnPress * 4)
  const cursorAt: [number, number] = [btnTop[0] + lerp(60, 0, actIn), btnTop[1] - lerp(70, 6, actIn)]

  return (
    <div className="iso-wrap">
    <svg ref={ref} className="iso" viewBox="50 24 460 300" role="img" aria-label="An isometric loop: ask, look, act, check. A request travels between four stations.">
      <Defs ids={ids} />
      <g transform="translate(280 110)">
        <polygon points={pts([0, 0, 0], [170, 0, 0], [170, 170, 0], [0, 170, 0])} className="iso-track" />

        {/* 01 ASK (back) */}
        <Box x={-32} y={-32} w={64} d={64} h={14} />
        <Box x={-24} y={-14} z={14} w={22} d={24} h={9 - keyPress * 5} top={<text x="5" y="16" className="iso-key">⌃</text>} topFill={keyPress > 0.2 ? '#1b2a4a' : undefined} />
        <Box x={4} y={-14} z={14} w={22} d={24} h={9 - keyPress * 5} top={<text x="5" y="16" className="iso-key">⌥</text>} topFill={keyPress > 0.2 ? '#1b2a4a' : undefined} />

        {/* 02 LOOK (right) */}
        <Box x={138} y={-32} w={64} d={64} h={14} />
        <Box
          x={142}
          y={-26}
          z={14}
          w={56}
          d={6}
          h={56}
          front={
            <>
              <rect x="4" y="4" width="48" height="48" className="iso-screen" />
              {[10, 20, 30, 40].map((v, i) => (
                <rect key={v} x="9" y={v} width={i % 2 ? 22 : 36} height="6" className="iso-line iso-dashed" />
              ))}
              {scan > 0 && <rect x="4" y="4" width="48" height={scan * 48} className="iso-scanned" />}
              {scan > 0 && <line x1="4" x2="52" y1={4 + scan * 48} y2={4 + scan * 48} className="iso-scan" />}
            </>
          }
        />

        {/* 04 CHECK (left) */}
        <Box x={-32} y={138} w={64} d={64} h={14} />
        <Box x={-12} y={158} z={14} w={24} d={24} h={38} topFill={lit ? `rgba(141, 255, 176, ${0.25 + lit * 0.6})` : undefined} top={lit > 0.5 ? <text x="6" y="17" className="iso-check">✓</text> : null} />

        {/* 03 ACT (front) */}
        <Box x={138} y={138} w={64} d={64} h={14} />
        <Box x={153} y={153} z={14} w={34} d={34} h={14 - btnPress * 4} topFill={`url(#${ids.hatch})`} />

        <Ripple at={P(170, 170, 28 - btnPress * 4)} age={pressAge} />

        {/* The request, riding between stations. */}
        <Box x={packet[0] - 7} y={packet[1] - 7} z={packet[2]} w={14} d={14} h={14} className="iso-packet" />

        {active === 2 && <Cursor at={cursorAt} name="Clinqy" color="#4a8cff" press={btnPress} opacity={actIn} />}
      </g>
    </svg>
    <Steps items={['ask', 'look', 'act', 'check']} active={active} />
    </div>
  )
}

/* ───────────────────────── 2. The gate ───────────────────────── */

export function SafetyArt() {
  const [ref, phase] = usePhase(10000)
  const ids = useIds()
  const LANE_Y = 40
  const LANE_D = 60
  const mid = LANE_Y + LANE_D / 2
  const GATE_X = 120
  // Timeline: drive up, stop, ask, you approve, the arm lifts, drive on, press Pay, reset.
  const drive1 = smooth(span(phase, 0.02, 0.18))
  const askIn = smooth(span(phase, 0.22, 0.28)) * (1 - smooth(span(phase, 0.5, 0.55)))
  const youIn = smooth(span(phase, 0.3, 0.44))
  const youClickAge = span(phase, 0.45, 0.52)
  const lift = smooth(span(phase, 0.52, 0.6)) * (1 - smooth(span(phase, 0.88, 0.96)))
  const drive2 = smooth(span(phase, 0.6, 0.72))
  const payPress = phase > 0.73 && phase < 0.78 ? 1 : 0
  const payAge = span(phase, 0.73, 0.82)
  const done = smooth(span(phase, 0.76, 0.8)) * (1 - smooth(span(phase, 0.9, 0.96)))
  const leave = 1 - smooth(span(phase, 0.9, 0.97))

  const cx = phase < 0.6 ? lerp(-60, GATE_X - 30, drive1) : lerp(GATE_X - 30, 250, drive2)
  const cz = phase < 0.6 ? 6 : lerp(6, 34, drive2)
  const cur = P(cx, mid, cz)
  const a = (lift * Math.PI) / 2.15
  const L = 112
  const post: [number, number, number] = [GATE_X, LANE_Y - 22, 42]
  const end: [number, number, number] = [post[0], post[1] + L * Math.cos(a), post[2] + L * Math.sin(a)]
  const p0 = P(...post)
  const p1 = P(...end)
  const card = P(GATE_X, LANE_Y - 22, 120)

  return (
    <div className="iso-wrap">
    <svg ref={ref} className="iso" viewBox="60 20 440 320" role="img" aria-label="Clinqy stops at a barrier before Pay, waits for your OK, then the barrier lifts and it clicks Pay">
      <Defs ids={ids} />
      <g transform="translate(250 120)">
        {/* The lane */}
        <polygon points={pts([-100, LANE_Y, 0], [230, LANE_Y, 0], [230, LANE_Y + LANE_D, 0], [-100, LANE_Y + LANE_D, 0])} className="iso-lane" />
        <polyline points={pts([-90, mid, 0], [225, mid, 0])} className="iso-lane-mid" />

        {/* Gate post (behind the lane) */}
        <Box x={GATE_X - 7} y={LANE_Y - 29} w={14} d={14} h={42} />

        {/* Pay pedestal */}
        <Box x={230} y={LANE_Y - 4} w={70} d={LANE_D + 8} h={22} front={<text x="8" y="15" className="iso-text iso-small">Pay ₹4,420</text>} />
        <Box x={248} y={mid - 18} z={22} w={36} d={36} h={12 - payPress * 4} topFill={`url(#${ids.hatch})`} />
        <Ripple at={P(266, mid, 34 - payPress * 4)} age={payAge} />
        {done > 0 && (
          <text x={P(300, mid, 70)[0] - 20} y={P(300, mid, 70)[1]} className="iso-done" style={{ opacity: done }}>
            ✓ paid, after your OK
          </text>
        )}

        {/* The arm: red and white, across the lane until you say OK */}
        <line x1={p0[0]} y1={p0[1]} x2={p1[0]} y2={p1[1]} className="iso-arm" />
        <line x1={p0[0]} y1={p0[1]} x2={p1[0]} y2={p1[1]} className="iso-arm-red" />

        <Cursor at={cur} name="Clinqy" color="#4a8cff" press={payPress} opacity={leave} />

        {/* The question */}
        {askIn > 0.01 && (
          <g transform={`translate(${card[0] - 166} ${card[1] - 34})`} style={{ opacity: askIn }}>
            <rect width="150" height="66" rx="9" className="iso-card" />
            <text x="12" y="22" className="iso-text">Pay ₹4,420?</text>
            <rect x="12" y="34" width="56" height="20" rx="4" className="iso-line" />
            <text x="20" y="48" className="iso-text iso-small">Not now</text>
            <rect x="76" y="34" width="62" height="20" rx="4" className={'iso-ok' + (youClickAge > 0 && youClickAge < 1 ? ' is-pressed' : '')} />
            <text x="96" y="48" className="iso-text iso-small iso-ok-text">Pay</text>
          </g>
        )}
        {askIn > 0.01 && (
          <Cursor
            at={[lerp(card[0] + 90, card[0] - 62, youIn), lerp(card[1] - 70, card[1] + 10, youIn)]}
            name="You"
            color="#e9ecf3"
            press={youClickAge > 0 && youClickAge < 0.5 ? 1 : 0}
            opacity={askIn}
          />
        )}
      </g>
    </svg>
    <Steps items={['Clinqy wants to pay', 'waits for your OK', 'then it clicks']} active={phase < 0.22 ? 0 : phase < 0.6 ? 1 : phase < 0.9 ? 2 : -1} />
    </div>
  )
}

/* ───────────────────────── 3. Setup: pieces snapping into place ───────────────────────── */

/** Icons drawn flat on a 64 x 64 tile top. */
const ICONS: Record<string, (ids: Ids, lit: boolean) => ReactNode> = {
  model: (ids) => (
    <>
      <rect x="18" y="18" width="28" height="28" rx="3" className="iso-line" fill={`url(#${ids.hatch})`} />
      {[24, 32, 40].map((v) => (
        <g key={v}>
          <line x1={v} y1="10" x2={v} y2="18" className="iso-line" />
          <line x1={v} y1="46" x2={v} y2="54" className="iso-line" />
          <line x1="10" y1={v} x2="18" y2={v} className="iso-line" />
          <line x1="46" y1={v} x2="54" y2={v} className="iso-line" />
        </g>
      ))}
    </>
  ),
  permissions: () => (
    <>
      <path d="M24 30 V24 a8 8 0 0 1 16 0 V30" className="iso-line" strokeWidth="2.2" />
      <rect x="18" y="30" width="28" height="20" rx="3" className="iso-line iso-bg" />
      <circle cx="32" cy="39" r="2.6" className="iso-fill" />
    </>
  ),
  extension: () => (
    <>
      <rect x="12" y="16" width="40" height="32" rx="3" className="iso-line iso-bg" />
      <line x1="12" y1="24" x2="52" y2="24" className="iso-line" />
      <circle cx="17" cy="20" r="1.4" className="iso-fill" />
      <circle cx="22" cy="20" r="1.4" className="iso-fill" />
      <rect x="20" y="30" width="24" height="10" rx="2" className="iso-line iso-dashed" />
    </>
  ),
  core: (_ids, lit) => <path d="M24 14 L24 44 L32.2 36.4 L45.4 36.4 Z" className={'iso-logo' + (lit ? '' : ' is-off')} />,
}

const SLOTS = [
  { id: 'model', x: 18, y: 18, at: 0.05 },
  { id: 'permissions', x: 118, y: 18, at: 0.22 },
  { id: 'extension', x: 18, y: 118, at: 0.39 },
] as const
const CORE = { x: 118, y: 118 }

export function SetupArt() {
  const [ref, phase] = usePhase(10000)
  const ids = useIds()
  const out = smooth(span(phase, 0.9, 0.98))
  const seat = (at: number) => span(phase, at, at + 0.12)
  /** Drop from above with a small settle at the end. */
  const dropZ = (at: number) => {
    const p = seat(at)
    if (p <= 0) return null
    const e = smooth(Math.min(1, p / 0.8))
    const bounce = p > 0.8 ? Math.sin(((p - 0.8) / 0.2) * Math.PI) * 4 : 0
    return 120 * (1 - e) + bounce + out * 120
  }
  const seated = (at: number) => seat(at) >= 1 && out < 0.5
  const coreLit = phase > 0.58 && out < 0.5
  const coreRise = smooth(span(phase, 0.58, 0.66)) * (1 - out)
  const pop = smooth(span(phase, 0.66, 0.72)) * (1 - out)
  const coreTop = P(CORE.x + 32, CORE.y + 32, 10 + 12 + coreRise * 8)
  const active = phase < 0.17 ? 0 : phase < 0.34 ? 1 : phase < 0.56 ? 2 : phase < 0.9 ? 3 : -1
  // Circuit traces from each slot to the core, in board coordinates.
  const traces: Record<string, string> = {
    model: 'M82 50 H100 V150 H118',
    permissions: 'M150 82 V118',
    extension: 'M50 182 V196 H150 V182',
  }

  return (
    <div className="iso-wrap">
      <svg ref={ref} className="iso" viewBox="80 0 380 360" role="img" aria-label="Setup: a model, permissions and the browser extension click into place, and Clinqy lights up">
        <Defs ids={ids} />
        <g transform="translate(270 150)">
          {/* The board */}
          <Box
            x={0}
            y={0}
            w={200}
            h={10}
            d={200}
            top={
              <>
                {SLOTS.map((sl) => (
                  <path key={sl.id} d={traces[sl.id]} className={'iso-trace' + (seated(sl.at) ? ' is-lit' : '')} />
                ))}
                {[...SLOTS, { id: 'core', x: CORE.x, y: CORE.y }].map((sl) => (
                  <rect key={sl.id} x={sl.x - 2} y={sl.y - 2} width="68" height="68" rx="4" className="iso-slot" />
                ))}
              </>
            }
          />

          {/* Tiles, back to front */}
          {SLOTS.map((sl) => {
            const z = dropZ(sl.at)
            if (z === null) return null
            return (
              <g key={sl.id} style={{ opacity: 1 - out }}>
                <Box x={sl.x} y={sl.y} z={10 + z} w={64} d={64} h={12} top={ICONS[sl.id](ids, true)} />
              </g>
            )
          })}
          <Box x={CORE.x} y={CORE.y} z={10 + coreRise * 8} w={64} d={64} h={12} topFill={coreLit ? '#122347' : undefined} top={ICONS.core(ids, coreLit)} />

          {pop > 0.01 && <Cursor at={[coreTop[0] + 4, coreTop[1] - 50 * pop]} name="ready" color="#4a8cff" opacity={pop} />}
        </g>
      </svg>
      <Steps items={['pick a model', 'allow access', 'add the extension', 'ready']} active={active} />
    </div>
  )
}
