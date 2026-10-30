import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fingerprint, sharedRun, SAMPLE_RATE } from '../src/audio-fingerprint.ts';
import { addNoise, mix, programme } from './synthetic-audio.ts';

const now = async () => {};

const theme = programme(40, 99, 0.3);
const near = (actual: number, expected: number, label: string) => assert.ok(Math.abs(actual - expected) < 1, `${label}: ${actual.toFixed(2)} s, expected about ${expected} s`);

test('finds a shared theme at different, unaligned positions in two episodes', async () => {
  const a = await fingerprint(mix(programme(180, 1), theme, 30.3), now), b = await fingerprint(mix(programme(180, 2), theme, 75.77), now);
  const run = await sharedRun(a, b, 15, 150, now);
  assert.ok(run, 'the theme should be found');
  near(run.aStart, 30.3, 'start in the first episode'); near(run.aEnd, 70.3, 'end in the first episode');
  near(run.bStart, 75.77, 'start in the second episode'); near(run.bEnd, 115.77, 'end in the second episode');
});

test('still finds the theme when one copy is quieter and noisier', async () => {
  const a = await fingerprint(mix(programme(150, 3), theme, 12), now);
  const b = await fingerprint(addNoise(mix(programme(150, 4), theme, 64, 0.5), 5, 0.008), now);
  const run = await sharedRun(a, b, 15, 150, now);
  assert.ok(run, 'the theme should be found');
  near(run.aStart, 12, 'start'); near(run.aEnd, 52, 'end'); near(run.bStart, 64, 'start in the second episode');
});

test('reports nothing when the episodes share no audio', async () => {
  for (let seed = 20; seed < 32; seed += 2) {
    const run = await sharedRun(await fingerprint(programme(150, seed), now), await fingerprint(programme(150, seed + 1), now), 15, 150, now);
    assert.equal(run, undefined, `episodes ${seed} and ${seed + 1}`);
  }
});

test('a sound effect over part of the theme does not split it', async () => {
  const b = mix(programme(150, 15), theme, 50);
  b.set(programme(2, 16, 0.4), 70 * SAMPLE_RATE);
  const run = await sharedRun(await fingerprint(mix(programme(150, 14), theme, 20), now), await fingerprint(b, now), 15, 150, now);
  assert.ok(run, 'the theme should be found');
  near(run.aStart, 20, 'start'); near(run.aEnd, 60, 'end');
});

test('ignores shared audio shorter than the minimum', async () => {
  const sting = theme.subarray(0, 8 * SAMPLE_RATE);
  const run = await sharedRun(await fingerprint(mix(programme(120, 8), sting, 20), now), await fingerprint(mix(programme(120, 9), sting, 50), now), 15, 150, now);
  assert.equal(run, undefined);
});

test('silence in both episodes is never a match', async () => {
  const silent = new Float32Array(60 * SAMPLE_RATE);
  const a = programme(150, 10), b = programme(150, 11);
  a.set(silent, 20 * SAMPLE_RATE); b.set(silent, 40 * SAMPLE_RATE);
  assert.equal(await sharedRun(await fingerprint(a, now), await fingerprint(b, now), 15, 150, now), undefined);
});

test('two copies of the same episode are not mistaken for a theme', async () => {
  const episode = programme(200, 12);
  assert.equal(await sharedRun(await fingerprint(episode, now), await fingerprint(episode.slice(), now), 15, 150, now), undefined);
});

test('fingerprinting stops when cancelled', async () => {
  const controller = new AbortController(); controller.abort();
  await assert.rejects(fingerprint(programme(30, 13), now, controller.signal), { name: 'AbortError' });
});
