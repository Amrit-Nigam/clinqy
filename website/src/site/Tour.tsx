import { useEffect, useRef, useState } from 'react'
import { CursorArrow } from '../shared/Cursor'
import { smooth } from '../shared/timeline'
import { paint, streak, Trail } from '../shared/streak'

/**
 * A guided tour where Clinqy drives the page the way the real app drives a
 * Mac: it flies to things, frames them, circles them, clicks for real, asks
 * before anything that leaves a trace, and stops the moment you take over.
 */

type Step = {
  /** Element to go to (CSS selector). Omit to float mid-screen. */
  target?: string
  /** What to bring into view, if bigger than the target (defaults to the target). */
  view?: string
  /** Where on the element the tip lands, as fractions of its box. */
  at?: [number, number]
  say: string
  /** frame: dashed box. circle: hand-drawn ring. click: really click it. ask: wait for OK, then click. */
  do?: 'frame' | 'circle' | 'click' | 'ask'
  /** Extra time to look after the caption is typed. */
  dwell?: number
  /** Put the card under the target (when the space beside it holds text). */
  below?: boolean
  /** Buttons for an ask step. */
  ask?: [string, string]
}

const STEPS: Step[] = [
  {
    target: '[data-tour="hello"]',
    at: [0.62, 0.45],
    say: 'Hi, I’m Clinqy. On your Mac I move to things, look, click and type, just like you. Let me show you this page the same way.',
    do: 'frame',
    dwell: 700,
  },
  {
    target: '[data-tour="keys"]',
    at: [0.5, 0.6],
    say: 'This is how you call me: tap Control + Option, then type or talk.',
    do: 'circle',
    dwell: 600,
  },
  {
    target: '[data-tour="desk"]',
    view: '.hero',
    at: [0.3, 0.35],
    say: 'Here I’m doing real tasks. Every click gets checked: if nothing changed, I try another way.',
    do: 'frame',
    dwell: 1600,
  },
  {
    target: '.trace li:nth-child(3) .trace-log',
    view: '.how',
    below: true,
    at: [0.2, 0.5],
    say: 'Every request runs this loop: look, act, then check that it worked.',
    do: 'frame',
    dwell: 900,
  },
  {
    target: '.stage-index button:nth-child(3)',
    view: '.stage',
    at: [0.4, 0.55],
    say: 'Pick any request and I’ll play it. Here’s me launching a server on AWS.',
    do: 'click',
    dwell: 3200,
  },
  {
    target: '.stage-index button:nth-child(5)',
    view: '.stage',
    at: [0.4, 0.55],
    say: 'And telling your mom you’ll be late.',
    do: 'click',
    dwell: 2600,
  },
  {
    target: '[data-tour="voice"] q',
    at: [0.25, 0.5],
    say: 'Talk to me in English, Hindi or Hinglish. Replies keep your style.',
    do: 'circle',
    dwell: 700,
  },
  {
    target: '[data-tour="alert"]',
    view: '.safety',
    at: [0.55, 0.45],
    say: 'Anything you can’t take back, like paying or sending, waits for your OK.',
    do: 'frame',
    dwell: 700,
  },
  {
    target: '[data-tour="copy"]',
    view: '.term',
    at: [0.5, 0.55],
    say: 'Want the setup prompt? I’ll copy it to your clipboard, but only if you say so.',
    do: 'ask',
    ask: ['Not now', 'Copy it'],
  },
  {
    target: '[data-tour="finale-cta"]',
    view: '[data-tour="finale"]',
    at: [0.5, 0.6],
    say: 'That’s the tour. Paste the prompt into your coding agent and I’ll be on your Mac in a few minutes.',
    dwell: 1800,
  },
]

class Stopped extends Error {}

/** Space kept clear at the top (nav) and bottom (the tour bar). */
const TOP = 76
const BOTTOM = 84
const CARD_W = 340

/**
 * Put the card next to the target, never over it: right, left, below, then
 * above, whichever fits first. Height is estimated from the text (14px mono).
 */
