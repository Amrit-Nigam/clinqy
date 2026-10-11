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

function Desktop({ title, children }: { title: string; children: React.ReactNode }) {
  const { bare, app } = useContext(StageCtx)
  return (
    <div className={'sc-desktop' + (bare ? ' is-bare' : '')}>
      {!bare && <MenuBar app={app} />}
      <div className="sc-window">
        <div className="sc-titlebar">
          <i style={{ background: '#ff5f57' }} />
          <i style={{ background: '#febc2e' }} />
          <i style={{ background: '#28c840' }} />
          <span>{title}</span>
        </div>
        <div className="sc-content">{children}</div>
      </div>
    </div>
  )
}

function Field({ x, y, w = 300, label, value, active }: { x: number; y: number; w?: number; label: string; value: string; active?: boolean }) {
  return (
    <div className="sc-field" style={{ left: x, top: y, width: w }}>
      <label>{label}</label>
      <div className={'sc-input' + (active ? ' is-active' : '')}>
        {value}
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
  const rows = [
    ['IndiGo 6E 2131', '06:10', '₹4,860'],
    ['Air India AI 805', '08:45', '₹5,320'],
    ['Vistara UK 943', '13:20', '₹6,110'],
    ['Akasa QP 1104', '19:05', '₹4,420'],
  ]
  return (
    <Desktop title="Flights to Mumbai">
      <div className="sc-url">flights.example.com/del-bom</div>
      <h3 className="sc-h" style={{ left: 30, top: 50 }}>Delhi to Mumbai, Fri 17 Oct</h3>
      {rows.map((r, i) => (
        <div key={i} className="sc-row" style={{ left: 30, top: 92 + i * 52 }}>
          <span className="sc-dot" />
          <b>{r[0]}</b>
          <span>{r[1]}</span>
          <em>{r[2]}</em>
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
    <Desktop title="beach.jpg">
      <div
        className="sc-photo"
        style={{ filter: `brightness(${0.62 + dragP * 0.55}) saturate(${0.7 + warm * 0.6})` }}
      >
        <div className="sc-sun" />
        <div className="sc-sea" />
        <div className="sc-sand" />
      </div>
      <div className="sc-panel">
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
        <div className={'sc-btn sc-btn-blue' + (t > 0.84 && t < 0.9 ? ' is-pressed' : '')} style={{ left: 18, top: 308, width: 96 }}>Export</div>
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
    <Desktop title="EC2 · Launch an instance">
      <div className="sc-url">console.aws.amazon.com/ec2/launch</div>
      <div className="sc-aws-bar">Console <span>›</span> EC2 <span>›</span> Launch an instance</div>
      <Field x={30} y={118} label="Name" value={name} active={t > 0.1 && t < 0.42} />
      <div className="sc-field" style={{ left: 30, top: 188, width: 300 }}>
        <label>Instance type</label>
        <div className={'sc-input sc-select' + (open ? ' is-active' : '')}>{picked ? 't3.micro' : 't2.nano'}</div>
      </div>
      {open && (
        <div className="sc-dropdown" style={{ left: 30, top: 236 }}>
          <div>t2.nano</div>
          <div className={t > 0.55 ? 'is-hover' : ''}>t3.micro <small>Free tier</small></div>
          <div>t3.large</div>
        </div>
      )}
      <div className="sc-field" style={{ left: 360, top: 118, width: 190 }}>
        <label>Region</label>
        <div className="sc-input">ap-south-1</div>
      </div>
      <div className={'sc-btn sc-btn-orange' + (t > 0.74 && t < 0.78 ? ' is-pressed' : '')} style={{ left: 410, top: 324, width: 140 }}>Launch instance</div>
      {confirm > 0 && (
        <div className="sc-ask" style={{ opacity: confirm, transform: `scale(${0.94 + confirm * 0.06})` }}>
          <b>Launch tf-server (t3.micro)?</b>
          <span>This starts a billable instance.</span>
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
    <Desktop title="Careers · Product Designer">
      <div className="sc-url">jobs.example.com/apply/product-designer</div>
      <h3 className="sc-h" style={{ left: 30, top: 46 }}>Product Designer, Bengaluru</h3>
      <Field x={30} y={106} label="Full name" value={nameV} active={t > 0.07 && t < 0.29} />
      <Field x={30} y={168} label="Email" value={mailV} active={t > 0.3 && t < 0.5} />
      <div className="sc-field" style={{ left: 30, top: 230, width: 300 }}>
        <label>Resume</label>
        <div className="sc-upload">
          <span className="sc-btn-mini">Upload</span>
          {uploaded ? <em>resume.pdf · 182 KB</em> : <small>No file chosen</small>}
        </div>
      </div>
      <div className="sc-check" style={{ left: 30, top: 306 }}>
        <span className={ticked ? 'is-on' : ''}>{ticked ? '✓' : ''}</span>
        I agree to the privacy notice
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
  const chats = [
    ['Mom', 'Call me when you’re free'],
    ['Raj', 'Sent the deck'],
    ['Priya', 'Thursday works'],
    ['Design team', 'New mocks are up'],
  ]
  return (
    <Desktop title="WhatsApp">
      <div className="sc-chats">
        <b className="sc-chats-title">Chats</b>
        {chats.map(([n, m], i) => (
          <div key={n} className={'sc-chat' + (open && i === 0 ? ' is-open' : '')} style={{ top: 50 + i * 48 }}>
            <span className="sc-avatar">{n[0]}</span>
            <div><b>{n}</b><small>{m}</small></div>
          </div>
        ))}
      </div>
      {open && (
        <div className="sc-thread">
          <div className="sc-bubble">Call me when you’re free</div>
          {sent > 0 && (
            <div className="sc-bubble is-me" style={{ opacity: sent, transform: `translateY(${(1 - sent) * 10}px)` }}>
              I’ll be late, stuck in traffic <small>✓✓</small>
            </div>
          )}
        </div>
      )}
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
  const days = ['Mon 13', 'Tue 14', 'Wed 15', 'Thu 16', 'Fri 17']
  const busy: [number, number, number, string][] = [
    [0, 0, 1, 'Standup'],
    [1, 1, 3, 'Workshop'],
    [2, 0, 2, 'Reviews'],
    [3, 0, 2, 'Interviews'],
    [3, 3, 4, '1:1 with Sam'],
    [4, 1, 2, 'Lunch'],
  ]
  const scanning = t >= 0.22 && t < 0.56
  const booked = easeOut(span(t, 0.57, 0.66))
  const toast = easeOut(span(t, 0.68, 0.76))
  const ROW = 60
  return (
    <Desktop title="Calendar">
      {days.map((d, i) => (
        <div key={d} className="sc-cal-day" style={{ left: 60 + i * 96, top: 14 }}>{d}</div>
      ))}
      {['1 PM', '2 PM', '3 PM', '4 PM', '5 PM'].map((h, i) => (
        <div key={h} className="sc-cal-hour" style={{ top: 46 + i * ROW }}>{h}</div>
      ))}
      <div className="sc-cal-grid" />
      {busy.map(([d, a, b, n]) => (
        <div key={n} className="sc-cal-ev" style={{ left: 62 + d * 96, top: 50 + a * ROW, height: (b - a) * ROW - 4 }}>{n}</div>
      ))}
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
const FILES: [string, number][] = [
  ['invoice-sept.pdf', 0],
  ['beach.jpg', 1],
  ['Zoom.pkg', 2],
  ['offer-letter.pdf', 0],
  ['screenshot.png', 1],
  ['resume.pdf', 0],
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
      {FILES.map(([name], i) => {
        const gone = t >= landed[i]
        const fading = i >= 3 ? 1 - span(t, landed[i] - 0.04, landed[i]) : gone ? 0 : 1
        return (
          <div key={name} className="sc-file" style={{ left: 20, top: 20 + i * 40, opacity: dragging === i ? 0.3 : fading }}>
            <span className={'sc-file-ico ' + name.split('.')[1]} />
            {name}
          </div>
        )
      })}
      {folders.map((f, j) => (
        <div key={f} className={'sc-folder' + (dragging >= 0 && FILES[dragging][1] === j ? ' is-target' : '')} style={{ left: 340, top: 30 + j * 90 }}>
          <span className="sc-folder-ico" />
          <div><b>{f}</b><small>{counts[j]} {counts[j] === 1 ? 'file' : 'files'}</small></div>
        </div>
      ))}
      {dragging >= 0 && (
        <div className="sc-file is-ghost" style={{ left: cur.x - 40 - 60, top: cur.y - 64 - 17 }}>
          <span className={'sc-file-ico ' + FILES[dragging][0].split('.')[1]} />
          {FILES[dragging][0]}
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
export function SceneStage({ scene, t, showRequest = true, bare = false }: { scene: Scene; t: number; showRequest?: boolean; bare?: boolean }) {
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
      <CursorArrow className="sc-cursor" size={20} style={{ transform: `translate(${cur.x}px, ${cur.y}px)` }} />
    </div>
    </StageCtx.Provider>
  )
}
