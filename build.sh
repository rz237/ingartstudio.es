#!/usr/bin/env bash
# Build the IngArt site as a small ES-first multilingual static site.
#
#   web/index.template.html  — home template + shared shell (base text Spanish)
#   web/i18n.json            — UI translations es/en/ru (single source)
#   web/pages.json           — content of the crawlable subpages (services /
#                              projects / profile / hubs), already per-language
#
# What the build does:
#   * resizes source photos to WebP (dist/img/), referenced by root /img/*.webp;
#   * SSR of three languages by data-i / data-i-ph / data-i-al attributes, so the
#     shipped HTML already carries text in the right language (for crawlers/LLMs);
#   * writes the HOME as crawlable URLs: es → dist/index.html, en → dist/en/,
#     ru → dist/ru/;
#   * writes each SUBPAGE from pages.json as its own crawlable URL under a
#     localized slug (es at root, en under /en/, ru under /ru/), reusing the home
#     shell (header/footer/styles/scripts) so there is a single source of chrome;
#   * every page gets its own <head> (title/description/canonical + hreflang
#     cluster + OG + preload + JSON-LD by entity + BreadcrumbList) and <html lang>;
#   * writes robots.txt (open, links sitemap) and sitemap.xml (all URLs + hreflang).
#
# Images external + loading="lazy" (fast first paint); each page hero is eager+preload.
# Reproducible: edit template / i18n.json / pages.json / assets and run `make build`.
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
  "SRC_FB_GARDEN|assets/firebird-garden.jpg|1300"
  "SRC_FB_BIRD|assets/firebird-bird.jpg|1000"
  "SRC_FB_HEARTH|assets/firebird-hearth.jpg|1000"
  "SRC_FB_MOSAIC|assets/firebird-mosaic.jpg|1000"
  "SRC_BP_BULL|assets/bocapez-bull.jpg|900"
  "SRC_BP_BULLS|assets/bocapez-bulls.jpg|900"
  "SRC_BP_FISH|assets/bocapez-fish.jpg|900"
  "SRC_BP_PLATTER|assets/bocapez-platter.jpg|900"
  "SRC_CLASS_GROUP|assets/class-group.jpg|1300"
  "SRC_CLASS_HANDSON|assets/class-handson.jpg|1000"
  "SRC_CLASS_TEXTURE|assets/class-texture.jpg|1000"
  "SRC_CLASS_WORKS|assets/class-works.jpg|1000"
)

for m in "${MAP[@]}"; do
  tok="${m%%|*}"; rest="${m#*|}"; src="${rest%%|*}"; w="${rest##*|}"
  [ -f "$src" ] || { echo "build: missing asset $src" >&2; exit 1; }
  "$MAGICK" "$src" -auto-orient -resize "${w}x${w}>" -strip -quality 80 -define webp:method=6 "$TMP/$tok.webp"
  # per-token Open Graph preview (1200x630 JPEG — robust for link scrapers that dislike WebP);
  # each page references its own hero so social/Telegram previews are page-specific.
  "$MAGICK" "$src" -auto-orient -resize 1200x630^ -gravity center -extent 1200x630 -strip -quality 82 "$TMP/og-$tok.jpg"
  printf '%s\t%s\n' "$tok" "$src" >> "$TMP/assets.tsv"   # token → source, for sitemap <lastmod>
done

# Default Open Graph preview for the home page (the signature triptych)
"$MAGICK" "assets/feature-triptych.jpg" -auto-orient -resize 1200x630^ -gravity center -extent 1200x630 -strip -quality 82 "$TMP/og.jpg"

# Regenerate pages.json from its single source (pages.gen.py). pages.json is a
# GENERATED artifact — content is authored in pages.gen.py. Fall back to the
# committed pages.json if the generator is absent.
if [ -f pages.gen.py ]; then python3 pages.gen.py; fi

python3 - "$TEMPLATE" "dist" "$TMP" <<'PY'
import html as H, json, pathlib, re, shutil, subprocess, sys, urllib.parse, datetime

template, distdir, tmp = sys.argv[1], sys.argv[2], sys.argv[3]
SITE = "https://ingartstudio.es/"
LANGS = [("es", "/"), ("en", "/en/"), ("ru", "/ru/")]   # order = priority; es is primary
CODES = [c for c, _ in LANGS]

