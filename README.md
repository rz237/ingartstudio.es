# ingartstudio.es — IngArt Studio / Inga Burina

Trilingual (ES / EN / RU) static portfolio for ceramic artist **Inga Burina / IngArt Studio**
(Benicàssim, Castellón, Spain). Hosted on **GitHub Pages** at https://ingartstudio.es/ and
built by **GitHub Actions** on every push to `main`.

This README is the maintainer guide: what the site is, how the build works, and how to make
common changes. It is written for whoever (human or AI agent) picks up the repo next.

---

## 1. What the site is

- **ES-first**: the base markup is Spanish; EN and RU are server-rendered at build time, so
  crawlers and LLMs get fully-translated HTML (no client-side language toggle).
- **Every intent has its own crawlable URL**: the home page plus indexable subpages for
  services, project case studies, ceramic classes, and the artist profile — each with its own
  `<title>`, meta description, canonical, `hreflang` cluster, entity JSON-LD, breadcrumb, and
  per-page Open Graph image.
- **No backend**: contact/lead capture is a WhatsApp deep link and a brief form that composes a
  WhatsApp message. Reviews are baked in at build time.
- **~40 HTML pages** total = home (×3 langs) + 12 subpages (×3 langs). See the sitemap.

---

## 2. Repo layout

```
web/
├── build.sh              ← the whole build (bash + one Python heredoc). Read this first.
├── index.template.html   ← HOME template + the SHARED SHELL (header/footer/styles/scripts/wa-fab)
│                            that build.sh extracts and reuses on every subpage.
├── i18n.json             ← UI-string translations es/en/ru (single source) + meta.* for the home
├── pages.gen.py          ← SOURCE OF TRUTH for subpage CONTENT (trilingual). Run by build.sh.
├── pages.json            ← GENERATED from pages.gen.py — do NOT hand-edit (overwritten on build)
├── contact.config.json   ← WhatsApp / email / telegram for the CTAs and the brief form
├── reviews.config.json   ← curation (featured ids, max, googleUrl) for reviews
├── reviews.json          ← the reviews shown on the home page (import-reviews.mjs can refresh)
├── assets/               ← original source photos (JPEG). build.sh resizes them to WebP.
├── static/               ← passthrough files copied to site root as-is (search-engine
│                            verification: BingSiteAuth.xml, IndexNow key, google*.html …)
├── test/responsive.mjs   ← headless-Chrome layout regression test (overflow/wrap/menu)
├── .github/workflows/deploy.yml  ← CI: build.sh → upload-pages-artifact → deploy-pages → IndexNow
└── dist/                 ← build output (gitignored). Never edit by hand.
```

The private knowledge base (`../inga_kb`, `../BRIEF.md`, `../kb-site`) is **not** in this repo —
it stays local. The repo contains only the public site sources.

---

## 3. How the build works (`build.sh`)

`make build` (or `./web/build.sh`) does, in order:

1. **Images** → resizes every asset in the `MAP=(…)` list to WebP in `dist/img/<TOKEN>.webp`,
   and makes a 1200×630 JPEG `dist/img/og-<TOKEN>.jpg` for social previews.
2. **Regenerates `pages.json`** by running `pages.gen.py` (single source of subpage content).
3. **Renders the HOME** from `index.template.html` into three languages (`/`, `/en/`, `/ru/`).
4. **Extracts the shared shell** (the `<style>`, `<header>`, `.wa-fab`, `<footer>`, `<script>`
   blocks) from the home template with regex, and **reuses it for every subpage** — so there is
   exactly one source of chrome; edit the header once and all pages change.
5. **Renders every subpage** from `pages.json` (one renderer per `kind`), wrapping the shell
   around a per-kind `<main>`, and writing its own `<head>`.
6. Writes `robots.txt`, `sitemap.xml` (home + all subpages, with hreflang), `CNAME`, `.nojekyll`,
   and copies `static/*` to the site root.

