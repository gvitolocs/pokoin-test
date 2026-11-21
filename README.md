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

`media-manifest.json` lists every object key the app can request, with sizes and SHA-256 from the machine that holds the media objects and, when a fallback host is configured, from that host too. A row holds keys only: `object` is the name the object store holds the file under, never a path and never the directory it was read from, and it equals the row's own `key` except on an alias row, where it is the `aliasOf` target because that is the one file the store holds. Where the store lives is said at run time by `POKOIN_OBJECTS`, and no script of this repository keeps a default for it. Regenerate after adding board media:

```bash
POKOIN_OBJECTS=/path/to/object/store node scripts/media-manifest.mjs
```

Upload from the machine that holds the media objects (the script loads the Cloudflare credentials file `~/.config/pokoin/cloudflare.env` itself, where `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` come from; its values replace values already exported; it needs `~/.bun/bin/wrangler`):

```bash
POKOIN_OBJECTS=/path/to/object/store ./scripts/upload-media-r2.sh
```

Both media scripts take one required variable, `POKOIN_OBJECTS`: the directory that holds the media objects, which every `object` and `aliasOf` key of the manifest is relative to. Unset or empty, both print `set POKOIN_OBJECTS to the directory that holds the media objects` and exit 2, and the tree names no directory of its own for them to fall back to. `scripts/upload-media-r2.sh` looks at the value as well: set but not a directory, it prints `POKOIN_OBJECTS is not a directory` and exits 2 in the same place, before a key is read or a host is asked. Both scripts take two more variables that belong together: `POKOIN_MEDIA_FALLBACK_HOST`, the ssh host that holds media objects missing from the local store, and `POKOIN_MEDIA_FALLBACK_OBJECTS`, the directory on that host that its keys are relative to. The host value has to be a plain host token -- letters, digits and `.` `_` `-` and the ASCII `@`, not starting with a dash -- otherwise both scripts print `invalid POKOIN_MEDIA_FALLBACK_HOST`, exit 2 and make no ssh or scp call at all. A colon is not one of the characters: `host:22` names a host and a port, which is what a URL writes and not what ssh and scp take as one argument, so such a value is refused the same way. A host with no remote directory behind it is refused the same way, by both: they print `set POKOIN_MEDIA_FALLBACK_OBJECTS to the remote directory that holds the media objects` and exit 2, after the host is validated and before any ssh or scp call. With no host set the value is never used, and the tree holds no default for it either. `POKOIN_MEDIA_FALLBACK_OBJECTS` is held to the shape of a name, by both scripts and with no host set as much as with one -- absolute, of letters, digits and `.` `_` `/` `@` `+` `-` only, no `..` component, no control character -- or they print `invalid POKOIN_MEDIA_FALLBACK_OBJECTS` and exit 2 before a fetch or an ssh call, and the path it gives is handed to ssh as one single-quoted word, so a key holding a space, a glob or a `$` cannot become two names, a file list or a command in the shell that reads it there. Unset (the default) means no fallback, and what a run then makes of a key it cannot read locally depends on what `media-manifest.json` says about that key, because the manifest is the record of what the generator found on either store. A key whose row names an `object`, or whose `aliasOf` source is missing too, is a real skip: `scripts/upload-media-r2.sh` prints one `skip (no source)` line per such key, then `N keys skipped: no source` -- `1 key skipped: no source` for a single one -- on stderr once the whole list has been worked through, and exits 3 so a partial upload is not mistaken for a complete one. A key whose row says `"object": null`, carries no `aliasOf` and is not named by `media-aliases.json` is a key no run can upload, so it is counted apart: the script prints `N keys have no object in the manifest` (singular `1 key has no object in the manifest`), only when N is not zero, and that alone does not change the exit status. The alias map is consulted for that count exactly as it is for the upload, which looks a null row's key up in it: a null row the map names has a source the run was told to look for, so when neither that file nor the remote holds it the key is a real skip and the run exits 3, not a free line about the manifest. The committed manifest records 7 such keys, all `figure-masks-whole/v*.webp`, so a plain run over it uploads the rest and exits 0. `scripts/media-manifest.mjs` with no fallback host records such a key with no source. The keys a run works are the rows of `media-manifest.json`, or the lines of the file named by `KEYS_FILE` (one key per line; blank lines and `#` lines are ignored), and `FORCE=1` makes it re-upload keys that `.media-upload.done` already records. A key named twice -- twice in that file, or as two rows of the manifest -- is one key to the run: the list is worked over before the keys go out to the parallel workers, keeping the first row of each key and the order, so `Keys to process: N` counts distinct keys and a duplicate is never the reason a run reports a key as unaccounted. A run of `scripts/upload-media-r2.sh` ends 4 when any upload failed, when a key it handed to the parallel workers never reported itself, when those workers stopped before the end of the list, when an upload worked but the done list would not take its row, or when the step that reads the manifest rows for the counts or the step that rewrites the done list of a forced run could not work; 3 when a key the manifest gives an object had to be skipped for want of a source; 5 when the final HEAD sample fetch did not come back; and 0 when none of these applies -- that is the order of precedence, not the order of the numbers. A preflight check that fails ends the run with 1 and an unusable `POKOIN_MEDIA_FALLBACK_HOST`, a host with no `POKOIN_MEDIA_FALLBACK_OBJECTS` behind it, a `POKOIN_MEDIA_FALLBACK_OBJECTS` that is not a plain absolute path, or a `POKOIN_OBJECTS` the run was not given or was given as something other than a directory with 2, any of them before a single key is worked. A run that could not account for every key says so with `unaccounted: N keys` beside its counts, names the code it saw with `xargs status: N` when the workers did not finish, says `done list not writable: <key>` for each key it could not record and `N keys uploaded but not recorded in the done list` (singular `1 key uploaded but not recorded in the done list`) for the count of them, and says `could not read the manifest rows` or `could not rewrite the done list` for the two steps that cannot work. A key whose upload failed is not recorded in `.media-upload.done`, so the next run retries it. The generator writes no host into the file, because a row names a key and not the place it was read from; as a last hold it refuses to write a manifest whose serialised text holds the value of `POKOIN_MEDIA_FALLBACK_HOST`, printing `refusing to write a manifest that names the fallback host` and exiting 1 before the file is written.

