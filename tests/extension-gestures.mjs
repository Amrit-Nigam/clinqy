// Run production routing/delivery against browser API mocks. No real browser or user input.
import vm from 'node:vm';
import fs from 'node:fs';
import assert from 'node:assert/strict';
const events = [], hook = { addListener() {} };
let covered = false, failMove = false, movedFrame = false;
const map = { documentID: 'doc', snapshotID: 'snap', items: { 7: [0, 7], 8: [0, 8], 9: [2, 9] },
  offsets: { 0: { x: 0, y: 0 }, 2: { x: 100, y: 100 } },
  frameBoxes: { 2: { nodeToken: 'frame', x: 100, y: 100, w: 200, h: 200 } },
  frameTokens: { 0: { documentID: 'doc', snapshotID: 's0' }, 2: { documentID: 'child', snapshotID: 's2' } } };
const storage = { async get(key) { return { [key]: key === 'map1' ? map : ['workTabs', 'opened'].includes(key) ? [1] : [] }; }, async set() {}, async remove() {} };
const chrome = {
  storage: { session: storage, local: storage }, runtime: { onStartup: hook, onInstalled: hook },
  alarms: { create() {}, onAlarm: hook }, tabs: { onRemoved: hook, async get(id) { return { id, windowId: 1 }; } },
  debugger: { onDetach: hook, onEvent: hook, async attach() {}, async sendCommand(target, method, args) {
    if (method === 'Input.dispatchMouseEvent') {
      events.push(args);
      if (failMove && args.type === 'mouseMoved' && args.buttons === 1) throw Error('lost mid-drag acknowledgement');
    }
    return {};
  } },
  scripting: { async executeScript({ args }) {
    if (!args) return [];
    const [name, parameters] = args;
    if (name === 'check') return [{ result: { __ok: {} } }];
    if (name === 'locate') return [{ result: { __ok: { hit: !covered, still: true, px: parameters[0] === 7 ? 20 : 80, py: 40 } } }];
    if (name === 'frameBoxes') return [{ result: { __ok: { frames: [{ nodeToken: 'frame', x: movedFrame ? 120 : 100, y: 100, w: 200, h: 200 }] } } }];
    throw Error('unexpected page helper ' + name);
  } }
};
class WebSocket { constructor() { this.readyState = 0; } }
const context = vm.createContext({ chrome, WebSocket, URL, navigator: {}, console, setTimeout, clearTimeout, setInterval() {} });
vm.runInContext(fs.readFileSync(new URL('../extension/bridge.js', import.meta.url), 'utf8'), context);
const call = (gesture, extra = {}) => context.serializedHandle({ cmd: 'cdpGesture', tabId: 1, workOnly: true,
  documentID: 'doc', snapshotID: 'snap', gesture, index: 7, ...extra });
await call('hover');
assert.deepEqual(events.map(e => e.type), ['mouseMoved']);
events.length = 0;
await call('right_click');
assert.equal(events[1].button, 'right'); assert.equal(events[1].buttons, 2); assert.equal(events.at(-1).buttons, 0);
events.length = 0;
await call('double_click');
assert.deepEqual(events.filter(e => e.type === 'mousePressed').map(e => e.clickCount), [1, 2]);
events.length = 0;
await call('drag', { toIndex: 8 });
assert.equal(events.filter(e => e.type === 'mouseMoved' && e.buttons === 1).length, 12);
assert.equal(events.at(-1).x, 80); assert.equal(events.at(-1).type, 'mouseReleased');
events.length = 0;
covered = true;
await assert.rejects(call('drag', { toIndex: 8 }), /covered/);
assert.equal(events.length, 0); covered = false;
await assert.rejects(call('hover', { snapshotID: 'stale' }), /stale/); assert.equal(events.length, 0);
movedFrame = true;
await assert.rejects(call('drag', { toIndex: 9 }), /frame moved/); assert.equal(events.length, 0); movedFrame = false;
failMove = true;
await assert.rejects(call('drag', { toIndex: 8 }), /lost mid-drag/);
assert.equal(events.filter(e => e.type === 'mousePressed').length, 1, 'no input retry');
assert.equal(events.at(-1).type, 'mouseReleased', 'release after lost acknowledgement');
assert.equal(events.at(-1).buttons, 0);
console.log('PASS hover, context menu, double-click and drag protocol events');
console.log('PASS stale/covered/moved frame refusal before input; single delivery and release on error');
