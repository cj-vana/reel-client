import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { setImmediate as settle } from 'node:timers/promises';
import { JellyfinAPI } from '../src/api.ts';
import { ReelPlayer } from '../src/player.ts';
import type { Account, MediaItem, MediaSource, PlaybackInfo } from '../src/types.ts';

const windowDescriptor = Object.getOwnPropertyDescriptor(globalThis, 'window');
test.beforeEach(() => Object.defineProperty(globalThis, 'window', { configurable: true, writable: true, value: new EventTarget() }));
test.after(() => { if (windowDescriptor) Object.defineProperty(globalThis, 'window', windowDescriptor); else Reflect.deleteProperty(globalThis, 'window'); });

class Video extends EventTarget {
  playsInline = false; preload = ''; paused = true; ended = false; duration = 14; currentTime = 0;
  failSourceAssignment = false;
  private value = '';
  get src(): string { return this.value; }
  set src(value: string) { if (value && this.failSourceAssignment) throw new Error('Synthetic media setup failed'); this.value = value; }
  setAttribute(): void {}
  removeAttribute(name: string): void { if (name === 'src') this.value = ''; }
  pause(): void { this.paused = true; }
  play(): Promise<void> { this.paused = false; return Promise.resolve(); }
  load(): void {}
  canPlayType(): string { return 'probably'; }
}
type Call = { url: URL; method: string; authorization: string | null };
const item: MediaItem = { Id: 'title', Name: 'Synthetic title', MediaSources: [{ Id: 'source-owned', LiveStreamId: 'library-not-owned' }] };
const options = { bitrate: 16000000, source: 'source-owned' };
const source = (changes: Partial<MediaSource> = {}): MediaSource => ({ Id: 'source-owned', SupportsDirectPlay: true, LiveStreamId: 'live-owned', ...changes });
function api(id = 'owned'): JellyfinAPI {
  const server = 'http://127.0.0.1:18771/jellyfin';
  const account: Account = { id, server, userId: id, token: 'fixture-' + id, name: id, serverName: 'Fixture', remember: false };
  return new JellyfinAPI(account, server, 'device-' + id, true, true);
}
function harness(t: TestContext, info: PlaybackInfo | Promise<PlaybackInfo>, failEncoder = false) {
  const calls: Call[] = [];
  t.mock.method(globalThis, 'fetch', async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    calls.push({ url, method: init?.method ?? 'GET', authorization: new Headers(init?.headers).get('Authorization') });
    return new Response(null, { status: failEncoder && url.pathname.endsWith('/Videos/ActiveEncodings') ? 503 : 204 });
  });
  const connection = api(); t.mock.method(connection, 'playback', async () => info);
  const video = new Video(), player = new ReelPlayer(video as unknown as HTMLVideoElement), states: string[] = [];
  player.onState = state => states.push(state);
  t.after(() => { player.close(); player.reports.dispose(); });
  return { connection, calls, video, player, states };
}
function assertOwnedCleanup(calls: Call[], session: string, liveIds: string[]) {
  const encodings = calls.filter(call => call.url.pathname.endsWith('/Videos/ActiveEncodings'));
  assert.equal(encodings.length, 1); assert.equal(encodings[0].method, 'DELETE');
  assert.equal(encodings[0].url.searchParams.get('playSessionId'), session);
  assert.equal(encodings[0].url.searchParams.get('deviceId'), 'device-owned');
  const tuners = calls.filter(call => call.url.pathname.endsWith('/LiveStreams/Close'));
  assert.deepEqual(tuners.map(call => call.url.searchParams.get('liveStreamId')), liveIds);
  assert.ok(tuners.every(call => call.method === 'POST'));
  assert.ok(calls.every(call => call.url.origin === 'http://127.0.0.1:18771' && call.url.pathname.startsWith('/jellyfin/') && call.authorization?.includes('Token="fixture-owned"')));
  assert.equal(calls.filter(call => call.url.pathname.includes('/Sessions/Playing')).length, 0);
}

