#!/usr/bin/env node
// Responsive assertions for the IngArt homepage. Run when the site is "done"
// (or any time) to catch layout regressions:
//
//   node web/test/responsive.mjs               # tests web/dist/index.html
//   node web/test/responsive.mjs <url|path>    # test a URL or file
//
// Checks, per width: no horizontal overflow (scrollWidth <= viewport), no nav
// link / button wrapping to a second line, correct header mode (hamburger vs
// full nav), and that the mobile menu opens. Exit code 1 if any check fails, 0
// if all pass — so it drops into CI or a pre-deploy gate.
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join, resolve } from 'node:path';
import puppeteer from 'puppeteer-core';

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT = pathToFileURL(resolve(HERE, '..', 'dist', 'index.html')).href;
let target = process.argv[2] || DEFAULT;
if (target && !/^https?:|^file:/.test(target)) target = pathToFileURL(resolve(target)).href;
const CHROME = process.env.CHROME || '/usr/bin/google-chrome';
const WIDTHS = [360, 390, 414, 768, 1024, 1240, 1280, 1366, 1440];

const rows = [];
let failed = 0;
const browser = await puppeteer.launch({ executablePath: CHROME, headless: 'new',
  args: ['--no-sandbox', '--disable-gpu', '--hide-scrollbars', '--force-prefers-reduced-motion'] });

for (const w of WIDTHS) {
  const page = await browser.newPage();
  await page.setViewport({ width: w, height: 900, deviceScaleFactor: 1 });
  await page.goto(target, { waitUntil: 'networkidle0' });
  const m = await page.evaluate(() => {
    const disp = s => { const el = document.querySelector(s); return el ? getComputedStyle(el).display : 'missing'; };
    return {
      sw: document.documentElement.scrollWidth,
      wrap: [...document.querySelectorAll('.nav a, .hdr .btn, .btn')].some(e => e.getClientRects().length > 1),
      navDisplay: disp('.nav'),
      menuDisplay: disp('.menu-btn'),
    };
  });
  // header mode expectation
  let headerOk = true;
  if (w <= 1240) headerOk = m.menuDisplay !== 'none' && m.navDisplay === 'none';
  if (w >= 1280) headerOk = m.menuDisplay === 'none' && m.navDisplay !== 'none';

  // mobile menu opens?
  let menuOpens = true;
  if (w <= 1240) {
    await page.click('.menu-btn').catch(() => {});
    await new Promise(r => setTimeout(r, 400));
    menuOpens = await page.evaluate(() => {
      const mn = document.getElementById('mobileNav');
      return mn && mn.getAttribute('data-open') === 'true' && mn.getBoundingClientRect().height > 40;
    });
  }

  const overflow = m.sw > w;
  const ok = !overflow && !m.wrap && headerOk && menuOpens;
  if (!ok) failed++;
  rows.push({ w, sw: m.sw, overflow, wrap: m.wrap, headerOk, menuOpens, ok });
  await page.close();
}
await browser.close();

const pad = (s, n) => String(s).padEnd(n);
console.log(pad('width', 7) + pad('scrollW', 9) + pad('overflow', 10) + pad('wrap', 6) + pad('header', 8) + pad('menu', 6) + 'result');
for (const r of rows) {
  console.log(pad(r.w, 7) + pad(r.sw, 9) + pad(r.overflow ? 'YES' : '-', 10) + pad(r.wrap ? 'YES' : '-', 6)
    + pad(r.headerOk ? 'ok' : 'BAD', 8) + pad(r.menuOpens ? 'ok' : 'BAD', 6) + (r.ok ? '✓ pass' : '✗ FAIL'));
}
console.log(failed ? `\n${failed}/${rows.length} widths FAILED` : `\nall ${rows.length} widths passed`);
process.exit(failed ? 1 : 0);
