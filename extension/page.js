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
    for (let n = tw.nextNode(); n; n = tw.nextNode()) if (n.shadowRoot) walk(n.shadowRoot);
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

function snapshot() {
  const started = performance.now();
  const vw = innerWidth, vh = innerHeight;
  const seen = new Set(), listed = new Set();
  const out = [], picked = [], sigs = [];
  let above = 0, below = 0, skipped = 0, truncated = false;
  for (const el of candidates()) {
    if (seen.has(el)) continue;
    seen.add(el);
    if (performance.now() - started > 700) { truncated = true; break; }   // huge pages: list what we have
    try {
      const r = el.getBoundingClientRect();
      if (r.width < 3 || r.height < 3) continue;
      if (r.bottom < 0 || r.top > vh) {
        // Off screen: just count fields and buttons, so the model knows to scroll.
        if (el.getClientRects().length && (/^(INPUT|TEXTAREA|SELECT|BUTTON)$/.test(el.tagName)
            || /^(listbox|radio|checkbox|textbox|combobox|switch|button)$/.test(el.getAttribute("role") || ""))) {
          if (r.bottom < 0) above++; else below++;
        }
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
      const covered = top && !(el === top || el.contains(top) || top.contains(el));
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
      if (document.activeElement === el) item.focused = true;
      out.push(item);
      picked.push(el);
      listed.add(el);
      sigs.push({ role, text, q: d.q, x: r.left + r.width / 2, y: r.top + r.height / 2 });
      if (out.length >= 220) { truncated = true; break; }
    } catch (e) { skipped++; }   // one odd element never costs the whole page
  }
  window.__clinqyList = picked;
  window.__clinqySigs = sigs;
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
    headings, elements: out, messages, text, frames, above, below, truncated, skipped,
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

function click(index) {
  const el = target(index);
  el.scrollIntoView({ block: "nearest", inline: "nearest" });
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
  el.scrollIntoView({ block: "nearest", inline: "nearest" });
  el.focus({ preventScroll: true });
  if (el.select && !el.isContentEditable) el.select();
  return { focused: document.activeElement === el || el.contains(document.activeElement) };
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
  hit.scrollIntoView({ block: "nearest", inline: "nearest" });
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

function readText() {
  const main = document.querySelector("main, article, [role=main]") || document.body;
  return { url: location.href, title: document.title, text: main.innerText.replace(/\n{3,}/g, "\n\n").slice(0, 8000) };
}


  function isActive(i) {
    let el = null; try { el = target(i); } catch {}
    if (!el) return { active: false };
    const inner = editableOf(el), a = document.activeElement;
    return { active: !!a && (a === inner || inner.contains(a)) && document.hasFocus() };
  }
  function value(i) {
    let el = null; try { el = target(i); } catch {}
    if (!el) return { value: null };
    const f = editableOf(el);
    return { value: f.tagName === "SELECT" ? (f.options[f.selectedIndex] ? f.options[f.selectedIndex].text.trim() : "")
                                           : String(f.isContentEditable ? f.innerText : f.value || "").slice(0, 400) };
  }
  function activeValue() {
    const el = document.activeElement;
    // Editors like Google Docs keep the caret in an iframe: keys typed now land there, but its text can't be read.
    const where = { hasFocus: document.hasFocus(), url: location.href };
    if (el && (el.tagName === "IFRAME" || el.tagName === "FRAME")) return { ...where, editable: true, code: false, value: null, frame: true };
    const editable = el && (el.isContentEditable || /^(INPUT|TEXTAREA)$/.test(el.tagName));
    // Code editors (Monaco on LeetCode, CodeMirror, Ace) re-indent what's typed.
    const code = !!(el && el.closest && el.closest(".monaco-editor, .CodeMirror, .cm-editor, .ace_editor"));
    return { ...where, editable: !!editable, code, value: editable ? String(el.isContentEditable ? el.innerText : el.value || "").slice(0, 400) : null };
  }
  function fillActive(text) {
    const el = document.activeElement;
    if (!el) return { value: null };
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
      el && el.value, location.href, document.body ? document.body.innerText.length : 0, document.activeElement === el]) };
  }
  // Apps like the AWS console scroll an inner panel, not the window: scroll whichever actually moves.
  function scroller() {
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

  window.__clinqy = { snapshot, click, focus, fill, findOption, chosen, upload, review, readText, isActive, value, activeValue, fillActive, prepare, state, scroll, selection };
})();
