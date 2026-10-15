import assert from 'node:assert/strict';
import test from 'node:test';
import { rebaseMediaUrl } from './media.js';

const FROM = 'https://example.com/poko-video/newpoko';
const TO = 'https://test-media.pokoin.com/poko-video/newpoko';

test('rebaseMediaUrl replaces matching prefix', () => {
  assert.equal(
    rebaseMediaUrl(`${FROM}/clips/foo.mp3`, FROM, TO),
    `${TO}/clips/foo.mp3`,
  );
});

test('rebaseMediaUrl leaves non-matching URLs unchanged', () => {
  const other = 'https://other.example/asset.mp3';
  assert.equal(rebaseMediaUrl(other, FROM, TO), other);
});

test('rebaseMediaUrl handles trailing slashes on prefixes', () => {
  assert.equal(
    rebaseMediaUrl(`${FROM}/scripts/ep1.txt`, `${FROM}/`, `${TO}/`),
    `${TO}/scripts/ep1.txt`,
  );
  assert.equal(rebaseMediaUrl(FROM, `${FROM}/`, TO), TO);
});
