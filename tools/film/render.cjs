// Рендер ролика лендинга: film.html покадрово (renderAt(t)) → WebCodecs H.264 → MP4.
// Запуск: cd tools/film && npm i --workspaces=false && node render.cjs (см. README)
const fs = require('fs'), path = require('path')
const WEB = path.join(__dirname, '../../apps/web')
const { chromium } = require(require.resolve('@playwright/test', { paths: [WEB] }))
const OUT = path.join(WEB, 'public/video')
// Шрифты — те же, что у приложения (@fontsource-variable), подставляются в копию film.html.
const font = (pkg, file) => 'file://' + fs.realpathSync(path.join(WEB, 'node_modules/@fontsource-variable', pkg, 'files', file))
const FILM = path.join(__dirname, '.film.html')
fs.writeFileSync(FILM, fs.readFileSync(path.join(__dirname, 'film.html'), 'utf8')
  .replace('FONT_GOLOS', font('golos-text', 'golos-text-cyrillic-wght-normal.woff2'))
  .replace('FONT_UNB', font('unbounded', 'unbounded-cyrillic-wght-normal.woff2')))
fs.writeFileSync(path.join(__dirname, '.encoder.html'), '<!doctype html><meta charset="utf-8"><script src="node_modules/mp4-muxer/build/mp4-muxer.js"></script>')
const W = 1280, H = 720, FPS = 30, DUR = 60, N = FPS * DUR
;(async () => {
  const b = await chromium.launch({ channel: 'chrome' })
  const film = await b.newPage({ viewport: { width: W, height: H } })
  await film.goto('file://' + FILM)
  await film.evaluate(() => window.filmReady)
  const enc = await b.newPage()
  await enc.goto('file://' + path.join(__dirname, '.encoder.html'))
  await enc.evaluate(({ W, H, FPS }) => {
    window.muxer = new Mp4Muxer.Muxer({ target: new Mp4Muxer.ArrayBufferTarget(), video: { codec: 'avc', width: W, height: H, frameRate: FPS }, fastStart: 'in-memory' })
    window.encErr = null
    window.encoder = new VideoEncoder({ output: (chunk, meta) => muxer.addVideoChunk(chunk, meta), error: (e) => (window.encErr = String(e)) })
    encoder.configure({ codec: 'avc1.640028', width: W, height: H, bitrate: 1_000_000, bitrateMode: 'variable', framerate: FPS, avc: { format: 'avc' } })
  }, { W, H, FPS })
  const t0 = Date.now()
  for (let i = 0; i < N; i++) {
    const t = i / FPS
    await film.evaluate((t) => renderAt(t), t)
    const jpg = await film.screenshot({ type: 'jpeg', quality: 95 })
    if (i === Math.round(9.7 * FPS)) fs.writeFileSync(path.join(OUT, 'logocrm-60s.jpg'), await film.screenshot({ type: 'jpeg', quality: 82 }))
    await enc.evaluate(async ({ b64, i, FPS }) => {
      const blob = await (await fetch('data:image/jpeg;base64,' + b64)).blob()
      const bmp = await createImageBitmap(blob)
      const frame = new VideoFrame(bmp, { timestamp: Math.round((i * 1e6) / FPS), duration: Math.round(1e6 / FPS) })
      encoder.encode(frame, { keyFrame: i % (FPS * 2) === 0 })
      frame.close(); bmp.close()
      while (encoder.encodeQueueSize > 8) await new Promise((r) => setTimeout(r, 5))
      if (window.encErr) throw new Error(window.encErr)
    }, { b64: jpg.toString('base64'), i, FPS })
    if (i % 150 === 0) console.log(`кадр ${i}/${N}, ${((Date.now() - t0) / 1000).toFixed(0)} с`)
  }
  const b64 = await enc.evaluate(async () => {
    await encoder.flush(); muxer.finalize()
    const buf = new Uint8Array(muxer.target.buffer); let s = ''
    for (let i = 0; i < buf.length; i += 0x8000) s += String.fromCharCode.apply(null, buf.subarray(i, i + 0x8000))
    return btoa(s)
  })
  fs.writeFileSync(path.join(OUT, 'logocrm-60s.mp4'), Buffer.from(b64, 'base64'))
  console.log('готово', (fs.statSync(path.join(OUT, 'logocrm-60s.mp4')).size / 1e6).toFixed(2), 'МБ за', ((Date.now() - t0) / 1000).toFixed(0), 'с')
  await b.close()
})().catch((e) => { console.error(e); process.exit(1) })
