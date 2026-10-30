import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { localPlaylist, OfflineDownloads, onServer, segmentsOf, serverRoot, SIZES, validRequest, variantOf } from '../src/offline.mjs';
import { offlineResponse } from '../src/offline-bridge.mjs';

const server = 'https://media.example.test/jellyfin';
const request = (extra = {}) => ({ accountId: server + '|user', server, token: 'synthetic-token', userId: 'user', deviceId: 'device-1', itemId: 'movie-1',
  mediaSourceId: 'source-1', size: 'standard', title: 'A quiet film', subtitle: '', runtime: 12, ...extra });
const playlist = (count, endlist = true) => ['#EXTM3U', '#EXT-X-PLAYLIST-TYPE:VOD', '#EXT-X-TARGETDURATION:6',
  ...Array.from({ length: count }, (_, i) => [`#EXTINF:${i === count - 1 ? 2.5 : 6},`, `hls1/main/${i}.ts?runtimeTicks=0&actualSegmentLengthTicks=60000000`]).flat(), ...(endlist ? ['#EXT-X-ENDLIST'] : [])].join('\n');

// A fake Jellyfin that answers the master playlist, the variant, three segments and the artwork, and records every
// request with its authorization header.
function fakeServer({ failSegment } = {}) {
  const calls = [];
  const fetch = async (url, options = {}) => {
    calls.push({ url: new URL(url), method: options.method ?? 'GET', authorization: options.headers?.Authorization });
    const path = new URL(url).pathname;
    const body = path.endsWith('/master.m3u8') ? '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000000\nmain.m3u8?PlaySessionId=x\n'
      : path.endsWith('/main.m3u8') ? playlist(3)
      : path.endsWith('.ts') ? (failSegment === path ? null : 'segment ' + path.split('/').pop())
      : path.endsWith('/Images/Primary') ? 'jpeg' : path.endsWith('/ActiveEncodings') ? '' : null;
    if (body === null) return { ok: false, status: 500 };
    return { ok: true, status: 200, text: async () => body, body: (async function* () { yield new TextEncoder().encode(body); })() };
  };
  return { calls, fetch };
}
async function settled(downloads, accountId) {
  await downloads.idle();
  const [entry] = downloads.list(accountId);
  if (entry && ['complete', 'failed'].includes(entry.state)) return entry;
  throw new Error('The download never finished');
}
async function folder() { return mkdtemp(join(tmpdir(), 'reel-offline-')); }

test('playlists are read only from the server the download started on', () => {
  const root = serverRoot(server);
  assert.equal(root, server);
  const withCredentials = new URL(server); withCredentials.username = 'user'; withCredentials.password = 'secret';
  assert.equal(serverRoot(withCredentials.toString()), undefined);
  assert.equal(serverRoot('ftp://media.example.test'), undefined);
  assert.equal(onServer('main.m3u8', server + '/Videos/a/master.m3u8', root).pathname, '/jellyfin/Videos/a/main.m3u8');
  for (const reference of ['https://elsewhere.example/a.ts', '/other/a.ts', '//media.example.test.evil/a.ts']) assert.throws(() => onServer(reference, server + '/Videos/a/', root), reference);
  assert.equal(variantOf('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nmain.m3u8\n', new URL(server + '/Videos/a/master.m3u8'), root).pathname, '/jellyfin/Videos/a/main.m3u8');
  const segments = segmentsOf(playlist(3), new URL(server + '/Videos/a/main.m3u8'), root);
  assert.deepEqual(segments.map(segment => segment.duration), [6, 6, 2.5]);
  assert.throws(() => segmentsOf(playlist(3, false), new URL(server + '/Videos/a/main.m3u8'), root), /complete playlist/);
  assert.throws(() => segmentsOf('#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:6,\na.mp4\n#EXT-X-ENDLIST', new URL(server + '/Videos/a/main.m3u8'), root));
  assert.equal(localPlaylist(segments), '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:6.000000,\n0.ts\n#EXTINF:6.000000,\n1.ts\n#EXTINF:2.500000,\n2.ts\n#EXT-X-ENDLIST\n');
});

test('requests are checked field by field', () => {
  assert.equal(validRequest(request()), true);
  for (const extra of [{ size: 'huge' }, { server: 'file:///etc' }, { itemId: '../x' }, { title: '' }, { runtime: -1 }, { token: 'a\nb' }]) assert.equal(validRequest(request(extra)), false, JSON.stringify(extra));
  assert.equal(validRequest({ ...request(), path: '/tmp' }), false);
});

