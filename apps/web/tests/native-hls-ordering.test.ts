import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { setImmediate as settle } from 'node:timers/promises';
import { JellyfinAPI } from '../src/api.ts';
import { ReelPlayer } from '../src/player.ts';
import type { Account, MediaItem, PlaybackInfo } from '../src/types.ts';

class NativeVideo extends EventTarget {
  playsInline = false; preload = ''; paused = true; ended = false; duration = 7808.852; seeking = false;
  src = ''; value = 0; playCalls = 0; writes: number[] = []; events: string[] = [];
  seekMode: 'pending' | 'settled' | 'throw' = 'pending'; rejectPlay = false;
  onSeek?: () => void;
  handlers = new Map<string, Set<EventListenerOrEventListenerObject>>();
  get currentTime(): number { return this.value; }
  set currentTime(value: number) {
    if (this.seekMode === 'throw') throw new Error('Synthetic setter rejection');
    this.value = value; this.writes.push(value); this.seeking = true; this.events.push('assign');
    this.onSeek?.();
    if (this.seekMode === 'settled') { this.seeking = false; this.emit('seeked'); }
  }
  override addEventListener(type: string, listener: EventListenerOrEventListenerObject | null, options?: AddEventListenerOptions | boolean): void {
    super.addEventListener(type, listener, options);
    if (listener) { const set = this.handlers.get(type) ?? new Set(); set.add(listener); this.handlers.set(type, set); }
  }
  override removeEventListener(type: string, listener: EventListenerOrEventListenerObject | null, options?: EventListenerOptions | boolean): void {
    super.removeEventListener(type, listener, options); if (listener) this.handlers.get(type)?.delete(listener);
  }
  snapshot(): Map<string, EventListenerOrEventListenerObject[]> { return new Map([...this.handlers].map(([key, listeners]) => [key, [...listeners]])); }
  stale(snapshot: Map<string, EventListenerOrEventListenerObject[]>, names: string[]): void {
    for (const name of names) for (const listener of snapshot.get(name) ?? []) {
      if (typeof listener === 'function') listener.call(this, new Event(name)); else listener.handleEvent(new Event(name));
    }
  }
  setAttribute(): void {}
  removeAttribute(name: string): void { if (name === 'src') this.src = ''; }
  pause(): void { this.paused = true; }
  play(): Promise<void> {
    this.playCalls++;
    if (this.rejectPlay) return Promise.reject(new Error('Synthetic autoplay denied'));
    this.paused = false; this.emit('play'); this.emit('playing'); return Promise.resolve();
  }
  load(): void { if (!this.src) { this.value = 0; this.seeking = false; this.ended = false; } }
  canPlayType(): string { return 'probably'; }
  emit(name: string): void { this.events.push(name); this.dispatchEvent(new Event(name)); }
  settleSeek(): void { this.seeking = false; this.emit('seeked'); }
}
const item: MediaItem = { Id: 'synthetic-title', Name: 'Synthetic title', UserData: { PlaybackPositionTicks: 13_990_000 } };
type Call = { path: string; query: Record<string, string>; method: string; body?: Record<string, unknown>; auth: string };
function connection(id = 'owned', history = false, remote = false): JellyfinAPI {
  const server = remote ? 'https://media.example/jellyfin' : 'http://127.0.0.1:18771/jellyfin';
  const account: Account = { id, server, token: 'fixture-' + id, userId: id, name: id, serverName: 'Synthetic', remember: false };
  return new JellyfinAPI(account, server, 'device-' + id, true, history);
}
function hlsInfo(session: string): PlaybackInfo {
  return { PlaySessionId: session, MediaSources: [{ Id: 'source-' + session, Container: 'mkv', SupportsDirectPlay: false, TranscodingUrl: '/jellyfin/Videos/synthetic-title/master.m3u8', LiveStreamId: 'live-' + session }] };
}
function harness(t: TestContext, settings: { history?: boolean; direct?: boolean; remote?: boolean } = {}) {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'window');
  Object.defineProperty(globalThis, 'window', { configurable: true, value: new EventTarget() });
  t.after(() => { if (descriptor) Object.defineProperty(globalThis, 'window', descriptor); else Reflect.deleteProperty(globalThis, 'window'); });
  const calls: Call[] = [], preparations: Array<{ session: string; fallback?: string }> = [];
  t.mock.method(globalThis, 'fetch', async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    assert.ok(['http://127.0.0.1:18771', 'https://media.example'].includes(url.origin));
    calls.push({ path: url.pathname, query: Object.fromEntries(url.searchParams), method: init?.method ?? 'GET', body: init?.body ? JSON.parse(String(init.body)) : undefined, auth: new Headers(init?.headers).get('Authorization') ?? '' });
    return new Response(null, { status: 204 });
  });
  const api = connection('owned', settings.history, settings.remote); let sequence = 0;
  t.mock.method(api, 'playback', async (_item: MediaItem, options: { fallback?: string }) => {
    const session = 'session-' + ++sequence; preparations.push({ session, fallback: options.fallback });
    const info = hlsInfo(session); if (settings.direct) info.MediaSources[0].SupportsDirectPlay = true; return info;
  });
  const video = new NativeVideo(), player = new ReelPlayer(video as unknown as HTMLVideoElement), states: string[] = [], positions: number[] = [];
  player.onState = state => states.push(state); player.onPosition = (_item, seconds) => positions.push(seconds);
  t.after(async () => { await player.closeAndDrain(); player.reports.dispose(); });
  return { api, video, player, states, calls, preparations, positions };
}
async function open(h: ReturnType<typeof harness>, start = 1.399): Promise<void> { await h.player.open(h.api, item, { bitrate: 120_000_000, start }); }
function starts(h: ReturnType<typeof harness>): Call[] { return h.calls.filter(call => call.path.endsWith('/Sessions/Playing')); }
async function closed(h: ReturnType<typeof harness>, sessions = ['session-1']): Promise<void> {
  assert.equal((await h.player.closeAndDrain()).resourcesComplete, true); await settle();
  const encoders = h.calls.filter(call => call.path.endsWith('/Videos/ActiveEncodings'));
  assert.deepEqual(encoders.map(call => call.query.playSessionId).sort(), [...sessions].sort());
  assert.equal(new Set(encoders.map(call => call.query.playSessionId)).size, sessions.length);
  assert.deepEqual(h.calls.filter(call => call.path.endsWith('/LiveStreams/Close')).map(call => call.query.liveStreamId).sort(), sessions.map(value => 'live-' + value).sort());
  assert.equal(h.calls.filter(call => /^\/jellyfin\/User(?:Played|Favorite)Items/.test(call.path)).length, 0);
  if (!h.api.recordsHistory) assert.equal(h.calls.filter(call => call.path.includes('/Sessions/Playing')).length, 0);
  h.player.close(); await settle(); assert.equal(h.calls.filter(call => call.path.endsWith('/Videos/ActiveEncodings')).length, sessions.length);
}

