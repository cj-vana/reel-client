// Three synthetic episodes for the intro and credits scan: each has its own programme audio, the same 40 second
// theme and the same 40 second credits music, at different times in each episode. All of it is generated here
// from tones and noise; no real media is involved.
export const INTRO_EPISODES = ['episode-1-1', 'episode-1-2', 'episode-1-3'];
export const INTRO_RUNTIME = 330;
// The client scans the last 90 seconds of a 330 second episode, from 240 seconds in.
export const INTRO_TAIL_START = 240;
export const introPlan = id => { const n = Number(id.split('-').at(-1)); return { intro: 12 + 9 * n, credits: 276 + 3 * n, length: 40 }; };
const RATE = 16000;

function random(seed) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// A new chord of three partials every 200 to 500 ms over faint noise; every seed gives a different sequence.
function programme(seconds, seed, level) {
  const next = random(seed), out = new Float32Array(Math.round(seconds * RATE));
  let i = 0;
  while (i < out.length) {
    const length = Math.round((0.2 + next() * 0.3) * RATE), partials = [0, 1, 2].map(() => 150 + next() * 2800);
    for (let k = 0; k < length && i < out.length; k++, i++) {
      const fade = Math.min(1, k / 160, (length - k) / 160);
      out[i] = level * fade * partials.reduce((sum, hz) => sum + Math.sin(2 * Math.PI * hz * k / RATE), 0) / 3 + (next() - 0.5) * 0.01;
    }
  }
  return out;
}

/** A 16-bit mono WAV of one episode's audio. */
export function introEpisodeWAV(id) {
  const plan = introPlan(id), n = Number(id.split('-').at(-1));
  const audio = programme(INTRO_RUNTIME, 1000 + n, 0.2);
  audio.set(programme(plan.length, 99, 0.3), plan.intro * RATE);
  audio.set(programme(plan.length, 77, 0.3), plan.credits * RATE);
  const data = Buffer.alloc(audio.length * 2);
  audio.forEach((value, index) => data.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(value * 32767))), index * 2));
  const header = Buffer.alloc(44);
  header.write('RIFF', 0); header.writeUInt32LE(36 + data.length, 4); header.write('WAVE', 8); header.write('fmt ', 12);
  header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20); header.writeUInt16LE(1, 22); header.writeUInt32LE(RATE, 24);
  header.writeUInt32LE(RATE * 2, 28); header.writeUInt16LE(2, 32); header.writeUInt16LE(16, 34); header.write('data', 36); header.writeUInt32LE(data.length, 40);
  return Buffer.concat([header, data]);
}
