import { useEffect, useState } from 'react'
import { BuddyCursor } from './BuddyCursor'
import { LiveDesk } from './LiveDesk'
import { ScenePlayer } from './ScenePlayer'
import { AsciiField } from './AsciiField'
import { ARROW, AsciiFinale } from './AsciiFinale'
import { Scramble } from './Scramble'
import { HowArt, SafetyArt, SetupArt } from './IsoArt'
import { AgentSection, QaSection } from './AgentSections'
import { SETUP_PROMPT } from './setupPrompt'
import { Tour, TourOffer } from './Tour'

const GITHUB = 'https://github.com/Amrit-Nigam/clinqy'

/** Real requests from the README, for the strip under the hero. */
const ASKS = [
  'book me a flight to Mumbai',
  'where’s the brightness setting?',
  'tick Keynote and Design panel',
  'message mom I’ll be late',
  'what’s the phone number on my resume?',
  'in the background, add a reminder to call Raj',
  'schedule a call with Priya Thursday afternoon',
  'sort my Downloads into folders',
  'the PDF I got from HR last week',
]

/** One request, followed through each step of the loop. */
const TRACE = [
  {
    step: 'You ask',
    body: 'Tap ⌃⌥ and type, or hold it and talk. Whatever you’ve highlighted goes along, so “reply to this” just works.',
    log: '⌃⌥  “message mom I’ll be late”',
  },
  {
    step: 'It looks',
    body: 'It reads the screen the way assistive tech does: buttons, fields and lists by name, plus text recognition when an app hides them.',
    log: 'WhatsApp  →  4 chats  →  found “Mom”',
  },
  {
    step: 'It acts, then checks',
    body: 'The blue cursor flies to the target and clicks or types for real. If nothing changed, it tries another way.',
    log: 'click “Mom”  →  type message  →  text appeared ✓',
  },
  {
    step: 'It asks when it matters',
    body: 'Sending to someone counts, so it shows you the message first. Details, choices, Pay and Delete work the same way.',
    log: 'Send “I’ll be late” to Mom?  [ Send ]',
  },
]

/** Each capability, introduced by something you might actually say. */
const CAN = [
  {
    say: 'tick Keynote and Design panel',
    title: 'Clicks that check themselves',
    body: 'After every click it looks for an effect. Nothing changed? It tries a real mouse click, then a click through the page, then focus plus a key, and remembers what works on each site.',
  },
  {
    say: 'what’s the phone number on my resume?',
    title: 'Sees the whole Mac',
    body: 'Native apps through Accessibility, web pages through a browser extension, PDFs and scans through on-device text recognition, scriptable apps through AppleScript.',
  },
  {
    say: 'mummy ko bolo main late hoon',
    title: 'Talk to it, in your words',
    body: 'Hold ⌃⌥ and speak. Whisper turns it into text on your Mac. English, Hindi and Hinglish all work, and replies keep your style.',
  },
  {
    say: 'message mom I’ll be late',
    title: 'Remembers who’s who',
    body: 'It keeps lasting facts after each task: people, preferences, your usual apps. It never saves passwords, card numbers or OTPs.',
  },
  {
    say: 'do the weekly report like I showed you',
    title: 'Learns by watching',
    body: 'Click Watch & learn, do a task once yourself, and it becomes a skill with blanks to fill in next time.',
  },
  {
    say: 'check how localhost:5173 looks in my browser',
    title: 'Works with your coding agent',
    body: 'Add Clinqy as an MCP server to Claude Code, Cursor, Codex or Gemini CLI, and they can see how your page really renders, logged in, in your own browser.',
  },
]

const MODELS: [string, string][] = [
  ['claude cli', 'your Claude login'],
  ['codex cli', 'your ChatGPT login'],
  ['gemini cli', 'your Google login'],
  ['anthropic api key', 'or openai, gemini, openrouter'],
  ['ollama qwen3-vl', 'any local vision model'],
]

function Rule() {
  return (
    <div className="rule" aria-hidden="true">
      {'─'.repeat(400)}
    </div>
  )
}

