import { createContext, useContext } from 'react'
import { CursorArrow } from './Cursor'
import { cursorAt, easeOut, Key, lastClick, span, typed } from './timeline'

/** Every scene is drawn on a fixed 640 x 480 stage, then scaled. */
export const STAGE_W = 640
export const STAGE_H = 480

type SceneProps = { t: number; cur: { x: number; y: number; down: boolean } }

export type Scene = {
  id: string
  label: string
  app: string
  osd: string
  request: string
  keys: Key[]
  Body: (p: SceneProps) => JSX.Element
}

/** bare: the host draws the wallpaper and menu bar itself (full-bleed CRT). */
const StageCtx = createContext({ bare: false, app: '' })

export function MenuBar({ app }: { app: string }) {
  return (
    <div className="sc-menubar">
      <span className="sc-apple" />
      <b>{app}</b>
      <span>File</span>
      <span>Edit</span>
      <span>View</span>
      <span className="sc-menu-right">⌃⌥ Clinqy</span>
    </div>
  )
}

/**
 * A macOS window. Browser scenes pass `url` and get a toolbar with the
 * address in a pill; app scenes get a plain centred title. `dark` is for
 * apps that edit in dark mode (Photos).
 */
function Desktop({ title, url, dark, children }: { title: string; url?: string; dark?: boolean; children: React.ReactNode }) {
  const { bare, app } = useContext(StageCtx)
  return (
    <div className={'sc-desktop' + (bare ? ' is-bare' : '')}>
      {!bare && <MenuBar app={app} />}
      <div className={'sc-window' + (dark ? ' is-dark' : '')}>
        <div className={'sc-titlebar' + (url ? ' is-browser' : '')}>
          <i style={{ background: '#ff5f57' }} />
          <i style={{ background: '#febc2e' }} />
          <i style={{ background: '#28c840' }} />
          {url ? (
            <>
              <span className="sc-nav">‹ ›</span>
              <span className="sc-addr">
                <span className="sc-lock" />
                {url}
              </span>
            </>
          ) : (
            <span className="sc-title">{title}</span>
          )}
        </div>
        <div className="sc-content">{children}</div>
      </div>
    </div>
  )
}

function Field({ x, y, w = 300, label, value, active, placeholder }: { x: number; y: number; w?: number; label: string; value: string; active?: boolean; placeholder?: string }) {
  return (
    <div className="sc-field" style={{ left: x, top: y, width: w }}>
      <label>{label}</label>
      <div className={'sc-input' + (active ? ' is-active' : '')}>
        {value || (!active && placeholder ? <small>{placeholder}</small> : null)}
        {active && <span className="sc-caret" />}
      </div>
    </div>
  )
}

function Toast({ show, children }: { show: number; children: React.ReactNode }) {
  return (
    <div className="sc-toast" style={{ opacity: show, transform: `translateY(${(1 - show) * 16}px)` }}>
      {children}
    </div>
  )
}

/* Coordinates inside .sc-content are relative to the window body (x 40, y 64 on the stage). */
const OX = 40
const OY = 64