test('a download saves every segment, a local playlist and the artwork, then stops the conversion', async () => {
  const root = await folder(), { calls, fetch } = fakeServer();
  try {
    const downloads = new OfflineDownloads({ root, fetch, now: () => 1000 });
    await downloads.load();
    const started = await downloads.start(request());
    assert.equal(started.state, 'queued');
    const entry = await settled(downloads, request().accountId);
    assert.equal(entry.state, 'complete'); assert.equal(entry.progress, 1); assert.equal(entry.art, true);
    assert.deepEqual((await readdir(join(root, entry.id))).sort(), ['0.ts', '1.ts', '2.ts', 'art.jpg', 'index.m3u8']);
    const master = calls[0].url;
    assert.equal(master.pathname, '/jellyfin/Videos/movie-1/master.m3u8');
    for (const [key, value] of Object.entries({ MediaSourceId: 'source-1', VideoCodec: 'h264', MaxWidth: String(SIZES.standard.maxWidth), VideoBitRate: String(SIZES.standard.videoBitRate), SegmentContainer: 'ts' })) assert.equal(master.searchParams.get(key), value, key);
    assert.match(master.searchParams.get('PlaySessionId'), /^reel-download-[0-9a-f]{32}$/);
    // The token travels only in the Authorization header, never in a URL or on disk.
    assert.ok(calls.every(call => call.authorization?.includes('Token="synthetic-token"') && !call.url.toString().includes('synthetic-token')));
    assert.equal((await readFile(join(root, 'index.json'), 'utf8')).includes('synthetic-token'), false);
    const stop = calls.find(call => call.method === 'DELETE');
    assert.equal(stop.url.pathname, '/jellyfin/Videos/ActiveEncodings');
    assert.equal(stop.url.searchParams.get('playSessionId'), master.searchParams.get('PlaySessionId'));
    const response = await offlineResponse(downloads, new Request(`reel://app/offline/${entry.id}/index.m3u8`));
    assert.equal(response.headers.get('content-type'), 'application/vnd.apple.mpegurl');
    assert.match(await response.text(), /0\.ts/);
    // URL parsing folds `..` away, so the index is never an offline file; the app's asset handler answers 404.
    const escaped = await offlineResponse(downloads, new Request(`reel://app/offline/${entry.id}/../index.json`));
    assert.ok(escaped === undefined || escaped.status === 404);
    assert.equal((await offlineResponse(downloads, new Request(`reel://app/offline/${entry.id}/notes.txt`))).status, 404);
    assert.equal(await offlineResponse(downloads, new Request('reel://app/index.html')), undefined);
    assert.equal(await downloads.setPosition(request().accountId, entry.id, 7.4), true);
    assert.equal(downloads.list(request().accountId)[0].position, 7);
    assert.deepEqual(downloads.list('https://other.example.test|user'), []);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('a segment that keeps failing fails the download and leaves no files', async () => {
  const root = await folder(), { fetch } = fakeServer({ failSegment: '/jellyfin/Videos/movie-1/hls1/main/1.ts' });
  try {
    const downloads = new OfflineDownloads({ root, fetch });
    await downloads.load(); await downloads.start(request());
    const entry = await settled(downloads, request().accountId);
    assert.equal(entry.state, 'failed'); assert.equal(entry.error, 'Your server answered 500.');
    assert.deepEqual(await readdir(root), ['index.json']);
    assert.equal(downloads.file(entry.id, 'index.m3u8'), undefined);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('removing, signing out and restarting', async () => {
  const root = await folder(), { fetch } = fakeServer();
  try {
    const downloads = new OfflineDownloads({ root, fetch });
    await downloads.load(); await downloads.start(request());
    const entry = await settled(downloads, request().accountId);
    assert.equal(await downloads.remove('someone else', entry.id), false);
    const reloaded = new OfflineDownloads({ root, fetch });
    await reloaded.load();
    assert.equal(reloaded.list(request().accountId)[0].state, 'complete');
    await reloaded.forget(request().accountId);
    assert.deepEqual(reloaded.list(request().accountId), []);
    assert.deepEqual(await readdir(root), ['index.json']);
  } finally { await rm(root, { recursive: true, force: true }); }
});
