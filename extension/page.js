// Runs inside web pages (in the extension's isolated world). Installed by background.js before each command;
// all page-side logic lives here so helpers are available to every command.
(() => {
  const HELPER_VERSION = 8;
  const waits = new Set();
  function cancelWaits() { for (const cancel of [...waits]) cancel(); }
  if (window.__clinqy?.protocolVersion === 7 && window.__clinqy?.version === HELPER_VERSION) return;
  window.__clinqy?.dispose?.();
  const documentID = typeof crypto.randomUUID === "function" ? crypto.randomUUID()
    : Array.from(crypto.getRandomValues(new Uint8Array(16)), (v) => v.toString(16).padStart(2, "0")).join("");
  let snapshotID = null;
  let revision = 0;
  let observedGeometry = null;
  const optionTargets = new Map();
  let nextOptionTarget = 0;
  const frameNodes = new WeakMap();
  let nextFrameNode = 0;
  const elementNodes = new WeakMap();
  let nextElementNode = 0;

const squash = (s) => String(s || "").replace(/\s+/g, " ").trim();
const norm = (s) => squash(s).toLowerCase();

function visible(el) {
  const r = el.getBoundingClientRect();
  if (r.width < 2 || r.height < 2 || r.bottom < 0 || r.right < 0 || r.top > innerHeight || r.left > innerWidth) return false;
  const cs = getComputedStyle(el);
  return cs.visibility !== "hidden" && cs.display !== "none" && Number(cs.opacity) > 0.05;
}

// An element's shadow root, closed ones too (content scripts may open them; only custom elements carry one in practice).
function shadowOf(n) {
  if (n.shadowRoot) return n.shadowRoot;
  if (!n.tagName || !n.tagName.includes("-")) return null;
  try { return typeof chrome !== "undefined" && chrome.dom && chrome.dom.openOrClosedShadowRoot ? chrome.dom.openOrClosedShadowRoot(n) : null; } catch { return null; }
}

// Is `node` inside `box`, crossing shadow-root boundaries (contains() stops at them)?
function within(box, node) {
  for (let n = node, k = 0; n && k < 200; n = n.parentNode || n.host, k++) if (n === box) return true;
  return false;
}

// The element that really has the caret: document.activeElement only names the shadow host.
function deepActive() {
  let a = document.activeElement;
  for (let k = 0; a && k < 20; k++) { const s = shadowOf(a); if (!s || !s.activeElement) break; a = s.activeElement; }
  return a;
}

// The element on top at a viewport point, looking inside shadow roots.
function topAt(x, y) {
  let top = document.elementFromPoint(x, y);
  for (let k = 0; top && k < 10; k++) { const s = shadowOf(top); const inner = s && s.elementFromPoint(x, y); if (!inner || inner === top) break; top = inner; }
  return top;
}

// Would a real click at the element's centre land on it (not on a sticky footer, backdrop or popup over it)?
function hitAt(el) {
  const r = el.getBoundingClientRect();
  const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
  if (r.width < 1 || r.height < 1 || cx < 0 || cy < 0 || cx >= innerWidth || cy >= innerHeight) return false;
  const top = topAt(cx, cy);
  return !!top && (within(el, top) || within(top, el));
}

// A viewport point where a real click lands on the element: the centre, else the first of a few spots around it
// that isn't covered (a badge over a button's middle, a half-hidden row). null = covered everywhere.
function hitPoint(el) {
  const r = el.getBoundingClientRect();
  if (r.width < 1 || r.height < 1) return null;
  const spots = [[0.5, 0.5], [0.3, 0.5], [0.7, 0.5], [0.5, 0.3], [0.5, 0.7], [0.15, 0.5], [0.85, 0.5], [0.25, 0.25], [0.75, 0.75]];
  for (const [fx, fy] of spots) {
    const x = r.left + r.width * fx, y = r.top + r.height * fy;
    if (x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) continue;
    const top = topAt(x, y);
    if (top && (within(el, top) || within(top, el))) return { x, y };
  }
  return null;
}

// Waits (briefly) until the element stops moving: a click aimed while a popup slides in or a list re-lays out
// lands beside it. Timers, not animation frames, which a background tab never runs.
async function settle(el, ms = 400) {
  const at = () => { const r = el.getBoundingClientRect(); return [r.left, r.top, r.width, r.height].map(Math.round).join(","); };
  let prev = at();
  for (const end = performance.now() + ms; performance.now() < end && el.isConnected;) {
    await new Promise((res) => setTimeout(res, 40));
    const now = at();
    if (now === prev) return true;
    prev = now;
  }
  return false;
}

// Loose text matching for choosing options: case, accents, punctuation and common short forms don't matter.
const ALIASES = [
  ["united states", "united states of america", "usa", "us", "u s", "u s a", "america"],
  ["united kingdom", "uk", "u k", "great britain", "britain", "england"],
  ["united arab emirates", "uae"], ["india", "bharat"], ["bengaluru", "bangalore"], ["mumbai", "bombay"], ["chennai", "madras"],
  ["kolkata", "calcutta"], ["gurugram", "gurgaon"], ["new delhi", "delhi"], ["netherlands", "holland", "the netherlands"],
  ["south korea", "korea republic of", "republic of korea", "korea"], ["russia", "russian federation"],
  ["senior", "sr"], ["junior", "jr"], ["mister", "mr"], ["doctor", "dr"],
  ["yes", "y", "true"], ["no", "n", "false"],
  ["prefer not to say", "prefer not to answer", "decline to answer", "decline to self identify", "i don t wish to answer",
   "i do not wish to answer", "do not wish to disclose", "rather not say", "not specified"],
  ["male", "man"], ["female", "woman"], ["non binary", "nonbinary"],
];
const plain = (s) => norm(s).normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/[^a-z0-9+]+/g, " ").trim();
const aliasOf = (() => {
  const m = new Map();
  ALIASES.forEach((group) => group.forEach((w) => m.set(w, group[0])));
  return (s) => m.get(s) || s;
})();
// How well an option's text matches what's wanted, 0 (no) to 1 (exact). Numbers must agree ("1-2 years" never
// picks "10+ years").
function matchScore(want, have) {
  const w = plain(want), h = plain(have);
  if (!w || !h) return 0;
  if (w === h || aliasOf(w) === aliasOf(h)) return 1;
  const nums = (s) => s.match(/\d+/g) || [];
  const wn = nums(w), hn = nums(h);
  if (wn.length && !wn.every((n) => hn.includes(n))) return 0;
  // Whole words only: "Male" isn't in "Female", "No" doesn't start "Not specified".
  if (h.startsWith(w + " ")) return 0.9;
  if ((" " + h + " ").includes(" " + w + " ")) return 0.8;
  if (h.length > 2 && (" " + w + " ").includes(" " + h + " ")) return 0.7;
  if (w.length >= 4 && h.startsWith(w)) return 0.75;   // typed the start of it ("Indi" → "India")
  const wt = new Set(w.split(" ").map(aliasOf)), ht = new Set(h.split(" ").map(aliasOf));
  let both = 0;
  wt.forEach((t) => { if (ht.has(t)) both++; });
  return both ? 0.6 * both / Math.max(wt.size, ht.size) : 0;
}
function bestMatch(want, items, textOf) {
  let best = null, score = 0, tied = false;
  for (const it of items) {
    const sc = matchScore(want, textOf(it));
    if (sc > score) { best = it; score = sc; tied = false; }
    else if (sc === score && sc > 0 && it !== best) tied = true;
  }
  return score >= 0.5 && !tied ? best : null;
}

// The element's nearest scrolling ancestor (a modal's body, a side panel), or null when that's the page itself.
// `memo` (a Map) lets a snapshot resolve each ancestor once.
function scrollBoxOf(el, memo) {
  const up = (n) => n.parentElement || (n.getRootNode && n.getRootNode().host) || null;
  const chain = [];
  let found = null;
  for (let p = up(el); p && p !== document.body && p !== document.documentElement; p = up(p)) {
    if (memo && memo.has(p)) { found = memo.get(p); break; }
    chain.push(p);
    if (p.scrollHeight > p.clientHeight + 4 && /^(auto|scroll|overlay)$/.test(getComputedStyle(p).overflowY)) { found = p; break; }
  }
  if (memo) chain.forEach((n) => memo.set(n, found));
  return found;
}

// Brings an element into view, scrolling every box it sits in (instantly: a page's smooth scrolling would leave
// the rect we read next stale). If a sticky header/footer inside a scrolling modal still covers it, centre it.
function reveal(el) {
  el.scrollIntoView({ block: "nearest", inline: "nearest", behavior: "instant" });
  if (hitAt(el)) return;
  const box = scrollBoxOf(el);
  if (box) {
    const br = box.getBoundingClientRect(), r = el.getBoundingClientRect();
    box.scrollBy({ top: (r.top + r.height / 2) - (br.top + br.height / 2), behavior: "instant" });
  } else el.scrollIntoView({ block: "center", inline: "nearest", behavior: "instant" });
}

// A modal's (or scrolling panel's) name, for "5 more fields below in “Apply to Acme”".
function paneName(box) {
  const d = box.closest("[role=dialog], [role=alertdialog], dialog, [aria-modal=true]");
  const n = d || box;
  const h = n.querySelector("h1, h2, h3, [role=heading]");
  return { name: squash(n.getAttribute("aria-label") || labelledBy(n) || (h && h.innerText) || "").slice(0, 60), modal: !!d };
}

// Which code editor (if any) an element is part of: they re-indent and auto-close what's typed.
function editorKind(el) {
  const kinds = [[".monaco-editor", "monaco"], [".cm-editor", "codemirror"], [".CodeMirror", "codemirror"], [".ace_editor", "ace"]];
  for (let n = el, k = 0; n && k < 10; n = (n.getRootNode && n.getRootNode().host) || null, k++) {
    if (!n.closest) continue;
    for (const [sel, kind] of kinds) { const box = n.closest(sel); if (box) return { kind, box }; }
  }
  return null;
}

// A code editor's text: its hidden input only holds a line or so, so read the rendered lines (the visible part;
// editors only draw what's on screen).
function editorText(ed) {
  const sel = { monaco: ".view-line", codemirror: ".cm-line, pre.CodeMirror-line", ace: ".ace_line" }[ed.kind];
  const lines = [...ed.box.querySelectorAll(sel)];
  if (ed.kind === "monaco") lines.sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top);
  return lines.map((l) => l.innerText.replace(/\u00a0/g, " ")).join("\n");
}

