/** Tiny WebAudio CRT: mains hum while on, a static buzz, and a degauss thunk. */
export class CrtSound {
  private ctx: AudioContext | null = null
  private master: GainNode | null = null
  private hum: OscillatorNode[] = []

  start() {
    if (this.ctx) return
    const ctx = new AudioContext()
    const master = ctx.createGain()
    master.gain.value = 0.0001
    master.gain.exponentialRampToValueAtTime(0.5, ctx.currentTime + 0.4)
    master.connect(ctx.destination)
    const lp = ctx.createBiquadFilter()
    lp.type = 'lowpass'
    lp.frequency.value = 420
    lp.connect(master)
    for (const [f, g, type] of [[60, 0.05, 'sawtooth'], [120, 0.03, 'square'], [7800, 0.0025, 'sine']] as const) {
      const o = ctx.createOscillator()
      const gn = ctx.createGain()
      o.type = type
      o.frequency.value = f
      gn.gain.value = g
      o.connect(gn).connect(f > 1000 ? master : lp)
      o.start()
      this.hum.push(o)
    }
    this.ctx = ctx
    this.master = master
  }

  buzz(seconds = 1.2) {
    const ctx = this.ctx
    if (!ctx || !this.master) return
    const len = Math.floor(ctx.sampleRate * seconds)
    const buf = ctx.createBuffer(1, len, ctx.sampleRate)
    const d = buf.getChannelData(0)
    for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * (Math.sin((i / ctx.sampleRate) * 2 * Math.PI * 60) > 0 ? 1 : 0.35)
    const src = ctx.createBufferSource()
    src.buffer = buf
    const bp = ctx.createBiquadFilter()
    bp.type = 'bandpass'
    bp.frequency.value = 1800
    bp.Q.value = 0.7
    const g = ctx.createGain()
    g.gain.setValueAtTime(0.0001, ctx.currentTime)
    g.gain.exponentialRampToValueAtTime(0.18, ctx.currentTime + 0.05)
    g.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + seconds)
    src.connect(bp).connect(g).connect(this.master)
    src.start()
  }

  thunk() {
    const ctx = this.ctx
    if (!ctx || !this.master) return
    const o = ctx.createOscillator()
    const g = ctx.createGain()
    o.frequency.setValueAtTime(110, ctx.currentTime)
    o.frequency.exponentialRampToValueAtTime(38, ctx.currentTime + 0.35)
    g.gain.setValueAtTime(0.4, ctx.currentTime)
    g.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + 0.45)
    o.connect(g).connect(this.master)
    o.start()
    o.stop(ctx.currentTime + 0.5)
  }

  stop() {
    const ctx = this.ctx
    if (!ctx || !this.master) return
    this.master.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + 0.3)
    setTimeout(() => ctx.close(), 400)
    this.ctx = null
    this.master = null
    this.hum = []
  }

  get on() {
    return !!this.ctx
  }
}