i18n = json.loads(pathlib.Path("i18n.json").read_text(encoding="utf-8"))
frag = pathlib.Path(template).read_text(encoding="utf-8")

# drop HTML section-marker comments from the shipped output (no "-->" in content)
frag = re.sub(r"<!--.*?-->", "", frag, flags=re.S)

# lazy-load every content image except the hero (LCP element stays eager)
frag = re.sub(r'<img (?![^>]*%%SRC_HERO%%)', '<img loading="lazy" decoding="async" ', frag)

# --- reviews: render from reviews.json (real) or placeholders (shared by all languages) ---
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
    # placeholder note carries data-i so SSR translates it to the page language
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
# primary CTA priority: WhatsApp → Telegram (fallback) → email → anchor
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
produced = set()
for wp in sorted(pathlib.Path(tmp).glob("*.webp")):
    tok = wp.stem
    produced.add(tok)
    shutil.copy2(wp, imgdir / f"{tok}.webp")
    frag = frag.replace(f"%%{tok}%%", f"/img/{tok}.webp")
ogp = pathlib.Path(tmp) / "og.jpg"
if ogp.exists():
    shutil.copy2(ogp, imgdir / "og.jpg")

def img_url(tok):
    if tok not in produced:
        sys.exit(f"build: pages.json references unknown image token {tok!r}")
    return f"/img/{tok}.webp"

def og_image(tok):
    return SITE + f"img/og-{tok}.jpg"

# --- server-side i18n: fill data-i (text), data-i-ph (placeholder), data-i-al (aria-label) ---
tmpl_keys = (set(re.findall(r'data-i="([^"]+)"', frag))
             | set(re.findall(r'data-i-ph="([^"]+)"', frag))
             | set(re.findall(r'data-i-al="([^"]+)"', frag)))
for code in CODES:
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

# --- URL helpers ------------------------------------------------------------
def home_url(code):    return SITE if code == "es" else SITE + code + "/"
def home_rel(code):    return "/" if code == "es" else "/" + code + "/"
def sub_abs(path):     return SITE + path + "/"        # path already carries the lang prefix
def sub_rel(path):     return "/" + path + "/"

ARIA = {"es": "Idioma", "en": "Language", "ru": "Язык"}
def langswitch(cur, rels):
    parts = []
    for code in CODES:
        label = code.upper(); path = rels[code]
        if code == cur:
            parts.append(f'<a href="{path}" aria-current="page">{label}</a>')
        else:
            parts.append(f'<a href="{path}" hreflang="{code}">{label}</a>')
    inner = '<span class="sep">/</span>'.join(parts)
    return f'<div class="langs" role="group" aria-label="{ARIA[cur]}">{inner}</div>'

# --- structured data building blocks ---------------------------------------
JOBTITLE = {"es": "Artista ceramista", "en": "Ceramic artist", "ru": "Художница-керамист"}
SAMEAS = [s for s in [
    "https://instagram.com/ingartstudio",
    "https://www.facebook.com/ingartstudio/",
    "https://saatchiart.com/ingart",
    "https://t.me/ingartstudios",
    cfg.get("cidUrl"),
] if s]
PROFILE_PATH = {"es": "sobre-inga-burina", "en": "en/about-inga-burina", "ru": "ru/ob-inge-burinoy"}

def studio_node(code, url):
    return {
        "@type": ["ArtGallery", "LocalBusiness"], "@id": SITE + "#studio",
        "name": "IngArt Studio", "alternateName": "Ingart Art House",
        "description": i18n[code]["meta.description"], "url": url,
        "image": SITE + "img/og.jpg",
        "telephone": ("+" + wa) if wa else None, "email": email or None,
        "priceRange": "€€€",
        "address": {"@type": "PostalAddress", "addressLocality": "Benicàssim",
                    "addressRegion": "Castellón", "addressCountry": "ES"},
        "areaServed": ["Benicàssim", "Castellón", "Comunitat Valenciana"],
        "founder": {"@id": SITE + "#inga"},
        "contactPoint": {"@type": "ContactPoint", "contactType": "sales",
                         "availableLanguage": ["es", "en", "ru"], "email": email or None},
        "sameAs": SAMEAS,
    }
