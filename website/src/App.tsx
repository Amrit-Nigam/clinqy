import { useCallback, useEffect, useRef, useState } from 'react'
import { CrtLoader } from './loader/CrtLoader'
import { Site } from './site/Site'

type Stage = 'intro' | 'reveal' | 'live'

const calm = () => matchMedia('(prefers-reduced-motion: reduce)').matches

export default function App() {
  const [stage, setStage] = useState<Stage>(() => (calm() ? 'live' : 'intro'))
  const [run, setRun] = useState(0)
  const shell = useRef<HTMLDivElement>(null)

  useEffect(() => {
    document.documentElement.style.overflow = stage === 'live' ? '' : 'hidden'
    // Keep the page out of tab order and screen readers until the intro hands over.
    if (stage === 'intro') shell.current?.setAttribute('inert', '')
    else shell.current?.removeAttribute('inert')
  }, [stage])

  const onReveal = useCallback(() => setStage('reveal'), [])
  const onDone = useCallback(() => setStage('live'), [])

  function replay() {
    window.scrollTo(0, 0)
    setRun((r) => r + 1)
    setStage('intro')
  }

  return (
    <>
      <div ref={shell} className={'site-shell stage-' + stage}>
        <Site live={stage === 'live'} onReplay={replay} />
      </div>
      {stage !== 'live' && <CrtLoader key={run} onReveal={onReveal} onDone={onDone} />}
    </>
  )
}
