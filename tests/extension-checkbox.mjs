// Styled tick boxes and hidden file inputs: the visible label/wrapper of a hidden <input type=checkbox> is listed
// (with the input's checked state), empty role=checkbox controls borrow their caption, and an upload button
// resolves to the hidden file input beside it, with a readback that survives the page resetting that input.
import vm from 'node:vm';
import fs from 'node:fs';
import assert from 'node:assert/strict';

// --- A tiny DOM: enough for snapshot(), describe(), target(), state() and the upload helpers. ---
function parsePart(part) {
  const nots = [];
  part = part.replace(/:not\(([^)]*)\)/g, (_, inner) => { nots.push(parsePart(inner)); return ''; });
  const tag = (part.match(/^[a-z*]+/i) || [''])[0].toLowerCase();
  const attrs = [...part.matchAll(/\[([\w-]+)(?:=(?:'([^']*)'|"([^"]*)"|([^\]]*)))?\]/g)].map(m => [m[1], m[2] ?? m[3] ?? m[4]]);
  return { tag, attrs, nots };
}
function matchPart(el, p) {
  if (p.tag && p.tag !== '*' && el.tagName.toLowerCase() !== p.tag) return false;
  for (const [name, value] of p.attrs) {
    const have = el.getAttribute(name);
    if (have === null) return false;
    if (value !== undefined && have !== value) return false;
  }
  return !p.nots.some(n => matchPart(el, n));
}
const matches = (el, selector) => selector.split(',').map(s => s.trim()).filter(Boolean).some(s => {
  if (/\s|>/.test(s.replace(/\[[^\]]*\]/g, ''))) return false;   // descendant selectors aren't needed here
  return matchPart(el, parsePart(s));
});

let all = [];
const textNodes = [];
class El {
  constructor(tagName, { attrs = {}, text = '', rect = null, style = {}, parent = null, props = {} } = {}) {
    this.nodeType = 1; this.tagName = tagName.toUpperCase(); this.attrs = { ...attrs }; this.ownText = text;
    this.rect = rect; this.style = { display: 'block', visibility: 'visible', opacity: '1', position: 'static', overflowY: 'visible', ...style };
    this.children = []; this.parentElement = null; this.isConnected = true; this.isContentEditable = false;
    this.scrollHeight = 0; this.clientHeight = 0; this.labels = [];
    Object.assign(this, props);
    if (parent) parent.append(this);
    all.push(this);
  }
  get parentNode() { return this.parentElement; }
  append(child) { child.parentElement = this; this.children.push(child); return child; }
  get type() { return this.attrs.type || (this.tagName === 'INPUT' ? 'text' : ''); }
  get innerText() {
    if (this.style.display === 'none') return '';
    return [this.ownText, ...this.children.map(c => c.innerText)].filter(Boolean).join(' ');
  }
  getAttribute(n) { return n in this.attrs ? String(this.attrs[n]) : null; }
  hasAttribute(n) { return n in this.attrs; }
  setAttribute(n, v) { this.attrs[n] = String(v); }
  removeAttribute(n) { delete this.attrs[n]; }
  matches(sel) { return matches(this, sel); }
  closest(sel) { for (let n = this; n; n = n.parentElement) if (n.matches(sel)) return n; return null; }
  contains(n) { for (; n; n = n.parentElement) if (n === this) return true; return false; }
  descendants() { return this.children.flatMap(c => [c, ...c.descendants()]); }
  querySelectorAll(sel) { return this.descendants().filter(e => e.matches(sel)); }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  getBoundingClientRect() {
    const r = this.style.display === 'none' ? { left: 0, top: 0, width: 0, height: 0 } : (this.rect || { left: 0, top: 0, width: 0, height: 0 });
    return { ...r, x: r.left, y: r.top, right: r.left + r.width, bottom: r.top + r.height };
  }
  getClientRects() { const r = this.getBoundingClientRect(); return r.width || r.height ? [r] : []; }
  getRootNode() { return document; }
  scrollIntoView() {}
  focus() { document.activeElement = this; }
  dispatchEvent(event) { (this.listeners?.[event.type] || []).forEach(f => f(event)); return true; }
  addEventListener(type, f) { (this.listeners ||= {})[type] = [...(this.listeners?.[type] || []), f]; }
  click() {}
}

const html = new El('html', { rect: { left: 0, top: 0, width: 1280, height: 800 } });
const body = new El('body', { rect: { left: 0, top: 0, width: 1280, height: 800 }, parent: html });
const form = new El('form', { rect: { left: 0, top: 0, width: 800, height: 600 }, parent: body });

// MUI-style: <label><span><input type=checkbox opacity:0 1px></span><span>I consent…</span></label>
const consentLabel = new El('label', { rect: { left: 20, top: 500, width: 300, height: 24 }, parent: form });
const box = new El('span', { rect: { left: 20, top: 502, width: 20, height: 20 }, parent: consentLabel });
const consent = new El('input', { attrs: { type: 'checkbox', name: 'consent', required: '' }, rect: { left: 20, top: 502, width: 1, height: 1 },
  style: { opacity: '0', position: 'absolute' }, parent: box, props: { checked: false, required: true } });
new El('span', { text: 'I consent to share my details', rect: { left: 44, top: 502, width: 260, height: 20 }, parent: consentLabel });
consent.labels = [consentLabel];

// An empty role=checkbox with its caption beside it.
const row = new El('div', { rect: { left: 20, top: 540, width: 300, height: 24 }, parent: form });
const toggle = new El('div', { attrs: { role: 'checkbox', 'aria-checked': 'false', tabindex: '0' }, rect: { left: 20, top: 542, width: 20, height: 20 }, parent: row });
new El('span', { text: 'Subscribe to updates', rect: { left: 44, top: 542, width: 200, height: 20 }, parent: row });

// A custom upload button with the real file input hidden beside it.
const uploadRow = new El('div', { rect: { left: 20, top: 400, width: 400, height: 40 }, parent: form });
const uploadButton = new El('button', { text: 'Upload resume', rect: { left: 20, top: 400, width: 140, height: 36 }, parent: uploadRow });
const fileInput = new El('input', { attrs: { type: 'file', accept: '.pdf' }, style: { display: 'none' }, parent: uploadRow, props: { multiple: false, accept: '.pdf' } });
let fileList = [];
Object.defineProperty(fileInput, 'files', { get: () => fileList, set: v => { fileList = [...v]; } });
const status = new El('div', { rect: { left: 20, top: 450, width: 400, height: 20 }, parent: uploadRow });

const document = {
  body, documentElement: html, activeElement: body, readyState: 'complete', title: 'Apply',
  hasFocus: () => false,
  querySelectorAll: sel => [html, ...html.descendants()].filter(e => e.matches(sel)),
  querySelector: sel => document.querySelectorAll(sel)[0] || null,
  getElementById: id => all.find(e => e.attrs.id === id) || null,
  elementFromPoint: (x, y) => {
    const hits = [html, ...html.descendants()].filter(e => { const r = e.getBoundingClientRect(); return r.width && x >= r.left && x < r.right && y >= r.top && y < r.bottom; });
    return hits[hits.length - 1] || null;
  },
  createTreeWalker: (root, what) => {
    const start = root === document ? html : root;
    const list = what === 4 ? [] : [start, ...start.descendants()];
    let i = what === 4 ? -1 : 0;
    return { nextNode: () => list[++i] || null };
  },
};
class DataTransfer { constructor() { const files = []; this.files = files; this.items = { add: f => files.push(f) }; } }
class File { constructor(parts, name, opts) { this.name = name; this.size = parts.reduce((n, p) => n + (p.length || 0), 0); this.type = opts.type; } }
const context = vm.createContext({
  window: {}, document, crypto: { randomUUID: () => 'doc' }, innerWidth: 1280, innerHeight: 800, scrollX: 0, scrollY: 0,
  screenX: 0, screenY: 0, outerWidth: 1280, outerHeight: 900, devicePixelRatio: 2, location: { href: 'https://jobs.test/apply' },
  performance: { now: () => Date.now() }, setTimeout, clearTimeout, atob: s => Buffer.from(s, 'base64').toString('binary'),
  MutationObserver: class { observe() {} disconnect() {} takeRecords() { return []; } },
  NodeFilter: { SHOW_ELEMENT: 1, SHOW_TEXT: 4 }, getComputedStyle: el => el.style, DataTransfer, File,
  Event: class { constructor(type) { this.type = type; } }, PointerEvent: class {}, MouseEvent: class {},
});
vm.runInContext(fs.readFileSync(new URL('../extension/page.js', import.meta.url), 'utf8'), context);
const api = context.window.__clinqy;

// --- Snapshot: the visible label stands in for the hidden checkbox. ---
let snap = api.snapshot();
const consentItem = snap.elements.find(e => /I consent to share my details/.test(e.text));
assert.ok(consentItem, 'the consent label is listed: ' + JSON.stringify(snap.elements.map(e => e.text)));
assert.equal(consentItem.role, 'checkbox');
assert.equal(consentItem.unchecked, true);
assert.equal(consentItem.required, true);
assert.equal(consentItem.proxy, true);
assert.equal(snap.elements.filter(e => e.role === 'checkbox' && /consent/i.test(e.text)).length, 1, 'listed once, not twice');
assert.ok(consentItem.w >= 100, 'the click lands on the visible label, not the 1px input');
const subscribe = snap.elements.find(e => e.text === 'Subscribe to updates');
assert.ok(subscribe && subscribe.role === 'checkbox' && subscribe.unchecked, 'an empty role=checkbox borrows its caption');

// State readback follows the hidden input.
const before = api.state(consentItem.i).sig;
consent.checked = true;
assert.notEqual(api.state(consentItem.i).sig, before, 'state changes when the hidden input is ticked');
snap = api.snapshot();
assert.equal(snap.elements.find(e => /I consent/.test(e.text)).checked, true, 'snapshot reads checked from the input');

// --- Uploads: a button resolves to the hidden input beside it. ---
const buttonItem = snap.elements.find(e => e.text === 'Upload resume');
assert.ok(buttonItem, 'upload button listed');
const mark = api.markFileInput(buttonItem.i, 'cv.pdf');
assert.equal(fileInput.getAttribute('data-clinqy-file'), mark.token, 'the hidden file input is tagged for the browser');
assert.equal(mark.shownBefore, false);
fileList = [{ name: 'cv.pdf', size: 3, type: 'application/pdf' }];   // what DOM.setFileInputFiles would do
let r = await api.fileReadback(mark.token, 'cv.pdf', 3, false);
assert.equal(r.ok, true); assert.equal(r.held, true); assert.equal(fileInput.getAttribute('data-clinqy-file'), null, 'tag removed');

// A page that reads the file, shows its name and resets the input: still confirmed, by the page text.
fileList = [];
fileInput.addEventListener('change', () => { status.ownText = fileInput.files[0].name + ' ✓'; fileList = []; });
r = await api.upload(buttonItem.i, 'resume.pdf', 'application/pdf', Buffer.from('abcd').toString('base64'));
assert.equal(r.assigned, true, 'the input took the file before the page handler ran');
assert.equal(r.held, false); assert.equal(r.shown, true); assert.equal(r.ok, true); assert.equal(r.cleared, true);

// A page that resets the input and shows nothing: delivered, not confirmed.
status.ownText = ''; fileInput.listeners.change = [() => { fileList = []; }];
r = await api.upload(buttonItem.i, 'other.pdf', 'application/pdf', Buffer.from('xy').toString('base64'));
assert.equal(r.assigned, true); assert.equal(r.ok, false);
console.log('PASS custom checkbox proxies and hidden file input uploads');
