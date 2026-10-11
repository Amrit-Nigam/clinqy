import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { Grain } from './Grain'
import { CrtSound } from './sound'
import { barrelMap } from './barrel'
import { MenuBar, SCENES, SceneStage, STAGE_W } from '../shared/Scenes'
import { easeOut, span } from '../shared/timeline'
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
 * The jumble: windows pile onto the tube one after another, overlapping,
 * each with its own Clinqy cursor mid-task. x/y are fractions of the glass,
 * w is the window width relative to the glass.
 */
const PILE = [
  { id: 'shot', x: 0.04, y: 0.1, w: 0.4, r: -3, speed: 1 },
  { id: 'edit', x: 0.58, y: 0.06, w: 0.38, r: 2.5, speed: 0.9 },
  { id: 'job', x: 0.03, y: 0.5, w: 0.38, r: 2, speed: 1.1 },
  { id: 'msg', x: 0.6, y: 0.52, w: 0.36, r: -2, speed: 0.95 },
  { id: 'files', x: 0.4, y: 0.02, w: 0.28, r: 4, speed: 1.05 },
  { id: 'cal', x: 0.38, y: 0.6, w: 0.3, r: -1, speed: 0.92 },
  { id: 'aws', x: 0.28, y: 0.24, w: 0.44, r: 0.5, speed: 1 },
]

const POWER = 700
const SPAWN_GAP = 520
const LOOP = 4300
const JUMBLE = 8200
const SCENES_END = POWER + JUMBLE
const BUZZ = 1500
const BUZZ_END = SCENES_END + BUZZ
const DIVE = 1100
export const LOADER_TOTAL = BUZZ_END + DIVE

type Props = { onReveal: () => void; onDone: () => void }

