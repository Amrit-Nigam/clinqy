import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { SCENES, SceneStage, STAGE_W } from '../shared/Scenes'

const COLS = 4
const ROWS = 4
const LOOP = 5200
// Spread scenes and start times so no two neighbours are on the same step.
const TILES = Array.from({ length: COLS * ROWS }, (_, i) => ({
  scene: SCENES[(i * 3 + Math.floor(i / COLS)) % SCENES.length],
  offset: ((i * 7) % 11) / 11,
  speed: 0.85 + ((i * 5) % 7) * 0.05,
}))

/**
 * A tilted wall of Macs behind the page, each with Clinqy busy on a
 * different task. One shared clock at ~30 fps drives all of them.
 */
export function ScreenWall({ running }: { running: boolean }) {
  const grid = useRef<HTMLDivElement>(null)
  const wall = useRef<HTMLDivElement>(null)
  const [tileW, setTileW] = useState(0)
  const [ms, setMs] = useState(0)

  useLayoutEffect(() => {
    const el = grid.current
    if (!el) return
    const ro = new ResizeObserver(() => {
      const gap = parseFloat(getComputedStyle(el).columnGap) || 0
      setTileW((el.clientWidth - gap * (COLS - 1)) / COLS)
    })
    ro.observe(el)
    return () => ro.disconnect()
  }, [])

  useEffect(() => {
    if (!running || matchMedia('(prefers-reduced-motion: reduce)').matches) return
    let raf = 0
    let last = 0
    const start = performance.now()
    const tick = (now: number) => {
      raf = requestAnimationFrame(tick)
      if (now - last < 33) return
      last = now
      setMs(now - start)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [running])

  // Gentle parallax: the wall drifts slower than the page.
  useEffect(() => {
    const onScroll = () => {
      if (wall.current) wall.current.style.translate = `0 ${-scrollY * 0.05}px`
      // Past the hero, veil the wall more so long-form text stays easy to read.
      document.documentElement.style.setProperty('--veil', String(Math.min(1, scrollY / (innerHeight * 0.7))))
    }
    onScroll()
    addEventListener('scroll', onScroll, { passive: true })
    return () => removeEventListener('scroll', onScroll)
  }, [])

  const scale = tileW / STAGE_W
  return (
    <div className="wall" aria-hidden="true">
      <div className="wall-tilt" ref={wall}>
        <div className="wall-grid" ref={grid}>
          {TILES.map((tile, i) => {
            const t = ((ms * tile.speed) / LOOP + tile.offset) % 1
            return (
              <div key={i} className="wall-tile" style={{ height: 480 * scale }}>
                {tileW > 0 && (
                  <div style={{ transform: `scale(${scale})`, transformOrigin: '0 0' }}>
                    <SceneStage scene={tile.scene} t={Math.min(1, t * 1.12)} />
                  </div>
                )}
              </div>
            )
          })}
        </div>
      </div>
      <div className="wall-scrim" />
    </div>
  )
}
