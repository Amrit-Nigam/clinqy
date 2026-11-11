// Round-5 J fixture: a sibling <input type=checkbox class=hidden> (opacity 0, 1px, clip-path inset(50%)) with a
// separate <label for=consent> that draws the box. Clicking the label must report the hidden input's state flip in
// the effect receipt (so the click is CONFIRMED and doesn't hold the barrier before Apply), and value() must read
// the box's checked state so "verify w0 checked" can succeed.
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
const form = new El('form', { rect: { left: 24, top: 100, width: 540, height: 600 }, parent: body });
const field = (label, id, top, type) => {
  const l = new El('label', { attrs: { class: 'field' }, text: label, rect: { left: 32, top, width: 533, height: 70 }, parent: form });
  const i = new El('input', { attrs: { id, ...(type ? { type } : {}), required: '' }, rect: { left: 32, top: top + 28, width: 533, height: 41 }, parent: l, props: { value: '', required: true } });
  i.labels = [l];
  return i;
};
field('First name', 'first', 155); field('Last name', 'last', 230); field('Email', 'email', 305, 'email'); field('Phone', 'phone', 380, 'tel');
// <input type=checkbox id=consent class=hidden><label id=consentLabel for=consent>I consent to share my details</label>
const consent = new El('input', { attrs: { type: 'checkbox', id: 'consent', class: 'hidden' }, rect: { left: 32, top: 462, width: 1, height: 1 },
  style: { position: 'absolute', opacity: '0', clipPath: 'inset(50%)' }, parent: form, props: { checked: false } });
const consentLabel = new El('label', { attrs: { id: 'consentLabel', for: 'consent' }, text: 'I consent to share my details',
  rect: { left: 32, top: 462, width: 540, height: 61 }, parent: form });
consent.labels = [consentLabel];
// Clicking the label toggles the input (what the browser's label activation does), then the page reacts.
const apply = new El('button', { attrs: { id: 'apply', type: 'submit', disabled: '' }, text: 'Apply', rect: { left: 32, top: 620, width: 90, height: 44 }, parent: form, props: { disabled: true } });
consentLabel.click = () => { consent.checked = !consent.checked; consent.dispatchEvent({ type: 'change' }); };
consent.addEventListener('change', () => { apply.disabled = !consent.checked; });

const document = {
  body, documentElement: html, activeElement: body, readyState: 'complete', title: 'Clinqy Job Application J1',
  hasFocus: () => false,
  querySelectorAll: sel => [html, ...html.descendants()].filter(e => e.matches(sel)),
  querySelector: sel => document.querySelectorAll(sel)[0] || null,
  getElementById: id => all.find(e => e.attrs.id === id) || null,
  elementFromPoint: (x, y) => {
    const hits = [html, ...html.descendants()].filter(e => { const r = e.getBoundingClientRect(); return r.width > 2 && x >= r.left && x < r.right && y >= r.top && y < r.bottom; });
    return hits[hits.length - 1] || null;
  },
  createTreeWalker: (root, what) => {
    const start = root === document ? html : root;
    const list = what === 4 ? [] : [start, ...start.descendants()];
    let i = what === 4 ? -1 : 0;
    return { nextNode: () => list[++i] || null };
  },
};
const context = vm.createContext({
  window: {}, document, crypto: { randomUUID: () => 'doc' }, innerWidth: 1280, innerHeight: 800, scrollX: 0, scrollY: 0,
  screenX: 0, screenY: 0, outerWidth: 1280, outerHeight: 900, devicePixelRatio: 2, location: { href: 'http://127.0.0.1:58834/?key=k' },
  performance: { now: () => Date.now() }, setTimeout, clearTimeout,
  MutationObserver: class { observe() {} disconnect() {} takeRecords() { return []; } },
  NodeFilter: { SHOW_ELEMENT: 1, SHOW_TEXT: 4 }, getComputedStyle: el => el.style,
  Event: class { constructor(type) { this.type = type; } }, PointerEvent: class {}, MouseEvent: class {},
});
vm.runInContext(fs.readFileSync(new URL('../extension/page.js', import.meta.url), 'utf8'), context);
const api = context.window.__clinqy;

const snap = api.snapshot();
const item = snap.elements.find(e => e.text === 'I consent to share my details');
assert.ok(item, 'the for= label is listed for the hidden checkbox: ' + JSON.stringify(snap.elements.map(e => e.text)));
assert.equal(item.role, 'checkbox'); assert.equal(item.proxy, true); assert.equal(item.unchecked, true);
assert.equal(snap.elements.filter(e => /consent/i.test(e.text)).length, 1, 'the hidden input is not listed separately');
assert.equal(api.value(item.i).value, 'unchecked', 'value reads the proxied input before the click');
const before = api.state(item.i).sig;

// The click as Clinqy delivers it: receipt armed, label clicked once, receipt collected.
api.receiptArm('t1', item.i);
consentLabel.click();
const receipt = await api.receiptCollect('t1', 30, 60);
assert.equal(consent.checked, true, 'one click ticks the box');
assert.equal(receipt.targetStateChanged, true, 'the receipt sees the hidden input flip through the proxy: ' + JSON.stringify(receipt));
assert.notEqual(api.state(item.i).sig, before, 'state signature includes the underlying input');
assert.equal(api.value(item.i).value, 'checked', 'value reads checked after the click (verify w0 checked can resolve)');
assert.equal(apply.disabled, false, 'Apply is enabled once consent is ticked');

// Unticking is seen the same way, and a receipt with no click reports no change.
api.receiptArm('t2', item.i);
const idle = await api.receiptCollect('t2', 30, 60);
assert.equal(idle.targetStateChanged, false, 'no click, no state change');
api.receiptArm('t3', item.i);
consentLabel.click();
assert.equal((await api.receiptCollect('t3', 30, 60)).targetStateChanged, true, 'unticking flips the state too');
assert.equal(api.value(item.i).value, 'unchecked');
console.log('PASS styled for= label checkbox: receipt and value read the hidden input (J fixture)');
