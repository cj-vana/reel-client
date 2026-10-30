import test from 'node:test';
import assert from 'node:assert/strict';
import { Connections, type StorageLike } from '../src/storage.ts';
import { directionalScore } from '../src/navigation.ts';
import { PlaybackReports } from '../src/player.ts';
import { ArtworkCache } from '../src/artwork.ts';
import { JellyfinAPI, ApiError } from '../src/api.ts';
import type { Account } from '../src/types.ts';

function memory(): StorageLike {
  const values = new Map<string, string>();
  return { getItem: key => values.get(key) ?? null, setItem: (key, value) => { values.set(key, value); }, removeItem: key => { values.delete(key); } };
}
const account = (id: string, remember: boolean): Account => ({ id, server: 'https://media.example', token: 'token-' + id, userId: id, name: id, serverName: 'Fixture', remember });

test('connection persistence is opt-in, isolated and removable', () => {
  const storage = memory(), session = new Connections(storage);
  session.add(account('one', false));
  assert.equal(session.active?.userId, 'one');
  assert.equal(new Connections(storage).all.length, 0);
  session.add(account('two', true));
  const restored = new Connections(storage);
  assert.equal(restored.all.length, 1); assert.equal(restored.active?.userId, 'two');
  session.switch('one'); assert.equal(new Connections(storage).active, null);
  session.remove('two'); assert.equal(new Connections(storage).all.length, 0);
});

test('failed durable save cannot partially replace the signed-in account', () => {
  const storage = memory(), session = new Connections(storage);
  session.add(account('one', true));
  storage.setItem = () => { throw new Error('Quota'); };
  assert.throws(() => session.add(account('two', true)));
  assert.equal(session.active?.id, 'one'); assert.equal(session.all.length, 1);
});

test('directional navigation favors the aligned neighbor and excludes the wrong half-plane', () => {
  const origin = { left: 50, top: 50, width: 40, height: 40 };
  const aligned = { left: 100, top: 50, width: 40, height: 40 };
  const diagonal = { left: 90, top: 100, width: 40, height: 40 };
  const behind = { left: 0, top: 50, width: 40, height: 40 };
  assert.ok(directionalScore(origin, aligned, 'right') < directionalScore(origin, diagonal, 'right'));
  assert.equal(directionalScore(origin, behind, 'right'), Infinity);
  assert.equal(directionalScore(origin, aligned, 'left'), Infinity);
});

test('report queue coalesces old progress and keeps start before final stop', async () => {
  const reports = new PlaybackReports();
  const delivered: string[] = [];
  let release: (() => void) | undefined;
  const blocked = new Promise<void>(resolve => { release = resolve; });
  reports.enqueue({ sessionId: 'one', kind: 'start', send: async () => { await blocked; delivered.push('start'); } });
  for (let i = 0; i < 30; i++) reports.enqueue({ sessionId: 'one', kind: 'progress', send: async () => { delivered.push('progress-' + i); } });
  assert.equal(reports.pendingCount, 1);
  reports.enqueue({ sessionId: 'one', kind: 'stop', send: async () => { delivered.push('stop'); } });
  assert.equal(reports.pendingCount, 1); release!();
  assert.equal(await reports.flush(), true);
  assert.deepEqual(delivered, ['start', 'stop']); reports.dispose();
});

test('failed final report remains queued and succeeds on a later flush', async () => {
  const reports = new PlaybackReports(); let attempts = 0;
  reports.enqueue({ sessionId: 'one', kind: 'stop', send: async () => { attempts++; if (attempts === 1) throw new Error('Offline'); } });
  assert.equal(await reports.flush(), false); assert.equal(reports.pendingCount, 1);
  assert.equal(await reports.flush(), true); assert.equal(reports.pendingCount, 0); reports.dispose();
});

test('expired account reports cannot block a later account', async () => {
  const reports = new PlaybackReports(), delivered: string[] = [];
  reports.enqueue({ sessionId: 'expired', kind: 'stop', send: async () => { throw new ApiError('Expired', 401); } });
  await reports.flush();
  reports.enqueue({ sessionId: 'current', kind: 'start', send: async () => { delivered.push('current'); } });
  assert.equal(await reports.flush(), true); assert.deepEqual(delivered, ['current']); assert.equal(reports.pendingCount, 0); reports.dispose();
});

