import { useState } from 'react'
import { BuddyCursor } from './BuddyCursor'
import { CommandBar } from './CommandBar'
import { ScenePlayer } from './ScenePlayer'
import { ScreenWall } from './ScreenWall'
import { SETUP_PROMPT } from './setupPrompt'

const GITHUB = 'https://github.com/Amrit-Nigam/clinqy'

const FEATURES = [
  {
    title: 'Clicks that check themselves',
    body: 'After every click it looks for an effect. If nothing changed, it tries a real mouse click, then a click through the page, then focus plus a key. It remembers which way works on each site.',
  },
  {
    title: 'Sees the whole Mac',
    body: 'Native apps through Accessibility, web pages through a browser extension, PDFs and scans through on-device text recognition, and scriptable apps through AppleScript.',
  },
  {
    title: 'Talk to it',
    body: 'Hold ⌃⌥ and speak. Whisper writes the final text on your Mac. English, Hindi and Hinglish all work, and replies keep your style.',
  },
  {
    title: 'Remembers what matters',
    body: 'After each task it keeps lasting facts: people, preferences, your usual apps. It never saves passwords, card numbers or OTPs.',
  },
  {
    title: 'Learns by watching',
    body: 'Click Watch & learn, do a task once yourself, and it becomes a reusable skill with blanks to fill in next time.',
  },
  {
    title: 'Works with your coding agent',
    body: 'Add Clinqy as an MCP server to Claude Code, Cursor, Codex or Gemini CLI, and they can check how your page really renders in your own browser.',
  },
]

const MODELS = [
  ['Claude Code, Codex CLI or Gemini CLI', 'Uses the login you already have.'],
  ['An API key', 'Anthropic, OpenAI, Gemini or OpenRouter.'],
  ['A local model', 'Any vision model through Ollama, LM Studio or an OpenAI-compatible server.'],
]

