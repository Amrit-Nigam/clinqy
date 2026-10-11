import { useEffect, useState } from 'react'

const REQUESTS = [
  'book me a flight to Mumbai',
  'where’s the brightness setting?',
  'tick Keynote and Design panel',
  'message mom I’ll be late',
  'what’s the phone number on my resume?',
  'in the background, add a reminder to call Raj',
]

/** A replica of the ⌃⌥ command bar, typing real example requests. */
export function CommandBar({ running }: { running: boolean }) {
  const [i, setI] = useState(0)
  const [n, setN] = useState(0)

  useEffect(() => {
    if (!running) return
    const text = REQUESTS[i]
    const id = setTimeout(
      () => {
        if (n < text.length + 26) setN(n + 1) // type, then hold for a beat
        else {
          setN(0)
          setI((i + 1) % REQUESTS.length)
        }
      },
      n < text.length ? 38 + Math.random() * 50 : 60,
    )
    return () => clearTimeout(id)
  }, [i, n, running])

  const text = REQUESTS[i]
  const shown = text.slice(0, n)
  const working = n > text.length + 6
  return (
    <div className="cmdbar" aria-label={`Example request: ${text}`}>
      <div className="cmdbar-input">
        <kbd>clinqy&gt;</kbd>
        <span>{shown}</span>
        {!working && <span className="cmdbar-caret" />}
      </div>
      <div className="cmdbar-status" data-working={working}>
        {working ? 'Working on it. Your pointer stays yours.' : 'Type or hold to talk'}
      </div>
    </div>
  )
}
