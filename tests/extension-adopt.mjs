// Adopting the user's own open tab for one run: ownership, focus emulation, release on real user input,
// never activating the tab or its window, and blocked origins refused. Production worker, mocked browser APIs.
import vm from 'node:vm';
import fs from 'node:fs';
import assert from 'node:assert/strict';
const calls = [], sent = [];
const event = { addListener() {} };
const listeners = { message: [], activated: [], removed: [] };
const data = {};
const storage = {
  async get(key) { if (Array.isArray(key)) return Object.fromEntries(key.map(k => [k, data[k]])); return { [key]: data[key] }; },
  async set(values) { Object.assign(data, structuredClone(values)); },
  async remove(keys) { for (const k of [].concat(keys)) delete data[k]; }
};
const tabs = new Map([
  [1, { id: 1, windowId: 5, active: true, url: 'https://github.com/me/repo', title: 'repo' }],
  [2, { id: 2, windowId: 5, active: false, url: 'https://chase.com/accounts', title: 'Bank' }],
  [3, { id: 3, windowId: 7, active: true, url: 'chrome://newtab/', title: 'New Tab' }],
  [4, { id: 4, windowId: 7, active: false, url: 'https://mail.test/inbox', title: 'Inbox' }],
]);
let next = 20;
const scripted = [];
const chrome = {
  scripting: { async executeScript(args) { scripted.push(args); return []; } },
  storage: { session: storage, local: storage },
  runtime: { onStartup: event, onInstalled: event, onMessage: { addListener: f => listeners.message.push(f) }, getManifest: () => ({ version: 'x' }) },
  alarms: { create() {}, onAlarm: event },
  tabs: {
    onRemoved: { addListener: f => listeners.removed.push(f) },
    onActivated: { addListener: f => listeners.activated.push(f) },
    async query(q) { return [...tabs.values()].filter(t => !q.active || (t.active && t.windowId === 5)); },
    async get(id) { if (!tabs.has(id)) throw Error('closed'); return tabs.get(id); },
    async create(args) { calls.push(['create', args]); const t = { id: next++, windowId: 5, ...args }; tabs.set(t.id, t); return t; },
    async update(id, args) { calls.push(['update', id, args]); Object.assign(tabs.get(id), args); return tabs.get(id); },
    async remove(id) { calls.push(['remove', id]); tabs.delete(id); },
    async group() { return 8; }
  },
  tabGroups: { async query() { return []; }, async update() {} },
  windows: { async get() { return { focused: false }; }, async update(...args) { calls.push(['focusWindow', ...args]); } },
  debugger: {
    onDetach: event, onEvent: event,
    async attach(target) { calls.push(['attach', target.tabId]); },
    async detach(target) { calls.push(['detach', target.tabId]); },
    async sendCommand(target, method, params) { calls.push([method, target.tabId, params]); return { data: 'PNG' }; }
  }
};
class WebSocket {
  static CONNECTING = 0; static OPEN = 1;
  constructor() { this.readyState = 1; WebSocket.last = this; }
  send(text) { sent.push(JSON.parse(text)); }
}
const context = vm.createContext({ chrome, WebSocket, URL, navigator: {}, crypto, setTimeout, clearTimeout, setInterval() {}, console });
vm.runInContext(fs.readFileSync(new URL('../extension/bridge.js', import.meta.url), 'utf8'), context);
const settle = () => new Promise(resolve => setTimeout(resolve, 20));
const userInput = async (tabId, kind = 'pointerdown') => { for (const f of listeners.message) f({ clinqy: 'userInput', kind }, { tab: { id: tabId } }); await settle(); };
const focusChanges = () => calls.filter(c => c[0] === 'focusWindow' || (c[0] === 'update' && c[2].active));

// Adopting: same ownership structures as a task tab plus an adoption record; focus emulated; never activated.
const run = 'run-a';
const adopted = await context.handle({ cmd: 'adoptTab', tabId: 1, runID: run, expectedOrigin: 'https://github.com', blockedHosts: ['chase.com'] });
assert.equal(adopted.adopted, true);
assert.equal(adopted.id, 1);
assert(calls.some(c => c[0] === 'attach' && c[1] === 1));
assert(calls.some(c => c[0] === 'Emulation.setFocusEmulationEnabled' && c[1] === 1 && c[2].enabled));
assert(calls.some(c => c[0] === 'Page.setInterceptFileChooserDialog' && c[1] === 1 && c[2].enabled));
assert.equal(data.owner1, run);
assert(data.workTabs.includes(1));
assert.equal(data.adoptedTabs[1].runID, run);
assert(!(data.opened || []).includes(1), 'an adopted tab is never recorded as one Clinqy opened (so it is never closed)');
assert(data.activityTabs.includes(1), 'activity marker shown');
assert(scripted.some(s => s.args?.[0] === true && s.target.allFrames), 'user-input watcher armed in every frame');
assert.deepEqual(focusChanges(), [], 'adoption never activates the tab or focuses its window');
const listing = await context.handle({ cmd: 'tabs', workOnly: true, runID: run });
assert.deepEqual(Array.from(listing.tabs, t => [t.id, t.adopted]), [[1, true]]);
assert.equal((await context.handle({ cmd: 'captureTask', workOnly: true, runID: run, tabId: 1 })).image, 'PNG');
await assert.rejects(context.handle({ cmd: 'captureTask', workOnly: true, runID: 'run-b', tabId: 1 }), /does not belong/);
await assert.rejects(context.handle({ cmd: 'adoptTab', tabId: 1, runID: 'run-b' }), /another Clinqy task/);
console.log('PASS adopted tab gets run ownership, debugger with emulated focus and marker, without activation');

