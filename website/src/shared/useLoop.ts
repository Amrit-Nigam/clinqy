import { useEffect, useRef, useState } from 'react'

/** Elapsed ms since mount (or since `key` changed), updated every frame while `running`. */
export function useClock(running: boolean, key: unknown = 0) {
  const [ms, setMs] = useState(0)
  const start = useRef<number | null>(null)
  useEffect(() => {
    start.current = null
    setMs(0)
  }, [key])
  useEffect(() => {
    if (!running) return
    let raf = 0
    const tick = (now: number) => {
      if (start.current === null) start.current = now - ms
      setMs(now - start.current)
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => {
      cancelAnimationFrame(raf)
      start.current = null
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [running, key])
  return ms
}
