import { SAMPLE_RATE } from '../src/audio-fingerprint.ts';

export function random(seed: number): () => number {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Programme-like audio: a new chord of three partials every 200 to 500 ms over faint noise. Each seed gives a
// different, never-repeating sequence, standing in for dialogue and score that differ between episodes.
export function programme(seconds: number, seed: number, level = 0.2): Float32Array {
  const next = random(seed), out = new Float32Array(Math.round(seconds * SAMPLE_RATE));
  let i = 0;
  while (i < out.length) {
    const length = Math.round((0.2 + next() * 0.3) * SAMPLE_RATE), partials = [0, 1, 2].map(() => 150 + next() * 2800);
    for (let k = 0; k < length && i < out.length; k++, i++) {
      const fade = Math.min(1, k / 80, (length - k) / 80);
      out[i] = level * fade * partials.reduce((sum, hz) => sum + Math.sin(2 * Math.PI * hz * k / SAMPLE_RATE), 0) / 3 + (next() - 0.5) * 0.01;
    }
  }
  return out;
}

/** `base` with `insert` written over it from `at` seconds. */
export function mix(base: Float32Array, insert: Float32Array, at: number, gain = 1): Float32Array {
  const out = base.slice(), offset = Math.round(at * SAMPLE_RATE);
  for (let i = 0; i < insert.length && offset + i < out.length; i++) out[offset + i] = insert[i] * gain;
  return out;
}

export function addNoise(samples: Float32Array, seed: number, amount: number): Float32Array {
  const next = random(seed);
  return samples.map(value => value + (next() - 0.5) * amount);
}