test('native HLS defers resume assignment until first canplay and waits genuine settled seeked', async t => {
  const h = harness(t); await open(h); h.video.emit('loadedmetadata'); h.video.emit('loadeddata');
  assert.deepEqual(h.video.writes, []); assert.equal(h.video.playCalls, 0);
  h.video.emit('canplay'); assert.deepEqual(h.video.writes, [1.399]); assert.equal(h.video.seeking, true); assert.equal(h.video.playCalls, 0);
  h.video.settleSeek(); assert.equal(h.video.playCalls, 1); assert.equal(h.states.at(-1), 'playing'); assert.equal(h.positions.at(-1), 1.399); await closed(h);
});
test('repeat metadata/readiness/buffering cannot reapply native initial resume or rewind playback', async t => {
  const h = harness(t); await open(h); for (const name of ['loadedmetadata', 'canplay', 'loadedmetadata', 'canplay', 'waiting']) h.video.emit(name);
  assert.deepEqual(h.video.writes, [1.399]); assert.equal(h.video.playCalls, 0); h.video.settleSeek();
  h.video.value = 12; h.video.emit('timeupdate'); for (const name of ['loadedmetadata', 'canplay', 'waiting', 'canplay', 'playing']) h.video.emit(name);
  assert.deepEqual(h.video.writes, [1.399]); assert.equal(h.video.currentTime, 12); assert.equal(h.video.playCalls, 1); assert.equal(h.positions.at(-1), 12); await closed(h);
});
test('reentrant settled setter and readiness admit exactly one play and start report', async t => {
  const h = harness(t, { history: true }); await open(h); h.video.seekMode = 'settled'; h.video.onSeek = () => h.video.emit('canplay');
  h.video.emit('loadedmetadata'); h.video.emit('canplay'); h.video.emit('canplay'); h.video.emit('seeked'); await h.player.reports.flush();
  assert.deepEqual(h.video.writes, [1.399]); assert.equal(h.video.playCalls, 1); assert.equal(starts(h).length, 1); assert.equal(starts(h)[0].body?.PositionTicks, 13_990_000); await closed(h);
});
test('reentrant close from initial native setter cannot start or publish a stale session', async t => {
  const h = harness(t); await open(h); h.video.onSeek = () => h.player.close(); h.video.emit('canplay');
  assert.equal(h.video.playCalls, 0); assert.ok(!h.states.includes('playing')); await closed(h);
});
test('native seeking before readiness postpones the single initial attempt until settled', async t => {
  const h = harness(t); await open(h); h.video.seeking = true; h.video.emit('canplay'); assert.deepEqual(h.video.writes, []); assert.equal(h.video.playCalls, 0);
  h.video.settleSeek(); assert.deepEqual(h.video.writes, [1.399]); assert.equal(h.video.playCalls, 0); h.video.settleSeek(); assert.equal(h.video.playCalls, 1); await closed(h);
});
test('seeked still reporting native seeking cannot release the startup gate', async t => {
  const h = harness(t); await open(h); h.video.emit('canplay'); h.video.emit('seeked'); h.video.emit('playing');
  assert.equal(h.video.seeking, true); assert.equal(h.video.playCalls, 0); assert.ok(!h.states.includes('playing'));
  h.video.settleSeek(); assert.equal(h.video.playCalls, 1); await closed(h);
});
test('missing settled seeked never clears by time or repeated native readiness', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] }); const h = harness(t); await open(h); h.video.emit('canplay');
  t.mock.timers.tick(120_000); h.video.seeking = false; for (const name of ['canplay', 'loadedmetadata', 'waiting', 'playing']) h.video.emit(name);
  assert.equal(h.video.playCalls, 0); assert.deepEqual(h.video.writes, [1.399]); assert.ok(!h.states.includes('playing')); h.player.close(); h.player.reports.dispose();
});
test('an already reached resume target starts once without an artificial seek', async t => {
  const h = harness(t); await open(h); h.video.value = 1.399; h.video.emit('loadedmetadata'); h.video.emit('canplay'); h.video.emit('canplay');
  assert.deepEqual(h.video.writes, []); assert.equal(h.video.playCalls, 1); assert.equal(h.video.currentTime, 1.399); await closed(h);
});
test('native HLS Start over at zero never seeks and starts once', async t => {
  const h = harness(t); await open(h, 0); h.video.emit('loadedmetadata'); h.video.emit('canplay'); h.video.emit('canplay');
  assert.deepEqual(h.video.writes, []); assert.equal(h.video.playCalls, 1); assert.equal(h.video.currentTime, 0); await closed(h);
});
test('native HLS retains duration clamp and the actual settled local position', async t => {
  const h = harness(t); h.video.duration = 10; await open(h, 100); h.video.emit('canplay'); assert.deepEqual(h.video.writes, [9.75]);
  h.video.settleSeek(); assert.equal(h.positions.at(-1), 9.75); assert.equal(h.video.playCalls, 1); await closed(h);
});
test('native HLS unbounded duration retains desired position without guessing a new target', async t => {
  const h = harness(t); h.video.duration = Infinity; await open(h); h.video.emit('canplay'); assert.deepEqual(h.video.writes, [1.399]); h.video.settleSeek(); assert.equal(h.positions.at(-1), 1.399); await closed(h);
});
test('very short native HLS duration keeps the existing zero-clamp threshold', async t => {
  const h = harness(t); h.video.duration = .1; await open(h); h.video.emit('canplay'); assert.deepEqual(h.video.writes, []); assert.equal(h.video.playCalls, 1); h.video.emit('timeupdate'); assert.equal(h.positions.at(-1), 0); await closed(h);
});
test('native setter rejection releases only that session, reports error, and Retry retains desired position', async t => {
  const h = harness(t); await open(h); h.video.seekMode = 'throw'; h.video.emit('canplay'); await settle();
  assert.equal(h.states.at(-1), 'error'); assert.equal(h.video.playCalls, 0); assert.equal(h.video.src, '');
  h.video.seekMode = 'pending'; h.player.retry(); await settle(); h.video.emit('loadedmetadata'); assert.deepEqual(h.video.writes, []); h.video.emit('canplay'); assert.deepEqual(h.video.writes, [1.399]); h.video.settleSeek(); assert.equal(h.video.playCalls, 1); await closed(h, ['session-1', 'session-2']);
});
test('rejected native play publishes actionable paused state without a repeated autoplay loop', async t => {
  const h = harness(t); await open(h); h.video.rejectPlay = true; h.video.emit('canplay'); h.video.settleSeek(); await settle();
  assert.equal(h.states.at(-1), 'paused'); assert.equal(h.video.playCalls, 1); h.video.emit('canplay'); assert.equal(h.video.playCalls, 1);
  h.video.rejectPlay = false; h.player.toggle(); await settle(); assert.equal(h.states.at(-1), 'playing'); assert.equal(h.video.playCalls, 2); assert.deepEqual(h.video.writes, [1.399]); await closed(h);
});
for (const phase of ['metadata', 'pending-seek'] as const) test('close at ' + phase + ' rejects every captured old event and cleans exactly once', async t => {
  const h = harness(t); await open(h); h.video.emit('loadedmetadata'); if (phase === 'pending-seek') h.video.emit('canplay'); const old = h.video.snapshot(); h.player.close(); const writes = [...h.video.writes]; const states = [...h.states];
  h.video.stale(old, ['loadedmetadata', 'canplay', 'seeked', 'playing', 'timeupdate', 'ended', 'error']); assert.deepEqual(h.video.writes, writes); assert.deepEqual(h.states, states); assert.equal(h.video.playCalls, 0); await closed(h);
});
test('replacement account rejects captured old readiness/seeked without releasing its newer session', async t => {
  const h = harness(t); await open(h); h.video.emit('canplay'); const old = h.video.snapshot();
  const other = connection('other'); t.mock.method(other, 'playback', async () => ({ ...hlsInfo('account-b') }));
  await h.player.open(other, item, { bitrate: 120_000_000, start: 3 }); const url = h.video.src;
  h.video.stale(old, ['loadedmetadata', 'canplay', 'seeked', 'playing', 'ended', 'error']); assert.equal(h.video.src, url); assert.equal(h.video.playCalls, 0);
  h.video.emit('canplay'); h.video.settleSeek(); assert.equal(h.video.currentTime, 3); assert.equal(h.video.playCalls, 1); await h.player.closeAndDrain();
  assert.deepEqual(h.calls.filter(x => x.path.endsWith('/Videos/ActiveEncodings')).map(x => x.query.playSessionId), ['session-1', 'account-b']);
  assert.ok(h.calls.find(x => x.query.playSessionId === 'account-b')?.auth.includes('fixture-other')); assert.equal(h.calls.filter(x => x.path.includes('/Sessions/Playing')).length, 0);
});
test('Retry during pending initial seek creates a fresh latch and retains the desired target', async t => {
  const h = harness(t); await open(h); h.video.emit('canplay'); const old = h.video.snapshot(); h.player.retry(); await settle();
  h.video.stale(old, ['canplay', 'seeked', 'playing']); assert.equal(h.video.playCalls, 0); h.video.emit('loadedmetadata'); assert.equal(h.video.writes.length, 1);
  h.video.emit('canplay'); assert.deepEqual(h.video.writes, [1.399, 1.399]); h.video.settleSeek(); assert.equal(h.video.playCalls, 1); await closed(h, ['session-1', 'session-2']);
});
test('native HLS error fallbacks and final Retry preserve target and bounded owned cleanup', async t => {
  const h = harness(t); await open(h);
  for (let n = 0; n < 3; n++) { h.video.emit('canplay'); h.video.emit('error'); await settle(); }
  assert.equal(h.states.at(-1), 'error'); assert.equal(h.video.playCalls, 0); assert.deepEqual(h.preparations.map(x => x.fallback), [undefined, 'audio', 'video']);
  h.player.retry(); await settle(); h.video.emit('canplay'); h.video.settleSeek(); assert.equal(h.video.currentTime, 1.399); assert.equal(h.video.playCalls, 1); await closed(h, ['session-1', 'session-2', 'session-3', 'session-4']);
});
test('native HLS EOF cannot restart or reapply initial seek after owned resources are released', async t => {
  const h = harness(t); await open(h, 0); h.video.emit('canplay'); h.video.value = 14; h.video.ended = true; h.video.emit('ended'); h.video.emit('canplay'); h.video.emit('loadedmetadata'); await settle();
  assert.equal(h.video.playCalls, 1); assert.deepEqual(h.video.writes, []); assert.equal(h.states.at(-1), 'ended'); assert.equal(h.positions.at(-1), 0); await closed(h);
});
test('direct MP4 retains the original metadata-time seek path', async t => {
  const h = harness(t, { direct: true }); await open(h); h.video.emit('loadedmetadata'); assert.deepEqual(h.video.writes, [1.399]); h.video.emit('canplay'); assert.equal(h.video.playCalls, 0); h.video.settleSeek(); assert.equal(h.video.playCalls, 1); await closed(h);
});
test('native HLS protected preview suppresses history even when the preference is true', async t => {
  const h = harness(t, { history: true, remote: true }); await open(h); h.video.emit('canplay'); h.video.settleSeek(); h.video.value = 8; h.video.emit('timeupdate'); h.video.pause(); h.video.emit('pause'); await closed(h);
});
