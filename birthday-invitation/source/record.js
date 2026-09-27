// Usage: node record.js <animated.html> <out.mp4> [--seconds 8] [--fps 30] [--scale 1] [--crf 20]
// Deterministic frame-by-frame capture: pauses every CSS/Web Animation and seeks it to t for each frame,
// so only CSS animations / Web Animations API are captured (requestAnimationFrame/JS timers are NOT).
// Make every animation duration divide --seconds evenly so the video loops seamlessly.
const path = require('path'), fs = require('fs'), { execFileSync } = require('child_process');
const { chromium } = require('playwright');
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const [html, out] = args.filter((a, i) => !a.startsWith('--') && !(i > 0 && args[i - 1].startsWith('--')));
const secs = +opt('--seconds', '8'), fps = +opt('--fps', '30'), scale = +opt('--scale', '1'), crf = opt('--crf', '20');
const FFMPEG = '/usr/local/lib/python3.11/dist-packages/imageio_ffmpeg/binaries/ffmpeg-linux-x86_64-v7.0.2';
(async () => {
  const dir = fs.mkdtempSync(path.join(path.dirname(path.resolve(out)), '.frames-'));
  const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
  const page = await browser.newPage({ viewport: { width: 1080, height: 1620 }, deviceScaleFactor: scale });
  await page.goto('file://' + path.resolve(html), { waitUntil: 'load' });
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(500);
  const n = await page.evaluate(() => { const a = document.getAnimations(); a.forEach(x => x.pause()); return a.length; });
  console.log(`animations found: ${n}; frames: ${secs * fps}`);
  for (let f = 0; f < secs * fps; f++) {
    const t = (f / fps) * 1000;
    await page.evaluate(t => document.getAnimations().forEach(a => { a.currentTime = t; }), t);
    await page.screenshot({ path: path.join(dir, `f${String(f).padStart(5, '0')}.png`) });
  }
  await browser.close();
  execFileSync(FFMPEG, ['-y', '-loglevel', 'error', '-framerate', String(fps), '-i', path.join(dir, 'f%05d.png'),
    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', crf, '-preset', 'slow', '-movflags', '+faststart', out]);
  fs.rmSync(dir, { recursive: true });
  console.log('saved ' + out + ' ' + (fs.statSync(out).size / 1e6).toFixed(1) + ' MB');
})().catch(e => { console.error(e); process.exit(1); });
