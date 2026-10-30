// Finds the stretch of audio two episodes share, such as the theme over the opening titles or the music under
// the end credits. Each 64 ms step of audio becomes 32 bits, one per pair of neighbouring frequency bands, set
// when the energy difference between the two bands grows from the step before (Haitsma and Kalker's audio
// fingerprint). Matching steps from the same recording differ in a few bits; unrelated audio differs in about
// half of them, so a long stretch of steps with few differing bits is audio both episodes contain.

export const SAMPLE_RATE = 8000;
// A 256 ms frame every 64 ms. A frame this long changes little when the two episodes' steps fall up to half a
// step apart, so matching audio still differs in under a quarter of its bits.
const FRAME = 2048;
const HOP = 512;
export const STEP_SECONDS = HOP / SAMPLE_RATE;
const BANDS = 33;
const LOW_HZ = 300;
const HIGH_HZ = 3400;
// Steps quieter than about -55 dBFS carry no usable spectrum. Two silent stretches would otherwise match exactly.
const QUIET = 3.2e-6;
// A step pair counts as matching while the steps around it differ in at most this many of their 32 bits on
// average. The same audio a fraction of a step out of line differs in about 8; unrelated audio in 16.
const MATCH_BITS = 12.5;
const WINDOW = 15;
// A run survives up to 4 seconds of poorer matches, such as a sound effect over the theme. Unrelated audio
// almost never matches again at the same offset after a gap, so the bridge does not reach past the theme.
const GAP = 64;
const KEYS = 1 << 16;
const BUCKET_LIMIT = 256;
const CANDIDATES = 8;
const MIN_VOTES = 6;

export interface Fingerprint { bits: Uint32Array; quiet: Uint8Array }
export interface SharedRun { aStart: number; aEnd: number; bStart: number; bEnd: number }
export type Pause = () => Promise<void>;

const reversed = new Uint16Array(FRAME);
const cosine = new Float64Array(FRAME / 2);
const sine = new Float64Array(FRAME / 2);
const hann = new Float64Array(FRAME);
const bandStart = new Uint16Array(BANDS);
const bandEnd = new Uint16Array(BANDS);
(() => {
  const levels = Math.log2(FRAME);
  for (let i = 0; i < FRAME; i++) {
    let r = 0;
    for (let bit = 0; bit < levels; bit++) r |= ((i >> bit) & 1) << (levels - 1 - bit);
    reversed[i] = r;
    hann[i] = 0.5 - 0.5 * Math.cos(2 * Math.PI * i / (FRAME - 1));
  }
  for (let k = 0; k < FRAME / 2; k++) { cosine[k] = Math.cos(2 * Math.PI * k / FRAME); sine[k] = -Math.sin(2 * Math.PI * k / FRAME); }
  for (let band = 0; band < BANDS; band++) {
    const from = Math.round(LOW_HZ * (HIGH_HZ / LOW_HZ) ** (band / BANDS) * FRAME / SAMPLE_RATE);
    const to = Math.round(LOW_HZ * (HIGH_HZ / LOW_HZ) ** ((band + 1) / BANDS) * FRAME / SAMPLE_RATE);
    bandStart[band] = from; bandEnd[band] = Math.max(from + 1, to);
  }
})();

function transform(re: Float64Array, im: Float64Array): void {
  for (let i = 0; i < FRAME; i++) {
    const j = reversed[i];
    if (j > i) { let t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; }
  }
  for (let size = 2; size <= FRAME; size *= 2) {
    const half = size / 2, step = FRAME / size;
    for (let start = 0; start < FRAME; start += size) {
      for (let k = 0; k < half; k++) {
        const wr = cosine[k * step], wi = sine[k * step], a = start + k, b = a + half;
        const tr = wr * re[b] - wi * im[b], ti = wr * im[b] + wi * re[b];
        re[b] = re[a] - tr; im[b] = im[a] - ti; re[a] += tr; im[a] += ti;
      }
    }
  }
}

