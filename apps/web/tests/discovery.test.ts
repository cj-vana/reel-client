import { test } from 'node:test';
import assert from 'node:assert/strict';
import { featuredTitles, viewingProgress } from '../src/discovery.ts';
import { type MediaItem, TICKS } from '../src/types.ts';

const title = (Id: string): MediaItem => ({ Id, Name: Id });
test('featured choices combine movies and shows without repeating fallback titles', () => {
  assert.deepEqual(featuredTitles(['a', 'b', 'c', 'd'].map(title), ['x', 'y'].map(title), [title('a')]).map(item => item.Id), ['a', 'b', 'c', 'x', 'y']);
  assert.deepEqual(featuredTitles([], [], [title('episode'), title('episode')]).map(item => item.Id), ['episode']);
  assert.deepEqual(featuredTitles([], [], []), []);
});
test('remaining time is based on a valid partial playback position', () => {
  const item = { ...title('movie'), RunTimeTicks: 7200 * TICKS, UserData: { PlaybackPositionTicks: 1800 * TICKS } };
  assert.deepEqual(viewingProgress(item), { percent: 25, remaining: '1h 30m left' });
  for (const time of [0, -1, NaN, Infinity, 7200, 8000]) assert.equal(viewingProgress({ ...item, UserData: { PlaybackPositionTicks: time * TICKS } }), undefined);
  for (const total of [0, -1, NaN, Infinity, undefined]) assert.equal(viewingProgress({ ...item, RunTimeTicks: total }), undefined);
});
