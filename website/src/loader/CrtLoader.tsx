import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { Grain } from './Grain'
import { CrtSound } from './sound'
import { barrelMap } from './barrel'
import { CursorArrow } from '../shared/Cursor'
import { SCENES, SceneStage } from '../shared/Scenes'
import { clamp, easeOutExpo, smooth, span } from '../shared/timeline'
import { useClock } from '../shared/useLoop'

/** Size of an element, kept current. */
function useSize<T extends HTMLElement>() {
  const ref = useRef<T>(null)
  const [size, setSize] = useState({ w: 0, h: 0 })
  useLayoutEffect(() => {
    const el = ref.current
    if (!el) return
    const ro = new ResizeObserver(() => setSize({ w: el.clientWidth, h: el.clientHeight }))
    ro.observe(el)
    return () => ro.disconnect()
  }, [])
  return [ref, size] as const
}

const byId = Object.fromEntries(SCENES.map((s) => [s.id, s]))

/**
 * One long desk of windows, left to right. x/y are window centres in world
 * px; d is depth (1 = in focus, lower sits further back and drifts slower).
 */
const DESK = [
  { id: 'shot', x: 0, y: -120, d: 1 },
  { id: 'aws', x: 560, y: 230, d: 0.9 },
  { id: 'msg', x: 1060, y: -200, d: 1.04 },
  { id: 'job', x: 1580, y: 200, d: 0.93 },
  { id: 'cal', x: 2080, y: -170, d: 0.86 },
  { id: 'edit', x: 2580, y: 190, d: 1.03 },
  { id: 'files', x: 3080, y: -110, d: 0.9 },
]

const POWER = 700
const TAKE = 9000
const TAKE_END = POWER + TAKE
const OUTRO = 1700
const OFF_START = TAKE_END + OUTRO
const OFF = 900
export const LOADER_TOTAL = OFF_START + OFF + 300
const SCENE_LEN = 5200
const CAM_FROM = 180
const CAM_TO = 2900

/** Camera x along the desk: one unhurried move that eases in and out. */
const camXAt = (T: number) => CAM_FROM + (CAM_TO - CAM_FROM) * smooth(span(T, POWER - 300, TAKE_END + 600))

type Props = { onReveal: () => void; onDone: () => void }

