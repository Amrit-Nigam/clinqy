// Runs inside web pages (in the extension's isolated world). Installed by background.js before each command;
// all page-side logic lives here so helpers are available to every command.
(() => {
  if (window.__clinqy) return;

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

// Would a real click at the element's centre land on it (not on a sticky footer, backdrop or popup over it)?
function hitAt(el) {
  const r = el.getBoundingClientRect();
  const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
  if (r.width < 1 || r.height < 1 || cx < 0 || cy < 0 || cx >= innerWidth || cy >= innerHeight) return false;
  let top = document.elementFromPoint(cx, cy);
  for (let k = 0; top && k < 10; k++) { const s = shadowOf(top); const inner = s && s.elementFromPoint(cx, cy); if (!inner || inner === top) break; top = inner; }
  return !!top && (within(el, top) || within(top, el));
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

// Every candidate element, including inside open shadow roots.
function candidates() {
  const nodes = [];
  const walk = (root) => {
    root.querySelectorAll(SEL).forEach((el) => nodes.push(el));
    const tw = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
    for (let n = tw.nextNode(); n; n = tw.nextNode()) { const s = shadowOf(n); if (s) walk(s); }
  };
  walk(document);
  return nodes;
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
  // Closed dropdown options aren't targets: the dropdown itself lists them.
  if (role === "option") { const lb = el.closest("[role=listbox]"); if (lb && lb.getAttribute("aria-expanded") !== "true" && lb !== el) return null; }
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

// A key per listed element that stays the same while the page shifts around it (role, name, question; for
// look-alikes also the link target or nearest label, then an ordinal), so background.js can keep its w-id.
function keys(out, picked) {
  const base = out.map((it) => [it.role, it.text, it.q || ""].join("|"));
  const count = new Map();
  base.forEach((b) => count.set(b, (count.get(b) || 0) + 1));
  const ctx = (el, it) => {
    if (it.href) { try { return new URL(it.href).pathname; } catch {} }
    for (let p = el.parentElement, hops = 0; p && hops < 5; p = p.parentElement, hops++) {
      const l = p.querySelector("label, legend, [role=heading], h1, h2, h3, h4, h5, h6");
      const t = l && !within(l, el) && squash(l.innerText).slice(0, 40);
      if (t && t !== it.text) return t;
    }
    return "";
  };
  const seen = new Map();
  out.forEach((it, k) => {
    let key = base[k];
    if (count.get(key) > 1) key += "|" + ctx(picked[k], it);
    const n = (seen.get(key) || 0) + 1;
    seen.set(key, n);
    it.key = n > 1 ? key + "#" + n : key;
  });
}

function snapshot() {
  const started = performance.now();
  const vw = innerWidth, vh = innerHeight;
  const seen = new Set(), listed = new Set();
  const out = [], picked = [], sigs = [];
  const act = deepActive();
  let above = 0, below = 0, skipped = 0, truncated = false;
  const boxOf = new Map(), boxRects = new Map(), panes = new Map();
  const countable = (el) => el.getClientRects().length && (/^(INPUT|TEXTAREA|SELECT|BUTTON)$/.test(el.tagName)
    || /^(listbox|radio|checkbox|textbox|combobox|switch|button)$/.test(el.getAttribute("role") || ""));
  for (const el of candidates()) {
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
      const covered = top && !(within(el, top) || within(top, el));
      const { tag, role, text } = d;
      const item = { i: out.length, role, text, x: r.left, y: r.top, w: r.width, h: r.height };
      if (d.editable) {
        item.editable = true;
        const v = el.isContentEditable ? el.innerText : el.value;
        if (v && el.type !== "password") item.value = String(v).slice(0, 80);
        if (el.getAttribute("placeholder")) item.placeholder = el.getAttribute("placeholder").slice(0, 60);
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
        const chosen = el.querySelector("[role=option][aria-selected=true]");
        item.value = (chosen ? optionText(chosen) : "") || "(nothing chosen)";
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
      sigs.push({ role, text, q: d.q, x: r.left + r.width / 2, y: r.top + r.height / 2 });
      if (out.length >= 220) { truncated = true; break; }
    } catch (e) { skipped++; }   // one odd element never costs the whole page
  }
  window.__clinqyList = picked;
  window.__clinqySigs = sigs;
  try { keys(out, picked); } catch {}
  const paneList = [];
  for (const [box, p] of panes) {
    try { paneList.push({ ...paneName(box), above: p.above, below: p.below }); } catch {}
    above += p.above; below += p.below;
  }
  let headings = [], messages = [], text = "", frames = [];
  try { headings = [...document.querySelectorAll("h1,h2,h3")].map((h) => squash(h.innerText)).filter(Boolean).slice(0, 12); } catch {}
  try { messages = pageMessages(); } catch {}
  try { text = visibleText(listed, 120); } catch {}
  // Embedded pages (Greenhouse/Lever job forms, payment boxes, editors) that are big enough to matter.
  try {
    frames = [...document.querySelectorAll("iframe, frame")].map((f) => {
      const r = f.getBoundingClientRect(), cs = getComputedStyle(f);
      return { src: f.src || "", x: r.left + f.clientLeft + (parseFloat(cs.paddingLeft) || 0), y: r.top + f.clientTop + (parseFloat(cs.paddingTop) || 0),
               w: f.clientWidth, h: f.clientHeight, hidden: cs.visibility === "hidden" || cs.display === "none" };
    }).filter((f) => !f.hidden && f.w >= 80 && f.h >= 40 && f.x < vw && f.y < vh && f.x + f.w > 0 && f.y + f.h > 0);
  } catch {}
  return {
    url: location.href, title: document.title, focused: document.hasFocus(), ready: document.readyState,
    viewport: { w: vw, h: vh },
    // Where the viewport sits on screen (for browsers that don't expose it to Accessibility).
    screen: { x: screenX, y: screenY, ow: outerWidth, oh: outerHeight, zoom: devicePixelRatio },
    scroll: (() => { const el = scroller(); return el ? { y: el.scrollTop, max: el.scrollHeight - el.clientHeight }
                                                     : { y: scrollY, max: document.documentElement.scrollHeight - vh }; })(),
    headings, elements: out, messages, text, frames, above, below, panes: paneList, truncated, skipped,
    ms: Math.round(performance.now() - started),
  };
}

// The listed element, or — if the page re-rendered it since (React, Google Forms) — the same thing found again
// by role, name and question, nearest to where it was.
function target(index) {
  const el = (window.__clinqyList || [])[index];
  if (el && el.isConnected) return el;
  const sig = (window.__clinqySigs || [])[index];
  if (sig) {
    let best = null, dist = Infinity;
    for (const c of candidates()) {
      try {
        const d = describe(c);
        if (!d || d.role !== sig.role || d.text !== sig.text || (d.q || "") !== (sig.q || "")) continue;
        const r = c.getBoundingClientRect();
        if (r.width < 1 || r.height < 1) continue;
        const k = Math.hypot(r.left + r.width / 2 - sig.x, r.top + r.height / 2 - sig.y);
        if (k < dist) { best = c; dist = k; }
      } catch {}
    }
    if (best) { window.__clinqyList[index] = best; return best; }
  }
  throw new Error("element w" + index + " is gone (the page changed); take a new look");
}

// Where the element is right now (brought into view first), and whether a real mouse click at its centre would
// land on it — not on a popup's backdrop, which on LinkedIn/Indeed closes the popup instead.
function locate(index) {
  const el = target(index);
  reveal(el);
  const r = el.getBoundingClientRect();
  return { x: r.left, y: r.top, w: r.width, h: r.height, hit: hitAt(el) };
}

function click(index) {
  const el = target(index);
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

// Sets text the way frameworks (React etc.) notice, for when keystrokes don't land.
function fill(index, text) {
  const el = editableOf(target(index));
  el.focus({ preventScroll: true });
  if (el.tagName === "SELECT") {
    // Dropdowns: pick the option whose text (or value) matches.
    const want = String(text).trim().toLowerCase();
    const opt = [...el.options].find((o) => o.text.trim().toLowerCase() === want || o.value.toLowerCase() === want)
      || [...el.options].find((o) => o.text.trim().toLowerCase().includes(want));
    if (!opt) throw new Error("no option like " + JSON.stringify(text) + "; options: " + [...el.options].map((o) => o.text.trim()).join(", "));
    el.value = opt.value;
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return { value: opt.text };
  }
  if (el.isContentEditable) {
    document.execCommand("selectAll", false);
    document.execCommand("insertText", false, text);
  } else {
    const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, "value").set.call(el, text);
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  }
  return { value: (el.isContentEditable ? el.innerText : el.value).slice(0, 200) };
}

// A visible option (of an open dropdown or menu) matching `text`, scrolled into view, with its viewport rect.
function findOption(text) {
  const want = norm(text);
  const all = [...document.querySelectorAll("[role=option], [role=menuitem], [role=menuitemradio], [role=menuitemcheckbox], [role=treeitem]")].filter(visible);
  const t = (o) => norm(optionText(o)) || norm(o.innerText);
  const hit = all.find((o) => t(o) === want) || all.find((o) => t(o).startsWith(want)) || all.find((o) => t(o).includes(want))
    || all.find((o) => t(o).length > 2 && want.includes(t(o)));
  if (!hit) return { found: false, options: all.map((o) => optionText(o) || squash(o.innerText)).filter(Boolean).slice(0, 30) };
  reveal(hit);
  const r = hit.getBoundingClientRect();
  return { found: true, text: optionText(hit) || squash(hit.innerText), x: r.left, y: r.top, w: r.width, h: r.height };
}

// The file input an element stands for: itself, one inside it, or the nearest one in the page (upload buttons
// usually sit next to a hidden <input type=file>). index < 0 = the page's only / first file input.
function fileInputFor(index) {
  const all = [...document.querySelectorAll("input[type=file]")];
  if (!all.length) throw new Error("this page has no file upload field (it may use its own picker, e.g. Google Drive)");
  if (index < 0) return all[0];
  const el = target(index);
  if (el.matches("input[type=file]")) return el;
  const inner = el.querySelector("input[type=file]");
  if (inner) return inner;
  if (el.tagName === "LABEL" && el.control && el.control.type === "file") return el.control;
  // Closest by DOM: the one sharing the deepest ancestor with the element.
  for (let p = el.parentElement; p; p = p.parentElement) {
    const near = p.querySelector("input[type=file]");
    if (near) return near;
  }
  return all[0];
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
  return { ok: input.files.length > 0, files: [...input.files].map((f) => f.name), accept: input.accept || "" };
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
  return { url: location.href, title: document.title, text: main.innerText.replace(/\n{3,}/g, "\n\n").slice(0, 8000) };
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
    if (el.isContentEditable) { document.execCommand("selectAll", false); document.execCommand("insertText", false, text); }
    else if (/^(INPUT|TEXTAREA)$/.test(el.tagName)) {
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
    const all = field.form ? [...field.form.querySelectorAll("input, textarea")] : [field];
    all.forEach((f) => { if (f.type !== "password") f.setAttribute("autocomplete", "off"); });
    return { ok: true };
  }
  function state(i) {
    let el = null; try { el = target(i); } catch {}
    const a = (n) => el && el.getAttribute(n);
    return { sig: JSON.stringify([el && el.checked, a("aria-checked"), a("aria-expanded"), a("aria-selected"), a("aria-pressed"),
      el && el.value, location.href, textHash(), document.activeElement === el]) };
  }
  // Cheap hash of the visible text: its length alone misses same-length changes ("Step 2" → "Step 4"),
  // and a click that did work would then be clicked again by the fallback.
  function textHash() {
    const t = document.body ? document.body.innerText : "";
    let h = 0;
    for (let i = 0; i < t.length; i++) h = (h * 31 + t.charCodeAt(i)) | 0;
    return t.length + ":" + h;
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
  function scroll(dy) {
    const el = scroller();
    if (el) { el.scrollBy({ top: dy, behavior: "instant" }); return { y: el.scrollTop }; }
    window.scrollBy({ top: dy, behavior: "instant" });
    return { y: scrollY };
  }
  function selection() { return String(window.getSelection() || "").slice(0, 8000); }

  // Resolves as soon as `want` shows in the page's text or title — or, with gone, has stayed gone for half a second —
  // woken by the page's own changes (a MutationObserver) rather than polled; { met: false } at the timeout.
  function waitText(want, gone, ms) {
    const w = norm(want);
    const has = () => norm(document.title + " " + (document.body ? document.body.innerText : "")).includes(w);
    return new Promise((resolve) => {
      let done = false, queued = false, goneTimer = null, obs = null, timer = null;
      const finish = (met) => {
        if (done) return;
        done = true;
        if (obs) obs.disconnect();
        clearTimeout(timer); clearTimeout(goneTimer);
        resolve({ met });
      };
      const check = () => {
        queued = false;
        if (done) return;
        const seen = has();
        if (!gone) { if (seen) finish(true); return; }
        if (seen) { clearTimeout(goneTimer); goneTimer = null; }
        else if (!goneTimer) goneTimer = setTimeout(() => { goneTimer = null; if (!has()) finish(true); }, 500);
      };
      // Bursts of changes are read once (innerText lays the page out): at most every 80 ms.
      obs = new MutationObserver(() => { if (!queued) { queued = true; setTimeout(check, 80); } });
      obs.observe(document.documentElement, { childList: true, subtree: true, characterData: true, attributes: true,
                                              attributeFilter: ["hidden", "style", "class", "aria-hidden", "open"] });
      timer = setTimeout(() => finish(false), Math.max(100, ms));
      check();
    });
  }

  window.__clinqy = { snapshot, locate, click, focus, fill, findOption, chosen, upload, review, readText, tables, isActive, value, activeValue, fillActive, prepare, state, scroll, selection, waitText };
})();
