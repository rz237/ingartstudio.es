#!/usr/bin/env bash
# Build the IngArt homepage as a small ES-first multilingual static site.
#
#   web/index.template.html  — единый фрагмент-шаблон (базовый текст испанский)
#   web/i18n.json            — переводы es/en/ru (единый источник)
#
# Что делает сборка:
#   * ресайзит исходные фото в WebP (dist/img/), ссылки корневые /img/*.webp;
#   * SSR трёх языков по атрибутам data-i / data-i-ph / data-i-al, чтобы в
#     отгруженном HTML контент был уже на нужном языке (важно для краулеров/LLM);
#   * пишет crawlable-URL: es → dist/index.html, en → dist/en/, ru → dist/ru/,
#     каждый со своим <head> (title/description/canonical + кластер hreflang +
#     OG + preload + JSON-LD) и корректным <html lang>;
#   * пишет robots.txt (открыт, ссылка на sitemap) и sitemap.xml (3 URL + hreflang).
#
# Изображения внешние + loading="lazy" (быстрый first paint); hero — eager+preload.
# Воспроизводимо: правь шаблон / i18n.json / assets и запускай `make build`.
set -euo pipefail
cd "$(dirname "$0")"

TEMPLATE="index.template.html"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ImageMagick 7 ships a unified `magick`; CI runners / older distros only have
# the v6 `convert`. Both accept our `<in> <opts> <out>` argument order.
MAGICK="$(command -v magick || command -v convert || true)"
[ -n "$MAGICK" ] || { echo "build: need ImageMagick (magick or convert) on PATH" >&2; exit 1; }

# token | source asset | max width (px)
MAP=(
  "SRC_HERO|assets/hero-panel-home.jpg|1300"
  "SRC_FEATURE|assets/feature-triptych.jpg|2200"
  "SRC_PROCESS|assets/process-atwork.jpg|1300"
  "SRC_PROCESS2|assets/process-painting.jpg|1300"
  "SRC_WARE_PIGS|assets/ware-pigs.jpg|720"
  "SRC_WARE_FISH|assets/ware-fish-plates.jpg|720"
  "SRC_WARE_ROOSTER|assets/ware-rooster.jpg|720"
  "SRC_WARE_BULL|assets/ware-bull-inuse.jpg|720"
  "SRC_WARE_MOON|assets/ware-moon-plate.jpg|720"
  "SRC_WARE_TURQ|assets/ware-fish-turquoise.jpg|720"
  "SRC_PANEL|assets/panel-succulents.jpg|900"
  "SRC_WARE|assets/tableware-mermaid.jpg|900"
  "SRC_DECOR|assets/decor-mosaic-bar.jpg|900"
  "SRC_CASE1|assets/case-panel-agave.jpg|1150"
  "SRC_CASE2|assets/case-habanero.jpg|1150"
  "SRC_CASE3|assets/case-bocapez.jpg|1150"
  "SRC_PORTRAIT|assets/portrait-studio.jpg|900"
  "SRC_GORY_ROOM|assets/gory-room.jpg|1000"
  "SRC_GORY_ARTIST|assets/gory-artist.jpg|1000"
  "SRC_GORY_SUCC|assets/gory-succulents.jpg|1000"
  "SRC_GORY_BIRD|assets/gory-hoopoe.jpg|1000"
)

for m in "${MAP[@]}"; do
  tok="${m%%|*}"; rest="${m#*|}"; src="${rest%%|*}"; w="${rest##*|}"
  [ -f "$src" ] || { echo "build: missing asset $src" >&2; exit 1; }
  "$MAGICK" "$src" -auto-orient -resize "${w}x${w}>" -strip -quality 80 -define webp:method=6 "$TMP/$tok.webp"
done

# Open Graph preview (1200x630 JPEG — robust for link scrapers that dislike WebP)
"$MAGICK" "assets/feature-triptych.jpg" -auto-orient -resize 1200x630^ -gravity center -extent 1200x630 -strip -quality 82 "$TMP/og.jpg"