// Text of the elements an aria-labelledby points at (how Google Forms and many apps name their fields).
function labelledBy(el) {
  const ids = (el.getAttribute && el.getAttribute("aria-labelledby") || "").split(/\s+/).filter(Boolean);
  return squash(ids.map((id) => { const n = document.getElementById(id); return n ? n.innerText : ""; }).join(" "));
}

// The question a field, radio or checkbox answers: its labelled group, fieldset legend, or the heading of its
// list item (Google Forms puts every question in a [role=listitem] with a [role=heading]).
function questionOf(el) {
  let q = labelledBy(el);
  for (let p = el.parentElement, hops = 0; !q && p && hops < 10; p = p.parentElement, hops++) {
    const role = p.getAttribute("role") || "";
    if (/^(radiogroup|group|listbox|list)$/.test(role) || p.tagName === "FIELDSET") {
      q = labelledBy(p) || p.getAttribute("aria-label") || (p.querySelector(":scope > legend") || {}).innerText || "";
    }
    if (!q && (role === "listitem" || p.tagName === "FIELDSET")) {
      const h = p.querySelector("[role=heading], legend");
      if (h && !h.contains(el)) q = h.innerText;
    }
  }
  return squash(q).slice(0, 100);
}

function optionText(o) {
  const dv = o.getAttribute("data-value");
  return squash(dv !== null ? dv : (o.getAttribute("aria-label") || o.innerText));
}

// A custom dropdown's choices, whether open or not (Google Forms keeps them in the DOM).
function optionTexts(el) {
  const lists = [el];
  const owned = el.getAttribute("aria-controls") || el.getAttribute("aria-owns");
  if (owned) owned.split(/\s+/).forEach((id) => { const n = document.getElementById(id); if (n) lists.push(n); });
  const out = [];
  for (const l of lists) l.querySelectorAll("[role=option]").forEach((o) => { const t = optionText(o); if (t && !out.includes(t)) out.push(t); });
  return out;
}

// Error and status messages on the page ("This is a required question", "Invalid email").
function pageMessages() {
  const out = [];
  document.querySelectorAll("[role=alert], [aria-live=assertive], [aria-live=polite], .error, .errors, .invalid-feedback, [class*=error-message], [class*=errorMessage]")
    .forEach((m) => { const t = squash(m.innerText); if (t.length > 2 && t.length < 200 && visible(m) && !out.includes(t)) out.push(t); });
  return out.slice(0, 8);
}

const SEL = [
  "a[href]", "button", "input:not([type=hidden])", "textarea", "select", "summary", "label[for]",
  "[role=button]", "[role=link]", "[role=tab]", "[role=menuitem]", "[role=checkbox]", "[role=radio]",
  "[role=option]", "[role=switch]", "[role=textbox]", "[role=combobox]", "[role=searchbox]", "[role=treeitem]", "[role=listbox]",
  "[contenteditable=''], [contenteditable=true]", "[onclick]", "[tabindex]:not([tabindex='-1'])",
].join(",");

// Cache only the candidate set. Geometry, labels, values and checked states are read fresh on every snapshot.
let candidateCache = null, shadowHosts = [];
const candidateObserver = new MutationObserver(() => { candidateCache = null; });
function candidates() {
  if (candidateObserver.takeRecords().length) candidateCache = null;
  if (candidateCache && shadowHosts.every(([host, root]) => shadowOf(host) === root)) return candidateCache;
  candidateObserver.disconnect();
  const nodes = [], hosts = [];
  const walk = (root) => {
    candidateObserver.observe(root, { subtree: true, childList: true, attributes: true,
      attributeFilter: ["role", "type", "href", "for", "contenteditable", "onclick", "tabindex"] });
    root.querySelectorAll(SEL).forEach((el) => nodes.push(el));
    const tw = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
    for (let n = tw.nextNode(); n; n = tw.nextNode()) {
      if (n.hasAttribute("data-clinqy-overlay")) continue;
      const shadow = shadowOf(n);
      if (n.tagName && n.tagName.includes("-")) hosts.push([n, shadow]);
      if (shadow) walk(shadow);
    }
  };
  walk(document);
  shadowHosts = hosts;
  return candidateCache = nodes;
}

// What an element is, as listed to the model (null = not worth listing). Shared by snapshot and re-finding.
function describe(el) {
  const tag = el.tagName.toLowerCase();
  const role = el.getAttribute("role") || (tag === "a" ? "link" : tag === "input" ? (el.type || "text") : tag);
  // Fields are named by their label, never by what's typed in them (so a name stays stable run to run).
  const isField = tag === "input" || tag === "textarea" || tag === "select";
  const labelText = isField && el.labels && el.labels[0] ? el.labels[0].innerText.replace(el.innerText || "", "") : "";
  const listbox = role === "listbox" || (role === "combobox" && tag !== "input");
  const text = squash(el.getAttribute("aria-label") || labelledBy(el) || (isField || listbox ? "" : el.innerText) || labelText ||
    el.getAttribute("placeholder") || el.title || el.getAttribute("alt") || el.name || (tag === "button" || tag === "a" ? el.innerText : "") ||
    (tag === "input" && el.type === "submit" ? el.value : "") || "").slice(0, 100);
  const editable = tag === "input" || tag === "textarea" || el.isContentEditable || /textbox|combobox|searchbox/.test(role);
  if (!text && !editable && !listbox) return null;
  // Expanded state normally belongs to the controlling combobox, not its listbox. A visible
  // listbox without that attribute (including a persistent list) still exposes selectable options.
  // Explicitly collapsed lists remain non-actionable; hidden lists are excluded by geometry.
  if (role === "option") { const lb = el.closest("[role=listbox]"); if (lb && lb.getAttribute("aria-expanded") === "false" && lb !== el) return null; }
  // A label is listed through its control (one line per field or choice, not two) — unless the control is hidden
  // (styled checkboxes), when the label is the thing to click.
  if (tag === "label" && el.querySelector("[role=radio], [role=checkbox], [role=switch], input[type=radio], input[type=checkbox]")) return null;
  if (tag === "label" && el.control && el.control.type !== "file" && el.control.getClientRects().length && getComputedStyle(el.control).opacity !== "0") return null;
  const q = questionOf(el);
  return { tag, role, text, editable, listbox, q: q && norm(q) !== norm(text) && !norm(text).includes(norm(q)) ? q : "" };
}

// Visible text that isn't part of any listed element (confirmation messages, job details, prices), in reading order.
function visibleText(listed, budgetMs) {
  const end = performance.now() + budgetMs, vh = innerHeight, out = [];
  let size = 0;
  const tw = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
  for (let n = tw.nextNode(); n && size < 1500 && performance.now() < end; n = tw.nextNode()) {
    const t = squash(n.nodeValue);
    if (t.length < 2) continue;
    const p = n.parentElement;
    if (!p || /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|OPTION)$/.test(p.tagName)) continue;
    let inside = false;
    for (let a = p, k = 0; a && k < 8; a = a.parentElement, k++) if (listed.has(a)) { inside = true; break; }
    if (inside) continue;
    const r = p.getBoundingClientRect();
    if (r.bottom < 0 || r.top > vh || r.width < 1 || r.height < 1) continue;
    const cs = getComputedStyle(p);
    if (cs.visibility === "hidden" || cs.display === "none" || Number(cs.opacity) < 0.05) continue;
    if (out.length && out[out.length - 1] === t) continue;
    out.push(t);
    size += t.length + 3;
  }
  return out.join(" · ").slice(0, 1500);
}

