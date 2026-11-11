import test from 'node:test';
import assert from 'node:assert/strict';
import { DoubleTapSeek, ScreenWake, SystemMediaControls } from '../src/player-system.ts';

function session(refuse: string[] = []) {
  const handlers = new Map<string, ((details: { seekOffset?: number; seekTime?: number }) => void) | null>();
  const positions: unknown[] = [];
  return {
    handlers, positions, metadata: undefined as unknown, playbackState: 'none' as 'none' | 'paused' | 'playing',
    setActionHandler(action: string, handler: ((details: { seekOffset?: number; seekTime?: number }) => void) | null) {
      if (refuse.includes(action)) throw new TypeError('unknown action'); handlers.set(action, handler);
    },
    setPositionState(state?: unknown) { positions.push(state); }
  };
}
function actions() {
  const calls: string[] = [];
  return { calls, play: () => calls.push('play'), pause: () => calls.push('pause'), stop: () => calls.push('stop'), seekBy: (seconds: number) => calls.push('by ' + seconds), seekTo: (seconds: number) => calls.push('to ' + seconds), previous: () => calls.push('previous'), next: () => calls.push('next') };
}
const metadata = (init: unknown) => init;

test('system media controls describe the title and route each action to the player', () => {
  const system = session(), act = actions();
  const controls = new SystemMediaControls(system, metadata, act);
  controls.open({ title: 'A new beginning', artist: 'Out of the Blue', album: 'Season 1' });
  assert.deepEqual(system.metadata, { title: 'A new beginning', artist: 'Out of the Blue', album: 'Season 1', artwork: [] });
  system.handlers.get('play')!({}); system.handlers.get('pause')!({}); system.handlers.get('stop')!({});
  system.handlers.get('seekbackward')!({}); system.handlers.get('seekforward')!({ seekOffset: 30 });
  system.handlers.get('seekto')!({ seekTime: 42 }); system.handlers.get('seekto')!({}); system.handlers.get('seekto')!({ seekTime: Number.NaN });
  assert.deepEqual(act.calls, ['play', 'pause', 'stop', 'by -10', 'by 30', 'to 42']);
  assert.equal(system.handlers.get('previoustrack'), null); assert.equal(system.handlers.get('nexttrack'), null);
  controls.setEpisodes(false, true);
  assert.equal(system.handlers.get('previoustrack'), null); system.handlers.get('nexttrack')!({});
  assert.equal(act.calls.at(-1), 'next');
  controls.setState('playing'); assert.equal(system.playbackState, 'playing');
});

test('system media controls take artwork only for the title that is open', () => {
  const system = session();
  const controls = new SystemMediaControls(system, metadata, actions());
  controls.setArtwork('blob:early', 'Film'); assert.equal(system.metadata, undefined);
  controls.open({ title: 'Film' });
  controls.setArtwork('blob:other', 'Another film');
  assert.deepEqual((system.metadata as { artwork: unknown[] }).artwork, []);
  controls.setArtwork('blob:film', 'Film');
  assert.deepEqual((system.metadata as { artwork: unknown[] }).artwork, [{ src: 'blob:film' }]);
});

test('system media controls guard the position and clear everything on close', () => {
  const system = session(), controls = new SystemMediaControls(system, metadata, actions());
  controls.setPosition(100, 10, 1); assert.equal(system.positions.length, 0, 'nothing is reported before a title opens');
  controls.open({ title: 'Film' });
  controls.setPosition(100, 10, 1); controls.setPosition(Number.POSITIVE_INFINITY, 10, 1); controls.setPosition(Number.NaN, 0, 1); controls.setPosition(100, 250, 0);
  assert.deepEqual(system.positions, [{ duration: 100, position: 10, playbackRate: 1 }, undefined, undefined, { duration: 100, position: 100, playbackRate: 1 }]);
  controls.close();
  assert.equal(system.metadata, null); assert.equal(system.playbackState, 'none');
  for (const action of ['play', 'pause', 'stop', 'seekbackward', 'seekforward', 'seekto', 'previoustrack', 'nexttrack']) assert.equal(system.handlers.get(action), null, action);
  controls.setState('playing'); assert.equal(system.playbackState, 'none', 'a closed player reports nothing');
  controls.setArtwork('blob:late', 'Film'); assert.equal(system.metadata, null);
});