function placeCard(r: DOMRect | null, cur: { x: number; y: number }, text: string, ask: boolean, below = false): [number, number] {
  const W = Math.min(CARD_W, innerWidth - 32)
  const perLine = Math.max(10, Math.floor((W - 32) / 8.45))
  const H = Math.ceil(text.length / perLine) * 22 + 30 + (ask ? 46 : 0)
  const minY = TOP + 8
  const maxY = innerHeight - BOTTOM - H
  const clampY = (y: number) => Math.max(minY, Math.min(maxY, y))
  const clampX = (x: number) => Math.max(16, Math.min(innerWidth - W - 16, x))
  if (!r) return [clampX(cur.x + 28), clampY(cur.y + 24)]
  const gap = 18
  const y = clampY(Math.max(r.top, cur.y - 20))
  if (below && r.bottom + gap + H <= innerHeight - BOTTOM) return [clampX(r.left), r.bottom + gap]
  if (r.right + gap + W <= innerWidth - 16) return [r.right + gap, y]
  if (r.left - gap - W >= 16) return [r.left - gap - W, y]
  if (r.bottom + gap + H <= innerHeight - BOTTOM) return [clampX(cur.x - 40), r.bottom + gap]
  if (r.top - gap - H >= minY) return [clampX(cur.x - 40), r.top - gap - H]
  // Nothing outside fits (a big target): tuck it into the target's lower corner.
  return [clampX(r.right - W - 12), clampY(r.bottom - H - 12)]
}

type Caption = { text: string; x: number; y: number; ask?: [string, string] }
type Circle = { x: number; y: number; w: number; h: number; key: number }