export function Site({ live, onReplay }: { live: boolean; onReplay: () => void }) {
  const [copied, setCopied] = useState(false)

  async function copyPrompt() {
    try {
      await navigator.clipboard.writeText(SETUP_PROMPT)
      setCopied(true)
      setTimeout(() => setCopied(false), 2200)
    } catch {
      document.getElementById('setup')?.scrollIntoView({ behavior: 'smooth' })
    }
  }

  return (
    <div className="site">
      <ScreenWall running={live} />
      <BuddyCursor enabled={live} />

      <header className="nav">
        <a className="nav-logo" href="#top" data-buddy>
          <img src="/icon.png" alt="" width={28} height={28} />
          Clinqy
        </a>
        <nav aria-label="Sections">
          <a href="#watch">Watch it work</a>
          <a href="#features">What it can do</a>
          <a href="#safety">Safety</a>
          <a href="#setup">Set up</a>
        </nav>
        <a className="btn btn-quiet" href={GITHUB} target="_blank" rel="noreferrer" data-buddy>
          GitHub
        </a>
      </header>

      <main id="top">
        <section className="hero">
          <div className="hero-copy">
            <h1>Your Mac, on autopilot. And you can watch it work.</h1>
            <p className="lede">
              Press ⌃⌥ and say what you want. A small blue cursor goes and does it on screen: it clicks the Dock,
              types into the address bar, ticks the boxes and fills the form.
            </p>
            <div className="hero-ctas">
              <button type="button" className="btn btn-primary" onClick={copyPrompt} data-buddy>
                {copied ? 'Setup prompt copied' : 'Copy the setup prompt'}
              </button>
              <a className="btn btn-quiet" href={GITHUB} target="_blank" rel="noreferrer" data-buddy>
                View on GitHub
              </a>
            </div>
            <p className="fineprint">For macOS 14 or later on Apple silicon. Paste the prompt into your coding agent and it sets everything up.</p>
          </div>
          <div className="hero-demo">
            <CommandBar running={live} />
            <p className="hero-hint">
              See the blue arrow riding next to your pointer? That’s the companion. It goes where Clinqy is about to
              click, so nothing happens behind your back.
            </p>
          </div>
        </section>

        <section className="how" aria-labelledby="how-title">
          <h2 id="how-title">How it works</h2>
          <ol className="how-steps">
            <li>
              <h3>You ask</h3>
              <p>Tap ⌃⌥ and type, or hold it and talk. Whatever you’ve highlighted goes along, so “reply to this” just works.</p>
            </li>
            <li>
              <h3>It looks</h3>
              <p>It reads the screen the way assistive tech does: buttons, fields and lists by name, plus text recognition when an app hides them.</p>
            </li>
            <li>
              <h3>It acts, then checks</h3>
              <p>The blue cursor flies to the target and clicks or types for real. If nothing changed, it tries another way.</p>
            </li>
            <li>
              <h3>It asks when it matters</h3>
              <p>Missing details, choices and anything like Pay or Send come back to you first, with quick buttons or a voice answer.</p>
            </li>
          </ol>
        </section>

        <section className="watch" id="watch">
          <div className="section-head">
            <h2>It uses your Mac the way you would</h2>
            <p>
              No hidden APIs and no headless browser. It opens apps from the Dock, types at a human rhythm and clicks
              for real, then puts your pointer back where it was. Each step takes a second or two.
            </p>
          </div>
          <ScenePlayer />
        </section>

        <section className="features" id="features">
          <h2>What it can do</h2>
          <dl className="feature-list">
            {FEATURES.map((f) => (
              <div key={f.title} className="feature">
                <dt>{f.title}</dt>
                <dd>{f.body}</dd>
              </div>
            ))}
          </dl>
        </section>

        <section className="safety" id="safety">
          <div className="safety-copy">
            <h2>It asks before anything you can’t take back</h2>
            <ul>
              <li>Pay, Buy, Book, Send, Submit and Delete need your OK, unless you asked for exactly that.</li>
              <li>On a call? It checks with you before acting.</li>
              <li>One click in the menu bar stops any task.</li>
              <li>A watchdog stops a run that’s been stuck for 30 seconds.</li>
              <li>Renames and moves can be undone. Deleting only moves to the Trash.</li>
            </ul>
          </div>
          <div className="ask-card" aria-label="Example confirmation">
            <div className="ask-card-head">
              <img src="/icon.png" alt="" width={22} height={22} />
              Clinqy needs your OK
            </div>
            <p>
              Click <b>Pay ₹4,420</b> on flights.example.com for Akasa QP 1104, Delhi to Mumbai?
            </p>
            <div className="ask-card-actions">
              <button type="button" className="btn btn-ghost-dark" data-buddy>Not now</button>
              <button type="button" className="btn btn-primary" data-buddy>Pay ₹4,420</button>
            </div>
          </div>
        </section>

        <section className="models">
          <h2>Bring your own model</h2>
          <ul>
            {MODELS.map(([a, b]) => (
              <li key={a}>
                <b>{a}</b>
                <span>{b}</span>
              </li>
            ))}
          </ul>
        </section>

        <section className="setup" id="setup">
          <h2>Set it up in three steps</h2>
          <ol className="steps">
            <li>
              <h3>Fill in two lines</h3>
              <p>
                <code>Model:</code> is what drives it, like <code>claude cli</code> or <code>ollama qwen3-vl</code>.{' '}
                <code>Connect to:</code> lists the coding agents that should be able to use it.
              </p>
            </li>
            <li>
              <h3>Paste the prompt into your coding agent</h3>
              <p>Claude Code, Cursor, Codex, Gemini CLI or Windsurf. It builds Clinqy, installs it and only stops when it needs you.</p>
            </li>
            <li>
              <h3>Grant permissions and press ⌃⌥</h3>
              <p>Accessibility, Screen Recording, Microphone and Speech Recognition. Then ask it something.</p>
            </li>
          </ol>
          <div className="prompt">
            <div className="prompt-head">
              <span>Setup prompt</span>
              <button type="button" className="btn btn-primary btn-small" onClick={copyPrompt} data-buddy>
                {copied ? 'Copied' : 'Copy prompt'}
              </button>
            </div>
            <pre tabIndex={0}>{SETUP_PROMPT}</pre>
          </div>
        </section>
      </main>

      <footer className="footer">
        <div className="footer-brand">
          <img src="/icon.png" alt="" width={28} height={28} />
          <div>
            <b>Clinqy</b>
            <span>Your cursor’s clingy partner.</span>
          </div>
        </div>
        <div className="footer-links">
          <a href={GITHUB} target="_blank" rel="noreferrer" data-buddy>GitHub</a>
          <button type="button" className="linklike" onClick={onReplay} data-buddy>Watch the intro again</button>
        </div>
        <div className="smpte" aria-hidden="true">
          {['#c0c0c0', '#c0c000', '#00c0c0', '#00c000', '#c000c0', '#c00000', '#0000c0'].map((c) => (
            <i key={c} style={{ background: c }} />
          ))}
        </div>
      </footer>
    </div>
  )
}
