import { ApiError, type JellyfinAPI } from './api.ts';
import { fingerprint, nextTask, SAMPLE_RATE, sharedRun, type Fingerprint, type Pause } from './audio-fingerprint.ts';
import { type Markers } from './playback-extras.ts';
import { type MediaItem, TICKS } from './types.ts';

// Finds intros and credits when the server has no markers for them: the opening (or closing) minutes of an
// episode and of a neighboring episode are fingerprinted, and the longest stretch of audio they share is the
// theme. Jellyfin transcodes any video's audio on request; 32 kbps mono MP3 keeps ten minutes near 2.4 MB.
//
// The audio request carries its own play session id and no device id. Jellyfin stops transcodes by play
// session id, so stopping or seeking the video never ends the scan and the scan never ends the video, and a
// request with no device id leaves the session's transcoding details on the dashboard as they were.

const BITRATE = 32_000;
const INTRO_MIN = 15;
const INTRO_MAX = 150;
const CREDITS_MIN = 15;
const DAY = 86_400_000;
const FOUND_DAYS = 180;
const MISSING_DAYS = 14;
const STORE_KEY = 'reel.markers.v1';
const STORE_LIMIT = 600;
const PRINT_LIMIT = 8;
const STALL_MS = 20_000;

type Part = 'head' | 'tail';
type AudioAPI = Pick<JellyfinAPI, 'request' | 'server'>;
export type Decoder = (bytes: Uint8Array, signal: AbortSignal) => Promise<Float32Array>;
interface StorageLike { getItem(key: string): string | null; setItem(key: string, value: string): void }
// i: the intro, or 0 when none was found. c: where the credits start, or 0 when none were found. t: when saved.
interface Entry { i?: [number, number] | 0; c?: number | 0; t: number }

const cancelled = () => new DOMException('Cancelled', 'AbortError');
const isAbort = (error: unknown) => error instanceof DOMException && error.name === 'AbortError';

function runtime(item: MediaItem): number | undefined {
  const ticks = item.RunTimeTicks;
  return typeof ticks === 'number' && Number.isFinite(ticks) && ticks > 0 ? ticks / TICKS : undefined;
}

/** The opening minutes to scan: 30% of the episode, between three and ten minutes. */
export function headWindow(item: MediaItem): { start: number; seconds: number } {
  const length = runtime(item);
  return { start: 0, seconds: length ? Math.min(length, Math.max(180, Math.min(600, length * 0.3))) : 600 };
}

/** The closing minutes to scan: 20% of the episode, between 90 seconds and five minutes. */
export function tailWindow(item: MediaItem): { start: number; seconds: number } | undefined {
  const length = runtime(item);
  if (!length || length < 300) return undefined;
  const seconds = Math.max(90, Math.min(300, length * 0.2));
  return { start: length - seconds, seconds };
}

export class MarkerStore {
  private entries: Record<string, Entry> = {};
  private readonly storage?: StorageLike;
  constructor(storage?: StorageLike) {
    this.storage = storage;
    try {
      const saved = JSON.parse(storage?.getItem(STORE_KEY) ?? '{}');
      if (saved && typeof saved === 'object' && !Array.isArray(saved)) {
        for (const [key, value] of Object.entries(saved as Record<string, unknown>)) if (validEntry(value)) this.entries[key] = value;
      }
    } catch { this.entries = {}; }
  }
  get(key: string, now = Date.now()): Entry | undefined {
    const entry = this.entries[key];
    if (!entry) return undefined;
    const found = Array.isArray(entry.i) || typeof entry.c === 'number' && entry.c > 0;
    return now - entry.t > (found ? FOUND_DAYS : MISSING_DAYS) * DAY ? undefined : entry;
  }
  update(key: string, change: Omit<Entry, 't'>, now = Date.now()): void {
    this.entries[key] = { ...this.get(key, now), ...change, t: now };
    const keys = Object.keys(this.entries);
    if (keys.length > STORE_LIMIT) {
      keys.sort((a, b) => this.entries[a].t - this.entries[b].t).slice(0, keys.length - STORE_LIMIT).forEach(old => delete this.entries[old]);
    }
    this.save();
  }
  /** Drops what was learned under an account, when it signs out or is removed. */
  forget(accountId: string): void {
    const prefix = accountId + '|';
    for (const key of Object.keys(this.entries)) if (key.startsWith(prefix)) delete this.entries[key];
    this.save();
  }
  private save(): void {
    try { this.storage?.setItem(STORE_KEY, JSON.stringify(this.entries)); } catch { /* Markers last for this session only. */ }
  }
}

