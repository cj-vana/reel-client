import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { setImmediate as settle } from 'node:timers/promises';
import { JellyfinAPI } from '../src/api.ts';
import { ReelPlayer } from '../src/player.ts';
import type { Account, MediaItem, PlaybackInfo, RuntimePlatform } from '../src/types.ts';

// Models the observed LG failure: a seek made before the decoder has played never
// finishes, even at readyState 4. Once activated, the same seek can finish.
class PipelineVideo extends EventTarget {
  playsInline = false; preload = ''; muted = false; style = { visibility: '' };
  paused = true; ended = false; seeking = false; readyState = 0; duration = 14; src = '';
  value = 0; activated = false; playCalls = 0; writes: number[] = [];
  activationPolicies: Array<{ muted: boolean; visibility: string }> = [];
  seekMode: 'settled' | 'pending' | 'wrong' | 'throw' = 'settled';
  playMode: 'automatic' | 'manual' | 'reject' | 'deferred' = 'automatic';
  rejectPlay?: (reason: Error) => void;
  onSeek?: () => void;
  get currentTime(): number { return this.value; }
  set currentTime(value: number) {
    if (this.seekMode === 'throw') throw Error('Synthetic seek rejection');
    this.writes.push(value); this.value = value; this.seeking = true; this.onSeek?.();
    if (this.activated && ['settled', 'wrong'].includes(this.seekMode)) {
      this.value = this.seekMode === 'wrong' ? 0 : value;
      this.seeking = false; this.emit('seeked');
    }
  }
  setAttribute(): void {}
  removeAttribute(name: string): void { if (name === 'src') this.src = ''; }
  canPlayType(): string { return 'probably'; }
  pause(): void { this.paused = true; this.emit('pause'); }
  load(): void { if (!this.src) { this.value = 0; this.activated = false; this.seeking = false; this.ended = false; } }
  play(): Promise<void> {
    this.playCalls++;
    this.activationPolicies.push({ muted: this.muted, visibility: this.style.visibility });
    if (this.playMode === 'reject') return Promise.reject(Error('Synthetic autoplay denial'));
    if (this.playMode === 'deferred') return new Promise((_resolve, reject) => { this.rejectPlay = reject; });
    if (this.playMode === 'automatic') this.activate();
    return Promise.resolve();
  }
  activate(): void {
    this.paused = false; this.activated = true;
    // Neither early native event may leak position zero into local/server history.
    this.emit('timeupdate'); this.emit('playing');
  }
  emit(name: string): void { this.dispatchEvent(new Event(name)); }
  ready(): void { this.readyState = 4; this.emit('loadedmetadata'); this.emit('canplay'); }
  finishSeek(value = 5): void { this.value = value; this.seeking = false; this.emit('seeked'); }
}
const item: MediaItem = { Id: 'synthetic-movie', Name: 'Synthetic movie', MediaType: 'Video' };
type Report = { session: string; event: string; seconds: number; paused: boolean };
function harness(t: TestContext, options: { platform?: RuntimePlatform; container?: string; history?: boolean; remote?: boolean; mediaType?: string | null; itemType?: string } = {}) {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'window');
  Object.defineProperty(globalThis, 'window', { configurable: true, value: new EventTarget() });
  t.after(() => { if (descriptor) Object.defineProperty(globalThis, 'window', descriptor); else Reflect.deleteProperty(globalThis, 'window'); });
  const reports: Report[] = [], cleanup: string[] = [], positions: number[] = [], states: string[] = [];
  let sequence = 0;
  const connect = (id: string) => {
    const server = options.remote ? 'https://media.example' : 'http://127.0.0.1:18771';
    const account: Account = { id, server, userId: id, name: id, token: 'fixture-' + id, serverName: 'Fixture', remember: false };
    const api = new JellyfinAPI(account, server, 'owned-device-' + id, true, options.history ?? true);
    t.mock.method(api, 'playback', async (): Promise<PlaybackInfo> => ({ PlaySessionId: id + '-' + ++sequence, MediaSources: [{ Id: 'source', Container: options.container ?? 'mp4', SupportsDirectPlay: true }] }));
    t.mock.method(api, 'report', async (_item, _source, session, _method, event, seconds, paused) => { reports.push({ session, event, seconds, paused }); });
    t.mock.method(api, 'cleanup', async session => { cleanup.push(session); });
    return api;
  };
  const api = connect('first'), video = new PipelineVideo();
  const player = new ReelPlayer(video as unknown as HTMLVideoElement, options.platform ?? 'webos');
  player.onPosition = (_item, seconds) => positions.push(seconds); player.onState = state => states.push(state);
  const open = (start = 5, owner = api) => player.open(owner, { ...item, MediaType: options.mediaType === null ? undefined : options.mediaType ?? 'Video', Type: options.itemType }, { bitrate: 20_000_000, start });
  t.after(async () => { await player.closeAndDrain(); player.reports.dispose(); });
  return { api, video, player, reports, cleanup, positions, states, connect, open };
}

