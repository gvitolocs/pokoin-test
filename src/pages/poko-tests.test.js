import assert from 'node:assert/strict';
import test from 'node:test';
import { MEDIA_BASE } from '../lib/media.js';
import { POKO_TESTS, testsByMonth } from './poko-tests.js';

const OCTOBER_IDS = [
  'ep8-voxkit-opening',
  'ep8-lugia',
  'ep7-v2',
  'ep7-rooms',
  'qwen-v4',
  'cb-lora1',
  'cb-lora2',
  'part5-opening',
];

test('every test has an explicit date and a playable source', () => {
  const ids = new Set();
  for (const entry of POKO_TESTS) {
    assert.match(entry.date, /^\d{4}-\d{2}-\d{2}$/, entry.id);
    assert.equal(ids.has(entry.id), false, entry.id);
    ids.add(entry.id);
    if (entry.kind === 'video') {
      assert.match(entry.src, new RegExp(`^${MEDIA_BASE.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}/`), entry.id);
    } else {
      assert.equal(entry.kind, 'audio', entry.id);
      assert.ok(entry.clips?.length, entry.id);
      for (const clip of entry.clips) {
        assert.match(clip.src, new RegExp(`^${MEDIA_BASE.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}/`), clip.id);
        assert.equal(clip.src.includes('/market/poko-audio/'), false, clip.id);
      }
    }
  }
});

test('months are newest first and October holds the new tests', () => {
  const months = testsByMonth();
  const keys = months.map((month) => month.id);
  assert.deepEqual(keys, keys.slice().sort((a, b) => b.localeCompare(a)));
  const october = months.find((month) => month.id === '2026-10');
  assert.ok(october);
  const ids = october.tests.map((entry) => entry.id);
  for (const id of OCTOBER_IDS) assert.ok(ids.includes(id), id);
  const dates = october.tests.map((entry) => entry.date);
  assert.deepEqual(dates, dates.slice().sort((a, b) => b.localeCompare(a)));
  assert.equal(october.tests[0].id, 'ep8-voxkit-opening');
  const lora1 = october.tests.find((entry) => entry.id === 'cb-lora1');
  const lora2 = october.tests.find((entry) => entry.id === 'cb-lora2');
  assert.equal(lora1.clips.length, 14);
  assert.equal(lora2.clips.length, 9);
  assert.equal(october.tests.find((entry) => entry.id === 'qwen-v4').clips.length, 8);
  assert.equal(october.tests.find((entry) => entry.id === 'part5-opening').clips.length, 3);
});
