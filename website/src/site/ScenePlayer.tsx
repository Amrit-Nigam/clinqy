import { useEffect, useRef, useState } from 'react'
import { SCENES, SceneStage } from '../shared/Scenes'
import { useFitScale } from '../shared/useFitScale'
import { useClock } from '../shared/useLoop'

const LOOP = 5200
const HOLD = 1200

/**
 * One stage: the request in large type on the left, the window doing it on
 * the right, and an index of every request along the bottom.
 */
export function ScenePlayer() {
  const [idx, setIdx] = useState(0)
  const [picked, setPicked] = useState(false)
  const [visible, setVisible] = useState(false)
  const wrap = useRef<HTMLDivElement>(null)
  // Crop to the window itself (560 x 400 at 40, 40 in the stage).
  const [fitRef, scale] = useFitScale<HTMLDivElement>(560)
  const ms = useClock(visible, idx, 30)
  const t = Math.min(1, (ms % (LOOP + HOLD)) / LOOP)

  useEffect(() => {
    const el = wrap.current
    if (!el) return
    const io = new IntersectionObserver(([e]) => setVisible(e.isIntersecting), { threshold: 0.2 })
    io.observe(el)
    return () => io.disconnect()
  }, [])

  // Until someone picks one, walk through them all.
  useEffect(() => {
    if (!picked && ms > LOOP + HOLD) setIdx((i) => (i + 1) % SCENES.length)
  }, [ms, picked])

  const scene = SCENES[idx]
  const typedN = Math.round(scene.request.length * Math.min(1, ms / 900))
  return (
    <div className="stage" ref={wrap}>
      <div className="stage-body">
        <div className="stage-copy">
          <p className="stage-app">{scene.app}</p>
          <p className="stage-quote" aria-live="polite">
            <span className="stage-quote-sizer" aria-hidden="true">“{scene.request}”</span>
            <span className="stage-quote-live">
              “{scene.request.slice(0, typedN)}
              {typedN >= scene.request.length ? '”' : <span className="caret">▍</span>}
            </span>
          </p>
          <p className="stage-doing">Clinqy is {scene.doing}.</p>
        </div>
        <div className="stage-screen" ref={fitRef} style={{ height: 400 * scale }}>
          <div style={{ transform: `scale(${scale}) translate(-40px, -40px)`, transformOrigin: '0 0' }}>
            <SceneStage scene={scene} t={t} bare showRequest={false} />
          </div>
        </div>
      </div>
      <div className="stage-index" role="tablist" aria-label="Example requests">
        {SCENES.map((s, i) => (
          <button
            key={s.id}
            role="tab"
            type="button"
            aria-selected={i === idx}
            aria-label={s.request}
            onClick={() => {
              setIdx(i)
              setPicked(true)
            }}
            data-buddy
          >
            <span className="stage-num">{String(i + 1).padStart(2, '0')}</span>
            <span className="stage-name">{s.label}</span>
            <i className="stage-bar" style={{ transform: `scaleX(${i === idx ? t : i < idx && !picked ? 1 : 0})` }} />
          </button>
        ))}
      </div>
    </div>
  )
}
