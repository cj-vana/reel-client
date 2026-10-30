import test from 'node:test';
import assert from 'node:assert/strict';
import { readBlob, JellyfinAPI, normalizeServer, scopedURL } from '../src/api.ts';
import { subtitle, type Account, type MediaItem } from '../src/types.ts';

const account: Account = { id: 'one', server: 'https://media.example/jellyfin', token: 'test-token', userId: 'user-one', name: 'Test', serverName: 'Fixture', remember: false };
const item: MediaItem = { Id: 'film', Name: 'Film', UserData: { PlaybackPositionTicks: 300_000_000 } };

test('addresses normalize without accepting credentials or remote cleartext', () => {
  assert.equal(normalizeServer(' https://MEDIA.example:443/jellyfin/// '), 'https://media.example/jellyfin');
  for (const input of ['example.com', 'ftp://example.com', 'https://user:pass@example.com', 'https://example.com/?x=1', 'http://example.com', 'http://192.168.999.1']) assert.throws(() => normalizeServer(input), input);
  for (const input of ['http://127.0.0.1:18771', 'http://192.168.1.8', 'http://10.0.0.1', 'http://100.64.0.2', 'http://server.tailxyz.ts.net']) assert.doesNotThrow(() => normalizeServer(input));
});

test('API and stream paths preserve server subpaths and refuse escape', () => {
  assert.equal(scopedURL(account.server, 'Videos/film/master.m3u8').pathname, '/jellyfin/Videos/film/master.m3u8');
  assert.equal(scopedURL(account.server, '/jellyfin/Videos/film/master.m3u8').pathname, '/jellyfin/Videos/film/master.m3u8');
  for (const input of ['https://evil.example/x', '//evil.example/x', 'https://media.example/outside', '../outside', 'https://name:pass@media.example/jellyfin/x']) assert.throws(() => scopedURL(account.server, input), input);
});

test('protected preview blocks remote writes before fetch and suppresses history', async () => {
  const old = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => { calls++; return new Response(null, { status: 204 }); };
  try {
    const api = new JellyfinAPI(account, account.server, 'device', true, true);
    await assert.rejects(api.favorite(item, true), /Protected preview/);
    await assert.rejects(api.watched(item, true), /Protected preview/);
    await api.report(item, { Id: 'source' }, 'session', 'DirectPlay', '/Stopped', 50, true);
    assert.equal(calls, 0);
    await api.cleanup('owned-session');
    assert.equal(calls, 1);
  } finally { globalThis.fetch = old; }
});

test('mutable loopback fixtures and explicit history preference remain separate', async () => {
  const old = globalThis.fetch;
  const bodies: unknown[] = [];
  globalThis.fetch = async (_input, options) => { bodies.push(options?.body); return new Response(null, { status: 204 }); };
  try {
    const local = { ...account, server: 'http://127.0.0.1:18771' };
    const api = new JellyfinAPI(local, local.server, 'device', true, false);
    await api.favorite(item, true);
    await api.watched(item, true);
    await api.report(item, { Id: 'source' }, 'session', 'DirectPlay', '/Stopped', 50, true);
    assert.equal(bodies.length, 2);
    const recorder = new JellyfinAPI(local, local.server, 'device', true, true);
    await recorder.report(item, { Id: 'source' }, 'session', 'DirectPlay', '/Stopped', 50, true);
    assert.equal(bodies.length, 3);
    assert.equal(JSON.parse(String(bodies[2])).PositionTicks, 500_000_000);
  } finally { globalThis.fetch = old; }
});

test('playback negotiation requests a complete timeline and preserves HEVC for audio fallback', async () => {
  const old = globalThis.fetch;
  const bodies: Array<Record<string, unknown>> = [];
  globalThis.fetch = async (_input, options) => { bodies.push(JSON.parse(String(options?.body))); return Response.json({ MediaSources: [], PlaySessionId: 'session' }); };
  try {
    const api = new JellyfinAPI(account, account.server, 'device');
    await api.playback(item, { bitrate: 20_000_000, fallback: 'audio', capabilities: { mp4Video: ['h264', 'hevc'], mp4Audio: ['aac'], nativeHLS: true, audioFiles: [] } });
    assert.equal(bodies[0].StartTimeTicks, 0);
    assert.equal(bodies[0].AllowVideoStreamCopy, true);
    assert.equal(bodies[0].AllowAudioStreamCopy, false);
    await api.playback(item, { bitrate: 2_000_000, fallback: 'video' });
    assert.equal(bodies[1].AllowVideoStreamCopy, false);
  } finally { globalThis.fetch = old; }
});

