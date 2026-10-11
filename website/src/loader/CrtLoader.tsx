import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { Grain } from './Grain'
import { CrtSound } from './sound'
import { SCENES, SceneStage, STAGE_W } from '../shared/Scenes'
import { span } from '../shared/timeline'
import { useClock } from '../shared/useLoop'
import { useFitScale } from '../shared/useFitScale'

const POWER = 700
const SCENE = 2200
const SCENES_END = POWER + SCENE * SCENES.length
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
  const [stageRef, scale] = useFitScale<HTMLDivElement>(STAGE_W)
  const tvRef = useRef<HTMLDivElement>(null)
  const screenRef = useRef<HTMLDivElement>(null)
  const sound = useRef(new CrtSound())
  const [soundOn, setSoundOn] = useState(false)
  const fired = useRef({ buzz: false, reveal: false, done: false })
  const [origin, setOrigin] = useState('50% 45%')

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

  // Zoom toward the centre of the glass, wherever the TV lands in the viewport.
  useLayoutEffect(() => {
    const tv = tvRef.current?.getBoundingClientRect()
    const sc = screenRef.current?.getBoundingClientRect()
    if (!tv || !sc) return
    setOrigin(`${sc.left + sc.width / 2 - tv.left}px ${sc.top + sc.height / 2 - tv.top}px`)
  }, [phase === 'buzz'])

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

  // Scene + progress
  const sceneIdx = Math.min(SCENES.length - 1, Math.max(0, Math.floor((t - POWER) / SCENE)))
  const sceneT = phase === 'scenes' ? span(t - POWER - sceneIdx * SCENE, 0, SCENE) : phase === 'power' ? 0 : 1
  const scene = SCENES[sceneIdx]
  const loadPct = Math.round(span(t, 0, SCENES_END) * 100)

  // Power-on: a bright line opens into the picture.
  const powerP = span(t, 120, POWER)
  const powerClip = phase === 'power' ? `inset(${(1 - powerP) * 49.6}% 0 ${(1 - powerP) * 49.6}% 0)` : 'none'

  // Buzz: jitter, rolling bars, then colour bars.
  const b = phase === 'buzz' ? span(t, SCENES_END, BUZZ_END) : phase === 'dive' ? 1 : 0
  const jitter = phase === 'buzz' ? Math.sin(t * 0.9) * 6 * (1 - b * 0.4) + (Math.random() - 0.5) * 8 : 0
  const showBars = phase === 'buzz' && b > 0.35
  const chroma = 1.3 + (phase === 'buzz' ? 3 + Math.random() * 4 : 0)

  // Scene transitions get a short channel-flip hiccup.
  const flip = phase === 'scenes' && sceneT < 0.04 && sceneIdx > 0

  // Dive: push into the glass.
  const d = phase === 'dive' ? span(t, BUZZ_END, BUZZ_END + 700) : 0
  const diveEase = d * d * d
  const fade = phase === 'dive' ? 1 - span(t, BUZZ_END + 300, LOADER_TOTAL - 150) : 1

  return (
    <div className="crt-room" style={{ opacity: fade }} aria-label="Clinqy intro" role="img">
      <svg width="0" height="0" style={{ position: 'absolute' }} aria-hidden="true">
        <filter id="crt-chroma" x="-5%" y="-5%" width="110%" height="110%">
          <feColorMatrix in="SourceGraphic" type="matrix" values="1 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 1 0" result="r" />
          <feOffset in="r" dx={chroma} dy="0" result="r2" />
          <feColorMatrix in="SourceGraphic" type="matrix" values="0 0 0 0 0  0 1 0 0 0  0 0 0 0 0  0 0 0 1 0" result="g" />
          <feColorMatrix in="SourceGraphic" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 1 0 0  0 0 0 1 0" result="b" />
          <feOffset in="b" dx={-chroma} dy="0" result="b2" />
          <feBlend in="r2" in2="g" mode="screen" result="rg" />
          <feBlend in="rg" in2="b2" mode="screen" />
        </filter>
      </svg>

      <div className="crt-glow" style={{ opacity: phase === 'power' ? powerP * 0.8 : 0.9 + (phase === 'buzz' ? Math.random() * 0.3 : 0) }} />

      <div
        ref={tvRef}
        className="crt-tv"
        style={{ transform: `scale(${1 + diveEase * 7})`, transformOrigin: origin }}
      >
        <div className="crt-brand">Clinqytron</div>
        <div className="crt-bezel">
          <div ref={screenRef} className={'crt-screen' + (phase === 'buzz' ? ' is-buzzing' : '')}>
            <div className="crt-picture" style={{ clipPath: powerClip, transform: `translateX(${jitter}px) skewX(${jitter * 0.15}deg)` }}>
              <div ref={stageRef} className="crt-stage-fit">
                <div className="crt-stage" style={{ transform: `scale(${scale})`, filter: 'url(#crt-chroma)' }}>
                  {phase !== 'power' && !showBars && <SceneStage scene={scene} t={sceneT} />}
                  {phase === 'power' && <div className="crt-powerline" style={{ opacity: 1 - powerP * 0.6 }} />}
                  {showBars && <ColorBars />}
                </div>
              </div>

              <div className="crt-osd crt-osd-tl">
                {showBars ? 'NO SIGNAL' : `CH 0${sceneIdx + 1}  ${scene.osd}`}
              </div>
              <div className="crt-osd crt-osd-tr">{phase === 'buzz' ? '◼ STOP' : '▶ PLAY'}</div>
              <div className="crt-osd crt-osd-bl">
                LOADING CLINQY <span className="crt-bar">{'█'.repeat(Math.round(loadPct / 10)).padEnd(10, '░')}</span> {loadPct}%
              </div>
              {phase === 'buzz' && <div className="crt-roll" style={{ top: `${((t * 0.25) % 140) - 20}%` }} />}
            </div>

            <div className="crt-scanlines" />
            <div className="crt-grille" />
            <Grain amount={phase === 'buzz' ? 0.8 + Math.random() * 0.2 : flip ? 0.9 : 0.12} className="crt-grain" />
            <div className="crt-flicker" />
            <div className="crt-glass" />
            {(flip || d > 0) && <div className="crt-white" style={{ opacity: flip ? 0.5 : d * 0.9 }} />}
          </div>
        </div>
        <div className="crt-panel">
          <span className="crt-led" data-on={phase !== 'power' || powerP > 0.2} />
          <span className="crt-grillelines" />
          <button type="button" className="crt-knob" onClick={toggleSound} aria-pressed={soundOn} aria-label={soundOn ? 'Turn sound off' : 'Turn sound on'}>
            <i />
          </button>
          <button type="button" className="crt-knob" onClick={skip} aria-label="Change channel (skip intro)">
            <i style={{ transform: `rotate(${sceneIdx * 45}deg)` }} />
          </button>
        </div>
      </div>

      <div className="crt-controls" style={{ opacity: phase === 'scenes' || phase === 'power' ? 1 : 0 }}>
        <button type="button" onClick={toggleSound}>{soundOn ? 'Sound on' : 'Sound off'}</button>
        <button type="button" onClick={skip}>Skip intro</button>
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
