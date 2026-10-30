import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ApiError } from '../src/api.ts';
import { SAMPLE_RATE } from '../src/audio-fingerprint.ts';
import { frameLength, headWindow, MarkerDetector, MarkerStore, resample, tailWindow, wholeFrames, type Decoder } from '../src/intro-detection.ts';
import { type MediaItem, TICKS } from '../src/types.ts';
import { mix, programme } from './synthetic-audio.ts';

const now = async () => {};
const theme = programme(40, 99, 0.3), creditsTheme = programme(50, 77, 0.3);
const introAt = (n: number) => 10 + 7 * n, creditsAt = (n: number) => 530 + n;
const episode = (n: number): MediaItem => ({ Id: 'episode-' + n, Name: 'Episode ' + n, Type: 'Episode', SeriesId: 'show', RunTimeTicks: 600 * TICKS });
const signal = () => new AbortController().signal;
const near = (actual: number | undefined, expected: number, label: string) => assert.ok(actual !== undefined && Math.abs(actual - expected) < 1, `${label}: ${actual} s, expected about ${expected} s`);

// The fake server answers each audio request with the episode and window it asked for; the fake decoder turns
// that into synthetic audio holding the shared theme and credits music at each episode's own positions.
function fakeServer(options: { status?: number; unrelated?: Set<string> } = {}) {
  const requests: Array<{ path: string; query: Record<string, unknown> }> = [];
  const api = {
    server: 'https://media.example.test',
    async request<T>(path: string, request?: { query?: Record<string, unknown>; raw?: boolean }): Promise<T> {
      requests.push({ path, query: request?.query ?? {} });
      assert.equal(request?.raw, true);
      if (options.status) throw new ApiError('refused', options.status);
      const id = /^Audio\/([^/]+)\/stream\.mp3$/.exec(path)?.[1];
      assert.ok(id, path);
      const start = Number(request?.query?.startTimeTicks ?? 0) / TICKS;
      return new Response(JSON.stringify({ id, start, seconds: start ? 600 - start : 180 })) as T;
    }
  };
  const decode: Decoder = async bytes => {
    const { id, start, seconds } = JSON.parse(new TextDecoder().decode(bytes)) as { id: string; start: number; seconds: number };
    const n = Number(id.split('-')[1]);
    let audio = programme(seconds, n * 1000 + start);
    if (!options.unrelated?.has(id)) { audio = mix(audio, theme, introAt(n) - start); audio = mix(audio, creditsTheme, creditsAt(n) - start); }
    return audio;
  };
  return { api, requests, detector: new MarkerDetector(decode, new MarkerStore(), now) };
}

test('scan windows follow the episode length', () => {
  assert.deepEqual(headWindow(episode(1)), { start: 0, seconds: 180 });
  assert.deepEqual(tailWindow(episode(1)), { start: 480, seconds: 120 });
  assert.deepEqual(headWindow({ ...episode(1), RunTimeTicks: 3600 * TICKS }), { start: 0, seconds: 600 });
  assert.deepEqual(tailWindow({ ...episode(1), RunTimeTicks: 3600 * TICKS }), { start: 3300, seconds: 300 });
  assert.equal(tailWindow({ ...episode(1), RunTimeTicks: 200 * TICKS }), undefined);
  assert.deepEqual(headWindow({ ...episode(1), RunTimeTicks: undefined }), { start: 0, seconds: 600 });
});

test('finds the intro and the credits, and the markers of the neighboring episode as well', async () => {
  const { api, requests, detector } = fakeServer();
  const markers = await detector.detect(api, 'account', episode(2), [episode(1), episode(3)], { intro: true, credits: true }, signal());
  near(markers.intro?.start, introAt(2), 'intro start'); near(markers.intro?.end, introAt(2) + 40, 'intro end'); near(markers.credits, creditsAt(2), 'credits');
  assert.deepEqual(requests.map(request => request.path), ['Audio/episode-2/stream.mp3', 'Audio/episode-1/stream.mp3', 'Audio/episode-2/stream.mp3', 'Audio/episode-1/stream.mp3']);
  assert.deepEqual(requests.map(request => request.query.startTimeTicks), [undefined, undefined, 480 * TICKS, 480 * TICKS]);
  for (const { query } of requests) {
    assert.equal(query.audioCodec, 'mp3'); assert.equal(query.audioChannels, 1); assert.equal(query.audioBitRate, 32_000);
    // Its own play session, and no device id, so the scan and the video never stop each other.
    assert.match(String(query.playSessionId), /^reel-scan-[0-9a-f]{24}$/);
    assert.equal('deviceId' in query, false);
  }
  assert.equal(new Set(requests.map(request => request.query.playSessionId)).size, 4);
  const neighbor = detector.known('account', episode(1));
  near(neighbor.intro?.start, introAt(1), 'neighbor intro'); near(neighbor.credits, creditsAt(1), 'neighbor credits');
  assert.deepEqual(detector.known('other account', episode(1)), {});
});