async function rejectedPreparation(t: TestContext, info: PlaybackInfo) {
  const h = harness(t, info, info.ErrorCode !== undefined);
  await h.player.open(h.connection, item, options); await settle();
  assert.equal(h.states.at(-1), 'error'); assert.equal(h.video.src, '');
  assertOwnedCleanup(h.calls, 'failed', ['live-owned']);
  h.player.close(); await settle(); assertOwnedCleanup(h.calls, 'failed', ['live-owned']);
}
test('preparation releases foreign stream URL without history writes', t => rejectedPreparation(t, { MediaSources: [source({ SupportsDirectPlay: false, TranscodingUrl: 'https://foreign.invalid/stream.m3u8' })], PlaySessionId: 'failed' }));
test('preparation releases stream URL outside the server base path without history writes', t => rejectedPreparation(t, { MediaSources: [source({ SupportsDirectPlay: false, TranscodingUrl: 'http://127.0.0.1:18771/outside/stream.m3u8' })], PlaySessionId: 'failed' }));
test('preparation releases PlaybackInfo ErrorCode with a selected source without history writes', t => rejectedPreparation(t, { MediaSources: [source()], PlaySessionId: 'failed', ErrorCode: 'NotAllowed' }));
test('preparation releases returned owned source without a playable URL without history writes', t => rejectedPreparation(t, { MediaSources: [source({ SupportsDirectPlay: false })], PlaySessionId: 'failed' }));

test('failed preparation does not close an unrelated returned live source', async t => {
  const h = harness(t, { MediaSources: [source({ Id: 'unrelated', LiveStreamId: 'not-owned', SupportsDirectPlay: false }), source({ SupportsDirectPlay: false })], PlaySessionId: 'selected' });
  await h.player.open(h.connection, item, options); await settle();
  assertOwnedCleanup(h.calls, 'selected', ['live-owned']);
});

test('failed preparation with no sources releases only its returned encoding session', async t => {
  const h = harness(t, { MediaSources: [], PlaySessionId: 'no-source', ErrorCode: 'NoCompatibleStream' });
  await h.player.open(h.connection, item, options); await settle();
  assertOwnedCleanup(h.calls, 'no-source', []);
});

test('closing a pending preparation releases late returned ownership exactly once', async t => {
  let finish!: (info: PlaybackInfo) => void;
  const h = harness(t, new Promise<PlaybackInfo>(resolve => { finish = resolve; }));
  const opening = h.player.open(h.connection, item, options); h.player.close();
  finish({ MediaSources: [source()], PlaySessionId: 'late' }); await opening; await settle();
  assertOwnedCleanup(h.calls, 'late', ['live-owned']); assert.deepEqual(h.states, ['preparing']); assert.equal(h.video.src, '');
});

test('a stale preparation cannot release or overwrite a newer active session', async t => {
  let finish!: (info: PlaybackInfo) => void;
  const h = harness(t, new Promise<PlaybackInfo>(resolve => { finish = resolve; }));
  const opening = h.player.open(h.connection, item, options);
  const newer = api('newer'); t.mock.method(newer, 'playback', async () => ({ MediaSources: [source({ LiveStreamId: 'live-newer' })], PlaySessionId: 'newer' }));
  await h.player.open(newer, item, options);
  const newerURL = h.video.src; assert.ok(newerURL.includes('fixture-newer'));
  finish({ MediaSources: [source()], PlaySessionId: 'older' }); await opening; await settle();
  assert.equal(h.video.src, newerURL); assertOwnedCleanup(h.calls, 'older', ['live-owned']);
  h.player.close(); await settle();
  assert.deepEqual(h.calls.filter(c => c.url.pathname.endsWith('/Videos/ActiveEncodings')).map(c => c.url.searchParams.get('playSessionId')), ['older', 'newer']);
  assert.deepEqual(h.calls.filter(c => c.url.pathname.endsWith('/LiveStreams/Close')).map(c => c.url.searchParams.get('liveStreamId')), ['live-owned', 'live-newer']);
  assert.equal(h.calls.filter(c => c.url.pathname.includes('/Sessions/Playing')).length, 0);
});

test('successful preparation transfers ownership until close without premature or duplicate cleanup', async t => {
  const h = harness(t, { MediaSources: [source()], PlaySessionId: 'accepted' });
  await h.player.open(h.connection, item, options); await settle(); assert.equal(h.calls.length, 0); assert.ok(h.video.src);
  h.player.close(); await settle(); assertOwnedCleanup(h.calls, 'accepted', ['live-owned']);
  h.player.close(); await settle(); assertOwnedCleanup(h.calls, 'accepted', ['live-owned']);
});