export function CrtLoader({ onReveal, onDone }: Props) {
  const [skipAt, setSkipAt] = useState<number | null>(null)
  const ms = useClock(true)
  // Skipping jumps straight to the buzz, so the exit still plays.
  const t = skipAt !== null ? Math.max(ms, SCENES_END + (ms - skipAt)) : ms
  const [picRef, pic] = useSize<HTMLDivElement>()
  const map = useState(barrelMap)[0]
  const sound = useRef(new CrtSound())
  const [soundOn, setSoundOn] = useState(false)
  const fired = useRef({ buzz: false, reveal: false, done: false })

  const phase = t < POWER ? 'power' : t < SCENES_END ? 'scenes' : t < BUZZ_END ? 'buzz' : 'dive'

  useEffect(() => {
    if (phase === 'buzz' && !fired.current.buzz) {
      fired.current.buzz = true
      sound.current.buzz(1.3)
    }
    if (phase === 'dive' && !fired.current.reveal && t > BUZZ_END + 350) {
      fired.current.reveal = true
      sound.current.thunk()
      onReveal()
    }
    if (t >= LOADER_TOTAL && !fired.current.done) {
      fired.current.done = true
      sound.current.stop()
      onDone()
    }
  }, [phase, t, onReveal, onDone])

  useEffect(() => () => sound.current.stop(), [])

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape' || e.key === 'Enter') skip()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  })

  function skip() {
    if (skipAt === null && ms < SCENES_END) setSkipAt(ms)
  }

  function toggleSound() {
    if (sound.current.on) sound.current.stop()
    else sound.current.start()
    setSoundOn(sound.current.on)
  }

  const loadPct = Math.round(span(t, 0, SCENES_END) * 100)
  const spawned = PILE.filter((_, i) => t >= POWER + 200 + i * SPAWN_GAP).length
  // Once they're all up, a different window keeps jumping to the front.
  const allUp = POWER + 200 + PILE.length * SPAWN_GAP
  const focus = t > allUp ? Math.floor((t - allUp) / 1100) % PILE.length : -1
  const front = focus >= 0 ? PILE[focus] : PILE[Math.max(0, spawned - 1)]

  // Power-on: a bright line opens into the picture.
  const powerP = span(t, 120, POWER)
  const powerClip = phase === 'power' ? `inset(${(1 - powerP) * 49.6}% 0 ${(1 - powerP) * 49.6}% 0)` : 'none'

  // Buzz: jitter, rolling bars, then colour bars.
  const jitter = phase === 'buzz' ? Math.sin(t * 0.9) * 6 + (Math.random() - 0.5) * 9 : 0
  const showBars = phase === 'buzz' && span(t, SCENES_END, BUZZ_END) > 0.35

  // Dive: push into the glass.
  const d = phase === 'dive' ? span(t, BUZZ_END, BUZZ_END + 700) : 0
  const diveEase = d * d * d
  const fade = phase === 'dive' ? 1 - span(t, BUZZ_END + 300, LOADER_TOTAL - 150) : 1

  // How hard the glass bends, in px at the corners. More while it buzzes.
  const bulge = Math.min(pic.w, pic.h) * (phase === 'buzz' ? 0.17 + Math.random() * 0.04 : 0.14)
  // Window size is set by the shorter side so phones still get a pile, not specks.
  const base = Math.min(pic.w, pic.h * 1.45)

  return (
    <div className="crt-room" style={{ opacity: fade }} aria-label="Clinqy intro" role="img">
      <svg width="0" height="0" style={{ position: 'absolute' }} aria-hidden="true">
        <defs>
          <clipPath id="crt-glass-shape" clipPathUnits="objectBoundingBox">
            {/* Rounded rectangle whose sides bow outward: the tube's face. */}
            <path d="M0.055 0.022 Q0.5 0 0.945 0.022 Q0.988 0.03 0.982 0.085 Q1 0.5 0.982 0.915 Q0.988 0.97 0.945 0.978 Q0.5 1 0.055 0.978 Q0.012 0.97 0.018 0.915 Q0 0.5 0.018 0.085 Q0.012 0.03 0.055 0.022 Z" />
          </clipPath>
        </defs>
        {pic.w > 0 && (
          <filter id="crt-barrel" filterUnits="userSpaceOnUse" primitiveUnits="userSpaceOnUse" x="0" y="0" width={pic.w} height={pic.h} colorInterpolationFilters="sRGB">
            <feImage href={map} x="0" y="0" width={pic.w} height={pic.h} preserveAspectRatio="none" result="map" />
            <feDisplacementMap in="SourceGraphic" in2="map" scale={bulge} xChannelSelector="R" yChannelSelector="G" />
          </filter>
        )}
      </svg>

      <div className="crt-tv" style={{ transform: `scale(${1 + diveEase * 1.6})` }}>
        <div className="crt-bezel">
          <div className={'crt-screen' + (phase === 'buzz' ? ' is-buzzing' : '')}>
            <div className="crt-picture" ref={picRef} style={{ clipPath: powerClip, filter: pic.w ? 'url(#crt-barrel)' : undefined }}>
              <div className="crt-signal" style={{ transform: `translateX(${jitter}px) skewX(${jitter * 0.15}deg)` }}>
                {phase !== 'power' && !showBars && pic.w > 0 && (
                  <>
                    <div className="crt-wall" />
                    <div className="crt-menubar" style={{ width: pic.w / (base / 900), transform: `scale(${base / 900})` }}>
                      <MenuBar app={byId[front.id].app} />
                    </div>
                    {PILE.map((p, i) => {
                      const born = POWER + 200 + i * SPAWN_GAP
                      if (t < born) return null
                      const pop = easeOut(span(t, born, born + 260))
                      const sceneT = (((t - born) * p.speed) / LOOP) % 1
                      const isFront = p === front
                      const s = ((p.w * base) / STAGE_W) * (0.86 + pop * 0.14) * (isFront ? 1.32 : 1)
                      const drift = Math.sin(t / 1700 + i * 1.7) * 6
                      // Centre each 640x480 stage on its slot.
                      const cx = p.x * pic.w + (p.w * base) / 2
                      const cy = p.y * pic.h + (p.w * base * 0.75) / 2
                      return (
                        <div
                          key={p.id}
                          className="crt-tile"
                          style={{
                            transform: `translate(${cx - 320 + drift}px, ${cy - 240 - drift * 0.6}px) scale(${s}) rotate(${p.r}deg)`,
                            opacity: pop,
                            zIndex: isFront ? 50 : i,
                            // Dark-mode windows glow like phosphor; the ones behind sit dimmer.
                            filter: `invert(0.9) hue-rotate(180deg) brightness(${isFront ? 1.25 : 0.7})`,
                          }}
                        >
                          <SceneStage scene={byId[p.id]} t={sceneT} bare />
                        </div>
                      )
                    })}
                    <div className="crt-beam" />
                  </>
                )}
                {phase === 'power' && <div className="crt-powerline" style={{ opacity: 1 - powerP * 0.6 }} />}
                {showBars && <ColorBars />}

                <div className="crt-osd crt-osd-tl">
                  {showBars ? 'NO SIGNAL' : `CH 03  ${spawned} TASK${spawned === 1 ? '' : 'S'} RUNNING`}
                </div>
                <div className="crt-osd crt-osd-tr">{phase === 'buzz' ? '◼ STOP' : '▶ PLAY'}</div>
                <div className="crt-osd crt-osd-bl">
                  LOADING CLINQY <span className="crt-bar">{'█'.repeat(Math.round(loadPct / 10)).padEnd(10, '░')}</span> {loadPct}%
                </div>
              </div>
              {phase === 'buzz' && <div className="crt-roll" style={{ top: `${((t * 0.25) % 140) - 20}%` }} />}
            </div>

            <Grain amount={phase === 'buzz' ? 0.8 + Math.random() * 0.2 : 0.1} className="crt-grain" />
            <div className="crt-flicker" />
            <div className="crt-glass" />
            {d > 0 && <div className="crt-white" style={{ opacity: d * 0.9 }} />}
          </div>
        </div>

        <div className="crt-chin">
          <span className="crt-brand">Clinqytron</span>
          <div className="crt-controls" style={{ opacity: phase === 'scenes' || phase === 'power' ? 1 : 0 }}>
            <button type="button" onClick={toggleSound} aria-pressed={soundOn}>
              {soundOn ? 'Sound on' : 'Sound off'}
            </button>
            <button type="button" onClick={skip}>Skip intro</button>
            <span className="crt-led" data-on={phase !== 'power' || powerP > 0.2} />
          </div>
        </div>
      </div>
    </div>
  )
}

function ColorBars() {
  const top = ['#c0c0c0', '#c0c000', '#00c0c0', '#00c000', '#c000c0', '#c00000', '#0000c0']
  const mid = ['#0000c0', '#131313', '#c000c0', '#131313', '#00c0c0', '#131313', '#c0c0c0']
  return (
    <div className="crt-bars">
      <div className="crt-bars-top">{top.map((c) => <i key={c} style={{ background: c }} />)}</div>
      <div className="crt-bars-mid">{mid.map((c, i) => <i key={i} style={{ background: c }} />)}</div>
      <div className="crt-bars-low">
        <i style={{ background: '#00214c', flex: 1.25 }} />
        <i style={{ background: '#fff', flex: 1.25 }} />
        <i style={{ background: '#32006a', flex: 1.25 }} />
        <i style={{ background: '#131313', flex: 3.25 }} />
      </div>
      <div className="crt-bars-label">CLINQY</div>
    </div>
  )
}