**Server-side i18n**: translatable nodes in the template carry `data-i` (text), `data-i-ph`
(placeholder) or `data-i-al` (aria-label); build.sh substitutes the string for each language from
`i18n.json`. Subpage content is already per-language (from `pages.json`) so it needs no `data-i`.

**Tokens** used in the template/shell (all resolved at build; a leftover `%%…%%` fails the build):
`%%SRC_*%%` (image → `/img/*.webp`), `%%LANGSWITCH%%`, `%%HOME%%` (language home path, e.g. `/en/`),
`%%URL_SERVICIOS%%` / `%%URL_PROYECTOS%%` / `%%URL_PROFILE%%` / `%%URL_CLASSES%%` (localized hub /
profile / classes URLs — these let the shared header link to the right localized slug per language),
`%%CONTACT_PRIMARY%%`, `%%CONTACT_LINKS%%`, `%%WA_BASE%%`, `%%REVIEWS%%`, `%%GOOGLE_URL%%`.

---

## 4. URL & language model

- ES lives at the root (`/servicios/…`), EN under `/en/…`, RU under `/ru/…`.
- **Slugs are localized per language** and stored in full in each page's `path` field, e.g.
  `servicios/murales-ceramicos-a-medida` (es) / `en/services/custom-ceramic-murals` (en) /
  `ru/uslugi/keramicheskie-murali-na-zakaz` (ru).
- Each page emits self-`canonical`, a full `hreflang` cluster (es/en/ru + `x-default`→es), and the
  language switcher + breadcrumb link to the correct localized slug of the *same* page.

---

## 5. Editing content

### Change a subpage's text, or add/remove a subpage → edit `pages.gen.py`
`pages.gen.py` is the single source of truth for all subpage content. It is a small Python script
that builds a list of page dicts. Its top docstring documents every field. `build.sh` runs it, so
**never edit `pages.json` directly** (it is regenerated and your edit would be lost).

To **add a page**: append a new `pages.append({...})` block. Pick a `kind`
(`service` / `project` / `profile` / `hub`), give it a unique `id`, a localized `path` (see §4),
`img` (a hero token from build.sh MAP), and the localized `crumb/h1/title/desc/snippet` plus the
kind-specific bodies. To make it reachable, add its `id` to a hub's `children`, and/or to the
nav — hub/profile/classes nav lives via the `%%URL_*%%` tokens (see §3) which are wired in
build.sh's `NAVURL`; a plain new page is reached from its hub card, breadcrumb, `related`, and
the sitemap.

Then `make build` (regenerates `pages.json`, rebuilds `dist/`) and `make pages` to deploy.

### Change UI strings (nav, footer, buttons, home copy) → edit `i18n.json`
Keys are shared across the home and the shared shell. Every key must exist in all three languages
or the build fails. `meta.title` / `meta.description` are the home page's title/description.

### Change the home layout/sections → edit `index.template.html`
This file is both the home page **and** the shared shell. Changing the header/footer/styles here
changes every page. Keep translatable text on `data-i` nodes and add the key to `i18n.json`.

### Add or swap a photo → drop a JPEG in `assets/`, add a token to `build.sh` `MAP`
Add a line `"SRC_NEWTHING|assets/new.jpg|<maxwidth>"` to the `MAP=(…)` array, then reference the
token as `%%SRC_NEWTHING%%` in the template, or as `"img"`/gallery `"img"` (the bare token,
e.g. `SRC_NEWTHING`) in `pages.gen.py`. The build makes the WebP and the OG JPEG automatically.
Contact-sheet trick to choose from many source photos:
`magick montage <folder>/*.jpg -thumbnail 300x300 -label '%f' -tile 4x sheet.jpg` then view it.

### Change contact channel / reviews → `contact.config.json` / `reviews.config.json` + `reviews.json`
`make import-reviews` can refresh `reviews.json` from Google (best with `GOOGLE_MAPS_API_KEY`).

---

## 6. SEO / social features (all automatic per page)

