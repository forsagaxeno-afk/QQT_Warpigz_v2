// Usage: node render.js <page.html> <out.png> [--scale 1|2] [--crop x,y,w,h] [--quiet]
// Renders a 1080x1620 CSS-px invitation to PNG and prints a QA report (fonts, overflow, visible text).
const path = require('path');
const { chromium } = require('playwright');
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const [html, out] = args.filter((a, i) => !a.startsWith('--') && !(i > 0 && args[i - 1].startsWith('--') && args[i - 1] !== '--quiet'));
const W = 1080, H = 1620, scale = +opt('--scale', '1'), crop = opt('--crop', null), quiet = args.includes('--quiet');
(async () => {
  const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
  const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: scale });
  const errors = [];
  page.on('pageerror', e => errors.push('JS error: ' + e.message));
  page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
  page.on('requestfailed', r => errors.push('request failed: ' + r.url()));
  page.on('request', r => { if (!r.url().startsWith('file:') && !r.url().startsWith('data:')) errors.push('NETWORK REQUEST (not allowed): ' + r.url()); });
  await page.goto('file://' + path.resolve(html), { waitUntil: 'load' });
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(600);
  const report = await page.evaluate(({ W, H }) => {
    const r = { fontsFailed: [], familiesNotLoaded: [], outside: [], clipped: [], text: '' };
    document.fonts.forEach(f => { if (f.status === 'error') r.fontsFailed.push(f.family + ' ' + f.weight); });
    const fams = new Map();
    const all = [...document.querySelectorAll('body *')];
    for (const el of all) {
      const hasText = [...el.childNodes].some(n => n.nodeType === 3 && n.textContent.trim());
      if (!hasText) continue;
      const cs = getComputedStyle(el);
      if (cs.visibility === 'hidden' || cs.display === 'none' || +cs.opacity === 0) continue;
      const fam = cs.fontFamily.split(',')[0].trim().replace(/^["']|["']$/g, '');
      const key = `${cs.fontStyle} ${cs.fontWeight} 20px "${fam}"`;
      if (!fams.has(key)) fams.set(key, document.fonts.check(key, 'Ая'));
      const b = el.getBoundingClientRect();
      if (b.width && (b.left < -1 || b.top < -1 || b.right > W + 1 || b.bottom > H + 1))
        r.outside.push(`<${el.tagName.toLowerCase()} class="${el.className && el.className.baseVal !== undefined ? el.className.baseVal : el.className}"> "${el.textContent.trim().slice(0, 40)}" rect=${[b.left, b.top, b.right, b.bottom].map(Math.round)}`);
      if ((el.scrollWidth > el.clientWidth + 1 || el.scrollHeight > el.clientHeight + 1) && cs.overflow !== 'visible' && el.clientWidth)
        r.clipped.push(`<${el.tagName.toLowerCase()}> "${el.textContent.trim().slice(0, 40)}" scroll=${el.scrollWidth}x${el.scrollHeight} client=${el.clientWidth}x${el.clientHeight}`);
    }
    for (const [k, ok] of fams) if (!ok) r.familiesNotLoaded.push(k);
    r.text = document.body.innerText.replace(/\n{2,}/g, '\n').trim();
    const svgText = [...document.querySelectorAll('svg text')].map(t => t.textContent.trim()).filter(Boolean);
    if (svgText.length) r.text += '\n[svg text] ' + svgText.join(' | ');
    return r;
  }, { W, H });
  const shot = { path: out, animations: 'disabled' };
  if (crop) { const [x, y, w, h] = crop.split(',').map(Number); shot.clip = { x, y, width: w, height: h }; }
  await page.screenshot(shot);
  await browser.close();
  console.log(`saved ${out} (${crop ? crop : W + 'x' + H} css px @${scale}x)`);
  const warn = (t, a) => a.length && console.log(`WARN ${t}:\n  ` + a.join('\n  '));
  warn('page errors', errors); warn('font files failed', report.fontsFailed);
  warn('font families NOT loaded (fallback font in use!)', report.familiesNotLoaded);
  warn('text elements outside canvas', report.outside); warn('text clipped by overflow', report.clipped);
  if (!quiet) console.log('--- visible text ---\n' + report.text);
})().catch(e => { console.error(e); process.exit(1); });
