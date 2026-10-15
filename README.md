# test.pokoin.com

Review boards for Pokoin pipelines: leftover-scan cleanup, Espurr artwork clusters, OCR, artist matching, Pokémon-only hover masks, Jumbo leftovers, and Poko picture and voice tests.

This site is its own app and its own Vercel project. pokoin.com (the marketplace) is a different repo. The boards do not include search, cart, accounts, or Firebase.

## Run

```bash
npm ci
npm test
npm run dev
```

`npm run dev` serves the app at http://localhost:5175. `/` redirects to `/tests`. `/card-images/*` is proxied to `https://test-media.pokoin.com` (Cloudflare R2) so OCR scans and mask previews load. `npm run build` writes `dist/`. `npm run preview` serves that build.

## Boards

| Path | What it is |
| --- | --- |
| `/tests` | Index of every board |
| `/sanitize` | Leftover JPEG deskew, before / after |
| `/espurr` | Same painting across JP / EN / CN |
| `/ocr` | Expansion print language read off the leftover |
| `/ocr/artists` | OCR illustrator credit matched to pokemontcg.io |
| `/artwork` | Pokémon-only album hover masks |
| `/jumbos` | Jumbo Oversized leftover grid |
| `/poko` | Poko picture and voice tests, grouped by month |
| `/poko/archive` | newPoko Gemini Fenrir clip archive |

Each path also works with a trailing slash. The bottom dock is `public/review/tests.json`.

## Media (R2)

test.pokoin.com does **not** use pokoin.com’s CDN or Kubernetes. Board media lives in Cloudflare R2:

| Item | Value |
| --- | --- |
| Bucket | `pokoin-test-media` |
| Public URL | `https://test-media.pokoin.com` (`MEDIA_BASE` in `src/lib/media.js`) |
| Key layout | Same as the old `cdn.pokoin.com` root (`/card-images/foo.jpg` → object key `foo.jpg`) |

`media-manifest.json` lists every object key the app can request, with sizes and SHA-256 from nezopt/pi-home sources. Regenerate after adding board media:

```bash
node scripts/media-manifest.mjs
```

Upload from nezopt (uses `~/.bun/bin/wrangler`; run in a shell that has `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`, e.g. `bash -ic`):

```bash
./scripts/upload-media-r2.sh
```

Do not commit `.media-upload.done`.

Some jumbo card image keys in review JSON are **aliases**: the old CDN served them from another object (`x-pokoin-cdn-object-key`). `media-aliases.json` maps requested key → source object key; `scripts/media-manifest.mjs` records `aliasOf` and hashes the source, and `scripts/upload-media-r2.sh` uploads the source bytes under the requested key. Seven `figure-masks-whole/v*.webp` keys have no object on the old CDN either; the artwork board falls back when they are absent.

### Add a Poko test

Picture and voice tests live in `src/pages/poko-tests.js`. Add one object to `POKO_TESTS` with a `date` (`YYYY-MM-DD`). Newest date is listed first inside its month. Upload the file to R2 under `poko-video/…` (same path as on the old CDN), point `src` (and `poster` / `voiceover` for video) at `` `${MEDIA_BASE}/poko-video/…` ``. Do not commit the media into this repo. Re-run `node scripts/media-manifest.mjs` and commit the manifest if keys changed.

```js
video({
  id: 'ep9-example',
  date: '2026-10-16',
  title: 'Part 9 · short description',
  src: `${MEDIA_BASE}/poko-video/ep9/example-20261016/episode-720p.mp4`,
  poster: `${MEDIA_BASE}/poko-video/ep9/example-20261016/poster.jpg`,
}),
```

An audio comparison uses `audio({ id, date, title, clips: [{ id, title, src }] })` with the same host. `npm test` checks that every entry has a date and that every file URL is on `MEDIA_BASE`.

A new *board* (a new path, not another Poko tile) is a page under `src/pages/`, a route in `src/router.js`, a matching rewrite in `vercel.json`, and one entry in `public/review/tests.json` so the dock and `/tests` list it.

## Data

Snapshots the boards render from disk are in `public/review/` and are served at `/review/…` (the same paths as today). Card scans and figure masks are on R2 and are requested as `/card-images/…` (rewritten to `test-media.pokoin.com`).

## Deploy

Create a Vercel project for this repo, separate from pokoin.com. The build is `npm run build` and the output is `dist/` (`vercel.json` sets both). Attach the domain `test.pokoin.com` to this project only.

`/` on that host redirects to `/tests`. `/card-images/*` is rewritten to `https://test-media.pokoin.com/*` so the OCR and artwork boards can load scans. Artist-table links under `/marketplace/…` redirect to `https://pokoin.com/marketplace/…`. There is no `/api` proxy: none of these boards call the marketplace API.
