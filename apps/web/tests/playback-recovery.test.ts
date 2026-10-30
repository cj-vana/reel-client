import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { setImmediate as settle } from 'node:timers/promises';
import { JellyfinAPI } from '../src/api.ts';
import { ReelPlayer } from '../src/player.ts';
import type { MediaItem } from '../src/types.ts';

class RecoveryVideo extends EventTarget {
  playsInline = false; preload = ''; paused = true; ended = false; duration = 14;
  readyState = 0; error: { code: number } | null = null; src = ''; value = 0; rejectPlay = false;
  get currentTime(): number { return this.value; }
  set currentTime(value: number) { this.value = value; this.emit('seeked'); }
  setAttribute(): void {}
  removeAttribute(name: string): void { if (name === 'src') this.src = ''; }
  canPlayType(): string { return 'probably'; }
  pause(): void { this.paused = true; this.emit('pause'); }
  play(): Promise<void> {
    if (this.rejectPlay) return Promise.reject(Error('Synthetic autoplay denial'));
    this.paused = false; this.emit('playing'); return Promise.resolve();
  }
  load(): void { this.value = 0; this.readyState = 0; this.error = null; }
  ready(): void { this.readyState = 4; this.emit('loadedmetadata'); this.emit('canplay'); }
  emit(event: string): void { this.dispatchEvent(new Event(event)); }
  advance(value: number): void { this.value = value; this.emit('timeupdate'); }
  fail(reset = true): void {
    // A native source reload resets paused and currentTime before reporting MediaError.
    // The reset's pause/timeupdate must not become the user's desired recovery state.
    this.paused = true; this.value = 0;
    if (reset) { this.readyState = 0; this.emit('pause'); this.emit('emptied'); this.emit('timeupdate'); }
    this.error = { code: 3 }; this.emit('pause'); this.emit('timeupdate'); this.emit('error');
  }
}

function harness(t: TestContext) {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'window');
  Object.defineProperty(globalThis, 'window', { configurable: true, value: new EventTarget() });
  t.after(() => { if (descriptor) Object.defineProperty(globalThis, 'window', descriptor); else Reflect.deleteProperty(globalThis, 'window'); });
  const server = 'http://127.0.0.1:18771', api = new JellyfinAPI({ id: 'recovery', server, userId: 'recovery', token: 'fixture-recovery', name: 'Synthetic', serverName: 'Fixture', remember: false }, server, 'owned-recovery', true, true);
  let sequence = 0, rejectNegotiation = false;
  const reports: Array<{ event: string; seconds: number; paused: boolean }> = [];
  t.mock.method(api, 'playback', async () => {
    if (rejectNegotiation) throw Error('Synthetic negotiation failure');
    return { PlaySessionId: 'owned-' + ++sequence, MediaSources: [{ Id: 'source', Container: 'mp4', SupportsDirectPlay: true }] };
  });
  t.mock.method(api, 'cleanup', async () => {});
  t.mock.method(api, 'report', async (_item, _source, _session, _method, event, seconds, paused) => { reports.push({ event, seconds, paused }); });
  const video = new RecoveryVideo(), player = new ReelPlayer(video as unknown as HTMLVideoElement), states: string[] = [];
  player.onState = state => states.push(state);
  const item: MediaItem = { Id: 'owned-title', Name: 'Synthetic recovery title' };
  const open = async (paused = false, start = 0) => { await player.open(api, item, { bitrate: 20000000, start, paused }); video.ready(); await settle(); };
  t.after(async () => { await player.closeAndDrain(); player.reports.dispose(); });
  return { video, player, states, reports, open, negotiationFails(value: boolean) { rejectNegotiation = value; } };
}

for (const reset of [true, false]) test(`native error preserves playing intent and last confirmed position (reset=${reset})`, async t => {
  const h = harness(t); await h.open(); h.video.advance(4);
  h.video.fail(reset); await settle(); h.video.ready(); await h.player.reports.flush();
  assert.equal(h.video.paused, false); assert.equal(h.video.currentTime, 4); assert.equal(h.states.at(-1), 'playing');
  assert.equal(h.reports.at(-1)?.seconds, 4); assert.ok(h.reports.filter(r => r.event === '/Stopped').every(r => r.seconds === 4));
});
test('a real native pause before error remains paused after recovery', async t => {
  const h = harness(t); await h.open(); h.video.advance(4); h.video.pause();
  h.video.fail(); await settle(); h.video.ready(); await h.player.reports.flush();
  assert.equal(h.video.paused, true); assert.equal(h.video.currentTime, 4); assert.equal(h.states.at(-1), 'paused'); assert.equal(h.reports.at(-1)?.paused, true);
});
test('an explicit paused restart retains its intent through native failure', async t => {
  const h = harness(t); await h.open(true, 4);
  h.video.fail(); await settle(); h.video.ready();
  assert.equal(h.video.paused, true); assert.equal(h.video.currentTime, 4); assert.equal(h.states.at(-1), 'paused');
});
test('resuming an explicit paused restart updates recovery intent', async t => {
  const h = harness(t); await h.open(true, 4); h.player.toggle(); h.video.advance(5);
  h.video.fail(); await settle(); h.video.ready();
  assert.equal(h.video.paused, false); assert.equal(h.video.currentTime, 5); assert.equal(h.states.at(-1), 'playing');
});
test('native Play during buffering updates intent before playing can arrive', async t => {
  const h = harness(t); await h.open(true, 4);
  h.video.paused = false; h.video.emit('play');
  h.video.fail(); await settle(); h.video.ready();
  assert.equal(h.video.paused, false); assert.equal(h.video.currentTime, 4); assert.equal(h.states.at(-1), 'playing');
});
test('queued pause after native Play cannot override the current playing intent', async t => {
  const h = harness(t); await h.open(true, 4);
  h.video.paused = false; h.video.emit('play'); h.video.emit('pause');
  h.video.fail(); await settle(); h.video.ready();
  assert.equal(h.video.paused, false); assert.equal(h.video.currentTime, 4); assert.equal(h.states.at(-1), 'playing');
});
test('failed fallback then Retry preserves pre-error playing state and clock', async t => {
  const h = harness(t); await h.open(); h.video.advance(4); h.negotiationFails(true);
  h.video.fail(); await settle(); assert.equal(h.states.at(-1), 'error');
  h.negotiationFails(false); h.player.retry(); await settle(); h.video.ready();
  assert.equal(h.video.paused, false); assert.equal(h.video.currentTime, 4); assert.equal(h.states.at(-1), 'playing');
});
test('autoplay denial retains paused recovery state without another unwanted play', async t => {
  const h = harness(t); h.video.rejectPlay = true; await h.open(); assert.equal(h.states.at(-1), 'paused');
  h.video.rejectPlay = false; h.video.fail(); await settle(); h.video.ready();
  assert.equal(h.video.paused, true); assert.equal(h.states.at(-1), 'paused');
});
