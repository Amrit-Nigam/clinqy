// Connects to the CursorBoy app on this Mac and runs its requests against the active tab.
const URL_ = "ws://127.0.0.1:47823";
let socket = null;

function connect() {
  if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) return;
  try { socket = new WebSocket(URL_); } catch { return; }
  socket.onopen = () => send({ type: "hello", agent: navigator.userAgent });
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
  socket.onclose = () => { socket = null; };
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

// Loads page.js into the tab (once per page) and calls one of its functions.
async function inPage(tab, name, args = []) {
  await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["page.js"] });
  const [res] = await chrome.scripting.executeScript({
    target: { tabId: tab.id },
    func: (n, a) => { const f = window.__cursorboy && window.__cursorboy[n]; if (!f) throw new Error("no page function " + n); return f(...a); },
    args: [name, args],
  });
  if (res && res.error) throw new Error(String(res.error.message || res.error));
  return res && res.result;
}

async function handle(msg) {
  const tab = await activeTab();
  if (msg.cmd === "reload") { setTimeout(() => chrome.runtime.reload(), 100); return { reloading: true }; }
  if (msg.cmd === "version") return { version: chrome.runtime.getManifest().version };
  if (msg.cmd === "selection") {
    const win = await chrome.windows.get(tab.windowId);
    if (!/^(https?|file):/.test(tab.url || "")) return { focused: !!win.focused, text: "" };
    const text = await inPage(tab, "selection");
    return { focused: !!win.focused, text: text || "" };
  }
  if (msg.cmd === "tabInfo") {
    const win = await chrome.windows.get(tab.windowId);
    return { id: tab.id, url: tab.url || tab.pendingUrl || "", focused: !!win.focused };
  }
  if (msg.cmd === "newTab") {
    const t = await chrome.tabs.create({ url: msg.url, active: true });
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
    return { url: tab.url, title: tab.title, focused: !!win.focused, elements: [], restricted: true };
  }
  switch (msg.cmd) {
    case "snapshot": {
      // "Focused" = this browser's window is the focused one (the page itself may not have keyboard focus
      // right after typing in the address bar). Some tabs can't be scripted (PDF viewer): still say where we are.
      const win = await chrome.windows.get(tab.windowId);
      let snap;
      try { snap = await inPage(tab, "snapshot"); } catch { snap = null; }
      if (!snap) return { url: tab.url, title: tab.title, focused: !!win.focused, elements: [], restricted: true };
      return { ...snap, focused: !!win.focused };
    }
    case "click": case "focus": case "value": case "isActive": case "prepare": case "state":
      return await inPage(tab, msg.cmd, [msg.index]);
    case "fill": return await inPage(tab, "fill", [msg.index, msg.text]);
    case "read": return await inPage(tab, "readText");
    case "activeValue": return await inPage(tab, "activeValue");
    case "fillActive": return await inPage(tab, "fillActive", [msg.text]);
    case "scroll": return await inPage(tab, "scroll", [msg.dy]);
    default: throw new Error("unknown command " + msg.cmd);
  }
}

// ---- keep the connection up ----
chrome.alarms.create("cursorboy-keepalive", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(() => { connect(); send({ type: "ping" }); });
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
setInterval(() => { connect(); send({ type: "ping" }); }, 20000);
connect();
