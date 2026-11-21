#!/usr/bin/env node
/**
 * Build media-manifest.json: every object key the boards can request, with local hashes.
 *
 *   POKOIN_OBJECTS=/path/to/object/store node scripts/media-manifest.mjs
 *
 * POKOIN_OBJECTS is the directory that holds the media objects; the manifest records every key
 * relative to it and never the directory itself. Optional: POKOIN_MEDIA_FALLBACK_HOST, the ssh host
 * that holds objects missing from the local store, and with it POKOIN_MEDIA_FALLBACK_OBJECTS, the
 * directory on that host the keys are relative to. A host with no remote directory behind it ends the
 * run 2; with no host neither is asked for, and the tree names neither of them. A remote directory that
 * is not an absolute path of plain characters, with no step out of itself, ends the run 2 too, before a
 * catalog is fetched: the keys go over under it as one quoted word, and a name of that shape is a
 * mistyped path rather than a place.
 */

import { createHash } from 'node:crypto';
import { createReadStream, existsSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { stat } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

import { collectMediaKeys } from './media-collect.mjs';
import { assertNoHost, assertNoLeaks } from './media-manifest-guard.mjs';
import { MEDIA_BASE } from '../src/lib/media.js';

const ROOT = join(fileURLToPath(import.meta.url), '..', '..');
const OUT = join(ROOT, 'media-manifest.json');
const ALIASES_PATH = join(ROOT, 'media-aliases.json');

function loadAliases() {
  if (!existsSync(ALIASES_PATH)) return {};
  return JSON.parse(readFileSync(ALIASES_PATH, 'utf8'));
}

const LOCAL_OBJECTS = process.env.POKOIN_OBJECTS || '';
const PI_OBJECTS = process.env.POKOIN_MEDIA_FALLBACK_OBJECTS || '';
const PI_HOST = process.env.POKOIN_MEDIA_FALLBACK_HOST || '';
// the host reaches ssh as one argument, so it must not start with a dash nor hold a space, a colon or
// another shell character; a host with a port on it is not one ssh can use, and nothing is looked up
// before the value is accepted
if (PI_HOST && !/^[A-Za-z0-9][A-Za-z0-9._@-]*$/.test(PI_HOST)) {
  console.error('invalid POKOIN_MEDIA_FALLBACK_HOST');
  process.exit(2);
}
// the remote directory belongs to the host and to nothing else: with no host set nothing is looked
// up anywhere, and with one set the run that was not told names the variable rather than guess the
// layout of a machine it reaches
if (PI_HOST && !PI_OBJECTS) {
  console.error('set POKOIN_MEDIA_FALLBACK_OBJECTS to the remote directory that holds the media objects');
  process.exit(2);
}
// the shape of that directory is held to what a name is made of, the way the host is: absolute, of
// these characters only, no step out of itself and nothing after its name. It stands in front of every
// key the run asks the other machine for, and it goes into a command line the shell there reads, so a
// value of any other shape ends the run before a catalog is fetched. A run with no host set ends the
// same way: the name it would reach for is the one it was given either way, and a directory holding a
// space, a quote or a star is a mistyped path rather than a place.
if (PI_OBJECTS && !(
  /^[A-Za-z0-9._/@+-]+$/.test(PI_OBJECTS)
  && PI_OBJECTS.startsWith('/')
  && !PI_OBJECTS.includes('\n')
  && !/(^|\/)\.\.(\/|$)/.test(PI_OBJECTS)
)) {
  console.error('invalid POKOIN_MEDIA_FALLBACK_OBJECTS');
  process.exit(2);
}
// the store is where the operator keeps it, and the tree holds no guess at it: a run that was not
// told would hash the files of whatever directory its name happens to match
if (!LOCAL_OBJECTS) {
  console.error('set POKOIN_OBJECTS to the directory that holds the media objects');
  process.exit(2);
}
const LEGACY_CATALOG = 'https://cdn.pokoin.com/poko-video/newpoko/catalog.json';

async function fetchCatalog() {
  const candidates = [`${MEDIA_BASE}/poko-video/newpoko/catalog.json`, LEGACY_CATALOG];
  for (const candidate of candidates) {
    try {
      const res = await fetch(candidate, { signal: AbortSignal.timeout(30_000) });
      if (!res.ok) throw new Error(`${res.status}`);
      return await res.json();
    } catch (e) {
      console.warn(`catalog fetch failed (${candidate}): ${e.message}`);
    }
  }
  throw new Error('could not load newPoko catalog.json');
}

async function sha256File(path) {
  return new Promise((resolve, reject) => {
    const hash = createHash('sha256');
    const stream = createReadStream(path);
    stream.on('error', reject);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
  });
}

function piKeysPresent(keys) {
  if (!PI_HOST || !keys.length) return Promise.resolve(new Set());
  // the directory is quoted on the way in, though the value was held to plain characters above: the
  // command is one line the shell on that machine reads, and a name is one word there or it is nothing
  const script = `cd '${PI_OBJECTS}' && while IFS= read -r k; do test -f "$k" && printf '%s\\n' "$k"; done`;
  return new Promise((resolve) => {
    const child = spawn('ssh', ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '--', PI_HOST, script], {
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let stdout = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stdin.write(`${keys.join('\n')}\n`);
    child.stdin.end();
    child.on('close', () => {
      resolve(new Set(stdout.trim().split('\n').filter(Boolean)));
    });
    child.on('error', () => resolve(new Set()));
  });
}

// the key of a resolution is the name the object store holds the file under, which on an alias row
// is the alias target and not the key of the row
function resolveSource(key, piPresent) {
  const local = join(LOCAL_OBJECTS, key);
  if (existsSync(local) && statSync(local).isFile()) {
    return { path: local, key, source: 'local' };
  }
  if (piPresent.has(key)) {
    return { path: `ssh:${PI_HOST}:${PI_OBJECTS}/${key}`, key, source: 'fallback' };
  }
  return { path: '', key: '', source: '' };
}

async function fileMeta(resolved) {
  if (!resolved.path || resolved.path.startsWith('ssh:')) {
    return { size: null, sha256: null };
  }
  const st = await stat(resolved.path);
  const sha256 = await sha256File(resolved.path);
  return { size: st.size, sha256 };
}

function topFolder(key) {
  const i = key.indexOf('/');
  return i === -1 ? '(root)' : key.slice(0, i);
}

async function main() {
  const aliases = loadAliases();
  console.log('Loading catalog…');
  const catalog = await fetchCatalog();
  console.log('Collecting keys…');
  const keyMap = collectMediaKeys({ catalog });

  const keys = [...keyMap.keys()].sort();
  const localMissing = keys.filter((key) => !existsSync(join(LOCAL_OBJECTS, key)));
  console.log(`Resolving ${keys.length} keys (${localMissing.length} need a fallback-host check)…`);
  const piPresent = await piKeysPresent(localMissing);
  console.log(`Hashing (local files only)…`);

  const CONCURRENCY = 12;
  const entries = new Array(keys.length);
  let cursor = 0;

  async function worker() {
    while (true) {
      const index = cursor;
      if (index >= keys.length) return;
      cursor += 1;
      const key = keys[index];
      let aliasOf;
      let resolved = resolveSource(key, piPresent);
      if (!resolved.path && aliases[key]) {
        aliasOf = aliases[key];
        resolved = resolveSource(aliasOf, piPresent);
      }
      const meta = await fileMeta(resolved);
      const row = {
        key,
        sources: [...keyMap.get(key)].sort(),
        object: resolved.key || null,
        objectStore: resolved.source || null,
        size: meta.size,
        sha256: meta.sha256,
      };
      if (aliasOf) row.aliasOf = aliasOf;
      entries[index] = row;
    }
  }

  await Promise.all(Array.from({ length: CONCURRENCY }, () => worker()));

  const byFolder = new Map();
  const byFolderBytes = new Map();
  let totalBytes = 0;
  const missing = [];
  for (const row of entries) {
    if (!row.object) missing.push(row.key);
    else if (row.size != null) totalBytes += row.size;
    const folder = topFolder(row.key);
    byFolder.set(folder, (byFolder.get(folder) || 0) + 1);
    if (row.size != null) {
      byFolderBytes.set(folder, (byFolderBytes.get(folder) || 0) + row.size);
    }
  }

  const manifest = {
    generatedAt: new Date().toISOString(),
    mediaBase: MEDIA_BASE,
    bucket: 'pokoin-test-media',
    counts: {
      keys: keys.length,
      bytes: totalBytes,
      missing: missing.length,
    },
    byFolder: Object.fromEntries([...byFolder.entries()].sort(([a], [b]) => a.localeCompare(b))),
    byFolderBytes: Object.fromEntries(
      [...byFolderBytes.entries()].sort(([a], [b]) => a.localeCompare(b)),
    ),
    missing,
    entries,
  };

  const text = `${JSON.stringify(manifest, null, 2)}\n`;
  // the checks run on the manifest that is about to become the file, before anything is written
  try {
    assertNoHost(text, PI_HOST);
  } catch {
    console.error('refusing to write a manifest that names the fallback host');
    process.exit(1);
  }
  try {
    assertNoLeaks(manifest);
  } catch (e) {
    console.error(`refusing to write a manifest that names a directory: ${e.message}`);
    process.exit(1);
  }
  writeFileSync(OUT, text);

  const mb = (totalBytes / (1024 * 1024)).toFixed(2);
  console.log(`Wrote ${OUT}`);
  console.log(`Keys: ${keys.length} · ${mb} MB (local hashes) · missing source: ${missing.length}`);
  console.log('By folder (count):', manifest.byFolder);
  if (missing.length) {
    console.log('Missing (first 20):', missing.slice(0, 20).join('\n  '));
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
