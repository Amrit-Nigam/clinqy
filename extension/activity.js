// Page-local feedback. No browser/system pointer events, focus changes, or page input.
(() => {
  if (window !== window.top || window.__clinqyActivity?.version === 5) return;
  window.__clinqyActivity?.stop();
  const prefix = '◉ Clinqy · ';
  let host, root, cursor, ring, label, titleObserver, expiry, settle;
  let siteTitle = document.title;
  const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches;
  const pageTitle = () => document.title.startsWith(prefix) ? document.title.slice(prefix.length) : document.title;
  function stop() {
    clearTimeout(expiry); clearTimeout(settle);
    titleObserver?.disconnect();
    titleObserver = null;
    if (document.title.startsWith(prefix)) document.title = document.title.slice(prefix.length);
    host?.remove();
    host = root = cursor = ring = label = null;
  }
  function mount() {
    if (host?.isConnected) return;
    host = document.createElement('div');
    host.setAttribute('data-clinqy-overlay', '');

    host.style.cssText = 'all:initial!important;position:fixed!important;inset:0!important;z-index:2147483647!important;pointer-events:none!important;contain:layout style!important;';
    root = host.attachShadow({ mode: 'closed' });
    root.innerHTML = `<style>
      :host, * { box-sizing:border-box; pointer-events:none !important; }
      .edge { position:fixed; inset:0; border:2px solid #6aa7edb3; border-radius:8px; box-shadow:inset 0 0 10px #438bff26; animation:breathe 2.6s ease-in-out infinite; }
      @keyframes breathe { 50% { border-color:#8bb9f0cc; box-shadow:inset 0 0 14px #438bff38; } }
      .badge { position:fixed; top:12px; right:14px; display:flex; align-items:center; gap:9px; padding:9px 13px; border:1px solid #7eb5ff; border-radius:24px; background:#102341f5; color:#f4f8ff; box-shadow:0 3px 16px #07162e45; font:600 12px/1.35 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
      .cursor-name { position:absolute; top:23px; left:12px; padding:4px 8px; border-radius:5px 12px 12px 12px; background:#135fc8; color:white; box-shadow:0 2px 8px #07162e40; font:600 11px/1.3 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; white-space:nowrap; }
      .dot { width:7px; height:7px; border-radius:50%; background:#82afff; box-shadow:0 0 0 4px #4a8cff25; }
      .cursor { position:fixed; top:0; left:0; width:1px; height:1px; opacity:1; transform:translate(32px,64px); transform-origin:0 0; }
      .cursor svg { position:absolute; left:-3px; top:-3px; overflow:visible; transform-origin:3px 3px; filter:drop-shadow(0 0 6px #3b82ffd9); }
      .cursor.typing svg { animation:typing 450ms ease-in-out infinite alternate; }
      @keyframes typing { from { translate:0 -1.5px; } to { translate:0 1.5px; } }
      .ring { position:fixed; top:0; left:0; width:36px; height:36px; margin:-18px; border:2px solid #3b82ff; background:#3b82ff20; border-radius:50%; opacity:0; }
      @media (prefers-reduced-motion:reduce) { .edge, .cursor.typing svg { animation:none; } .cursor { transition:none; } }
    </style><div class="edge" aria-hidden="true"></div><div class="badge" role="status" aria-live="polite" aria-atomic="true"><span class="dot" aria-hidden="true"></span><span class="label">Clinqy is working</span></div><div class="ring" aria-hidden="true"></div><div class="cursor" aria-hidden="true"><svg width="20" height="25" viewBox="-3 -3 20 25" aria-hidden="true"><path d="M0 0L0 19L5.2 14.2L13.6 14.2Z" fill="#3b82ff" stroke="#ffffff" stroke-width="2" stroke-linejoin="round"/></svg><span class="cursor-name">Clinqy</span></div>`;
    cursor = root.querySelector('.cursor'); ring = root.querySelector('.ring'); label = root.querySelector('.label');
    cursor.style.transform = `translate(${Math.max(24, innerWidth - 185)}px,70px)`;
    document.documentElement.append(host);
    siteTitle = pageTitle();
    const markTitle = () => {
      if (!document.title.startsWith(prefix)) siteTitle = document.title;
      const desired = prefix + siteTitle;
      if (document.title !== desired) document.title = desired;
    };
    titleObserver = new MutationObserver(markTitle);
    titleObserver.observe(document.head || document.documentElement, { childList: true, characterData: true, subtree: true });
    markTitle();
  }
  function update(state = {}) {
    if (state.active === false) { stop(); return; }
    mount();
    clearTimeout(expiry);
    // A crashed app/worker must not leave a permanent "working" marker behind.
    // Allow a model turn and an explicit rate-limit wait; normal completion/socket loss clears immediately.
    expiry = setTimeout(stop, 180000);
    const labels = { click:'Clinqy is clicking', type:'Clinqy is typing', scroll:'Clinqy is scrolling', working:'Clinqy is working' };
    const nextLabel = labels[state.kind] || labels.working;
    if (label.textContent !== nextLabel) label.textContent = nextLabel;
    clearTimeout(settle);
    cursor.classList.toggle('typing', state.kind === 'type' && !reduced());
    if (state.kind && state.kind !== 'working') settle = setTimeout(() => {
      if (label) label.textContent = labels.working;
      cursor?.classList.remove('typing');
    }, 1000);
    if (Number.isFinite(state.x) && Number.isFinite(state.y)) {
      const x = Math.max(0, Math.min(innerWidth - 4, state.x + 3));
      const y = Math.max(0, Math.min(innerHeight - 4, state.y + 3));
      const start = cursor.getBoundingClientRect();
      const distance = Math.hypot(x - start.left, y - start.top);
      const lift = Math.min(distance * .22, 90);
      cursor.getAnimations().forEach(a => a.cancel());
      cursor.style.opacity = '1';
      cursor.style.transform = `translate(${x}px,${y}px)`;
      if (!reduced() && distance >= 4) {
        const frames = Array.from({length:21}, (_, i) => {
          const raw = i / 20, t = raw * raw * (3 - 2 * raw), u = 1 - t;
          const px = u*u*start.left + 2*u*t*(start.left+x)/2 + t*t*x;
          const py = u*u*start.top + 2*u*t*((start.top+y)/2-lift) + t*t*y;
          return {transform:`translate(${px}px,${py}px) scale(${1 + .28 * Math.sin(raw*Math.PI)})`};
        });
        cursor.animate(frames, {duration:Math.min(.8, Math.max(.3, .24 + distance/1900))*1000});
      }
      if (state.kind === 'click') {
        cursor.querySelector('svg').animate([{transform:'scale(1)'},{transform:'scale(.75)'},{transform:'scale(1)'}], {duration:reduced() ? 100 : 260});
        ring.style.left = `${x-3}px`; ring.style.top = `${y-3}px`;
        ring.getAnimations().forEach(a => a.cancel());
        ring.animate([{ opacity:.8, scale:.5 }, { opacity:0, scale:1.6 }], { duration:reduced() ? 100 : 480, easing:'ease-out' });
      }
    }
  }
  // Evidence captures exclude feedback so OCR/model checks cannot mistake our status for page content.
  // Visibility is restored by the capture caller in finally; no DOM/title lifecycle changes are needed.
  function setCaptureHidden(hidden) { if (host) host.style.setProperty('visibility', hidden ? 'hidden' : 'visible', 'important'); }
  window.__clinqyActivity = { version:5, update, stop, pageTitle, setCaptureHidden };
})();