export function Site({ live, onReplay }: { live: boolean; onReplay: () => void }) {
  const [copied, setCopied] = useState(false)
  const [tour, setTour] = useState<'offer' | 'on' | 'off' | null>(null)
  const [toast, setToast] = useState('')

  // The nav hides once you scroll down, and comes back when the pointer nears the top (or you scroll back up).
  const [navHidden, setNavHidden] = useState(false)
  useEffect(() => {
    let lastY = scrollY
    let nearTop = false
    const onScroll = () => {
      const y = scrollY
      if (y < 80) setNavHidden(false)
      else if (y > lastY + 4 && !nearTop) setNavHidden(true)
      else if (y < lastY - 30) setNavHidden(false)
      lastY = y
    }
    const onMove = (e: PointerEvent) => {
      nearTop = e.clientY < 72
      if (nearTop) setNavHidden(false)
      else if (scrollY > 80 && e.clientY > 140) setNavHidden(true)
    }
    addEventListener('scroll', onScroll, { passive: true })
    addEventListener('pointermove', onMove, { passive: true })
    return () => {
      removeEventListener('scroll', onScroll)
      removeEventListener('pointermove', onMove)
    }
  }, [])

  // Offer the tour a moment after the page switches on.
  useEffect(() => {
    if (!live) {
      setTour(null)
      return
    }
    const id = setTimeout(() => setTour((t) => t ?? 'offer'), 700)
    return () => clearTimeout(id)
  }, [live])

  function endTour(how: 'done' | 'stopped' | 'taken') {
    setTour('off')
    if (how !== 'done') {
      setToast(how === 'taken' ? 'Stopped. You’re in control.' : 'Stopped.')
      setTimeout(() => setToast(''), 2400)
    }
  }

  async function copyPrompt() {
    try {
      await navigator.clipboard.writeText(SETUP_PROMPT)
      setCopied(true)
      setTimeout(() => setCopied(false), 2200)
    } catch {
      document.getElementById('setup')?.scrollIntoView({ behavior: 'smooth' })
    }
  }

  const copyLabel = copied ? 'Copied. Paste it into your agent' : 'Copy the setup prompt'

  return (
    <div className="site">
      <AsciiField running={live} />
      <BuddyCursor enabled={live && tour !== 'on'} />
      {tour === 'offer' && <TourOffer onYes={() => setTour('on')} onNo={() => setTour('off')} />}
      <Tour running={tour === 'on'} onEnd={endTour} />
      {toast && <div className="tour-toast" role="status">{toast}</div>}

      <header className={'nav' + (navHidden && tour !== 'on' ? ' is-hidden' : '')} onFocus={() => setNavHidden(false)}>
        <a className="nav-logo" href="#top" data-buddy>
          <img src="/icon.png" alt="" width={26} height={26} />
          clinqy
        </a>
        <nav aria-label="Sections">
          <a href="#how">How it works</a>
          <a href="#watch">Watch it</a>
          <a href="#agents">For agents</a>
          <a href="#safety">Safety</a>
          <a href="#setup">Set up</a>
          <button type="button" className="linklike nav-tour" onClick={() => setTour('on')} disabled={tour === 'on'}>
            Show me around
          </button>
        </nav>
        <a className="btn btn-quiet" href={GITHUB} target="_blank" rel="noreferrer" data-buddy>
          GitHub
        </a>
      </header>

      <main id="top">
        <section className="hero">
          <div className="hero-copy">
            <pre className="hero-mark" aria-hidden="true">
              {ARROW.join('\n')}
            </pre>
            <div data-tour="hello">
              <Scramble as="h1" text={'Your Mac,\non autopilot.'} start={live} />
            </div>
            <p className="hero-sub">And you can watch it work.</p>
            <p className="lede">
              Press <kbd data-tour="keys">⌃⌥</kbd> and say what you want. A small blue cursor goes and does it on screen. It clicks the Dock, types
              into the address bar, ticks the boxes and fills the form, then hands your pointer back.
            </p>
            <div className="hero-ctas">
              <button type="button" className="btn btn-primary" onClick={copyPrompt} data-buddy>
                {copyLabel}
              </button>
              <a className="btn btn-quiet" href={GITHUB} target="_blank" rel="noreferrer" data-buddy>
                View on GitHub
              </a>
            </div>
            <p className="fineprint">Free and open source. macOS 14+ on Apple silicon.</p>
          </div>
          <div data-tour="desk">
            <LiveDesk running={live} />
          </div>
        </section>

        <div className="asks" aria-label="Things you can ask">
          <div className="asks-track">
            {[...ASKS, ...ASKS].map((a, i) => (
              <span key={i} aria-hidden={i >= ASKS.length}>
                “{a}”
              </span>
            ))}
          </div>
        </div>

        <section className="how" id="how" aria-labelledby="how-title">
          <div className="section-head has-art">
            <div>
              <Scramble as="h2" id="how-title" text="One request, start to finish" />
              <p>Every task runs the same loop. Here it is for one message, layer by layer.</p>
            </div>
            <div className="art">
              <HowArt />
            </div>
          </div>
          <ol className="trace">
            {TRACE.map((r) => (
              <li key={r.step}>
                <h3>{r.step}</h3>
                <p>{r.body}</p>
                <code className="trace-log">{r.log}</code>
              </li>
            ))}
          </ol>
        </section>

        <Rule />
        <QaSection />

        <Rule />
        <AgentSection />

        <Rule />
        <section className="watch" id="watch">
          <div className="section-head">
            <Scramble as="h2" text="It uses your Mac the way you would" />
            <p>
              No hidden APIs and no headless browser. It opens apps from the Dock, types at a human rhythm and clicks
              for real. Pick a request.
            </p>
          </div>
          <ScenePlayer />
        </section>

        <Rule />
        <section className="can" id="features">
          <Scramble as="h2" text="Say it like you’d say it" />
          <ul className="can-list">
            {CAN.map((c) => (
              <li key={c.title} data-tour={c.say.startsWith('mummy') ? 'voice' : undefined}>
                <q className="can-say">{c.say}</q>
                <div>
                  <h3>{c.title}</h3>
                  <p>{c.body}</p>
                </div>
              </li>
            ))}
          </ul>
        </section>

        <section className="safety" id="safety">
          <div className="safety-copy">
            <Scramble as="h2" text="It asks before anything you can’t take back" />
            <ul>
              <li>Pay, Buy, Book, Send, Submit and Delete wait for your OK, unless you asked for exactly that.</li>
              <li>On a call? It checks with you before acting.</li>
              <li>One click in the menu bar stops any task. A watchdog stops anything stuck for 30 seconds.</li>
              <li>Renames and moves can be undone. Deleting only moves to the Trash.</li>
            </ul>
          </div>
          <div className="art art-safety" data-tour="alert">
            <SafetyArt />
          </div>
        </section>

        <section className="setup" id="setup">
          <div className="section-head has-art">
            <div>
              <Scramble as="h2" text="Set up in one paste" />
              <p>Your coding agent does the setup. It builds Clinqy, installs it, and only stops when it needs you.</p>
            </div>
            <div className="art">
              <SetupArt />
            </div>
          </div>
          <div className="setup-grid">
            <ol className="steps">
              <li>
                <h3>Fill in two lines</h3>
                <p>
                  <code>Model:</code> is what drives Clinqy. <code>Connect to:</code> lists the coding agents that can
                  use it.
                </p>
                <dl className="models">
                  {MODELS.map(([k, v]) => (
                    <div key={k}>
                      <dt>{k}</dt>
                      <dd>{v}</dd>
                    </div>
                  ))}
                </dl>
              </li>
              <li>
                <h3>Paste it into your agent</h3>
                <p>Claude Code, Cursor, Codex, Gemini CLI or Windsurf.</p>
              </li>
              <li>
                <h3>Allow access, press ⌃⌥</h3>
                <p>Accessibility, Screen Recording, Microphone and Speech Recognition. Then ask it something.</p>
              </li>
            </ol>
            <div className="term">
              <div className="term-bar">
                <i />
                <i />
                <i />
                <span>setup prompt</span>
                <button type="button" className="btn btn-primary btn-small" onClick={copyPrompt} data-buddy data-tour="copy">
                  {copied ? 'Copied' : 'Copy'}
                </button>
              </div>
              <pre tabIndex={0}>{SETUP_PROMPT}</pre>
            </div>
          </div>
        </section>

        <section className="finale" aria-labelledby="finale-title" data-tour="finale">
          <AsciiFinale />
          <p id="finale-title" className="finale-line">Press ⌃⌥. Say it. Watch it happen.</p>
          <div className="hero-ctas" data-tour="finale-cta">
            <button type="button" className="btn btn-primary" onClick={copyPrompt} data-buddy>
              {copyLabel}
            </button>
            <a className="btn btn-quiet" href={GITHUB} target="_blank" rel="noreferrer" data-buddy>
              View on GitHub
            </a>
          </div>
        </section>
      </main>

      <footer className="footer">
        <div className="footer-brand">
          <img src="/icon.png" alt="" width={24} height={24} />
          <span>Clinqy. Your cursor’s clingy partner.</span>
        </div>
        <div className="footer-links">
          <a href={GITHUB} target="_blank" rel="noreferrer" data-buddy>GitHub</a>
          <button type="button" className="linklike" onClick={onReplay} data-buddy>Watch the intro again</button>
        </div>
      </footer>
    </div>
  )
}