def person_node(code):
    return {
        "@type": "Person", "@id": SITE + "#inga",
        "name": "Inga Burina", "alternateName": "Инга Бурина", "jobTitle": JOBTITLE[code],
        "birthPlace": "Moscow", "url": SITE + PROFILE_PATH[code] + "/",
        "worksFor": {"@id": SITE + "#studio"},
    }
def website_node(code):
    return {"@type": "WebSite", "@id": SITE + "#website", "url": SITE,
            "name": "IngArt Studio", "inLanguage": code, "publisher": {"@id": SITE + "#studio"}}

def clean(o):
    if isinstance(o, dict):  return {k: clean(v) for k, v in o.items() if v is not None}
    if isinstance(o, list):  return [clean(x) for x in o]
    return o
def jsonld_tag(graph):
    doc = clean({"@context": "https://schema.org", "@graph": graph})
    return '<script type="application/ld+json">' + json.dumps(doc, ensure_ascii=False) + '</script>'

def home_jsonld(code):
    return jsonld_tag([
        studio_node(code, home_url(code)), person_node(code), website_node(code),
        {"@type": "VisualArtwork", "name": i18n[code]["meta.artwork"],
         "artform": "Ceramic mural", "artMedium": "Hand-painted ceramic tile",
         "material": "Ceramic tile", "creator": {"@id": SITE + "#inga"},
         "dateCreated": "2020", "image": SITE + "img/SRC_FEATURE.webp",
         "locationCreated": {"@type": "Place", "name": "Benicàssim, Castellón, España"},
         "description": i18n[code]["feature.d"]},
    ])

# --- <head> (shared by home and subpages) ----------------------------------
FAVICON = ("data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'>"
           "<rect width='32' height='32' rx='7' fill='%23234a7c'/><text x='16' y='23' "
           "font-family='Georgia,serif' font-size='20' fill='%23f2ede1' "
           "text-anchor='middle'>I</text></svg>")

def head_common(code, title, desc, canon, alt_pairs, preload_path, jsonld_str, og_url):
    alts = "".join(f'<link rel="alternate" hreflang="{c}" href="{u}">\n' for c, u in alt_pairs)
    alts += f'<link rel="alternate" hreflang="x-default" href="{alt_pairs[0][1]}">\n'
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
        '<meta property="og:site_name" content="IngArt Studio">\n'
        f'<meta property="og:locale" content="{code}">\n'
        f'<meta property="og:title" content="{H.escape(title, quote=True)}">\n'
        f'<meta property="og:description" content="{H.escape(desc, quote=True)}">\n'
        f'<meta property="og:url" content="{canon}">\n'
        f'<meta property="og:image" content="{og_url}">\n'
        '<meta property="og:image:width" content="1200">\n'
        '<meta property="og:image:height" content="630">\n'
        '<meta name="twitter:card" content="summary_large_image">\n'
        f'<meta name="twitter:image" content="{og_url}">\n'
        f'<link rel="preload" as="image" href="{preload_path}" fetchpriority="high">\n'
        + jsonld_str + '\n'
    )

# --- content manifest for the crawlable subpages (loaded early: the shared header
#     links to hubs/profile via %%URL_*%% tokens that resolve to localized slugs) ---
pages = json.loads(pathlib.Path("pages.json").read_text(encoding="utf-8"))["pages"]
byid = {p["id"]: p for p in pages}
NAVURL = {pid: {c: sub_rel(byid[pid]["path"][c]) for c in CODES}
          for pid in ("servicios", "proyectos", "sobre-inga", "clases",
                      "vajilla-restaurantes", "vajilla-boca-pez")}
# per-page OG preview JPEGs (scraper-friendly) → dist/img/og-<hero>.jpg for each page hero
for tok in sorted({p["img"] for p in pages if p.get("img")}):
    ogsrc = pathlib.Path(tmp) / f"og-{tok}.jpg"
    if ogsrc.exists():
        shutil.copy2(ogsrc, imgdir / f"og-{tok}.jpg")