/* 1. Screenshot: drag a marquee over flight results, flash, thumbnail. */
const shotKeys: Key[] = [
  { t: 0, x: 560, y: 420 },
  { t: 0.22, x: 110, y: 130 },
  { t: 0.26, x: 110, y: 130, down: true },
  { t: 0.6, x: 480, y: 330, down: true },
  { t: 0.64, x: 480, y: 330 },
  { t: 0.9, x: 540, y: 400 },
  { t: 1, x: 540, y: 400 },
]
function ShotBody({ t, cur }: SceneProps) {
  const dragging = t >= 0.26 && t < 0.64
  const flash = t >= 0.64 ? Math.max(0, 1 - span(t, 0.64, 0.74)) : 0
  const thumb = easeOut(span(t, 0.7, 0.82))
  const rows: [string, string, string, string, string, string][] = [
    ['6E', '#1d3f9a', 'IndiGo', '06:10 – 08:20', '2h 10m · Non-stop', '₹4,860'],
    ['AI', '#c8102e', 'Air India', '08:45 – 11:05', '2h 20m · Non-stop', '₹5,320'],
    ['UK', '#5b2d82', 'Vistara', '13:20 – 15:35', '2h 15m · Non-stop', '₹6,110'],
    ['QP', '#f26522', 'Akasa Air', '19:05 – 21:15', '2h 10m · Non-stop', '₹4,420'],
  ]
  return (
    <Desktop title="Flights to Mumbai" url="skyfare.example/del-bom">
      <div className="sc-site-head">
        <b className="sc-logo">✈ skyfare</b>
        <span className="is-on">Flights</span>
        <span>Hotels</span>
        <span>Trips</span>
        <i className="sc-me">R</i>
      </div>
      <h3 className="sc-h" style={{ left: 30, top: 48 }}>Delhi → Mumbai</h3>
      <div className="sc-meta" style={{ left: 30, top: 70 }}>Fri, 17 Oct · 1 adult · Economy · 24 flights</div>
      <div className="sc-chips" style={{ right: 30, top: 50 }}>
        <span className="is-on">Cheapest</span>
        <span>Fastest</span>
        <span>Non-stop</span>
      </div>
      {rows.map((r, i) => (
        <div key={i} className={'sc-row' + (i === 3 ? ' is-best' : '')} style={{ left: 30, top: 92 + i * 52 }}>
          <span className="sc-airline" style={{ background: r[1] }}>{r[0]}</span>
          <div className="sc-row-name"><b>{r[2]}</b><small>{r[0]} {[2131, 805, 943, 1104][i]}</small></div>
          <div className="sc-row-time"><b>{r[3]}</b><small>{r[4]}</small></div>
          <em>{r[5]}</em>
        </div>
      ))}
      {(dragging || (t >= 0.6 && t < 0.66)) && (
        <div
          className="sc-marquee"
          style={{
            left: 110 - OX,
            top: 130 - OY,
            width: Math.max(0, cur.x - 110),
            height: Math.max(0, cur.y - 130),
          }}
        >
          <span>{Math.round(cur.x - 110)} × {Math.round(cur.y - 130)}</span>
        </div>
      )}
      <div className="sc-flash" style={{ opacity: flash }} />
      <div className="sc-thumb" style={{ opacity: thumb, transform: `translateX(${(1 - thumb) * 60}px)` }}>
        <div className="sc-thumb-img" />
        <span>Screenshot saved</span>
      </div>
    </Desktop>
  )
}

/* 2. Photo edit: drag brightness, then export. */
const editKeys: Key[] = [
  { t: 0, x: 300, y: 420 },
  { t: 0.2, x: 478, y: 146 },
  { t: 0.24, x: 478, y: 146, down: true },
  { t: 0.58, x: 572, y: 146, down: true },
  { t: 0.62, x: 572, y: 146 },
  { t: 0.8, x: 524, y: 388 },
  { t: 0.84, x: 524, y: 388, click: true },
  { t: 1, x: 524, y: 388 },
]
function EditBody({ t, cur }: SceneProps) {
  const dragP = span(t, 0.24, 0.58)
  const knobX = t < 0.24 ? 478 : t > 0.58 ? 572 : cur.x
  const value = Math.round(((knobX - 478) / 94) * 60 - 20)
  const warm = span(t, 0.3, 0.6)
  const exported = easeOut(span(t, 0.86, 0.94))
  return (
    <Desktop title="beach.jpg — Edit" dark>
      <div
        className="sc-photo"
        style={{ filter: `brightness(${0.62 + dragP * 0.55}) saturate(${0.7 + warm * 0.6})` }}
      >
        <div className="sc-sun" />
        <div className="sc-sea" />
        <div className="sc-sand" />
      </div>
      <div className="sc-panel">
        <div className="sc-seg" style={{ top: 12 }}>
          <span className="is-on">Adjust</span>
          <span>Filters</span>
          <span>Crop</span>
        </div>
        <div className="sc-panel-head" style={{ top: 44 }}>Light</div>
        <div className="sc-slider" style={{ top: 66 }}>
          <label>Brightness <b>{value > 0 ? '+' : ''}{value}</b></label>
          <div className="sc-track"><i style={{ width: knobX - 470 }} /><span style={{ left: knobX - 470 - 7 }} /></div>
        </div>
        <div className="sc-slider" style={{ top: 126 }}>
          <label>Warmth <b>+{Math.round(warm * 18)}</b></label>
          <div className="sc-track"><i style={{ width: 40 + warm * 30 }} /><span style={{ left: 40 + warm * 30 - 7 }} /></div>
        </div>
        <div className="sc-slider" style={{ top: 186 }}>
          <label>Contrast <b>0</b></label>
          <div className="sc-track"><i style={{ width: 50 }} /><span style={{ left: 43 }} /></div>
        </div>
        <div className="sc-panel-head" style={{ top: 236 }}>Color</div>
        <div className="sc-swatches" style={{ top: 256 }}>
          <i style={{ background: '#e8574a' }} />
          <i style={{ background: '#f2b33d' }} />
          <i style={{ background: '#4cae6a' }} />
          <i style={{ background: '#3b82f6' }} />
        </div>
        <div className={'sc-btn sc-btn-yellow' + (t > 0.84 && t < 0.9 ? ' is-pressed' : '')} style={{ left: 18, top: 308, width: 96 }}>Export</div>
      </div>
      <Toast show={exported}>Exported beach-edit.jpg</Toast>
    </Desktop>
  )
}

