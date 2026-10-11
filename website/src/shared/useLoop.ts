import { useEffect, useRef, useState } from 'react'

/**
 * Elapsed ms since mount (or since `key` changed), updated while `running`.
 * `fps` caps how often React re-renders; 30 is plenty for UI playback.
 */
export function useClock(running: boolean, key: unknown = 0, fps = 60) {
  const [ms, setMs] = useState(0)
  const start = useRef<number | null>(null)
  const latest = useRef(0)
  useEffect(() => {
    start.current = null
    latest.current = 0
    setMs(0)
  }, [key])
  useEffect(() => {
    if (!running) return
    let raf = 0
    let last = 0
    const gap = 1000 / fps - 2
    const tick = (now: number) => {
      raf = requestAnimationFrame(tick)
      if (start.current === null) start.current = now - latest.current
      if (now - last < gap) return
      last = now
      latest.current = now - start.current
      setMs(latest.current)
    }
    raf = requestAnimationFrame(tick)
    return () => {
      cancelAnimationFrame(raf)
      start.current = null
    }
  }, [running, key, fps])
  return ms
}
