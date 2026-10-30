import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ApiError, type JellyfinAPI } from '../src/api.ts';
import { loadEpisodeContext, loadIntroSegment, loadSeasonEpisodes } from '../src/playback-extras.ts';
import { type MediaItem, TICKS } from '../src/types.ts';

const episode = (season: number, number: number): MediaItem => ({ Id: `e-${season}-${number}`, Name: `Episode ${number}`, Type: 'Episode', SeriesId: 'show', SeasonId: `s-${season}`, ParentIndexNumber: season, IndexNumber: number, RunTimeTicks: 120 * TICKS });
const seasons: MediaItem[] = [1, 2].map(n => ({ Id: `s-${n}`, Name: `Season ${n}`, Type: 'Season', SeriesId: 'show', IndexNumber: n }));
const signal = () => new AbortController().signal;

test('episode context follows authoritative adjacent order across seasons and loads the current season', async () => {
  const current = episode(2, 1), before = episode(1, 8), after = episode(2, 2);
  const calls: Array<[string, unknown]> = [];
  const api: Pick<JellyfinAPI, 'page'> = { async page(path, query) {
    calls.push([path, query]);
    if (path.endsWith('/Seasons')) {
      assert.equal(query?.startIndex, undefined); assert.equal(query?.limit, undefined);
      return { Items: seasons };
    }
    if (query?.adjacentTo) return { Items: [before, current, after] };
    assert.equal(query?.seasonId, 's-2');
    return { Items: [current, after] };
  } };
  const result = await loadEpisodeContext(api, current, signal());
  assert.equal(result.previous?.Id, before.Id); assert.equal(result.next?.Id, after.Id);
  assert.equal(result.selectedSeason, 's-2'); assert.deepEqual(result.episodes, [current, after]);
  assert.equal(calls.length, 3);
});

test('episode boundaries never wrap or guess when the active episode is absent', async () => {
  const a = episode(1, 1), b = episode(1, 2);
  const api: Pick<JellyfinAPI, 'page'> = { async page(path) { return { Items: path.endsWith('/Seasons') ? seasons : [a, b] }; } };
  assert.equal((await loadEpisodeContext(api, a, signal())).previous, undefined);
  assert.equal((await loadEpisodeContext(api, b, signal())).next, undefined);
  const missing = await loadEpisodeContext(api, episode(1, 3), signal());
  assert.equal(missing.previous, undefined); assert.equal(missing.next, undefined);
  const movie = await loadEpisodeContext({ page: () => { throw new Error('must not request episodes'); } }, { Id: 'movie', Name: 'Film', Type: 'Movie' }, signal());
  assert.deepEqual(movie, { seasons: [], selectedSeason: '', episodes: [] });
});

test('season list follows actual returned count when a server applies a lower page cap', async () => {
  const all = Array.from({ length: 307 }, (_, n) => episode(1, n + 1));
  const offsets: number[] = [];
  const api: Pick<JellyfinAPI, 'page'> = { async page(_path, query) {
    const start = Number(query?.startIndex); offsets.push(start);
    return { Items: all.slice(start, start + 100), TotalRecordCount: all.length };
  } };
  assert.deepEqual(await loadSeasonEpisodes(api, 'show', 's-1', signal()), all);
  assert.deepEqual(offsets, [0, 100, 200, 300]);
});

test('repeated pages and stalled lists fail explicitly instead of silently duplicating or omitting episodes', async () => {
  const page = Array.from({ length: 200 }, (_, n) => episode(1, n + 1));
  await assert.rejects(loadSeasonEpisodes({ page: async () => ({ Items: page, TotalRecordCount: 300 }) }, 'show', 's-1', signal()), /changed while loading/);
  await assert.rejects(loadSeasonEpisodes({ page: async () => ({ Items: [], TotalRecordCount: 300 }) }, 'show', 's-1', signal()), /stopped loading/);
});

test('aborted metadata loads cannot return stale episode or intro context', async () => {
  const controller = new AbortController();
  const api: Pick<JellyfinAPI, 'page'> = { async page() { controller.abort(); return { Items: seasons }; } };
  await assert.rejects(loadEpisodeContext(api, episode(1, 1), controller.signal), { name: 'AbortError' });
  let requested = false;
  await assert.rejects(loadIntroSegment({ request: async <T>() => { requested = true; return {} as T; } }, episode(1, 1), controller.signal), { name: 'AbortError' });
  assert.equal(requested, false);
});

function segmentAPI(Items: unknown[]): Pick<JellyfinAPI, 'request'> {
  return { async request<T>(path, options) {
    assert.equal(path, 'MediaSegments/e-1-1'); assert.equal(options?.query?.includeSegmentTypes, 'Intro');
    return { Items } as T;
  } };
}
test('Skip Intro uses typed server metadata and never infers boundaries from chapter names', async () => {
  const item = { ...episode(1, 1), Chapters: [{ Name: 'Intro', StartPositionTicks: 0 }, { Name: 'Episode', StartPositionTicks: 30 * TICKS }] };
  assert.equal(await loadIntroSegment(segmentAPI([]), item, signal()), undefined);
  assert.deepEqual(await loadIntroSegment(segmentAPI([
    { Type: 'Outro', StartTicks: 90 * TICKS, EndTicks: 120 * TICKS },
    { ItemId: item.Id, Type: 'Intro', StartTicks: 5 * TICKS, EndTicks: 27 * TICKS }
  ]), item, signal()), { start: 5, end: 27 });
});

test('wrong-item, nonfinite, reversed, negative and beyond-runtime segment data are not skippable', async () => {
  const base = { ItemId: 'e-1-1', Type: 'Intro', StartTicks: 5 * TICKS, EndTicks: 27 * TICKS };
  for (const patch of [{ ItemId: 'other' }, { Type: 'Unknown' }, { StartTicks: -1 }, { StartTicks: NaN }, { EndTicks: Infinity }, { EndTicks: 5 * TICKS }, { EndTicks: 121 * TICKS }, { EndTicks: '270000000' }]) {
    assert.equal(await loadIntroSegment(segmentAPI([{ ...base, ...patch }]), episode(1, 1), signal()), undefined);
  }
});

test('unsupported segment APIs degrade gracefully while authorization and connectivity errors remain visible', async () => {
  for (const status of [404, 405, 501]) {
    assert.equal(await loadIntroSegment({ request: async () => { throw new ApiError('not available', status); } }, episode(1, 1), signal()), undefined);
  }
  for (const status of [401, 403, 500, 0]) {
    await assert.rejects(loadIntroSegment({ request: async () => { throw new ApiError('request failed', status); } }, episode(1, 1), signal()), (error: unknown) => error instanceof ApiError && error.status === status);
  }
});
