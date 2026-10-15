import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const ROOT = join(fileURLToPath(import.meta.url), '..', '..', '..');
const LEGACY_HOST = ['cdn', 'pokoin', 'com'].join('.');

function walk(dir, acc = []) {
  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, ent.name);
    if (ent.isDirectory()) walk(path, acc);
    else acc.push(path);
  }
  return acc;
}

test('no legacy pokoin CDN host in app config or review JSON', () => {
  const targets = [
    join(ROOT, 'vercel.json'),
    ...walk(join(ROOT, 'src')).filter((p) => /\.(js|jsx)$/.test(p)),
    ...readdirSync(join(ROOT, 'public', 'review'))
      .filter((f) => f.endsWith('.json'))
      .map((f) => join(ROOT, 'public', 'review', f)),
  ];

  const hits = [];
  for (const file of targets) {
    const text = readFileSync(file, 'utf8');
    if (text.includes(LEGACY_HOST)) hits.push(file.replace(`${ROOT}/`, ''));
  }
  assert.deepEqual(hits, [], `remove ${LEGACY_HOST} from: ${hits.join(', ')}`);
});