function validEntry(value: unknown): value is Entry {
  if (!value || typeof value !== 'object') return false;
  const entry = value as Record<string, unknown>;
  const seconds = (n: unknown) => typeof n === 'number' && Number.isFinite(n) && n >= 0 && n < 86_400;
  return typeof entry.t === 'number' && Number.isFinite(entry.t) && entry.t > 0
    && (entry.i === undefined || entry.i === 0 || Array.isArray(entry.i) && entry.i.length === 2 && seconds(entry.i[0]) && seconds(entry.i[1]) && entry.i[1] > entry.i[0])
    && (entry.c === undefined || seconds(entry.c));
}

const LAYER3_KBPS = { 1: [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320], 2: [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160] };
const LAYER3_RATES: Record<number, number[]> = { 3: [44100, 48000, 32000], 2: [22050, 24000, 16000], 0: [11025, 12000, 8000] };

// The length of the MPEG Layer III frame whose header starts at `at`, or 0 when no such header is there.
export function frameLength(bytes: Uint8Array, at: number): number {
  if (at + 4 > bytes.length || bytes[at] !== 0xff || (bytes[at + 1] & 0xe0) !== 0xe0 || ((bytes[at + 1] >> 1) & 3) !== 1) return 0;
  const version = (bytes[at + 1] >> 3) & 3, kbps = (version === 3 ? LAYER3_KBPS[1] : LAYER3_KBPS[2])[bytes[at + 2] >> 4], rate = LAYER3_RATES[version]?.[(bytes[at + 2] >> 2) & 3];
  if (!kbps || !rate) return 0;
  return Math.floor((version === 3 ? 144 : 72) * kbps * 1000 / rate) + ((bytes[at + 2] >> 1) & 1);
}

/** Cuts a partial MP3 frame off the end of a download stopped mid-stream. Some decoders refuse one. */
export function wholeFrames(bytes: Uint8Array): Uint8Array {
  let at = 0;
  if (bytes.length > 10 && bytes[0] === 0x49 && bytes[1] === 0x44 && bytes[2] === 0x33) {
    at = 10 + ((bytes[6] & 0x7f) << 21 | (bytes[7] & 0x7f) << 14 | (bytes[8] & 0x7f) << 7 | (bytes[9] & 0x7f));
  }
  if (!frameLength(bytes, at)) return bytes;
  // Step from frame to frame by each header's own length; bytes inside the audio that happen to look like a
  // header are never visited, so they cannot cut the stream short.
  for (let length = frameLength(bytes, at); length && at + length <= bytes.length; length = frameLength(bytes, at)) at += length;
  return bytes.subarray(0, at);
}

async function readPrefix(response: Response, limit: number, signal: AbortSignal): Promise<Uint8Array> {
  const reader = response.body?.getReader();
  if (!reader) throw new ApiError('The server returned no audio.');
  const chunks: Uint8Array[] = [];
  let size = 0, stalled = false, timer: ReturnType<typeof setTimeout> | undefined;
  const stop = () => { void reader.cancel().catch(() => undefined); };
  const watch = () => { clearTimeout(timer); timer = setTimeout(() => { stalled = true; stop(); }, STALL_MS); };
  signal.addEventListener('abort', stop, { once: true });
  try {
    watch();
    while (size < limit) {
      const part = await reader.read();
      if (signal.aborted) throw cancelled();
      if (stalled) throw new ApiError('The audio stopped loading.');
      if (part.done) break;
      chunks.push(part.value); size += part.value.byteLength; watch();
    }
  } finally { clearTimeout(timer); signal.removeEventListener('abort', stop); stop(); }
  const bytes = new Uint8Array(size);
  let at = 0;
  for (const chunk of chunks) { bytes.set(chunk, at); at += chunk.byteLength; }
  return bytes;
}

