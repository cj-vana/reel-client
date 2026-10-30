import { playbackProfile, probeEngine, type EngineCapabilities } from './media-capabilities.ts';
import { type Account, type ItemPage, type MediaItem, type MediaSource, type PlaybackInfo, TICKS } from './types.ts';

// poster: 2:3 cover. landscape: a 16:9 card. backdrop: full-bleed background art.
export type ArtworkShape = 'poster' | 'landscape' | 'backdrop';

export class ApiError extends Error {
  readonly status: number;
  constructor(message: string, status = 0) { super(message); this.name = 'ApiError'; this.status = status; }
}

export async function readBlob(response: Response, maxBytes: number, signal?: AbortSignal): Promise<Blob> {
  const reader = response.body?.getReader();
  if (!reader) throw new ApiError('The server returned an empty file.');
  let failure: Error | undefined;
  const cancel = (error: Error) => { if (!failure) { failure = error; void reader.cancel().catch(() => undefined); } };
  const onAbort = () => cancel(new DOMException('Cancelled', 'AbortError'));
  const timeout = setTimeout(() => cancel(new ApiError('The file stopped loading. Check your connection and try again.')), 18000);
  signal?.addEventListener('abort', onAbort, { once: true });
  const chunks: BlobPart[] = []; let bytes = 0;
  try {
    if (signal?.aborted) onAbort();
    if (Number(response.headers.get('content-length') ?? 0) > maxBytes) cancel(new ApiError('This file exceeds the browser memory limit.'));
    while (true) {
      if (failure) throw failure;
      const part = await reader.read();
      if (failure) throw failure;
      if (part.done) break;
      bytes += part.value.byteLength;
      if (bytes > maxBytes) { cancel(new ApiError('This file exceeds the browser memory limit.')); throw failure; }
      chunks.push(part.value);
    }
    return new Blob(chunks, { type: response.headers.get('content-type') ?? '' });
  } finally { clearTimeout(timeout); signal?.removeEventListener('abort', onAbort); reader.releaseLock(); }
}

export function isLoopback(host: string): boolean {
  return host === 'localhost' || host === '[::1]' || /^127\.(?:\d{1,3}\.){2}\d{1,3}$/.test(host);
}

export function normalizeServer(value: string): string {
  let url: URL;
  try { url = new URL(value.trim()); } catch { throw new ApiError('Enter a complete Jellyfin address, including https://.'); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) throw new ApiError('Use an HTTP or HTTPS server address without a username, query, or fragment.');
  const h = url.hostname.toLowerCase();
  const parts = h.split('.');
  const octets = parts.map(Number);
  const ip = parts.length === 4 && parts.every(p => /^\d{1,3}$/.test(p)) && octets.every(p => p >= 0 && p <= 255);
  const local = isLoopback(h) || h.endsWith('.local') || h.endsWith('.ts.net') || (ip && (octets[0] === 10 || octets[0] === 127 || octets[0] === 192 && octets[1] === 168 || octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31 || octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127));
  if (url.protocol === 'http:' && !local) throw new ApiError('Remote connections need HTTPS. HTTP is available on trusted local and Tailscale networks.');
  url.pathname = url.pathname.replace(/\/+$/, '');
  return url.toString().replace(/\/$/, '');
}