/* 3. AWS console: name the instance, pick a type, launch (asks first). */
const awsKeys: Key[] = [
  { t: 0, x: 560, y: 420 },
  { t: 0.1, x: 210, y: 210, click: true },
  { t: 0.4, x: 230, y: 214 },
  { t: 0.46, x: 210, y: 280, click: true },
  { t: 0.56, x: 200, y: 332 },
  { t: 0.58, x: 200, y: 332, click: true },
  { t: 0.72, x: 520, y: 404 },
  { t: 0.74, x: 520, y: 404, click: true },
  { t: 0.86, x: 420, y: 299 },
  { t: 0.88, x: 420, y: 299, click: true },
  { t: 1, x: 430, y: 330 },
]
function AwsBody({ t }: SceneProps) {
  const name = typed('tf-server', t, 0.14, 0.36)
  const open = t >= 0.47 && t < 0.59
  const picked = t >= 0.59
  const confirm = t >= 0.76 && t < 0.9 ? easeOut(span(t, 0.76, 0.8)) : 0
  const done = easeOut(span(t, 0.9, 0.96))
  return (
    <Desktop title="Launch an instance | EC2" url="console.aws.amazon.com/ec2">
      <div className="sc-aws-nav">
        <b className="sc-aws-logo">aws</b>
        <span>Services</span>
        <span className="sc-aws-search">Search <small>[Option+S]</small></span>
        <span className="sc-aws-right">Mumbai ▾</span>
        <span>riya ▾</span>
      </div>
      <div className="sc-aws-crumbs">EC2 <span>›</span> Instances <span>›</span> <b>Launch an instance</b></div>
      <div className="sc-aws-card" style={{ left: 18, top: 90, width: 524, height: 200 }}>
        <b>Name and tags</b>
      </div>
      <Field x={30} y={118} label="Name" value={name} active={t > 0.1 && t < 0.42} placeholder="e.g. My Web Server" />
      <div className="sc-field" style={{ left: 30, top: 188, width: 300 }}>
        <label>Instance type</label>
        <div className={'sc-input sc-select' + (open ? ' is-active' : '')}>
          {picked ? 't3.micro' : 't2.nano'}
          <small className="sc-select-note">{picked ? '2 vCPU · 1 GiB · Free tier' : '1 vCPU · 0.5 GiB'}</small>
        </div>
      </div>
      {open && (
        <div className="sc-dropdown" style={{ left: 30, top: 236 }}>
          <div>t2.nano</div>
          <div className={t > 0.55 ? 'is-hover' : ''}>t3.micro <small>Free tier eligible</small></div>
          <div>t3.large</div>
        </div>
      )}
      <div className="sc-field" style={{ left: 360, top: 118, width: 170 }}>
        <label>Region</label>
        <div className="sc-input">Asia Pacific (Mumbai)</div>
      </div>
      <div className="sc-aws-summary" style={{ left: 360, top: 188, width: 170 }}>
        <small>Number of instances</small>
        <b>1</b>
      </div>
      <div className="sc-btn sc-btn-ghost" style={{ left: 320, top: 324, width: 80 }}>Cancel</div>
      <div className={'sc-btn sc-btn-aws' + (t > 0.74 && t < 0.78 ? ' is-pressed' : '')} style={{ left: 410, top: 324, width: 140 }}>Launch instance</div>
      {confirm > 0 && (
        <div className="sc-ask" style={{ opacity: confirm, transform: `scale(${0.94 + confirm * 0.06})` }}>
          <b>Launch tf-server (t3.micro)?</b>
          <span>Clinqy needs your OK. This starts a billable instance.</span>
          <div><i>Cancel</i><i className="is-yes">Launch</i></div>
        </div>
      )}
      <Toast show={done}>Instance tf-server is running</Toast>
    </Desktop>
  )
}