export const nextTask: Pause = () => new Promise(resolve => setTimeout(resolve, 0));

/** Fingerprints mono samples at SAMPLE_RATE, pausing now and then so playback stays smooth. */
export async function fingerprint(samples: Float32Array, pause: Pause = nextTask, signal?: AbortSignal): Promise<Fingerprint> {
  const steps = samples.length < FRAME ? 0 : Math.floor((samples.length - FRAME) / HOP) + 1;
  const bits = new Uint32Array(steps), quiet = new Uint8Array(steps).fill(1);
  const energy = new Float64Array(steps * BANDS);
  const re = new Float64Array(FRAME), im = new Float64Array(FRAME);
  let windowPower = 0;
  for (let i = 0; i < FRAME; i++) windowPower += hann[i] * hann[i];
  // Two real frames share one complex transform: the first as the real part, the second as the imaginary part.
  for (let step = 0; step < steps; step += 2) {
    if (step % 128 === 0) { await pause(); if (signal?.aborted) throw new DOMException('Cancelled', 'AbortError'); }
    const second = step + 1 < steps;
    let first = 0, other = 0;
    for (let i = 0; i < FRAME; i++) {
      const x = samples[step * HOP + i] * hann[i], y = second ? samples[(step + 1) * HOP + i] * hann[i] : 0;
      re[i] = x; im[i] = y; first += x * x; other += y * y;
    }
    quiet[step] = first / windowPower < QUIET ? 1 : 0;
    if (second) quiet[step + 1] = other / windowPower < QUIET ? 1 : 0;
    transform(re, im);
    for (let band = 0; band < BANDS; band++) {
      let a = 0, b = 0;
      for (let k = bandStart[band]; k < bandEnd[band]; k++) {
        const xr = re[k], xi = im[k], yr = re[FRAME - k], yi = im[FRAME - k];
        const ar = xr + yr, ai = xi - yi, br = xi + yi, bi = yr - xr;
        a += ar * ar + ai * ai; b += br * br + bi * bi;
      }
      energy[step * BANDS + band] = a;
      if (second) energy[(step + 1) * BANDS + band] = b;
    }
  }
  for (let step = 1; step < steps; step++) {
    let value = 0;
    const now = step * BANDS, before = now - BANDS;
    for (let band = 0; band < BANDS - 1; band++) {
      if (energy[now + band] - energy[now + band + 1] - (energy[before + band] - energy[before + band + 1]) > 0) value |= 1 << band;
    }
    bits[step] = value >>> 0;
  }
  quiet[0] = 1;
  return { bits, quiet };
}

function differingBits(value: number): number {
  value -= (value >>> 1) & 0x55555555;
  value = (value & 0x33333333) + ((value >>> 2) & 0x33333333);
  return Math.imul((value + (value >>> 4)) & 0x0f0f0f0f, 0x01010101) >>> 24;
}

// Offsets (a step minus b step) where many 16-bit halves of the two prints are equal. Matching audio lines up at
// one offset; equal halves from unrelated audio scatter across all of them.
function candidateOffsets(a: Fingerprint, b: Fingerprint): number[] {
  const n = a.bits.length, m = b.bits.length;
  const start = new Uint32Array(2 * KEYS + 1);
  for (let j = 0; j < m; j++) if (!b.quiet[j]) { start[(b.bits[j] >>> 16) + 1]++; start[KEYS + (b.bits[j] & 0xffff) + 1]++; }
  for (let key = 1; key <= 2 * KEYS; key++) start[key] += start[key - 1];
  const fill = start.slice(), positions = new Int32Array(start[2 * KEYS]);
  for (let j = 0; j < m; j++) if (!b.quiet[j]) { positions[fill[b.bits[j] >>> 16]++] = j; positions[fill[KEYS + (b.bits[j] & 0xffff)]++] = j; }
  const votes = new Int32Array(n + m + 1);
  for (let i = 0; i < n; i++) {
    if (a.quiet[i]) continue;
    for (const key of [a.bits[i] >>> 16, KEYS + (a.bits[i] & 0xffff)]) {
      const from = start[key], to = start[key + 1];
      // Halves shared by hundreds of steps come from tones and hum, not from anything worth lining up.
      if (to - from > BUCKET_LIMIT) continue;
      for (let p = from; p < to; p++) votes[i - positions[p] + m]++;
    }
  }
  const peaks: Array<[number, number]> = [];
  for (let k = 1; k < votes.length - 1; k++) {
    const total = votes[k - 1] + votes[k] + votes[k + 1];
    if (total >= MIN_VOTES && votes[k] >= votes[k - 1] && votes[k] >= votes[k + 1]) peaks.push([total, k - m]);
  }
  peaks.sort((x, y) => y[0] - x[0]);
  const chosen: number[] = [];
  for (const [, offset] of peaks) {
    if (chosen.some(other => Math.abs(other - offset) <= 2)) continue;
    chosen.push(offset);
    if (chosen.length === CANDIDATES) break;
  }
  return chosen;
}