export function CrtLoader({ onReveal, onDone }: Props) {
  const [skipAt, setSkipAt] = useState<number | null>(null)
  const ms = useClock(true)
  // Skipping goes to the outro, so the sign-off and switch-off still play.
  const T = skipAt !== null ? Math.max(ms, TAKE_END + (ms - skipAt)) : ms
  const [picRef, pic] = useSize<HTMLDivElement>()
  const map = useState(barrelMap)[0]
  const sound = useRef(new CrtSound())
  const [soundOn, setSoundOn] = useState(false)
  const fired = useRef({ opened: new Set<string>(), off: false, reveal: false, done: false })

  const W = pic.w || 1
  const H = pic.h || 1
  // A window fills about a third of the width, so two or three share the frame.
  const zBase = Math.min((W * 0.34) / 560, (H * 0.44) / 400)
  const zAt = (t: number) => zBase * (1.04 - 0.08 * smooth(span(t, POWER, TAKE_END)))

  // Each window opens as the camera brings it to the right third of the frame.
  const openAt = useMemo(() => {
    const out: Record<string, number> = {}
    for (const w of DESK) {
      let t = 0
      for (; t < TAKE_END; t += 16) {
        const x = W / 2 + (w.x - camXAt(t)) * zAt(t) * w.d
        if (x < W * 0.78) break
      }
      out[w.id] = Math.max(POWER + 150, t)
    }
    return out
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [W, H])

  const phase = T < POWER ? 'power' : T < TAKE_END ? 'take' : T < OFF_START ? 'outro' : 'off'

  useEffect(() => {
    DESK.forEach((w) => {
      if (T >= openAt[w.id] && !fired.current.opened.has(w.id)) {
        fired.current.opened.add(w.id)
        sound.current.click()
      }
    })
    if (phase === 'off' && !fired.current.off) {
      fired.current.off = true
      sound.current.thunk()
    }
    if (T >= OFF_START + OFF && !fired.current.reveal) {
      fired.current.reveal = true
      onReveal()
    }
    if (T >= LOADER_TOTAL && !fired.current.done) {
      fired.current.done = true
      sound.current.stop()
      onDone()
    }
  }, [phase, T, openAt, onReveal, onDone])

  useEffect(() => () => sound.current.stop(), [])

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape' || e.key === 'Enter') skip()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  })

  function skip() {
    if (skipAt === null && ms < TAKE_END) setSkipAt(ms)
  }

  function toggleSound() {
    if (sound.current.on) sound.current.stop()
    else sound.current.start()
    setSoundOn(sound.current.on)
  }

  // ── Camera ──
  const camX = camXAt(T)
  const camY = Math.sin(T / 2600) * 18
  const z = zAt(T)

  // ── Outro and switch-off ──
  const outro = smooth(span(T, TAKE_END, TAKE_END + 900))
  const mark = smooth(span(T, TAKE_END + 300, TAKE_END + 1100))
  const offY = span(T, OFF_START, OFF_START + 380)
  const offX = span(T, OFF_START + 380, OFF_START + 620)
  const dot = phase === 'off' ? 1 - span(T, OFF_START + 620, OFF_START + OFF) : 0
  const powerP = smooth(span(T, 100, POWER))
  const picTransform =
    phase === 'power'
      ? `scaleY(${0.004 + powerP * 0.996})`
      : phase === 'off'
        ? `scale(${1 - smooth(offX) * 0.996}, ${1 - smooth(offY) * 0.996})`
        : undefined
  const picBright = phase === 'power' ? 3 - powerP * 2 : phase === 'off' ? 1 + offY * 2.5 : 1
  const bulge = Math.min(W, H) * 0.12

  // ── Caption: the newest window, in plain words ──
  const newest = [...DESK].reverse().find((w) => T >= openAt[w.id])
  const captionText = phase === 'take' && newest ? `Clinqy is ${byId[newest.id].doing}` : ''
  const captionShown = newest ? captionText.slice(0, Math.round(captionText.length * span(T, openAt[newest.id], openAt[newest.id] + 900))) : ''

  const windows = DESK.map((w) => {
    const open = easeOutExpo(span(T, openAt[w.id], openAt[w.id] + 700))
    const s = z * w.d * (0.92 + 0.08 * open)
    const cx = W / 2 + (w.x - camX) * z * w.d
    const cy = H / 2 + (w.y - camY) * z * w.d + (1 - open) * 10
    const sceneT = clamp((T - openAt[w.id] - 250) / SCENE_LEN)
    // Further back: softer and a little darker, like a shallow depth of field.
    const depth = Math.max(0, 1 - w.d)
    return { w, open, s, cx, cy, sceneT, blur: depth * 9, dim: 1 - depth * 1.6 }
  }).sort((a, b) => a.w.d - b.w.d)

  return (
    <div className="crt-room" aria-label="Clinqy intro" role="img">
      <svg width="0" height="0" style={{ position: 'absolute' }} aria-hidden="true">
        <defs>
          <clipPath id="crt-glass-shape" clipPathUnits="objectBoundingBox">
            <path d="M0.03 0.012 Q0.5 0 0.97 0.012 Q0.994 0.016 0.99 0.05 Q1 0.5 0.99 0.95 Q0.994 0.984 0.97 0.988 Q0.5 1 0.03 0.988 Q0.006 0.984 0.01 0.95 Q0 0.5 0.01 0.05 Q0.006 0.016 0.03 0.012 Z" />
          </clipPath>
        </defs>
        {/* Slight red/blue misregistration, like the guns of a real tube. */}
        <filter id="crt-fringe" x="-2%" y="-2%" width="104%" height="104%">
          <feColorMatrix in="SourceGraphic" type="matrix" values="1 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 1 0" result="r" />
          <feOffset in="r" dx="1" result="r2" />
          <feColorMatrix in="SourceGraphic" type="matrix" values="0 0 0 0 0  0 1 0 0 0  0 0 0 0 0  0 0 0 1 0" result="g" />
          <feColorMatrix in="SourceGraphic" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 1 0 0  0 0 0 1 0" result="b" />
          <feOffset in="b" dx="-1" result="b2" />
          <feBlend in="r2" in2="g" mode="screen" result="rg" />
          <feBlend in="rg" in2="b2" mode="screen" />
        </filter>
        {pic.w > 0 && (
          <filter id="crt-barrel" filterUnits="userSpaceOnUse" primitiveUnits="userSpaceOnUse" x="0" y="0" width={W} height={H} colorInterpolationFilters="sRGB">
            <feImage href={map} x="0" y="0" width={W} height={H} preserveAspectRatio="none" result="map" />
            <feDisplacementMap in="SourceGraphic" in2="map" scale={bulge} xChannelSelector="R" yChannelSelector="G" />
          </filter>
        )}
      </svg>

      <div className="crt-screen">
        <div
          className="crt-picture"
          ref={picRef}
          style={{
            transform: picTransform,
            filter: `${pic.w ? 'url(#crt-barrel) ' : ''}brightness(${picBright})`,
            opacity: phase === 'off' && offX >= 1 ? 0 : 1,
          }}
        >
          <div className="crt-grid" style={{ transform: `translate(${(-camX * z * 0.25) % 36}px, ${(-camY * z * 0.25) % 36}px)` }} />
          {pic.w > 0 && (
            <div className="crt-windows" style={{ opacity: 1 - outro * 0.72 }}>
              {windows.map(({ w, open, s, cx, cy, sceneT, blur, dim }) =>
                open <= 0 ? null : (
                  <div
                    key={w.id}
                    className="crt-win"
                    style={{
                      transform: `translate(${cx - 320}px, ${cy - 240}px) scale(${s})`,
                      opacity: open,
                      filter: blur > 0.3 ? `blur(${blur.toFixed(1)}px) brightness(${dim.toFixed(2)})` : undefined,
                    }}
                  >
                    <SceneStage scene={byId[w.id]} t={sceneT} bare />
                  </div>
                ),
              )}
            </div>
          )}

          {mark > 0 && (
            <div className="crt-mark" style={{ opacity: mark, transform: `translate(-50%, -50%) scale(${0.98 + mark * 0.02})` }}>
              <CursorArrow size={Math.min(W, H) * 0.07} />
              <span>clinqy</span>
            </div>
          )}

          {captionShown && (
            <div className="crt-caption">
              {captionShown}
              <span className="crt-caret">▍</span>
            </div>
          )}
        </div>

        {dot > 0 && <div className="crt-dot" style={{ opacity: dot, transform: `translate(-50%, -50%) scale(${0.6 + dot * 0.4})` }} />}
        <div className="crt-scanlines" />
        <Grain amount={0.07} className="crt-grain" />
        <div className="crt-flicker" />
        <div className="crt-glass" />
      </div>

      <div className="crt-controls" style={{ opacity: phase === 'take' || phase === 'power' ? 1 : 0 }}>
        <button type="button" onClick={toggleSound} aria-pressed={soundOn}>
          {soundOn ? 'Sound on' : 'Sound off'}
        </button>
        <button type="button" onClick={skip}>
          Skip
        </button>
      </div>
    </div>
  )
}