/* 4. Job portal: fill, upload resume, tick, submit. */
const jobKeys: Key[] = [
  { t: 0, x: 560, y: 420 },
  { t: 0.07, x: 220, y: 200, click: true },
  { t: 0.27, x: 236, y: 206 },
  { t: 0.3, x: 220, y: 262, click: true },
  { t: 0.48, x: 236, y: 268 },
  { t: 0.54, x: 104, y: 322, click: true },
  { t: 0.66, x: 78, y: 378 },
  { t: 0.68, x: 78, y: 378, click: true },
  { t: 0.8, x: 520, y: 400 },
  { t: 0.82, x: 520, y: 400, click: true },
  { t: 1, x: 540, y: 420 },
]
function JobBody({ t }: SceneProps) {
  const nameV = typed('Riya Sharma', t, 0.09, 0.27)
  const mailV = typed('riya@hey.com', t, 0.32, 0.48)
  const uploaded = t >= 0.58
  const ticked = t >= 0.69
  const sent = easeOut(span(t, 0.84, 0.92))
  return (
    <Desktop title="Product Designer — Northwind" url="careers.northwind.example/jobs/2041">
      <div className="sc-job-head">
        <span className="sc-job-logo">N</span>
        <b>Northwind</b>
        <span className="sc-job-links">Teams · Life · <u>Open roles</u></span>
      </div>
      <h3 className="sc-h" style={{ left: 30, top: 44 }}>Product Designer</h3>
      <div className="sc-tags" style={{ left: 30, top: 70 }}>
        <span>Bengaluru</span>
        <span>Full-time</span>
        <span>Hybrid</span>
      </div>
      <Field x={30} y={106} label="Full name" value={nameV} active={t > 0.07 && t < 0.29} placeholder="Your name" />
      <Field x={30} y={168} label="Email" value={mailV} active={t > 0.3 && t < 0.5} placeholder="you@example.com" />
      <div className="sc-field" style={{ left: 30, top: 230, width: 300 }}>
        <label>Resume / CV</label>
        <div className="sc-upload">
          <span className="sc-btn-mini">Upload</span>
          {uploaded ? <em>📄 resume.pdf · 182 KB</em> : <small>PDF, DOC up to 5 MB</small>}
        </div>
      </div>
      <div className="sc-check" style={{ left: 30, top: 306 }}>
        <span className={ticked ? 'is-on' : ''}>{ticked ? '✓' : ''}</span>
        I agree to the privacy notice
      </div>
      <div className="sc-job-about" style={{ left: 360, top: 106, width: 180 }}>
        <b>About the role</b>
        <p>Own flows end to end with a small team, from research to polished UI.</p>
        <b>You’ll bring</b>
        <p>4+ years in product design and a portfolio of shipped work.</p>
      </div>
      <div className={'sc-btn sc-btn-blue' + (t > 0.82 && t < 0.86 ? ' is-pressed' : '')} style={{ left: 410, top: 320, width: 140 }}>Submit application</div>
      <Toast show={sent}>Application sent</Toast>
    </Desktop>
  )
}

