import { useState } from 'react'
import { usePhase } from './IsoArt'
import { Scramble } from './Scramble'
import { QaWindow, SignupWindow } from './LiveWindows'

const SKILL_URL = 'https://raw.githubusercontent.com/Amrit-Nigam/clinqy/main/skills/clinqy/SKILL.md'
const SKILL_INSTALL = `mkdir -p ~/.claude/skills/clinqy && curl -fsSL ${SKILL_URL} -o ~/.claude/skills/clinqy/SKILL.md`

type Line = { at: number; text: string; kind?: 'cmd' | 'ok' | 'fail' | 'pass' | 'note' | 'dim' | 'you' | 'agent' }

/** Lines that have appeared by `phase`, with the newest one typed out. */
function shown(lines: Line[], phase: number, typeSpan = 0.03) {
  return lines
    .filter((l) => phase >= l.at)
    .map((l) => {
      const p = Math.min(1, (phase - l.at) / typeSpan)
      const typed = l.kind === 'cmd' || l.kind === 'you' ? l.text.slice(0, Math.round(l.text.length * p)) : l.text
      return { ...l, typed }
    })
}

/* ───────────────────────── QA ───────────────────────── */

const TEST = `# Log in
Go to localhost:3000/login
Type test@example.com as the email
Type hunter2 as the password
Click Sign in
Expect: Welcome back`

/** Three runs of the same test: learn, replay, heal. Each is a slice of the loop. */
const RUNS: { from: number; to: number; lines: Line[] }[] = [
  {
    from: 0,
    to: 0.36,
    lines: [
      { at: 0.0, text: 'clinqy qa tests/login.md', kind: 'cmd' },
      { at: 0.05, text: 'learning: the model drives your browser', kind: 'dim' },
      { at: 0.09, text: '✓ go to localhost:3000/login', kind: 'ok' },
      { at: 0.13, text: '✓ type test@example.com as the email', kind: 'ok' },
      { at: 0.17, text: '✓ type ●●●●●●● as the password', kind: 'ok' },
      { at: 0.21, text: '✓ click Sign in', kind: 'ok' },
      { at: 0.25, text: '✓ expect: Welcome back', kind: 'ok' },
      { at: 0.29, text: 'PASS  learned  31.2s  → script saved to .clinqy/login.json', kind: 'pass' },
    ],
  },
  {
    from: 0.36,
    to: 0.6,
    lines: [
      { at: 0.36, text: 'clinqy qa tests/login.md', kind: 'cmd' },
      { at: 0.4, text: 'replay: no model, from .clinqy/login.json', kind: 'dim' },
      { at: 0.42, text: '✓ go to localhost:3000/login', kind: 'ok' },
      { at: 0.43, text: '✓ type test@example.com as the email', kind: 'ok' },
      { at: 0.44, text: '✓ type ●●●●●●● as the password', kind: 'ok' },
      { at: 0.45, text: '✓ click Sign in', kind: 'ok' },
      { at: 0.46, text: '✓ expect: Welcome back', kind: 'ok' },
      { at: 0.48, text: 'PASS  replay  3.9s', kind: 'pass' },
    ],
  },
  {
    from: 0.6,
    to: 1,
    lines: [
      { at: 0.6, text: '# you renamed “Sign in” to “Log in”', kind: 'note' },
      { at: 0.63, text: 'clinqy qa tests/login.md', kind: 'cmd' },
      { at: 0.67, text: 'replay: no model, from .clinqy/login.json', kind: 'dim' },
      { at: 0.69, text: '✓ go to localhost:3000/login', kind: 'ok' },
      { at: 0.7, text: '✓ type test@example.com as the email', kind: 'ok' },
      { at: 0.71, text: '✓ type ●●●●●●● as the password', kind: 'ok' },
      { at: 0.73, text: '✕ can’t find “Sign in”: the model takes over this step', kind: 'fail' },
      { at: 0.79, text: '✓ click Log in', kind: 'ok' },
      { at: 0.82, text: '✓ expect: Welcome back', kind: 'ok' },
      { at: 0.86, text: 'PASS  healed  9.7s  → script updated', kind: 'pass' },
    ],
  },
]

const MODES = [
  { name: 'learn', body: 'First run: the model drives your browser and saves a script of what worked.' },
  { name: 'replay', body: 'Every run after: no model, just the script. Fast, free, the same every time.' },
  { name: 'heal', body: 'UI changed: the model fixes only the broken step and updates the script.' },
]

export function QaSection() {
  const [ref, phase] = usePhase<HTMLDivElement>(16000)
  const run = RUNS.findIndex((r) => phase >= r.from && phase < r.to)
  const lines = shown(RUNS[Math.max(0, run)].lines, phase)
  return (
    <section className="qa" id="qa" aria-labelledby="qa-title">
      <div className="section-head">
        <Scramble as="h2" id="qa-title" text="UI tests in plain English" />
        <p>
          Write the test the way you’d tell a person. Clinqy runs it in your real browser, then turns it into a script
          that replays with no model. Run it from any terminal or coding agent.
        </p>
      </div>

      <div className="qa-demo" ref={ref}>
        <div className="qa-left">
        <figure className="qa-file">
          <figcaption>tests/login.md</figcaption>
          <pre>
            {TEST.split('\n').map((l, i) => (
              <span key={i} className={l.startsWith('#') ? 'md-h' : /^(Expect|Check|Verify)/.test(l) ? 'md-expect' : undefined}>
                {l}
                {'\n'}
              </span>
            ))}
          </pre>
        </figure>

        <div className="term qa-term" aria-label="Three runs of the test: learned, replayed, healed">
          <div className="term-bar">
            <i />
            <i />
            <i />
            <div className="mode-tabs" role="tablist" aria-label="Test modes">
              {MODES.map((m, i) => (
                <span key={m.name} role="tab" aria-selected={i === run} className={i === run ? 'is-on' : undefined}>
                  {m.name}
                </span>
              ))}
            </div>
          </div>
          <p className="mode-line">{MODES[Math.max(0, run)].body}</p>
          <pre aria-hidden="true">
            {lines.map((l, i) => (
              <span key={i} className={'tl tl-' + (l.kind ?? 'out')}>
                {l.kind === 'cmd' ? '$ ' : ''}
                {l.typed}
                {'\n'}
              </span>
            ))}
            <span className="caret">▍</span>
          </pre>
        </div>
        </div>
        <QaWindow phase={phase} />
      </div>

    </section>
  )
}

