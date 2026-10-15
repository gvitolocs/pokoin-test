# test.pokoin.com

Review boards for Pokoin pipelines: leftover-scan cleanup, Espurr artwork clusters, OCR, artist matching, Pokémon-only hover masks, Jumbo leftovers, and Poko picture and voice tests.

This site is its own app and its own Vercel project. pokoin.com (the marketplace) is a different repo. The boards do not include search, cart, accounts, or Firebase.

## Run

```bash
npm ci
npm test
npm run dev
```

`npm run dev` serves the app at http://localhost:5175. `/` redirects to `/tests`. `/card-images/*` is proxied to `https://cdn.pokoin.com` so OCR scans and mask previews load. `npm run build` writes `dist/`. `npm run preview` serves that build.

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

## Add a Poko test

Picture and voice tests live in `src/pages/poko-tests.js`. Add one object to `POKO_TESTS` with a `date` (`YYYY-MM-DD`). Newest date is listed first inside its month. Put the file on the CDN under `https://cdn.pokoin.com/poko-video/…` and point `src` (and `poster`, for a video) at that URL. Do not commit the media into this repo.

```js
video({
  id: 'ep9-example',
  date: '2026-10-16',
  title: 'Part 9 · short description',
  src: 'https://cdn.pokoin.com/poko-video/ep9/example-20261016/episode-720p.mp4',
  poster: 'https://cdn.pokoin.com/poko-video/ep9/example-20261016/poster.jpg',
}),
```

An audio comparison uses `audio({ id, date, title, clips: [{ id, title, src }] })` with the same CDN host. `npm test` checks that every entry has a date and that every file URL is on `cdn.pokoin.com`.

A new *board* (a new path, not another Poko tile) is a page under `src/pages/`, a route in `src/router.js`, a matching rewrite in `vercel.json`, and one entry in `public/review/tests.json` so the dock and `/tests` list it.

## Data

Snapshots the boards render from disk are in `public/review/` and are served at `/review/…` (the same paths as today). Card scans and figure masks stay on the CDN and are requested as `/card-images/…`.

## Deploy

Create a Vercel project for this repo, separate from pokoin.com. The build is `npm run build` and the output is `dist/` (`vercel.json` sets both). Attach the domain `test.pokoin.com` to this project only.

`/` on that host redirects to `/tests`. `/card-images/*` is rewritten to `https://cdn.pokoin.com/*` so the OCR and artwork boards can load scans. Artist-table links under `/marketplace/…` redirect to `https://pokoin.com/marketplace/…`. There is no `/api` proxy: none of these boards call the marketplace API.