/* 5. Messages: open Mom's chat, type, send. */
const msgKeys: Key[] = [
  { t: 0, x: 560, y: 420 },
  { t: 0.14, x: 120, y: 136, click: true },
  { t: 0.3, x: 360, y: 413, click: true },
  { t: 0.68, x: 372, y: 418 },
  { t: 0.76, x: 555, y: 413, click: true },
  { t: 1, x: 555, y: 413 },
]
function MsgBody({ t }: SceneProps) {
  const open = t >= 0.15
  const draft = t >= 0.77 ? '' : typed('I’ll be late, stuck in traffic', t, 0.32, 0.68)
  const sent = easeOut(span(t, 0.77, 0.83))
  const chats: [string, string, string, string][] = [
    ['Mom', 'Call me when you’re free', '9:12', '#e8a87c'],
    ['Raj', 'Sent the deck', '8:47', '#85b8e8'],
    ['Priya', 'Thursday works', 'Yesterday', '#c9a0dc'],
    ['Design team', 'Ana: new mocks are up', 'Yesterday', '#8fd1a8'],
  ]
  return (
    <Desktop title="WhatsApp">
      <div className="sc-chats">
        <b className="sc-chats-title">Chats</b>
        <span className="sc-chats-search">Search or start a new chat</span>
        {chats.map(([n, m, time, color], i) => (
          <div key={n} className={'sc-chat' + (open && i === 0 ? ' is-open' : '')} style={{ top: 50 + i * 48 }}>
            <span className="sc-avatar" style={{ background: color }}>{n[0]}</span>
            <div><b>{n}</b><small>{m}</small></div>
            <time>{time}</time>
          </div>
        ))}
      </div>
      <div className="sc-thread-head">
        {open ? (
          <>
            <span className="sc-avatar" style={{ background: '#e8a87c' }}>M</span>
            <div><b>Mom</b><small>online</small></div>
          </>
        ) : null}
      </div>
      <div className="sc-thread">
        {open && (
          <>
            <div className="sc-day">TODAY</div>
            <div className="sc-bubble">Call me when you’re free <time>9:12</time></div>
            {sent > 0 && (
              <div className="sc-bubble is-me" style={{ opacity: sent, transform: `translateY(${(1 - sent) * 10}px)` }}>
                I’ll be late, stuck in traffic <time>9:41 <span>✓✓</span></time>
              </div>
            )}
          </>
        )}
      </div>
      <div className="sc-composer" />
      <div className={'sc-input sc-compose' + (t > 0.3 && t < 0.77 ? ' is-active' : '')}>
        {draft || <small>Type a message</small>}
      </div>
      <div className={'sc-btn sc-btn-green sc-send' + (t > 0.76 && t < 0.8 ? ' is-pressed' : '')}>Send</div>
    </Desktop>
  )
}

