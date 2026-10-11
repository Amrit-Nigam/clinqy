import { useLayoutEffect, useRef, useState } from 'react'

/** Scale factor that fits a fixed-size stage (w x h) into the element's width. */
export function useFitScale<T extends HTMLElement>(w: number) {
  const ref = useRef<T>(null)
  const [scale, setScale] = useState(1)
  useLayoutEffect(() => {
    const el = ref.current
    if (!el) return
    const ro = new ResizeObserver(() => setScale(el.clientWidth / w))
    ro.observe(el)
    return () => ro.disconnect()
  }, [w])
  return [ref, scale] as const
}
