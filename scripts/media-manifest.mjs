#!/usr/bin/env node
/**
 * Build media-manifest.json: every object key the boards can request, with local hashes.
 *
 *   node scripts/media-manifest.mjs
 */

import { createHash } from 'node:crypto';
import { createReadStream, existsSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { stat } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

import { collectMediaKeys } from './media-collect.mjs';
import { MEDIA_BASE } from '../src/lib/media.js';

const ROOT = join(fileURLToPath(import.meta.url), '..', '..');
const OUT = join(ROOT, 'media-manifest.json');
const ALIASES_PATH = join(ROOT, 'media-aliases.json');

function loadAliases() {
  if (!existsSync(ALIASES_PATH)) return {};
  return JSON.parse(readFileSync(ALIASES_PATH, 'utf8'));
}

const NEZOPT_OBJECTS = '/home/nez/data/pokoin-leftovers/objects';
const PI_OBJECTS = '/srv/pokoin/card-images/objects';
const PI_HOST = 'pi-home';
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
  if (!keys.length) return Promise.resolve(new Set());
  const script = `cd ${PI_OBJECTS} && while IFS= read -r k; do test -f "$k" && printf '%s\\n' "$k"; done`;
  return new Promise((resolve) => {
    const child = spawn('ssh', ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', PI_HOST, script], {
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

function resolveSource(key, piPresent) {
  const local = join(NEZOPT_OBJECTS, key);
  if (existsSync(local) && statSync(local).isFile()) {
    return { path: local, source: 'nezopt' };
  }
  if (piPresent.has(key)) {
    return { path: `ssh:${PI_HOST}:${PI_OBJECTS}/${key}`, source: 'pi-home' };
  }
  return { path: '', source: '' };
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
  const localMissing = keys.filter((key) => !existsSync(join(NEZOPT_OBJECTS, key)));
  console.log(`Resolving ${keys.length} keys (${localMissing.length} need pi-home check)…`);
  const piPresent = await piKeysPresent(localMissing);
  console.log(`Hashing (nezopt files only)…`);

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
        object: resolved.path || null,
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

  writeFileSync(OUT, `${JSON.stringify(manifest, null, 2)}\n`);

  const mb = (totalBytes / (1024 * 1024)).toFixed(2);
  console.log(`Wrote ${OUT}`);
  console.log(`Keys: ${keys.length} · ${mb} MB (nezopt hashes) · missing source: ${missing.length}`);
  console.log('By folder (count):', manifest.byFolder);
  if (missing.length) {
    console.log('Missing (first 20):', missing.slice(0, 20).join('\n  '));
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