test('API uses header credentials, refuses redirects and authenticated stream URLs remain scoped', async () => {
  const old = globalThis.fetch;
  let options: RequestInit | undefined, requestURL = '';
  globalThis.fetch = async (input, init) => { requestURL = String(input); options = init; return Response.json({ Items: [] }); };
  try {
    const api = new JellyfinAPI(account, account.server, 'device');
    await api.page('Items');
    assert.ok(!requestURL.includes(account.token));
    assert.equal(options?.redirect, 'error');
    assert.equal(options?.credentials, 'omit');
    assert.match(String((options?.headers as Record<string, string>).Authorization), /Token="test-token"/);
    const stream = api.streamURL(item, { Id: 'source', TranscodingUrl: '/jellyfin/Videos/film/master.m3u8?api_key=old' }, 'session');
    assert.equal(new URL(stream.url).searchParams.get('ApiKey'), account.token);
    assert.equal(new URL(stream.url).searchParams.get('api_key'), null);
    assert.throws(() => api.streamURL(item, { Id: 'source', TranscodingUrl: 'https://evil.example/stream' }, 'session'));
  } finally { globalThis.fetch = old; }
});

test('live history preference revokes previously created API instances', async () => {
  const old = globalThis.fetch; let allowed = true, calls = 0;
  globalThis.fetch = async () => { calls++; return new Response(null, { status: 204 }); };
  try {
    const local = { ...account, server: 'http://127.0.0.1:18771' };
    const api = new JellyfinAPI(local, local.server, 'device', true, true, () => allowed);
    allowed = false;
    await api.report(item, { Id: 'source' }, 'old-session', 'DirectPlay', '/Stopped', 50, true);
    assert.equal(calls, 0);
  } finally { globalThis.fetch = old; }
});

test('owned tuner cleanup is attempted even when encoder cleanup fails', async () => {
  const old = globalThis.fetch, urls: string[] = [];
  globalThis.fetch = async input => { urls.push(String(input)); return new Response(null, { status: String(input).includes('ActiveEncodings') ? 503 : 204 }); };
  try {
    const api = new JellyfinAPI(account, account.server, 'device');
    await assert.rejects(api.cleanup('owned-session', { Id: 'source', LiveStreamId: 'owned-tuner' }));
    assert.equal(urls.length, 2); assert.ok(urls.some(url => url.includes('LiveStreams/Close')));
  } finally { globalThis.fetch = old; }
});

test('unknown-length file bodies stop at the byte limit and cancel their stream', async () => {
  let cancelled = false;
  const body = new ReadableStream<Uint8Array>({ pull(controller) { controller.enqueue(new Uint8Array([1, 2, 3, 4])); }, cancel() { cancelled = true; } });
  await assert.rejects(readBlob(new Response(body), 5), /memory limit/);
  assert.equal(cancelled, true);
});

test('aborting after file headers cancels a waiting body and later reads recover', async () => {
  let cancelled = false;
  const body = new ReadableStream<Uint8Array>({ start(controller) { controller.enqueue(new Uint8Array([1, 2])); }, cancel() { cancelled = true; } });
  const abort = new AbortController(), pending = readBlob(new Response(body), 1024, abort.signal);
  abort.abort(); await assert.rejects(pending, { name: 'AbortError' }); assert.equal(cancelled, true);
  assert.equal(await (await readBlob(new Response('fresh', { headers: { 'content-type': 'text/plain' } }), 1024)).text(), 'fresh');
});

test('file body deadline cancels its reader and subsequent file reads recover', async context => {
  context.mock.timers.enable({ apis: ['setTimeout'] });
  let cancelled = false;
  const body = new ReadableStream<Uint8Array>({ cancel() { cancelled = true; } });
  const pending = readBlob(new Response(body), 1024);
  context.mock.timers.tick(18000);
  await assert.rejects(pending, /stopped loading/); assert.equal(cancelled, true);
  assert.equal(await (await readBlob(new Response('recovered'), 1024)).text(), 'recovered');
});


test('recent episodes queries individual user-scoped Items ordered by DateCreated descending', async () => {
  const old = globalThis.fetch; const calls: Array<{ url: URL; options?: RequestInit }> = [];
  const episodes: MediaItem[] = [{ Id: 'e2', Name: 'Second', Type: 'Episode', SeriesId: 's1', DateCreated: '2026-10-24T20:00:00Z' }, { Id: 'e1', Name: 'First', Type: 'Episode', SeriesId: 's1', DateCreated: '2026-10-23T20:00:00Z' }];
  globalThis.fetch = async (input, options) => { calls.push({ url: new URL(String(input)), options }); return Response.json({ Items: episodes }); };
  try {
    const api = new JellyfinAPI(account, account.server, 'device');
    assert.deepEqual((await api.recentEpisodes()).Items, episodes);
    assert.equal(calls.length, 1); const call = calls[0];
    assert.equal(call.url.pathname, '/jellyfin/Items');
    assert.deepEqual(Object.fromEntries(call.url.searchParams), { userId: account.userId, fields: 'Overview,Genres,DateCreated', enableUserData: 'true', recursive: 'true', includeItemTypes: 'Episode', sortBy: 'DateCreated', sortOrder: 'Descending', limit: '18', enableTotalRecordCount: 'false' });
    assert.equal(call.options?.method, 'GET'); assert.equal(call.url.searchParams.has('groupItems'), false);
    assert.match(String((call.options?.headers as Record<string, string>).Authorization), /Token="test-token"/);
  } finally { globalThis.fetch = old; }
});