/* 6. Calendar: scan Thursday for a free slot, book it. */
const calKeys: Key[] = [
  { t: 0, x: 560, y: 420 },
  { t: 0.22, x: 436, y: 130 },
  { t: 0.5, x: 436, y: 244 },
  { t: 0.56, x: 436, y: 250, click: true },
  { t: 1, x: 480, y: 330 },
]
function CalBody({ t, cur }: SceneProps) {
  const days: [string, number][] = [['Mon', 13], ['Tue', 14], ['Wed', 15], ['Thu', 16], ['Fri', 17]]
  const busy: [number, number, number, string, string][] = [
    [0, 0, 1, 'Standup', 'blue'],
    [1, 1, 3, 'Design workshop', 'purple'],
    [2, 0, 2, 'Portfolio reviews', 'green'],
    [3, 0, 2, 'Interviews', 'orange'],
    [3, 3, 4, '1:1 with Sam', 'blue'],
    [4, 1, 2, 'Lunch with Raj', 'green'],
  ]
  const scanning = t >= 0.22 && t < 0.56
  const booked = easeOut(span(t, 0.57, 0.66))
  const toast = easeOut(span(t, 0.68, 0.76))
  const ROW = 60
  return (
    <Desktop title="October 2026">
      {days.map(([d, n], i) => (
        <div key={d} className={'sc-cal-day' + (i === 3 ? ' is-today' : '')} style={{ left: 60 + i * 96, top: 12 }}>
          {d} <b>{n}</b>
        </div>
      ))}
      {['1 PM', '2 PM', '3 PM', '4 PM', '5 PM'].map((h, i) => (
        <div key={h} className="sc-cal-hour" style={{ top: 46 + i * ROW }}>{h}</div>
      ))}
      <div className="sc-cal-grid" />
      {busy.map(([d, a, b, n, c]) => (
        <div key={n} className={'sc-cal-ev is-' + c} style={{ left: 62 + d * 96, top: 50 + a * ROW, height: (b - a) * ROW - 4 }}>
          {n}
          <small>{a + 1}:00 PM</small>
        </div>
      ))}
      <div className="sc-cal-now" style={{ top: 50 + 1.4 * ROW }} />
      {scanning && (
        <div className="sc-cal-scan" style={{ left: 348, top: Math.max(50, cur.y - 64 - 20), height: 30 }} />
      )}
      {booked > 0 && (
        <div className="sc-cal-ev is-new" style={{ left: 350, top: 170, height: 28, opacity: booked, transform: `scale(${0.9 + booked * 0.1})` }}>
          Call with Priya
        </div>
      )}
      <Toast show={toast}>Added Call with Priya, Thu 3:00 PM</Toast>
    </Desktop>
  )
}

/* 7. Files: sort Downloads into folders. */
const FILES: [string, number, string, string][] = [
  ['invoice-sept.pdf', 0, 'Today, 9:02', '84 KB'],
  ['beach.jpg', 1, 'Today, 8:40', '3.2 MB'],
  ['Zoom.pkg', 2, 'Yesterday', '41 MB'],
  ['offer-letter.pdf', 0, 'Yesterday', '120 KB'],
  ['screenshot.png', 1, '14 Oct', '612 KB'],
  ['resume.pdf', 0, '12 Oct', '182 KB'],
]
const drags = [
  [0.12, 0.26],
  [0.3, 0.44],
  [0.48, 0.62],
]
const fileKeys: Key[] = [
  { t: 0, x: 560, y: 420 },
  ...drags.flatMap(([a, b], i) => {
    const rowY = 101 + i * 40
    const folderY = 131 + FILES[i][1] * 90
    return [
      { t: a, x: 120, y: rowY },
      { t: a + 0.02, x: 120, y: rowY, down: true },
      { t: b, x: 480, y: folderY, down: true },
      { t: b + 0.02, x: 480, y: folderY },
    ]
  }),
  { t: 1, x: 520, y: 400 },
]
function FilesBody({ t, cur }: SceneProps) {
  const folders = ['PDFs', 'Images', 'Installers']
  // When each file lands: the first three are dragged, the rest follow in bulk.
  const landed = FILES.map((_, i) => (i < 3 ? drags[i][1] + 0.02 : 0.68 + (i - 3) * 0.04))
  const dragging = drags.findIndex(([a, b]) => t >= a + 0.02 && t < b + 0.02)
  const counts = folders.map((_, f) => FILES.filter(([, ff], i) => ff === f && t >= landed[i]).length)
  const toast = easeOut(span(t, 0.84, 0.9))
  return (
    <Desktop title="Downloads">
      <div className="sc-cols" style={{ left: 20, top: 2 }}>
        <span>Name</span>
        <span>Date Modified</span>
        <span>Size</span>
      </div>
      {FILES.map(([name, , date, size], i) => {
        const gone = t >= landed[i]
        const fading = i >= 3 ? 1 - span(t, landed[i] - 0.04, landed[i]) : gone ? 0 : 1
        return (
          <div key={name} className="sc-file" style={{ left: 20, top: 20 + i * 40, opacity: dragging === i ? 0.3 : fading }}>
            <span className={'sc-file-ico ' + name.split('.')[1]} />
            <span className="sc-file-name">{name}</span>
            <small>{date}</small>
            <small>{size}</small>
          </div>
        )
      })}
      {folders.map((f, j) => (
        <div key={f} className={'sc-folder' + (dragging >= 0 && FILES[dragging][1] === j ? ' is-target' : '')} style={{ left: 340, top: 30 + j * 90 }}>
          <span className="sc-folder-ico" />
          <div><b>{f}</b><small>{counts[j]} {counts[j] === 1 ? 'item' : 'items'}</small></div>
        </div>
      ))}
      {dragging >= 0 && (
        <div className="sc-file is-ghost" style={{ left: cur.x - 40 - 60, top: cur.y - 64 - 17 }}>
          <span className={'sc-file-ico ' + FILES[dragging][0].split('.')[1]} />
          <span className="sc-file-name">{FILES[dragging][0]}</span>
        </div>
      )}
      <Toast show={toast}>Sorted 6 files. You can undo this.</Toast>
    </Desktop>
  )
}

