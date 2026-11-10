// Background-tab uploads: the browser itself sets the hidden file input (CDP DOM.setFileInputFiles), the result is
// read back, and the page-side route runs only when nothing was assigned.
import vm from 'node:vm';
import fs from 'node:fs';
import assert from 'node:assert/strict';
const event = { addListener() {} };
const storage = { async get() { return {}; }, async set() {}, async remove() {} };
const chrome = {
  scripting: { async executeScript() { return []; } }, storage: { session: storage, local: storage },
  runtime: { onStartup: event, onInstalled: event }, alarms: { create() {}, onAlarm: event },
  tabs: { onRemoved: event, async query() { return []; }, async get() { return {}; } },
  tabGroups: { async query() { return []; }, async update() {} }, windows: { async get() { return {}; } },
  debugger: { onDetach: event, onEvent: event },
};
class WebSocket { constructor() { this.readyState = 0; } }
const context = vm.createContext({ chrome, WebSocket, URL, navigator: {}, setTimeout, clearTimeout, setInterval() {}, console });
vm.runInContext(fs.readFileSync(new URL('../extension/bridge.js', import.meta.url), 'utf8'), context);

let pageCalls = [], cdpCalls = [], owned = true, held = true;
context.call = async (tabId, frameId, name, args) => {
  pageCalls.push([name, ...args]);
  if (name === 'markFileInput') return { token: 'f1', shownBefore: false };
  if (name === 'fileReadback') return { ok: held, held, shown: false, files: held ? [args[1]] : [] };
  if (name === 'upload') return { ok: true, held: true, via: 'datatransfer' };
  throw Error('unexpected ' + name);
};
context.cdp = async (tabId, method, params) => {
  if (!owned) throw Error("tab 3 wasn't opened by Clinqy, so it isn't driven in the background");
  cdpCalls.push([method, params]);
  if (method === 'DOM.getDocument') return { root: { nodeId: 1 } };
  if (method === 'DOM.querySelector') return { nodeId: 42 };
  return {};
};
const msg = { name: 'Amrit_Resume_C.pdf', path: '/Users/me/Downloads/Amrit_Resume_C.pdf', size: 1234, type: 'application/pdf', data: 'AAAA' };

// Owned task tab: the browser sets the file on the tagged input, then the page reads it back.
let r = await context.uploadThroughBrowser(3, 15, msg);
assert.equal(r.via, 'cdp'); assert.equal(r.ok, true); assert.equal(r.assigned, true);
assert.equal(JSON.stringify(cdpCalls.find(c => c[0] === 'DOM.setFileInputFiles')[1]), JSON.stringify({ nodeId: 42, files: [msg.path] }));
assert.equal(cdpCalls.find(c => c[0] === 'DOM.querySelector')[1].selector, '[data-clinqy-file="f1"]');
assert.equal(JSON.stringify(pageCalls.at(-1)), JSON.stringify(['fileReadback', 'f1', msg.name, 1234, false]));

// The browser took it but the page reset the input: reported, never assigned a second time.
pageCalls = []; cdpCalls = []; held = false;
r = await context.uploadThroughBrowser(3, 15, msg);
assert.equal(r.ok, false); assert.equal(r.assigned, true); assert.equal(r.cleared, true);
assert(!pageCalls.some(c => c[0] === 'upload'), 'no second assignment through the page');

// Not a task tab (foreground use of the user's own tab): no CDP, nothing assigned, page-side route allowed.
pageCalls = []; cdpCalls = []; owned = false; held = true;
r = await context.uploadThroughBrowser(3, 15, msg);
assert.equal(r, null);
assert.equal(pageCalls.at(-1)[0], 'fileReadback', 'the tag is cleared');
console.log('PASS background uploads go through the browser and never assign twice');
