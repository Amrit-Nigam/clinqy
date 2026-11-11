// Page-local feedback. Never captures input, changes focus, or moves the system pointer.
(() => {
  if (window !== window.top || window.__clinqyActivity?.version === 6) return;
  window.__clinqyActivity?.stop();
  const prefix = '◉ Clinqy · ';
  const labels = { working:'Clinqy is working', observing:'Reading the page', planning:'Planning the next step', waiting:'Waiting for the page', verifying:'Checking the result', paused:'Clinqy is paused', error:'Clinqy needs attention', click:'Clicking', type:'Typing', scroll:'Scrolling', drag:'Dragging', hover:'Pointing', upload:'Attaching the file', navigating:'Opening the page' };
  let host, root, cursor, ring, label, badge, expiry, settle, frame, anchor, captureDepth = 0;
  let phase = 'working', point = null, trackingTimer = null, trackingUntil = 0;
  const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches;
  const pageTitle = () => document.title.startsWith(prefix) ? document.title.slice(prefix.length) : document.title;
  // Do not rewrite document.title: it is site content and can be observed by app scripts.
  const viewport = () => {
    const v = window.visualViewport;
    return { x:v?.offsetLeft || 0, y:v?.offsetTop || 0, w:v?.width || innerWidth, h:v?.height || innerHeight };
  };
  function stop() {
    clearTimeout(expiry); clearTimeout(settle); clearTimeout(trackingTimer); cancelAnimationFrame(frame);
    removeEventListener('resize', scheduleLayout); removeEventListener('scroll', scheduleLayout, true);
    window.visualViewport?.removeEventListener('resize', scheduleLayout);
    window.visualViewport?.removeEventListener('scroll', scheduleLayout);
    host?.remove();
    host = root = cursor = ring = label = badge = anchor = point = null;
    captureDepth = 0; frame = null; trackingTimer = null; phase = 'working';
  }
  function scheduleLayout(event) {
    if(event && !anchor)point=null; // Raw/frame-local points cannot be tracked after a viewport move.
    if (!host || frame) return;
    frame = requestAnimationFrame(() => { frame = null; layout(); });
  }
  function trackTarget() {
    clearTimeout(trackingTimer);
    if(!host || !anchor || performance.now()>=trackingUntil)return;
    scheduleLayout();
    trackingTimer=setTimeout(trackTarget,150);
  }
  function layout() {
    if (!host) return;
    const v = viewport();
    for (const [name, value] of Object.entries({x:v.x,y:v.y,w:v.w,h:v.h})) host.style.setProperty(`--${name}`, `${value}px`);
    if (anchor) {
      try {
        const p = window.__clinqy?.activityPoint(anchor.index);
        if (!p || anchor.documentID !== window.__clinqy?.documentID) { anchor = null; point = null; }
        else point = p;
      } catch { anchor = null; point = null; }
    }
    if (point && (point.x < v.x || point.y < v.y || point.x > v.x+v.w || point.y > v.y+v.h)) {
      cursor.style.opacity = '0'; // Do not clamp an offscreen target into a misleading visible position.
    } else {
      const p = point || {x:v.x+24,y:v.y+Math.min(v.h-24,64)};
      cursor.style.opacity = '1'; cursor.style.transform = `translate(${p.x}px,${p.y}px)`;
      cursor.classList.toggle('label-left', p.x > v.x+v.w-110);
    }
    const avoid = point || { x:-1000,y:-1000 };
    const right = avoid.x > v.x+v.w-280 && avoid.y < v.y+80;
    badge.style.left = right ? `${v.x+12}px` : 'auto';
    badge.style.right = right ? 'auto' : `${Math.max(0,innerWidth-v.x-v.w)+12}px`;
    badge.style.top = `${v.y+12}px`;
  }
  function mount() {
    if (host?.isConnected) return;
    host = document.createElement('div');
    host.setAttribute('data-clinqy-overlay','');
    host.style.cssText = 'all:initial!important;position:fixed!important;inset:0!important;z-index:2147483647!important;pointer-events:none!important;contain:layout style!important;';
    root = host.attachShadow({mode:'closed'});
    root.innerHTML = `<style>
      :host { --accent:#5594ee; --surface:#f8fbfff2; --ink:#173555; }
      *, *::before, *::after { box-sizing:border-box; pointer-events:none!important; }
      .edge { position:fixed; left:var(--x); top:var(--y); width:var(--w); height:var(--h); border:1px solid #5594ee80; border-radius:10px; box-shadow:inset 0 0 0 1px #5594ee18,inset 0 0 12px #5594ee16; }
      .badge { position:fixed; max-width:min(280px,calc(100vw - 24px)); display:flex; align-items:center; gap:8px; padding:7px 11px; border:1px solid #5594ee45; border-radius:18px; background:var(--surface); color:var(--ink); box-shadow:0 2px 10px #07162e18; font:500 12px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
      .label { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
      .dot { flex:none; width:6px; height:6px; border-radius:50%; background:var(--accent); }
      .cursor { position:fixed; top:0; left:0; width:1px; height:1px; transform-origin:0 0; }
      .cursor svg { position:absolute; left:-2px; top:-2px; overflow:visible; filter:drop-shadow(0 1px 3px #17355545); }
      .cursor-name { position:absolute; top:20px; left:12px; padding:3px 7px; border-radius:3px 9px 9px 9px; background:#286bc5; color:white; font:500 10px/1.3 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; white-space:nowrap; }
      .label-left .cursor-name { left:auto; right:8px; border-radius:9px 3px 9px 9px; }
      .ring { position:fixed; top:0; left:0; width:28px; height:28px; margin:-14px; border:1px solid var(--accent); background:#5594ee12; border-radius:50%; opacity:0; }
      :host([data-phase="paused"]) { --accent:#b17b24; }
      :host([data-phase="error"]) { --accent:#c25454; }
      @media(prefers-color-scheme:dark) { :host { --surface:#17283bef; --ink:#e5efff; } }
      @media(prefers-contrast:more) { .edge { border-width:2px; border-color:var(--accent); } .badge { border-color:var(--accent); } }
      @media(prefers-reduced-motion:reduce) { * { animation:none!important; transition:none!important; } }
    </style><div class="edge" aria-hidden="true"></div><div class="badge" role="status" aria-live="polite" aria-atomic="true"><span class="dot" aria-hidden="true"></span><span class="label"></span></div><div class="ring" aria-hidden="true"></div><div class="cursor" aria-hidden="true"><svg width="20" height="25" viewBox="-2 -2 20 25"><path d="M0 0L0 18L5 13.5L13 13.5Z" fill="#4385df" stroke="white" stroke-width="1.7" stroke-linejoin="round"/></svg><span class="cursor-name">Clinqy</span></div>`;
    cursor=root.querySelector('.cursor'); ring=root.querySelector('.ring'); label=root.querySelector('.label'); badge=root.querySelector('.badge');
    label.textContent=labels[phase] || labels.working;
    document.documentElement.append(host);
    if(captureDepth)host.style.setProperty('visibility','hidden','important');
    addEventListener('resize',scheduleLayout); addEventListener('scroll',scheduleLayout,true);
    window.visualViewport?.addEventListener('resize',scheduleLayout);
    window.visualViewport?.addEventListener('scroll',scheduleLayout);
    layout();
  }
  function update(state={}) {
    if (state.active===false) { stop(); return; }
    mount(); clearTimeout(expiry); expiry=setTimeout(stop,180000);
    if (state.heartbeat) return;
    clearTimeout(settle);
    phase=labels[state.kind] ? state.kind : 'working';
    host.setAttribute('data-phase',phase);
    label.textContent=state.stage==='prepare' && phase==='click' ? 'Moving to the control' : labels[phase];
    if (Number.isFinite(state.x) && Number.isFinite(state.y)) point={x:state.x,y:state.y};
    anchor=Number.isInteger(state.localIndex) && state.documentID ? {index:state.localIndex,documentID:state.documentID} : null;
    layout();
    trackingUntil=performance.now()+2500; trackTarget();
    // A pulse means input was delivered, never merely that a command was queued.
    if (state.stage==='delivered' && ['click','type','drag','upload'].includes(phase) && point) {
      ring.style.left=`${point.x}px`; ring.style.top=`${point.y}px`;
      ring.getAnimations().forEach(a=>a.cancel());
      const quiet = reduced();
      ring.animate(quiet ? [{opacity:.65},{opacity:0}] : [{opacity:.65,transform:'scale(.6)'},{opacity:0,transform:'scale(1.4)'}],{duration:quiet?80:280,easing:'ease-out'});
    }
    if (state.stage==='delivered') settle=setTimeout(()=>{ if(label) {phase='working';label.textContent=labels.working;host.setAttribute('data-phase',phase);} },900);
  }
  function setCaptureHidden(hidden) {
    captureDepth=Math.max(0,captureDepth+(hidden?1:-1));
    if(host) host.style.setProperty('visibility',captureDepth?'hidden':'visible','important');
  }
  window.__clinqyActivity={version:6,update,stop,pageTitle,setCaptureHidden};
})();