export function Tour({ running, onEnd }: { running: boolean; onEnd: (how: 'done' | 'stopped' | 'taken') => void }) {
  const cursor = useRef<HTMLDivElement>(null)
  const tail = useRef<SVGPathElement>(null)
  const frame = useRef<HTMLDivElement>(null)
  const pos = useRef({ x: innerWidth * 0.82, y: innerHeight * 0.9 })
  const alive = useRef(false)
  const answer = useRef<((yes: boolean) => void) | null>(null)
  const [caption, setCaption] = useState<Caption | null>(null)
  const [circle, setCircle] = useState<Circle | null>(null)
  const [ripples, setRipples] = useState<{ x: number; y: number; key: number }[]>([])
  const [stepNo, setStepNo] = useState(0)
  const endRef = useRef(onEnd)
  endRef.current = onEnd

  useEffect(() => {
    if (!running) return
    alive.current = true
    const calm = matchMedia('(prefers-reduced-motion: reduce)').matches

    const check = () => {
      if (!alive.current) throw new Stopped()
    }
    const sleep = (ms: number) =>
      new Promise<void>((res, rej) => {
        const id = setTimeout(() => (alive.current ? res() : rej(new Stopped())), ms)
        if (!alive.current) {
          clearTimeout(id)
          rej(new Stopped())
        }
      })
    const frameLoop = (dur: number, fn: (p: number) => void) =>
      new Promise<void>((res, rej) => {
        if (calm || dur <= 0) {
          fn(1)
          return res()
        }
        const t0 = performance.now()
        const tick = (now: number) => {
          if (!alive.current) return rej(new Stopped())
          const p = Math.min(1, (now - t0) / dur)
          fn(p)
          if (p < 1) requestAnimationFrame(tick)
          else res()
        }
        requestAnimationFrame(tick)
      })

    const trail = new Trail()
    const place = (flying = false) => {
      const el = cursor.current
      if (el) el.style.transform = `translate(${pos.current.x}px, ${pos.current.y}px)`
      paint(tail.current, flying ? streak(trail.push(pos.current)) : null)
    }
    place()

    /** Bring the view into frame: its top just under the nav, or centred on the target if it's too tall. */
    const scrollTo = async (view: Element, target: Element, roomBelow = 0) => {
      const r = view.getBoundingClientRect()
      const t = target.getBoundingClientRect()
      const max = document.documentElement.scrollHeight - innerHeight
      const room = innerHeight - TOP - BOTTOM
      // Too tall to fit: show its top, as long as the target stays on screen.
      const want = r.height <= room ? r.top - TOP - (room - r.height) / 2 : Math.max(r.top - TOP, t.bottom + 24 - (innerHeight - BOTTOM))
      // Leave space under the target for a card that goes below it.
      const need = roomBelow ? t.bottom + roomBelow - (innerHeight - BOTTOM) : -Infinity
      const goal = Math.max(0, Math.min(max, scrollY + Math.max(want, need)))
      const from = scrollY
      const dist = goal - from
      if (Math.abs(dist) < 30) return
      const dur = Math.min(1500, 500 + Math.abs(dist) * 0.35)
      await frameLoop(dur, (p) => window.scrollTo({ top: from + dist * smooth(p), behavior: 'instant' as ScrollBehavior }))
    }

    /** Fly in an arc, the way the companion cursor does. */
    const flyTo = async (x: number, y: number) => {
      const fx = pos.current.x
      const fy = pos.current.y
      const dx = x - fx
      const dy = y - fy
      const len = Math.hypot(dx, dy) || 1
      const dur = Math.min(1100, 380 + len * 0.6)
      await frameLoop(dur, (p) => {
        const e = smooth(p)
        const arc = Math.sin(e * Math.PI) * Math.min(90, len * 0.2)
        pos.current = { x: fx + dx * e + (-dy / len) * arc, y: fy + dy * e + (dx / len) * arc }
        place(p < 1)
      })
      trail.clear()
      place()
    }

    const showFrame = (r: DOMRect | null) => {
      const el = frame.current
      if (!el) return
      if (!r) {
        el.style.opacity = '0'
        return
      }
      el.style.opacity = '1'
      el.style.transform = `translate(${r.left - 8}px, ${r.top - 8}px)`
      el.style.width = `${r.width + 16}px`
      el.style.height = `${r.height + 16}px`
    }

    let box: DOMRect | null = null
    let below = false
    const say = async (text: string, ask?: [string, string]) => {
      const [cx, cy] = placeCard(box, pos.current, text, !!ask, below)
      if (calm) {
        setCaption({ text, x: cx, y: cy, ask })
        return
      }
      for (let n = 0; n <= text.length; n += 2) {
        check()
        setCaption({ text: text.slice(0, n), x: cx, y: cy })
        await sleep(16)
      }
      setCaption({ text, x: cx, y: cy, ask })
    }

    const click = async () => {
      const key = performance.now()
      setRipples((r) => [...r, { x: pos.current.x, y: pos.current.y, key }])
      setTimeout(() => setRipples((r) => r.filter((q) => q.key !== key)), 700)
      cursor.current?.classList.add('is-down')
      await sleep(140)
      cursor.current?.classList.remove('is-down')
    }

    const run = async () => {
      try {
        await sleep(250)
        for (let i = 0; i < STEPS.length; i++) {
          const s = STEPS[i]
          setStepNo(i + 1)
          setCaption(null)
          showFrame(null)
          setCircle(null)
          const el = s.target ? document.querySelector(s.target) : null
          const view = s.view ? document.querySelector(s.view) : el
          if (el && view) await scrollTo(view, el, s.below ? 140 : 0)
          check()
          const r = el?.getBoundingClientRect()
          const [ax, ay] = s.at ?? [0.5, 0.5]
          const tx = r ? r.left + r.width * ax : innerWidth / 2
          const ty = r ? r.top + r.height * ay : innerHeight / 2
          await flyTo(tx, ty)
          await sleep(120)
          const r2 = el?.getBoundingClientRect() ?? null
          box = r2
          below = !!s.below
          if (s.do === 'frame' && r2) showFrame(r2)
          if (s.do === 'circle' && r2) setCircle({ x: r2.left, y: r2.top, w: r2.width, h: r2.height, key: i })
          if (s.do === 'click' && el) {
            showFrame(r2)
            await sleep(220)
            await click()
            ;(el as HTMLElement).click()
          }
          await say(s.say, s.ask)
          if (s.do === 'ask' && el && r2) {
            showFrame(r2)
            const yes = await new Promise<boolean>((res) => (answer.current = res))
            answer.current = null
            check()
            if (yes) {
              await click()
              ;(el as HTMLElement).click()
              await say('Copied. It’s on your clipboard.')
              await sleep(1200)
            }
          } else {
            await sleep(900 + (s.dwell ?? 0))
          }
        }
        alive.current = false
        endRef.current('done')
      } catch (e) {
        if (!(e instanceof Stopped)) throw e
      }
    }
    run()

    // You can always take over: Esc, or scrolling yourself.
    const stopWith = (how: 'stopped' | 'taken') => {
      if (!alive.current) return
      alive.current = false
      answer.current?.(false)
      endRef.current(how)
    }
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') stopWith('stopped')
      else if (['ArrowDown', 'ArrowUp', 'PageDown', 'PageUp', ' ', 'Home', 'End'].includes(e.key)) stopWith('taken')
    }
    const onWheel = () => stopWith('taken')
    addEventListener('keydown', onKey)
    addEventListener('wheel', onWheel, { passive: true })
    addEventListener('touchmove', onWheel, { passive: true })
    return () => {
      alive.current = false
      removeEventListener('keydown', onKey)
      removeEventListener('wheel', onWheel)
      removeEventListener('touchmove', onWheel)
    }
  }, [running])

  if (!running) return null
  return (
    <div className="tour" aria-live="polite">
      <div className="tour-bar" role="status">
        <img src="/icon.png" alt="" width={18} height={18} />
        <span>
          <span className="tour-bar-long">Clinqy is showing you around</span>
          <span className="tour-bar-short">Tour</span> <small>{stepNo}/{STEPS.length}</small>
        </span>
        <button type="button" onClick={() => {
          alive.current = false
          answer.current?.(false)
          onEnd('stopped')
        }}>
          <i /> Stop
        </button>
      </div>

      <div ref={frame} className="tour-frame" aria-hidden="true" />
      {circle && (
        <svg
          key={circle.key}
          className="tour-circle"
          style={{ left: circle.x - 14, top: circle.y - 12, width: circle.w + 28, height: circle.h + 24 }}
          viewBox="0 0 100 100"
          preserveAspectRatio="none"
          aria-hidden="true"
        >
          {/* Slightly lopsided and overlapping at the end, like a quick pen stroke. */}
          <path d="M 52 4 C 82 3, 98 22, 97 50 C 96 80, 74 97, 48 96 C 20 95, 3 78, 4 49 C 5 22, 24 6, 58 8" pathLength={1} />
        </svg>
      )}
      {ripples.map((r) => (
        <i key={r.key} className="tour-ripple" style={{ left: r.x, top: r.y }} aria-hidden="true" />
      ))}
      <svg className="streak-layer" aria-hidden="true">
        <path ref={tail} />
      </svg>
      <div ref={cursor} className="tour-cursor" aria-hidden="true">
        <CursorArrow size={26} />
      </div>
      {caption && (
        <div className="tour-card" style={{ left: caption.x, top: caption.y }}>
          <p>{caption.text}</p>
          {caption.ask && (
            <div className="tour-ask">
              <button type="button" onClick={() => answer.current?.(false)}>{caption.ask[0]}</button>
              <button type="button" className="is-yes" onClick={() => answer.current?.(true)} autoFocus>
                {caption.ask[1]}
              </button>
            </div>
          )}
        </div>
      )}
    </div>
  )
}

/** The offer, shown once the page switches on: Clinqy's own command bar. */
export function TourOffer({ onYes, onNo }: { onYes: () => void; onNo: () => void }) {
  return (
    <div className="offer" role="dialog" aria-labelledby="offer-title">
      <img src="/icon.png" alt="" width={34} height={34} />
      <div className="offer-text">
        <b id="offer-title">Want me to show you around?</b>
        <span>About a minute. I move my own cursor, so yours stays free.</span>
      </div>
      <div className="offer-actions">
        <button type="button" className="btn btn-quiet" onClick={onNo}>
          I’ll look myself
        </button>
        <button type="button" className="btn btn-primary" onClick={onYes} autoFocus>
          Show me around
        </button>
      </div>
    </div>
  )
}