/* ───────────────────────── /clinqy for agents ───────────────────────── */

/** A Claude Code session: the person types /clinqy …, Claude calls the clinqy command, then answers. */
const ASK = '/clinqy check that signup on localhost:3000 rejects a bad email'
type CC = { at: number; kind: 'tool' | 'result' | 'agent' | 'status'; text: string }
const SESSION: CC[] = [
  { at: 0.11, kind: 'agent', text: 'I’ll try it in your browser with Clinqy.' },
  { at: 0.16, kind: 'tool', text: 'Bash(clinqy run --test "open localhost:3000/signup, type bad@ as the email, click Sign up")' },
  { at: 0.3, kind: 'result', text: '✓ opened localhost:3000/signup  ✓ typed bad@  ✓ clicked Sign up' },
  { at: 0.37, kind: 'tool', text: 'Bash(clinqy page)' },
  { at: 0.45, kind: 'result', text: 'w4 textbox: Email [bad@, required]' },
  { at: 0.47, kind: 'result', text: 'messages: “Enter a valid email address”' },
  { at: 0.55, kind: 'agent', text: 'It works: the email field turns red with “Enter a valid email address”, and the form doesn’t submit.' },
  { at: 0.66, kind: 'status', text: '✻ Worked for 14s' },
]

function ClaudeTerm({ phase }: { phase: number }) {
  const typed = ASK.slice(0, Math.round(ASK.length * span01(phase / 0.08)))
  const sent = phase >= 0.09
  const shownLines = SESSION.filter((l) => phase >= l.at)
  const thinking = sent && phase < 0.66 && !SESSION.some((l) => l.kind === 'agent' && phase >= l.at && phase < l.at + 0.02)
  return (
    <div className="cc" aria-label="A Claude Code session: the person types /clinqy, Claude runs clinqy in the browser and reports the error it found">
      <div className="cc-bar">
        <i />
        <i />
        <i />
        <span>~/my-app</span>
      </div>
      <div className="cc-body" aria-hidden="true">
        <div className="cc-scroll">
          {sent && (
            <p className="cc-user">
              <span>&gt;</span> {ASK}
            </p>
          )}
          {shownLines.map((l, i) =>
            l.kind === 'tool' ? (
              <p key={i} className="cc-tool">
                <span className="cc-dot">●</span> <b>Bash</b>
                {l.text.slice(4)}
              </p>
            ) : l.kind === 'result' ? (
              <p key={i} className="cc-result">
                <span>⎿</span> {l.text}
              </p>
            ) : l.kind === 'status' ? (
              <p key={i} className="cc-status">{l.text}</p>
            ) : (
              <p key={i} className="cc-agent">
                <span>●</span> {l.text}
              </p>
            ),
          )}
          {thinking && <p className="cc-status cc-thinking">✻ Clinqying…</p>}
        </div>
        <div className="cc-input">
          <span>&gt;</span> {sent ? '' : typed}
          <span className="cc-caret" />
        </div>
        <p className="cc-mode">⏵⏵ bypass permissions on <span>(shift+tab to cycle)</span></p>
      </div>
    </div>
  )
}

const span01 = (v: number) => Math.max(0, Math.min(1, v))


export function AgentSection() {
  const [ref, phase] = usePhase<HTMLDivElement>(15000)
  const [copied, setCopied] = useState(false)

  async function copy() {
    try {
      await navigator.clipboard.writeText(SKILL_INSTALL)
      setCopied(true)
      setTimeout(() => setCopied(false), 2200)
    } catch {
      /* the command is visible to select by hand */
    }
  }

  return (
    <section className="agents" id="agents" aria-labelledby="agents-title">
      <div className="section-head">
        <Scramble as="h2" id="agents-title" text="/clinqy, for your coding agent" />
        <p>
          Give Claude Code, Cursor, Codex or any agent eyes and hands in your real browser. With the /clinqy skill it
          checks what your page actually shows instead of guessing, and stops to ask before anything risky.
        </p>
      </div>

      <div className="agents-grid" ref={ref}>
        <ClaudeTerm phase={phase} />
        <SignupWindow phase={phase} />
      </div>

      <div className="skill-bar">
        <span className="skill-bar-label">Add /clinqy to Claude Code</span>
        <code className="skill-bar-cmd" tabIndex={0}>{SKILL_INSTALL}</code>
        <button type="button" className="btn btn-primary btn-small" onClick={copy} data-buddy>
          {copied ? 'Copied' : 'Copy'}
        </button>
      </div>
    </section>
  )
}