Exit 0 says that none of the above happened, and nothing more. The upload tool can exit 0 without uploading anything, when it is given nothing to do: an empty keys file, or a list whose every key an earlier run already recorded, is a run that succeeds and puts no object up. A manifest or keys file that is itself wrong is not detected: the run uploads what it is told to, so a row that names the wrong source, or a key the file leaves out, is a wrong upload or a missing one and not an error. And a key an earlier run recorded as done by mistake is not uploaded again unless `FORCE=1` -- the done list is the only record the run has of what went up, so it trusts it. Two steps that happen before a single key is worked can end the run with a shell error instead of one of these codes: creating the done list, and creating the private temporary directory the workers write their records in. That is accepted as it stands -- bash prints its own error and the run exits non-zero, so it is never mistaken for a run that uploaded everything.

### Tests

This repository has no CI, so the three script tests run by hand from a clone:

```bash
bash scripts/upload-media-r2.test.sh      # the upload script, against stub ssh / scp / wrangler / node and a temporary HOME
bash scripts/no-host-names.test.sh        # no tracked file of the repository names a retired machine or a home directory
bash scripts/media-manifest-guard.test.sh # the manifest holds keys, and no host name reaches the file
```

`scripts/upload-media-r2.test.sh` takes the path of the script under test as its only argument (default: its sibling `upload-media-r2.sh`), uploads nothing and reads no credential file, and it runs `scripts/no-host-names.test.sh` and `scripts/media-manifest-guard.test.sh` as two of its own steps, so that first command covers all three tests. It never runs `scripts/media-manifest.mjs`: the generator's own fetch and ssh calls are refused by its stubs, its cases work on manifest fixtures, and the suite fails if any step of it leaves `media-manifest.json` different from HEAD. `scripts/media-manifest-guard.test.sh` never runs the generator either: importing it fetches the catalog, so it reads the generator's rules out of its text and calls only `scripts/media-manifest-guard.mjs`, the one module of the pair that holds no side effect. `scripts/no-host-names.test.sh` needs only bash, git and tar. `npm test` covers the app, not these scripts.

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