python3 - "$TEMPLATE" "dist" "$TMP" <<'PY'
import html as H, json, pathlib, re, shutil, sys, urllib.parse, datetime

template, distdir, tmp = sys.argv[1], sys.argv[2], sys.argv[3]
SITE = "https://ingartstudio.es/"
LANGS = [("es", "/"), ("en", "/en/"), ("ru", "/ru/")]   # порядок = приоритет; es — основной

i18n = json.loads(pathlib.Path("i18n.json").read_text(encoding="utf-8"))
frag = pathlib.Path(template).read_text(encoding="utf-8")

# drop HTML section-marker comments from the shipped output (no "-->" in content)
frag = re.sub(r"<!--.*?-->", "", frag, flags=re.S)

# lazy-load every content image except the hero (LCP element stays eager)
frag = re.sub(r'<img (?![^>]*%%SRC_HERO%%)', '<img loading="lazy" decoding="async" ', frag)

# --- reviews: render from reviews.json (real) or placeholders (общие для всех языков) ---
cfg = {}
cfp = pathlib.Path("reviews.config.json")
if cfp.exists(): cfg = json.loads(cfp.read_text(encoding="utf-8"))
google_url = cfg.get("googleUrl") or "#"
maxn, minr = int(cfg.get("max", 3)), int(cfg.get("minRating", 4))
featured = cfg.get("featured") or []

reviews = []
rjp = pathlib.Path("reviews.json")
if rjp.exists():
    reviews = (json.loads(rjp.read_text(encoding="utf-8")) or {}).get("reviews", [])

def card(text, author, rating):
    r = int(rating or 5); r = max(1, min(5, r))
    stars = "★"*r + "☆"*(5-r)
    cite = "— " + H.escape(author or "Google")
    return (f'        <blockquote class="review reveal">\n'
            f'          <div class="stars" aria-label="{r}/5">{stars}</div>\n'
            f'          <p>{H.escape(text)}</p>\n'
            f'          <cite>{cite}</cite>\n'
            f'        </blockquote>')

usable = [r for r in reviews if r.get("text") and not r.get("hidden")
          and int(r.get("rating") or 5) >= minr]
if usable:
    order = {rid: i for i, rid in enumerate(featured)}
    usable.sort(key=lambda r: (order.get(r["id"], 10**6), -int(r.get("rating") or 5), -len(r.get("text",""))))
    cards = "\n".join(card(r["text"], r.get("author"), r.get("rating")) for r in usable[:maxn])
    note = ""  # real reviews: no placeholder disclaimer
else:
    cards = "\n".join([
        card("Инга создала для нашего дома керамическое панно, которое стало сердцем гостиной. "
             "Каждый гость спрашивает о нём. Работа с автором напрямую — совсем другой уровень.",
             "Marta G., частный дом · Castellón", 5),
        card("Encargamos una colección de vajilla para el restaurante. Piezas únicas, hechas a "
             "mano, que nuestros clientes fotografían constantemente. Profesionalidad total.",
             "Restaurante · Benicàssim", 5),
        card("Un taller lleno de magia y una artista con una imaginación desbordante. El mural "
             "cerámico superó todo lo que imaginábamos. Recomendable al cien por cien.",
             "Ana R., Valencia", 5),
    ])
    # заметка-плейсхолдер выводится с data-i, чтобы SSR перевёл её на язык страницы
    note = ('        <p class="review-note" data-i="reviews.note"></p>')

frag = frag.replace("%%REVIEWS%%", cards).replace("%%REVIEWS_NOTE%%", note)
frag = frag.replace("%%GOOGLE_URL%%", H.escape(google_url))