export function scopedURL(server: string, path: string): URL {
  const base = new URL(server);
  const root = base.pathname.replace(/\/+$/, '');
  let result: URL;
  if (/^(?:[a-z]+:)?\/\//i.test(path)) result = new URL(path, base);
  else {
    const part = path.replace(/^\/+/, '');
    const prefix = root.replace(/^\//, '');
    result = new URL(base.origin + '/' + (prefix && part !== prefix && !part.startsWith(prefix + '/') ? prefix + '/' : '') + part);
  }
  if (result.origin !== base.origin || result.username || result.password || (root && result.pathname !== root && !result.pathname.startsWith(root + '/'))) throw new ApiError('Jellyfin returned a resource outside this server connection.');
  return result;
}

function safeHeader(value: string): string { return value.replace(/["\\\x00-\x1f\x7f]/g, ''); }

export class JellyfinAPI {
  readonly server: string;
  readonly account: Account | null;
  readonly deviceId: string;
  readonly preview: boolean;
  readonly history: boolean;
  readonly historyPolicy?: () => boolean;
  constructor(account: Account | null, server: string, deviceId: string, preview = true, history = false, historyPolicy?: () => boolean) {
    this.account = account; this.server = normalizeServer(server); this.deviceId = deviceId; this.preview = preview; this.history = history;
    this.historyPolicy = historyPolicy;
  }
  get protected(): boolean { return this.preview && !isLoopback(new URL(this.server).hostname); }
  get recordsHistory(): boolean { return !this.protected && this.history && (this.historyPolicy?.() ?? true); }
  endpoint(path: string, query: Record<string, string | number | boolean | undefined> = {}): URL {
    const url = scopedURL(this.server, path);
    Object.entries(query).forEach(([key, value]) => { if (value !== undefined) url.searchParams.set(key, String(value)); });
    return url;
  }
  get authorization(): string {
    return `MediaBrowser Client="Reel", Device="Reel Web", DeviceId="${safeHeader(this.deviceId)}", Version="0.1.0"${this.account ? `, Token="${safeHeader(this.account.token)}"` : ''}`;
  }
  async request<T>(path: string, options: { query?: Record<string, string | number | boolean | undefined>; method?: string; body?: unknown; signal?: AbortSignal; raw?: boolean } = {}): Promise<T> {
    const method = options.method ?? 'GET';
    const route = path.split('?')[0].replace(/^\/+/, '').toLowerCase();
    const allowed = /^(users\/authenticatebyname|quickconnect\/initiate|users\/authenticatewithquickconnect|sessions\/logout|videos\/activeencodings|livestreams\/close)$/.test(route) || /^items\/[^/]+\/playbackinfo$/.test(route);
    const historyWrite = route.startsWith('sessions/playing');
    if (method !== 'GET' && method !== 'HEAD' && ((this.protected && !allowed) || historyWrite && !this.recordsHistory)) throw new ApiError('Protected preview is on. This action would change your server.');
    const controller = new AbortController();
    const onAbort = () => controller.abort();
    if (options.signal?.aborted) controller.abort();
    options.signal?.addEventListener('abort', onAbort, { once: true });
    const timeout = setTimeout(() => controller.abort(), 18000);
    try {
      const response = await fetch(this.endpoint(path, options.query), {
        method, redirect: 'error', credentials: 'omit', cache: 'no-store', referrerPolicy: 'no-referrer',
        signal: controller.signal,
        headers: { Authorization: this.authorization, Accept: options.raw ? '*/*' : 'application/json', ...(options.body !== undefined ? { 'Content-Type': 'application/json' } : {}) },
        body: options.body !== undefined ? JSON.stringify(options.body) : undefined
      });
      if (!response.ok) throw new ApiError(response.status === 401 || response.status === 403 ? 'Your sign-in expired or this account does not have permission. Open Servers to sign in again.' : `Jellyfin returned ${response.status}. Try again in a moment.`, response.status);
      if (options.raw) return response as T;
      if (response.status === 204 || response.headers.get('content-length') === '0') return undefined as T;
      return await response.json() as T;
    } catch (error) {
      if (error instanceof ApiError) throw error;
      if (options.signal?.aborted) throw new DOMException('Cancelled', 'AbortError');
      throw new ApiError('Your server could not be reached. Check Wi-Fi, Tailscale, and the server address. A web connection also needs Jellyfin CORS access.');
    } finally { clearTimeout(timeout); options.signal?.removeEventListener('abort', onAbort); }
  }
  async authenticate(username: string, password: string, remember: boolean, signal?: AbortSignal): Promise<Account> {
    const info = await this.request<{ ServerName: string }>('System/Info/Public', { signal });
    // A 401 here is a wrong username or password, not an expired session. A 403 (a disabled account, for
    // example) keeps the general permission text.
    const auth = await this.request<{ AccessToken: string; User: { Id: string; Name: string } }>('Users/AuthenticateByName', { method: 'POST', body: { Username: username.trim(), Pw: password }, signal })
      .catch((error: unknown) => {
        if (error instanceof ApiError && error.status === 401) throw new ApiError('That sign-in did not work. Check the username and password.', error.status);
        throw error;
      });
    if (typeof auth.AccessToken !== 'string' || !auth.AccessToken || typeof auth.User?.Id !== 'string' || !auth.User.Id || typeof auth.User.Name !== 'string') throw new ApiError('The server did not provide a valid sign-in.');
    return { id: this.server + '|' + auth.User.Id, server: this.server, token: auth.AccessToken, userId: auth.User.Id, name: auth.User.Name, serverName: typeof info.ServerName === 'string' ? info.ServerName : new URL(this.server).host, remember };
  }
  page(path: string, query: Record<string, string | number | boolean | undefined> = {}, signal?: AbortSignal): Promise<ItemPage> {
    return this.request(path, { query: { userId: this.account?.userId, fields: 'Overview,Genres', enableUserData: true, ...query }, signal });
  }
  item(id: string, signal?: AbortSignal): Promise<MediaItem> {
    return this.request('Items/' + encodeURIComponent(id), { query: { userId: this.account?.userId, fields: 'Overview,Genres,MediaSources,People,Chapters', enableUserData: true }, signal });
  }
  latest(type: string, signal?: AbortSignal): Promise<MediaItem[]> {
    return this.request('Items/Latest', { query: { userId: this.account?.userId, fields: 'Overview,Genres', includeItemTypes: type, groupItems: type === 'Episode' ? false : undefined, limit: 18, enableUserData: true }, signal });
  }
  async recentEpisodes(signal?: AbortSignal): Promise<ItemPage> {
    const page = await this.page('Items', {
      recursive: true, includeItemTypes: 'Episode', sortBy: 'DateCreated', sortOrder: 'Descending',
      limit: 18, fields: 'Overview,Genres,DateCreated', enableTotalRecordCount: false
    }, signal);
    if (!Array.isArray(page?.Items) || page.Items.some(item => !item || item.Type !== 'Episode' || typeof item.Id !== 'string' || !item.Id || typeof item.Name !== 'string')) {
      throw new ApiError('Jellyfin returned an invalid episode shelf. Try again in a moment.');
    }
    return page;
  }
  imageURL(item: MediaItem, shape: ArtworkShape = 'poster', width = 600): URL {
    let id = item.Id, type = 'Primary', tag = item.ImageTags?.Primary;
    // An episode's own Primary image is its 16:9 still, so landscape cards use it before the series backdrop.
    const ownStill = shape === 'landscape' && item.Type === 'Episode' && Boolean(tag);
    if (shape === 'poster') {
      if (item.Type === 'Episode' && item.SeriesId && item.SeriesPrimaryImageTag) { id = item.SeriesId; tag = item.SeriesPrimaryImageTag; }
    } else if (!ownStill) {
      if (item.BackdropImageTags?.[0]) { type = 'Backdrop'; tag = item.BackdropImageTags[0]; }
      else if (item.ParentBackdropItemId && item.ParentBackdropImageTags?.[0]) { id = item.ParentBackdropItemId; type = 'Backdrop'; tag = item.ParentBackdropImageTags[0]; }
    }
    return this.endpoint(`Items/${encodeURIComponent(id)}/Images/${type}`, { maxWidth: width, quality: 85, tag });
  }
  async image(item: MediaItem, shape: ArtworkShape = 'poster', width = 600, signal?: AbortSignal): Promise<Blob> {
    const url = this.imageURL(item, shape, width);
    const root = new URL(this.server).pathname.replace(/\/+$/, '');
    const response = await this.request<Response>(url.pathname.slice(root.length) + url.search, { raw: true, signal });
    const blob = await readBlob(response, 8 * 1024 * 1024, signal);
    if (!blob.type.startsWith('image/') || blob.size > 8 * 1024 * 1024) throw new ApiError('Artwork could not be loaded.');
    return blob;
  }
  async playback(item: MediaItem, options: { bitrate: number; audio?: number; subtitle?: number; source?: string; fallback?: 'audio' | 'video'; capabilities?: EngineCapabilities; signal?: AbortSignal }): Promise<PlaybackInfo> {
    const cap = options.capabilities ?? probeEngine(() => '');
    const profile = playbackProfile(cap, options.bitrate, options.fallback);
    const copyVideo = options.fallback !== 'video' && cap.mp4Video.some(codec => ['h264', 'hevc'].includes(codec));
    return this.request(`Items/${encodeURIComponent(item.Id)}/PlaybackInfo`, { method: 'POST', signal: options.signal, body: {
      UserId: this.account?.userId, DeviceProfile: profile, MaxStreamingBitrate: options.bitrate, StartTimeTicks: 0,
      EnableDirectPlay: !options.fallback && options.audio === undefined && options.subtitle === undefined,
      EnableDirectStream: false, EnableTranscoding: true, AllowVideoStreamCopy: copyVideo,
      AllowAudioStreamCopy: !options.fallback && cap.nativeHLS, AutoOpenLiveStream: true,
      MediaSourceId: options.source ?? item.MediaSources?.[0]?.Id, AudioStreamIndex: options.audio, SubtitleStreamIndex: options.subtitle
    } });
  }
  streamURL(item: MediaItem, source: MediaSource, sessionId: string): { url: string; method: 'DirectPlay' | 'Transcode' } {
    const audio = item.MediaType === 'Audio' || ['Audio', 'MusicAlbum', 'AudioBook'].includes(item.Type ?? '');
    const method = source.SupportsDirectPlay ? 'DirectPlay' : 'Transcode';
    const url = source.SupportsDirectPlay ? this.endpoint(`${audio ? 'Audio' : 'Videos'}/${encodeURIComponent(item.Id)}/stream`, { static: true, mediaSourceId: source.Id, playSessionId: sessionId, deviceId: this.deviceId }) : source.TranscodingUrl ? scopedURL(this.server, source.TranscodingUrl) : null;
    if (!url) throw new ApiError('Jellyfin could not prepare a playable stream.');
    Array.from(url.searchParams.keys()).forEach(key => { if (['apikey', 'api_key'].includes(key.toLowerCase())) url.searchParams.delete(key); });
    url.searchParams.set('ApiKey', this.account?.token ?? '');
    return { url: url.toString(), method };
  }
  async favorite(item: MediaItem, value: boolean): Promise<void> { await this.request(`UserFavoriteItems/${encodeURIComponent(item.Id)}`, { method: value ? 'POST' : 'DELETE', query: { userId: this.account?.userId } }); }
  async watched(item: MediaItem, value: boolean): Promise<void> { await this.request(`UserPlayedItems/${encodeURIComponent(item.Id)}`, { method: value ? 'POST' : 'DELETE', query: { userId: this.account?.userId } }); }
  async report(item: MediaItem, source: MediaSource, sessionId: string, method: string, event: string, seconds: number, paused: boolean, signal?: AbortSignal): Promise<void> {
    if (!this.recordsHistory) return;
    await this.request('Sessions/Playing' + event, { method: 'POST', signal, body: { ItemId: item.Id, MediaSourceId: source.Id, PlaySessionId: sessionId, PositionTicks: Math.floor(Math.max(0, seconds) * TICKS), IsPaused: paused, CanSeek: true, PlayMethod: method } });
  }
  async cleanup(sessionId: string, source?: MediaSource): Promise<void> {
    const operations = [this.request('Videos/ActiveEncodings', { method: 'DELETE', query: { deviceId: this.deviceId, playSessionId: sessionId } })];
    if (source?.LiveStreamId) operations.push(this.request('LiveStreams/Close', { method: 'POST', query: { liveStreamId: source.LiveStreamId } }));
    const results = await Promise.allSettled(operations);
    const failed = results.find(result => result.status === 'rejected');
    if (failed?.status === 'rejected') throw failed.reason;
  }
}
