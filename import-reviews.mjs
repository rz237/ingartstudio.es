#!/usr/bin/env node
// Idempotent import of Google Maps reviews into web/reviews.json.
//
//   node web/import-reviews.mjs [--max N] [--headful] [--debug]
//
// Reads web/reviews.config.json (placeUrl / hl). Scrapes reviews with headless
// Chrome, then MERGES into web/reviews.json:
//   - dedupe by Google's data-review-id (stable across runs);
//   - preserve manual flags on existing entries (featured / hidden);
//   - update text/rating/date if Google changed them;
//   - write sorted by id → same Google data yields a byte-identical file.
// So re-running is safe and produces no spurious diff. The site build
// (web/build.sh) renders cards from this file; curate via reviews.config.json
// "featured": [id,...] or per-entry "hidden": true.
//
// Google Maps DOM is obfuscated and changes; extraction uses several selector
// fallbacks and logs what it found. If Google blocks/So consent walls the page,
// the script exits non-zero without touching reviews.json. Official alternative:
// Google Places API `place details` (needs API key; returns up to 5 reviews).
import { readFileSync, writeFileSync, existsSync, mkdtempSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import puppeteer from 'puppeteer-core';

const UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36';

const WEB = dirname(fileURLToPath(import.meta.url));
const CFG = JSON.parse(readFileSync(join(WEB, 'reviews.config.json'), 'utf8'));
const OUT = join(WEB, 'reviews.json');
const CHROME = process.env.CHROME || '/usr/bin/google-chrome';
const args = process.argv.slice(2);
const MAX = Number((args.find(a => a.startsWith('--max=')) || '').split('=')[1]) || Number(args[args.indexOf('--max') + 1]) || 40;
const HEADFUL = args.includes('--headful');
const DEBUG = args.includes('--debug');

const log = (...a) => console.log('[reviews]', ...a);

async function acceptConsent(page) {
  // EU consent interstitial: ACCEPT is preferred (its `continue=` redirect
  // returns us straight to the place URL, reviews intact).
  const clicked = await page.evaluate(() => {
    const accept = /^(aceptar todo|aceptarlo todo|acepto|accept all|i agree|de acuerdo)$/i;
    const reject = /^(rechazar todo|reject all|rechazar)$/i;
    const els = [...document.querySelectorAll('button, [role="button"], input[type="submit"], form [type="submit"]')];
    const label = e => (e.innerText || e.value || e.getAttribute('aria-label') || '').trim();
    const el = els.find(e => accept.test(label(e))) || els.find(e => reject.test(label(e)));
    if (el) { el.click(); return label(el); }
    return null;
  }).catch(() => null);
  if (clicked) {
    log('consent:', clicked);
    await page.waitForNavigation({ waitUntil: 'domcontentloaded', timeout: 20000 }).catch(() => {});
  }
  return !!clicked;
}

async function clickReviewsTab(page) {
  await new Promise(r => setTimeout(r, 1500));
  const clicked = await page.evaluate(() => {
    const short = /^(rese(ñ|n)as|reviews|opiniones)\b/i;               // starts with the word
    const bad = /informaci|aviso|legal|more about|escrib|write|acerca/i; // not the legal/info links
    const label = e => (e.getAttribute('aria-label') || e.innerText || '').trim();
    const ok = e => { const l = label(e); return short.test(l) && l.length < 40 && !bad.test(l); };
    const tabs = [...document.querySelectorAll('[role="tab"], button[role="tab"]')];
    let b = tabs.find(ok) || [...document.querySelectorAll('button, [role="button"]')].find(ok);
    if (b) { b.click(); return label(b); }
    return null;
  }).catch(() => null);
  if (clicked) { log('reviews tab:', clicked); await new Promise(r => setTimeout(r, 2200)); }
  return clicked;
}

async function scrollReviews(page, target) {
  let last = 0, stable = 0;
  for (let i = 0; i < 60 && stable < 4; i++) {
    const n = await page.evaluate(() => {
      const cont = [...document.querySelectorAll('.m6QErb')].find(e => e.querySelector('[data-review-id]'))
        || document.querySelector('div[role="feed"]')
        || [...document.querySelectorAll('.m6QErb.DxyBCb, .m6QErb')].pop();
      if (cont) cont.scrollTo(0, cont.scrollHeight);
      return document.querySelectorAll('[data-review-id]').length;
    });
    if (n >= target) break;
    stable = n === last ? stable + 1 : 0;
    last = n;
    await new Promise(r => setTimeout(r, 700));
  }
  // expand truncated review bodies ("Más" / "More")
  await page.evaluate(() => {
    const rx = /^(más|more|ver más|read more)$/i;
    document.querySelectorAll('button, [role="button"]').forEach(b => {
      if (rx.test((b.innerText || '').trim())) b.click();
    });
  });
  await new Promise(r => setTimeout(r, 400));
}

async function extract(page) {
  return page.evaluate(() => {
    const clean = (t) => {
      if (!t) return '';
      // cut Google's structured visit-metadata / owner response appended after the text
      t = t.split(/\n(?=\s*(se visitó|visited|tiempo de espera|wait time|precio|price|servicio|comida|ambiente|recomendad|reservar|aparcamiento|response from|respuesta del propietario)\b)/i)[0];
      return t.replace(/\s*\bMás\b\s*$/i, '').replace(/\s+/g, ' ').trim();
    };
    const pickText = (root) => {
      // known review-text span first, else the longest plausible text block
      const known = root.querySelector('.wiI7pd, .MyEned, [class*="review-full-text"]');
      if (known && known.innerText.trim()) return clean(known.innerText);
      let best = '';
      root.querySelectorAll('span, div').forEach(n => {
        const t = (n.innerText || '').trim();
        if (t.length > best.length && t.length < 2000 && !/·|estrella|star|hace |ago/i.test(t.slice(0, 12))) best = t;
      });
      return clean(best);
    };
    const parseRating = (root) => {
      const img = root.querySelector('[role="img"][aria-label]');
      if (img) { const m = img.getAttribute('aria-label').match(/([1-5])([.,]\d)?/); if (m) return Number(m[1]); }
      const filled = root.querySelectorAll('[aria-hidden="true"] svg[fill], .hCCjke.google-symbols.NhBTye').length;
      return filled >= 1 && filled <= 5 ? filled : null;
    };
    const out = [];
    document.querySelectorAll('[data-review-id]').forEach(card => {
      const id = card.getAttribute('data-review-id');
      if (!id || out.some(r => r.id === id)) return;
      const author = (card.getAttribute('aria-label')
        || (card.querySelector('.d4r55, [class*="reviewer"]') || {}).innerText || '').trim();
      const date = ((card.querySelector('.rsqaWe, .DU9Pgb') || {}).innerText || '').trim();
      const text = pickText(card);
      const rating = parseRating(card);
      out.push({ id, author, rating, date, text });
    });
    return out;
  });
}

// --- Path A: official Google Places API (New). Reliable, needs an API key.
// Returns up to 5 reviews. Set GOOGLE_MAPS_API_KEY and enable "Places API (New)".
async function fetchViaApi(key) {
  const H = { 'X-Goog-Api-Key': key, 'Content-Type': 'application/json' };
  let placeId = CFG.placeId;
  if (!placeId) {
    const r = await fetch('https://places.googleapis.com/v1/places:searchText', {
      method: 'POST', headers: { ...H, 'X-Goog-FieldMask': 'places.id,places.displayName' },
      body: JSON.stringify({ textQuery: CFG.textQuery, languageCode: CFG.hl || 'es' }),
    });
    if (!r.ok) throw new Error(`searchText ${r.status}: ${await r.text()}`);
    const j = await r.json();
    placeId = j.places?.[0]?.id;
    if (!placeId) throw new Error('Places API: place not found for textQuery ' + CFG.textQuery);
    log('resolved placeId:', placeId, '—', j.places[0].displayName?.text || '');
  }
  const d = await fetch(`https://places.googleapis.com/v1/places/${placeId}?languageCode=${CFG.hl || 'es'}`, {
    headers: { ...H, 'X-Goog-FieldMask': 'reviews,rating,userRatingCount' },
  });
  if (!d.ok) throw new Error(`place details ${d.status}: ${await d.text()}`);
  const j = await d.json();
  log(`Places API: rating ${j.rating} over ${j.userRatingCount} ratings, ${j.reviews?.length || 0} reviews returned`);
  return (j.reviews || []).map(rv => ({
    id: rv.name,                                   // stable review resource name
    author: rv.authorAttribution?.displayName || '',
    rating: rv.rating,
    date: rv.relativePublishTimeDescription || '',
    text: (rv.originalText?.text || rv.text?.text || '').trim(),
  }));
}

// --- Path B: headless-Chrome scrape (no key; works from a normal machine/IP,
// but Google degrades Maps for datacenter/automation IPs).
async function fetchViaScrape() {
  const profile = mkdtempSync(join(tmpdir(), 'ingart-maps-'));  // persist consent across nav
  const browser = await puppeteer.launch({
    executablePath: CHROME, headless: HEADFUL ? false : 'new', userDataDir: profile,
    args: ['--no-sandbox', '--disable-gpu', '--lang=' + (CFG.hl || 'es') + '-ES',
      '--disable-blink-features=AutomationControlled', '--window-size=1360,1700'],
  });
  try {
    const page = await browser.newPage();
    await page.setUserAgent(UA);
    // strip the headless tells Google keys off of
    await page.evaluateOnNewDocument(() => {
      Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
      Object.defineProperty(navigator, 'languages', { get: () => ['es-ES', 'es', 'en'] });
      Object.defineProperty(navigator, 'plugins', { get: () => [1, 2, 3, 4, 5] });
      window.chrome = window.chrome || { runtime: {} };
    });
    await page.setExtraHTTPHeaders({ 'Accept-Language': (CFG.hl || 'es') + '-ES,' + (CFG.hl || 'es') + ';q=0.9,en;q=0.8' });
    await page.setViewport({ width: 1360, height: 1700 });

    await page.goto(CFG.placeUrl, { waitUntil: 'domcontentloaded', timeout: 45000 });
    // consent redirect returns to the place via its `continue=` param — do NOT
    // re-goto (that resets the SPA to the Maps home shell without a place panel)
    await acceptConsent(page);
    // make sure we actually left the consent domain before proceeding
    await page.waitForFunction(() => !location.hostname.includes('consent.'), { timeout: 20000 })
      .catch(() => log('warn: still on consent domain'));
    log('after consent, url:', page.url().slice(0, 80));

    await new Promise(r => setTimeout(r, 2500));  // let the Maps SPA settle

    // the `!1b1` URL opens the reviews list directly — just be patient for it to
    // hydrate; only click the Reseñas tab as a fallback if it doesn't appear
    const hasReviews = () => page.waitForSelector('[data-review-id]', { timeout: 30000 })
      .then(() => true).catch(() => false);
    let ok = await hasReviews();
    for (let attempt = 0; !ok && attempt < 3; attempt++) {
      log('reviews not up yet, clicking tab (try ' + (attempt + 1) + ')');
      await clickReviewsTab(page);
      ok = await page.waitForSelector('[data-review-id]', { timeout: 15000 }).then(() => true).catch(() => false);
    }
    await scrollReviews(page, MAX);
    const scraped = await extract(page);
    if (DEBUG || !scraped.length) writeFileSync(join(WEB, 'reviews.debug.html'), await page.content());
    return scraped;
  } finally {
    await browser.close();
    rmSync(profile, { recursive: true, force: true });
  }
}

async function main() {
  const key = process.env.GOOGLE_MAPS_API_KEY;
  log(`fetching up to ${MAX} reviews via ${key ? 'Places API' : 'headless scrape'}`);
  let scraped = key ? await fetchViaApi(key) : await fetchViaScrape();

  scraped = scraped.filter(r => r.id && (r.text || r.rating));
  log(`got ${scraped.length} reviews`);
  if (!scraped.length) {
    console.error('[reviews] no reviews obtained.');
    if (!key) console.error('[reviews] Google likely blocked this IP. Run from a normal machine, or set '
      + 'GOOGLE_MAPS_API_KEY (Places API New) for a reliable path: GOOGLE_MAPS_API_KEY=... make import-reviews');
    process.exit(2);
  }

  const existing = existsSync(OUT) ? JSON.parse(readFileSync(OUT, 'utf8')) : { place: CFG.googleUrl, reviews: [] };
  const byId = new Map((existing.reviews || []).map(r => [r.id, r]));
  let added = 0, updated = 0;
  for (const r of scraped) {
    const prev = byId.get(r.id);
    if (!prev) { byId.set(r.id, { ...r, source: 'google' }); added++; }
    else {
      const merged = { ...prev, author: r.author || prev.author, rating: r.rating ?? prev.rating,
        date: r.date || prev.date, text: r.text || prev.text };
      if (JSON.stringify(merged) !== JSON.stringify(prev)) updated++;
      byId.set(r.id, merged);
    }
  }
  const reviews = [...byId.values()].sort((a, b) => a.id.localeCompare(b.id));
  const data = { place: CFG.googleUrl, fetchedCount: scraped.length, reviews };
  writeFileSync(OUT, JSON.stringify(data, null, 2) + '\n');
  log(`wrote ${OUT}: ${reviews.length} total (+${added} new, ~${updated} updated). Rebuild: make build`);
}

main().catch(e => { console.error('[reviews] error:', e.message); process.exit(1); });