function scanSession(): string {
  const bytes = new Uint8Array(12);
  crypto.getRandomValues(bytes);
  return 'reel-scan-' + Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
}

/** Decodes with the browser's audio decoder, resampled to the fingerprint rate. Undefined where there is none. */
export function browserDecoder(): Decoder | undefined {
  const scope = globalThis as typeof globalThis & { webkitOfflineAudioContext?: typeof OfflineAudioContext };
  const Context = scope.OfflineAudioContext ?? scope.webkitOfflineAudioContext;
  if (typeof Context !== 'function') return undefined;
  return async (bytes, signal) => {
    const frames = wholeFrames(bytes), data = frames.slice().buffer;
    // Older engines only decode at higher rates; the fingerprint rate is reached by averaging afterwards.
    let context: OfflineAudioContext | undefined;
    for (const rate of [SAMPLE_RATE, 16_000, 22_050, 44_100]) { try { context = new Context(1, 1, rate); break; } catch { /* try the next rate */ } }
    if (!context) throw new ApiError('Audio cannot be decoded here.');
    const decoder = context;
    const audio = await new Promise<AudioBuffer>((resolve, reject) => {
      const result = decoder.decodeAudioData(data, resolve, reject) as Promise<AudioBuffer> | undefined;
      if (result && typeof result.then === 'function') result.then(resolve, reject);
    });
    if (signal.aborted) throw cancelled();
    const channels = Array.from({ length: audio.numberOfChannels }, (_, index) => audio.getChannelData(index));
    return resample(channels, audio.sampleRate);
  };
}

export function resample(channels: Float32Array[], rate: number): Float32Array {
  if (rate === SAMPLE_RATE && channels.length === 1) return channels[0];
  const ratio = rate / SAMPLE_RATE, length = Math.floor((channels[0]?.length ?? 0) / ratio), out = new Float32Array(length);
  for (let i = 0; i < length; i++) {
    const from = Math.floor(i * ratio), to = Math.max(from + 1, Math.floor((i + 1) * ratio));
    let sum = 0;
    for (const channel of channels) for (let k = from; k < to; k++) sum += channel[k];
    out[i] = sum / ((to - from) * channels.length);
  }
  return out;
}

export class MarkerDetector {
  readonly store: MarkerStore;
  private readonly decode: Decoder;
  private readonly pause: Pause;
  private readonly prints = new Map<string, Promise<Fingerprint | undefined>>();
  private readonly refused = new Set<string>();
  constructor(decode: Decoder, store: MarkerStore, pause: Pause = nextTask) { this.decode = decode; this.store = store; this.pause = pause; }

  /** What has already been found for this item, without scanning anything. */
  known(accountId: string, item: MediaItem): Markers {
    const entry = this.store.get(accountId + '|' + item.Id), length = runtime(item);
    const markers: Markers = {};
    if (entry && Array.isArray(entry.i) && (!length || entry.i[1] <= length)) markers.intro = { start: entry.i[0], end: entry.i[1] };
    if (entry && typeof entry.c === 'number' && entry.c > 0 && (!length || entry.c < length)) markers.credits = entry.c;
    return markers;
  }

  /** Scans this episode against its neighbors for whatever is not yet known, and returns all that is. */
  async detect(api: AudioAPI, accountId: string, item: MediaItem, neighbors: MediaItem[], want: { intro: boolean; credits: boolean }, signal: AbortSignal): Promise<Markers> {
    const entry = this.store.get(accountId + '|' + item.Id);
    const others = neighbors.filter(other => other.Id !== item.Id && other.Type === 'Episode').slice(0, 2);
    if (item.Type === 'Episode' && others.length && !this.refused.has(api.server)) {
      if (want.intro && entry?.i === undefined) await this.compare(api, accountId, item, others, 'head', signal);
      if (want.credits && entry?.c === undefined && tailWindow(item)) await this.compare(api, accountId, item, others.filter(other => tailWindow(other)), 'tail', signal);
    }
    if (signal.aborted) throw cancelled();
    return this.known(accountId, item);
  }

