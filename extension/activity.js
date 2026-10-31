// Page-local feedback. No browser/system pointer events, focus changes, or page input.
(() => {
  if (window !== window.top || window.__clinqyActivity?.version === 1) return;
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
    host.setAttribute('aria-hidden', 'true');
    host.inert = true;
    host.style.cssText = 'all:initial!important;position:fixed!important;inset:0!important;z-index:2147483647!important;pointer-events:none!important;contain:layout style!important;';
    root = host.attachShadow({ mode: 'closed' });
    root.innerHTML = `<style>
      :host, * { box-sizing:border-box; pointer-events:none !important; }
      .edge { position:fixed; inset:0; border:2px solid #4a8cff; box-shadow:inset 0 0 22px #4a8cff30; border-radius:5px; }
      .badge { position:fixed; top:12px; right:14px; display:flex; align-items:center; gap:8px; padding:9px 13px; border:1px solid #82afff; border-radius:20px; background:#142342; color:#fff; box-shadow:0 3px 14px #10224738; font:500 12px/1.2 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif; }
      .dot { width:7px; height:7px; border-radius:50%; background:#82afff; box-shadow:0 0 0 4px #4a8cff25; }
      .cursor { position:fixed; top:0; left:0; width:30px; height:34px; opacity:0; transform:translate(32px,64px); transition:transform 180ms cubic-bezier(.2,.75,.25,1); filter:drop-shadow(0 2px 3px #12254055); }
      .ring { position:fixed; top:0; left:0; width:36px; height:36px; margin:-18px; border:2px solid #4a8cff; background:#4a8cff20; border-radius:50%; opacity:0; }
      @media (prefers-reduced-motion:reduce) { .cursor { transition:none; } }
    </style><div class="edge"></div><div class="badge"><span class="dot"></span><span class="label">Clinqy is working</span></div><div class="ring"></div><div class="cursor"><svg width="30" height="34" viewBox="0 0 30 34" aria-hidden="true"><path d="M3 2L25 20L15 21L11 31L3 2Z" fill="#4a8cff" stroke="white" stroke-width="2" stroke-linejoin="round"/></svg></div>`;
    cursor = root.querySelector('.cursor'); ring = root.querySelector('.ring'); label = root.querySelector('.label');
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
    expiry = setTimeout(stop, 45000);
    const labels = { click:'Clinqy is clicking', type:'Clinqy is typing', scroll:'Clinqy is scrolling', working:'Clinqy is working' };
    label.textContent = labels[state.kind] || labels.working;
    clearTimeout(settle);
    if (state.kind && state.kind !== 'working') settle = setTimeout(() => { if (label) label.textContent = labels.working; }, 1000);
    if (Number.isFinite(state.x) && Number.isFinite(state.y)) {
      const x = Math.max(0, Math.min(innerWidth - 4, state.x));
      const y = Math.max(0, Math.min(innerHeight - 4, state.y));
      cursor.style.opacity = '1';
      cursor.style.transform = `translate(${x}px,${y}px)`;
      if (state.kind === 'click') {
        ring.style.left = `${x}px`; ring.style.top = `${y}px`;
        ring.getAnimations().forEach(a => a.cancel());
        ring.animate([{ opacity:.8, scale:.5 }, { opacity:0, scale:1.6 }], { duration:reduced() ? 100 : 480, easing:'ease-out' });
      }
    }
  }
  window.__clinqyActivity = { version:1, update, stop, pageTitle };
})();