export const SCENES: Scene[] = [
  { id: 'shot', label: 'Screenshots', app: 'Safari', osd: 'SCREENSHOT', request: 'grab the cheapest flights', keys: shotKeys, Body: ShotBody },
  { id: 'edit', label: 'Photo edits', app: 'Photos', osd: 'PHOTO EDIT', request: 'brighten this photo and export it', keys: editKeys, Body: EditBody },
  { id: 'aws', label: 'AWS console', app: 'Chrome', osd: 'AWS CONSOLE', request: 'launch a t3.micro called tf-server', keys: awsKeys, Body: AwsBody },
  { id: 'job', label: 'Job applications', app: 'Arc', osd: 'JOB PORTAL', request: 'apply to this job with my resume', keys: jobKeys, Body: JobBody },
  { id: 'msg', label: 'Messages', app: 'WhatsApp', osd: 'MESSAGES', request: 'message mom I’ll be late', keys: msgKeys, Body: MsgBody },
  { id: 'cal', label: 'Calendar', app: 'Calendar', osd: 'CALENDAR', request: 'schedule a call with Priya Thursday afternoon', keys: calKeys, Body: CalBody },
  { id: 'files', label: 'Files', app: 'Finder', osd: 'FILES', request: 'sort my Downloads into folders', keys: fileKeys, Body: FilesBody },
]


/** Renders one scene at progress t (0..1), with the companion cursor and click ripples. */
export function SceneStage({
  scene,
  t,
  showRequest = true,
  bare = false,
  hideCursor = false,
}: {
  scene: Scene
  t: number
  showRequest?: boolean
  bare?: boolean
  /** The host draws the cursor itself (the CRT does, above its colour filter). */
  hideCursor?: boolean
}) {
  const cur = cursorAt(scene.keys, t)
  const click = lastClick(scene.keys, t)
  const ripple = click ? span(t, click.t, click.t + 0.08) : 1
  const { Body } = scene
  return (
    <StageCtx.Provider value={{ bare, app: scene.app }}>
    <div className="sc-stage" style={{ width: STAGE_W, height: STAGE_H }}>
      <Body t={t} cur={cur} />
      {showRequest && (
        <div className="sc-request" style={{ opacity: 1 - span(t, 0.12, 0.2) }}>
          <span className="sc-request-key">⌃⌥</span>
          {typed(scene.request, t, 0, 0.1)}
        </div>
      )}
      {click && ripple < 1 && (
        <div
          className="sc-ripple"
          style={{ left: click.x, top: click.y, transform: `translate(-50%,-50%) scale(${0.3 + ripple * 1.4})`, opacity: 1 - ripple }}
        />
      )}
      {cur.down && <div className="sc-ripple sc-hold" style={{ left: cur.x, top: cur.y }} />}
      {!hideCursor && <CursorArrow className="sc-cursor" size={20} style={{ transform: `translate(${cur.x}px, ${cur.y}px)` }} />}
    </div>
    </StageCtx.Provider>
  )
}
