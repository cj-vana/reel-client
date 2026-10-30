import test from 'node:test';
import assert from 'node:assert/strict';
import { refreshWatchedDetail, type WatchedDetailState } from '../src/detail-status.ts';
import { WatchedActions } from '../src/library-browser.ts';
import type { ItemPage, MediaItem } from '../src/types.ts';

const item = (id: string, extra: Partial<MediaItem> = {}): MediaItem => ({ Id: id, Name: id, Type: 'Series', UserData: { Played: false, IsFavorite: false, UnplayedItemCount: 3, PlaybackPositionTicks: 7 }, ...extra });
function deferred<T>() { let resolve!: (value: T) => void; let reject!: (error: unknown) => void; const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
function harness() {
  let state: WatchedDetailState | undefined = { owner: 'account|token|route|read1', item: item('series', { MediaSources: [{ Id: 'first' }, { Id: 'alternate' }] }), season: 'later-season', episodes: [item('episode', { Type: 'Episode' })] };
  const choices = { source: 'alternate', audio: '3', subtitle: '-1', season: 'later-season' };
  let publications = 0;
  const signal = new AbortController();
  return { choices, signal, get state() { return state; }, set state(value) { state = value; }, get publications() { return publications; },
    options: { signal: signal.signal, current: () => state, readItem: async (id: string) => item(id, { UserData: { Played: true, UnplayedItemCount: 0 } }),
      readSeason: async (_id: string, season: string) => { assert.equal(season, 'later-season'); return { Items: [item('episode', { UserData: { Played: true } })] }; },
      publish(value: WatchedDetailState) { state = value; publications++; } } };
}
test('accepted and partially accepted watched dialogs refresh only status while retaining later season and nondefault tracks', async () => {
  for (const partial of [false, true]) {
    const h = harness(), actions = new WatchedActions();
    actions.prepare([h.state!.item, item('other')], true, { owner: 'same', current: () => 'same', protected: false, write: async value => { if (partial && value.Id === 'other') throw new Error('Permission denied'); } });
    const result = await actions.confirm(); assert.equal(result!.succeeded.length, partial ? 1 : 2); assert.equal(result!.failed.length, partial ? 1 : 0);
    assert(actions.acceptedItems.length > 0); actions.cancel();
    const sources = h.state!.item.MediaSources;
    assert.equal(await refreshWatchedDetail(h.options), true);
    assert.deepEqual(h.choices, { source: 'alternate', audio: '3', subtitle: '-1', season: 'later-season' });
    assert.equal(h.state!.season, 'later-season'); assert.equal(h.state!.item.MediaSources, sources);
    assert.equal(h.state!.item.UserData!.Played, true); assert.equal(h.state!.item.UserData!.UnplayedItemCount, 0);
    assert.equal(h.state!.episodes[0].UserData!.Played, true); assert.equal(h.publications, 1);
  }
});
test('a delayed status read preserves newer local favorites/progress and an intervening season choice', async () => {
  const h = harness(), response = deferred<ItemPage>();
  const pending = refreshWatchedDetail({ ...h.options, readSeason: () => response.promise });
  h.state = { ...h.state!, item: { ...h.state!.item, UserData: { IsFavorite: true, PlaybackPositionTicks: 99 } }, season: 'newest-season', episodes: [item('different')] };
  response.resolve({ Items: [item('episode', { UserData: { Played: true } })] }); await pending;
  assert.equal(h.state!.item.UserData!.IsFavorite, true); assert.equal(h.state!.item.UserData!.PlaybackPositionTicks, 99);
  assert.equal(h.state!.season, 'newest-season'); assert.equal(h.state!.episodes[0].Id, 'different');
});
test('route, account, token and subsequent watched-read ownership changes reject a late readback', async () => {
  for (const replacement of ['other-route', 'other-account', 'new-token', 'read2', undefined]) {
    const h = harness(), response = deferred<MediaItem>();
    const pending = refreshWatchedDetail({ ...h.options, readItem: () => response.promise });
    h.state = replacement ? { ...h.state!, owner: replacement } : undefined;
    response.resolve(item('series', { UserData: { Played: true } }));
    assert.equal(await pending, false); assert.equal(h.publications, 0);
  }
});
test('abort and same-owner item replacement cannot publish old watched data', async () => {
  for (const abort of [false, true]) {
    const h = harness(), response = deferred<MediaItem>();
    const pending = refreshWatchedDetail({ ...h.options, readItem: () => response.promise });
    if (abort) h.signal.abort(); else h.state = { ...h.state!, item: item('other') };
    response.resolve(item('series')); assert.equal(await pending, false); assert.equal(h.publications, 0);
  }
});
test('failed readback preserves current detail and selections, without pretending an accepted write was undone', async () => {
  const h = harness(), before = h.state;
  await assert.rejects(refreshWatchedDetail({ ...h.options, readSeason: async () => { throw new Error('Unavailable'); } }), /Unavailable/);
  assert.equal(h.state, before); assert.equal(h.publications, 0); assert.equal(h.choices.source, 'alternate');
});
test('non-Series readback does not fetch seasons and missing watched fields become unknown', async () => {
  const h = harness(); h.state = { ...h.state!, item: item('movie', { Type: 'Movie' }) }; let seasonReads = 0;
  await refreshWatchedDetail({ ...h.options, readItem: async id => item(id, { UserData: undefined }), readSeason: async () => { seasonReads++; return { Items: [] }; } });
  assert.equal(seasonReads, 0); assert.equal(h.state!.item.UserData!.Played, undefined); assert.equal(h.state!.item.UserData!.UnplayedItemCount, undefined);
});
test('wrong item readback is refused without losing current choices', async () => {
  const h = harness(); await assert.rejects(refreshWatchedDetail({ ...h.options, readItem: async () => item('wrong') }), /invalid watched status/);
  assert.equal(h.publications, 0); assert.equal(h.state!.item.Id, 'series');
});