def fill_navurls(s, code):
    return (s.replace("%%URL_SERVICIOS%%", NAVURL["servicios"][code])
             .replace("%%URL_PROYECTOS%%", NAVURL["proyectos"][code])
             .replace("%%URL_PROFILE%%",   NAVURL["sobre-inga"][code])
             .replace("%%URL_CLASSES%%",   NAVURL["clases"][code])
             .replace("%%URL_VAJILLA%%",   NAVURL["vajilla-restaurantes"][code])
             .replace("%%URL_BOCAPEZ%%",   NAVURL["vajilla-boca-pez"][code]))

# ==========================================================================
#  HOME — three languages, from the full template (chrome + main)
# ==========================================================================
written = []
for code in CODES:
    page = ssr(frag, i18n[code])
    page = page.replace("%%LANGSWITCH%%", langswitch(code, {c: home_rel(c) for c in CODES}))
    page = page.replace("%%HOME%%", home_rel(code))
    page = fill_navurls(page, code)
    left = re.findall(r"%%[A-Z_]+%%", page)
    if left:
        sys.exit(f"build: unreplaced tokens (home {code}): {sorted(set(left))}")
    home_alts = [(c, home_url(c)) for c in CODES]
    doc = head_common(code, i18n[code]["meta.title"], i18n[code]["meta.description"],
                      home_url(code), home_alts, "/img/SRC_HERO.webp", home_jsonld(code),
                      SITE + "img/og.jpg") + page
    doc = doc.replace("</style>", "</style>\n</head>\n<body>", 1)
    doc = doc.rstrip() + "\n</body>\n</html>\n"
    dest = out_root / "index.html" if code == "es" else out_root / code / "index.html"
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(doc, encoding="utf-8")
    written.append((code, dest, len(doc.encode())))

# ==========================================================================
#  SUBPAGES — reuse the home shell (header / footer / wa-fab / scripts / style)
# ==========================================================================
def grab(pat):
    m = re.search(pat, frag, re.S)
    if not m: sys.exit(f"build: could not extract shell part /{pat}/")
    return m.group(0)
STYLE  = grab(r"<style>.*?</style>")
HEADER = grab(r'<header class="site-header">.*?</header>')
WAFAB  = grab(r'<a class="wa-fab".*?</a>')
FOOTER = grab(r'<footer class="site-footer">.*?</footer>')
SCRIPT = grab(r"<script>.*?</script>")

# localized shell labels (kept here so pages.json stays content-only)
KIND_EYE = {
    "service": {"es": "Servicio", "en": "Service", "ru": "Услуга"},
    "project": {"es": "Proyecto", "en": "Project", "ru": "Проект"},
    "profile": {"es": "Autora", "en": "About the artist", "ru": "Об авторе"},
    "hub":     {"es": "IngArt Studio · Benicàssim", "en": "IngArt Studio · Benicàssim", "ru": "IngArt Studio · Benicàssim"},
}
CRUMB_HOME  = {"es": "Inicio", "en": "Home", "ru": "Главная"}
CTA_TITLE   = {"es": "¿Hablamos de tu proyecto?", "en": "Shall we talk about your project?", "ru": "Обсудим ваш проект?"}
CTA_SUB     = {"es": "Cuéntame la idea, el espacio y los plazos. Te respondo personalmente por WhatsApp — en español, English o по-русски.",
               "en": "Tell me the idea, the space and the timeline. I reply personally on WhatsApp — in Spanish, English or Russian.",
               "ru": "Расскажите идею, пространство и сроки. Отвечу лично в WhatsApp — на испанском, английском или русском."}
CTA_LABEL   = {"es": "Escríbeme por WhatsApp", "en": "Message me on WhatsApp", "ru": "Написать в WhatsApp"}
SEC_LABEL   = {"es": "Ver proyectos", "en": "See projects", "ru": "Смотреть проекты"}
WA_PRE      = {"es": "Hola, me interesa: ", "en": "Hi, I'm interested in: ", "ru": "Здравствуйте, интересует: "}
INCLUDES_H  = {"es": "Qué incluye", "en": "What's included", "ru": "Что входит"}
FAQ_H       = {"es": "Preguntas frecuentes", "en": "FAQ", "ru": "Частые вопросы"}
GALLERY_H   = {"es": "Galería", "en": "Gallery", "ru": "Галерея"}
DETAILS_H   = {"es": "Ficha del proyecto", "en": "Project details", "ru": "О проекте"}
RELATED_H   = {"es": "También te puede interesar", "en": "You may also like", "ru": "Смотрите также"}