  private async compare(api: AudioAPI, accountId: string, item: MediaItem, others: MediaItem[], part: Part, signal: AbortSignal): Promise<void> {
    if (!others.length) return;
    // Neighbors already fingerprinted this session come first: comparing with them downloads nothing more.
    const ordered = [...others].sort((a, b) => Number(this.prints.has(this.key(api, b, part))) - Number(this.prints.has(this.key(api, a, part))));
    const mine = await this.print(api, item, part, signal);
    if (!mine) return;
    let compared = false;
    for (const other of ordered) {
      const theirs = await this.print(api, other, part, signal);
      if (!theirs) continue;
      compared = true;
      const run = await sharedRun(mine, theirs, part === 'head' ? INTRO_MIN : CREDITS_MIN, part === 'head' ? INTRO_MAX : Infinity, this.pause);
      if (signal.aborted) throw cancelled();
      if (!run) continue;
      const otherKey = accountId + '|' + other.Id, otherEntry = this.store.get(otherKey);
      if (part === 'head') {
        this.store.update(accountId + '|' + item.Id, { i: [run.aStart, run.aEnd] });
        if (otherEntry?.i === undefined) this.store.update(otherKey, { i: [run.bStart, run.bEnd] });
        return;
      }
      // The credits must leave at least ten seconds; a match in the last moments is a closing logo.
      const mineStart = tailWindow(item)!.start + run.aStart, theirStart = tailWindow(other)!.start + run.bStart;
      this.store.update(accountId + '|' + item.Id, { c: runtime(item)! - mineStart >= 10 ? mineStart : 0 });
      if (otherEntry?.c === undefined && runtime(other)! - theirStart >= 10) this.store.update(otherKey, { c: theirStart });
      return;
    }
    if (compared) this.store.update(accountId + '|' + item.Id, part === 'head' ? { i: 0 } : { c: 0 });
  }

  private key(api: AudioAPI, item: MediaItem, part: Part): string { return api.server + '|' + item.Id + '|' + part; }

  private async print(api: AudioAPI, item: MediaItem, part: Part, signal: AbortSignal): Promise<Fingerprint | undefined> {
    const key = this.key(api, item, part);
    for (let attempt = 0; attempt < 2; attempt++) {
      let pending = this.prints.get(key);
      if (pending) { this.prints.delete(key); this.prints.set(key, pending); }
      else {
        pending = this.scan(api, item, part, signal);
        this.prints.set(key, pending);
        while (this.prints.size > PRINT_LIMIT) this.prints.delete(this.prints.keys().next().value!);
        pending.catch(() => { if (this.prints.get(key) === pending) this.prints.delete(key); });
      }
      try { return await pending; }
      catch (error) {
        // A scan started by playback that has since ended was cancelled; start again for this one.
        if (isAbort(error) && !signal.aborted) continue;
        throw error;
      }
    }
    return undefined;
  }

  private async scan(api: AudioAPI, item: MediaItem, part: Part, signal: AbortSignal): Promise<Fingerprint | undefined> {
    const window = part === 'head' ? headWindow(item) : tailWindow(item);
    if (!window || this.refused.has(api.server)) return undefined;
    let response: Response;
    try {
      response = await api.request<Response>(`Audio/${encodeURIComponent(item.Id)}/stream.mp3`, { raw: true, signal, query: {
        audioCodec: 'mp3', audioChannels: 1, maxAudioChannels: 1, audioSampleRate: 16_000, audioBitRate: BITRATE,
        startTimeTicks: window.start > 0 ? Math.round(window.start * TICKS) : undefined,
        mediaSourceId: item.MediaSources?.[0]?.Id, playSessionId: scanSession()
      } });
    } catch (error) {
      if (signal.aborted) throw cancelled();
      // A server that will not transcode audio for this account is not asked again this session.
      if (error instanceof ApiError && [400, 401, 403, 415].includes(error.status)) this.refused.add(api.server);
      // A dropped connection is tried again next time; any other answer stands for this session.
      if (error instanceof ApiError && error.status !== 0) return undefined;
      throw error;
    }
    try {
      const bytes = await readPrefix(response, Math.ceil(window.seconds * BITRATE / 8) + 16_384, signal);
      return await fingerprint(await this.decode(bytes, signal), this.pause, signal);
    } catch (error) {
      if (signal.aborted || isAbort(error)) throw cancelled();
      return undefined;
    }
  }
}