// Refusals: blocked origin, site changed since chosen, browser pages, and tabs nobody handed over.
const before = calls.filter(c => c[0] === 'attach').length;
await assert.rejects(context.handle({ cmd: 'adoptTab', tabId: 2, runID: run, blockedHosts: ['*bank*', 'chase.com'] }), /blocked list/);
await assert.rejects(context.handle({ cmd: 'adoptTab', tabId: 4, runID: run, expectedOrigin: 'https://other.test' }), /changed site/);
await assert.rejects(context.handle({ cmd: 'adoptTab', tabId: 3, runID: run }), /browser page/);
await assert.rejects(context.handle({ cmd: 'adoptTab', tabId: 4 }), /ownership token/);
assert.equal(calls.filter(c => c[0] === 'attach').length, before, 'refused adoptions never attach');
assert(!data.adoptedTabs[2] && !data.adoptedTabs[4] && data.owner2 === undefined);
await assert.rejects(context.handle({ cmd: 'captureTask', tabId: 4 }), /wasn't opened/);
console.log('PASS blocked origins, changed sites, browser pages and non-adopted user tabs are refused');

// Clinqy's own (trusted CDP) input is not the user's: no release while it is in flight or just after.
context.beginClinqyInput(1);
await userInput(1);
context.endClinqyInput(1);
await userInput(1, 'keydown');
assert(data.adoptedTabs[1], 'Clinqy input does not release the tab');
await new Promise(resolve => setTimeout(resolve, 450));
const detachesBefore = calls.filter(c => c[0] === 'detach' && c[1] === 1).length;
await userInput(1);
assert(!data.adoptedTabs[1], 'real user input releases at once');
assert(calls.filter(c => c[0] === 'detach' && c[1] === 1).length > detachesBefore);
assert(calls.some(c => c[0] === 'Emulation.setFocusEmulationEnabled' && c[1] === 1 && c[2].enabled === false), 'focus emulation restored');
assert(!data.workTabs.includes(1) && data.owner1 === undefined);
assert(!data.activityTabs.includes(1), 'marker removed');
assert(scripted.some(s => s.args?.[0] === false), 'watcher disarmed');
const notice = sent.find(m => m.type === 'adoptedReleased');
assert.deepEqual([notice.tabId, notice.runID, notice.reason], [1, run, 'input:pointerdown']);
await assert.rejects(context.handle({ cmd: 'captureTask', workOnly: true, runID: run, tabId: 1 }), /took tab 1 back/);
await assert.rejects(context.handle({ cmd: 'captureTask', tabId: 1 }), /took tab 1 back/);
assert(tabs.has(1) && tabs.get(1).active, 'the user keeps their tab');
console.log('PASS real user input releases instantly: detach, restore, marker removed, app told; further input refused');

// Hand-back re-adopts; selecting the tab is also a takeover.
await context.handle({ cmd: 'adoptTab', tabId: 1, runID: run });
assert(data.adoptedTabs[1]);
assert.equal((await context.handle({ cmd: 'captureTask', workOnly: true, runID: run, tabId: 1 })).image, 'PNG');
for (const f of listeners.activated) f({ tabId: 1, windowId: 5 });
await settle();
assert(!data.adoptedTabs[1]);
assert.equal(sent.filter(m => m.type === 'adoptedReleased').at(-1).reason, 'selected');
await context.handle({ cmd: 'adoptTab', tabId: 1, runID: run });
console.log('PASS hand-back re-adopts; user selecting the adopted tab releases it');

// Popups and other tabs of the window are unaffected; run end releases without closing or notifying.
const own = await context.handle({ cmd: 'clinqyTab', url: 'https://task.test', runID: run });
const candidates = await context.handle({ cmd: 'adoptCandidates' });
assert(!candidates.tabs.some(t => t.id === own.id || t.id === 1), 'task tabs are not candidates');
assert.deepEqual(JSON.parse(JSON.stringify(candidates.tabs.find(t => t.id === 4))), { id: 4, windowId: 7, title: 'Inbox', url: 'https://mail.test/inbox', active: false, lastFocusedWindow: false });
assert.equal(candidates.lastFocusedWindow, 5);
const notices = sent.length;
await context.handle({ cmd: 'clinqyDone', tabIds: [1, own.id] });
assert(!data.adoptedTabs[1] && !data.workTabs.includes(1));
assert(tabs.has(1), 'run end never closes the user tab');
assert.equal(sent.length, notices, 'ordinary run end is not a takeover');
await context.handle({ cmd: 'clinqyClear' });
assert(tabs.has(1));
assert.deepEqual(focusChanges(), [], 'nothing in the adoption lifecycle activated a tab or window');
console.log('PASS run end releases adopted tabs without closing them or reporting a takeover');

// Closing an adopted tab is reported, and its records go.
await context.handle({ cmd: 'adoptTab', tabId: 4, runID: run });
tabs.delete(4);
for (const f of listeners.removed) f(4);
await new Promise(resolve => setTimeout(resolve, 50));
assert(!data.adoptedTabs[4]);
assert.equal(sent.filter(m => m.type === 'adoptedReleased').at(-1).reason, 'closed');
console.log('PASS a closed adopted tab is reported and forgotten');