test('revoked live history policy discards an offline final report', async () => {
  const reports = new PlaybackReports(); let enabled = true, attempts = 0;
  reports.enqueue({ sessionId: 'one', kind: 'stop', isAllowed: () => enabled, send: async () => { attempts++; throw new Error('Offline'); } });
  assert.equal(await reports.flush(), false);
  enabled = false;
  assert.equal(await reports.flush(), true); assert.equal(attempts, 1); assert.equal(reports.pendingCount, 0); reports.dispose();
});

test('discard aborts an in-flight report and permits the next session', async () => {
  const reports = new PlaybackReports(), delivered: string[] = [];
  reports.enqueue({ sessionId: 'removed', kind: 'stop', send: signal => new Promise((_resolve, reject) => { signal?.addEventListener('abort', () => reject(new DOMException('Cancelled', 'AbortError')), { once: true }); }) });
  reports.discard();
  reports.enqueue({ sessionId: 'new', kind: 'start', send: async () => { delivered.push('new'); } });
  assert.equal(await reports.flush(), true); assert.deepEqual(delivered, ['new']); reports.dispose();
});

test('artwork cache evicts by byte budget, coalesces and revokes object URLs', async () => {
  const api = new JellyfinAPI(null, 'http://127.0.0.1', 'fixture');
  let calls = 0; api.image = async () => { calls++; return new Blob(['1234'], { type: 'image/png' }); };
  const cache = new ArtworkCache(120, 5);
  const [first, duplicate] = await Promise.all([cache.get(api, { Id: 'one', Name: 'One' }), cache.get(api, { Id: 'one', Name: 'One' })]);
  assert.equal(first, duplicate); assert.equal(calls, 1);
  const second = await cache.get(api, { Id: 'two', Name: 'Two' });
  await assert.rejects(fetch(first)); assert.equal(await (await fetch(second)).text(), '1234');
  cache.clear(); await assert.rejects(fetch(second));
});

test('artwork clear cancels stale requests and fresh loads can recover', async () => {
  const api = new JellyfinAPI(null, 'http://127.0.0.1', 'fixture');
  let cancelled = false;
  api.image = async (_item, _backdrop, _width, signal) => new Promise((_resolve, reject) => { signal?.addEventListener('abort', () => { cancelled = true; reject(new DOMException('Cancelled', 'AbortError')); }, { once: true }); });
  const cache = new ArtworkCache();
  const pending = cache.get(api, { Id: 'one', Name: 'One' }); cache.clear();
  await assert.rejects(pending, { name: 'AbortError' }); assert.equal(cancelled, true);
  api.image = async () => new Blob(['fresh'], { type: 'image/png' });
  const fresh = await cache.get(api, { Id: 'one', Name: 'One' });
  assert.equal(await (await fetch(fresh)).text(), 'fresh'); cache.clear();
});

test('route cancellation aborts pending artwork while preserving decoded images', async () => {
  const api = new JellyfinAPI(null, 'http://127.0.0.1', 'fixture');
  let calls = 0, aborted = false;
  api.image = async (_item, _backdrop, _width, signal) => {
    calls++;
    if (calls === 1) return new Blob(['cached']);
    return new Promise((_resolve, reject) => signal?.addEventListener('abort', () => {
      aborted = true; reject(new DOMException('Cancelled', 'AbortError'));
    }, { once: true }));
  };
  const cache = new ArtworkCache();
  const item = { Id: 'ready', Name: 'Ready' }, pendingItem = { Id: 'slow', Name: 'Slow' };
  const cached = await cache.get(api, item), pending = cache.get(api, pendingItem);
  cache.cancelPending();
  await assert.rejects(pending, { name: 'AbortError' });
  assert.equal(aborted, true); assert.equal(await cache.get(api, item), cached);
  assert.equal(await (await fetch(cached)).text(), 'cached'); assert.equal(calls, 2);
  cache.clear(); await assert.rejects(fetch(cached));
});

test('late artwork after route cancellation cannot replace or detach the fresh request', async () => {
  const api = new JellyfinAPI(null, 'http://127.0.0.1', 'fixture');
  const releases: Array<(blob: Blob) => void> = [];
  api.image = async () => new Promise(resolve => releases.push(resolve));
  const cache = new ArtworkCache(), item = { Id: 'same', Name: 'Same' };
  const stale = cache.get(api, item); cache.cancelPending();
  const fresh = cache.get(api, item);
  releases[0](new Blob(['stale'])); await assert.rejects(stale, { name: 'AbortError' });
  const coalesced = cache.get(api, item); assert.equal(releases.length, 2);
  releases[1](new Blob(['fresh']));
  assert.equal(await fresh, await coalesced);
  assert.equal(await (await fetch(await fresh)).text(), 'fresh'); cache.clear();
});