test('LG initial positive seek cannot remain deadlocked before decoder activation', async t => {
  const h = harness(t); await h.open(); h.video.ready(); await settle();
  assert.equal(h.video.playCalls, 1, 'The decoder must start before its initial seek can settle');
  assert.equal(h.video.seeking, false); assert.equal(h.video.currentTime, 5);
  assert.equal(h.states.at(-1), 'playing');
});

test('LG direct MP4 activates silently before initial seek and reports only the confirmed resume', async t => {
  const h = harness(t); await h.open();
  assert.equal(h.video.preload, 'metadata'); assert.equal(h.video.muted, true); assert.equal(h.video.style.visibility, 'hidden');
  h.video.readyState = 4; h.video.emit('loadedmetadata');
  assert.deepEqual(h.video.writes, []); assert.equal(h.video.playCalls, 0);
  h.video.emit('canplay'); await h.player.reports.flush();
  assert.equal(h.video.playCalls, 1); assert.deepEqual(h.video.writes, [5]); assert.equal(h.video.seeking, false);
  assert.deepEqual(h.video.activationPolicies, [{ muted: true, visibility: 'hidden' }]);
  assert.equal(h.video.muted, false); assert.equal(h.video.style.visibility, '');
  assert.deepEqual(h.states, ['preparing', 'playing']); assert.deepEqual(h.positions, [5]);
  assert.deepEqual(h.reports.map(({ event, seconds }) => ({ event, seconds })), [{ event: '', seconds: 5 }]);
});

test('play promise resolution alone cannot consume seek, expose video or publish history', async t => {
  const h = harness(t); h.video.playMode = 'manual'; await h.open(); h.video.ready(); await settle();
  for (const name of ['timeupdate', 'pause', 'seeked', 'loadedmetadata', 'canplay']) h.video.emit(name);
  h.player.seek(1); h.player.skip(10); h.player.toggle(); await h.player.reports.flush();
  assert.equal(h.video.playCalls, 1); assert.deepEqual(h.video.writes, []); assert.deepEqual(h.positions, []); assert.deepEqual(h.reports, []);
  assert.deepEqual(h.states, ['preparing']); assert.equal(h.video.muted, true); assert.equal(h.video.style.visibility, 'hidden');
  h.video.activate(); await h.player.reports.flush(); assert.deepEqual(h.positions, [5]); assert.equal(h.reports[0].seconds, 5);
});

for (const clock of [0, 1, NaN]) test('settled wrong clock ' + clock + ' remains concealed and unreported', async t => {
  const h = harness(t); h.video.seekMode = 'pending'; await h.open(); h.video.ready(); h.video.finishSeek(clock);
  for (const name of ['canplay', 'playing', 'loadedmetadata', 'timeupdate']) h.video.emit(name);
  await h.player.reports.flush(); assert.deepEqual(h.reports, []); assert.deepEqual(h.positions, []);
  assert.equal(h.video.muted, true); assert.equal(h.video.style.visibility, 'hidden'); assert.deepEqual(h.video.writes, [5]);
  h.video.finishSeek(); await h.player.reports.flush(); assert.equal(h.reports[0].seconds, 5); assert.equal(h.video.playCalls, 1);
});

test('matching clock still requires native seeking false and actual readiness', async t => {
  const h = harness(t); h.video.seekMode = 'pending'; await h.open(); h.video.ready();
  h.video.emit('seeked'); assert.deepEqual(h.positions, []);
  h.video.readyState = 2; h.video.finishSeek(); assert.deepEqual(h.positions, []);
  h.video.readyState = 4; h.video.emit('canplay'); assert.deepEqual(h.positions, [5]);
});