test('media setup failure after ownership transfer releases current only once', async t => {
  const h = harness(t, { MediaSources: [source()], PlaySessionId: 'setup' }); h.video.failSourceAssignment = true;
  await h.player.open(h.connection, item, options); await settle();
  assert.equal(h.states.at(-1), 'error'); assertOwnedCleanup(h.calls, 'setup', ['live-owned']);
});

test('Retry after rejected preparation owns only its new session until close', async t => {
  const h = harness(t, { MediaSources: [source({ SupportsDirectPlay: false, TranscodingUrl: 'https://foreign.invalid/stream' })], PlaySessionId: 'failed' });
  await h.player.open(h.connection, item, options); await settle();
  assertOwnedCleanup(h.calls, 'failed', ['live-owned']);
  t.mock.method(h.connection, 'playback', async () => ({ MediaSources: [source({ LiveStreamId: 'live-retry' })], PlaySessionId: 'retry' }));
  h.player.retry(); await settle(); assert.ok(h.video.src); assertOwnedCleanup(h.calls, 'failed', ['live-owned']);
  h.player.close(); await settle();
  assert.deepEqual(h.calls.filter(c => c.url.pathname.endsWith('/Videos/ActiveEncodings')).map(c => c.url.searchParams.get('playSessionId')), ['failed', 'retry']);
  assert.deepEqual(h.calls.filter(c => c.url.pathname.endsWith('/LiveStreams/Close')).map(c => c.url.searchParams.get('liveStreamId')), ['live-owned', 'live-retry']);
  assert.equal(h.calls.filter(c => c.url.pathname.includes('/Sessions/Playing')).length, 0);
});

test('closeAndDrain waits late PlaybackInfo and the cleanup it creates', async t => {
  let finish!: (info: PlaybackInfo) => void, cleanupFinished = false, releaseCleanup!: () => void;
  const h = harness(t, new Promise<PlaybackInfo>(resolve => { finish = resolve; }));
  t.mock.method(h.connection, 'cleanup', async () => { await new Promise<void>(resolve => { releaseCleanup = resolve; }); cleanupFinished = true; });
  const opening = h.player.open(h.connection, item, options);
  const first = h.player.closeAndDrain(), duplicate = h.player.closeAndDrain(); assert.equal(first, duplicate);
  finish({ MediaSources: [source()], PlaySessionId: 'late-drain' }); await opening; await settle();
  assert.equal(cleanupFinished, false); releaseCleanup(); const result = await first;
  assert.equal(result.resourcesComplete, true); assert.equal(result.cleanupSucceeded, true);
});

test('closeAndDrain timeout is bounded while late ownership still cleans up safely', async t => {
  let finish!: (info: PlaybackInfo) => void;
  const h = harness(t, new Promise<PlaybackInfo>(resolve => { finish = resolve; }));
  const opening = h.player.open(h.connection, item, options);
  const result = await h.player.closeAndDrain(5); assert.equal(result.resourcesComplete, false); assert.equal(result.reportsFlushed, false);
  finish({ MediaSources: [source()], PlaySessionId: 'after-deadline' }); await opening; await settle();
  assertOwnedCleanup(h.calls, 'after-deadline', ['live-owned']);
});

test('closeAndDrain observes cleanup failure after attempting both owned resources', async t => {
  const h = harness(t, { MediaSources: [source()], PlaySessionId: 'cleanup-failure' }, true);
  await h.player.open(h.connection, item, options); const result = await h.player.closeAndDrain();
  assert.equal(result.resourcesComplete, true); assert.equal(result.cleanupSucceeded, false);
  assertOwnedCleanup(h.calls, 'cleanup-failure', ['live-owned']);
});

