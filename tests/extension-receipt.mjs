// Effect receipts: a MutationObserver armed before an input reports what the page did in response.
import vm from 'node:vm';
import fs from 'node:fs';
import assert from 'node:assert/strict';

const observers = [];
class FakeObserver {
  constructor(callback) { this.callback = callback; this.active = false; observers.push(this); }
  observe() { this.active = true; }
  disconnect() { this.active = false; }
  takeRecords() { return []; }
}
const emit = records => { for (const o of observers) if (o.active) o.callback(records); };
// A tiny DOM: elements know their tag, role and parent, and match simple "tag, [role=x], [attr]" selectors.
function matches(el, selector) {
  return selector.split(',').map(p => p.trim()).some(part => {
    const attr = part.match(/^\[([\w-]+)(?:=([\w-]+))?\]$/);
    if (attr) return attr[1] === 'role' ? el.role === attr[2] : attr[2] === undefined ? !!el.attrs[attr[1]] : el.attrs[attr[1]] === attr[2];
    return /^[a-z]+$/.test(part) && el.tagName.toLowerCase() === part;
  });
}
const element = (innerText, tagName = 'DIV', parentNode = null, role = null, attrs = {}) => {
  const el = { nodeType: 1, tagName, innerText, parentNode, role, attrs, isConnected: true, value: undefined, checked: undefined,
    getAttribute: n => (n === 'role' ? role : attrs[n] ?? null), matches: sel => matches(el, sel), querySelector: () => null };
  return el;
};
const text = (data, parentNode) => ({ nodeType: 3, data, parentNode });

let dialogs = [];
const body = element('', 'BODY');
const page = vm.createContext({
  MutationObserver: FakeObserver, window: {}, crypto: { randomUUID: () => 'doc' }, innerWidth: 1280, innerHeight: 900,
  performance: { now: () => Date.now() }, setTimeout, clearTimeout,
  location: { href: 'https://shop.test/item' },
  document: { activeElement: null, body, documentElement: {}, querySelectorAll: selector => selector.includes('dialog') ? dialogs : [] },
  getComputedStyle: () => ({ display: 'block', visibility: 'visible', opacity: '1' }),
});
vm.runInContext(fs.readFileSync(new URL('../extension/page.js', import.meta.url), 'utf8'), page);
const api = page.window.__clinqy;
// The listed target w0: a button in a cart row (li > div > button), elsewhere a live news ticker and a clock.
const row = element('', 'LI', body);
const cell = element('', 'DIV', row);
const button = element('Add', 'BUTTON', cell);
const ticker = element('', 'DIV', body, 'status', { 'aria-live': 'polite' });
const sidebar = element('', 'ASIDE', body);
page.window.__clinqyList = [button];
// The identity page.js derives for this button (role, name, question, tag, id, name/type/href/formaction/aria-controls).
page.window.__clinqySigs = [{ identity: JSON.stringify(['button', 'Add', '', 'BUTTON', '', null, null, null, null, null]) }];

// A click that opens a dialog with a confirmation: the new dialog's text counts even far from the target.
api.receiptArm('t1', 0);
const dialog = element('Item added to your cart', 'DIV', body, 'dialog');
emit([{ type: 'childList', target: body, addedNodes: [dialog], removedNodes: [] }]);
dialogs = [{ getAttribute: () => null, getBoundingClientRect: () => ({ left: 0, top: 0, right: 400, bottom: 300, width: 400, height: 300 }) }];
let r = await api.receiptCollect('t1', 40, 400);
assert.equal(r.dialogOpened, true);
assert.match(r.addedText, /Item added to your cart/);
assert.equal(r.structural, true);
assert.equal(r.urlChanged, false);
assert.ok(r.mutationCount >= 1);
console.log('PASS receipt reports a newly opened dialog with its text and structural change');

// Text edits inside the target's container report old and new text; scripts/styles are ignored.
dialogs = [];
api.receiptArm('t2', 0);
emit([{ type: 'characterData', target: text('Step 2 of 3', cell), oldValue: 'Step 1 of 3' },
      { type: 'childList', target: row, addedNodes: [element('var x = 1', 'SCRIPT', row)], removedNodes: [] }]);
r = await api.receiptCollect('t2', 40, 400);
assert.equal(r.addedText, 'Step 2 of 3');
assert.equal(r.removedText, 'Step 1 of 3');
assert.equal(r.dialogOpened, false);
assert.ok(!r.addedText.includes('var x'));
console.log('PASS receipt reports changed text in the target container, skips script content');

