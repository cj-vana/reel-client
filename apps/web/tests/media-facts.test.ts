import test from 'node:test';
import assert from 'node:assert/strict';
import { communityRating, mediaBadges } from '../src/media-facts.ts';
import type { MediaItem, MediaStream } from '../src/types.ts';

const item = (streams: MediaStream[]): MediaItem => ({ Id: 'movie', Name: 'Movie', MediaSources: [{ Id: 'source', MediaStreams: streams }] });

test('badges come only from reported streams', () => {
  assert.deepEqual(mediaBadges({ Id: 'bare', Name: 'Bare' }), []);
  assert.deepEqual(mediaBadges(item([{ Index: 0, Type: 'Video', Width: 1920, VideoRangeType: 'SDR' }, { Index: 1, Type: 'Audio', Channels: 2 }])), []);
  assert.deepEqual(mediaBadges(item([
    { Index: 0, Type: 'Video', Width: 3840, VideoRangeType: 'HDR10' },
    { Index: 1, Type: 'Audio', Channels: 6 },
    { Index: 2, Type: 'Subtitle' }
  ])), ['4K', 'HDR', '5.1', 'CC']);
});

test('Dolby Vision outranks HDR and Atmos needs a spatial format', () => {
  assert.deepEqual(mediaBadges(item([
    { Index: 0, Type: 'Video', Width: 3840, VideoRangeType: 'DOVIWithHDR10' },
    { Index: 1, Type: 'Audio', Channels: 8, AudioSpatialFormat: 'DolbyAtmos' }
  ])), ['4K', 'Dolby Vision', '7.1', 'Atmos']);
  assert.deepEqual(mediaBadges(item([{ Index: 1, Type: 'Audio', Channels: 6, AudioSpatialFormat: 'None' }])), ['5.1']);
});

test('community rating rejects missing, malformed and zero values', () => {
  assert.equal(communityRating({ Id: 'a', Name: 'A', CommunityRating: 7.4 }), 7.4);
  for (const value of [undefined, 0, Number.NaN, 'invalid' as unknown as number]) assert.equal(communityRating({ Id: 'a', Name: 'A', CommunityRating: value }), undefined);
});
