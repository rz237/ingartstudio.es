# ingartstudio.es

Sitio de la ceramista **Inga Burina / IngArt Studio** (Benicàssim, Castellón).
Sitio estático trilingüe (ES / EN / RU) alojado en **GitHub Pages** → https://ingartstudio.es/

El HTML de cada idioma se renderiza en el servidor (build), así que los rastreadores y
los LLM ven el contenido ya en su idioma. URLs indexables: `/` (es), `/en/`, `/ru/`, con
`hreflang`, `canonical`, JSON-LD, `robots.txt` y `sitemap.xml`.

## Cómo funciona

- **`index.template.html`** — plantilla (un solo fragmento; el texto base es español).
  Los nodos traducibles llevan `data-i` / `data-i-ph` / `data-i-al`.
- **`i18n.json`** — única fuente de traducciones (es/en/ru) + `meta.*` por idioma.
- **`assets/`** — fotos originales; el build las redimensiona a WebP.
- **`build.sh`** — genera `dist/`: SSR de los 3 idiomas, `<head>` por idioma
  (title/description/canonical/hreflang/OG/JSON-LD), imágenes WebP en `/img/`,
  `robots.txt`, `sitemap.xml`, `CNAME` y `.nojekyll`.
- **`contact.config.json`** — WhatsApp / email para el CTA y el formulario.
- **`reviews.config.json` + `reviews.json`** — reseñas de Google mostradas en el sitio.

## Build local

Requiere **ImageMagick** (`magick` o `convert`) y **Python 3** (solo stdlib):

```sh
./build.sh        # escribe dist/
```

Para servirlo en local: `cd dist && python3 -m http.server` → http://localhost:8000/

## Despliegue

Automático: cada push a `main` dispara **GitHub Actions**
(`.github/workflows/deploy.yml`), que ejecuta `build.sh` y publica `dist/` en Pages.
El dominio personalizado sale de `dist/CNAME` (derivado de `SITE` en `build.sh`).
