import { createHash, randomUUID } from 'node:crypto';
import { mkdir, open, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

// Converted downloads for watching without a connection. Jellyfin converts the title to H.264 and AAC in HLS at
// the chosen size; every segment is saved under the app's data folder, and the page plays them back through the
// reel: protocol. The sizes match the iPhone and iPad app (DownloadSize in apps/apple/Reel/Core/HLSDownloads.swift).
export const SIZES = Object.freeze({
  high: Object.freeze({ maxWidth: 1920, maxHeight: 1080, videoBitRate: 6_000_000 }),
  standard: Object.freeze({ maxWidth: 1280, maxHeight: 720, videoBitRate: 1_872_000 }),
  small: Object.freeze({ maxWidth: 854, maxHeight: 480, videoBitRate: 900_000 })
});
export const AUDIO_BITRATE = 128_000;
/** A problem worth showing as it is; anything else becomes a general message. */
export class DownloadError extends Error {}
const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const FILE = /^(index\.m3u8|\d{1,5}\.ts|art\.jpg)$/;
const SEGMENT_LIMIT = 20_000;
const text = (value, max) => typeof value === 'string' && value.length > 0 && value.length <= max && !/[\x00-\x1f\x7f]/.test(value);
export const accountKey = accountId => createHash('sha256').update(String(accountId)).digest('hex');

/** The server origin and path a download may read from, or undefined for anything else. */
export function serverRoot(value) {
  try {
    const url = new URL(value);
    if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) return undefined;
    return url.toString().replace(/\/+$/, '');
  } catch { return undefined; }
}

/** A URL from a playlist, resolved against it, as long as it stays on the server the download started from. */
export function onServer(reference, base, root) {
  const url = new URL(reference, base), rootURL = new URL(root), path = rootURL.pathname.replace(/\/+$/, '');
  if (url.origin !== rootURL.origin || url.username || url.password || path && url.pathname !== path && !url.pathname.startsWith(path + '/')) throw new DownloadError('The playlist pointed outside this server.');
  return url;
}

/** The first variant of a master playlist. */
export function variantOf(master, base, root) {
  const line = master.split(/\r?\n/).map(value => value.trim()).find(value => value && !value.startsWith('#'));
  if (!line) throw new DownloadError('Your server returned an empty playlist.');
  return onServer(line, base, root);
}

/** The segments of a complete media playlist, with their durations. */
export function segmentsOf(media, base, root) {
  const lines = media.split(/\r?\n/).map(value => value.trim()), segments = [];
  if (lines.some(line => line.startsWith('#EXT-X-MAP') || line.startsWith('#EXT-X-KEY'))) throw new DownloadError('Your server converted this title in a way downloads do not support.');
  let duration;
  for (const line of lines) {
    if (line.startsWith('#EXTINF:')) duration = Number.parseFloat(line.slice(8));
    else if (line && !line.startsWith('#')) {
      if (!Number.isFinite(duration) || duration <= 0) throw new DownloadError('Your server returned a playlist Reel could not read.');
      segments.push({ url: onServer(line, base, root), duration }); duration = undefined;
    }
  }
  if (!segments.length || segments.length > SEGMENT_LIMIT || !lines.includes('#EXT-X-ENDLIST')) throw new DownloadError('Your server did not return a complete playlist.');
  return segments;
}

/** The playlist saved beside the segments: the same durations, local file names. */
export function localPlaylist(segments) {
  const target = Math.ceil(Math.max(...segments.map(segment => segment.duration)));
  return ['#EXTM3U', '#EXT-X-VERSION:3', '#EXT-X-PLAYLIST-TYPE:VOD', `#EXT-X-TARGETDURATION:${target}`, '#EXT-X-MEDIA-SEQUENCE:0',
    ...segments.flatMap((segment, index) => [`#EXTINF:${segment.duration.toFixed(6)},`, `${index}.ts`]), '#EXT-X-ENDLIST', ''].join('\n');
}

export function validRequest(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const keys = ['accountId', 'server', 'token', 'userId', 'deviceId', 'itemId', 'mediaSourceId', 'size', 'title', 'subtitle', 'runtime'];
  if (Object.keys(value).length !== keys.length || !keys.every(key => Object.hasOwn(value, key))) return false;
  return text(value.accountId, 2600) && !!serverRoot(value.server) && text(value.token, 512) && text(value.userId, 128) && text(value.deviceId, 128)
    && /^[A-Za-z0-9-]{1,64}$/.test(value.itemId) && /^[A-Za-z0-9-]{1,64}$/.test(value.mediaSourceId) && Object.hasOwn(SIZES, value.size)
    && text(value.title, 300) && (value.subtitle === '' || text(value.subtitle, 300)) && Number.isFinite(value.runtime) && value.runtime >= 0 && value.runtime < 86_400;
}