def esc(s): return H.escape(str(s))

def cta_href(page, code):
    if wa_base:
        return H.escape(wa_base + "?text=" + urllib.parse.quote(WA_PRE[code] + page["h1"][code]))
    return H.escape(primary)

def crumbs_html(page, code):
    items = [(CRUMB_HOME[code], home_rel(code))]
    par = page.get("parent")
    if par and par in byid:
        items.append((byid[par]["crumb"][code], sub_rel(byid[par]["path"][code])))
    out = ['<nav class="crumbs" aria-label="breadcrumb">']
    for i, (label, url) in enumerate(items):
        out.append(f'<a href="{url}">{esc(label)}</a><span class="sep">›</span>')
    out.append(f'<span class="cur">{esc(page["crumb"][code])}</span></nav>')
    return "".join(out)

def breadcrumb_node(page, code):
    items = [{"name": CRUMB_HOME[code], "item": home_url(code)}]
    par = page.get("parent")
    if par and par in byid:
        items.append({"name": byid[par]["crumb"][code], "item": sub_abs(byid[par]["path"][code])})
    items.append({"name": page["crumb"][code], "item": sub_abs(page["path"][code])})
    return {"@type": "BreadcrumbList",
            "itemListElement": [{"@type": "ListItem", "position": i+1, "name": it["name"], "item": it["item"]}
                                for i, it in enumerate(items)]}

def gallery_html(page, code):
    g = page.get("gallery") or []
    if not g: return ""
    figs = "".join(
        f'      <figure><img loading="lazy" decoding="async" src="{img_url(it["img"])}" alt="{esc(it["alt"][code])}"></figure>\n'
        for it in g)
    return (f'  <section class="subsection"><div class="wrap">\n'
            f'    <h2 class="reveal">{esc(page.get("gallery_title",{}).get(code) or GALLERY_H[code])}</h2>\n'
            f'    <div class="subgrid reveal">\n{figs}    </div>\n  </div></section>\n')

def related_html(page, code):
    rel = page.get("related") or []
    rel = [byid[r] for r in rel if r in byid]
    if not rel: return ""
    links = "".join(
        f'<a class="has-arrow" href="{sub_rel(r["path"][code])}">{esc(r["crumb"][code])}</a>'
        for r in rel)
    return (f'    <p class="eyebrow" style="margin-top:34px">{esc(RELATED_H[code])}</p>\n'
            f'    <div class="related-links">{links}</div>\n')

def cta_section(page, code):
    # reuse the home ".contact .wrap" centering (flex column, align-items:center);
    # both classes must be on separate nested elements for the selector to match.
    return (f'  <section class="subsection contact"><div class="wrap reveal">\n'
            f'    <h2>{esc(CTA_TITLE[code])}</h2>\n'
            f'    <p class="muted">{esc(CTA_SUB[code])}</p>\n'
            f'    <a class="btn btn-primary has-arrow" href="{cta_href(page, code)}" target="_blank" rel="noopener">'
            f'{esc(page.get("cta",{}).get(code) or CTA_LABEL[code])}</a>\n'
            f'{related_html(page, code)}'
            f'  </div></section>\n')

def hero_block(page, code, with_media=True, meta_line=None):
    eye = page.get("eyebrow", {}).get(code) or KIND_EYE[page["kind"]][code]
    ml = f'    <p class="meta-line">{esc(meta_line)}</p>\n' if meta_line else ""
    media = ""
    if with_media and page.get("img"):
        media = (f'  <div class="wrap"><div class="sub-hero-img reveal">'
                 f'<img fetchpriority="high" src="{img_url(page["img"])}" alt="{esc(page.get("img_alt",{}).get(code) or page["h1"][code])}">'
                 f'</div></div>\n')
    return (
        f'  <div class="wrap">\n    {crumbs_html(page, code)}\n'
        f'    <header class="subhero reveal">\n'
        f'      <p class="eyebrow">{esc(eye)}</p>\n'
        f'      <h1>{esc(page["h1"][code])}</h1>\n'
        f'{ml}'
        f'      <p class="lead">{esc(page["snippet"][code])}</p>\n'
        f'      <div class="subcta">\n'
        f'        <a class="btn btn-primary has-arrow" href="{cta_href(page, code)}" target="_blank" rel="noopener">'
        f'{esc(page.get("cta",{}).get(code) or CTA_LABEL[code])}</a>\n'
        f'        <a class="btn btn-ghost" href="{NAVURL["proyectos"][code]}">{esc(SEC_LABEL[code])}</a>\n'
        f'      </div>\n    </header>\n  </div>\n'
        f'{media}'
    )

