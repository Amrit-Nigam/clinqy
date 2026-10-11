import { useEffect, useRef, useState } from 'react'
import { SCENES, SceneStage, STAGE_W } from '../shared/Scenes'
import { useFitScale } from '../shared/useFitScale'
import { useClock } from '../shared/useLoop'

const PLAY = 5200
const HOLD = 1400

/** The hero: the intro's windows, now crisp, with Clinqy working through them. */
export function LiveDesk({ running }: { running: boolean }) {
  const wrap = useRef<HTMLDivElement>(null)
  const [visible, setVisible] = useState(true)
  const [fitRef, scale] = useFitScale<HTMLDivElement>(STAGE_W)
  const ms = useClock(running && visible, 0, 30)
  const round = Math.floor(ms / (PLAY + HOLD))
  const scene = SCENES[round % SCENES.length]
  const local = ms - round * (PLAY + HOLD)
  const t = Math.min(1, local / PLAY)
  const fade = Math.min(1, local / 300, (PLAY + HOLD - local) / 300)

  useEffect(() => {
    const el = wrap.current
    if (!el) return
    const io = new IntersectionObserver(([e]) => setVisible(e.isIntersecting))
    io.observe(el)
    return () => io.disconnect()
  }, [])

  const caption = `Clinqy is ${scene.doing}`
  const typed = caption.slice(0, Math.round(caption.length * Math.min(1, local / 900)))
  return (
    <figure className="desk" ref={wrap}>
      <div className="desk-screen" ref={fitRef} style={{ height: 480 * scale }}>
        <div style={{ transform: `scale(${scale})`, transformOrigin: '0 0', opacity: fade }}>
          <SceneStage scene={scene} t={t} />
        </div>
      </div>
      <figcaption className="desk-caption" aria-live="off">
        {typed}
        <span className="caret">▍</span>
      </figcaption>
    </figure>
  )
}
