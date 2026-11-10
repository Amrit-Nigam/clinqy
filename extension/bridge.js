// Connects to the Clinqy app on this Mac and runs its requests against the active tab — including the pages
// embedded in it (Greenhouse/Lever job forms, payment boxes), whose elements are listed with the rest.
const URL_ = "ws://127.0.0.1:47823";
// This script's own version, kept equal to manifest.json's. Chrome can keep running an older copy of the worker after
// a reload (the manifest is re-read, the script isn't), so the app checks this one, not the manifest's.
const SCRIPT_VERSION = "1.9.16";
const SCRIPT_BUILD = "2026-11-browser-reliability-2";
const CAPABILITIES = ["document-tokens", "task-ownership", "condition-waits", "activity-phases", "cooperative-cancellation", "upload-readback", "html-range-state", "effect-receipts", "adopted-tabs"];
let socket = null;
let retry = 1000;
// A snapshot must not overwrite index maps while an earlier action is resolving its target.
const commandQueues = new Map();
// Every connection to the app gets an epoch. Work received on one is answered on that same socket only, and work
// still queued when it closes never dispatches: a replacement socket must not carry a retired request's result.
let connectionEpoch = 0;
// Requests the app gave up on (timeout/cancel) before they started running. Bounded; entries are tiny.
const cancelledIDs = new Set();
const runningIDs = new Set();
const runningRequests = new Map();
const tabRequestsInFlight = new Map();
function assertRequestLive(tabId) {
  const request = tabRequestsInFlight.get(tabId);
  if (request && (request.cancelled || request.epoch !== connectionEpoch || Date.now() > request.deadline))
    throw new Error("operation interrupted; observe the result before retrying any input");
}
async function connectionHello() {
  const stored = await chrome.storage.local.get("clinqyProfileIdentity");
  const profileIdentity = stored.clinqyProfileIdentity || crypto.randomUUID();
  if (!stored.clinqyProfileIdentity) await chrome.storage.local.set({clinqyProfileIdentity:profileIdentity});
  // This identifies an extension installation, not a Chrome profile directory or account.
  return {type:"hello",agent:navigator.userAgent,version:SCRIPT_VERSION,manifest:chrome.runtime.getManifest().version,
    profileIdentity, build:SCRIPT_BUILD, capabilities:CAPABILITIES, protocolVersion:7};
}
const NOT_DISPATCHED = "cancelled before dispatch";
function markCancelled(id) {
  if (typeof id !== "string") return false;
  const running = runningRequests.get(id);
  if (running) {
    running.cancelled = true;
    if (Number.isInteger(running.tabId)) void chrome.scripting.executeScript({target:{tabId:running.tabId,allFrames:true},
      func:() => window.__clinqy?.cancelWaits?.()}).catch(() => {});
    return true; // Delivered input is never undone; remaining input and waits are cancelled.
  }
  cancelledIDs.add(id);
  if (cancelledIDs.size > 500) cancelledIDs.delete(cancelledIDs.values().next().value);
  return true;
}
function serializedHandle(msg, origin = {}) {
  // Snapshot/index mutations serialize within a tab. Different tabs can wait/read/act concurrently.
  // Creation and shared extension lifecycle/storage operations retain their own management lane.
  const tabScoped = msg.tabId != null && !["clinqyDone", "clinqyClear", "newTab", "clinqyTab", "reload"].includes(msg.cmd);
  const key = tabScoped ? `tab:${msg.tabId}` : "management";
  const previous = commandQueues.get(key) || Promise.resolve();
  const receivedAt = Date.now();
  const ttl = Number(msg.ttlMs) > 0 ? Number(msg.ttlMs) : null;
  const next = previous.then(() => {
    // The decision to run happens here, at dispatch, not at receipt: time spent behind earlier commands counts.
    if (msg.id != null && cancelledIDs.delete(msg.id)) throw new Error(NOT_DISPATCHED + ": the app stopped waiting for it");
    if (origin.epoch != null && origin.epoch !== connectionEpoch) throw new Error(NOT_DISPATCHED + ": its connection was replaced");
    if (ttl != null && Date.now() - receivedAt > ttl) throw new Error(NOT_DISPATCHED + ": it expired while queued");
    let finishRequest;
    const finished = new Promise(resolve => {finishRequest=resolve;});
    const request = {finished,cancelled:false, epoch:origin.epoch ?? connectionEpoch, deadline:ttl == null ? Infinity : receivedAt+ttl,
      command:msg.cmd, tabId:msg.tabId == null ? null : Number(msg.tabId)};
    if (msg.id != null) { runningIDs.add(msg.id); runningRequests.set(msg.id,request); }
    if (Number.isInteger(request.tabId)) tabRequestsInFlight.set(request.tabId,request);
    return handle(msg).finally(() => {
      if (msg.id != null) { runningIDs.delete(msg.id); runningRequests.delete(msg.id); }
      if (tabRequestsInFlight.get(request.tabId) === request) tabRequestsInFlight.delete(request.tabId);
      finishRequest();
    });
  });
  const tail = next.catch(() => {});
  commandQueues.set(key, tail);
  void tail.then(() => { if (commandQueues.get(key) === tail) commandQueues.delete(key); });
  return next;
}

function connect() {
  if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) return;
  let ws;
  try { ws = new WebSocket(URL_); } catch { return; }
  socket = ws;
  const epoch = ++connectionEpoch;
  // Replies go out on the socket the request arrived on, and only while it is still the current connection.
  const reply = (obj) => { if (ws === socket && epoch === connectionEpoch && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj)); };
  ws.onopen = async () => {
    retry = 1000;
    try { reply(await connectionHello()); } catch { reply({type:"hello",version:SCRIPT_VERSION,build:SCRIPT_BUILD,capabilities:CAPABILITIES}); }
  };
  ws.onmessage = async (event) => {
    let msg;
    try { msg = JSON.parse(event.data); } catch { return; }
    if (msg.type === "cancel") { markCancelled(msg.id); return; }
    if (!msg.id) return;
    try {
      reply({ id: msg.id, ok: true, result: await serializedHandle(msg, { epoch }) });
    } catch (err) {
      reply({ id: msg.id, ok: false, error: String(err && err.message || err) });
    }
  };
  // Back quickly when the app restarts or Chrome wakes the worker (1 s, doubling to 10 s).
  ws.onclose = () => {
    if (ws === socket) { for (const id of runningRequests.keys()) markCancelled(id); socket = null; queueActivity(() => clinqyDone()); setTimeout(connect, retry); retry = Math.min(retry * 2, 10000); }
  };
  ws.onerror = () => {};
}

function send(obj) {
  if (socket && socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(obj));
}

async function activeTab() {
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  if (!tab) throw new Error("no active tab");
  return tab;
}

// ---- running page.js functions in frames ----

// Runs window.__clinqy[name](...args) in a frame; errors come back as values, so one frame never sinks the rest.
// Async so a page function may return a promise (waitText); executeScript waits for it.
const runner = async (n, a, expected = null) => {
  try {
    const f = window.__clinqy && window.__clinqy[n];
    if (!f) return { __error: "no page function " + n };
    if (n === "snapshot" && a[0] && a[0].excludeTop && window === window.top) return { __error: "top frame already observed" };
    if (n === "snapshot" || n === "selection" || n === "focusStatus") return { __ok: await f(...a) };
    if (!expected) throw new Error("missing browser observation tokens; take a new look");
    const token = expected.documentID ? expected : expected[window.__clinqy.documentID];
    return { __ok: await window.__clinqy.invoke(n, a, token) };
  } catch (e) { return { __error: String(e && e.message || e) }; }
};

// Runs in the page's own world (scripts there create and click file inputs, which the extension's world can't
// intercept): clicks the element page.js marked, catching the file input it asks for, and gives it the file.
const pickerUpload = async (name, type, b64) => {
  const el = document.querySelector("[data-clinqy-up]");
  if (!el) return { ok: false, why: "the upload button is gone" };
  el.removeAttribute("data-clinqy-up");
  const proto = HTMLInputElement.prototype;
  const click = proto.click, picker = proto.showPicker;
  let caught = null;
  proto.click = function (...a) { if (this.type === "file") { caught = this; return; } return click.apply(this, a); };
  if (picker) proto.showPicker = function (...a) { if (this.type === "file") { caught = this; return; } return picker.apply(this, a); };
  // A label or real click reaching a file input opens the picker by default: catch that too.
  const onClick = (e) => { const t = e.composedPath ? e.composedPath()[0] : e.target; if (t && t.tagName === "INPUT" && t.type === "file") { caught = t; e.preventDefault(); } };
  document.addEventListener("click", onClick, true);
  try {
    el.click();
    for (let k = 0; k < 30 && !caught; k++) await new Promise((r) => setTimeout(r, 50));
  } finally {
    proto.click = click;
    if (picker) proto.showPicker = picker;
    document.removeEventListener("click", onClick, true);
  }
  if (!caught) return { ok: false, why: "clicking it didn't ask for a file" };
  const bin = atob(b64), bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  const dt = new DataTransfer();
  if (caught.multiple) for (const f of caught.files || []) dt.items.add(f);
  dt.items.add(new File([bytes], name, { type: type || "application/octet-stream", lastModified: Date.now() }));
  caught.files = dt.files;
  caught.dispatchEvent(new Event("input", { bubbles: true }));
  caught.dispatchEvent(new Event("change", { bubbles: true }));
  const files=[...(caught.files || [])];
  return {ok:files.some(f=>f.name===name && f.size===bytes.length),files:files.map(f=>f.name),
    attached:files.map(f=>({name:f.name,size:f.size,type:f.type})),verified:"file-input-readback",serverAccepted:false};
};

async function inject(target) {
  try { await chrome.scripting.executeScript({ target, files: ["page.js"] }); } catch {}
}

async function call(tabId, frameId, name, args = []) {
  assertRequestLive(tabId);
  const target = { tabId, frameIds: [frameId] };
  await inject(target);
  let res;
  const token = (await mapFor(tabId)).frameTokens?.[frameId] || null;
  assertRequestLive(tabId);
  try { [res] = await chrome.scripting.executeScript({ target, func: runner, args: [name, args, token] }); }
  catch (e) { throw new Error("the page can't be scripted: " + String(e && e.message || e)); }
  const out = res && res.result;
  if (!out) throw new Error("the page didn't answer");
  if (out.__error) throw new Error(out.__error);
  return out.__ok;
}

// Every frame's answer that worked: [{frameId, result}].
async function callAll(tabId, name, args = []) {
  assertRequestLive(tabId);
  const target = { tabId, allFrames: true };
  await inject(target);
  let res = [];
  const frameTokens = (await mapFor(tabId)).frameTokens || {};
  const tokens = Object.fromEntries(Object.values(frameTokens).map((t) => [t.documentID, t]));
  assertRequestLive(tabId);
  try { res = await chrome.scripting.executeScript({ target, func: runner, args: [name, args, tokens] }); } catch {}
  return res.filter((r) => r && r.result && !r.result.__error).map((r) => ({ frameId: r.frameId, result: r.result.__ok }));
}