test('duration clamp is confirmed before reporting and later ready events cannot rewind', async t => {
  const h = harness(t); await h.open(20); h.video.ready(); await h.player.reports.flush();
  assert.deepEqual(h.video.writes, [13.75]); assert.equal(h.reports[0].seconds, 13.75);
  h.video.value = 13.9; for (const name of ['loadedmetadata', 'canplay', 'playing', 'seeked']) h.video.emit(name);
  assert.deepEqual(h.video.writes, [13.75]); assert.equal(h.video.playCalls, 1);
});

for (const cause of ['play', 'seek', 'timeout', 'eof'] as const) test(cause + ' failure preserves resume and Retry can recover', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const h = harness(t); if (cause === 'play') h.video.playMode = 'reject';
  if (cause === 'seek') h.video.seekMode = 'throw';
  if (cause === 'timeout' || cause === 'eof') h.video.seekMode = 'pending';
  await h.open(); h.video.ready(); await settle();
  if (cause === 'timeout') t.mock.timers.tick(15000);
  if (cause === 'eof') { h.video.ended = true; h.video.emit('ended'); }
  assert.equal(h.states.at(-1), 'error'); assert.deepEqual(h.positions, []); assert.deepEqual(h.reports, []);
  assert.equal(h.video.muted, false); assert.equal(h.video.style.visibility, ''); assert.equal(h.video.src, '');
  h.video.playMode = 'automatic'; h.video.seekMode = 'settled'; h.player.retry(); await settle(); h.video.ready(); await h.player.reports.flush();
  assert.equal(h.reports[0].seconds, 5); assert.deepEqual(h.cleanup, ['first-1']);
  t.mock.timers.tick(15000); assert.equal(h.states.at(-1), 'playing');
});

test('close during bootstrap never publishes zero and clears its timeout', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const h = harness(t); h.video.playMode = 'manual'; await h.open(); h.video.ready();
  await h.player.closeAndDrain(); t.mock.timers.tick(15000);
  assert.deepEqual(h.reports, []); assert.deepEqual(h.positions, []); assert.deepEqual(h.cleanup, ['first-1']);
  assert.equal(h.video.muted, false); assert.equal(h.video.style.visibility, ''); assert.deepEqual(h.states, ['preparing']);
});

test('stale activation rejection cannot release or expose a replacement account', async t => {
  const h = harness(t); h.video.playMode = 'deferred'; await h.open(); h.video.ready(); const rejectOld = h.video.rejectPlay!;
  await h.open(7, h.connect('second')); h.video.playMode = 'manual'; h.video.ready(); rejectOld(Error('Late rejection')); await settle();
  assert.equal(h.video.muted, true); assert.equal(h.video.style.visibility, 'hidden'); assert.equal(h.states.at(-1), 'preparing');
  assert.deepEqual(h.cleanup, ['first-1']); h.video.activate(); await h.player.reports.flush();
  assert.deepEqual(h.reports.map(({ session, seconds }) => ({ session, seconds })), [{ session: 'second-2', seconds: 7 }]);
});

test('reentrant close from confirmed position never starts a released owner', async t => {
  const h = harness(t); h.player.onPosition = () => h.player.close(); await h.open(); h.video.ready(); await h.player.reports.flush();
  assert.deepEqual(h.reports, []); assert.deepEqual(h.cleanup, ['first-1']); assert.equal(h.video.src, '');
  assert.equal(h.video.muted, false); assert.equal(h.video.style.visibility, ''); assert.equal(h.states.includes('playing'), false);
});

test('owned concealment restores prior mute/style and respects later external policy', async t => {
  const h = harness(t); h.video.muted = true; h.video.style.visibility = 'visible'; await h.open(); h.video.ready();
  assert.equal(h.video.muted, true); assert.equal(h.video.style.visibility, 'visible');
  await h.open(); h.video.muted = false; h.video.style.visibility = 'collapse'; await h.player.closeAndDrain();
  assert.equal(h.video.muted, false); assert.equal(h.video.style.visibility, 'collapse');
});

test('protected remote account never reports even after confirmed direct resume', async t => {
  const h = harness(t, { remote: true }); await h.open(); h.video.ready(); await h.player.reports.flush();
  assert.equal(h.states.at(-1), 'playing'); assert.deepEqual(h.reports, []);
});

