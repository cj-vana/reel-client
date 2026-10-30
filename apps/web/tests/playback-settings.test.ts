import test from 'node:test';
import assert from 'node:assert/strict';
import { validPlaybackSelection, selectPlaybackSource, playbackSources, playbackTracks } from '../src/playback-settings.ts';
import type { MediaItem } from '../src/types.ts';
const item: MediaItem = { Id: 'film', Name: 'Film', MediaSources: [
  { Id: 'original', MediaStreams: [{ Index: 1, Type: 'Audio' }, { Index: 2, Type: 'Subtitle' }] },
  { Id: 'alternate', MediaStreams: [{ Index: 5, Type: 'Audio' }, { Index: 6, Type: 'Subtitle' }] },
] };
test('picture and sound accepts only source-owned tracks and supported quality values', () => {
  assert.equal(validPlaybackSelection(item, { bitrate: 8_000_000, source: 'original', audio: 1, subtitle: 2 }), true);
  for (const change of [{ audio: 2 }, { audio: 5 }, { subtitle: 1 }, { subtitle: 6 }, { source: 'missing' }, { bitrate: NaN }, { bitrate: -1 }, { audio: Infinity }]) assert.equal(validPlaybackSelection(item, { bitrate: 8_000_000, source: 'original', ...change }), false);
  assert.equal(validPlaybackSelection(item, { bitrate: 120_000_000, subtitle: -1 }), true);
  assert.equal(validPlaybackSelection({ Id: 'empty', Name: 'No metadata' }, { bitrate: 120_000_000 }), true);
});
test('version changes reset incompatible tracks while preserving explicit subtitle Off', () => {
  assert.deepEqual(selectPlaybackSource({ bitrate: 20_000_000, source: 'original', audio: 1, subtitle: 2 }, 'alternate'), { bitrate: 20_000_000, source: 'alternate', subtitle: undefined });
  assert.deepEqual(selectPlaybackSource({ bitrate: 20_000_000, subtitle: -1 }, 'alternate'), { bitrate: 20_000_000, source: 'alternate', subtitle: -1 });
});
test('malformed source and track metadata cannot introduce selectable invalid indices', () => {
  assert.deepEqual(playbackSources({ ...item, MediaSources: [null, { Id: '' }] as never }), []);
  assert.deepEqual(playbackTracks({ Id: 'source', MediaStreams: [null, { Index: -1, Type: 'Audio' }, { Index: 1.5, Type: 'Audio' }] as never }, 'Audio'), []);
});

test('duplicate source IDs and track indices never become ambiguous selectable choices', () => {
  const ambiguous = { ...item, MediaSources: [...item.MediaSources!, item.MediaSources![0]] };
  assert.deepEqual(playbackSources(ambiguous).map(source => source.Id), ['alternate']);
  assert.equal(validPlaybackSelection(ambiguous, { bitrate: 8_000_000, source: 'original' }), false);
  const source = { Id: 'ambiguous', MediaStreams: [{ Index: 1, Type: 'Audio' }, { Index: 1, Type: 'Audio' }, { Index: 2, Type: 'Audio' }, { Index: 2, Type: 'Subtitle' }] };
  assert.deepEqual(playbackTracks(source, 'Audio'), []); assert.deepEqual(playbackTracks(source, 'Subtitle'), []);
});