// The longest stretch of matching steps at one offset, as a step range in `a`, allowing short gaps.
function longestRun(a: Fingerprint, b: Fingerprint, offset: number): [number, number] | undefined {
  const from = Math.max(0, offset), to = Math.min(a.bits.length, b.bits.length + offset), length = to - from;
  if (length <= 0) return undefined;
  const total = new Float64Array(length + 1);
  for (let t = 0; t < length; t++) {
    const i = from + t, j = i - offset;
    total[t + 1] = total[t] + (a.quiet[i] || b.quiet[j] ? 16 : differingBits(a.bits[i] ^ b.bits[j]));
  }
  const average = (first: number, last: number) => {
    const low = Math.max(0, first), high = Math.min(length - 1, last);
    return (total[high + 1] - total[low]) / (high - low + 1);
  };
  let best: [number, number] | undefined, runStart = -1, lastMatch = -1;
  const close = () => { if (runStart >= 0 && (!best || lastMatch - runStart > best[1] - best[0])) best = [runStart, lastMatch]; };
  for (let t = 0; t < length; t++) {
    if (average(t - WINDOW, t + WINDOW) > MATCH_BITS) continue;
    if (runStart < 0 || t - lastMatch > GAP) { close(); runStart = t; }
    lastMatch = t;
  }
  close();
  if (!best) return undefined;
  let [first, last] = best;
  // The averaging window lets a run spill a little past the shared audio; trim edges that do not match closely.
  while (first < last && average(first, first + 4) > MATCH_BITS) first++;
  while (last > first && average(last - 4, last) > MATCH_BITS) last--;
  return [from + first, from + last];
}

/**
 * The longest stretch of audio both prints contain, if it lasts between `minSeconds` and `maxSeconds`. Times are
 * seconds from the start of each print. A longer match means the two files share far more than a theme, such as
 * two copies of one episode, so it is not reported.
 */
export async function sharedRun(a: Fingerprint, b: Fingerprint, minSeconds: number, maxSeconds: number, pause: Pause = nextTask): Promise<SharedRun | undefined> {
  if (!a.bits.length || !b.bits.length) return undefined;
  const offsets = candidateOffsets(a, b);
  let best: { first: number; last: number; offset: number } | undefined;
  for (const candidate of offsets) {
    await pause();
    for (const offset of [candidate - 1, candidate, candidate + 1]) {
      const run = longestRun(a, b, offset);
      if (run && (!best || run[1] - run[0] > best.last - best.first)) best = { first: run[0], last: run[1], offset };
    }
  }
  if (!best) return undefined;
  const seconds = (best.last + 1 - best.first) * STEP_SECONDS;
  if (seconds < minSeconds || seconds > maxSeconds) return undefined;
  return {
    aStart: best.first * STEP_SECONDS, aEnd: (best.last + 1) * STEP_SECONDS,
    bStart: (best.first - best.offset) * STEP_SECONDS, bEnd: (best.last + 1 - best.offset) * STEP_SECONDS
  };
}
