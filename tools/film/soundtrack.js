/*
 * Саундтрек ролика «LogoCRM за минуту» — синтез, без чужих сэмплов и треков:
 * права на звук целиком наши. Тайминги — те же, что у сцен в film.html
 * (SCENES и блоки 1–8); поменяли сцену — сдвиньте её события здесь.
 *
 * buildSoundtrack() → Promise<AudioBuffer> (48 кГц, стерео, ровно 60 с).
 * Рендер — OfflineAudioContext, быстрее реального времени; render.cjs
 * кодирует результат в AAC и кладёт дорожкой в тот же MP4.
 */
// eslint-disable-next-line no-unused-vars
async function buildSoundtrack() {
  const SR = 48000, DUR = 60
  const ctx = new OfflineAudioContext(2, SR * DUR, SR)

  // Детерминированный шум: одинаковый звук при каждом рендере.
  let seed = 20261007
  const rnd = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296) * 2 - 1
  const noiseBuf = ctx.createBuffer(2, SR * 3, SR)
  for (let c = 0; c < 2; c++) { const d = noiseBuf.getChannelData(c); for (let i = 0; i < d.length; i++) d[i] = rnd() }

  // Шина: музыка и эффекты → компрессор → выход; общий хвост реверберации.
  const comp = ctx.createDynamicsCompressor()
  comp.threshold.value = -16; comp.ratio.value = 3.5; comp.attack.value = 0.005; comp.release.value = 0.25
  // Лимитер последним: громкость для веба (~−17 дБ RMS) без клиппинга на финальном ударе.
  const limiter = ctx.createDynamicsCompressor()
  limiter.threshold.value = -3; limiter.knee.value = 0; limiter.ratio.value = 20; limiter.attack.value = 0.001; limiter.release.value = 0.1
  const master = ctx.createGain(); master.gain.value = 1.45
  master.connect(comp); comp.connect(limiter); limiter.connect(ctx.destination)
  // Затухание в конце, чтобы ролик не обрывался на полуслове.
  master.gain.setValueAtTime(1.45, 58.2); master.gain.linearRampToValueAtTime(0, 59.95)

  const verb = ctx.createConvolver()
  const ir = ctx.createBuffer(2, SR * 2.8, SR)
  for (let c = 0; c < 2; c++) { const d = ir.getChannelData(c); for (let i = 0; i < d.length; i++) d[i] = rnd() * Math.pow(1 - i / d.length, 3.2) }
  verb.buffer = ir
  const wet = ctx.createGain(); wet.gain.value = 0.32
  verb.connect(wet); wet.connect(master)

  const bus = (gain, send = 0.3) => {
    const g = ctx.createGain(); g.gain.value = gain; g.connect(master)
    if (send) { const s = ctx.createGain(); s.gain.value = send; g.connect(s); s.connect(verb) }
    return g
  }
  const music = bus(0.34, 0.45)
  const drums = bus(0.42, 0.08)
  const sfx = bus(0.62, 0.25)

  const env = (g, t, peak, a, d, sustain = 0, r = 0.05, hold = 0) => {
    g.gain.setValueAtTime(0.0001, t)
    g.gain.linearRampToValueAtTime(peak, t + a)
    g.gain.exponentialRampToValueAtTime(Math.max(peak * sustain, 0.0001), t + a + d)
    if (hold) { g.gain.setValueAtTime(Math.max(peak * sustain, 0.0001), t + a + d + hold) }
    g.gain.exponentialRampToValueAtTime(0.0001, t + a + d + hold + r)
  }
  const osc = (type, freq, t, stop, dest, detune = 0) => {
    const o = ctx.createOscillator(); o.type = type; o.frequency.setValueAtTime(freq, t); o.detune.value = detune
    o.connect(dest); o.start(t); o.stop(stop); return o
  }
  const noise = (t, dur, dest) => { const s = ctx.createBufferSource(); s.buffer = noiseBuf; s.loop = true; s.connect(dest); s.start(t, (t * 7.3) % 2); s.stop(t + dur); return s }
  const pan = (dest, v) => { const p = ctx.createStereoPanner(); p.pan.value = v; p.connect(dest); return p }

  // ---------- музыка: ре мажор, 96 BPM, аккорд на такт (2,5 с) ----------
  const BEAT = 60 / 96, BAR = BEAT * 4
  const N = (m) => 440 * Math.pow(2, (m - 69) / 12) // MIDI → Гц
  const CHORDS = [
    { root: 38, notes: [50, 54, 57, 61] }, // Dmaj7
    { root: 35, notes: [47, 50, 54, 57] }, // Bm7
    { root: 31, notes: [43, 47, 50, 54] }, // Gmaj7
    { root: 33, notes: [45, 49, 52, 59] }, // A(add9)
  ]
  const chordAt = (t) => CHORDS[Math.floor(t / BAR) % 4]

  // Пэд: пара расстроенных пил через мягкий фильтр, длинная атака.
  const padBar = (t, chord, level, bright) => {
    const f = ctx.createBiquadFilter(); f.type = 'lowpass'; f.Q.value = 0.6
    f.frequency.setValueAtTime(bright * 0.6, t); f.frequency.linearRampToValueAtTime(bright, t + BAR * 0.6)
    const g = ctx.createGain(); f.connect(g); g.connect(music)
    env(g, t, level, 0.9, 0.6, 0.75, 1.4, BAR - 1.5)
    chord.notes.forEach((m, i) => { const p = pan(f, (i - 1.5) * 0.35); osc('sawtooth', N(m), t, t + BAR + 1.6, p, -7); osc('sawtooth', N(m), t, t + BAR + 1.6, p, 7) })
  }
  const bassBar = (t, chord, level) => {
    const g = ctx.createGain(); g.connect(music)
    const f = ctx.createBiquadFilter(); f.type = 'lowpass'; f.frequency.value = 260; f.connect(g)
    env(g, t, level, 0.04, 0.5, 0.6, 0.4, BAR - 0.9)
    osc('triangle', N(chord.root), t, t + BAR + 0.5, f); osc('sine', N(chord.root - 12), t, t + BAR + 0.5, f)
  }
  const pluck = (t, m, level, p) => {
    const g = ctx.createGain(); g.connect(pan(music, p)); env(g, t, level, 0.004, 0.32, 0.0001, 0.05)
    osc('triangle', N(m), t, t + 0.45, g); osc('sine', N(m + 12), t, t + 0.45, g)
  }
  const kick = (t, level) => {
    const g = ctx.createGain(); g.connect(drums); env(g, t, level, 0.003, 0.28, 0.0001, 0.05)
    const o = osc('sine', 120, t, t + 0.4, g); o.frequency.exponentialRampToValueAtTime(42, t + 0.22)
  }
  const hat = (t, level) => {
    const f = ctx.createBiquadFilter(); f.type = 'highpass'; f.frequency.value = 7500
    const g = ctx.createGain(); f.connect(g); g.connect(pan(drums, 0.25)); env(g, t, level, 0.002, 0.045, 0.0001, 0.02)
    noise(t, 0.08, f)
  }

  for (let bar = 0; bar * BAR < DUR; bar++) {
    const t = bar * BAR, ch = chordAt(t)
    const intro = t < 6, finale = t >= 54
    padBar(t, ch, intro ? 0.10 + bar * 0.03 : finale ? 0.17 : 0.13, intro ? 900 : finale ? 2600 : 1600)
    if (t >= 5) bassBar(t, ch, finale ? 0.5 : 0.36)
    // Ритм и арпеджио — только в рабочих сценах (11–54 с), перед финалом пауза на нарастание.
    for (let b = 0; b < 8; b++) {
      const tb = t + b * (BEAT / 2)
      if (tb < 11 || tb >= 52.6) continue
      if (b % 2 === 0) kick(tb, b === 0 ? 0.5 : 0.32)
      else hat(tb, 0.08)
      const arp = [0, 1, 2, 3, 2, 1, 3, 2][b]
      pluck(tb, ch.notes[arp] + 12, tb > 20 && tb < 31 ? 0.05 : 0.07, b % 2 ? 0.3 : -0.3)
    }
  }

  // ---------- эффекты ----------
  const whoosh = (t, dur, up = true, level = 0.5) => {
    const f = ctx.createBiquadFilter(); f.type = 'bandpass'; f.Q.value = 1.2
    f.frequency.setValueAtTime(up ? 280 : 4200, t); f.frequency.exponentialRampToValueAtTime(up ? 4200 : 300, t + dur)
    const g = ctx.createGain(); f.connect(g); g.connect(sfx)
    g.gain.setValueAtTime(0.0001, t); g.gain.linearRampToValueAtTime(level, t + dur * 0.6); g.gain.exponentialRampToValueAtTime(0.0001, t + dur)
    noise(t, dur + 0.05, f)
  }
  const blip = (t, freq, level = 0.25, dur = 0.12, type = 'sine', p = 0) => {
    const g = ctx.createGain(); g.connect(pan(sfx, p)); env(g, t, level, 0.003, dur, 0.0001, 0.03)
    osc(type, freq, t, t + dur + 0.1, g)
  }
  const pop = (t, f0, f1, level = 0.3, p = 0) => {
    const g = ctx.createGain(); g.connect(pan(sfx, p)); env(g, t, level, 0.002, 0.09, 0.0001, 0.03)
    const o = osc('sine', f0, t, t + 0.15, g); o.frequency.exponentialRampToValueAtTime(f1, t + 0.07)
  }
  const tick = (t, level = 0.12, freq = 3200) => {
    const f = ctx.createBiquadFilter(); f.type = 'bandpass'; f.frequency.value = freq; f.Q.value = 3
    const g = ctx.createGain(); f.connect(g); g.connect(sfx); env(g, t, level, 0.001, 0.018, 0.0001, 0.01)
    noise(t, 0.04, f)
  }
  const chime = (t, notes, level = 0.18) => notes.forEach((m, i) => {
    const g = ctx.createGain(); g.connect(pan(sfx, i % 2 ? 0.25 : -0.25)); env(g, t + i * 0.07, level, 0.003, 1.3, 0.0001, 0.1)
    osc('sine', N(m), t + i * 0.07, t + i * 0.07 + 1.5, g); osc('sine', N(m + 12), t + i * 0.07, t + i * 0.07 + 1.5, g, 4)
  })
  const buzz = (t) => {
    const f = ctx.createBiquadFilter(); f.type = 'lowpass'; f.frequency.value = 900
    const g = ctx.createGain(); f.connect(g); g.connect(sfx)
    g.gain.setValueAtTime(0.0001, t)
    for (let i = 0; i < 3; i++) { g.gain.linearRampToValueAtTime(0.22, t + i * 0.14 + 0.01); g.gain.linearRampToValueAtTime(0.0001, t + i * 0.14 + 0.1) }
    osc('square', 98, t, t + 0.5, f); osc('square', 104, t, t + 0.5, f)
  }
  const thump = (t, level = 0.5) => {
    const g = ctx.createGain(); g.connect(sfx); env(g, t, level, 0.002, 0.22, 0.0001, 0.05)
    const o = osc('sine', 180, t, t + 0.3, g); o.frequency.exponentialRampToValueAtTime(60, t + 0.18)
    const f = ctx.createBiquadFilter(); f.type = 'lowpass'; f.frequency.value = 1800; f.connect(g); noise(t, 0.05, f)
  }

  // 1. Хук: тональные «попы» на каждое слово, вверх по пентатонике.
  ;[0.25, 1.1, 1.95, 2.8].forEach((t, i) => pop(t + 0.05, N(74 + [0, 2, 4, 7][i]) * 0.5, N(74 + [0, 2, 4, 7][i]), 0.26, (i - 1.5) * 0.3))
  blip(3.95, N(81), 0.12, 0.6)
  whoosh(4.6, 1.0, false, 0.4) // слова сжимаются в точку

  // 2. Логотип: точка, мерцание при прорисовке L, «поп» точки, буквы.
  pop(5.45, 300, 900, 0.32)
  for (let i = 0; i < 10; i++) blip(6.9 + i * 0.11, N(86 + [0, 2, 4, 7, 9][i % 5]), 0.05, 0.25, 'sine', (i % 2 ? 0.4 : -0.4))
  pop(7.95, 700, 1400, 0.3)
  for (let i = 0; i < 7; i++) tick(8.1 + i * 0.07, 0.08, 2600 + i * 200)

  // Переходы между сценами — «вжух» в такт раскрывающемуся кругу.
  ;[11, 20, 31, 40, 48].forEach((t) => whoosh(t - 0.5, 0.95, true, 0.45))

  // 3. Расписание: занятия падают, конфликт, перенос, «сохранено».
  for (let i = 0; i < 10; i++) tick(12.0 + i * 0.12, 0.1, 1800 + (i % 3) * 300)
  whoosh(14.0, 1.1, false, 0.3)
  thump(15.2, 0.45); buzz(15.25)
  whoosh(16.6, 0.9, true, 0.22)
  chime(17.5, [74, 78, 81], 0.15)

  // 4. Голосовое → резюме → утвердить → отправлено.
  pop(21.25, 400, 800, 0.28)
  whoosh(24.2, 1.2, true, 0.3)
  for (let t = 25.45; t < 28.0; t += 0.085) tick(t, 0.06 + 0.03 * Math.abs(Math.sin(t * 13)), 2800 + Math.abs(Math.sin(t * 7)) * 900)
  blip(28.45, 1600, 0.18, 0.04, 'square'); chime(28.6, [76, 81], 0.12)
  whoosh(29.0, 0.8, true, 0.35); blip(29.35, N(88), 0.12, 0.5)

  // 5. Карта звуков: перевороты плиток, цели, лист, штамп PDF.
  for (let i = 0; i < 10; i++) tick(32.65 + i * 0.12, 0.12, 1400 + i * 80)
  for (let i = 0; i < 4; i++) pop(34.95 + i * 0.18, N(69 + i * 3), N(81 + i * 3), 0.24, i % 2 ? 0.3 : -0.3)
  whoosh(37.0, 1.1, true, 0.28)
  thump(38.35, 0.55)

  // 6. Абонемент: галочки с растущим тоном, оплата, «монетка».
  for (let i = 0; i < 3; i++) pop(41.62 + i * 0.9, N(76 + i * 2), N(88 + i * 2), 0.28)
  blip(45.45, 1500, 0.16, 0.04, 'square')
  blip(46.0, N(95), 0.14, 0.18); blip(46.12, N(100), 0.16, 0.6)

  // 7. Телефон: иконки, касание, открытие приложения.
  for (let i = 0; i < 12; i++) tick(48.45 + i * 0.04, 0.05, 2000 + i * 120)
  blip(50.3, 1400, 0.16, 0.04, 'square'); whoosh(50.4, 0.8, true, 0.25)
  for (let i = 0; i < 5; i++) tick(51.15 + i * 0.12, 0.07, 2400)

  // 8. Нарастание и финальный удар на логотипе.
  {
    const f = ctx.createBiquadFilter(); f.type = 'highpass'; f.frequency.setValueAtTime(400, 52.6); f.frequency.exponentialRampToValueAtTime(5000, 54.15)
    const g = ctx.createGain(); f.connect(g); g.connect(sfx)
    g.gain.setValueAtTime(0.0001, 52.6); g.gain.exponentialRampToValueAtTime(0.45, 54.1); g.gain.linearRampToValueAtTime(0.0001, 54.2)
    noise(52.6, 1.65, f)
  }
  kick(54.2, 0.9); thump(54.2, 0.6)
  {
    const g = ctx.createGain(); g.connect(music); env(g, 54.2, 0.5, 0.01, 2.6, 0.0001, 0.2)
    osc('sine', N(26), 54.2, 57.2, g); osc('triangle', N(38), 54.2, 57.2, g)
  }
  chime(54.25, [74, 78, 81, 86], 0.16)
  chime(55.35, [86, 90], 0.08)

  return ctx.startRendering()
}