# --- contact channels: primary CTA + secondary links + wa base for the brief form ---
ccfg = {}
ccp = pathlib.Path("contact.config.json")
if ccp.exists(): ccfg = json.loads(ccp.read_text(encoding="utf-8"))
wa    = (ccfg.get("whatsapp") or "").strip()
email = (ccfg.get("email") or "").strip()
tg    = (ccfg.get("telegram") or "").strip()
wa_base   = ("https://wa.me/" + wa) if wa else ""
wa_url    = (wa_base + "?text=" + urllib.parse.quote(ccfg.get("prefill") or "")) if wa else ""
email_url = ("mailto:" + email) if email else ""
# приоритет primary CTA: WhatsApp → Telegram (запасной) → email → якорь
primary = wa_url or tg or email_url or "#contact"
chips = []
if wa_url:              chips.append(f'<a href="{H.escape(wa_url)}" target="_blank" rel="noopener">WhatsApp</a>')
if email_url:           chips.append(f'<a href="{H.escape(email_url)}">Email</a>')
if tg and not wa_url:   chips.append(f'<a href="{H.escape(tg)}" target="_blank" rel="noopener">Telegram</a>')
links = ('<p class="hero-geo contact-links">' + " · ".join(chips) + "</p>") if chips else ""
frag = (frag.replace("%%CONTACT_PRIMARY%%", H.escape(primary))
            .replace("%%CONTACT_LINKS%%", links)
            .replace("%%WA_BASE%%", H.escape(wa_base)))

# --- images: emit resized WebP to dist/img/, reference by ROOT-absolute /img/ URL ---
out_root = pathlib.Path(distdir)
imgdir = out_root / "img"
if imgdir.exists(): shutil.rmtree(imgdir)
imgdir.mkdir(parents=True, exist_ok=True)
for wp in sorted(pathlib.Path(tmp).glob("*.webp")):
    tok = wp.stem
    shutil.copy2(wp, imgdir / f"{tok}.webp")
    frag = frag.replace(f"%%{tok}%%", f"/img/{tok}.webp")
ogp = pathlib.Path(tmp) / "og.jpg"
if ogp.exists():
    shutil.copy2(ogp, imgdir / "og.jpg")

# --- server-side i18n: fill data-i (text), data-i-ph (placeholder), data-i-al (aria-label) ---
tmpl_keys = (set(re.findall(r'data-i="([^"]+)"', frag))
             | set(re.findall(r'data-i-ph="([^"]+)"', frag))
             | set(re.findall(r'data-i-al="([^"]+)"', frag)))
for code, _ in LANGS:
    missing = tmpl_keys - set(i18n[code])
    if missing:
        sys.exit(f"build: i18n[{code}] missing keys: {sorted(missing)}")

RE_TEXT = re.compile(r'(<(\w+)([^>]*\sdata-i="([^"]+)"[^>]*)>)(.*?)(</\2>)', re.S)
RE_PH   = re.compile(r'(<input[^>]*\sdata-i-ph="([^"]+)"[^>]*\splaceholder=")[^"]*(")')
RE_AL   = re.compile(r'(<[^>]*\sdata-i-al="([^"]+)"[^>]*\saria-label=")[^"]*(")')

def ssr(fragment, strings):
    def rep_text(m):
        s = strings.get(m.group(4))
        return m.group(0) if s is None else m.group(1) + H.escape(s) + m.group(6)
    def rep_attr(m):
        s = strings.get(m.group(2))
        return m.group(0) if s is None else m.group(1) + H.escape(s, quote=True) + m.group(3)
    out = RE_TEXT.sub(rep_text, fragment)
    out = RE_PH.sub(rep_attr, out)
    out = RE_AL.sub(rep_attr, out)
    return out

def page_url(code):
    return SITE if code == "es" else SITE + code + "/"