test('system media controls work without a media session and with unknown actions', () => {
  const absent = new SystemMediaControls(undefined, metadata, actions());
  absent.open({ title: 'Film' }); absent.setState('playing'); absent.setPosition(10, 1, 1); absent.setEpisodes(true, true); absent.close();
  const system = session(['seekto', 'stop']);
  const controls = new SystemMediaControls(system, metadata, actions());
  controls.open({ title: 'Film' });
  assert.ok(system.handlers.get('play')); assert.equal(system.handlers.has('seekto'), false);
  controls.close();
});

function wakeLock() {
  const sentinels: { released: boolean; listeners: (() => void)[] }[] = [];
  let fail = false;
  return {
    sentinels, refuse(value: boolean) { fail = value; },
    request(type: 'screen') {
      assert.equal(type, 'screen');
      if (fail) return Promise.reject(new Error('NotAllowedError'));
      const state = { released: false, listeners: [] as (() => void)[] }; sentinels.push(state);
      return Promise.resolve({ release: async () => { state.released = true; state.listeners.forEach(listener => listener()); }, addEventListener: (_type: 'release', listener: () => void) => { state.listeners.push(listener); } });
    }
  };
}
const settle = () => new Promise<void>(resolve => setImmediate(resolve));

test('the screen stays awake only while a video plays', async () => {
  const lock = wakeLock(), wake = new ScreenWake(lock);
  wake.set(true); await settle();
  assert.equal(wake.held, true); assert.equal(lock.sentinels.length, 1);
  wake.set(true); await settle(); assert.equal(lock.sentinels.length, 1, 'one lock is enough');
  wake.set(false); await settle();
  assert.equal(wake.held, false); assert.equal(lock.sentinels[0].released, true);
});

test('a wake lock that arrives after a pause is given back, and one the browser drops is asked for again', async () => {
  const lock = wakeLock(), wake = new ScreenWake(lock);
  wake.set(true); wake.set(false); await settle();
  assert.equal(wake.held, false); assert.equal(lock.sentinels[0].released, true);
  wake.set(true); await settle(); assert.equal(wake.held, true);
  // The browser releases the lock when the page is hidden.
  lock.sentinels[1].listeners.forEach(listener => listener());
  assert.equal(wake.held, false);
  wake.set(true); await settle(); assert.equal(wake.held, true); assert.equal(lock.sentinels.length, 3);
});

test('a missing or refused wake lock is not an error', async () => {
  const absent = new ScreenWake(undefined); absent.set(true); absent.set(false); assert.equal(absent.held, false);
  const lock = wakeLock(); lock.refuse(true);
  const wake = new ScreenWake(lock); wake.set(true); await settle(); assert.equal(wake.held, false);
  const throwing = new ScreenWake({ request() { throw new Error('insecure page'); } }); throwing.set(true); assert.equal(throwing.held, false);
});

test('a double tap seeks on its side of the picture and a single tap never does', () => {
  const taps = new DoubleTapSeek();
  assert.equal(taps.tap(700, 200, 800, 0), undefined, 'the first tap only wakes the controls');
  assert.equal(taps.tap(705, 204, 800, 200), 1);
  assert.equal(taps.tap(702, 198, 800, 400), 1, 'each further tap adds a step');
  assert.equal(taps.tap(700, 200, 800, 900), undefined, 'a slow tap starts again');
  assert.equal(taps.tap(100, 200, 800, 1000), undefined, 'so does a tap somewhere else');
  assert.equal(taps.tap(104, 204, 800, 1200), -1);
});

test('the middle of the picture, a far second tap and a changed side never seek', () => {
  const taps = new DoubleTapSeek();
  assert.equal(taps.tap(400, 200, 800, 0), undefined); assert.equal(taps.tap(400, 200, 800, 100), undefined);
  assert.equal(taps.tap(700, 200, 800, 1000), undefined); assert.equal(taps.tap(700, 300, 800, 1100), undefined, 'too far apart');
  // A narrow picture: both sides are within reach of each other.
  assert.equal(taps.tap(70, 50, 200, 2000), undefined); assert.equal(taps.tap(110, 50, 200, 2100), undefined);
  assert.equal(taps.tap(130, 50, 200, 2200), undefined); assert.equal(taps.tap(132, 50, 200, 2300), 1);
  taps.reset(); assert.equal(taps.tap(132, 50, 200, 2400), undefined);
  assert.equal(new DoubleTapSeek().tap(10, 10, 0, 0), undefined);
});
