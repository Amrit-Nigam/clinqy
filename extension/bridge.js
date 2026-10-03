// Connects to the Clinqy app on this Mac and runs its requests against the active tab — including the pages
// embedded in it (Greenhouse/Lever job forms, payment boxes), whose elements are listed with the rest.
const URL_ = "ws://127.0.0.1:47823";
// This script's own version, kept equal to manifest.json's. Chrome can keep running an older copy of the worker after
// a reload (the manifest is re-read, the script isn't), so the app checks this one, not the manifest's.
const SCRIPT_VERSION = "1.8.6";
let socket = null;
let retry = 1000;

function connect() {
  if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) return;
  try { socket = new WebSocket(URL_); } catch { return; }
  socket.onopen = () => {
    retry = 1000;
    send({ type: "hello", agent: navigator.userAgent, version: SCRIPT_VERSION, manifest: chrome.runtime.getManifest().version });
  };
  socket.onmessage = async (event) => {
    let msg;
    try { msg = JSON.parse(event.data); } catch { return; }
    if (!msg.id) return;
    try {
      send({ id: msg.id, ok: true, result: await handle(msg) });
    } catch (err) {
      send({ id: msg.id, ok: false, error: String(err && err.message || err) });
    }
  };
  // Back quickly when the app restarts or Chrome wakes the worker (1 s, doubling to 10 s).
  socket.onclose = () => { socket = null; setTimeout(connect, retry); retry = Math.min(retry * 2, 10000); };
  socket.onerror = () => {};
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
const runner = async (n, a) => {
  try {
    const f = window.__clinqy && window.__clinqy[n];
    if (!f) return { __error: "no page function " + n };
    return { __ok: await f(...a) };
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
  return { ok: caught.files.length > 0, files: [...caught.files].map((f) => f.name) };
};

async function inject(target) {
  try { await chrome.scripting.executeScript({ target, files: ["page.js"] }); } catch {}
}

async function call(tabId, frameId, name, args = []) {
  const target = { tabId, frameIds: [frameId] };
  await inject(target);
  let res;
  try { [res] = await chrome.scripting.executeScript({ target, func: runner, args: [name, args] }); }
  catch (e) { throw new Error("the page can't be scripted: " + String(e && e.message || e)); }
  const out = res && res.result;
  if (!out) throw new Error("the page didn't answer");
  if (out.__error) throw new Error(out.__error);
  return out.__ok;
}

// Every frame's answer that worked: [{frameId, result}].
async function callAll(tabId, name, args = []) {
  const target = { tabId, allFrames: true };
  await inject(target);
  let res = [];
  try { res = await chrome.scripting.executeScript({ target, func: runner, args: [name, args] }); } catch {}
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

async function snapshot(tab) {
  const top = await call(tab.id, 0, "snapshot");
  const list = top.elements.map((e) => ({ key: e.key, frameId: 0, local: e.i, e }));
  const offsets = { 0: { x: 0, y: 0 } };
  const elements = top.elements;
  const extraText = [];
  if (top.frames && top.frames.length) {
    const subs = (await callAll(tab.id, "snapshot")).filter((s) => s.frameId !== 0 && /^https?:/.test(s.result.url || ""));
    const free = [...top.frames];
    for (const { frameId, result: sub } of subs) {
      // Which visible frame box is this page? Same address, or (failing that) the only one of exactly its size.
      let k = free.findIndex((f) => f.src && samePage(f.src, sub.url));
      if (k < 0) {
        const sized = free.map((f, j) => [f, j]).filter(([f]) => Math.abs(f.w - sub.viewport.w) <= 2 && Math.abs(f.h - sub.viewport.h) <= 2);
        if (sized.length === 1) k = sized[0][1];
      }
      if (k < 0) continue;
      const f = free.splice(k, 1)[0];
      offsets[frameId] = { x: f.x, y: f.y };
      let host = "frame";
      try { host = new URL(sub.url).hostname; } catch {}
      for (const e of sub.elements) {
        const x = e.x + f.x, y = e.y + f.y;
        if (y + e.h < 0 || y > top.viewport.h || x + e.w < 0 || x > top.viewport.w) continue;
        const moved = { ...e, x, y, frame: host };
        elements.push(moved);
        list.push({ key: e.key != null ? host + "|" + e.key : null, frameId, local: e.i, e: moved });
      }
      top.messages = (top.messages || []).concat(sub.messages || []);
      if (sub.text) extraText.push(`[${host}] ${sub.text}`);
      top.below = (top.below || 0) + (sub.below || 0);
      top.above = (top.above || 0) + (sub.above || 0);
      if (sub.panes && sub.panes.length) top.panes = (top.panes || []).concat(sub.panes.map((p) => ({ ...p, frame: host })));
    }
  }
  await saveMap(tab.id, { ...assignIds(await mapFor(tab.id), top.url, list), offsets });
  if (extraText.length) top.text = [top.text, ...extraText].filter(Boolean).join(" · ").slice(0, 2200);
  return { ...top, elements, tabId: tab.id, active: !!tab.active };
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

chrome.tabs.onRemoved.addListener(async (tabId) => {
  maps.delete(tabId);
  focusFrames.delete(tabId);
  try { await chrome.storage.session.remove("map" + tabId); } catch {}
  const mine = await openedTabs();
  if (mine.delete(tabId)) await setOpened(mine);
});

async function tabCommand(msg) {
  const tabId = Number(msg.tabId);
  switch (msg.cmd) {
    case "tabs": {
      // The tabs of the window in front, in strip order.
      const cur = await activeTab();
      const mine = await openedTabs();
      const list = await chrome.tabs.query({ windowId: cur.windowId });
      return { windowId: cur.windowId, tabs: list.map((t) => ({ id: t.id, title: (t.title || "").slice(0, 100), url: (t.url || t.pendingUrl || "").slice(0, 200),
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

async function handle(msg) {
  if (/^(tabs|switchTab|closeTab)$/.test(msg.cmd)) return await tabCommand(msg);
  // A command may name its tab (a snapshot of a background tab, acting on a tab the app pinned); else the one in front.
  const tab = msg.tabId != null && msg.cmd !== "goBack" ? await chrome.tabs.get(Number(msg.tabId)) : await activeTab();
  if (msg.cmd === "reload") { setTimeout(() => chrome.runtime.reload(), 100); return { reloading: true }; }
  if (msg.cmd === "version") return { version: SCRIPT_VERSION, manifest: chrome.runtime.getManifest().version };
  if (msg.cmd === "selection") {
    const win = await chrome.windows.get(tab.windowId);
    if (!/^(https?|file):/.test(tab.url || "")) return { focused: !!win.focused, text: "" };
    const found = (await callAll(tab.id, "selection")).sort((a, b) => a.frameId - b.frameId).map((r) => r.result).find((t) => t && t.trim());
    return { focused: !!win.focused, text: found || "" };
  }
  if (msg.cmd === "tabInfo") {
    const win = await chrome.windows.get(tab.windowId);
    return { id: tab.id, url: tab.url || tab.pendingUrl || "", focused: !!win.focused };
  }
  if (msg.cmd === "newTab") {
    const t = await chrome.tabs.create({ url: msg.url, active: true });
    const mine = await openedTabs();
    mine.add(t.id);
    await setOpened(mine);
    return { id: t.id };
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
    case "activeOption": return await indexed("activeOption", [msg.want || ""]);
    case "locate": {
      // In top-page coordinates, so a frame's element (LinkedIn's Easy Apply form) is placed right too.
      const { frameId, local } = await route(tab.id, msg.index);
      const r = await call(tab.id, frameId, "locate", [local]);
      const o = ((await mapFor(tab.id)).offsets || {})[frameId];
      if (!o) return { ...r, hit: frameId === 0 && r.hit };
      return { ...r, x: r.x + o.x, y: r.y + o.y, px: r.px + o.x, py: r.py + o.y };
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
    case "waitText": return await call(tab.id, 0, "waitText", [msg.text, !!msg.gone, Number(msg.ms) || 10000]);
    case "upload": {
      if (msg.index >= 0) return await indexed("upload", [msg.name, msg.type, msg.data]);
      try { return await call(tab.id, 0, "upload", [-1, msg.name, msg.type, msg.data]); }
      catch (e) {
        // No upload field on the page itself: try the embedded forms.
        for (const frameId of Object.keys((await mapFor(tab.id)).offsets || {}).map(Number).filter((f) => f !== 0)) {
          try { return await call(tab.id, frameId, "upload", [-1, msg.name, msg.type, msg.data]); } catch {}
        }
        throw e;
      }
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
          const o = offsets[frameId] || { x: 0, y: 0 };
          return { ...result, x: result.x + o.x, y: result.y + o.y, px: result.px + o.x, py: result.py + o.y };
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
    case "read": {
      const top = await call(tab.id, 0, "readText");
      const offsets = (await mapFor(tab.id)).offsets || {};
      for (const { frameId, result } of await callAll(tab.id, "readText")) {
        if (frameId !== 0 && offsets[frameId] && result.text) top.text = (top.text + "\n\n[embedded: " + result.url + "]\n" + result.text).slice(0, 12000);
      }
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
    case "scroll": return await call(tab.id, 0, "scroll", [msg.dy]);
    default: throw new Error("unknown command " + msg.cmd);
  }
}

// ---- keep the connection up ----
chrome.alarms.create("clinqy-keepalive", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(() => { connect(); send({ type: "ping" }); });
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
setInterval(() => { connect(); send({ type: "ping" }); }, 20000);
connect();