test('EOF cleanup remains owned through closeAndDrain and releases encoder and tuner exactly once', async t => {
  const h = harness(t, { MediaSources: [source()], PlaySessionId: 'completed' });
  let release!: () => void, attempts = 0, settled = false;
  const cleanup = h.connection.cleanup.bind(h.connection);
  t.mock.method(h.connection, 'cleanup', async (...args: Parameters<JellyfinAPI['cleanup']>) => {
    if (++attempts === 1) await new Promise<void>(done => { release = done; });
    await cleanup(...args);
  });
  await h.player.open(h.connection, item, options);
  h.video.dispatchEvent(new Event('canplay')); h.video.ended = true; h.video.currentTime = 14;
  h.video.dispatchEvent(new Event('ended'));
  const draining = h.player.closeAndDrain().then(value => { settled = true; return value; });
  try {
    await settle(); assert.equal(settled, false, 'close must wait for the first EOF cleanup');
  } finally { release(); }
  const result = await draining;
  assert.equal(result.resourcesComplete, true); assert.equal(attempts, 1);
  assert.equal(h.calls.filter(call => call.url.pathname.endsWith('/Videos/ActiveEncodings')).length, 1);
  assert.equal(h.calls.filter(call => call.url.pathname.endsWith('/LiveStreams/Close')).length, 1);
});

test('inactive account drain waits its old cleanup without stopping newer playback', async t => {
  const h = harness(t, { MediaSources: [source()], PlaySessionId: 'account-a' });
  let release!: () => void, settled = false;
  const cleanup = h.connection.cleanup.bind(h.connection);
  t.mock.method(h.connection, 'cleanup', async (...args: Parameters<JellyfinAPI['cleanup']>) => { await new Promise<void>(done => { release = done; }); await cleanup(...args); });
  await h.player.open(h.connection, item, options); h.player.close();
  const newer = api('newer'); t.mock.method(newer, 'playback', async () => ({ MediaSources: [source({ LiveStreamId: 'live-newer' })], PlaySessionId: 'account-b' }));
  await h.player.open(newer, item, options); const newerURL = h.video.src;
  const waiting = h.player.drainAccountResources('owned').then(result => { settled = true; return result; });
  try { await settle(); assert.equal(settled, false); assert.equal(h.video.src, newerURL); }
  finally { release(); }
  assert.equal(await waiting, true); assert.equal(h.video.src, newerURL);
  assert.equal(h.calls.filter(call => call.url.searchParams.get('playSessionId') === 'account-b').length, 0);
});

test('inactive account drain does not wait unrelated preparation and has a bounded own deadline', async t => {
  let finish!: (info: PlaybackInfo) => void;
  const h = harness(t, new Promise<PlaybackInfo>(done => { finish = done; }));
  const opening = h.player.open(h.connection, item, options);
  assert.equal(await h.player.drainAccountResources('different', 5), true);
  assert.equal(await h.player.drainAccountResources('owned', 5), false);
  h.player.close(); finish({ MediaSources: [source()], PlaySessionId: 'late-account' });
  await opening; assert.equal(await h.player.drainAccountResources('owned'), true);
});

test('closing during the new HDR probe prevents PlaybackInfo and creates no cleanup ownership', async t => {
  const original = Object.getOwnPropertyDescriptor(globalThis, 'navigator');
  let release!: (value: MediaCapabilitiesDecodingInfo) => void, entered!: () => void;
  const started = new Promise<void>(resolve => { entered = resolve; });
  Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { mediaCapabilities: { decodingInfo: () => { entered(); return new Promise(resolve => { release = resolve; }); } } } });
  t.after(() => { if (original) Object.defineProperty(globalThis, 'navigator', original); else Reflect.deleteProperty(globalThis, 'navigator'); });
  const h = harness(t, { MediaSources: [source()], PlaySessionId: 'must-not-exist' }); let requests = 0;
  t.mock.method(h.connection, 'playback', async () => { requests++; return { MediaSources: [source()], PlaySessionId: 'must-not-exist' }; });
  const hdr = { ...item, MediaSources: [{ Id: 'source-owned', MediaStreams: [{ Index: 0, Type: 'Video', Codec: 'hevc', Width: 3840, Height: 2160, BitRate: 20000000, BitDepth: 10, RealFrameRate: 24, VideoRangeType: 'HDR10' }] }] };
  const opening = h.player.open(h.connection, hdr, options); await started; h.player.close();
  release({ supported: true, smooth: true, powerEfficient: true }); await opening; await settle();
  assert.equal(requests, 0); assert.equal(h.calls.length, 0); assert.equal(h.video.src, '');
});