ARIA = {"es": "Idioma", "en": "Language", "ru": "Язык"}
def langswitch(cur):
    parts = []
    for code, path in LANGS:
        label = code.upper()
        if code == cur:
            parts.append(f'<a href="{path}" aria-current="page">{label}</a>')
        else:
            parts.append(f'<a href="{path}" hreflang="{code}">{label}</a>')
    inner = '<span class="sep">/</span>'.join(parts)
    return f'<div class="langs" role="group" aria-label="{ARIA[cur]}">{inner}</div>'

# --- structured data (JSON-LD): Organization/LocalBusiness/ArtGallery + Person + WebSite + VisualArtwork ---
JOBTITLE = {"es": "Artista ceramista", "en": "Ceramic artist", "ru": "Художница-керамист"}
def jsonld(code):
    desc = i18n[code]["meta.description"]
    same = [s for s in [
        "https://instagram.com/ingartstudio",
        "https://www.facebook.com/ingartstudio/",
        "https://saatchiart.com/ingart",
        "https://t.me/ingartstudios",
        cfg.get("cidUrl"),
    ] if s]
    graph = [
        {
            "@type": ["ArtGallery", "LocalBusiness"],
            "@id": SITE + "#studio",
            "name": "IngArt Studio",
            "alternateName": "Ingart Art House",
            "description": desc,
            "url": page_url(code),
            "image": SITE + "img/og.jpg",
            "telephone": ("+" + wa) if wa else None,
            "email": email or None,
            "priceRange": "€€€",
            "address": {"@type": "PostalAddress", "addressLocality": "Benicàssim",
                        "addressRegion": "Castellón", "addressCountry": "ES"},
            "areaServed": ["Benicàssim", "Castellón", "Comunitat Valenciana"],
            "founder": {"@id": SITE + "#inga"},
            "contactPoint": {"@type": "ContactPoint", "contactType": "sales",
                             "availableLanguage": ["es", "en", "ru"],
                             "email": email or None},
            "sameAs": same,
        },
        {
            "@type": "Person",
            "@id": SITE + "#inga",
            "name": "Inga Burina",
            "alternateName": "Инга Бурина",
            "jobTitle": JOBTITLE[code],
            "birthPlace": "Moscow",
            "url": page_url(code) + "#about",
            "worksFor": {"@id": SITE + "#studio"},
        },
        {
            "@type": "WebSite",
            "@id": SITE + "#website",
            "url": SITE,
            "name": "IngArt Studio",
            "inLanguage": code,
            "publisher": {"@id": SITE + "#studio"},
        },
        {
            "@type": "VisualArtwork",
            "name": i18n[code]["meta.artwork"],
            "artform": "Ceramic mural",
            "artMedium": "Hand-painted ceramic tile",
            "material": "Ceramic tile",
            "creator": {"@id": SITE + "#inga"},
            "dateCreated": "2020",
            "image": SITE + "img/SRC_FEATURE.webp",
            "locationCreated": {"@type": "Place", "name": "Benicàssim, Castellón, España"},
            "description": i18n[code]["feature.d"],
        },
    ]
    # выкидываем None-поля (schema.org не любит null)
    def clean(o):
        if isinstance(o, dict):
            return {k: clean(v) for k, v in o.items() if v is not None}
        if isinstance(o, list):
            return [clean(x) for x in o]
        return o
    doc = clean({"@context": "https://schema.org", "@graph": graph})
    return '<script type="application/ld+json">' + json.dumps(doc, ensure_ascii=False) + '</script>'

FAVICON = ("data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'>"
           "<rect width='32' height='32' rx='7' fill='%23234a7c'/><text x='16' y='23' "
           "font-family='Georgia,serif' font-size='20' fill='%23f2ede1' "
           "text-anchor='middle'>I</text></svg>")