test('a neighbor fingerprinted earlier in the session is compared first, so only this episode is downloaded', async () => {
  const { api, requests, detector } = fakeServer();
  await detector.detect(api, 'account', episode(2), [episode(1)], { intro: true, credits: true }, signal());
  requests.length = 0;
  const markers = await detector.detect(api, 'account', episode(3), [episode(4), episode(2)], { intro: true, credits: true }, signal());
  near(markers.intro?.start, introAt(3), 'intro start'); near(markers.credits, creditsAt(3), 'credits');
  assert.deepEqual(requests.map(request => request.path), ['Audio/episode-3/stream.mp3', 'Audio/episode-3/stream.mp3']);
  requests.length = 0;
  assert.ok((await detector.detect(api, 'account', episode(3), [episode(4)], { intro: true, credits: true }, signal())).intro);
  assert.equal(requests.length, 0, 'known markers are not scanned again');
});

test('only what the server did not mark is scanned', async () => {
  const { api, requests, detector } = fakeServer();
  const markers = await detector.detect(api, 'account', episode(2), [episode(1)], { intro: false, credits: true }, signal());
  assert.equal(markers.intro, undefined); near(markers.credits, creditsAt(2), 'credits');
  assert.deepEqual(requests.map(request => request.query.startTimeTicks), [480 * TICKS, 480 * TICKS]);
});

test('when nothing is shared, that is remembered and the episode is not scanned again', async () => {
  const { api, requests, detector } = fakeServer({ unrelated: new Set(['episode-6']) });
  assert.deepEqual(await detector.detect(api, 'account', episode(6), [episode(5)], { intro: true, credits: true }, signal()), {});
  requests.length = 0;
  assert.deepEqual(await detector.detect(api, 'account', episode(6), [episode(5)], { intro: true, credits: true }, signal()), {});
  assert.equal(requests.length, 0);
});

test('a server that refuses the audio stream is not asked again this session', async () => {
  const { api, requests, detector } = fakeServer({ status: 403 });
  assert.deepEqual(await detector.detect(api, 'account', episode(2), [episode(1)], { intro: true, credits: true }, signal()), {});
  assert.equal(requests.length, 1);
  assert.deepEqual(await detector.detect(api, 'account', episode(4), [episode(3)], { intro: true, credits: true }, signal()), {});
  assert.equal(requests.length, 1);
});

test('movies, episodes without neighbors and cancelled scans', async () => {
  const { api, requests, detector } = fakeServer();
  assert.deepEqual(await detector.detect(api, 'account', { ...episode(1), Type: 'Movie' }, [episode(2)], { intro: true, credits: true }, signal()), {});
  assert.deepEqual(await detector.detect(api, 'account', episode(1), [], { intro: true, credits: true }, signal()), {});
  assert.equal(requests.length, 0);
  const controller = new AbortController(); controller.abort();
  await assert.rejects(detector.detect(api, 'account', episode(2), [episode(1)], { intro: true, credits: true }, controller.signal), { name: 'AbortError' });
});