// Identity follows the actual DOM object across listings, never its ordinal among identical labels.
// Semantic identity is included so a framework repurposing the same node also invalidates old references.
function keys(out, picked) {
  out.forEach((it, k) => {
    const el = picked[k];
    if (!elementNodes.has(el)) elementNodes.set(el, ++nextElementNode);
    it.key = documentID + ":node:" + elementNodes.get(el) + "|" + nodeIdentity(el, it);
  });
}

function nodeIdentity(el, d) {
  return JSON.stringify([d.role, d.text, d.q || "", el.tagName, el.id || "", el.getAttribute("name"),
    el.getAttribute("type"), el.getAttribute("href"), el.getAttribute("formaction"), el.getAttribute("aria-controls")]);
}

function frameBoxes() {
  const vw = innerWidth, vh = innerHeight;
  const frames = [...document.querySelectorAll("iframe, frame")].map((f) => {
      const r = f.getBoundingClientRect(), cs = getComputedStyle(f);
      if (!frameNodes.has(f)) frameNodes.set(f, ++nextFrameNode);
      // Deterministic identity: the extension API names the frame this element hosts (Chrome 132+), so the bridge
      // needn't guess from URL/size. Absent API or a detached element leaves it null and the bridge falls back.
      let frameId = null;
      try { if (typeof chrome !== "undefined" && chrome.runtime && chrome.runtime.getFrameId) { const id = chrome.runtime.getFrameId(f); if (Number.isInteger(id) && id >= 0) frameId = id; } } catch {}
      // Same-origin inline documents have no unique URL. Read their isolated-world helper identity,
      // never a page-controlled DOM attribute; cross-origin/sandboxed access fails closed.
      let inlineDocumentID = null;
      try {
        if (/^about:(blank|srcdoc)(?:[#?]|$)/.test(f.contentWindow.location.href))
          inlineDocumentID = f.contentWindow.__clinqy?.documentID || null;
      } catch {}
      // CSS transforms: a scaled frame draws its content at rect.width / offsetWidth; a rotated or skewed one has
      // no translation-only placement, which the bridge refuses to guess at.
      const ow = f.offsetWidth || 0, oh = f.offsetHeight || 0;
      const sx = ow > 0 && r.width > 0 ? r.width / ow : 1, sy = oh > 0 && r.height > 0 ? r.height / oh : 1;
      let rotated = false;
      for (let n = f; n && n.nodeType === 1 && !rotated; n = n.parentElement) {
        const t = n === f ? cs.transform : getComputedStyle(n).transform;
        if (!t || t === "none") continue;
        const m = /^matrix\(([^)]+)\)$/.exec(t);
        if (!m) { rotated = true; break; }
        const v = m[1].split(",").map(Number);
        if (Math.abs(v[1]) > 1e-6 || Math.abs(v[2]) > 1e-6) rotated = true;
      }
      const scaleX = Math.abs(sx - 1) < 0.005 ? 1 : sx, scaleY = Math.abs(sy - 1) < 0.005 ? 1 : sy;
      return { nodeToken: frameNodes.get(f), frameId, inlineDocumentID, src: f.src || "", x: r.left + (f.clientLeft + (parseFloat(cs.paddingLeft) || 0)) * scaleX,
               y: r.top + (f.clientTop + (parseFloat(cs.paddingTop) || 0)) * scaleY,
               w: f.clientWidth, h: f.clientHeight, sx: scaleX, sy: scaleY, rotated, hidden: cs.visibility === "hidden" || cs.display === "none" };
    }).filter((f) => !f.hidden && f.w >= 80 && f.h >= 40 && f.x < vw && f.y < vh && f.x + f.w * f.sx > 0 && f.y + f.h * f.sy > 0);
  return { frames };
}

function snapshot() {
  snapshotID = documentID + ":" + (++revision);
  optionTargets.clear();
  const started = performance.now();
  const vw = innerWidth, vh = innerHeight;
  observedGeometry={width:vw,height:vh,x:scrollX,y:scrollY};
  const seen = new Set(), listed = new Set();
  const out = [], picked = [], sigs = [];
  const act = deepActive();
  let above = 0, below = 0, skipped = 0, truncated = false;
  const boxOf = new Map(), boxRects = new Map(), panes = new Map();
  const countable = (el) => el.getClientRects().length && (/^(INPUT|TEXTAREA|SELECT|BUTTON)$/.test(el.tagName)
    || /^(listbox|radio|checkbox|textbox|combobox|switch|button)$/.test(el.getAttribute("role") || ""));
  const allCandidates = candidates();
  // Controls come before long link/list collections so a large navigation list cannot hide Cancel or Submit.
  // Bounds limit sorting work; the explicit truncation flag is carried to the agent.
  const priority = [], ordinary = [];
  for (const el of allCandidates.slice(0, 10000)) {
    if (/^(BUTTON|INPUT|TEXTAREA|SELECT)$/.test(el.tagName) || /^(button|textbox|combobox|checkbox|radio|switch)$/.test(el.getAttribute("role") || "")) priority.push(el);
    else ordinary.push(el);
  }
  if (allCandidates.length > 10000) truncated = true;
  for (const el of [...priority, ...ordinary]) {
    if (seen.has(el)) continue;
    seen.add(el);
    if (performance.now() - started > 700) { truncated = true; break; }   // huge pages: list what we have
    try {
      const r = el.getBoundingClientRect();
      if (r.width < 3 || r.height < 3) continue;
      // Scrolled out of its own box (LinkedIn's Easy Apply modal body): not visible even though it's inside the
      // viewport. Counted per box, so the model knows that box — not the page — needs scrolling.
      const box = scrollBoxOf(el, boxOf);
      if (box) {
        let br = boxRects.get(box);
        if (!br) { br = box.getBoundingClientRect(); boxRects.set(box, br); }
        if (br.bottom > 0 && br.top < vh && (r.bottom <= br.top + 2 || r.top >= br.bottom - 2)) {
          if (countable(el)) {
            const p = panes.get(box) || { above: 0, below: 0 };
            if (r.bottom <= br.top + 2) p.above++; else p.below++;
            panes.set(box, p);
          }
          continue;
        }
      }
      if (r.bottom < 0 || r.top > vh) {
        // Off screen: just count fields and buttons, so the model knows to scroll.
        if (countable(el)) { if (r.bottom < 0) above++; else below++; }
        continue;
      }
      if (r.right < 0 || r.left > vw) continue;
      const cs = getComputedStyle(el);
      if (cs.visibility === "hidden" || cs.display === "none" || Number(cs.opacity) < 0.05) continue;
      const d = describe(el);
      if (!d) continue;
      // Is it actually the thing on top at its centre (not covered by a modal)?
      const cx = Math.min(vw - 1, Math.max(0, r.left + r.width / 2)), cy = Math.min(vh - 1, Math.max(0, r.top + r.height / 2));
      const top = document.elementFromPoint(cx, cy);
      // Covered only if no spot on it can be clicked (a badge over a button's middle leaves its sides free).
      const covered = top && !(within(el, top) || within(top, el)) && !hitPoint(el);
      const { tag, role, text } = d;
      const item = { i: out.length, role, text, x: r.left, y: r.top, w: r.width, h: r.height };
      if (d.editable) {
        item.editable = true;
        const v = el.isContentEditable ? el.innerText : el.value;
        if (v && el.type !== "password") item.value = String(v).slice(0, 80);
        if (el.getAttribute("placeholder")) item.placeholder = el.getAttribute("placeholder").slice(0, 60);
      }
      if (tag === "input" && el.type === "range") {
        item.value = el.value;
        item.range = `min=${el.min || "0"} max=${el.max || "100"} step=${el.step || "1"}`;
      }
      if (tag === "select") {
        item.editable = true;
        item.value = el.options[el.selectedIndex] ? el.options[el.selectedIndex].text.trim() : "";
        item.options = [...el.options].map((o) => o.text.trim()).slice(0, 15).join(" | ");
      }
      if (d.listbox) {
        item.dropdown = true;
        const opts = optionTexts(el);
        if (opts.length) item.options = opts.slice(0, 25).join(" | ");
        // The chosen option may sit in the list it controls (aria-controls), not inside it.
        const owned = el.getAttribute("aria-controls") || el.getAttribute("aria-owns");
        const lists = [el, ...(owned ? owned.split(/\s+/).map((id) => document.getElementById(id)).filter(Boolean) : [])];
        const chosen = lists.map((l) => l.querySelector("[role=option][aria-selected=true]")).find(Boolean);
        let shown = el.tagName !== "INPUT" && el.getAttribute("role") === "combobox" ? squash(el.innerText) : "";
        if (/^(-+|(please )?(choose|select|pick)\b.*)$/i.test(shown)) shown = "";   // a placeholder, not a choice
        item.value = (chosen ? optionText(chosen) : "") || (shown && shown !== text ? shown.slice(0, 80) : "") || "(nothing chosen)";
      }
      if (d.q) item.q = d.q;
      if (el.required || el.getAttribute("aria-required") === "true" || /\*\s*$/.test(d.q || text)) item.required = true;
      if (el.getAttribute("aria-invalid") === "true") item.invalid = true;
      if (covered) item.covered = true;
      if (tag === "a" && el.href) item.href = el.href.slice(0, 120);
      if (el.disabled || el.getAttribute("aria-disabled") === "true") item.disabled = true;
      // Tick boxes, radios and switches always say which way they are, so nothing gets clicked twice "to make sure".
      const tickable = /^(checkbox|radio|switch|menuitemcheckbox|menuitemradio)$/.test(role) || el.hasAttribute("aria-checked");
      if (el.getAttribute("aria-checked") === "true" || el.checked) item.checked = true;
      else if (tickable) item.unchecked = true;
      if (el.getAttribute("aria-selected") === "true") item.selected = true;
      if (act && (act === el || (d.editable && act !== document.body && within(el, act)))) item.focused = true;
      out.push(item);
      picked.push(el);
      listed.add(el);
      sigs.push({ role, text, q: d.q, identity: nodeIdentity(el, d), x: r.left + r.width / 2, y: r.top + r.height / 2 });
      if (out.length >= 220) { truncated = true; break; }
    } catch (e) { skipped++; }   // one odd element never costs the whole page
  }
  window.__clinqyList = picked;
  window.__clinqySigs = sigs;
  keys(out, picked);
  const paneList = [];
  for (const [box, p] of panes) {
    try { paneList.push({ ...paneName(box), above: p.above, below: p.below }); } catch {}
    above += p.above; below += p.below;
  }
  let headings = [], messages = [], text = "", frames = [];
  try { headings = [...document.querySelectorAll("h1,h2,h3")].map((h) => squash(h.innerText)).filter(Boolean).slice(0, 12); } catch {}
  try { messages = pageMessages(); } catch {}
  try { text = visibleText(listed, 120); } catch {}
  try { frames = frameBoxes().frames; } catch {}
  return {
    documentID, snapshotID,
    url: location.href, title: window.__clinqyActivity?.pageTitle() || document.title, focused: document.hasFocus(), ready: document.readyState,
    viewport: { w: vw, h: vh },
    // Where the viewport sits on screen (for browsers that don't expose it to Accessibility).
    screen: { x: screenX, y: screenY, ow: outerWidth, oh: outerHeight, zoom: devicePixelRatio },
    scroll: (() => { const el = scroller(); return el ? { y: el.scrollTop, max: el.scrollHeight - el.clientHeight }
                                                     : { y: scrollY, max: document.documentElement.scrollHeight - vh }; })(),
    headings, elements: out, messages, text, frames, above, below, panes: paneList, truncated, skipped,
    ms: Math.round(performance.now() - started),
  };
}

// A reference names the exact observed node. Replacement or repurposing requires a new snapshot.
function target(index) {
  const el = (window.__clinqyList || [])[index];
  const sig = (window.__clinqySigs || [])[index];
  const current = el && el.isConnected && describe(el);
  if (current && sig && nodeIdentity(el, current) === sig.identity) return el;
  throw new Error("element w" + index + " is stale (the page changed); take a new look");
}

function coordinateGuard(x,y) {
  const geometry=observedGeometry;
  if(!geometry || geometry.width!==innerWidth || geometry.height!==innerHeight || geometry.x!==scrollX || geometry.y!==scrollY)
    throw Error("the viewport moved or resized; observe again before coordinate input");
  if(!Number.isFinite(x) || !Number.isFinite(y) || x<0 || y<0 || x>=innerWidth || y>=innerHeight)
    throw Error("the coordinate is outside the observed viewport");
  return {ok:true};
}
function validate(expected) {
  if (!expected || expected.documentID !== documentID || expected.snapshotID !== snapshotID || !snapshotID)
    throw new Error("stale browser observation; take a new look before acting");
  return { ok: true, documentID, snapshotID };
}
async function invoke(name, args, expected) {
  validate(expected);
  const fn = window.__clinqy[name];
  if (typeof fn !== "function" || ["invoke", "snapshot"].includes(name)) throw new Error("invalid guarded page operation");
  return await fn(...args);
}

// Where the element is right now (brought into view first), and whether a real mouse click at its centre would
// land on it — not on a popup's backdrop, which on LinkedIn/Indeed closes the popup instead.
// `px`/`py` is the point to click: the centre, or another uncovered spot on it. Waits for it to stop moving first.
async function locate(index, shouldReveal = true) {
  let el = target(index);
  if (shouldReveal) reveal(el);
  const still = await settle(el);
  // Re-rendered while it settled: aim at the new one.
  if (!el.isConnected) { el = target(index); if (shouldReveal) reveal(el); }
  const r = el.getBoundingClientRect();
  const p = hitPoint(el);
  return { x: r.left, y: r.top, w: r.width, h: r.height, hit: !!p, px: p ? p.x : r.left + r.width / 2, py: p ? p.y : r.top + r.height / 2, still };
}

// Whether a listed element can still be found (re-found if the page re-rendered it).
function alive(index) {
  try { target(index); return { ok: true }; } catch { return { ok: false }; }
}

// Focuses an element so a key press acts on it (the last fallback when clicks don't take).
function activityPoint(index) {
  const rect = target(index).getBoundingClientRect();
  return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
}

function focusFor(index) {
  const el = target(index);
  reveal(el);
  if (el.focus) el.focus({ preventScroll: true });
  const a = deepActive();
  return { focused: !!a && (within(el, a) || within(a, el)) };
}

function click(index) { return clickNode(target(index)); }
function clickNode(el) {
  reveal(el);
  const r = el.getBoundingClientRect();
  const opts = { bubbles: true, cancelable: true, composed: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, button: 0 };
  el.dispatchEvent(new PointerEvent("pointerdown", { ...opts, pointerType: "mouse" }));
  el.dispatchEvent(new MouseEvent("mousedown", opts));
  if (el.focus) el.focus({ preventScroll: true });
  el.dispatchEvent(new PointerEvent("pointerup", { ...opts, pointerType: "mouse" }));
  el.dispatchEvent(new MouseEvent("mouseup", opts));
  el.click();
  return { clicked: true };
}

// The real text input for an element: itself, or the input inside a wrapper (search boxes are often wrapped).
function replaceEditableText(el, text) {
  if (!el.isConnected || !el.isContentEditable) throw Error("the editable field changed; observe again");
  el.focus({preventScroll:true});
  if (!within(el, deepActive())) throw Error("the editor did not accept focus");
  // Scope selection to this editor; document-wide selectAll can select unrelated page content.
  const selection = window.getSelection(), range = document.createRange();
  range.selectNodeContents(el);
  selection.removeAllRanges(); selection.addRange(range);
  if (!document.execCommand("insertText", false, text)) throw Error("the editor rejected text insertion; observe before another attempt");
}
function editableOf(el) {
  const isEdit = (e) => e && (e.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(e.tagName));
  if (isEdit(el)) return el;
  const inner = el.querySelector && el.querySelector("input:not([type=hidden]), textarea, [contenteditable=''], [contenteditable=true]");
  if (inner) return inner;
  if (el.tagName === "LABEL" && el.control) return el.control;
  return el;
}

function focus(index) {
  const el = editableOf(target(index));
  reveal(el);
  el.focus({ preventScroll: true });
  if (el.select && !el.isContentEditable) el.select();
  const a = deepActive();
  return { focused: !!a && within(el, a) };
}

// Range controls expose numeric constraints; arbitrary ARIA/canvas sliders need their own interaction.
function setRange(index, desired) {
  const el = target(index);
  if (el.tagName !== "INPUT" || el.type !== "range") return { refused: true, why: "Only native HTML range inputs support numeric set_state" };
  if (el.disabled || el.matches(":disabled") || el.getAttribute("aria-disabled") === "true" || !hitPoint(el))
    return { refused: true, why: "The range input is disabled or covered" };
  if (typeof desired !== "number" || !Number.isFinite(desired)) return { refused: true, why: "Range state must be a finite number" };
  const number = (raw, fallback) => raw !== "" && Number.isFinite(Number(raw)) ? Number(raw) : fallback;
  const min = number(el.min, 0), max = number(el.max, 100);
  const rawStep = number(el.step, 1), step = rawStep > 0 ? rawStep : 1;
  const base = el.hasAttribute("min") ? number(el.min, 0) : number(el.getAttribute("value") || "", 0);
  const units = (desired - base) / step;
  if (desired < min || desired > max || max < min || (el.step !== "any" && Math.abs(units - Math.round(units)) > 1e-7))
    return { refused: true, why: "Value violates the range minimum, maximum or step" };
  if (el.valueAsNumber === desired) return { already: true, value: el.value };
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(el, String(desired));
  el.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
  el.dispatchEvent(new Event("change", { bubbles: true }));
  return { delivered: true, value: el.isConnected ? el.value : null, matches: el.isConnected && el.valueAsNumber === desired };
}

// Sets text the way frameworks (React etc.) notice, for when keystrokes do not land.
function fill(index, text) {
  const el = editableOf(target(index));
  if (el.disabled || el.readOnly || el.getAttribute("aria-disabled") === "true") throw Error("the field is disabled or read-only");
  if (el.type === "file" || el.type === "password") throw Error("this field requires its dedicated input path");
  if (editorKind(el) && !el.isContentEditable) throw Error("use keyboard input for this code editor");
  el.focus({ preventScroll: true });
  if (el.tagName === "SELECT") {
    // Dropdowns: pick the option whose text (or value) matches.
    const want = String(text).trim().toLowerCase();
    const opt = [...el.options].find((o) => o.text.trim().toLowerCase() === want || o.value.toLowerCase() === want)
      || bestMatch(text, [...el.options], (o) => o.text);
    if (!opt) throw new Error("no option like " + JSON.stringify(text) + "; options: " + [...el.options].map((o) => o.text.trim()).join(", "));
    el.value = opt.value;
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return { value: opt.text };
  }
  if (el.isContentEditable) {
    replaceEditableText(el, String(text));
  } else {
    const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, "value").set.call(el, text);
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  }
  return { value: (el.isContentEditable ? el.innerText : el.value).slice(0, 200) };
}

const OPTION_SEL = "[role=option], [role=menuitem], [role=menuitemradio], [role=menuitemcheckbox], [role=treeitem]";

// The list a dropdown opened: the one it names (aria-controls / aria-owns / its active option's list), else null.
function ownedList(el) {
  if (!el) return null;
  const ids = [el.getAttribute("aria-controls"), el.getAttribute("aria-owns")].filter(Boolean).join(" ").split(/\s+/).filter(Boolean);
  for (const id of ids) { const n = document.getElementById(id); if (n && n.getClientRects().length) return n; }
  const ad = el.getAttribute("aria-activedescendant");
  const a = ad && document.getElementById(ad);
  return a ? a.closest("[role=listbox], [role=menu], [role=tree]") : null;
}

// An option (of an open dropdown or menu) matching `text`, scrolled into view, with its viewport rect. Looks in the
// list the dropdown `index` opened first (options scrolled out of its box count), then in any open list on the page;
// matching is loose (case, accents, "USA" = "United States"). A long list that loads options as it scrolls is
// scrolled through to find it.
async function findOption(text, index) {
  let owner = null;
  if (index != null && index >= 0) owner = target(index);
  const list = ownedList(owner);
  const textOf = (o) => optionText(o) || squash(o.innerText);
  const shownIn = (o) => { const cs = getComputedStyle(o); return cs.display !== "none" && cs.visibility !== "hidden" && o.getClientRects().length; };
  const pool = () => {
    const inList = list ? [...list.querySelectorAll(OPTION_SEL)].filter(shownIn) : [];
    return inList.length ? inList : [...document.querySelectorAll(OPTION_SEL)].filter(visible);
  };
  let all = pool();
  let hit = bestMatch(text, all, textOf);
  // Not there yet: scroll the list (the owned one, else the box the visible options sit in) a page at a time.
  const box = !hit && (list && list.scrollHeight > list.clientHeight + 4 ? list : all.length ? scrollBoxOf(all[0]) : null);
  const seen = new Set(all.map(textOf));
  for (let k = 0; box && !hit && k < 25 && box.scrollTop + box.clientHeight < box.scrollHeight - 2; k++) {
    box.scrollBy({ top: Math.max(40, box.clientHeight - 30), behavior: "instant" });
    await new Promise((res) => setTimeout(res, 70));
    all = pool();
    all.forEach((o) => seen.add(textOf(o)));
    hit = bestMatch(text, all, textOf);
  }
  if (!hit) return { found: false, options: [...seen].filter(Boolean).slice(0, 40) };
  reveal(hit);
  await settle(hit, 250);
  const r = hit.getBoundingClientRect();
  const p = hitPoint(hit);
  if (!hit.isConnected || !p) return { found: false, options: [...seen].filter(Boolean).slice(0, 40) };
  const pointToken = documentID + ":option:" + (++nextOptionTarget);
  optionTargets.set(pointToken, { node: hit, identity: optionIdentity(hit) });
  // Tokens are short lived and bounded even if the caller repeatedly searches without a new snapshot.
  if (optionTargets.size > 64) optionTargets.delete(optionTargets.keys().next().value);
  return { found: true, pointToken, text: textOf(hit), x: r.left, y: r.top, w: r.width, h: r.height,
           px: p ? p.x : r.left + r.width / 2, py: p ? p.y : r.top + r.height / 2 };
}

function optionIdentity(el) {
  return JSON.stringify([el.tagName, el.id, el.getAttribute("role"), el.getAttribute("value"),
    el.getAttribute("data-value"), optionText(el) || squash(el.innerText)]);
}
function clickOption(pointToken) {
  const target = optionTargets.get(pointToken);
  optionTargets.delete(pointToken); // A delivered option click is never replayed through the same token.
  if (!target || !target.node.isConnected || optionIdentity(target.node) !== target.identity || !hitPoint(target.node))
    throw new Error("the option target is stale or covered; take a new look");
  return clickNode(target.node);
}

// The option a dropdown has highlighted now (moved with the arrow keys): its active descendant, or a focused option.
function activeOption(index, want) {
  let el = null; try { el = target(index); } catch {}
  const ad = el && el.getAttribute("aria-activedescendant");
  let o = ad ? document.getElementById(ad) : null;
  if (!o) { const a = deepActive(); if (a && a.matches && a.matches(OPTION_SEL)) o = a; }
  if (!o) { const list = ownedList(el); o = list && list.querySelector("[role=option][aria-selected=true], [role=option].focused, [role=option][data-focused=true]"); }
  const text = o ? optionText(o) || squash(o.innerText) : "";
  return { text, score: want && text ? matchScore(want, text) : 0 };
}

// Uploads require an explicit input/label/unique container, or the document's sole file input.
function fileInputCount() { return { count: document.querySelectorAll("input[type=file]").length }; }
function fileInputFor(index) {
  if (index >= 0) {
    const el = target(index);
    if (el.matches("input[type=file]")) return el;
    if (el.tagName === "LABEL" && el.control && el.control.type === "file") return el.control;
    const inner = [...el.querySelectorAll("input[type=file]")];
    if (inner.length === 1) return inner[0];
    if (inner.length > 1) throw new Error("ambiguous file upload fields; choose the exact input");
  }
  const all = [...document.querySelectorAll("input[type=file]")];
  if (!all.length) throw new Error("this page has no file upload field (it may use its own picker, e.g. Google Drive)");
  if (all.length !== 1) throw new Error("ambiguous file upload fields; choose the exact input");
  return all[0];
}

// Marks the element an upload goes through, for background.js's picker capture (which runs in the page's own
// world, where its scripts create and click their file inputs).
function markUpload(index) {
  document.querySelectorAll("[data-clinqy-up]").forEach((n) => n.removeAttribute("data-clinqy-up"));
  const el = target(index);
  reveal(el);
  el.setAttribute("data-clinqy-up", "1");
  return { ok: true };
}

// Puts a file into an upload field without the Mac file picker (bytes come from the app, base64).
function upload(index, name, type, b64) {
  const input = fileInputFor(index);
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  const dt = new DataTransfer();
  if (input.multiple) for (const f of input.files || []) dt.items.add(f);
  dt.items.add(new File([bytes], name, { type: type || "application/octet-stream", lastModified: Date.now() }));
  input.files = dt.files;
  input.dispatchEvent(new Event("input", { bubbles: true }));
  input.dispatchEvent(new Event("change", { bubbles: true }));
  const files = [...(input.files || [])];
  return { ok: files.some(f => f.name === name && f.size === bytes.length), files:files.map(f => f.name),
    attached:files.map(f=>({name:f.name,size:f.size,type:f.type})), verified:"file-input-readback", serverAccepted:false, accept:input.accept || "" };
}

// Every question on the page (not just the visible part) with its current answer, for a check before submitting.
function review() {
  const groups = new Map();
  const add = (q, answer, required, key) => {
    const k = key || q;
    const g = groups.get(k) || { q, answers: [], required: false, kind: "" };
    if (answer) g.answers.push(answer);
    g.required = g.required || required;
    groups.set(k, g);
  };
  const shown = (el) => { const cs = getComputedStyle(el); const r = el.getBoundingClientRect();
    return cs.display !== "none" && cs.visibility !== "hidden" && (r.width > 1 || r.height > 1 || el.type === "file"); };
  const req = (el, q) => el.required || el.getAttribute("aria-required") === "true" || /\*\s*$/.test(q || "");
  // Unlinked labels are common (<div><label>Resume *</label><button>Attach</button><input type=file hidden></div>):
  // fall back to the nearest label/legend/heading in the field's own wrapper.
  const nearbyLabel = (el) => {
    for (let p = el.parentElement, hops = 0; p && hops < 3; p = p.parentElement, hops++) {
      const l = p.querySelector("label, legend, [role=heading], h3, h4");
      if (l && !l.contains(el) && squash(l.innerText)) return l.innerText;
    }
    return "";
  };
  const labelOf = (el) => squash(el.getAttribute("aria-label") || labelledBy(el) || (el.labels && el.labels[0] && el.labels[0].innerText)
    || el.getAttribute("placeholder") || nearbyLabel(el) || el.name || "");
  document.querySelectorAll("input, textarea, select, [role=listbox], [role=radio], [role=checkbox], [contenteditable=true]").forEach((el) => {
    const tag = el.tagName.toLowerCase(), type = (el.type || "").toLowerCase(), role = el.getAttribute("role") || "";
    if (type !== "file" && !shown(el)) return;   // upload fields are usually hidden behind a button
    if (/^(hidden|submit|button|reset|image|search)$/.test(type)) return;
    if (role === "option" || el.closest("[role=listbox]") && role !== "listbox") return;
    const q = questionOf(el) || labelOf(el);
    if (!q) return;
    if (type === "radio" || type === "checkbox" || role === "radio" || role === "checkbox") {
      const on = el.checked || el.getAttribute("aria-checked") === "true";
      const opt = squash(el.getAttribute("aria-label") || el.getAttribute("data-value") || (el.labels && el.labels[0] && el.labels[0].innerText)
        || (role ? el.innerText : "") || el.value);
      add(q, on ? opt : "", req(el, q) || !!(el.closest("[aria-required=true]")), q);
    } else if (type === "file") {
      add(q, [...(el.files || [])].map((f) => "📎 " + f.name).join(", "), req(el, q));
    } else if (tag === "select") {
      add(q, el.selectedIndex > 0 || (el.options[el.selectedIndex] && el.options[el.selectedIndex].value) ? squash(el.options[el.selectedIndex].text) : "", req(el, q));
    } else if (role === "listbox") {
      const sel = el.querySelector("[role=option][aria-selected=true]");
      add(q, sel ? optionText(sel) : "", req(el, q));
    } else {
      const v = el.isContentEditable ? el.innerText : el.value;
      add(q, type === "password" && v ? "••••" : squash(v).slice(0, 160), req(el, q));
    }
  });
  const items = [...groups.values()].map((g) => ({ q: g.q.replace(/\s*\*\s*$/, ""), answer: g.answers.join(", "), required: g.required }));
  return { url: location.href, title: document.title, items, messages: pageMessages(),
           missing: items.filter((i) => i.required && !i.answer).map((i) => i.q) };
}

// What a field or dropdown shows as chosen now.
function chosen(i) {
  const el = target(i);
  const f = editableOf(el);
  if (f.tagName === "SELECT") return { value: f.options[f.selectedIndex] ? f.options[f.selectedIndex].text.trim() : "" };
  if (/^(INPUT|TEXTAREA)$/.test(f.tagName)) return { value: String(f.value || "") };
  const sel = el.querySelector("[role=option][aria-selected=true]");
  return { value: sel ? optionText(sel) : squash(el.innerText).slice(0, 100) };
}

// Every data table on the page as rows of cell text: <table>s and ARIA grids (Google Sheets-style apps, React
// data grids). Layout tables (one row or one column) are skipped. Header row first when there is one.
function tables() {
  const out = [];
  const cells = (row) => [...row.querySelectorAll(":scope > th, :scope > td, :scope > [role=cell], :scope > [role=gridcell], :scope > [role=columnheader], :scope > [role=rowheader]")]
    .map((c) => squash(c.innerText));
  const nameOf = (t) => squash((t.querySelector("caption") || {}).innerText || t.getAttribute("aria-label") || labelledBy(t)
    || ((t.previousElementSibling && /^H[1-6]$/.test(t.previousElementSibling.tagName)) ? t.previousElementSibling.innerText : "")).slice(0, 80);
  for (const t of document.querySelectorAll("table, [role=table], [role=grid], [role=treegrid]")) {
    if (t.parentElement && t.parentElement.closest("table, [role=table], [role=grid]")) continue;   // nested: the outer one has it
    const rows = [...t.querySelectorAll("tr, [role=row]")].filter((r) => r.closest("table, [role=table], [role=grid], [role=treegrid]") === t)
      .map(cells).filter((r) => r.some((c) => c));
    if (rows.length < 2 || Math.max(...rows.map((r) => r.length)) < 2) continue;
    out.push({ name: nameOf(t), rows: rows.slice(0, 500), more: Math.max(0, rows.length - 500) });
    if (out.length >= 10) break;
  }
  return { url: location.href, title: document.title, tables: out };
}

function readText() {
  const main = document.querySelector("main, article, [role=main]") || document.body;
  // Portalled help/dialog content can sit outside <main>. Read the visible overlay too,
  // so verification sees the same confirmation the snapshot lists instead of deadlocking.
  const overlays = [...document.querySelectorAll('[role="dialog"], [role="alertdialog"], dialog[open], [aria-modal="true"]')]
    .filter(el => !main.contains(el) && visible(el)).map(el => el.innerText || "");
  // Adjacent inline controls and status spans concatenate in innerText ("ReviewLocal review
  // confirmed"). Preserve each visible semantic message as its own text boundary instead of
  // weakening whole-word verification, which must still distinguish "paid" from "unpaid".
  const messages = [];
  let messageChars = 0;
  for (const el of [...document.querySelectorAll('[role="status"], [role="alert"], [aria-live="polite"], [aria-live="assertive"]')].slice(0, 80)) {
    if (!visible(el) || el.closest('[hidden], [aria-hidden="true"], [data-clinqy-overlay]')) continue;
    let hidden = false;
    for (let parent = el.parentElement; parent; parent = parent.parentElement) {
      const style = getComputedStyle(parent);
      if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) <= 0.05) { hidden = true; break; }
    }
    if (hidden) continue;
    const message = squash(el.innerText);
    if (!message || messages.includes(message) || message.length > 2000 || messageChars + message.length > 3000) continue;
    messages.push(message); messageChars += message.length;
  }
  const text = [...new Set([...messages, ...overlays, main.innerText || ""])].join("\n\n").replace(/\n{3,}/g, "\n\n").slice(0, 8000);
  return { url: location.href, title: document.title, text };
}


  function isActive(i) {
    let el = null; try { el = target(i); } catch {}
    if (!el) return { active: false };
    // The caret may be deep inside it: a shadow root (web components), or a code editor's hidden textarea.
    const inner = editableOf(el), a = deepActive();
    return { active: !!a && a !== document.body && (within(inner, a) || within(el, a)) && document.hasFocus() };
  }
  function value(i) {
    let el = null; try { el = target(i); } catch {}
    if (!el) return { value: null };
    const f = editableOf(el);
    return { value: f.tagName === "SELECT" ? (f.options[f.selectedIndex] ? f.options[f.selectedIndex].text.trim() : "")
                                           : String(f.isContentEditable ? f.innerText : f.value || "").slice(0, 400) };
  }
  function values(indices) {
    const result = {};
    for (const index of indices.slice(0, 200)) result[String(index)] = value(index).value;
    return { values: result };
  }
  function activeValue() {
    const el = deepActive();
    // Editors like Google Docs keep the caret in an iframe: keys typed now land there, but its text can't be read.
    // background.js then asks the frames themselves (focusedFrame).
    const where = { hasFocus: document.hasFocus(), url: location.href };
    if (el && (el.tagName === "IFRAME" || el.tagName === "FRAME")) return { ...where, editable: true, code: false, value: null, frame: true };
    // Code editors (Monaco on LeetCode, CodeMirror, Ace) re-indent what's typed; their caret sits in a hidden
    // textarea or a contenteditable, and their text is in the rendered lines.
    const ed = el && editorKind(el);
    if (ed) return { ...where, editable: true, code: true, editorKind: ed.kind, value: editorText(ed).slice(0, 400) };
    const role = el && el.getAttribute ? el.getAttribute("role") || "" : "";
    const editable = el && (el.isContentEditable || /^(INPUT|TEXTAREA)$/.test(el.tagName) || /^(textbox|searchbox|combobox)$/.test(role)
      || (document.designMode === "on" && el === document.body));   // old rich-text frames edit the whole document
    const v = !editable ? null : el.isContentEditable || el === document.body ? el.innerText : el.value;
    return { ...where, editable: !!editable, code: false, value: editable ? String(v || "").slice(0, 400) : null };
  }
  function fillActive(text) {
    const el = deepActive();
    if (!el) return { value: null };
    // A code editor's hidden textarea isn't its text: setting it would corrupt the editor. Leave it be.
    const ed = editorKind(el);
    if (ed && !el.isContentEditable) return { value: editorText(ed).slice(0, 400), skipped: true };
    if (el.isContentEditable) { replaceEditableText(el, String(text)); }
    else if (/^(INPUT|TEXTAREA)$/.test(el.tagName)) {
      if (el.disabled || el.readOnly || /^(file|password)$/.test(el.type)) throw Error("this field cannot be filled through the active-value path");
      const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, "value").set.call(el, text);
      el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true }));
    }
    return { value: String(el.isContentEditable ? el.innerText : el.value || "").slice(0, 400) };
  }
  function prepare(i) {
    let el = null; try { el = target(i); } catch {}
    if (!el) return { ok: false };
    const field = editableOf(el);
    // Preparation must not rewrite autocomplete on unrelated user fields.
    return { ok: !field.disabled && !field.readOnly };
  }
  // The target's own state plus the URL: the only fields the app compares (no whole-page text hash or focus).
  function targetState(el) {
    const a = (n) => el && el.getAttribute(n);
    return JSON.stringify([el && el.checked, a("aria-checked"), a("aria-expanded"), a("aria-selected"), a("aria-pressed"),
      el && el.value, location.href]);
  }
  function state(i) {
    let el = null; try { el = target(i); } catch {}
    return { sig: targetState(el) };
  }
  // Effect receipt: a MutationObserver armed before an input records what the page did in response, so an ordinary
  // click's effect is reported with its result instead of costing a separate verification turn.
  const receipts = new Map();
  const dialogSelector = "dialog[open], [role=dialog], [role=alertdialog], [aria-modal=true]";
  function openDialogs() {
    try { return [...document.querySelectorAll(dialogSelector)].filter((d) => d.getAttribute("aria-hidden") !== "true" && visible(d)).length; }
    catch { return 0; }
  }
  function nodeText(node) {
    if (!node) return "";
    if (node.nodeType === 3) return node.data || "";
    if (node.nodeType !== 1 || /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|svg)$/i.test(node.tagName || "")) return "";
    return node.innerText || node.textContent || "";
  }
  // Text only counts as the input's effect where the input could have caused it: inside the target's own container
  // (its nearest form/section/list item/landmark/dialog, at most 3 levels up), inside a dialog/alert/menu that opened
  // after arming, or in a node that is itself such a popup. Clocks, tickers, chats and live regions elsewhere don't.
  const containerSelector = "form, dialog, section, article, li, fieldset, main, nav, aside, header, footer, tr, [role=dialog], [role=alertdialog], " +
    "[role=form], [role=region], [role=listitem], [role=row], [role=main], [role=navigation], [role=complementary], [role=banner], " +
    "[role=contentinfo], [role=search], [role=menu], [role=listbox], [role=tabpanel], [role=group], [role=toolbar], [role=article]";
  const openedSelector = "dialog, [role=dialog], [role=alertdialog], [role=alert], [role=menu], [role=listbox], [aria-modal=true], [popover]";
  const timeChurn = /^(?:[\d\s:.,/%+\-–—]*|(?:about |over |almost |updated |edited )?(?:\d+\s*|(?:a|an|one)\s+)(?:s|secs?|seconds?|m|mins?|minutes?|h|hrs?|hours?|d|days?|w|wks?|weeks?|mo|months?|y|yrs?|years?)( ago)?|just now|now|(?:updated |edited )?(?:just now|moments? ago|yesterday|today))$/i;
  function isChurn(text) { return timeChurn.test(squash(text)); }
  function matchesSel(n, sel) { try { return !!(n && n.nodeType === 1 && n.matches && n.matches(sel)); } catch { return false; } }
  function closestUp(n, sel) {
    for (let x = n, k = 0; x && k < 200; x = x.parentNode || x.host, k++) if (matchesSel(x, sel)) return x;
    return null;
  }
  function receiptScope(el) {
    if (!el) return null;
    let scope = el;
    for (let n = el.parentNode || el.host, level = 1; n && n.nodeType === 1 && level <= 3; n = n.parentNode || n.host, level++) {
      if (n === document.body || n === document.documentElement) break;
      scope = n;
      if (matchesSel(n, containerSelector)) break;
    }
    return scope;
  }
  function openedNow(rec, node) {
    if (matchesSel(node, openedSelector)) return !rec.preOpened.has(node);
    try { if (node && node.nodeType === 1 && node.querySelector && node.querySelector(openedSelector)) return true; } catch {}
    return false;
  }
  // Is a change at `place` (the mutation's target) attributable to the input?
  function attributable(rec, place) {
    if (rec.scope && within(rec.scope, place)) return true;
    const popup = closestUp(place, openedSelector);
    return !!(popup && !rec.preOpened.has(popup));
  }
  // Armed right before delivery (after locate and the pointer's approach), so a hover tooltip is not the click's effect.
  function receiptArm(token, index) {
    if (typeof token !== "string" || !token || token.length > 80) throw new Error("receipt needs a token");
    receiptDrop(token);
    const el = Number.isInteger(index) ? target(index) : null;
    let preOpened = new Set();
    try { preOpened = new Set(document.querySelectorAll(openedSelector)); } catch {}
    const rec = { el, scope: receiptScope(el), preOpened, addedEls: [], sig: el ? targetState(el) : null, url: location.href, active: deepActive(),
      dialogs: openDialogs(), added: [], removed: [], size: 0, count: 0, structural: false, armedAt: performance.now(), last: performance.now() };
    const keep = (list, text) => {
      const t = squash(text);
      if (!t || isChurn(t) || rec.size > 4000 || list.includes(t)) return;
      list.push(t.slice(0, 400)); rec.size += Math.min(400, t.length);
    };
    rec.observer = new MutationObserver((records) => {
      for (const m of records) {
        rec.count++;
        if (m.type === "childList") {
          if ([...(m.addedNodes || []), ...(m.removedNodes || [])].some((n) => n.nodeType === 1)) rec.structural = true;
          const here = attributable(rec, m.target);
          for (const n of m.addedNodes || []) {
            if (n.nodeType === 1 && rec.addedEls.length < 200) rec.addedEls.push(n);
            if (here || openedNow(rec, n)) keep(rec.added, nodeText(n));
          }
          if (here) for (const n of m.removedNodes || []) keep(rec.removed, nodeText(n));
        } else if (m.type === "characterData") {
          const now = squash(m.target && m.target.data), was = squash(m.oldValue);
          if (now !== was && !(isChurn(now) && isChurn(was)) && attributable(rec, m.target)) { keep(rec.added, now); keep(rec.removed, was); }
        }
      }
      rec.last = performance.now();
    });
    rec.observer.observe(document.documentElement, { childList: true, subtree: true, characterData: true, characterDataOldValue: true,
      attributes: true, attributeFilter: ["open", "hidden", "aria-hidden", "aria-expanded", "aria-checked", "aria-selected", "aria-pressed", "checked", "value", "disabled"] });
    rec.expiry = setTimeout(() => receiptDrop(token), 15000);
    receipts.set(token, rec);
    return { armed: true, url: rec.url };
  }
  function receiptDrop(token) {
    const rec = receipts.get(token);
    if (!rec) return;
    try { rec.observer.disconnect(); } catch {}
    clearTimeout(rec.expiry);
    receipts.delete(token);
  }
  // Waits until the DOM has been quiet for `quietMs` (or `capMs` passed), then reports what changed.
  function receiptCollect(token, quietMs = 120, capMs = 800) {
    const rec = receipts.get(token);
    if (!rec) throw new Error("no armed receipt " + token);
    const quiet = Math.max(30, Math.min(1000, Number(quietMs) || 120)), cap = Math.max(quiet, Math.min(3000, Number(capMs) || 800));
    const started = performance.now();
    return new Promise((resolve) => {
      const tick = () => {
        const now = performance.now();
        if (now - Math.max(rec.last, started) < quiet && now - started < cap) { setTimeout(tick, 30); return; }
        try { rec.observer.takeRecords && rec.observer.takeRecords(); } catch {}
        const el = rec.el;
        const connected = !!(el && el.isConnected);
        const result = {
          urlChanged: location.href !== rec.url,
          targetStateChanged: !!(el && connected && targetState(el) !== rec.sig),
          targetRemoved: !!(el && !connected),
          dialogOpened: openDialogs() > rec.dialogs,
          focusChanged: deepActive() !== rec.active,
          focusIntoNew: (() => { const a = deepActive(); return !!(a && a !== rec.active && rec.addedEls.some((n) => within(n, a))); })(),
          addedText: rec.added.join(" | ").slice(0, 600),
          removedText: rec.removed.join(" | ").slice(0, 600),
          mutationCount: rec.count,
          structural: rec.structural,
          waitedMs: Math.round(now - started),
        };
        receiptDrop(token);
        resolve(result);
      };
      tick();
    });
  }
  // Apps like the AWS console scroll an inner panel, not the window: scroll whichever actually moves.
  function scroller() {
    // An open modal (LinkedIn's Easy Apply) scrolls its own body; scrolling the page behind it does nothing useful.
    try {
      const dialogs = [...document.querySelectorAll("[role=dialog], [role=alertdialog], dialog[open], [aria-modal=true]")].filter(visible);
      for (const d of dialogs.reverse()) {
        let best = null, area = 0;
        for (const el of [d, ...d.querySelectorAll("*")]) {
          if (el.scrollHeight <= el.clientHeight + 4 || !/^(auto|scroll|overlay)$/.test(getComputedStyle(el).overflowY)) continue;
          const r = el.getBoundingClientRect(), a = r.width * r.height;
          if (a > area) { best = el; area = a; }
        }
        if (best) return best;
      }
    } catch {}
    const root = document.scrollingElement || document.documentElement;
    if (root.scrollHeight > innerHeight + 4) return null;
    let best = null, area = 0;
    for (const el of document.querySelectorAll("*")) {
      if (el.scrollHeight <= el.clientHeight + 4) continue;
      const o = getComputedStyle(el).overflowY;
      if (o !== "auto" && o !== "scroll" && o !== "overlay") continue;
      const r = el.getBoundingClientRect(), a = r.width * r.height;
      if (a > area) { best = el; area = a; }
    }
    return best;
  }
  function scroll(dy, index = null, dx = 0) {
    if (!Number.isFinite(dy) || !Number.isFinite(dx)) throw Error("scroll distances must be finite");
    let el = Number.isInteger(index) ? target(index) : scroller();
    if (el && Number.isInteger(index)) {
      while (el && el !== document.documentElement) {
        const style=getComputedStyle(el);
        if ((dy && el.scrollHeight > el.clientHeight+2 && /auto|scroll|overlay/.test(style.overflowY)) ||
            (dx && el.scrollWidth > el.clientWidth+2 && /auto|scroll|overlay/.test(style.overflowX))) break;
        el=el.parentElement || el.getRootNode()?.host;
      }
    }
    const box=el || document.scrollingElement || document.documentElement;
    const before=box.scrollTop, beforeX=box.scrollLeft;
    box.scrollBy({top:dy,left:dx,behavior:"instant"});
    return {y:box.scrollTop,x:box.scrollLeft,before,beforeX,moved:box.scrollTop!==before || box.scrollLeft!==beforeX,
      container:box===document.scrollingElement?"page":"element",atStart:box.scrollTop<=0,atEnd:box.scrollTop+box.clientHeight>=box.scrollHeight-1};
  }
  // The selected text plus where its links go: "Apply here" alone loses the application URL the user meant.
  function selection() {
    const sel = window.getSelection();
    const text = String(sel || "").slice(0, 8000);
    if (!text.trim() || !sel.rangeCount) return text;
    const links = new Map();
    for (let i = 0; i < sel.rangeCount; i++) {
      const range = sel.getRangeAt(i);
      const root = range.commonAncestorContainer;
      const scope = root.nodeType === 1 ? root : root.parentElement;
      const around = scope && scope.closest("a[href]");
      const anchors = [...(scope ? scope.querySelectorAll("a[href]") : []), ...(around ? [around] : [])];
      for (const a of anchors) {
        if (links.size >= 10 || !range.intersectsNode(a)) continue;
        let href = a.href;
        if (!/^https?:/.test(href)) continue;
        try {   // LinkedIn and others wrap outside links in a redirect page
          const u = new URL(href), inner = u.searchParams.get("url") || u.searchParams.get("q");
          if (inner && /^https?:/.test(inner) && /\/(safety\/go|redirect|url)\b/.test(u.pathname)) href = inner;
        } catch (e) {}
        if (!links.has(href)) links.set(href, (a.innerText || "").trim().replace(/\s+/g, " ").slice(0, 60));
      }
    }
    if (!links.size) return text;
    return text + "\n\nLinks in the selection:\n" + [...links].map(([href, label]) => `- ${label ? label + " → " : ""}${href}`).join("\n");
  }

  // Document order within article content, then other visible content. Skip chrome, trackers and tiny icons.
  function images() {
    const root = document.querySelector("#mw-content-text, article, main, [role=main]") || document.body;
    const found = [], seen = new Set();
    for (const el of (root ? root.querySelectorAll("img") : [])) {
      if (el.closest("nav, header, footer, [role=navigation], .advertisement, .ad-slot, [aria-hidden=true]")) continue;
      const r = el.getBoundingClientRect(), style = getComputedStyle(el);
      if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) <= 0.05) continue;
      const width = Math.max(el.naturalWidth || 0, r.width), height = Math.max(el.naturalHeight || 0, r.height);
      if (width < 64 || height < 48 || r.width < 48 || r.height < 32) continue;
      const lazy = el.getAttribute("data-src") || el.getAttribute("data-original");
      const raw = el.naturalWidth > 16 ? (el.currentSrc || el.src) : (lazy || el.currentSrc || el.src);
      let url; try { url = new URL(raw, document.baseURI).href; } catch { continue; }
      if (!/^https?:/.test(url) || seen.has(url)) continue;
      seen.add(url);
      found.push({url, alt: squash(el.alt || el.title || "").slice(0, 200), width, height,
        visible: visible(el), loaded: el.naturalWidth > 16, page: location.href,
        rect: el.naturalWidth > 16 ? {x:r.left,y:r.top,width:r.width,height:r.height} : null});
      if (found.length === 40) break;
    }
    return {images: found, url: location.href, title: document.title};
  }

  // Resolves as soon as `want` shows in the page's text or title — or, with gone, has stayed gone for half a second —
  // woken by the page's own changes (a MutationObserver) rather than polled; { met: false } at the timeout.
  function waitCondition(condition, ms = 10000) {
    if (!condition || !["text", "url", "ready", "element"].includes(condition.kind)) throw Error("unsupported wait condition");
    if (["text","url"].includes(condition.kind) && !String(condition.text || "").trim()) throw Error("wait text must not be empty");
    const expectedDocument=documentID;
    const matches = () => {
      if (condition.kind === "ready") return document.readyState === "interactive" || document.readyState === "complete";
      if (condition.kind === "url") return location.href.includes(String(condition.text));
      if (condition.kind === "element") {
        let el;
        try { el=target(condition.index); } catch { return condition.state === "gone"; }
        if (condition.state === "gone") return !visible(el);
        if (condition.state === "enabled") return visible(el) && !el.disabled && el.getAttribute("aria-disabled") !== "true";
        return visible(el);
      }
      const content=norm(pageTitle()+" "+(document.body?.innerText || ""));
      const present=content.includes(norm(condition.text));
      return condition.gone ? !present : present;
    };
    return new Promise(resolve => {
      let done=false,observer,timer,poll,mutationTimer,stableSince=null;
      const started=performance.now();
      const finish=(met,cancelled=false)=>{
        if(done)return; done=true; observer?.disconnect(); clearTimeout(timer); clearTimeout(mutationTimer); clearInterval(poll); waits.delete(cancel);
        resolve({met,cancelled,documentID:expectedDocument,elapsedMs:Math.round(performance.now()-started)});
      };
      const cancel=()=>finish(false,true);
      const check=()=>{
        if(done)return;
        let met=false; try {met=matches();} catch {}
        if(!met){stableSince=null;return;}
        if(stableSince===null)stableSince=performance.now();
        const stableMs=condition.gone || condition.state==="gone" ? 400 : 80;
        if(performance.now()-stableSince>=stableMs)finish(true);
      };
      waits.add(cancel);
      observer=new MutationObserver(()=>{if(!mutationTimer)mutationTimer=setTimeout(()=>{mutationTimer=null;check();},80);});
      observer.observe(document.documentElement,{childList:true,subtree:true,characterData:true,attributes:true,
        attributeFilter:["hidden","style","class","aria-hidden","disabled","aria-disabled","open"]});
      poll=setInterval(check,100); // URL/ready/value changes need not mutate the DOM.
      timer=setTimeout(()=>finish(false),Math.max(100,Math.min(30000,Number(ms)||10000)));
      check();
    });
  }
  function pageTitle() { return window.__clinqyActivity?.pageTitle?.() || document.title; }
  // In a tab the user handed over (adopted), their own click, key, scroll or touch means they want it back. Only
  // trusted events are reported; the extension discards those arriving while it is sending its own CDP input.
  const USER_EVENTS = ["pointerdown", "mousedown", "keydown", "wheel", "touchstart"];
  let watchingUser = false, lastUserReport = 0;
  function onUserEvent(event) {
    if (!event.isTrusted) return;
    const now = Date.now();
    if (now - lastUserReport < 100) return;
    lastUserReport = now;
    try { chrome.runtime.sendMessage({ clinqy: "userInput", kind: event.type })?.catch?.(() => {}); } catch {}
  }
  function watchUser(on) {
    if (on && !watchingUser) for (const type of USER_EVENTS) addEventListener(type, onUserEvent, { capture: true, passive: true });
    if (!on && watchingUser) for (const type of USER_EVENTS) removeEventListener(type, onUserEvent, { capture: true });
    watchingUser = !!on;
    return { watching: watchingUser };
  }
  function waitText(want,gone,ms) { return waitCondition({kind:"text",text:want,gone},ms); }

  window.__clinqy = { version: HELPER_VERSION, dispose: () => { candidateObserver.disconnect(); cancelWaits(); watchUser(false); }, protocolVersion: 7, documentID, validate, invoke, check: () => ({ ok: true }),
    focusStatus: () => ({ documentID, hasFocus: document.hasFocus(), frame: /^(IFRAME|FRAME)$/.test((deepActive() || {}).tagName || "") }),
    frameBoxes, snapshot, coordinateGuard, locate, alive, activityPoint, focusFor, activeOption, markUpload, click, clickOption, focus, fill, setRange, findOption, chosen, upload, fileInputCount, review, readText, tables, images, isActive, value, values, activeValue, fillActive, prepare, state, receiptArm, receiptCollect, receiptDrop, scroll, selection, waitText, waitCondition, cancelWaits, watchUser };
})();