def prose_section(title, paras, code):
    ps = "".join(f'      <p>{esc(p)}</p>\n' for p in paras)
    head = f'    <h2 class="reveal">{esc(title)}</h2>\n' if title else ""
    return (f'  <section class="subsection"><div class="wrap">\n{head}'
            f'    <div class="prose reveal">\n{ps}    </div>\n  </div></section>\n')

def render_service(page, code):
    out = [hero_block(page, code)]
    if page.get("intro"):
        out.append(prose_section(None, page["intro"][code], code))
    if page.get("includes"):
        lis = "".join(f'      <li>{esc(x)}</li>\n' for x in page["includes"][code])
        out.append(f'  <section class="subsection"><div class="wrap">\n'
                   f'    <h2 class="reveal">{esc(page.get("includes_title",{}).get(code) or INCLUDES_H[code])}</h2>\n'
                   f'    <ul class="checklist reveal">\n{lis}    </ul>\n')
        if page.get("price"):
            out.append(f'    <p class="muted reveal" style="margin-top:26px">{esc(page["price"][code])}</p>\n')
        out.append('  </div></section>\n')
    out.append(gallery_html(page, code))
    if page.get("faq"):
        items = "".join(
            f'      <div class="faq-item"><h3>{esc(q)}</h3><p>{esc(a)}</p></div>\n'
            for q, a in page["faq"][code])
        out.append(f'  <section class="subsection"><div class="wrap">\n'
                   f'    <h2 class="reveal">{esc(page.get("faq_title",{}).get(code) or FAQ_H[code])}</h2>\n'
                   f'    <div class="faq-list reveal">\n{items}    </div>\n  </div></section>\n')
    out.append(cta_section(page, code))
    return "".join(out)

def render_project(page, code):
    out = [hero_block(page, code, meta_line=page.get("meta_line",{}).get(code))]
    if page.get("story"):
        out.append(prose_section(page.get("story_title",{}).get(code), page["story"][code], code))
    out.append(gallery_html(page, code))
    if page.get("details"):
        rows = "".join(f'      <tr><td>{esc(k)}</td><td>{esc(v)}</td></tr>\n' for k, v in page["details"][code])
        out.append(f'  <section class="subsection"><div class="wrap">\n'
                   f'    <h2 class="reveal">{esc(page.get("details_title",{}).get(code) or DETAILS_H[code])}</h2>\n'
                   f'    <table class="details reveal">\n{rows}    </table>\n  </div></section>\n')
    out.append(cta_section(page, code))
    return "".join(out)

def render_profile(page, code):
    out = [hero_block(page, code)]
    if page.get("paras"):
        out.append(prose_section(None, page["paras"][code], code))
    out.append(gallery_html(page, code))
    out.append(cta_section(page, code))
    return "".join(out)

def render_hub(page, code):
    out = [hero_block(page, code, with_media=False)]
    if page.get("intro"):
        out.append(prose_section(None, page["intro"][code], code))
    cards = []
    for cid in page.get("children", []):
        ch = byid[cid]
        cards.append(
            f'    <a class="hubcard reveal" href="{sub_rel(ch["path"][code])}">\n'
            f'      <div class="ph"><img loading="lazy" decoding="async" src="{img_url(ch["img"])}" '
            f'alt="{esc(ch.get("img_alt",{}).get(code) or ch["h1"][code])}"></div>\n'
            f'      <div class="hc-body"><h3>{esc(ch["h1"][code])}</h3>'
            f'<p>{esc(ch.get("card",{}).get(code) or ch["snippet"][code])}</p>'
            f'<span class="plink has-arrow">{esc(ch["crumb"][code])}</span></div>\n    </a>\n')
    out.append('  <section class="subsection"><div class="wrap">\n    <div class="hubcards reveal">\n'
               + "".join(cards) + '    </div>\n  </div></section>\n')
    out.append(cta_section(page, code))
    return "".join(out)