- Localized `<title>` / `<meta description>`, self `canonical`, full `hreflang` cluster.
- **JSON-LD by entity**: home = ArtGallery/LocalBusiness + Person + WebSite + VisualArtwork;
  service = `Service`; project = `VisualArtwork`; profile = `ProfilePage` + `Person`; hub =
  `CollectionPage`; **every** subpage also emits the shared studio node + a `BreadcrumbList`.
- **Per-page Open Graph image**: each page's `og:image` (and `twitter:image`) is a 1200×630 JPEG
  of its own hero (`og-<TOKEN>.jpg`); the home uses the signature triptych `og.jpg`. This is what
  fixes link previews showing the wrong image.
- `robots.txt` (open to all bots incl. AI) + `sitemap.xml` (home + subpages, with hreflang).
- **IndexNow**: CI pings `api.indexnow.org` after deploy (key file in `static/`), so Bing/Yandex
  learn about updates immediately. Google/Bing verification files live in `static/`.

---

## 7. Build, deploy, verify

```sh
make build          # regenerate pages.json + rebuild dist/ locally (sanity)
make pages          # build + commit + push web/ → CI builds and publishes to Pages
make deploy         # alias for make pages
make pages-verify   # curl https://ingartstudio.es/ expects 200
make test           # headless-Chrome responsive assertions (needs Chrome; CHROME=<path>)
```

- **Source vs generated**: committed sources are `build.sh`, `index.template.html`, `i18n.json`,
  `pages.gen.py`, `assets/`, `static/`, the config JSONs. `pages.json` is committed too but is a
  generated snapshot. `dist/` is gitignored.
- **CI** (`.github/workflows/deploy.yml`): on push to `main`, installs ImageMagick+WebP, runs
  `build.sh`, uploads `dist/` as the Pages artifact, deploys, then pings IndexNow.
- **Deploy = git push from `web/`.** `web/` is a git repo whose origin is
  `github.com/rz237/ingartstudio.es` (branch `main`). `make pages` does add/commit/push.
- **Watch a run**: `gh run watch <id> --repo rz237/ingartstudio.es`.

---

## 8. Operational gotchas (read before you get surprised)

- **`pages.json` is generated** — edit `pages.gen.py`, not `pages.json`.
- **Admin boundary**: the pushing account (`serg123e`) has push but **not admin** on
  `rz237/ingartstudio.es`. Pages settings (Source = GitHub Actions, custom domain, Enforce HTTPS)
  can only be set by the owner `rz237` — `PUT /pages` returns 403 for non-admins, incl. CI.
- **DNS is on Cloudflare and must be grey-cloud (DNS-only)** for Pages: apex A →
  185.199.108–111.153, AAAA → 2606:50c0:8000–8003::153, `www` CNAME → `rz237.github.io`.
  Orange-cloud (proxied) breaks Pages domain verification.
- **Telegram/social caching of link previews**: previews are cached per URL. After changing an
  `og:image`, an already-shared URL keeps the old preview until refreshed — send the link to
  **@WebpageBot** on Telegram to bust its cache.
- **OG image must be a JPEG**, not WebP (some scrapers reject WebP) — that is why build.sh makes
  `og-*.jpg` alongside the WebP.
- **Portable ImageMagick**: build.sh uses `magick||convert` (CI has v6 `convert`, dev has v7).
- **The build errors on any leftover `%%TOKEN%%`** — a safety net; if it fails, a token is
  unresolved (usually a new `%%URL_*%%`/image token not wired into build.sh).
- The old staging domain `ingart.d.123automate.it` 301-redirects here (managed via `../Makefile`
  → Ansible in `~/dev/d.123`, not in this repo).

---

## 9. Local prerequisites

**ImageMagick** (`magick` or `convert`) and **Python 3** (stdlib only) for the build. **Node +
Chrome** only for `make test` / `make import-reviews` (`npm install` in `web/` for puppeteer-core).