test('a scan reads only its own window, however much the server sends at once', async () => {
  // A busy page can receive the rest of the file in one read, and a server can send a lower bitrate than asked.
  // Either way the opening scan must stop before the credits music, or the credits would be taken for the intro.
  const decoded: number[] = [];
  const api = {
    server: 'https://media.example.test',
    async request<T>(path: string, request?: { query?: Record<string, unknown> }): Promise<T> {
      const body = new Uint8Array(3_000_000).fill(32);
      body.set(new TextEncoder().encode(JSON.stringify({ id: path.split('/')[1], start: Number(request?.query?.startTimeTicks ?? 0) / TICKS })));
      return new Response(new ReadableStream({ start(controller) { controller.enqueue(body); controller.close(); } })) as T;
    }
  };
  // Whatever the bytes, the decoder hands back the rest of the episode, theme and credits included.
  const decode: Decoder = async bytes => {
    decoded.push(bytes.length);
    const { id, start } = JSON.parse(new TextDecoder().decode(bytes.subarray(0, 64))) as { id: string; start: number };
    const n = Number(id.split('-')[1]);
    return mix(mix(programme(600 - start, n * 1000 + start), theme, introAt(n) - start), creditsTheme, creditsAt(n) - start);
  };
  const markers = await new MarkerDetector(decode, new MarkerStore(), now).detect(api, 'account', episode(2), [episode(1)], { intro: true, credits: true }, signal());
  near(markers.intro?.start, introAt(2), 'intro start'); near(markers.intro?.end, introAt(2) + 40, 'intro end'); near(markers.credits, creditsAt(2), 'credits');
  const window = (seconds: number) => Math.ceil(seconds * 32_000 / 8) + 16_384;
  assert.deepEqual(decoded, [window(180), window(180), window(120), window(120)]);
});

test('the marker store keeps found markers for months, misses for two weeks, and forgets an account', () => {
  const saved = new Map<string, string>();
  const storage = { getItem: (key: string) => saved.get(key) ?? null, setItem: (key: string, value: string) => { saved.set(key, value); } };
  const store = new MarkerStore(storage), day = 86_400_000, start = Date.UTC(2026, 9, 1);
  store.update('a|found', { i: [5, 50] }, start);
  store.update('a|missing', { i: 0 }, start);
  store.update('b|found', { c: 1200 }, start);
  const reloaded = new MarkerStore(storage);
  assert.deepEqual(reloaded.get('a|found', start + 100 * day)?.i, [5, 50]);
  assert.equal(reloaded.get('a|missing', start + 13 * day)?.i, 0);
  assert.equal(reloaded.get('a|missing', start + 15 * day), undefined);
  assert.equal(reloaded.get('a|found', start + 181 * day), undefined);
  reloaded.forget('a');
  assert.equal(new MarkerStore(storage).get('a|found', start), undefined);
  assert.equal(new MarkerStore(storage).get('b|found', start)?.c, 1200);
  saved.set('reel.markers.v1', JSON.stringify({ 'a|bad': { i: [50, 5], t: start }, 'a|worse': { c: -1, t: start }, 'a|nan': { t: 'soon' } }));
  const strict = new MarkerStore(storage);
  for (const key of ['a|bad', 'a|worse', 'a|nan']) assert.equal(strict.get(key, start), undefined, key);
});

test('a download stopped mid-frame is cut back to whole MP3 frames', () => {
  // MPEG-2 Layer III, 32 kbps at 16 kHz: 144 bytes a frame, 145 with the padding bit.
  const frame = (padding: number) => [0xff, 0xf3, 0x48 | padding, 0xc4, ...new Array(140 + padding / 2).fill(0x11)];
  // Audio data can hold bytes that look like a frame header; stepping by frame length never lands on them.
  const lookalike = frame(0); lookalike.splice(40, 4, 0xff, 0xf3, 0x18, 0xc4);
  const id3 = [0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 2, 0xaa, 0xbb];
  const bytes = Uint8Array.from([...id3, ...frame(0), ...lookalike, ...frame(2), ...frame(0).slice(0, 60)]);
  assert.equal(wholeFrames(bytes).length, id3.length + 144 + 144 + 145);
  assert.equal(frameLength(Uint8Array.from(frame(2)), 0), 145);
  assert.equal(frameLength(Uint8Array.from([0xff, 0xf3, 0xf8, 0xc4]), 0), 0, 'a reserved bitrate is not a header');
  const plain = new TextEncoder().encode('not audio');
  assert.equal(wholeFrames(plain), plain);
});

test('decoded audio at other rates is averaged down to the fingerprint rate', () => {
  const left = new Float32Array(SAMPLE_RATE * 2).fill(0.5), right = new Float32Array(SAMPLE_RATE * 2).fill(-0.1);
  const out = resample([left, right], SAMPLE_RATE * 2);
  assert.equal(out.length, SAMPLE_RATE);
  assert.ok(Math.abs(out[100] - 0.2) < 1e-6);
  const same = new Float32Array(10);
  assert.equal(resample([same], SAMPLE_RATE), same);
});