RENDER = {"service": render_service, "project": render_project,
          "profile": render_profile, "hub": render_hub}

def page_entity(page, code, canon):
    k = page["kind"]
    if k == "service":
        return {"@type": "Service", "name": page["h1"][code],
                "serviceType": page.get("serviceType"), "provider": {"@id": SITE + "#studio"},
                "areaServed": ["Benicàssim", "Castellón", "Comunitat Valenciana"],
                "url": canon, "description": page["desc"][code], "inLanguage": code}
    if k == "project":
        aw = page.get("artwork", {})
        first = (page.get("gallery") or [{"img": page.get("img")}])[0]["img"]
        return {"@type": "VisualArtwork", "name": aw.get("name") or page["h1"][code],
                "artform": aw.get("artform"), "artMedium": aw.get("artMedium"),
                "material": aw.get("material"), "creator": {"@id": SITE + "#inga"},
                "dateCreated": aw.get("dateCreated"),
                "locationCreated": ({"@type": "Place", "name": aw["location"]} if aw.get("location") else None),
                "image": SITE + img_url(first).lstrip("/"), "url": canon,
                "description": page["desc"][code]}
    if k == "profile":
        return {"@type": "ProfilePage", "@id": canon, "url": canon,
                "name": page["title"][code], "mainEntity": {"@id": SITE + "#inga"}}
    if k == "hub":
        parts = [{"@id": sub_abs(byid[c]["path"][code])} for c in page.get("children", []) if c in byid]
        return {"@type": "CollectionPage", "name": page["h1"][code], "url": canon,
                "description": page["desc"][code], "inLanguage": code, "hasPart": parts}
    return None

for page in pages:
    for code in CODES:
        path = page["path"][code]
        canon = sub_abs(path)
        main = RENDER[page["kind"]](page, code)
        body = (HEADER + "\n<main>\n" + main + "</main>\n" + WAFAB + "\n" + FOOTER + "\n" + SCRIPT + "\n")
        body = body.replace("%%LANGSWITCH%%", langswitch(code, {c: sub_rel(page["path"][c]) for c in CODES}))
        body = body.replace("%%HOME%%", home_rel(code))
        body = fill_navurls(body, code)
        body = ssr(body, i18n[code])
        left = re.findall(r"%%[A-Z_]+%%", body)
        if left:
            sys.exit(f"build: unreplaced tokens ({page['id']} {code}): {sorted(set(left))}")
        graph = [studio_node(code, SITE), page_entity(page, code, canon), breadcrumb_node(page, code)]
        if page["kind"] == "profile":
            graph.append(person_node(code))
        alt_pairs = [(c, sub_abs(page["path"][c])) for c in CODES]
        preload = img_url(page["img"]) if page.get("img") else "/img/SRC_HERO.webp"
        og_url = og_image(page["img"]) if page.get("img") else SITE + "img/og.jpg"
        head = head_common(code, page["title"][code], page["desc"][code], canon,
                           alt_pairs, preload, jsonld_tag(graph), og_url)
        doc = head + STYLE + "\n</head>\n<body>\n" + body
        doc = doc.rstrip() + "\n</body>\n</html>\n"
        dest = out_root / path / "index.html"
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(doc, encoding="utf-8")
        written.append((f"{page['id']}:{code}", dest, len(doc.encode())))

# --- robots.txt (open, incl. AI bots) + sitemap.xml (home + all subpages) ---
(out_root / "robots.txt").write_text(
    "User-agent: *\nAllow: /\n\nSitemap: " + SITE + "sitemap.xml\n", encoding="utf-8")

# <lastmod> = date of the last commit that touched the page's OWN content — its block in
# pages.gen.py plus the images it shows (home: template, i18n, reviews, contact config +
# its images) — never the build date. A lastmod that jumps on every deploy for every URL
# teaches crawlers to ignore it. Uncommitted local edits → today (the live site is built
# by CI after the commit, so it always sees real dates). No git / shallow clone → today.
TODAY = datetime.date.today().isoformat()
ASSET_OF = dict(l.split("\t", 1) for l in (pathlib.Path(tmp) / "assets.tsv").read_text().splitlines() if "\t" in l)

