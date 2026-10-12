import { ReactNode } from 'react'
import { CursorArrow } from '../shared/Cursor'
import { Desktop, Field, STAGE_H, STAGE_W } from '../shared/Scenes'
import { smooth, span } from '../shared/timeline'
import { useFitScale } from '../shared/useFitScale'

/**
 * Real-looking windows for the QA and agent sections, driven by the same phase as the terminal next to
 * them, so every ✓ in the log lines up with a click on screen. Drawn on the 640 x 480 stage and cropped
 * to the window, like the "Watch it" player.
 */

/* Window body origin on the stage (see .sc-window: 40, 40 plus the 24px title bar). */
const OX = 40
const OY = 64

type Pt = { t: number; x: number; y: number }

/** Where a cursor is at `phase`, gliding between waypoints. */
function along(path: Pt[], phase: number): [number, number] {
  if (phase <= path[0].t) return [path[0].x, path[0].y]
  for (let i = 1; i < path.length; i++) {
    const a = path[i - 1]
    const b = path[i]
    if (phase <= b.t) {
      const e = smooth(span(phase, a.t, b.t))
      return [a.x + (b.x - a.x) * e, a.y + (b.y - a.y) * e]
    }
  }
  const last = path[path.length - 1]
  return [last.x, last.y]
}

const typedIn = (text: string, phase: number, a: number, b: number) => text.slice(0, Math.round(text.length * span(phase, a, b)))

function Cropped({ children, label }: { children: ReactNode; label: string }) {
  const [ref, scale] = useFitScale<HTMLDivElement>(560)
  return (
    <div className="live-window" ref={ref} style={{ height: 400 * scale }} role="img" aria-label={label}>
      <div style={{ transform: `scale(${scale}) translate(-40px, -40px)`, transformOrigin: '0 0' }}>
        <div className="sc-stage" style={{ width: STAGE_W, height: STAGE_H }}>
          {children}
        </div>
      </div>
    </div>
  )
}

/** Clinqy's QA cursor: an amber targeting reticle with a "QA" tag. */
function Reticle({ at, press, fail }: { at: [number, number]; press: boolean; fail: boolean }) {
  return (
    <div className={'qa-reticle' + (press ? ' is-press' : '') + (fail ? ' is-fail' : '')} style={{ transform: `translate(${at[0]}px, ${at[1]}px)` }}>
      <i />
      <b>QA</b>
    </div>
  )
}

function Pop({ at, ok, age }: { at: [number, number]; ok: boolean; age: number }) {
  if (age <= 0 || age >= 1) return null
  return (
    <span className={'qa-pop ' + (ok ? 'is-ok' : 'is-bad')} style={{ left: at[0] + 18, top: at[1] - 26, opacity: 1 - age * age }}>
      {ok ? '✓' : '✕'}
    </span>
  )
}

/* ───────────────────────── QA: the login test ───────────────────────── */

/** When each step happens in each run (matching the terminal's ✓ lines). */
const QA_RUNS = [
  { from: 0, to: 0.36, go: [0.05, 0.09], email: [0.09, 0.13], pass: [0.13, 0.17], click: [0.17, 0.21], expect: [0.21, 0.25], fail: null as number[] | null },
  { from: 0.36, to: 0.6, go: [0.4, 0.42], email: [0.42, 0.43], pass: [0.43, 0.44], click: [0.44, 0.45], expect: [0.45, 0.46], fail: null },
  { from: 0.6, to: 1, go: [0.67, 0.69], email: [0.69, 0.7], pass: [0.7, 0.71], click: [0.73, 0.79], expect: [0.79, 0.82], fail: [0.71, 0.73] },
]

const EMAIL = { x: OX + 150 + 130, y: OY + 112 + 30 }
const PASS = { x: OX + 150 + 130, y: OY + 172 + 30 }
const BTN = { x: OX + 150 + 130, y: OY + 246 + 17 }
const REST = { x: 540, y: 430 }