// Unrelated churn: a ticker (aria-live) and a sidebar elsewhere, and time-ago text even next to the target.
api.receiptArm('t2b', 0);
emit([{ type: 'childList', target: ticker, addedNodes: [element('Markets up 2% on earnings news', 'SPAN', ticker)], removedNodes: [] },
      { type: 'characterData', target: text('New message from Sam', sidebar), oldValue: 'Hello' },
      { type: 'characterData', target: text('4 seconds ago', cell), oldValue: '3 seconds ago' },
      { type: 'characterData', target: text('Updated just now', cell), oldValue: 'Updated 1 min ago' }]);
r = await api.receiptCollect('t2b', 40, 400);
assert.equal(r.addedText, '', 'text outside the target container and time-ago churn are not the click\'s effect');
assert.equal(r.removedText, '');
assert.ok(r.mutationCount >= 4, 'mutations still count for settle waits');
console.log('PASS ticker, unrelated live region and time-ago churn are ignored');

// Without a target (a frame-level watch), only new popups count; focus moving into new content is reported.
api.receiptArm('t2c', null);
const panel = element('', 'SECTION', body);
const field = element('', 'INPUT', panel);
emit([{ type: 'childList', target: body, addedNodes: [panel, element('Cookie banner text', 'DIV', body)], removedNodes: [] }]);
page.document.activeElement = field;
r = await api.receiptCollect('t2c', 40, 400);
assert.equal(r.addedText, '');
assert.equal(r.focusIntoNew, true);
assert.equal(r.focusChanged, true);
page.document.activeElement = null;
api.receiptArm('t2d', 0);
page.document.activeElement = button;
r = await api.receiptCollect('t2d', 40, 400);
assert.equal(r.focusIntoNew, false, 'focus on an existing control is not new content');
page.document.activeElement = null;
console.log('PASS frame-level receipts count only popups; focus into new content is reported');

// A quiet page: no mutations, URL unchanged, listing stays valid.
api.receiptArm('t3', null);
const started = Date.now();
r = await api.receiptCollect('t3', 40, 400);
assert.equal(r.mutationCount, 0);
assert.equal(r.structural, false);
assert.equal(r.addedText, '');
assert.ok(Date.now() - started < 300, 'a quiet page returns after the quiet window, not the cap');
console.log('PASS quiet page returns quickly with no effect');

// Navigation in the same document (SPA) is reported; the receipt is single use.
api.receiptArm('t4', null);
page.location.href = 'https://shop.test/cart';
r = await api.receiptCollect('t4', 40, 400);
assert.equal(r.urlChanged, true);
assert.throws(() => api.receiptCollect('t4', 40, 400), /no armed receipt/);
assert.throws(() => api.receiptArm('', null), /token/);
console.log('PASS URL change reported; receipts are single use and need a token');

// Continuous churn still returns at the cap.
api.receiptArm('t5', null);
const churn = setInterval(() => emit([{ type: 'attributes' }]), 10);
const capped = Date.now();
r = await api.receiptCollect('t5', 60, 250);
clearInterval(churn);
assert.ok(Date.now() - capped < 600, 'collection is capped');
assert.ok(r.mutationCount > 0 && r.addedText === '');
console.log('PASS busy page is capped and attribute churn carries no text');

// Bridge: the collect command merges frames and survives a navigated document.
const event = { addListener() {} };
const tabsGet = { url: 'https://shop.test/item' };
const worker = vm.createContext({ chrome: { runtime: { onStartup: event, onInstalled: event, getManifest: () => ({ version: 'test' }) },
  alarms: { create() {}, onAlarm: event }, tabs: { onRemoved: event, get: async () => tabsGet }, debugger: { onDetach: event, onEvent: event },
  storage: { session: { get: async () => ({}), set: async () => {} } } },
  WebSocket: class {}, navigator: {}, setTimeout, clearTimeout, setInterval() {}, console, URL });
vm.runInContext(fs.readFileSync(new URL('../extension/bridge.js', import.meta.url), 'utf8'), worker);
assert.equal(typeof worker.receiptCollect, 'function');
vm.runInContext("receiptsArmed.set('rX', { tabId: 5, url: 'https://shop.test/item', frames: [0, 3], at: Date.now() })", worker);
worker.call = async (tabId, frameId) => {
  if (frameId === 3) throw Error('frame navigated');
  return { urlChanged: false, targetStateChanged: true, addedText: 'Added', removedText: '', mutationCount: 2, structural: false };
};
tabsGet.url = 'https://shop.test/cart';
r = await worker.receiptCollect({ id: 5 }, { token: 'rX' });
assert.equal(r.targetStateChanged, true);
assert.equal(r.unreadable, true);
assert.equal(r.urlChanged, true);
assert.equal(r.addedText, 'Added');
await assert.rejects(worker.receiptCollect({ id: 5 }, { token: 'rX' }), /no armed receipt/);
console.log('PASS bridge merges frame receipts, flags an unreadable frame and a tab URL change');
