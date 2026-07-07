#!/usr/bin/env node
// Capture full-page + header screenshots of the homepage at several widths, for
// eyeballing the layout when the site is done:
//
//   node web/test/screenshots.mjs                    # shots of web/dist/index.html
//   node web/test/screenshots.mjs <url|path> <dir>   # custom target / output dir
//
// Writes web/test/shots/full-<w>.png (whole page) and hdr-<w>.png (header strip).
// Full-page capture uses a real viewport (vh units resolve correctly), so it
// reflects what a user actually sees — unlike a tall-window hack.
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join, resolve } from 'node:path';
import { mkdirSync } from 'node:fs';
import puppeteer from 'puppeteer-core';

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT = pathToFileURL(resolve(HERE, '..', 'dist', 'index.html')).href;
let target = process.argv[2] || DEFAULT;
if (target && !/^https?:|^file:/.test(target)) target = pathToFileURL(resolve(target)).href;
const OUT = process.argv[3] || join(HERE, 'shots');
const CHROME = process.env.CHROME || '/usr/bin/google-chrome';
const WIDTHS = [360, 390, 768, 1024, 1280, 1440];
mkdirSync(OUT, { recursive: true });

const browser = await puppeteer.launch({ executablePath: CHROME, headless: 'new',
  args: ['--no-sandbox', '--disable-gpu', '--hide-scrollbars', '--force-prefers-reduced-motion'] });
for (const w of WIDTHS) {
  const page = await browser.newPage();
  await page.setViewport({ width: w, height: 900, deviceScaleFactor: 1 });
  await page.goto(target, { waitUntil: 'networkidle0' });
  await page.addStyleTag({ content: '.reveal{opacity:1 !important;transform:none !important}' });
  await new Promise(r => setTimeout(r, 250));
  await page.screenshot({ path: join(OUT, `hdr-${w}.png`), clip: { x: 0, y: 0, width: w, height: 110 } });
  const h = await page.evaluate(() => document.documentElement.scrollHeight);
  await page.screenshot({ path: join(OUT, `full-${w}.png`), fullPage: true });
  console.log(`shot w${w}: full ${w}x${h}`);
  await page.close();
}
await browser.close();
console.log('screenshots written to', OUT);