def _git(*args):
    try:
        r = subprocess.run(["git", *args], capture_output=True, text=True, timeout=30)
        return r.stdout if r.returncode == 0 else None
    except Exception:
        return None

def git_lastmod(date_paths=(), block=None, dirty_paths=()):
    """YYYY-MM-DD of the newest commit among date_paths / the -L block; today if dirty; None if unknown."""
    watched = [*dirty_paths, *date_paths]
    if watched and (_git("status", "--porcelain", "--", *watched) or "").strip():
        return TODAY
    dates = []
    if date_paths:
        d = (_git("log", "-1", "--format=%cs", "--", *date_paths) or "").strip()
        if d: dates.append(d)
    if block:
        d = (_git("log", "-1", "-s", "--format=%cs", "-L", block) or "").strip().splitlines()
        if d: dates.append(d[0])
    return max(dates) if dates else None

def assets_of(tokens):
    return sorted({ASSET_OF[t] for t in tokens if t in ASSET_OF})

def page_lastmod(page):
    toks = [page.get("img")] + [g.get("img") for g in page.get("gallery", [])]
    block = f'/"id": "{page["id"]}"/,/^}})/:pages.gen.py'
    return git_lastmod(assets_of(toks), block=block, dirty_paths=["pages.gen.py"]) or TODAY

def home_lastmod():
    srcs = ["index.template.html", "i18n.json", "reviews.json", "reviews.config.json", "contact.config.json"]
    srcs += assets_of(re.findall(r"%%(SRC_[A-Z0-9_]+)%%", frag))
    return git_lastmod([p for p in srcs if pathlib.Path(p).exists()]) or TODAY

def sm_entry(abs_by_code, lastmod):
    alt = "".join(f'    <xhtml:link rel="alternate" hreflang="{c}" href="{abs_by_code[c]}"/>\n' for c in CODES)
    alt += f'    <xhtml:link rel="alternate" hreflang="x-default" href="{abs_by_code["es"]}"/>\n'
    return "".join(
        f'  <url>\n    <loc>{abs_by_code[c]}</loc>\n    <lastmod>{lastmod}</lastmod>\n{alt}  </url>\n'
        for c in CODES)

lastmods = {"home": home_lastmod(), **{p["id"]: page_lastmod(p) for p in pages}}
sitemap_urls = sm_entry({c: home_url(c) for c in CODES}, lastmods["home"])
for page in pages:
    sitemap_urls += sm_entry({c: sub_abs(page["path"][c]) for c in CODES}, lastmods[page["id"]])
(out_root / "sitemap.xml").write_text(
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" '
    'xmlns:xhtml="http://www.w3.org/1999/xhtml">\n' + sitemap_urls + '</urlset>\n', encoding="utf-8")

# GitHub Pages: custom domain (CNAME) + skip Jekyll (.nojekyll). CNAME derives from SITE.
host = urllib.parse.urlparse(SITE).hostname or ""
(out_root / "CNAME").write_text(host + "\n", encoding="utf-8")
(out_root / ".nojekyll").write_text("", encoding="utf-8")

# Passthrough static files → served at site root as-is (search-engine verification
# such as BingSiteAuth.xml / google*.html, IndexNow key). Drop a file into web/static/.
staticdir = pathlib.Path("static")
if staticdir.is_dir():
    for f in sorted(staticdir.iterdir()):
        if f.is_file():
            shutil.copy2(f, out_root / f.name)

n = len(usable) if usable else 0
homes = [w for w in written if ":" not in w[0]]
subs  = [w for w in written if ":" in w[0]]
for code, dest, size in homes:
    print(f"build: home {code} → {dest} ({round(size/1024)} KB)")
print(f"build: {len(subs)} subpages ({len(pages)} × {len(CODES)} langs) written to dist/")
print(f"build: reviews {'%d real' % n if n else 'placeholders'} · robots.txt + "
      f"sitemap.xml ({1+len(pages)} url-clusters) · {len(tmpl_keys)} i18n keys")
print("build: sitemap lastmod · " + " · ".join(f"{d} ×{n}" for d, n in sorted(
      __import__("collections").Counter(lastmods.values()).items(), reverse=True)))
PY
