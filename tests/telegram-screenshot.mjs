// Run the production extension worker with a mocked browser API; never attach to a real browser.
import vm from 'node:vm';
import fs from 'node:fs';
import assert from 'node:assert/strict';
const calls = [];
const event = { addListener() {} };
const storage = { async get() { return { opened: [10] }; }, async set() {}, async remove() {} };
const chrome = {
  storage: { session: storage, local: storage },
  runtime: { onStartup: event, onInstalled: event },
  alarms: { create() {}, onAlarm: event },
  tabs: { async get(id) { return { id, windowId: 5, url: 'http://localhost/demo' }; },
          async query() { return [{ id: 99, windowId: 5 }]; }, onRemoved: event },
  windows: { async get() { return { focused: false }; } },
  debugger: { onDetach: event, onEvent: event, async attach(target) { calls.push(['attach', target]); },
              async sendCommand(target, method, params) { calls.push([method, target, params]); return { data: 'PNG-DATA' }; } }
};
class WebSocket { constructor() { this.readyState = 0; } }
const context = vm.createContext({ chrome, WebSocket, navigator: {}, setTimeout, clearTimeout, setInterval() {}, console });
vm.runInContext(fs.readFileSync(new URL('../extension/bridge.js', import.meta.url), 'utf8'), context);
const result = await context.handle({ cmd: 'captureTask', tabId: 10 });
assert.equal(result.image, 'PNG-DATA');
assert.equal(result.tabId, 10);
assert.equal(calls.find(c => c[0] === 'Page.captureScreenshot')[2].captureBeyondViewport, false);
await assert.rejects(context.handle({ cmd: 'captureTask', tabId: 99 }), /wasn't opened by Clinqy/);
await assert.rejects(context.handle({ cmd: 'captureTask' }), /explicit tab/);
assert.equal(calls.filter(c => c[0] === 'attach').length, 1);
assert.equal(calls.filter(c => c[0] === 'Page.captureScreenshot').length, 1);
console.log('PASS background screenshot targets the task tab without activating a window');
console.log('PASS unrelated tabs and implicit foreground captures are rejected');