for (const options of [{ platform: 'web' }, { platform: 'desktop' }, { platform: 'tizen' }, { container: 'mkv' }, { mediaType: 'Audio' }, ...['Audio', 'MusicAlbum', 'AudioBook'].map(itemType => ({ itemType, mediaType: null }))] as const)
  test('unchanged metadata seek outside direct MP4 video webOS scope ' + JSON.stringify(options), async t => {
    const h = harness(t, options); await h.open(); h.video.emit('loadedmetadata');
    assert.deepEqual(h.video.writes, [5]); assert.equal(h.video.playCalls, 0); assert.equal(h.video.muted, false); assert.equal(h.video.style.visibility, '');
  });

test('zero start remains ordinary visible unmuted playback', async t => {
  const h = harness(t); await h.open(0); h.video.ready(); await h.player.reports.flush();
  assert.deepEqual(h.video.writes, []); assert.equal(h.video.playCalls, 1); assert.deepEqual(h.video.activationPolicies, [{ muted: false, visibility: '' }]);
});

test('LG paused restart activates and confirms its seek before pausing and revealing', async t => {
  const h = harness(t);
  await h.player.open(h.api, item, { bitrate: 20_000_000, start: 5, paused: true });
  h.video.seekMode = 'pending'; h.video.ready();
  assert.equal(h.video.paused, false); assert.equal(h.video.muted, true); assert.equal(h.video.style.visibility, 'hidden');
  assert.deepEqual(h.reports, []); h.video.finishSeek(); await h.player.reports.flush();
  assert.equal(h.video.playCalls, 1); assert.equal(h.video.paused, true); assert.equal(h.video.currentTime, 5);
  assert.equal(h.video.muted, false); assert.equal(h.video.style.visibility, '');
  assert.deepEqual(h.states, ['preparing', 'paused']);
  assert.deepEqual(h.reports.map(({ event, seconds, paused }) => ({ event, seconds, paused })), [{ event: '', seconds: 5, paused: true }]);
  h.player.toggle(); assert.equal(h.video.paused, false); assert.equal(h.states.at(-1), 'playing');
});
test('ordinary paused start reports its position without starting the decoder', async t => {
  const h = harness(t, { platform: 'web' });
  await h.player.open(h.api, item, { bitrate: 20_000_000, start: 0, paused: true });
  h.video.ready(); await h.player.reports.flush();
  assert.equal(h.video.playCalls, 0); assert.equal(h.video.paused, true); assert.equal(h.states.at(-1), 'paused');
  assert.equal(h.reports[0].paused, true);
});
test('closing a pending paused LG restart never publishes or reveals stale playback', async t => {
  const h = harness(t); h.video.seekMode = 'pending';
  await h.player.open(h.api, item, { bitrate: 20_000_000, start: 5, paused: true }); h.video.ready(); h.player.close();
  h.video.finishSeek(); await h.player.reports.flush();
  assert.deepEqual(h.reports, []); assert.deepEqual(h.states, ['preparing']); assert.equal(h.video.paused, true);
  assert.equal(h.video.muted, false); assert.equal(h.video.style.visibility, '');
});

test('an explicit version selects its unique negotiated source rather than the first playable source', async t => {
  const h = harness(t);
  t.mock.method(h.api, 'playback', async () => ({ PlaySessionId: 'selected-version', MediaSources: [{ Id: 'wrong', Container: 'mp4', SupportsDirectPlay: true }, { Id: 'chosen', Container: 'mp4', SupportsDirectPlay: true }] }));
  await h.player.open(h.api, item, { bitrate: 20_000_000, source: 'chosen', start: 0, paused: true });
  assert.equal(new URL(h.video.src).searchParams.get('mediaSourceId'), 'chosen'); h.video.ready(); await h.player.reports.flush();
  assert.equal(h.states.at(-1), 'paused');
});
for (const ids of [['wrong'], ['chosen', 'chosen']]) test('missing or ambiguous negotiated version fails without playing: ' + ids.join(','), async t => {
  const h = harness(t);
  t.mock.method(h.api, 'playback', async () => ({ PlaySessionId: 'bad-version', MediaSources: ids.map(Id => ({ Id, Container: 'mp4', SupportsDirectPlay: true })) }));
  await h.player.open(h.api, item, { bitrate: 20_000_000, source: 'chosen', start: 5, paused: true });
  assert.equal(h.states.at(-1), 'error'); assert.equal(h.video.playCalls, 0); assert.deepEqual(h.reports, []); assert.ok(h.cleanup.includes('bad-version'));
});
