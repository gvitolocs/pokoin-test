/**
 * Collect every R2 object key referenced by the review boards.
 * Used by scripts/media-manifest.mjs and kept importable for tests.
 */

import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { MEDIA_BASE } from '../src/lib/media.js';
import { POKO_TESTS } from '../src/pages/poko-tests.js';

const ROOT = join(fileURLToPath(import.meta.url), '..', '..');
const REVIEW = join(ROOT, 'public', 'review');
const SRC = join(ROOT, 'src');

const BEFORE_MASK_REV = 'sam21-1';
const AFTER_MASK_REV = 'clean-1';
const WHOLE_MASK_REV = 'whole-1';

const ARTWORK_VERSIONS = [
  'v232338',
  'v219698',
  'v219702',
  'v219706',
  'v249112',
  'v249116',
  'v224472',
  'v239120',
];

const ARTWORK_CARD_IMAGES = [
  '116169_venusaur-ex-full-v4.jpg',
  '109849_oddish-1-98-ancient-origins.jpg',
  '109851_gloom-full-v4.jpg',
  '109853_vileplume-3-98-ancient-origins.jpg',
  '124556_lampent-42-119-phantom-forces.jpg',
  '124558_chandelure-rare-holo-43-119-phantom-forces.jpg',
  '112236_noivern-gx-full-v4.jpg',
  '119560_xerneas-gx-full-v4.jpg',
];

const MEDIA_HOSTS = new Set([
  'cdn.pokoin.com',
  'test-media.pokoin.com',
  new URL(MEDIA_BASE).hostname,
]);

export function isValidMediaKey(key) {
  if (!key || key.length > 512) return false;
  if (key.endsWith('/') || key.includes('//')) return false;
  if (/[${}()<>`]/.test(key)) return false;
  const base = key.split('/').pop();
  if (!base || !base.includes('.')) return false;
  return /^[a-zA-Z0-9_./-]+$/.test(key);
}

/** @param {string} urlOrPath */
export function mediaKeyFromRef(urlOrPath) {
  const text = String(urlOrPath || '').trim();
  if (!text || text.startsWith('data:') || text.startsWith('blob:')) return '';
  if (text.startsWith('/review/')) return '';

  try {
    if (/^https?:\/\//i.test(text)) {
      const url = new URL(text);
      if (!MEDIA_HOSTS.has(url.hostname)) return '';
      const path = url.pathname.replace(/^\//, '');
      return path.split('?')[0] || '';
    }
  } catch {
    return '';
  }

  if (text.startsWith('/card-images/')) {
    return text.slice('/card-images/'.length).split('?')[0] || '';
  }
  return '';
}

function addKey(set, ref, source) {
  const key = mediaKeyFromRef(ref);
  if (!key || !isValidMediaKey(key)) return;
  if (!set.has(key)) set.set(key, new Set());
  set.get(key).add(source);
}

function walkJson(value, source, set) {
  if (value == null) return;
  if (typeof value === 'string') {
    if (
      value.includes('/card-images/')
      || value.includes('cdn.pokoin.com')
      || value.includes('test-media.pokoin.com')
    ) {
      addKey(set, value, source);
    }
    return;
  }
  if (Array.isArray(value)) {
    for (const item of value) walkJson(item, source, set);
    return;
  }
  if (typeof value === 'object') {
    for (const v of Object.values(value)) walkJson(v, source, set);
  }
}

function scanSourceTree(dir, rel = '', set) {
  for (const name of readdirSync(join(dir, rel), { withFileTypes: true })) {
    const next = rel ? `${rel}/${name.name}` : name.name;
    const full = join(dir, next);
    if (name.isDirectory()) {
      scanSourceTree(dir, next, set);
      continue;
    }
    if (!/\.(js|jsx|json)$/.test(name.name)) continue;
    const text = readFileSync(full, 'utf8');
    const cdn = [...text.matchAll(/https:\/\/cdn\.pokoin\.com\/[a-zA-Z0-9_./%-]+/g)];
    const media = [...text.matchAll(/https:\/\/test-media\.pokoin\.com\/[a-zA-Z0-9_./%-]+/g)];
    const card = [...text.matchAll(/\/card-images\/[a-zA-Z0-9_./-]+/g)];
    for (const m of [...cdn, ...media, ...card]) addKey(set, m[0], `src:${next}`);
  }
}

function expandArtworkMasks(set) {
  const source = 'templated:ArtworkHover.jsx';
  for (const version of ARTWORK_VERSIONS) {
    addKey(set, `/card-images/figure-masks/${version}.webp?v=${BEFORE_MASK_REV}`, source);
    addKey(set, `/card-images/figure-masks-clean/${version}.webp?v=${AFTER_MASK_REV}`, source);
    addKey(set, `/card-images/figure-masks-whole/${version}.webp?v=${WHOLE_MASK_REV}`, source);
  }
  for (const file of ARTWORK_CARD_IMAGES) {
    addKey(set, `/card-images/${file}`, source);
  }
}

function expandPokoTests(set) {
  for (const entry of POKO_TESTS) {
    const source = 'src/pages/poko-tests.js';
    if (entry.kind === 'video') {
      addKey(set, entry.src, source);
      if (entry.poster) addKey(set, entry.poster, source);
      if (entry.voiceover) addKey(set, entry.voiceover, source);
    } else {
      for (const clip of entry.clips || []) addKey(set, clip.src, source);
    }
  }
}

/**
 * @param {object} catalog
 * @param {Map<string, Set<string>>} set
 */
export function addArchiveCatalog(catalog, set) {
  const source = 'poko-video/newpoko/catalog.json';
  addKey(set, `${MEDIA_BASE}/poko-video/newpoko/catalog.json`, source);
  for (const group of catalog.groups || []) {
    if (group.script) addKey(set, group.script, source);
    for (const file of group.files || []) {
      if (file.src) addKey(set, file.src, source);
    }
  }
}

/** @returns {Map<string, Set<string>>} key → referencing sources */
export function collectMediaKeys({ catalog = null } = {}) {
  const set = new Map();

  scanSourceTree(SRC, '', set);

  for (const name of readdirSync(REVIEW).filter((f) => f.endsWith('.json'))) {
    const data = JSON.parse(readFileSync(join(REVIEW, name), 'utf8'));
    walkJson(data, `public/review/${name}`, set);
  }

  expandArtworkMasks(set);
  expandPokoTests(set);

  if (catalog) addArchiveCatalog(catalog, set);

  return set;
}
