// Popup ownership, closed popups and windowless task-tab creation, against the production worker with mocks.
import vm from 'node:vm';
import fs from 'node:fs';
import assert from 'node:assert/strict';
const calls = [];
const listeners = {};
const event = name => ({ addListener(fn) { if (name) listeners[name] = fn; } });
const data = {};
const storage = {
  async get(keys) {
    const list = Array.isArray(keys) ? keys : [keys];
    return Object.fromEntries(list.map(k => [k, data[k]]));
  },
  async set(values) { Object.assign(data, structuredClone(values)); },
  async remove(keys) { for (const k of [].concat(keys)) delete data[k]; }
};
const tabs = new Map([[1, { id: 1, windowId: 5, active: true, url: 'https://personal.test' }]]);
let next = 10, windows = [{ id: 5 }];
const chrome = {
  scripting: { async executeScript() { return []; } },
  storage: { session: storage, local: storage },
  runtime: { onStartup: event(), onInstalled: event() },
  alarms: { create() {}, onAlarm: event() },
  tabs: {
    onRemoved: event('removed'), onCreated: event('created'), onUpdated: event(),
    async query(q) { return [...tabs.values()].filter(t => t.active && (q.windowId == null || t.windowId === q.windowId)); },
    async get(id) { if (!tabs.has(id)) throw Error('No tab with id: ' + id); return tabs.get(id); },
    async create(args) {
      calls.push(['create', args]);
      if (args.windowId == null) throw Error('No current window');
      const t = { id: next++, ...args }; tabs.set(t.id, t); return t;
    },
    async update(id, args) { calls.push(['update', id, args]); return tabs.get(id); },
    async remove(id) { calls.push(['remove', id]); tabs.delete(id); },
    async group() { return 8; }
  },
  tabGroups: { async query() { return []; }, async update() {} },
  windows: {
    async get() { return { focused: false }; },
    async getAll() { return windows; },
    async update(...args) { calls.push(['focusWindow', ...args]); },
    async create(args) {
      calls.push(['createWindow', args]);
      const w = { id: 77 }; windows.push(w);
      const t = { id: next++, windowId: 77, active: true, url: args.url }; tabs.set(t.id, t);
      return { ...w, tabs: [t] };
    }
  },
  debugger: {
    onDetach: event(), onEvent: event(),
    async attach() {}, async detach() {},
    async sendCommand() { return {}; }
  }
};
class WebSocket { constructor() { this.readyState = 0; } }
const context = vm.createContext({ chrome, WebSocket, URL, navigator: {}, setTimeout, clearTimeout, setInterval() {}, console });
vm.runInContext(fs.readFileSync(new URL('../extension/bridge.js', import.meta.url), 'utf8'), context);
const drain = () => vm.runInContext('commandQueues.get("management") || Promise.resolve()', context);

const opener = await context.handle({ cmd: 'clinqyTab', url: 'https://workspace.test', runID: 'run-A' });
// The page opens its review window after the click command has already returned.
vm.runInContext(`recentTabInput.set(${opener.id}, { at: Date.now(), command: 'cdpClick' })`, context);
tabs.set(50, { id: 50, windowId: 5, openerTabId: opener.id, url: 'https://workspace.test/popup' });
listeners.created(tabs.get(50));
let listed = await context.handle({ cmd: 'tabs', workOnly: true, runID: 'run-A' });
const child = listed.tabs.find(t => t.id === 50);
assert(child, 'popup opened just after Clinqy input inherits the task');
assert.equal(child.inherited, true);
assert.equal(child.openerTabId, opener.id);
assert(!calls.some(c => c[0] === 'focusWindow' || (c[0] === 'update' && c[2]?.active)), 'popup adoption never activates');
console.log('PASS popup opened after the click returned still inherits the opener task');

// Long after any Clinqy input (e.g. the page's own timer or the user), a popup is not inherited.
vm.runInContext(`recentTabInput.set(${opener.id}, { at: Date.now() - 60000, command: 'cdpClick' })`, context);
tabs.set(51, { id: 51, windowId: 5, openerTabId: opener.id, url: 'https://workspace.test/late' });
listeners.created(tabs.get(51));
listed = await context.handle({ cmd: 'tabs', workOnly: true, runID: 'run-A' });
assert(!listed.tabs.some(t => t.id === 51), 'stale input does not grant ownership');
// Another run never sees this run's popup.
listed = await context.handle({ cmd: 'tabs', workOnly: true, runID: 'run-B' });
assert(!listed.tabs.some(t => t.id === 50));
console.log('PASS popups without recent Clinqy input, or from another run, are not inherited');

// The popup closes itself (window.close()): reads say it closed and name the owned opener.
tabs.delete(50);
listeners.removed(50);
await drain();
await assert.rejects(context.handle({ cmd: 'snapshot', workOnly: true, runID: 'run-A', tabId: 50 }),
  err => /was closed/.test(err.message) && new RegExp(`opener tab ${opener.id}`).test(err.message) && !/does not belong/.test(err.message));
await assert.rejects(context.handle({ cmd: 'snapshot', workOnly: true, runID: 'run-B', tabId: 50 }), /does not belong/);
listed = await context.handle({ cmd: 'tabs', workOnly: true, runID: 'run-A' });
assert.deepEqual(JSON.parse(JSON.stringify(listed.closed)), [{ id: 50, openerTabId: opener.id }]);
assert(listed.tabs.some(t => t.id === opener.id), 'the opener stays owned after its popup closes');
console.log('PASS a self-closed popup is reported as closed with its owned opener, not as foreign');

// Chrome connected with no window at all: the task tab gets its own minimized, unfocused window.
windows = [];
for (const t of [...tabs.values()]) t.active = false;
const windowless = await context.handle({ cmd: 'clinqyTab', url: 'https://richtext.test', runID: 'run-C' });
const made = calls.find(c => c[0] === 'createWindow');
assert(made, 'a window is created when none exists');
assert.equal(made[1].focused, false);
assert.equal(made[1].state, undefined, 'state is not passed to create (Chrome may ignore it)');
assert(calls.some(c => c[0] === 'focusWindow' && c[1] === 77 && c[2]?.state === 'minimized'), 'window is minimized with windows.update');
assert(!calls.some(c => (c[0] === 'createWindow' && c[1]?.focused === true) || (c[0] === 'focusWindow' && c[2]?.focused === true)), 'never focused');
assert.equal(tabs.get(windowless.id).windowId, 77);
assert(!calls.some(c => (c[0] === 'focusWindow' && c[2]?.focused) || (c[0] === 'update' && c[2]?.active)), 'windowless creation never focuses');
listed = await context.handle({ cmd: 'tabs', workOnly: true, runID: 'run-C' });
assert.deepEqual(Array.from(listed.tabs, t => t.id), [windowless.id]);
console.log('PASS windowless browser: task tab opens in a new minimized, never-focused window');
