// The SF Symbols the Mac UI uses, drawn as small SVGs at the same weights and sizes.
const P = {
  "mic.fill": ['f', 'M12 2.5a3.5 3.5 0 0 0-3.5 3.5v6a3.5 3.5 0 0 0 7 0V6A3.5 3.5 0 0 0 12 2.5z', 'M5.5 11a.9.9 0 0 1 1.8 0 4.7 4.7 0 0 0 9.4 0 .9.9 0 0 1 1.8 0 6.5 6.5 0 0 1-5.6 6.43V20h2.6a.9.9 0 0 1 0 1.8H8.5a.9.9 0 0 1 0-1.8h2.6v-2.57A6.5 6.5 0 0 1 5.5 11z'],
  "waveform": ['s', 'M3 10v4M7 7v10M11 4v16M15 8v8M19 6v12M23 11v2'],
  "pause.fill": ['f', 'M7.5 5h2.6c.5 0 .9.4.9.9v12.2c0 .5-.4.9-.9.9H7.5a.9.9 0 0 1-.9-.9V5.9c0-.5.4-.9.9-.9zm6.4 0h2.6c.5 0 .9.4.9.9v12.2c0 .5-.4.9-.9.9h-2.6a.9.9 0 0 1-.9-.9V5.9c0-.5.4-.9.9-.9z'],
  "play.fill": ['f', 'M8 5.3v13.4c0 .8.9 1.3 1.6.9l10.4-6.7c.6-.4.6-1.4 0-1.8L9.6 4.4C8.9 4 8 4.5 8 5.3z'],
  "square.stack": ['s', 'M7 4.5h11A1.5 1.5 0 0 1 19.5 6v10M4.5 9A1.5 1.5 0 0 1 6 7.5h9A1.5 1.5 0 0 1 16.5 9v9a1.5 1.5 0 0 1-1.5 1.5H6A1.5 1.5 0 0 1 4.5 18z'],
  "square.stack.fill": ['f', 'M7 3.5h11A2.5 2.5 0 0 1 20.5 6v10a1 1 0 1 1-2 0V6a.5.5 0 0 0-.5-.5H7a1 1 0 0 1 0-2zM6 6.5h9A2.5 2.5 0 0 1 17.5 9v9a2.5 2.5 0 0 1-2.5 2.5H6A2.5 2.5 0 0 1 3.5 18V9A2.5 2.5 0 0 1 6 6.5z'],
  "gearshape": ['s', 'M12 8.8a3.2 3.2 0 1 0 0 6.4 3.2 3.2 0 0 0 0-6.4z', 'M19.4 13.5a7.6 7.6 0 0 0 0-3l1.9-1.5-1.9-3.2-2.3.9a7.5 7.5 0 0 0-2.6-1.5L14.1 3h-4.2l-.4 2.7a7.5 7.5 0 0 0-2.6 1.5l-2.3-.9L2.7 9l1.9 1.5a7.6 7.6 0 0 0 0 3L2.7 15l1.9 3.2 2.3-.9a7.5 7.5 0 0 0 2.6 1.5l.4 2.7h4.2l.4-2.7a7.5 7.5 0 0 0 2.6-1.5l2.3.9 1.9-3.2z'],
  "stop.fill": ['f', 'M7 5.5h10A1.5 1.5 0 0 1 18.5 7v10a1.5 1.5 0 0 1-1.5 1.5H7A1.5 1.5 0 0 1 5.5 17V7A1.5 1.5 0 0 1 7 5.5z'],
  "arrow.up": ['s', 'M12 19V5M5.5 11.5 12 5l6.5 6.5'],
  "checkmark": ['s', 'M4.5 12.5l5 5L19.5 7'],
  "xmark": ['s', 'M6 6l12 12M18 6 6 18'],
  "sparkle": ['f', 'M12 2.5c.6 4.6 2.9 6.9 7.5 7.5v1c-4.6.6-6.9 2.9-7.5 7.5h-1c-.6-4.6-2.9-6.9-7.5-7.5v-1C8.1 9.4 10.4 7.1 11 2.5z'],
  "sparkles": ['f', 'M10 3c.5 3.9 2.4 5.8 6.3 6.3v.9c-3.9.5-5.8 2.4-6.3 6.3h-.9c-.5-3.9-2.4-5.8-6.3-6.3v-.9C6.7 8.8 8.6 6.9 9.1 3zM18 13c.3 2.1 1.3 3.1 3.4 3.4v.6c-2.1.3-3.1 1.3-3.4 3.4h-.6c-.3-2.1-1.3-3.1-3.4-3.4v-.6c2.1-.3 3.1-1.3 3.4-3.4z'],
  "eye": ['s', 'M1.8 12S5.5 5 12 5s10.2 7 10.2 7-3.7 7-10.2 7S1.8 12 1.8 12z', 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z'],
  "eye.fill": ['f', 'M12 4.5C5.1 4.5 1.2 11.4 1 11.7a.7.7 0 0 0 0 .6c.2.3 4.1 7.2 11 7.2s10.8-6.9 11-7.2a.7.7 0 0 0 0-.6c-.2-.3-4.1-7.2-11-7.2zm0 11.2a3.7 3.7 0 1 1 0-7.4 3.7 3.7 0 0 1 0 7.4z'],
  "lasso": ['s', 'M12 4c5 0 9 2.5 9 5.6s-4 5.6-9 5.6c-1.3 0-2.6-.2-3.7-.5', 'M12 4C7 4 3 6.5 3 9.6c0 1.6 1.1 3.1 2.9 4.1', 'M6.2 14.1c-.9.9-.7 2.6.5 3.3 1.3.7 3 0 3.1-1.4.1-1.6-2.2-2.8-3.6-1.9zM8.4 17.6c.3 1.4-.3 2.7-1.6 3.4'],
  "graduationcap": ['s', 'M1.8 9 12 4.5 22.2 9 12 13.5z', 'M6 11v4.6c0 1.3 2.7 2.9 6 2.9s6-1.6 6-2.9V11', 'M22.2 9v5'],
  "clock.arrow.circlepath": ['s', 'M3.5 12a8.5 8.5 0 1 0 2.6-6.1', 'M3 3.6v4h4', 'M12 7.5V12l3 2'],
  "return": ['s', 'M20 5v5.5a3 3 0 0 1-3 3H5', 'M9 9.5 5 13.5l4 4'],
  "bubble.left.fill": ['f', 'M12 3.5c5.2 0 9.4 3.6 9.4 8.1S17.2 19.7 12 19.7c-1 0-2-.1-2.9-.4L4.4 21.3c-.4.2-.9-.2-.7-.6l1.1-3.4C3.4 15.9 2.6 13.8 2.6 11.6c0-4.5 4.2-8.1 9.4-8.1z'],
  "play.rectangle.fill": ['f', 'M5 4.5h14A2.5 2.5 0 0 1 21.5 7v10a2.5 2.5 0 0 1-2.5 2.5H5A2.5 2.5 0 0 1 2.5 17V7A2.5 2.5 0 0 1 5 4.5zm5 4.2v6.6c0 .5.5.7.9.5l5.2-3.3c.4-.2.4-.8 0-1l-5.2-3.3c-.4-.2-.9 0-.9.5z'],
  "moon.fill": ['f', 'M14.6 3.1a.7.7 0 0 0-.8.9 7.6 7.6 0 0 1-9.8 9.8.7.7 0 0 0-.9.8A9.3 9.3 0 1 0 14.6 3.1z'],
  "note.text": ['s', 'M5 3.5h14v17H5z', 'M8.5 8h7M8.5 12h7M8.5 16h4'],
  "questionmark.bubble.fill": ['f', 'M12 3c5.2 0 9.4 3.5 9.4 7.9s-4.2 7.9-9.4 7.9c-.9 0-1.8-.1-2.6-.3l-4.1 2.2c-.5.3-1.1-.2-.9-.7l.9-3c-1.7-1.5-2.7-3.6-2.7-6.1C2.6 6.5 6.8 3 12 3zm.1 3.7c-1.6 0-2.8.9-3 2.2a.8.8 0 0 0 1.6.3c.1-.6.6-1 1.4-1 .9 0 1.4.5 1.4 1.1 0 .5-.3.8-1 1.3-.8.5-1.3 1.1-1.3 2v.3a.8.8 0 0 0 1.6 0v-.2c0-.4.2-.7.9-1.1.9-.6 1.4-1.2 1.4-2.3 0-1.5-1.3-2.6-3-2.6zm-.1 7.6a1 1 0 1 0 0 2 1 1 0 0 0 0-2z'],
  "lock.fill": ['f', 'M12 2.5a4.5 4.5 0 0 0-4.5 4.5v3H7a2 2 0 0 0-2 2v7.5a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V12a2 2 0 0 0-2-2h-.5V7A4.5 4.5 0 0 0 12 2.5zm2.7 7.5H9.3V7a2.7 2.7 0 0 1 5.4 0z'],
  "checkmark.shield.fill": ['f', 'M12 2.3 4.5 5.1v6.4c0 4.7 3.2 8.9 7.5 10.2 4.3-1.3 7.5-5.5 7.5-10.2V5.1zm-1.2 13.2-3.6-3.6 1.3-1.3 2.3 2.3 4.8-4.8 1.3 1.3z'],
  "wrench.and.screwdriver": ['s', 'M14.5 6.5a4 4 0 0 0 5 5L12 19a2.1 2.1 0 0 1-3-3z', 'M4 4l5 5M3.5 6.5 6.5 3.5'],
  "arrow.turn.down.right": ['s', 'M5 4v7a3 3 0 0 0 3 3h11', 'M15 10l4 4-4 4'],
  "doc.on.doc": ['s', 'M8 8h10v12.5H8z', 'M5.5 15.5V3.5h10'],
  "doc.on.clipboard": ['s', 'M8 4.5H6.5v16h11v-16H16', 'M9 3h6v3H9z'],
  "text.quote": ['s', 'M4 6h16M4 10.5h16M4 15h10M4 19.5h7'],
  "arrow.up.right": ['s', 'M7 17 17 7M8.5 7H17v8.5'],
  "checkmark.circle": ['s', 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z', 'M8 12.3l2.7 2.7L16.2 9.5'],
  "xmark.circle": ['s', 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z', 'M9 9l6 6M15 9l-6 6'],
  "trash": ['s', 'M4 6.5h16M9.5 6.5V4h5v2.5M6.5 6.5l1 14h9l1-14'],
  "bolt.horizontal.circle": ['s', 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z', 'M7.5 12.5h4.5l-1 3.5 5.5-4.5H12l1-3.5z'],
  "arrow.uturn.backward": ['s', 'M9 14 4.5 9.5 9 5', 'M4.5 9.5H15a5 5 0 0 1 0 10h-3'],
  "waveform.badge.plus": ['s', 'M3 10v4M7 7v10M11 4v16M15 8v8'],
  "mic.slash": ['s', 'M3 3l18 18', 'M9 9v3a3 3 0 0 0 5.1 2.1M15 9.3V6a3 3 0 0 0-5.9-.7', 'M5.5 11a6.5 6.5 0 0 0 10.8 4.9M18.5 11a6.5 6.5 0 0 1-.4 2.2M12 17.5V21'],
  "exclamationmark.circle": ['s', 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z', 'M12 7.5v5.5M12 16.4v.1'],
};
function icon(name, extra = "") {
  const p = P[name] || P["sparkle"];
  const filled = p[0] === "f";
  return `<svg class="i ${filled ? "f" : ""} ${extra}" viewBox="0 0 24 24">${p.slice(1).map((d) => `<path d="${d}"/>`).join("")}</svg>`;
}

// The Orb: an Apple Watch–style "breathe" flower — six petals bloom out and back, faster while working, swelling
// with the voice; tinted by mood (teal/cyan when idle). Same maths as the SwiftUI Orb.
function orb(canvas) {
  const ctx = canvas.getContext("2d");
  const state = { mood: "idle", level: 0 };
  const dpr = () => window.devicePixelRatio || 1;
  const mix = (c, f) => c.map((v) => v + (255 - v) * f);
  const base = { failure: [255, 84, 77], success: [51, 204, 115] };
  function frame() {
    const size = canvas.clientWidth;
    const s = dpr();
    if (canvas.width !== Math.round(size * s)) { canvas.width = Math.round(size * s); canvas.height = Math.round(size * s); }
    ctx.setTransform(s, 0, 0, s, 0, 0);
    ctx.clearRect(0, 0, size, size);
    const t = performance.now() / 1000;
    const busy = state.mood === "thinking" || state.mood === "acting";
    const period = busy ? 1.4 : 3.0;
    const bloom = 0.5 - 0.5 * Math.cos(((t % period) / period) * 2 * Math.PI);
    const open = state.mood === "listening" ? Math.max(bloom, Math.min(1, state.level * 1.6)) : bloom;
    let a, b;
    if (state.mood === "idle") { a = [46, 212, 191]; b = [33, 212, 237]; }
    else { a = base[state.mood] || [59, 130, 255]; b = mix(a, 0.35); }
    const petal = size * 0.42;
    const rot = t * (busy ? 1.2 : 0.15) + open * Math.PI / 3;
    ctx.save();
    ctx.translate(size / 2, size / 2);
    ctx.rotate(rot);
    ctx.globalCompositeOperation = "lighter";
    ctx.shadowColor = `rgba(${a[0]},${a[1]},${a[2]},${0.35 + 0.45 * open})`;
    ctx.shadowBlur = 2 + 6 * open;
    for (let i = 0; i < 6; i++) {
      const ang = i * Math.PI / 3;
      const c = i % 2 === 0 ? a : b;
      const r = (petal / 2) * (0.45 + 0.75 * open);
      ctx.fillStyle = `rgba(${c[0] | 0},${c[1] | 0},${c[2] | 0},0.7)`;
      ctx.beginPath();
      ctx.arc(Math.cos(ang) * size * 0.3 * open, Math.sin(ang) * size * 0.3 * open, r, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.restore();
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
  return state;
}