test('latest Episode explicitly disables parent grouping without changing Movie and Series queries', async () => {
  const old = globalThis.fetch, queries: URLSearchParams[] = [];
  globalThis.fetch = async input => { queries.push(new URL(String(input)).searchParams); return Response.json([]); };
  try { const api = new JellyfinAPI(account, account.server, 'device'); for (const kind of ['Episode', 'Movie', 'Series']) await api.latest(kind); assert.equal(queries[0].get('groupItems'), 'false'); assert.equal(queries[1].has('groupItems'), false); assert.equal(queries[2].has('groupItems'), false); }
  finally { globalThis.fetch = old; }
});

test('recent Episode empty is valid and grouped or malformed collections fail the shelf', async () => {
  const old = globalThis.fetch; let payload: unknown = { Items: [] };
  globalThis.fetch = async () => Response.json(payload);
  try { const api = new JellyfinAPI(account, account.server, 'device'); assert.deepEqual((await api.recentEpisodes()).Items, []); for (payload of [{}, { Items: null }, { Items: [{ Id: 'series', Name: 'Grouped parent', Type: 'Series' }] }, { Items: [{ Name: 'No identity', Type: 'Episode' }] }]) await assert.rejects(api.recentEpisodes(), /invalid episode shelf/); }
  finally { globalThis.fetch = old; }
});

test('recent Episode cancellation aborts the active request rather than returning stale cards', async () => {
  const old = globalThis.fetch; let aborted = false;
  globalThis.fetch = async (_input, options) => new Promise((_resolve, reject) => { options?.signal?.addEventListener('abort', () => { aborted = true; reject(new DOMException('Cancelled', 'AbortError')); }, { once: true }); });
  try { const signal = new AbortController(), api = new JellyfinAPI(account, account.server, 'device'); const pending = api.recentEpisodes(signal.signal); signal.abort(); await assert.rejects(pending, { name: 'AbortError' }); assert.equal(aborted, true); }
  finally { globalThis.fetch = old; }
});


test('artwork shape picks the episode still for landscape cards and series art elsewhere', () => {
  const api = new JellyfinAPI(account, account.server, 'device');
  const episode: MediaItem = { Id: 'ep', Name: 'Pilot', Type: 'Episode', ImageTags: { Primary: 'still' }, SeriesId: 'show', SeriesPrimaryImageTag: 'cover', ParentBackdropItemId: 'show', ParentBackdropImageTags: ['wide'] };
  const path = (url: URL) => url.pathname.replace('/jellyfin/', '') + ' ' + url.searchParams.get('tag');
  assert.equal(path(api.imageURL(episode, 'landscape')), 'Items/ep/Images/Primary still');
  assert.equal(path(api.imageURL(episode, 'poster')), 'Items/show/Images/Primary cover');
  assert.equal(path(api.imageURL(episode, 'backdrop')), 'Items/show/Images/Backdrop wide');
  const stillless: MediaItem = { ...episode, ImageTags: {} };
  assert.equal(path(api.imageURL(stillless, 'landscape')), 'Items/show/Images/Backdrop wide');
  const film: MediaItem = { Id: 'film', Name: 'Film', Type: 'Movie', ImageTags: { Primary: 'poster' }, BackdropImageTags: ['scene'] };
  assert.equal(path(api.imageURL(film, 'landscape')), 'Items/film/Images/Backdrop scene');
  assert.equal(path(api.imageURL(film, 'poster')), 'Items/film/Images/Primary poster');
});

test('episode labels preserve real numbering including specials and do not invent missing numbers', () => {
  assert.equal(subtitle({ Id: 'e', Name: 'Chapter', Type: 'Episode', ParentIndexNumber: 1, IndexNumber: 2 }), 'S1 E2 Chapter');
  assert.equal(subtitle({ Id: 'e', Name: 'Special', Type: 'Episode', ParentIndexNumber: 0, IndexNumber: 0 }), 'S0 E0 Special');
  assert.equal(subtitle({ Id: 'e', Name: 'Unknown', Type: 'Episode' }), 'Unknown');
  assert.equal(subtitle({ Id: 'e', Name: 'Unknown season', Type: 'Episode', IndexNumber: 3 }), 'E3 Unknown season');
});