// ---- element ids across frames ----
// A snapshot lists the top page's elements first, then each visible frame's; commands with an id are routed to
// the frame (and that frame's own index) the id came from. Ids are stable on a page: an element keeps its w-id
// from look to look (matched by page.js's key), so a form that shifts by one field doesn't renumber everything
// and an old id never silently means a different element. A new page (address) starts again from 0. Kept in
// session storage too, so a restarted worker still knows.

const maps = new Map();   // tabId → { items: {id: [frameId, local]}, offsets: {frameId: {x, y}}, page, keys: {key: id}, next }
const focusFrames = new Map();   // tabId → frame that had the caret at the last activeValue

async function saveMap(tabId, map) {
  maps.set(tabId, map);
  try { await chrome.storage.session.set({ ["map" + tabId]: map }); } catch {}
}

async function mapFor(tabId) {
  if (maps.has(tabId)) return maps.get(tabId);
  try {
    const s = await chrome.storage.session.get("map" + tabId);
    if (s["map" + tabId]) { maps.set(tabId, s["map" + tabId]); return s["map" + tabId]; }
  } catch {}
  return { items: [], offsets: {} };
}

async function route(tabId, index) {
  const it = ((await mapFor(tabId)).items || {})[index];
  if (!it) throw new Error("element w" + index + " isn't on the page now; take a new look");
  return { frameId: it[0], local: it[1] };
}

const pageOf = (url) => { try { const u = new URL(url); return u.origin + u.pathname; } catch { return url || ""; } };

// Gives each listed element its w-id: the one its key had on this page before, else the next unused number.
// Keys seen earlier on the page are remembered (scrolled away and back = same id); ids are never reused for
// another key, so they only grow (renumbered from 0 on a new page, or if they ever pass 999).
function assignIds(prev, url, list) {
  const page = pageOf(url);
  const same = prev && prev.page === page && prev.keys && (prev.next || 0) < 1000;
  const keys = same ? { ...prev.keys } : {};
  let next = same ? prev.next || 0 : 0;
  const used = new Set(), items = {};
  for (const { key, frameId, local, e } of list) {
    let id = key != null ? keys[key] : undefined;
    if (id === undefined || used.has(id)) { id = next++; if (key != null && keys[key] === undefined) keys[key] = id; }
    used.add(id);
    items[id] = [frameId, local];
    e.i = id;
  }
  // Remember a bounded number of keys (oldest dropped first).
  const all = Object.keys(keys);
  if (all.length > 1500) for (const k of all.slice(0, all.length - 1500)) delete keys[k];
  return { items, page, keys, next };
}

const samePage = (a, b) => {
  try { const x = new URL(a), y = new URL(b); return x.origin === y.origin && x.pathname === y.pathname; } catch { return false; }
};

// Local coordinates of a frame → the top page's, through the frame's accumulated placement (offset and CSS scale).
const toTop = (o, x, y) => ({ x: o.x + x * (o.sx || 1), y: o.y + y * (o.sy || 1) });