export function QaWindow({ phase }: { phase: number }) {
  const r = QA_RUNS.findIndex((x) => phase >= x.from && phase < x.to)
  const run = QA_RUNS[Math.max(0, r)]
  const healed = r === 2
  const loaded = smooth(span(phase, run.go[0], run.go[1]))
  const email = typedIn('test@example.com', phase, run.email[0], run.email[1])
  const pass = '●'.repeat(Math.round(7 * span(phase, run.pass[0], run.pass[1])))
  const clickAt = run.click[1] - 0.006
  const pressed = phase > clickAt - 0.004 && phase < clickAt + 0.006
  const signedIn = phase >= run.click[1]
  const path: Pt[] = [
    { t: run.from, ...REST },
    { t: run.email[0], ...EMAIL },
    { t: run.pass[0], ...EMAIL },
    { t: run.pass[0] + 0.004, ...PASS },
    ...(run.fail ? [{ t: run.fail[0], ...BTN }, { t: run.click[0] + 0.02, x: BTN.x - 4, y: BTN.y }] : [{ t: run.click[0], ...PASS }]),
    { t: clickAt, ...BTN },
    { t: run.expect[0], ...BTN },
    { t: run.expect[1], x: 320, y: OY + 120 },
    { t: run.to, x: 320, y: OY + 120 },
  ]
  const at = along(path, phase)
  const failing = !!run.fail && phase >= run.fail[0] && phase < run.fail[1] + 0.01
  // ✓ after each step, ✕ when the old button is gone.
  const pops: { t: number; ok: boolean }[] = [
    { t: run.email[1], ok: true },
    { t: run.pass[1], ok: true },
    ...(run.fail ? [{ t: run.fail[0] + 0.01, ok: false }] : []),
    { t: run.click[1], ok: true },
    { t: run.expect[1], ok: true },
  ]
  return (
    <Cropped label="A login page in a browser: Clinqy's QA cursor types the email and password, clicks the button and checks for Welcome back">
      <Desktop title="Acme" url="localhost:3000/login">
        <div className="lw-site-head">
          <b>◆ acme</b>
          <span>Pricing</span>
          <span>Docs</span>
        </div>
        {!signedIn ? (
          <div className="lw-page" style={{ opacity: loaded }}>
            <h3 className="sc-h" style={{ left: 150, top: 56 }}>
              Log in to Acme
            </h3>
            <Field x={150} y={112} w={260} label="Email" value={email} active={phase >= run.email[0] && phase < run.email[1] + 0.01} placeholder="you@company.com" />
            <Field x={150} y={172} w={260} label="Password" value={pass} active={phase >= run.pass[0] && phase < run.pass[1] + 0.01} placeholder="••••••••" />
            <div className={'sc-btn sc-btn-blue lw-btn' + (pressed ? ' is-pressed' : '') + (failing ? ' is-searched' : '')} style={{ left: 150, top: 246, width: 260, height: 34 }}>
              {healed ? 'Log in' : 'Sign in'}
            </div>
            <div className="lw-foot" style={{ left: 150, top: 296 }}>
              Forgot password? · Create an account
            </div>
          </div>
        ) : (
          <div className="lw-page">
            <h3 className="sc-h lw-welcome" style={{ left: 150, top: 46 }}>
              Welcome back, Test
            </h3>
            {[0, 1, 2].map((i) => (
              <div key={i} className="lw-card" style={{ left: 150 + i * 90, top: 100 }} />
            ))}
            <div className="lw-row" style={{ left: 150, top: 196, width: 260 }} />
            <div className="lw-row" style={{ left: 150, top: 222, width: 200 }} />
          </div>
        )}
      </Desktop>
      {pops.map((p) => (
        <Pop key={p.t} at={at} ok={p.ok} age={(phase - p.t) / 0.04} />
      ))}
      <Reticle at={at} press={pressed} fail={failing} />
    </Cropped>
  )
}

/* ───────────────────────── Agent: checking a signup page ───────────────────────── */

const S_EMAIL = { x: OX + 150 + 130, y: OY + 112 + 30 }
const S_BTN = { x: OX + 150 + 130, y: OY + 262 + 17 }

export function SignupWindow({ phase }: { phase: number }) {
  const opened = smooth(span(phase, 0.18, 0.21))
  const email = typedIn('bad@', phase, 0.22, 0.25)
  const clickAt = 0.275
  const pressed = phase > clickAt - 0.006 && phase < clickAt + 0.008
  const error = phase >= 0.282
  const reading = span(phase, 0.39, 0.47)
  const readFade = 1 - smooth(span(phase, 0.62, 0.68))
  const path: Pt[] = [
    { t: 0.18, x: 560, y: 420 },
    { t: 0.215, ...S_EMAIL },
    { t: 0.25, ...S_EMAIL },
    { t: clickAt, ...S_BTN },
    { t: 0.32, ...S_BTN },
    { t: 0.38, x: 520, y: 400 },
  ]
  const at = along(path, phase)
  return (
    <Cropped label="A signup page: Clinqy types bad@ as the email and clicks Sign up, the error appears, then Clinqy reads the field and the message">
      <Desktop title="Sign up" url="localhost:3000/signup">
        <div className="lw-site-head">
          <b>◆ acme</b>
          <span>Pricing</span>
          <span>Docs</span>
        </div>
        <div className="lw-page" style={{ opacity: Math.max(0.35, opened) }}>
          <h3 className="sc-h" style={{ left: 150, top: 56 }}>
            Create your account
          </h3>
          <div className={'lw-field' + (error ? ' is-error' : '')}>
            <Field x={150} y={112} w={260} label="Email" value={email} active={phase >= 0.215 && phase < 0.26} placeholder="you@company.com" />
          </div>
          {error && (
            <div className="lw-error" style={{ left: 150, top: 160 }}>
              Enter a valid email address
            </div>
          )}
          <Field x={150} y={190} w={260} label="Password" value="" placeholder="At least 8 characters" />
          <div className={'sc-btn sc-btn-blue' + (pressed ? ' is-pressed' : '')} style={{ left: 150, top: 262, width: 260, height: 34 }}>
            Sign up
          </div>
        </div>
        {reading > 0 && readFade > 0 && (
          <>
            <div className="lw-read" style={{ left: 144, top: 106, width: 272, height: 52, opacity: readFade, clipPath: `inset(0 ${100 - Math.min(1, reading * 2) * 100}% 0 0)` }}>
              <em>w4 textbox · Email [bad@, required]</em>
            </div>
            <div className="lw-read" style={{ left: 144, top: 156, width: 210, height: 22, opacity: readFade, clipPath: `inset(0 ${100 - Math.max(0, Math.min(1, reading * 2 - 1)) * 100}% 0 0)` }}>
              <em>message</em>
            </div>
          </>
        )}
      </Desktop>
      {phase >= 0.18 && <CursorArrow className="sc-cursor" size={20} style={{ transform: `translate(${at[0]}px, ${at[1]}px) scale(${pressed ? 0.86 : 1})` }} />}
    </Cropped>
  )
}