def build_head(code):
    title = i18n[code]["meta.title"]
    desc  = i18n[code]["meta.description"]
    canon = page_url(code)
    alts = "".join(
        f'<link rel="alternate" hreflang="{c}" href="{page_url(c)}">\n' for c, _ in LANGS
    ) + f'<link rel="alternate" hreflang="x-default" href="{SITE}">\n'
    return (
        f'<!doctype html>\n<html lang="{code}">\n<head>\n'
        '<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        f'<title>{H.escape(title)}</title>\n'
        f'<meta name="description" content="{H.escape(desc, quote=True)}">\n'
        f'<link rel="canonical" href="{canon}">\n'
        + alts +
        '<meta name="theme-color" content="#234a7c">\n'
        f'<link rel="icon" href="{FAVICON}">\n'
        '<meta property="og:type" content="website">\n'
        f'<meta property="og:site_name" content="IngArt Studio">\n'
        f'<meta property="og:locale" content="{code}">\n'
        f'<meta property="og:title" content="{H.escape(title, quote=True)}">\n'
        f'<meta property="og:description" content="{H.escape(desc, quote=True)}">\n'
        f'<meta property="og:url" content="{canon}">\n'
        f'<meta property="og:image" content="{SITE}img/og.jpg">\n'
        '<meta name="twitter:card" content="summary_large_image">\n'
        '<link rel="preload" as="image" href="/img/SRC_HERO.webp" fetchpriority="high">\n'
        + jsonld(code) + '\n'
    )

written = []
for code, path in LANGS:
    page = ssr(frag, i18n[code])
    page = page.replace("%%LANGSWITCH%%", langswitch(code))
    left = re.findall(r"%%[A-Z_]+%%", page)
    if left:
        sys.exit(f"build: unreplaced tokens ({code}): {sorted(set(left))}")
    doc = build_head(code) + page
    doc = doc.replace("</style>", "</style>\n</head>\n<body>", 1)
    doc = doc.rstrip() + "\n</body>\n</html>\n"
    dest = out_root / "index.html" if code == "es" else out_root / code / "index.html"
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(doc, encoding="utf-8")
    written.append((code, dest, len(doc.encode())))

# --- robots.txt (открыт для всех, включая AI-ботов) + sitemap.xml ---
(out_root / "robots.txt").write_text(
    "User-agent: *\nAllow: /\n\nSitemap: " + SITE + "sitemap.xml\n", encoding="utf-8")

lastmod = datetime.date.today().isoformat()
alt_links = "".join(
    f'    <xhtml:link rel="alternate" hreflang="{c}" href="{page_url(c)}"/>\n' for c, _ in LANGS
) + f'    <xhtml:link rel="alternate" hreflang="x-default" href="{SITE}"/>\n'
urls = "".join(
    f'  <url>\n    <loc>{page_url(c)}</loc>\n    <lastmod>{lastmod}</lastmod>\n{alt_links}  </url>\n'
    for c, _ in LANGS
)
(out_root / "sitemap.xml").write_text(
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" '
    'xmlns:xhtml="http://www.w3.org/1999/xhtml">\n' + urls + '</urlset>\n', encoding="utf-8")

# GitHub Pages: custom domain (CNAME) + skip Jekyll processing (.nojekyll).
# CNAME derives from SITE so the domain lives in exactly one place.
host = urllib.parse.urlparse(SITE).hostname or ""
(out_root / "CNAME").write_text(host + "\n", encoding="utf-8")
(out_root / ".nojekyll").write_text("", encoding="utf-8")

# Passthrough static files → served at site root as-is (search-engine verification
# such as BingSiteAuth.xml / google*.html, etc.). Drop a file into web/static/.
staticdir = pathlib.Path("static")
if staticdir.is_dir():
    for f in sorted(staticdir.iterdir()):
        if f.is_file():
            shutil.copy2(f, out_root / f.name)

n = len(usable) if usable else 0
for code, dest, size in written:
    print(f"build: {code} → {dest} ({round(size/1024)} KB)")
print(f"build: reviews {'%d real' % n if n else 'placeholders'} · robots.txt + sitemap.xml · "
      f"{len(tmpl_keys)} i18n keys")
PY