// Which frame is behind each visible <iframe> box. Deterministic when the browser names it (runtime.getFrameId, the
// box's frameId); URL/size matching is only the fallback for boxes without one, and only when it is unambiguous.
function associateFrames(boxes, subs, claimed) {
  const matches = [];
  const free = [];
  for (const box of boxes) {
    const inline = box.inlineDocumentID ? [...subs].filter(([, sub]) => sub.documentID === box.inlineDocumentID && /^about:(blank|srcdoc)(?:[#?]|$)/.test(sub.url || "")) : [];
    const frameId = inline.length === 1 ? inline[0][0] : box.frameId;
    const sub = frameId != null ? subs.get(frameId) : null;
    const permitted = sub && (/^https?:/.test(sub.url || "") || (inline.length === 1 && sub.documentID === box.inlineDocumentID));
    if (permitted && !claimed.has(frameId)) { claimed.add(frameId); matches.push({ box, frameId, sub }); }
    else free.push(box);
  }
  const unplaced = free.filter((b) => b.frameId == null);
  for (const [frameId, sub] of subs) {
    if (claimed.has(frameId) || !unplaced.length || !/^https?:/.test(sub.url || "")) continue;
    const addressed = unplaced.filter((f) => f.src && samePage(f.src, sub.url));
    let box = addressed.length === 1 ? addressed[0] : null;
    if (!box) {
      const sized = unplaced.filter((f) => Math.abs(f.w - sub.viewport.w) <= 2 && Math.abs(f.h - sub.viewport.h) <= 2);
      if (sized.length === 1) box = sized[0];
    }
    if (!box) continue;
    unplaced.splice(unplaced.indexOf(box), 1);
    free.splice(free.indexOf(box), 1);
    claimed.add(frameId);
    matches.push({ box, frameId, sub });
  }
  return { matches, unmatched: free };
}

async function snapshot(tab) {
  const frameSnapshots = await callAll(tab.id, "snapshot", [{ excludeTop: true }]);
  const top = await call(tab.id, 0, "snapshot");
  const list = top.elements.map((e) => ({ key: e.key, frameId: 0, local: e.i, e }));
  if (!top.documentID || !top.snapshotID) throw new Error("update browser page helpers before acting");
  const frameBoxes = {};
  const frameTokens = { 0: { documentID: top.documentID, snapshotID: top.snapshotID } };
  const offsets = { 0: { x: 0, y: 0, sx: 1, sy: 1 } };
  const coverage = [];   // frames that exist on the page but are not part of this observation, and why
  const elements = top.elements;
  const extraText = [];
  if (top.frames && top.frames.length) {
    const subs = new Map(frameSnapshots
      .filter((s) => s.frameId !== 0 && /^(https?:|about:(blank|srcdoc)(?:[#?]|$))/.test(s.result.url || "")).map((s) => [s.frameId, s.result]));
    const claimed = new Set();
    const queue = [{ parent: 0, boxes: top.frames, origin: offsets[0], depth: 1 }];
    while (queue.length) {
      const { parent, boxes, origin, depth } = queue.shift();
      const { matches, unmatched } = associateFrames(boxes, subs, claimed);
      for (const box of unmatched) {
        let host = "frame"; try { host = new URL(box.src).hostname || host; } catch {}
        coverage.push({ frame: host, src: box.src || "", status: "unreadable",
                        reason: box.src && !/^https?:/.test(box.src) ? "not an http(s) page" : "the extension could not run in it or could not tell which page it shows" });
      }
      for (const { box, frameId, sub } of matches) {
        let host = "frame";
        try { host = new URL(sub.url).hostname; } catch {}
        if (!sub.documentID || !sub.snapshotID) { coverage.push({ frame: host, src: sub.url, status: "unreadable", reason: "its page helper is out of date" }); continue; }
        if (box.rotated) { coverage.push({ frame: host, src: sub.url, status: "unreadable", reason: "the frame is rotated or skewed by CSS, so its coordinates cannot be placed" }); continue; }
        if (depth > 4) { coverage.push({ frame: host, src: sub.url, status: "unreadable", reason: "nested too deeply" }); continue; }
        const sx = origin.sx * (box.sx || 1), sy = origin.sy * (box.sy || 1);
        const placed = toTop(origin, box.x, box.y);
        const here = { x: placed.x, y: placed.y, sx, sy };
        frameTokens[frameId] = { documentID: sub.documentID, snapshotID: sub.snapshotID };
        frameBoxes[frameId] = { ...box, parent };   // raw, in the parent's own coordinates: re-checked live before input
        offsets[frameId] = here;
        for (const e of sub.elements) {
          const p = toTop(here, e.x, e.y), w = e.w * sx, h = e.h * sy;
          if (p.y + h < 0 || p.y > top.viewport.h || p.x + w < 0 || p.x > top.viewport.w) continue;
          const moved = { ...e, x: p.x, y: p.y, w, h, frame: host };
          elements.push(moved);
          list.push({ key: e.key != null ? frameId + "|" + sub.documentID + "|" + e.key : null, frameId, local: e.i, e: moved });
        }
        top.messages = (top.messages || []).concat(sub.messages || []);
        if (sub.text) extraText.push(`[${host}] ${sub.text}`);
        top.below = (top.below || 0) + (sub.below || 0);
        top.above = (top.above || 0) + (sub.above || 0);
        if (sub.panes && sub.panes.length) top.panes = (top.panes || []).concat(sub.panes.map((p) => ({ ...p, frame: host })));
        if (sub.frames && sub.frames.length) queue.push({ parent: frameId, boxes: sub.frames, origin: here, depth: depth + 1 });
      }
    }
  }
  const previous = await mapFor(tab.id);
  const snapshotID = crypto.randomUUID();
  await saveMap(tab.id, { ...assignIds(previous.documentID === top.documentID ? previous : null, top.url, list),
    documentID: top.documentID, snapshotID, frameTokens, frameBoxes, offsets, coverage });
  // A new document in an adopted tab needs the user-input watcher again before Clinqy acts in it.
  if (await isAdopted(tab.id)) await armUserWatch(tab.id, true);
  if (coverage.length) extraText.push("[frames not read: " + coverage.map((c) => `${c.frame} (${c.reason})`).join("; ") + "]");
  if (extraText.length) top.text = [top.text, ...extraText].filter(Boolean).join(" · ").slice(0, 2400);
  return { ...top, snapshotID, elements, tabId: tab.id, active: !!tab.active, frameCoverage: coverage };
}

// A frame's box, and every ancestor's, must still be where the observation saw it: same node, same geometry.
async function frameChainStable(tabId, map, frameId) {
  for (let f = frameId, guard = 0; f !== 0 && guard < 8; guard++) {
    const observed = map.frameBoxes && map.frameBoxes[f];
    if (!observed) return false;
    const live = (await call(tabId, observed.parent ?? 0, "frameBoxes")).frames || [];
    const current = live.find((box) => box.nodeToken === observed.nodeToken);
    if (!current || (observed.inlineDocumentID && current.inlineDocumentID !== observed.inlineDocumentID) || ["x", "y", "w", "h"].some((key) => Math.abs(current[key] - observed[key]) > 0.5)
        || Math.abs((current.sx || 1) - (observed.sx || 1)) > 0.01 || Math.abs((current.sy || 1) - (observed.sy || 1)) > 0.01 || current.rotated) return false;
    f = observed.parent ?? 0;
    if (f === 0) return true;
  }
  return frameId === 0;
}

// The frame that has the caret: the top page, or a frame inside it when the top page's focus is on an <iframe>
// (at any depth: only the frame that holds the caret reports focus without pointing at a frame of its own).
// Blank/srcdoc frames count too — rich-text editors (TinyMCE, CKEditor) type into one.
async function focusedFrame(tabId) {
  const top = await call(tabId, 0, "activeValue");
  if (!top.frame) return { frameId: 0, info: top };
  const frames = (await callAll(tabId, "activeValue")).filter(({ frameId, result }) =>
    frameId !== 0 && /^(https?:|about:|file:)/.test(result.url || "") && !result.frame);
  const hit = frames.find(({ result }) => result.hasFocus && result.editable) || frames.find(({ result }) => result.hasFocus);
  if (hit) return { frameId: hit.frameId, info: { ...hit.result, inFrame: true } };
  return { frameId: 0, info: top };   // e.g. Google Docs' own typing frame: keys land there, the app pastes
}

// ---- tabs ----
// Tabs Clinqy opened (only those may be closed by it), kept across worker restarts.
async function openedTabs() {
  try { return new Set((await chrome.storage.session.get("opened")).opened || []); } catch { return new Set(); }
}
async function setOpened(set) {
  try { await chrome.storage.session.set({ opened: [...set] }); } catch {}
}

// Cosmetic feedback is independent of the action protocol: failure to draw it never retries input.
async function activityTabs() {
  try { return (await chrome.storage.session.get("activityTabs")).activityTabs || []; } catch { return []; }
}
async function renderActivity(tabId, state) {
  try {
    const target = { tabId, frameIds: [0] };
    if (state.active !== false) await chrome.scripting.executeScript({ target, files: ["activity.js"] });
    await chrome.scripting.executeScript({ target, func: state => window.__clinqyActivity?.update(state), args: [state] });
  } catch {} // restricted pages and navigating documents may refuse scripts
}
let activityUpdates = Promise.resolve();
function updateActivity(operation) {
  const next = activityUpdates.then(operation);
  activityUpdates = next.catch(() => {});
  return next;
}
async function showActivity(tabId, state = {}) {
  return updateActivity(async () => {
    const active = await activityTabs();
    if (!active.includes(tabId)) await chrome.storage.session.set({ activityTabs: [...active, tabId] });
    await renderActivity(tabId, state);
  });
}
async function finishActivity(tabIds) {
  return updateActivity(async () => {
    const active = await activityTabs();
    for (const id of active.filter(id => !tabIds || tabIds.includes(id))) await renderActivity(id, { active: false });
    await chrome.storage.session.set({ activityTabs: active.filter(id => tabIds && !tabIds.includes(id)) });
  });
}

function navigationKey(raw) {
  try {
    const url = new URL(raw.includes("://") ? raw : "https://" + raw);
    url.hostname = url.hostname.replace(/^www\./, "");
    return url.pathname === "/" ? url.href.replace(/\/(?=[?#]|$)/, "") : url.href;
  } catch { return raw; }
}

// Retries after a lost native acknowledgement must resolve to the same tab, even after worker suspension.
async function foregroundTab(msg) {
  const token = typeof msg.operationID === "string" ? msg.operationID : null;
  const requests = (await chrome.storage.session.get("tabRequests")).tabRequests || {};
  if (token && requests[token]) {
    const previous = requests[token];
    if (navigationKey(previous.url) !== navigationKey(msg.url) || previous.id == null) throw new Error("The earlier tab open has an unknown outcome; inspect the browser before trying again");
    const tab = await chrome.tabs.get(previous.id); // A closed tab is not silently recreated.
    await chrome.tabs.update(tab.id, { active: true });
    if (msg.activity) await showActivity(tab.id);
    return { id: tab.id };
  }
  if (token) {
    requests[token] = { url: msg.url }; // reserve before creation: a crash cannot turn a retry into another tab
    const keys = Object.keys(requests);
    for (const old of keys.slice(0, Math.max(0, keys.length - 100))) delete requests[old];
    await chrome.storage.session.set({ tabRequests: requests });
  }
  const tab = await chrome.tabs.create({ url: msg.url, active: true });
  const mine = await openedTabs(); mine.add(tab.id); await setOpened(mine);
  if (token) {
    requests[token] = { url: msg.url, id: tab.id };
    await chrome.storage.session.set({ tabRequests: requests });
  }
  if (msg.activity) await showActivity(tab.id);
  return { id: tab.id };
}

// ---- background runs ----

// A background run works in Clinqy's own window, opened without focus behind the user's, and its input goes to the
// tab through the debugger protocol: trusted clicks and keys that need neither the mouse, the keyboard nor a focused
// window. Chrome shows its "is debugging this browser" bar while attached; only Clinqy's own tabs are ever attached.
// Clinqy's window is remembered in local storage: session storage goes with every reload of the extension (each
// app update), which would orphan the window. Window ids only hold within one run of the browser, so it's
// forgotten when the browser starts.
chrome.runtime.onStartup.addListener(() => chrome.storage.local.remove("agentWin"));

async function agentWindow() {
  try {
    const { agentWin } = await chrome.storage.local.get("agentWin");
    if (agentWin != null) return await chrome.windows.get(agentWin);
  } catch {}
  return null;
}

// `at` is where the window goes: Clinqy's hidden screen (left, top, width, height in screen points), when it has one.
async function backgroundTab(url, at) {
  const win = await agentWindow();
  let t;
  if (win) {
    t = await chrome.tabs.create({ windowId: win.id, url, active: true });
    if (at) { try { await chrome.windows.update(win.id, { ...at, state: "normal" }); } catch {} }
  } else {
    const w = await chrome.windows.create({ url, focused: false, ...(at || { width: 1280, height: 900 }) });
    t = w.tabs[0];
    try { await chrome.storage.local.set({ agentWin: w.id }); } catch {}
  }
  const mine = await openedTabs();
  mine.add(t.id);
  await setOpened(mine);
  // Where the window really is (a browser may not place it where asked): the app moves it there itself.
  const w = await chrome.windows.get(t.windowId);
  return { id: t.id, windowId: t.windowId, bounds: { x: w.left, y: w.top, w: w.width, h: w.height } };
}

// A task in the user's own browser works in a tab of its own, in a "Clinqy" group beside theirs. It's never made active,
// so they keep the tab and window they're in. Focus is emulated, while layout keeps the browser's natural viewport.
// Screenshots, DOM targets and the visible task halo therefore share the same geometry when a user views the tab.
// Only tabs Clinqy opened are touched, and it lets go of them when the task ends.
async function workTabs() {
  try { return (await chrome.storage.session.get("workTabs")).workTabs || []; } catch { return []; }
}

async function clinqyGroup(tabId, windowId) {
  if (!chrome.tabGroups) return;
  const [group] = await chrome.tabGroups.query({ title: "Clinqy", windowId });
  const id = await chrome.tabs.group(group ? { tabIds: tabId, groupId: group.id } : { tabIds: tabId, createProperties: { windowId } });
  if (!group) await chrome.tabGroups.update(id, { title: "Clinqy", color: "blue", collapsed: false });
}

// All task ownership storage changes share a lane, including asynchronously opened popups.
let ownershipQueue = Promise.resolve();
function withOwnership(update) {
  const next = ownershipQueue.then(update);
  ownershipQueue = next.catch(() => {});
  return next;
}
const endingTaskTabs = new Set();
async function clinqyTab(url, width, height, runID) {
  return withOwnership(() => createClinqyTab(url, width, height, runID));
}
async function createClinqyTab(url, width, height, runID) {
  if (runID != null && (typeof runID !== "string" || !runID.length || runID.length > 128)) throw Error("invalid task ownership token");
  const [front] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  const t = await chrome.tabs.create({ ...(front ? { windowId: front.windowId } : {}), url, active: false });
  const mine = await openedTabs();
  mine.add(t.id);
  await setOpened(mine);
  // Arc exposes tab-group APIs whose promises can remain pending. Grouping is cosmetic;
  // it must never hold up attaching to or driving the owned tab.
  void clinqyGroup(t.id, t.windowId).catch(() => {});
  try { await chrome.storage.session.set({ workTabs: [...await workTabs(), t.id], workSize: { width, height } }); } catch {}
  try {
    await cdp(t.id, "Page.enable");
  } catch (error) {
    // A denied debugger permission must not leave an orphan task tab behind.
    try { await chrome.debugger.detach({ tabId: t.id }); } catch {}
    attached.delete(t.id);
    try { await chrome.tabs.remove(t.id); } catch {}
    mine.delete(t.id);
    await setOpened(mine);
    await chrome.storage.session.set({ workTabs: (await workTabs()).filter(id => id !== t.id) });
    throw error;
  }
  if (runID) await chrome.storage.session.set({["owner"+t.id]:runID});
  await showActivity(t.id);
  return { id: t.id };
}

async function prepareWorkTab(tabId) {
  const target = { tabId };
  await chrome.debugger.sendCommand(target, "Page.enable");
  // A hidden task must never open a native file picker over the user’s work. Uploads use page fields directly.
  await chrome.debugger.sendCommand(target, "Page.setInterceptFileChooserDialog", { enabled: true });
  try { await chrome.debugger.sendCommand(target, "Page.setDownloadBehavior", { behavior: "default" }); } catch {}   // lifecycle events; best effort
  await chrome.debugger.sendCommand(target, "Emulation.setFocusEmulationEnabled", { enabled: true });
  // Do not force a 1280px canvas inside a wider visible tab. Inactive Chrome tabs retain their layout viewport;
  // use that same geometry for DOM observations, screenshots and input. Clear overrides left by older sessions.
  await chrome.debugger.sendCommand(target, "Emulation.clearDeviceMetricsOverride");
}

// The task ended: Chrome's debugging bar goes, and the tab behaves normally if the user looks at it.
async function clinqyDone(tabIds, closeInactive = false) {
  // Stop new descendants inheriting ownership before draining already queued adoptions.
  const roots = tabIds || await activityTabs();
  for (const id of roots) endingTaskTabs.add(id);
  await Promise.all([...popupAdoptions]);
  return withOwnership(() => finishClinqyTabs(tabIds, closeInactive));
}
async function finishClinqyTabs(tabIds, closeInactive = false) {
  if(Array.isArray(tabIds)) {
    const ids=new Set(tabIds), owned=await workTabs();
    const records=await chrome.storage.session.get(owned.flatMap(id=>["popup"+id,"owner"+id]));
    // Include only descendants whose recorded owner still matches their parent's task.
    for(let depth=0;depth<8;depth++) {
      let added=false;
      for(const id of owned) {
        const popup=records["popup"+id];
        if(!ids.has(id) && popup && ids.has(popup.opener) && popup.runID===records["owner"+popup.opener] && popup.runID===records["owner"+id]) {ids.add(id);added=true;}
      }
      if(!added)break;
    }
    tabIds=[...ids];
  }
  const affected=tabIds || await activityTabs();
  for (const id of affected) endingTaskTabs.add(id);
  const finishing=[];
  for(const [id,request] of runningRequests) if(affected.includes(request.tabId)) {
    markCancelled(id); finishing.push(request.finished);
  }
  // Let key/button release cleanup run before detaching. A wedged renderer cannot hold cleanup indefinitely.
  if(finishing.length)await Promise.race([Promise.all(finishing),new Promise(resolve=>setTimeout(resolve,1500))]);
  await finishActivity(tabIds);
  // Adopted tabs go back to the user exactly as they were: detached, no emulation, never closed.
  const adoptedNow = await adoptedRecords();
  for (const id of Object.keys(adoptedNow).map(Number).filter(id => !tabIds || tabIds.includes(id))) {
    await dropAdoption(id);
    await restoreAdopted(id);
  }
  const owned = await workTabs();
  for (const tabId of tabIds ? owned.filter(id => tabIds.includes(id)) : owned) {
    try { await chrome.debugger.detach({ tabId }); } catch {}
    attached.delete(tabId);
  }
  const closed = [], kept = [];
  // Only an explicit test-run list may be removed. Never sweep another run's tabs,
  // and a tab the user selected or which is playing audio belongs to the user now.
  if (closeInactive && Array.isArray(tabIds)) {
    const mine = await openedTabs();
    for (const tabId of owned.filter(id => tabIds.includes(id) && mine.has(id))) {
      try {
        const tab = await chrome.tabs.get(tabId);
        if (tab.active || tab.audible) { kept.push(tabId); continue; }
        await chrome.tabs.remove(tabId);
        closed.push(tabId);
      } catch { kept.push(tabId); }
    }
    // Do not overwrite storage from the beginning of this await-heavy operation: another run may have opened a tab.
    const current = await openedTabs();
    for (const id of closed) current.delete(id);
    await setOpened(current);
    await chrome.storage.session.set({ workTabs: (await workTabs()).filter(id => !closed.includes(id)) });
  }
  for (const id of affected) endingTaskTabs.delete(id);
  for (const id of tabIds || [...userReleased.keys()]) userReleased.delete(id);
  return { done: true, closed, kept };
}

// The next task starts: the last one's tabs go, except one the user is on or one playing sound, which are theirs now.
async function clinqyClear() {
  await clinqyDone();
  const keep = [];
  for (const tabId of await workTabs()) {
    try {
      const t = await chrome.tabs.get(tabId);
      if (t.active || t.audible) {
        const mine = await openedTabs();
        mine.delete(tabId);
        await setOpened(mine);
      } else {
        await chrome.tabs.remove(tabId);
      }
    } catch {}
  }
  try { await chrome.storage.session.set({ workTabs: keep }); } catch {}
  return { cleared: true };
}

const attached = new Set();

// Chrome can run this script with an older manifest's permissions until the extension is reloaded: without the
// debugger permission only the debugger-based actions are unavailable, and everything else has to keep working.
// Per-tab record of things the page did on its own while a command ran: JS dialogs (and what was decided),
// file-chooser requests and downloads. Drained into the next result for that tab, so the app can see them.
const tabEvents = new Map();   // tabId → [event]
const downloads = new Map();   // guid → { tabId, url, filename, state, received, total }
const dialogPolicy = new Map(); // tabId → { accept, text, persistent }
function recordEvent(tabId, event) {
  if (tabId == null) return;
  const list = tabEvents.get(tabId) || [];
  list.push({ ...event, at: Date.now() });
  if (list.length > 50) list.shift();
  tabEvents.set(tabId, list);
}
function drainEvents(tabId) {
  const list = tabEvents.get(tabId) || [];
  tabEvents.delete(tabId);
  return list;
}
// Decision for a JS dialog. Nothing is confirmed on the user's behalf by default: an alert has only one answer
// (accept), leaving a page (beforeunload) is what navigation asked for, and confirm/prompt are dismissed unless the
// app set an explicit decision for the tab (cmd "dialogPolicy"). Every decision is reported with the dialog's text.
function dialogDecision(tabId, params) {
  const explicit = dialogPolicy.get(tabId);
  if (explicit) {
    if (!explicit.persistent) dialogPolicy.delete(tabId);
    return { accept: !!explicit.accept, promptText: explicit.text, basis: "explicit" };
  }
  return { accept: params.type === "alert" || params.type === "beforeunload", basis: "default" };
}
function onDebuggerEvent(source, method, params = {}) {
  const tabId = source && source.tabId;
  if (method === "Page.javascriptDialogOpening") {
    // A dialog would hold a tab nobody is looking at forever, so it is always answered, and the answer is recorded.
    const d = dialogDecision(tabId, params);
    const event = { kind: "dialog", type: params.type, message: String(params.message || "").slice(0, 500), url: params.url,
                    decision: d.accept ? "accepted" : "dismissed", basis: d.basis };
    if (params.type === "prompt") event.defaultPrompt = params.defaultPrompt;
    recordEvent(tabId, event);
    chrome.debugger.sendCommand(source, "Page.handleJavaScriptDialog", { accept: d.accept, ...(d.promptText != null ? { promptText: String(d.promptText) } : {}) })
      .catch((e) => recordEvent(tabId, { kind: "dialog", type: params.type, decision: "unanswered", error: String(e && e.message || e) }));
  } else if (method === "Page.fileChooserOpened") {
    // The task tab never opens a native picker. The chooser is reported, not silently swallowed: the extension has
    // no file path to hand the browser, so uploads use uploadVia/upload against the page's own file inputs.
    recordEvent(tabId, { kind: "fileChooser", mode: params.mode, state: "intercepted; not fulfilled" });
  } else if (method === "Page.downloadWillBegin" || method === "Browser.downloadWillBegin") {
    downloads.set(params.guid, { tabId, url: params.url, filename: params.suggestedFilename, state: "started", received: 0, total: null });
    recordEvent(tabId, { kind: "download", phase: "started", guid: params.guid, url: params.url, filename: params.suggestedFilename });
  } else if (method === "Page.downloadProgress" || method === "Browser.downloadProgress") {
    const known = downloads.get(params.guid) || { tabId, state: "started" };
    known.state = params.state; known.received = params.receivedBytes; known.total = params.totalBytes;
    downloads.set(params.guid, known);
    if (downloads.size > 200) {
      for (const [guid, download] of downloads) if (["completed","canceled"].includes(download.state) && guid !== params.guid) {downloads.delete(guid);break;}
    }
    if (params.state !== "inProgress") {
      recordEvent(known.tabId ?? tabId, { kind: "download", phase: params.state === "completed" ? "completed" : params.state, guid: params.guid,
                                          url: known.url, filename: known.filename, bytes: params.totalBytes ?? params.receivedBytes });
    }
  }
}
if (chrome.debugger) {
  chrome.debugger.onDetach.addListener((source) => attached.delete(source.tabId));
  chrome.debugger.onEvent.addListener(onDebuggerEvent);
}

async function cdp(tabId, method, params = {}) {
  assertRequestLive(tabId);
  if (userReleased.has(tabId)) throw new Error(releasedMessage(tabId));
  if (!attached.has(tabId)) {
    const mine = await openedTabs();
    // Only Clinqy's own tabs, or a tab the user's request handed over for this run (adoptTab), are ever attached.
    if (!mine.has(tabId) && !(await isAdopted(tabId))) throw new Error("tab " + tabId + " wasn't opened by Clinqy, so it isn't driven in the background");
    if (!chrome.debugger) throw new Error("reload the Clinqy extension to allow this action");
    try { await chrome.debugger.attach({ tabId }, "1.3"); }
    catch (e) { if (!/already attached/i.test(String(e && e.message || e))) throw e; }
    attached.add(tabId);
    if ((await workTabs()).includes(tabId)) await prepareWorkTab(tabId);
  }
  assertRequestLive(tabId);
  return await chrome.debugger.sendCommand({ tabId }, method, params);
}

// Named keys as the protocol wants them (key, code, Windows key code, and the text a key types).
const KEYS = {
  enter: ["Enter", "Enter", 13, "\r"], return: ["Enter", "Enter", 13, "\r"], tab: ["Tab", "Tab", 9],
  esc: ["Escape", "Escape", 27], escape: ["Escape", "Escape", 27], space: ["Space", " ", 32, " "],
  delete: ["Backspace", "Backspace", 8], backspace: ["Backspace", "Backspace", 8], forwarddelete: ["Delete", "Delete", 46],
  up: ["ArrowUp", "ArrowUp", 38], down: ["ArrowDown", "ArrowDown", 40], left: ["ArrowLeft", "ArrowLeft", 37],
  right: ["ArrowRight", "ArrowRight", 39], home: ["Home", "Home", 36], end: ["End", "End", 35],
  pageup: ["PageUp", "PageUp", 33], pagedown: ["PageDown", "PageDown", 34],
};
// ⌘-shortcuts that are editing commands on a Mac (the renderer doesn't map synthetic ⌘ keys to them itself).
const COMMANDS = { a: "selectAll", c: "copy", x: "cut", v: "paste", z: "undo" };

async function cdpKey(tabId, combo) {
  const parts = String(combo).toLowerCase().split("+").map((s) => s.trim()).filter(Boolean);
  const name = parts.pop() || "";
  const mods = { alt: 1, option: 1, opt: 1, ctrl: 2, control: 2, cmd: 4, command: 4, meta: 4, shift: 8 };
  const modifiers = parts.reduce((m, p) => m | (mods[p] || 0), 0);
  let [key, code, vk, text] = KEYS[name] || [];
  if (!key) {
    if (name.length !== 1) throw new Error("unknown key " + combo);
    key = modifiers & 8 ? name.toUpperCase() : name;
    code = /[a-z]/.test(name) ? "Key" + name.toUpperCase() : /[0-9]/.test(name) ? "Digit" + name : "";
    vk = name.toUpperCase().charCodeAt(0);
    text = modifiers & ~8 ? undefined : key;
  }
  const commands = modifiers === 4 && COMMANDS[name] ? [COMMANDS[name]]
    : modifiers === 12 && name === "z" ? ["redo"] : undefined;
  const base = { key, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, modifiers };
  try {
    await cdp(tabId, "Input.dispatchKeyEvent", { ...base, type: text ? "keyDown" : "rawKeyDown", text, unmodifiedText: text, commands });
  } finally {
    // Releasing an already dispatched key is cleanup, even after cancellation.
    await chrome.debugger.sendCommand({tabId}, "Input.dispatchKeyEvent", {...base,type:"keyUp"});
  }
  return { pressed: combo };
}

async function cdpClick(tabId, x, y, count = 1) {
  const at = { x: Number(x), y: Number(y) };
  if (!Number.isFinite(at.x) || !Number.isFinite(at.y) || at.x < 0 || at.y < 0 || !Number.isInteger(count) || count < 1 || count > 2)
    throw Error("invalid click coordinates or count");
  await cdp(tabId, "Input.dispatchMouseEvent", { type: "mouseMoved", ...at });
  for (let i = 1; i <= count; i++) {
    try {
      await cdp(tabId, "Input.dispatchMouseEvent", { type: "mousePressed", ...at, button: "left", buttons: 1, clickCount: i });
    } finally {
      await chrome.debugger.sendCommand({tabId}, "Input.dispatchMouseEvent", {type:"mouseReleased",...at,button:"left",buttons:0,clickCount:i});
    }
  }
  return { clicked: at };
}

// Effect receipts armed before an input (token → tab, URL and frames). Collecting merges every frame's report;
// a frame that no longer answers was replaced or navigated, which is itself an observed effect.
const receiptsArmed = new Map();
async function receiptCollect(tab, msg) {
  const armed = receiptsArmed.get(msg.token);
  if (!armed || armed.tabId !== tab.id) throw Error("no armed receipt for this tab");
  receiptsArmed.delete(msg.token);
  const out = { urlChanged: false, unreadable: false, targetStateChanged: false, targetRemoved: false, dialogOpened: false,
    focusChanged: false, focusIntoNew: false, structural: false, addedText: "", removedText: "", mutationCount: 0 };
  const quiet = Number(msg.quietMs) || 120, cap = Number(msg.capMs) || 800;
  await Promise.all(armed.frames.map(async (frameId) => {
    let r;
    try { r = await call(tab.id, frameId, "receiptCollect", [msg.token, quiet, cap]); }
    catch { out.unreadable = true; return; }
    for (const key of ["urlChanged", "targetStateChanged", "targetRemoved", "dialogOpened", "focusChanged", "focusIntoNew", "structural"]) out[key] = out[key] || !!r[key];
    for (const key of ["addedText", "removedText"]) if (r[key]) out[key] = (out[key] ? out[key] + " | " : "") + r[key];
    out.mutationCount += Number(r.mutationCount) || 0;
  }));
  try {
    const now = await chrome.tabs.get(tab.id);
    if ((now.pendingUrl || now.url || "") !== armed.url) out.urlChanged = true;
  } catch {}
  out.addedText = out.addedText.slice(0, 800); out.removedText = out.removedText.slice(0, 800);
  return out;
}

// Endpoint identity is checked before any pointer input. A lost acknowledgement never triggers a retry.
async function cdpGesture(tabId, msg) {
  if (!["hover", "right_click", "double_click", "drag"].includes(msg.gesture)) throw Error("unknown gesture");
  const map = await mapFor(tabId);
  async function point(index) {
    if (!Number.isInteger(index)) throw Error("gesture needs element ids");
    const { frameId, local } = await route(tabId, index);
    if (frameId !== 0 && !(await frameChainStable(tabId, map, frameId))) throw Error("gesture frame moved; observe again");
    const spot = await call(tabId, frameId, "locate", [local, false]);
    const offset = map.offsets[frameId];
    if (!offset || !spot.hit || !spot.still) throw Error("gesture target moved or is covered; observe again");
    const result = toTop(offset, Number(spot.px), Number(spot.py));
    if (!Number.isFinite(result.x) || !Number.isFinite(result.y)) throw Error("invalid gesture point");
    return result;
  }
  const destination = msg.gesture === "drag" ? await point(msg.toIndex) : null;
  const start = await point(msg.index);
  const button = msg.gesture === "right_click" ? "right" : "left", buttons = button === "right" ? 2 : 1;
  let held = false, last = start;
  const post = args => cdp(tabId, "Input.dispatchMouseEvent", args);
  try {
    await post({ type: "mouseMoved", ...start, button: "none", buttons: 0 });
    if (msg.gesture !== "hover") {
      for (let count = 1; count <= (msg.gesture === "double_click" ? 2 : 1); count++) {
        held = true;
        await post({ type: "mousePressed", ...start, button, buttons, clickCount: count });
        if (destination) for (let step = 1; step <= 12; step++) {
          last = { x: start.x + (destination.x - start.x) * step / 12, y: start.y + (destination.y - start.y) * step / 12 };
          await post({ type: "mouseMoved", ...last, button, buttons });
          if (msg._activity && step % 4 === 0) await renderActivity(tabId,{kind:"drag",...last});
          await new Promise(resolve => setTimeout(resolve, 20));
        }
        await post({ type: "mouseReleased", ...last, button, buttons: 0, clickCount: count });
        held = false;
      }
    }
  } finally {
    if (held) await chrome.debugger.sendCommand({tabId}, "Input.dispatchMouseEvent", { type: "mouseReleased", ...last, button, buttons: 0, clickCount: 1 }).catch(() => {});
  }
  if (destination && msg._activityState) {
    Object.assign(msg._activityState,destination);
    delete msg._activityState.localIndex;
  }
  return { delivered: true, verified: false };
}

function queueActivity(update) {
  const previous = commandQueues.get("management") || Promise.resolve();
  const next = previous.then(update).catch(() => {});
  commandQueues.set("management", next);
}

if (chrome.tabs.onUpdated) chrome.tabs.onUpdated.addListener((tabId, change) => {
  if (change.status === "complete") queueActivity(async () => {
    if ((await activityTabs()).includes(tabId)) await renderActivity(tabId, { kind: "working" });
  });
});

const popupAdoptions = new Set();
chrome.tabs.onCreated?.addListener(tab => {
  if(tab.openerTabId == null)return;
  const opener=tab.openerTabId, request=tabRequestsInFlight.get(opener);
  recordEvent(opener,{kind:"popup",tabId:tab.id,url:tab.pendingUrl || tab.url || "",state:"opened; observation required"});
  // Only a popup produced while dispatching input to an owned task tab can inherit that task.
  if(!request || request.cancelled || !["click","clickOption","cdpClick","cdpKey","cdpGesture"].includes(request.command))return;
  const adoption=withOwnership(async()=>{
    const owner=(await chrome.storage.session.get("owner"+opener))["owner"+opener];
    if(!owner || endingTaskTabs.has(opener) || !(await activityTabs()).includes(opener) || request.cancelled)return;
    const current=await chrome.tabs.get(tab.id);
    if(current.openerTabId!==opener)return;
    await chrome.storage.session.set({["owner"+tab.id]:owner,["popup"+tab.id]:{opener,runID:owner}});
    const mine=await openedTabs(); mine.add(tab.id); await setOpened(mine);
    await chrome.storage.session.set({workTabs:[...new Set([...await workTabs(),tab.id])]});
    // No tabs.update(active:true) or windows.update(focused:true): selection is logical and explicit.
    recordEvent(opener,{kind:"popup",tabId:tab.id,openerTabId:opener,state:"task-owned; select explicitly",owned:true});
  }).catch(error=>recordEvent(opener,{kind:"popup",tabId:tab.id,state:"not adopted",error:String(error?.message || error)}));
  popupAdoptions.add(adoption); void adoption.finally(()=>popupAdoptions.delete(adoption));
});
chrome.tabs.onRemoved.addListener((tabId) => queueActivity(async () => {
  await finishActivity([tabId]);
  endingTaskTabs.delete(tabId);
  attached.delete(tabId);
  maps.delete(tabId);
  focusFrames.delete(tabId);
  tabEvents.delete(tabId);
  dialogPolicy.delete(tabId);
  for (const [guid,download] of downloads) if (download.tabId === tabId) downloads.delete(guid);
  clinqyInput.delete(tabId);
  const adoption = await withOwnership(() => dropAdoption(tabId));
  if (adoption) send({ type: "adoptedReleased", tabId, runID: adoption.runID, reason: "closed" });
  userReleased.delete(tabId);
  await withOwnership(async () => {
    try { await chrome.storage.session.remove(["map" + tabId,"owner"+tabId,"popup"+tabId]); } catch {}
    const mine = await openedTabs();
    if (mine.delete(tabId)) await setOpened(mine);
    await chrome.storage.session.set({workTabs:(await workTabs()).filter(id => id !== tabId)});
  });
}));

// ---- the user's own tab, adopted for one run ----
// "Work in the tab I have open": the user's request hands one existing tab to one run. It gets the same ownership
// token as a task tab (owner<id>, workTabs) plus an adoption record, the debugger with emulated focus, and the
// activity marker. It is never activated, nor its window focused, and never closed. The moment the user acts in it
// (a real click, key or scroll that Clinqy did not send) or selects it, Clinqy lets go: the debugger detaches,
// focus emulation and the marker go, and the app is told so the run pauses until the user hands it back.
async function adoptedRecords() {
  try { return (await chrome.storage.session.get("adoptedTabs")).adoptedTabs || {}; } catch { return {}; }
}
async function setAdoptedRecords(records) {
  try { await chrome.storage.session.set({ adoptedTabs: records }); } catch {}
}
async function isAdopted(tabId) { return !!(await adoptedRecords())[tabId]; }
// Tabs the user took back during a run: actions on them stop with this reason instead of a generic ownership error.
const userReleased = new Map();   // tabId → { runID, reason }
function releasedMessage(tabId) {
  return "the user took tab " + tabId + " back (" + (userReleased.get(tabId)?.reason || "user input") + "); Clinqy let go of it and sends nothing more to it";
}
// Input Clinqy itself is sending to a tab: CDP input is trusted, so a page cannot tell it from the user's. Real
// input is whatever arrives while Clinqy is not sending any, plus a short grace for events still in flight.
const clinqyInput = new Map();   // tabId → { depth, until }
const CLINQY_INPUT_GRACE_MS = 400;
const INPUT_COMMANDS = new Set(["cdpClick", "cdpKey", "cdpType", "cdpScroll", "cdpGesture", "click", "clickOption", "fill", "fillActive",
  "setRange", "focus", "prepare", "upload", "uploadVia", "scroll"]);
function beginClinqyInput(tabId) {
  const state = clinqyInput.get(tabId) || { depth: 0, until: 0 };
  state.depth++; clinqyInput.set(tabId, state);
}
function endClinqyInput(tabId) {
  const state = clinqyInput.get(tabId);
  if (!state) return;
  state.depth = Math.max(0, state.depth - 1); state.until = Date.now() + CLINQY_INPUT_GRACE_MS;
}
function clinqyInputActive(tabId) {
  const state = clinqyInput.get(tabId);
  return !!state && (state.depth > 0 || Date.now() < state.until);
}
function hostOf(raw) {
  try { return new URL(raw).hostname.toLowerCase().replace(/^www\./, ""); } catch { return ""; }
}
function originOf(raw) { try { return new URL(raw).origin; } catch { return ""; } }
// Same rule as the app's AccessBlocklist: a host or its subdomains, "*" matching any run of characters.
function blockedHost(url, patterns) {
  const host = hostOf(url);
  if (!host) return false;
  return patterns.some(raw => {
    const pattern = String(raw || "").trim().toLowerCase();
    if (!pattern) return false;
    if (pattern.includes("*")) return new RegExp("^" + pattern.split("*").map(p => p.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*") + "$").test(host);
    const bare = hostOf(pattern.includes("://") ? pattern : "https://" + pattern) || pattern;
    return host === bare || host.endsWith("." + bare);
  });
}
async function armUserWatch(tabId, on) {
  try {
    if (on) await inject({ tabId, allFrames: true });
    await chrome.scripting.executeScript({ target: { tabId, allFrames: true }, func: on => window.__clinqy?.watchUser?.(on), args: [on] });
  } catch {} // a navigating or restricted document; the next observation re-arms it
}
async function adoptTab(msg) {
  const tabId = Number(msg.tabId), runID = msg.runID;
  if (!Number.isInteger(tabId)) throw Error("adoptTab needs a tab id");
  if (typeof runID !== "string" || !runID.length || runID.length > 128) throw Error("invalid task ownership token");
  const adopted = await withOwnership(async () => {
    const tab = await chrome.tabs.get(tabId);
    const url = tab.url || tab.pendingUrl || "";
    if (!/^(https?|file):/.test(url)) throw Error("this tab is a browser page (new tab, settings, extensions) that extensions can't drive");
    if (msg.expectedOrigin && originOf(url) !== msg.expectedOrigin) throw Error("the tab changed site since it was chosen; choose it again");
    if (Array.isArray(msg.blockedHosts) && blockedHost(url, msg.blockedHosts)) throw Error("this site is on Clinqy's blocked list and is never operated");
    const owner = (await chrome.storage.session.get("owner" + tabId))["owner" + tabId];
    if (owner && owner !== runID) throw Error("this tab is already in use by another Clinqy task");
    const records = await adoptedRecords();
    records[tabId] = { runID, url, windowId: tab.windowId, at: Date.now() };
    await setAdoptedRecords(records);
    await chrome.storage.session.set({ ["owner" + tabId]: runID, workTabs: [...new Set([...await workTabs(), tabId])] });
    userReleased.delete(tabId);
    return tab;
  });
  try {
    await cdp(tabId, "Page.enable");   // attaches and prepares it like a task tab: emulated focus, no native pickers
  } catch (error) {
    await withOwnership(() => dropAdoption(tabId));
    await restoreAdopted(tabId);
    throw error;
  }
  await armUserWatch(tabId, true);
  await showActivity(tabId);
  // No tabs.update(active) or windows.update(focused): the user keeps the tab and window they are in.
  return { id: tabId, adopted: true, url: adopted.url || adopted.pendingUrl || "", title: adopted.title || "", active: !!adopted.active, windowId: adopted.windowId };
}
// Ownership records only; callers hold the ownership lane.
async function dropAdoption(tabId) {
  const records = await adoptedRecords();
  if (!records[tabId]) return null;
  const record = records[tabId];
  delete records[tabId];
  await setAdoptedRecords(records);
  try { await chrome.storage.session.remove(["owner" + tabId]); } catch {}
  try { await chrome.storage.session.set({ workTabs: (await workTabs()).filter(id => id !== tabId) }); } catch {}
  return record;
}
// The tab behaves as it did before: no focus emulation, native pickers allowed, no debugger bar, no watcher.
async function restoreAdopted(tabId) {
  await armUserWatch(tabId, false);
  if (attached.has(tabId)) {
    for (const [method, params] of [["Emulation.setFocusEmulationEnabled", { enabled: false }], ["Page.setInterceptFileChooserDialog", { enabled: false }]]) {
      try { await chrome.debugger.sendCommand({ tabId }, method, params); } catch {}
    }
  }
  try { await chrome.debugger.detach({ tabId }); } catch {}
  attached.delete(tabId);
  clinqyInput.delete(tabId);
  dialogPolicy.delete(tabId);
}
// The user acted in an adopted tab (or the run ended): let go at once and say why.
async function releaseAdopted(tabId, reason) {
  const record = (await adoptedRecords())[tabId];
  if (!record) return { released: false };
  if (reason !== "done") userReleased.set(tabId, { runID: record.runID, reason });
  for (const [id, request] of runningRequests) if (request.tabId === tabId) markCancelled(id);
  await restoreAdopted(tabId);
  await finishActivity([tabId]);
  await withOwnership(() => dropAdoption(tabId));
  if (reason !== "done") {
    recordEvent(tabId, { kind: "adoption", state: "released", reason });
    send({ type: "adoptedReleased", tabId, runID: record.runID, reason });
  }
  return { released: true, reason };
}
async function userTookTab(tabId, reason) {
  if (reason.startsWith("input") && clinqyInputActive(tabId)) return;
  if (!(await isAdopted(tabId))) return;
  if (reason.startsWith("input") && clinqyInputActive(tabId)) return;
  await releaseAdopted(tabId, reason);
}
chrome.runtime.onMessage?.addListener((message, sender) => {
  if (message?.clinqy !== "userInput" || sender?.tab?.id == null) return;
  void userTookTab(sender.tab.id, "input:" + String(message.kind || "event").slice(0, 20));
});
// Clinqy never activates an adopted tab, so its activation is the user's.
chrome.tabs.onActivated?.addListener(({ tabId }) => { void userTookTab(tabId, "selected"); });
// The user's tabs to choose from (metadata only: nothing is attached, focused or changed).
async function adoptCandidates() {
  const [front] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  const own = new Set(await workTabs());
  const agent = await agentWindow();
  const all = await chrome.tabs.query({});
  return { lastFocusedWindow: front ? front.windowId : null, tabs: all
    .filter(t => !own.has(t.id) && (!agent || t.windowId !== agent.id) && !t.incognito)
    .slice(0, 300)
    .map(t => ({ id: t.id, windowId: t.windowId, title: (t.title || "").slice(0, 200), url: (t.url || t.pendingUrl || "").slice(0, 2048),
      active: !!t.active, lastFocusedWindow: !!front && t.windowId === front.windowId })) };
}

async function tabCommand(msg) {
  const tabId = Number(msg.tabId);
  switch (msg.cmd) {
    case "tabs": {
      // The tabs of the window in front, in strip order.
      const cur = await activeTab();
      const mine = await openedTabs();
      const list = await chrome.tabs.query({ windowId: cur.windowId });
      return { windowId: cur.windowId, tabs: list.map((t) => ({ id: t.id, title: (t.title || "").slice(0, 100), url: (t.url || t.pendingUrl || "").slice(0, 4096),
                                                                active: !!t.active, opened: mine.has(t.id), loading: t.status === "loading" })) };
    }
    case "switchTab": {
      const t = await chrome.tabs.update(tabId, { active: true });
      try { await chrome.windows.update(t.windowId, { focused: true }); } catch {}
      return { id: t.id, title: t.title || "", url: t.url || t.pendingUrl || "" };
    }
    case "closeTab": {
      const mine = await openedTabs();
      if (!mine.has(tabId)) throw new Error("tab " + tabId + " wasn't opened by Clinqy, so it stays open");
      await chrome.tabs.remove(tabId);
      mine.delete(tabId);
      await setOpened(mine);
      return { closed: tabId };
    }
  }
  return null;
}

// Tokens and page-initiated events travel with every tab-scoped result, so a caller never has to guess which
// observation an outcome belongs to or whether a dialog/download happened while it ran.
function activityKind(msg) {
  if (/^(cdpClick|click|clickOption)$/.test(msg.cmd)) return "click";
  if (/^(cdpType|fill|fillActive|cdpKey|setRange)$/.test(msg.cmd)) return "type";
  if (/^(scroll|cdpScroll)$/.test(msg.cmd)) return "scroll";
  if (/^(upload|uploadVia)$/.test(msg.cmd)) return "upload";
  if (/^(navigate|goBack)$/.test(msg.cmd)) return "navigating";
  if (/^(waitText|waitCondition)$/.test(msg.cmd)) return "waiting";
  if (msg.cmd === "cdpGesture") return msg.gesture === "drag" ? "drag" : msg.gesture === "hover" ? "hover" : "click";
  return "observing";
}
async function handle(msg) {
  msg._startedAt=Date.now();
  let out;
  const inputTab = INPUT_COMMANDS.has(msg.cmd) && msg.tabId != null ? Number(msg.tabId) : null;
  if (inputTab != null) beginClinqyInput(inputTab);
  try {
    out = await handleCommand(msg);
    if (msg._activity && msg.tabId != null && msg._activityState && !userReleased.has(Number(msg.tabId)) && !["observing","waiting"].includes(msg._activityState.kind))
      await showActivity(Number(msg.tabId), {...msg._activityState,stage:out?.ok===false || out?.skipped || out?.cancelled ? "failed" : "delivered",
        ...(out?.ok===false || out?.skipped || out?.cancelled ? {kind:"error"} : {})});
  } catch(error) {
    if (msg._activity && msg.tabId != null && !userReleased.has(Number(msg.tabId))) await showActivity(Number(msg.tabId),{kind:"error"});
    throw error;
  } finally {
    if (inputTab != null) endClinqyInput(inputTab);
  }
  const id = msg.tabId != null && msg.tabId !== "" ? Number(msg.tabId) : null;
  if (id == null || !Number.isInteger(id) || !out || typeof out !== "object" || Array.isArray(out)) return out;
  const events = drainEvents(id);
  if (events.length && out.events === undefined) out.events = events;
  out.elapsedMs = Math.max(0, Date.now() - (msg._startedAt || Date.now()));
  if (!["snapshot", "tabs", "tabInfo", "newTab", "clinqyTab", "switchTab", "closeTab", "clinqyDone", "adoptTab", "releaseAdopted"].includes(msg.cmd) && out.observation === undefined) {
    const map = maps.get(id);
    if (map && map.documentID) out.observation = { documentID: map.documentID, snapshotID: map.snapshotID };
  }
  return out;
}

async function handleCommand(msg) {
  if (msg.cmd === "reload") { setTimeout(() => chrome.runtime.reload(), 100); return { reloading: true }; }
  if (msg.cmd === "version") return { version: SCRIPT_VERSION, manifest: chrome.runtime.getManifest().version, build:SCRIPT_BUILD, capabilities:CAPABILITIES, protocolVersion:7 };
  if (msg.cmd === "adoptTab") return await adoptTab(msg);
  if (msg.cmd === "adoptCandidates") return await adoptCandidates();
  if (msg.cmd === "releaseAdopted") {
    const record = (await adoptedRecords())[Number(msg.tabId)];
    if (record && record.runID !== msg.runID) throw new Error("This tab does not belong to Clinqy's task");
    return await releaseAdopted(Number(msg.tabId), "done");
  }
  // Task commands are explicitly scoped: they cannot fall through to the user's active tab.
  if (msg.workOnly) {
    let owned = await workTabs();
    if (msg.runID) {
      const owners = await chrome.storage.session.get(owned.map(id => "owner"+id));
      owned = owned.filter(id => owners["owner"+id] === msg.runID);
    }
    if (msg.cmd === "tabs") {
      // A popup's tab event can trail its opener action; wait only for already-known ownership checks.
      await Promise.all([...popupAdoptions]);
      if (msg.runID) {
        const all=await workTabs(), ownership=await chrome.storage.session.get(all.map(id=>"owner"+id));
        owned=all.filter(id=>ownership["owner"+id]===msg.runID);
      }
      const tabs = [], adoptedNow = await adoptedRecords();
      for (const id of owned) {
        try {
          const t = await chrome.tabs.get(id);
          const popup=(await chrome.storage.session.get("popup"+id))["popup"+id];
          tabs.push({ id, title: t.title || "", url: t.url || t.pendingUrl || "", opened: true, adopted: !!adoptedNow[id],
            inherited:!!popup && popup.runID===msg.runID, openerTabId:popup?.opener });
        } catch {}
      }
      return { tabs };
    }
    if (msg.cmd === "newTab") throw new Error("Use clinqyTab to create an inactive task tab");
    const released = msg.tabId != null ? userReleased.get(Number(msg.tabId)) : null;
    if (released && (!msg.runID || released.runID === msg.runID) && !owned.includes(Number(msg.tabId)))
      throw new Error(releasedMessage(Number(msg.tabId)));
    if (msg.tabId == null || !owned.includes(Number(msg.tabId)))
      throw new Error("This tab does not belong to Clinqy's task");
    if (msg.cmd === "switchTab") return { id: Number(msg.tabId) };
  }
  if (/^(tabs|switchTab|closeTab)$/.test(msg.cmd)) return await tabCommand(msg);
  if (msg.cmd === "backgroundTab") return await backgroundTab(msg.url, msg.at);
  if (msg.cmd === "clinqyTab") return await clinqyTab(msg.url, Number(msg.width) || 1280, Number(msg.height) || 900, msg.runID);
  if (msg.cmd === "clinqyDone") {
    let ids = msg.tabIds;
    if (msg.operationIDs?.length) {
      const requests = (await chrome.storage.session.get("tabRequests")).tabRequests || {};
      ids = [...new Set([...(ids || []), ...msg.operationIDs.map(token => requests[token]?.id).filter(Number.isInteger)])];
    }
    return await clinqyDone(ids, msg.closeInactive === true);
  }
  if (msg.cmd === "clinqyClear") return await clinqyClear();
  // A window Clinqy left behind (it quit without closing it) goes; one the user took over is only forgotten.
  if (msg.cmd === "closeAgentWindow" || msg.cmd === "releaseAgentWindow") {
    const win = await agentWindow();
    try { await chrome.storage.local.remove("agentWin"); } catch {}
    if (win && msg.cmd === "closeAgentWindow") { await chrome.windows.remove(win.id); return { closed: win.id }; }
    return { closed: null };
  }
  if (msg.cmd === "newTab") return await foregroundTab(msg);
  // Every action is pinned to its explicit observed tab when available.
  const tab = msg.tabId != null ? await chrome.tabs.get(Number(msg.tabId)) : await activeTab();
  const request = runningRequests.get(msg.id);
  if(request && request.tabId == null) {
    if(tabRequestsInFlight.has(tab.id)) throw Error("this tab is busy with another request; observe again after it finishes");
    request.tabId=tab.id; tabRequestsInFlight.set(tab.id,request);
  }
  assertRequestLive(tab.id);
  if (msg.cmd === "activityStatus") {
    if (!(await activityTabs()).includes(tab.id)) return {updated:false};
    await showActivity(tab.id,{kind:msg.phase}); return {updated:true};
  }
  msg._activity = !userReleased.has(tab.id) && (msg.activity || (await activityTabs()).includes(tab.id));
  if (msg._activity) {
    const kind = activityKind(msg);
    const state = {kind,stage:"prepare"};
    if (Number.isFinite(msg.x) && Number.isFinite(msg.y)) {state.x=msg.x;state.y=msg.y;}
    else if (Number.isInteger(msg.index)) {
      try {
        const {frameId,local} = await route(tab.id,msg.index);
        const point = await call(tab.id,frameId,"activityPoint",[local]);
        const map = await mapFor(tab.id), offset = map.offsets?.[frameId];
        if (point && offset) Object.assign(state,toTop(offset,point.x,point.y));
        if (frameId===0) {state.localIndex=local;state.documentID=map.documentID;}
      } catch {} // Feedback never substitutes for the action's actual target validation below.
    }
    msg._activityState=state;
    await showActivity(tab.id,state);
  }
  if (msg.cmd === "selection") {
    const win = await chrome.windows.get(tab.windowId);
    if (!/^(https?|file):/.test(tab.url || "")) return { focused: !!win.focused, text: "" };
    const found = (await callAll(tab.id, "selection")).sort((a, b) => a.frameId - b.frameId).map((r) => r.result).find((t) => t && t.trim());
    return { focused: !!win.focused, text: found || "" };
  }
  if (msg.cmd === "captureTask") {
    // The debugger helper only accepts tabs opened by Clinqy. Never activate a tab or capture the user's display.
    if (msg.tabId == null) throw new Error("task screenshot requires an explicit tab");
    // Our task feedback is not page evidence. Hide it only for capture, restoring even on CDP failure.
    const captureVisibility = async hidden => {
      await chrome.scripting.executeScript({ target: { tabId: tab.id, frameIds: [0] },
        func: hidden => window.__clinqyActivity?.setCaptureHidden(hidden), args: [hidden] });
    };
    let captured;
    try {
      await captureVisibility(true);
      captured = await cdp(tab.id, "Page.captureScreenshot", {
        format: msg.format || "png", ...(msg.quality ? { quality: Number(msg.quality) } : {}), fromSurface: true, captureBeyondViewport: false
      });
    } finally {
      try { await captureVisibility(false); } catch {} // A navigated/closed document no longer owns this overlay.
    }
    // Freshness/coverage: which observation this picture matches, when it was taken, and what it can show.
    const meta = { capturedAt: Date.now(), coverage: "viewport", beyondViewport: false };
    const map = await mapFor(tab.id);
    if (map.documentID) { meta.documentID = map.documentID; meta.snapshotID = map.snapshotID; }
    try { await call(tab.id, 0, "check"); meta.matchesObservation = true; } catch { meta.matchesObservation = false; }
    try {
      const m = await cdp(tab.id, "Page.getLayoutMetrics");
      const v = m && m.cssVisualViewport;
      if (v) meta.viewport = { x: v.pageX, y: v.pageY, w: v.clientWidth, h: v.clientHeight, scale: v.scale };
    } catch {}
    return { image: captured.data, tabId: tab.id, ...meta };
  }
  if (msg.cmd === "tabInfo") {
    const win = await chrome.windows.get(tab.windowId);
    let live = null;
    try {
      const [result] = await chrome.scripting.executeScript({ target: { tabId: tab.id, frameIds: [0] },
        func: () => ({ url: location.href, ready: document.readyState }) });
      live = result?.result;
    } catch {} // Restricted or navigating documents retain the browser's status fallback.
    return { id: tab.id, url: live?.url || tab.url || tab.pendingUrl || "", ready: live?.ready,
      status: tab.status, title: tab.title || "", focused: !!win.focused };
  }
  if (msg.cmd === "dialogPolicy") {
    // The app's explicit decision for the next dialog on this owned tab (or every one, when persistent).
    if (msg.clear) dialogPolicy.delete(tab.id);
    else dialogPolicy.set(tab.id, { accept: !!msg.accept, text: msg.text, persistent: !!msg.persistent });
    return { dialogPolicy: msg.clear ? null : { accept: !!msg.accept, persistent: !!msg.persistent } };
  }
  if (msg.cmd === "downloadStatus") {
    return { downloads: [...downloads.entries()].filter(([, d]) => d.tabId === tab.id).map(([guid, d]) => ({ guid, ...d })) };
  }
  // A receipt is collected after the input it watched, which may have navigated or replaced the observed document.
  if (msg.cmd === "receiptCollect") return await receiptCollect(tab, msg);
  const unguarded = new Set(["snapshot", "goBack", "navigate"]);
  if (!unguarded.has(msg.cmd)) {
    const map = await mapFor(tab.id);
    if (msg.documentID !== map.documentID || msg.snapshotID !== map.snapshotID || !map.documentID || !map.snapshotID)
      throw new Error("stale browser observation; update the extension and take a new look");
    await call(tab.id, 0, "check");
    if (msg.cmd === "cdpClick" && !Number.isInteger(msg.index)) await call(tab.id,0,"coordinateGuard",[Number(msg.x),Number(msg.y)]);
    if (["cdpKey", "cdpType", "cdpScroll"].includes(msg.cmd)) {
      // A child can reload without changing its parent's URL or document token.
      for (const frame of Object.keys(map.frameTokens || {}).map(Number)) await call(tab.id, frame, "check");
      const statuses = await callAll(tab.id, "focusStatus");
      const leaves = statuses.filter(({ result }) => result.hasFocus && !result.frame);
      for (const { frameId, result } of leaves) {
        if (map.frameTokens?.[frameId]?.documentID !== result.documentID)
          throw new Error("the focused embedded document was not observed; take a new look before input");
      }
      const top = statuses.find(({ frameId }) => frameId === 0);
      if (!top || (top.result.frame && !leaves.length))
        throw new Error("the focused embedded document cannot be verified; take a new look before input");
    }
    if (msg.cmd === "cdpClick" && Number.isInteger(msg.index)) {
      const { frameId, local } = await route(tab.id, msg.index);
      if (frameId !== 0 && !(await frameChainStable(tab.id, map, frameId)))
        throw new Error("the embedded frame moved or was replaced; take a new look");
      const spot = await call(tab.id, frameId, "locate", [local]);
      const offset = map.offsets[frameId];
      const at = offset && toTop(offset, spot.px, spot.py);
      if (!offset || !spot.hit || !spot.still || Math.abs(Number(msg.x) - at.x) > 2 || Math.abs(Number(msg.y) - at.y) > 2)
        throw new Error("the click target moved or was covered; take a new look");
    }
  }
  if (msg.cmd === "cdpGesture") return await cdpGesture(tab.id, msg);
  if (msg.cmd === "cdpClick") return await cdpClick(tab.id, msg.x, msg.y, Number(msg.count) || 1);
  if (msg.cmd === "cdpKey") return await cdpKey(tab.id, msg.keys);
  if (msg.cmd === "cdpType") { await cdp(tab.id, "Input.insertText", { text: String(msg.text) }); return { typed: true }; }
  if (msg.cmd === "cdpScroll") {
    await cdp(tab.id, "Input.dispatchMouseEvent", { type: "mouseWheel", x: Number(msg.x) || 200, y: Number(msg.y) || 200, deltaX: 0, deltaY: Number(msg.dy) });
    return { scrolled: msg.dy };
  }
  if (msg.cmd === "goBack") {
    try { await chrome.tabs.goBack(msg.tabId); } catch {}
    return { ok: true };
  }
  if (msg.cmd === "navigate") {
    await chrome.tabs.update(tab.id, { url: msg.url });
    return { url: msg.url };
  }
  const page = /^(https?|file):/.test(tab.url || "");
  if (!page) {
    const win = await chrome.windows.get(tab.windowId);
    return { url: tab.url, title: tab.title, focused: !!win.focused, elements: [], restricted: true,
             error: "this tab is a browser page (new tab, settings, extensions) that extensions can't read" };
  }
  const indexed = async (name, extra = []) => {
    const { frameId, local } = await route(tab.id, msg.index);
    return await call(tab.id, frameId, name, [local, ...extra]);
  };
  switch (msg.cmd) {
    case "values": {
      const groups = new Map(), result = {};
      for (const index of (msg.indices || []).slice(0, 200)) {
        const { frameId, local } = await route(tab.id, index);
        if (!groups.has(frameId)) groups.set(frameId, []);
        groups.get(frameId).push([index, local]);
      }
      await Promise.all([...groups].map(async ([frameId, items]) => {
        const reply = await call(tab.id, frameId, "values", [items.map(([, local]) => local)]);
        for (const [global, local] of items) result[String(global)] = reply.values[String(local)] ?? null;
      }));
      return { values: result };
    }
    case "snapshot": {
      // "Focused" = this browser's window is the focused one (the page itself may not have keyboard focus
      // right after typing in the address bar). A page that can't be read says why instead of looking empty.
      const win = await chrome.windows.get(tab.windowId);
      // A discarded (memory-saver) tab has no page to script until it's shown again.
      if (tab.discarded) return { url: tab.url, title: tab.title, focused: !!win.focused, elements: [], tabId: tab.id, active: !!tab.active,
                                  error: "this tab is asleep (discarded by the browser); switch to it first" };
      try { return { ...(await snapshot(tab)), focused: !!win.focused }; }
      catch (e) {
        const why = String(e && e.message || e);
        const blocked = /can't be scripted|cannot be scripted|cannot access|web store|extensions gallery/i.test(why);
        return { url: tab.url, title: tab.title, focused: !!win.focused, elements: [], restricted: blocked,
                 error: blocked ? "this page blocks extensions (e.g. the Chrome Web Store or a built-in PDF viewer)" : "reading the page failed: " + why };
      }
    }
    case "click": case "focus": case "value": case "isActive": case "prepare": case "state": case "chosen":
    case "alive": case "focusFor":
      return await indexed(msg.cmd);
    case "clickOption": {
      const frame = Number(msg.pointFrame);
      if (!Number.isInteger(frame) || !(await mapFor(tab.id)).frameTokens?.[frame] || typeof msg.pointToken !== "string")
        throw new Error("the option has no current target token; take a new look");
      return await call(tab.id, frame, "clickOption", [msg.pointToken]);
    }
    case "activeOption": return await indexed("activeOption", [msg.want || ""]);
    case "receiptArm": {
      // Armed in the target's own frame (its state and local changes) and in the top page (dialogs, navigation).
      const token = "r" + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
      const frames = [];
      if (Number.isInteger(msg.index)) {
        const { frameId, local } = await route(tab.id, msg.index);
        await call(tab.id, frameId, "receiptArm", [token, local]);
        frames.push(frameId);
      }
      if (!frames.includes(0)) { await call(tab.id, 0, "receiptArm", [token, null]); frames.push(0); }
      receiptsArmed.set(token, { tabId: tab.id, url: tab.url || "", frames, at: Date.now() });
      for (const [old, r] of receiptsArmed) if (Date.now() - r.at > 60000) receiptsArmed.delete(old);
      return { token };
    }
    case "locate": {
      // In top-page coordinates, so a frame's element (LinkedIn's Easy Apply form) is placed right too.
      const { frameId, local } = await route(tab.id, msg.index);
      const r = await call(tab.id, frameId, "locate", [local, msg.reveal !== false]);
      const o = ((await mapFor(tab.id)).offsets || {})[frameId];
      if (!o) return { ...r, hit: frameId === 0 && r.hit };
      return { ...r, ...toTop(o, r.x, r.y), px: toTop(o, r.px, r.py).x, py: toTop(o, r.px, r.py).y };
    }
    case "uploadVia": {
      // The site's own upload button: click it in the page's world with file inputs' click()/showPicker() caught,
      // so the file goes into the input it asks for (often one it creates on the spot) and no Mac picker opens.
      const { frameId, local } = await route(tab.id, msg.index);
      await call(tab.id, frameId, "markUpload", [local]);
      let res;
      try {
        [res] = await chrome.scripting.executeScript({ target: { tabId: tab.id, frameIds: [frameId] }, world: "MAIN",
                                                       func: pickerUpload, args: [msg.name, msg.type, msg.data] });
      } catch (e) { throw new Error("the page can't be scripted: " + String(e && e.message || e)); }
      return (res && res.result) || { ok: false, why: "the page didn't answer" };
    }
    case "fill": return await indexed("fill", [msg.text]);
    case "setRange": return await indexed("setRange", [msg.state]);
    case "waitText": return await call(tab.id, 0, "waitText", [msg.text, !!msg.gone, Number(msg.ms) || 10000]);
    case "upload": {
      if (msg.index >= 0) return await indexed("upload", [msg.name, msg.type, msg.data]);
      const map = await mapFor(tab.id);
      const counts = [];
      for (const frame of Object.keys(map.frameTokens || {}).map(Number)) {
        const result = await call(tab.id, frame, "fileInputCount");
        if (result.count > 0) counts.push({ frame, count: result.count });
      }
      if (!counts.length) throw new Error("this page has no file upload field (it may use its own picker, e.g. Google Drive)");
      if (counts.length !== 1 || counts[0].count !== 1) throw new Error("ambiguous file upload fields; choose the exact input");
      return await call(tab.id, counts[0].frame, "upload", [-1, msg.name, msg.type, msg.data]);
    }
    case "findOption": {
      // The open list may be in the page or in an embedded form; report its box in top-page coordinates. The
      // dropdown's own frame is asked with its local index (so its own list is searched first).
      const offsets = (await mapFor(tab.id)).offsets || {};
      let owner = null;
      if (msg.index != null && msg.index >= 0) { try { owner = await route(tab.id, msg.index); } catch {} }
      let fallback = null;
      const answers = owner ? [{ frameId: owner.frameId, result: await call(tab.id, owner.frameId, "findOption", [msg.text, owner.local]).catch(() => ({ found: false, options: [] })) }] : [];
      if (!answers.length || !answers[0].result.found) answers.push(...(await callAll(tab.id, "findOption", [msg.text])).sort((a, b) => a.frameId - b.frameId));
      for (const { frameId, result } of answers) {
        if (frameId !== 0 && !offsets[frameId]) continue;   // a frame we can't place on screen
        if (result.found) {
          const o = offsets[frameId] || { x: 0, y: 0, sx: 1, sy: 1 };
          const a = toTop(o, result.x, result.y), b = toTop(o, result.px, result.py);
          return { ...result, pointFrame: frameId, x: a.x, y: a.y, px: b.x, py: b.y };
        }
        if (!fallback || (result.options || []).length > (fallback.options || []).length) fallback = result;
      }
      return fallback || { found: false, options: [] };
    }
    case "review": {
      const offsets = (await mapFor(tab.id)).offsets || {};
      const parts = await callAll(tab.id, "review");
      const top = (parts.find((p) => p.frameId === 0) || { result: { url: tab.url, title: tab.title, items: [], messages: [], missing: [] } }).result;
      for (const { frameId, result } of parts) if (frameId !== 0 && offsets[frameId] && result.items.length) {
        top.items = top.items.concat(result.items);
        top.missing = top.missing.concat(result.missing);
        top.messages = top.messages.concat(result.messages);
      }
      return top;
    }
    case "images": return await call(tab.id, 0, "images");
    case "read": {
      const top = await call(tab.id, 0, "readText");
      const offsets = (await mapFor(tab.id)).offsets || {};
      for (const { frameId, result } of await callAll(tab.id, "readText")) {
        if (frameId !== 0 && offsets[frameId] && result.text) top.text = (top.text + "\n\n[embedded: " + result.url + "]\n" + result.text).slice(0, 12000);
      }
      const unread = ((await mapFor(tab.id)).coverage || []);
      if (unread.length) { top.unreadFrames = unread; top.text = (top.text + "\n\n[frames not read: " + unread.map((c) => `${c.frame} (${c.reason})`).join("; ") + "]").slice(0, 12400); }
      return top;
    }
    case "tables": {
      // The page's tables plus those in embedded forms/frames that belong to it.
      const top = await call(tab.id, 0, "tables");
      const offsets = (await mapFor(tab.id)).offsets || {};
      for (const { frameId, result } of await callAll(tab.id, "tables")) {
        if (frameId !== 0 && offsets[frameId]) top.tables = top.tables.concat(result.tables.map((t) => ({ ...t, frame: result.url })));
      }
      return top;
    }
    case "activeValue": {
      const { frameId, info } = await focusedFrame(tab.id);
      focusFrames.set(tab.id, frameId);
      return info;
    }
    case "fillActive": return await call(tab.id, focusFrames.get(tab.id) || 0, "fillActive", [msg.text]);
    case "scroll": {
      if (Number.isInteger(msg.index)) {
        const {frameId,local}=await route(tab.id,msg.index);
        return await call(tab.id,frameId,"scroll",[msg.dy,local,msg.dx || 0]);
      }
      return await call(tab.id,0,"scroll",[msg.dy,null,msg.dx || 0]);
    }
    case "waitCondition": {
      const condition={...msg.condition}; let frameId=0;
      if(condition.kind === "element") {
        const target=await route(tab.id,condition.index); frameId=target.frameId; condition.index=target.local;
      }
      return await call(tab.id,frameId,"waitCondition",[condition,Math.min(30000,Number(msg.ms)||10000)]);
    }
    default: throw new Error("unknown command " + msg.cmd);
  }
}

// ---- keep the connection up ----
chrome.alarms.create("clinqy-keepalive", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(() => { connect(); send({ type: "ping" }); });
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
setInterval(() => {
  connect(); send({ type: "ping" });
  if (socket?.readyState === WebSocket.OPEN) queueActivity(async () => { for (const id of await activityTabs()) await renderActivity(id, { heartbeat: true }); });
}, 20000);
connect();