const publicEntry = entry => ({ id: entry.id, itemId: entry.itemId, title: entry.title, subtitle: entry.subtitle, runtime: entry.runtime, size: entry.size,
  state: entry.state, progress: entry.progress, bytes: entry.bytes, position: entry.position, error: entry.error ?? null, art: entry.art === true, createdAt: entry.createdAt });

export class OfflineDownloads {
  #root; #fetch; #now; #entries = []; #listeners = new Set(); #saving = Promise.resolve(); #active = new Map(); #queue = []; #running = false;

  constructor({ root, fetch, now = Date.now }) { this.#root = root; this.#fetch = fetch; this.#now = now; }

  async load() {
    await mkdir(this.#root, { recursive: true, mode: 0o700 });
    try {
      const saved = JSON.parse(await readFile(join(this.#root, 'index.json'), 'utf8'));
      if (Array.isArray(saved)) this.#entries = saved.filter(entry => entry && ID.test(entry.id) && /^[a-f0-9]{64}$/.test(entry.account) && Object.hasOwn(SIZES, entry.size));
    } catch { this.#entries = []; }
    // A download cut off by quitting cannot pick up where it stopped; it is offered again.
    for (const entry of this.#entries) if (entry.state === 'downloading' || entry.state === 'queued') Object.assign(entry, { state: 'failed', error: 'Reel closed before this finished. Download it again.' });
    await this.#save();
  }

  subscribe(listener) { this.#listeners.add(listener); return () => this.#listeners.delete(listener); }
  /** Resolves once no download is running and the index is written. */
  async idle() { while (this.#running) await new Promise(resolve => setTimeout(resolve, 10)); await this.#saving; }
  list(accountId) { const account = accountKey(accountId); return this.#entries.filter(entry => entry.account === account).map(publicEntry); }

  async start(request) {
    if (!validRequest(request)) throw new Error('invalid');
    const account = accountKey(request.accountId);
    const existing = this.#entries.find(entry => entry.account === account && entry.itemId === request.itemId);
    if (existing) await this.remove(request.accountId, existing.id);
    const entry = { id: randomUUID(), account, itemId: request.itemId, title: request.title, subtitle: request.subtitle, runtime: request.runtime, size: request.size,
      state: 'queued', progress: 0, bytes: 0, position: 0, error: null, art: false, createdAt: this.#now() };
    this.#entries.push(entry);
    this.#queue.push({ entry, request });
    await this.#save();
    const queued = publicEntry(entry);
    void this.#drain();
    return queued;
  }

  async remove(accountId, id) {
    const entry = this.#entries.find(value => value.id === id && value.account === accountKey(accountId));
    if (!entry) return false;
    this.#queue = this.#queue.filter(job => job.entry !== entry);
    this.#active.get(entry.id)?.abort();
    this.#entries = this.#entries.filter(value => value !== entry);
    await rm(join(this.#root, entry.id), { recursive: true, force: true });
    await this.#save();
    return true;
  }

  /** Removes every download made under an account, when it signs out. */
  async forget(accountId) {
    const account = accountKey(accountId);
    for (const entry of this.#entries.filter(value => value.account === account)) await this.remove(accountId, entry.id);
  }

  async setPosition(accountId, id, seconds) {
    const entry = this.#entries.find(value => value.id === id && value.account === accountKey(accountId));
    if (!entry || !Number.isFinite(seconds) || seconds < 0 || seconds > 86_400) return false;
    entry.position = Math.round(seconds); await this.#save();
    return true;
  }

  /** The file a page asks for, from a finished download only. */
  file(id, name) {
    const entry = this.#entries.find(value => value.id === id);
    if (!entry || entry.state !== 'complete' || !FILE.test(name) || name === 'art.jpg' && !entry.art) return undefined;
    return join(this.#root, entry.id, name);
  }

  async #drain() {
    if (this.#running) return;
    this.#running = true;
    try {
      while (this.#queue.length) {
        const { entry, request } = this.#queue.shift();
        if (!this.#entries.includes(entry)) continue;
        await this.#download(entry, request);
      }
    } finally { this.#running = false; }
  }

  async #download(entry, request) {
    const controller = new AbortController(), folder = join(this.#root, entry.id), root = serverRoot(request.server);
    const session = 'reel-download-' + randomUUID().replaceAll('-', '');
    const headers = { Authorization: `MediaBrowser Client="Reel", Device="Reel Desktop", DeviceId="${request.deviceId.replace(/["\\]/g, '')}", Version="1.0.0", Token="${request.token.replace(/["\\]/g, '')}"` };
    const get = async url => {
      const response = await this.#fetch(url.toString(), { headers, signal: controller.signal, redirect: 'error' });
      if (!response.ok) throw new DownloadError(response.status === 401 || response.status === 403 ? 'Your server did not allow this download. Sign in again, or ask its administrator.' : `Your server answered ${response.status}.`);
      return response;
    };
    this.#active.set(entry.id, controller);
    entry.state = 'downloading'; entry.error = null; this.#emit(); await this.#save();
    try {
      await mkdir(folder, { recursive: true, mode: 0o700 });
      const size = SIZES[request.size];
      const master = onServer(`Videos/${encodeURIComponent(request.itemId)}/master.m3u8`, root + '/', root);
      for (const [key, value] of Object.entries({ MediaSourceId: request.mediaSourceId, VideoCodec: 'h264', AudioCodec: 'aac', MaxWidth: size.maxWidth, MaxHeight: size.maxHeight,
        VideoBitRate: size.videoBitRate, AudioBitRate: AUDIO_BITRATE, MaxAudioChannels: 2, TranscodingMaxAudioChannels: 2, SegmentContainer: 'ts', SegmentLength: 6, MinSegments: 1,
        BreakOnNonKeyFrames: false, AllowVideoStreamCopy: false, AllowAudioStreamCopy: false, EnableAdaptiveBitrateStreaming: false, Context: 'Static', SubtitleMethod: 'Drop',
        PlaySessionId: session, DeviceId: request.deviceId })) master.searchParams.set(key, String(value));
      const variant = variantOf(await (await get(master)).text(), master, root);
      const segments = segmentsOf(await (await get(variant)).text(), variant, root);
      for (const [index, segment] of segments.entries()) {
        for (let attempt = 1; ; attempt++) {
          try { entry.bytes += await this.#saveSegment(await get(segment.url), join(folder, index + '.ts'), controller.signal); break; }
          catch (error) { if (controller.signal.aborted || attempt === 3) throw error; }
        }
        entry.progress = (index + 1) / segments.length; this.#emit();
      }
      await writeFile(join(folder, 'index.m3u8'), localPlaylist(segments), { mode: 0o600 });
      try {
        const art = onServer(`Items/${encodeURIComponent(request.itemId)}/Images/Primary`, root + '/', root);
        art.searchParams.set('maxWidth', '480'); art.searchParams.set('quality', '85');
        await this.#saveSegment(await get(art), join(folder, 'art.jpg'), controller.signal); entry.art = true;
      } catch { /* Artwork is optional; the list shows the title without it. */ }
      Object.assign(entry, { state: 'complete', progress: 1 });
    } catch (error) {
      if (!this.#entries.includes(entry)) return;
      Object.assign(entry, { state: 'failed', error: controller.signal.aborted ? 'Cancelled.' : error instanceof DownloadError ? error.message : 'The download stopped. Check your connection and try again.' });
      await rm(folder, { recursive: true, force: true });
    } finally {
      this.#active.delete(entry.id);
      // The server keeps converting until told the session is over.
      const stop = onServer('Videos/ActiveEncodings', root + '/', root);
      stop.searchParams.set('deviceId', request.deviceId); stop.searchParams.set('playSessionId', session);
      void this.#fetch(stop.toString(), { method: 'DELETE', headers, redirect: 'error' }).catch(() => {});
      if (this.#entries.includes(entry)) { this.#emit(); await this.#save(); }
    }
  }

  async #saveSegment(response, path, signal) {
    const partial = path + '.part', file = await open(partial, 'w', 0o600);
    let bytes = 0;
    try {
      for await (const chunk of response.body) {
        if (signal.aborted) throw new Error('Cancelled');
        await file.write(chunk); bytes += chunk.byteLength;
      }
    } finally { await file.close(); }
    await rename(partial, path);
    return bytes;
  }

  #emit() { for (const listener of this.#listeners) { try { listener(); } catch { /* A closed window cannot stop downloads. */ } } }
  #save() {
    const data = JSON.stringify(this.#entries), path = join(this.#root, 'index.json');
    this.#saving = this.#saving.then(async () => { await writeFile(path + '.tmp', data, { mode: 0o600 }); await rename(path + '.tmp', path); }).catch(() => {});
    return this.#saving;
  }
}
