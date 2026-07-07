# ingartstudio.es

Sitio de la ceramista **Inga Burina / IngArt Studio** (Benicàssim, Castellón).
Sitio estático trilingüe (ES / EN / RU) alojado en **GitHub Pages** → https://ingartstudio.es/

El HTML de cada idioma se renderiza en el servidor (build), así que los rastreadores y
los LLM ven el contenido ya en su idioma. Cada intención tiene su propia URL indexable:
la home (`/`, `/en/`, `/ru/`) y las subpáginas de servicios, proyectos y perfil bajo
slugs localizados — todas con `hreflang`, `canonical`, JSON-LD por entidad
(`Service` / `VisualArtwork` / `ProfilePage` + `BreadcrumbList`), `robots.txt` y `sitemap.xml`.

## Cómo funciona

- **`index.template.html`** — plantilla de la home + shell compartido (header, footer,
  estilos, scripts). El texto base es español; los nodos traducibles llevan
  `data-i` / `data-i-ph` / `data-i-al`. `build.sh` reutiliza el shell para las subpáginas.
- **`i18n.json`** — única fuente de traducciones de UI (es/en/ru) + `meta.*` por idioma.
- **`pages.json`** — contenido (ya por idioma) de las subpáginas indexables: hubs
  (servicios / proyectos), servicios, proyectos-caso y el perfil de la autora. Cada
  página define su `path` localizado, `title`/`desc`, snippet y bloques de contenido.
- **`assets/`** — fotos originales; el build las redimensiona a WebP.
- **`build.sh`** — genera `dist/`: SSR de los 3 idiomas (home + subpáginas), `<head>`
  por página (title/description/canonical/hreflang/OG/JSON-LD/breadcrumb), imágenes WebP
  en `/img/`, `robots.txt`, `sitemap.xml` (home + subpáginas), `CNAME` y `.nojekyll`.
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
