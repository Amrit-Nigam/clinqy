// Runs inside web pages (in the extension's isolated world). Installed by background.js before each command;
// all page-side logic lives here so helpers are available to every command.
(() => {
  if (window.__cursorboy) return;

function snapshot() {
  const sel = [
    "a[href]", "button", "input:not([type=hidden])", "textarea", "select", "summary", "label[for]",
    "[role=button]", "[role=link]", "[role=tab]", "[role=menuitem]", "[role=checkbox]", "[role=radio]",
    "[role=option]", "[role=switch]", "[role=textbox]", "[role=combobox]", "[role=searchbox]", "[role=treeitem]",
    "[contenteditable=''], [contenteditable=true]", "[onclick]", "[tabindex]:not([tabindex='-1'])",
  ].join(",");
  const vw = innerWidth, vh = innerHeight;
  const seen = new Set();
  const out = [];
  const picked = [];
  const nodes = [];
  const walk = (root) => {
    root.querySelectorAll(sel).forEach((el) => nodes.push(el));
    root.querySelectorAll("*").forEach((el) => { if (el.shadowRoot) walk(el.shadowRoot); });
  };
  walk(document);
  for (const el of nodes) {
    if (seen.has(el)) continue;
    seen.add(el);
    const r = el.getBoundingClientRect();
    if (r.width < 3 || r.height < 3 || r.bottom < 0 || r.right < 0 || r.top > vh || r.left > vw) continue;
    const cs = getComputedStyle(el);
    if (cs.visibility === "hidden" || cs.display === "none" || Number(cs.opacity) < 0.05) continue;
    // Is it actually the thing on top at its centre (not covered by a modal)?
    const cx = Math.min(vw - 1, Math.max(0, r.left + r.width / 2)), cy = Math.min(vh - 1, Math.max(0, r.top + r.height / 2));
    const top = document.elementFromPoint(cx, cy);
    const covered = top && !(el === top || el.contains(top) || top.contains(el));
    const tag = el.tagName.toLowerCase();
    const role = el.getAttribute("role") || (tag === "a" ? "link" : tag === "input" ? (el.type || "text") : tag);
    // Fields are named by their label, never by what's typed in them (so a name stays stable run to run).
    const isField = tag === "input" || tag === "textarea" || tag === "select";
    const labelText = isField && el.labels && el.labels[0] ? el.labels[0].innerText.replace(el.innerText || "", "") : "";
    const text = (el.getAttribute("aria-label") || (isField ? "" : el.innerText) || labelText || el.getAttribute("placeholder") ||
      el.title || el.getAttribute("alt") || el.name || (tag === "button" || tag === "a" ? el.innerText : "") ||
      (tag === "input" && el.type === "submit" ? el.value : "") || "")
      .replace(/\s+/g, " ").trim().slice(0, 100);
    const editable = tag === "input" || tag === "textarea" || el.isContentEditable || /textbox|combobox|searchbox/.test(role);
    if (!text && !editable) continue;
    const item = { i: out.length, role, text, x: r.left, y: r.top, w: r.width, h: r.height };
    if (editable) {
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
    if (covered) item.covered = true;
    if (tag === "a" && el.href) item.href = el.href.slice(0, 120);
    if (el.disabled || el.getAttribute("aria-disabled") === "true") item.disabled = true;
    if (el.getAttribute("aria-checked") === "true" || el.checked) item.checked = true;
    if (el.getAttribute("aria-selected") === "true") item.selected = true;
    if (document.activeElement === el) item.focused = true;
    out.push(item);
    picked.push(el);
    if (out.length >= 220) break;
  }
  window.__cursorboyList = picked;
  const headings = [...document.querySelectorAll("h1,h2,h3")].map((h) => h.innerText.trim()).filter(Boolean).slice(0, 12);
  return {
    url: location.href, title: document.title, focused: document.hasFocus(),
    viewport: { w: vw, h: vh },
    // Where the viewport sits on screen (for browsers that don't expose it to Accessibility).
    screen: { x: screenX, y: screenY, ow: outerWidth, oh: outerHeight, zoom: devicePixelRatio },
    scroll: (() => { const el = scroller(); return el ? { y: el.scrollTop, max: el.scrollHeight - el.clientHeight }
                                                     : { y: scrollY, max: document.documentElement.scrollHeight - vh }; })(),
    headings, elements: out,
  };
}

function target(index) {
  const el = (window.__cursorboyList || [])[index];
  if (!el || !el.isConnected) throw new Error("element w" + index + " is gone; take a new look");
  return el;
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

function readText() {
  const main = document.querySelector("main, article, [role=main]") || document.body;
  return { url: location.href, title: document.title, text: main.innerText.replace(/\n{3,}/g, "\n\n").slice(0, 8000) };
}


  function isActive(i) {
    const el = (window.__cursorboyList || [])[i];
    if (!el) return { active: false };
    const inner = editableOf(el), a = document.activeElement;
    return { active: !!a && (a === inner || inner.contains(a)) && document.hasFocus() };
  }
  function value(i) {
    const el = (window.__cursorboyList || [])[i];
    if (!el) return { value: null };
    const f = editableOf(el);
    return { value: f.tagName === "SELECT" ? (f.options[f.selectedIndex] ? f.options[f.selectedIndex].text.trim() : "")
                                           : String(f.isContentEditable ? f.innerText : f.value || "").slice(0, 400) };
  }
  function activeValue() {
    const el = document.activeElement;
    // Editors like Google Docs keep the caret in an iframe: keys typed now land there, but its text can't be read.
    if (el && el.tagName === "IFRAME") return { editable: true, code: false, value: null, frame: true };
    const editable = el && (el.isContentEditable || /^(INPUT|TEXTAREA)$/.test(el.tagName));
    // Code editors (Monaco on LeetCode, CodeMirror, Ace) re-indent what's typed.
    const code = !!(el && el.closest && el.closest(".monaco-editor, .CodeMirror, .cm-editor, .ace_editor"));
    return { editable: !!editable, code, value: editable ? String(el.isContentEditable ? el.innerText : el.value || "").slice(0, 400) : null };
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
    const el = (window.__cursorboyList || [])[i];
    if (!el) return { ok: false };
    const field = editableOf(el);
    const all = field.form ? [...field.form.querySelectorAll("input, textarea")] : [field];
    all.forEach((f) => { if (f.type !== "password") f.setAttribute("autocomplete", "off"); });
    return { ok: true };
  }
  function state(i) {
    const el = (window.__cursorboyList || [])[i];
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

  window.__cursorboy = { snapshot, click, focus, fill, readText, isActive, value, activeValue, fillActive, prepare, state, scroll, selection };
})();
