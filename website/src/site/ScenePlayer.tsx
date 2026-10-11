import { useEffect, useRef, useState } from 'react'
import { SCENES, SceneStage, STAGE_W } from '../shared/Scenes'
import { useFitScale } from '../shared/useFitScale'
import { useClock } from '../shared/useLoop'

const LOOP = 4600

/** The same scenes from the intro, minus the CRT. */
export function ScenePlayer() {
  const [idx, setIdx] = useState(0)
  const [picked, setPicked] = useState(false)
  const [visible, setVisible] = useState(false)
  const wrap = useRef<HTMLDivElement>(null)
  const [fitRef, scale] = useFitScale<HTMLDivElement>(STAGE_W)
  const ms = useClock(visible, idx)
  const t = Math.min(1, (ms % (LOOP + 900)) / LOOP)

  useEffect(() => {
    const el = wrap.current
    if (!el) return
    const io = new IntersectionObserver(([e]) => setVisible(e.isIntersecting), { threshold: 0.25 })
    io.observe(el)
    return () => io.disconnect()
  }, [])

  // Until someone picks a tab, walk through all four.
  useEffect(() => {
    if (!picked && ms > LOOP + 900) setIdx((i) => (i + 1) % SCENES.length)
  }, [ms, picked])

  const scene = SCENES[idx]
  return (
    <div className="player" ref={wrap}>
      <div className="player-tabs" role="tablist" aria-label="Example tasks">
        {SCENES.map((s, i) => (
          <button
            key={s.id}
            role="tab"
            type="button"
            aria-selected={i === idx}
            onClick={() => {
              setIdx(i)
              setPicked(true)
            }}
          >
            {s.label}
          </button>
        ))}
      </div>
      <div className="player-screen" ref={fitRef} style={{ height: 480 * scale }}>
        <div style={{ transform: `scale(${scale})`, transformOrigin: '0 0' }}>
          <SceneStage scene={scene} t={t} />
        </div>
      </div>
      <p className="player-caption">“{scene.request}”</p>
    </div>
  )
}
