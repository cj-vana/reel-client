import type { MediaItem } from './types.ts';

/** Badges only for what the server reports about the first version: resolution, range, audio and captions. */
export function mediaBadges(item: MediaItem): string[] {
  const streams = item.MediaSources?.[0]?.MediaStreams ?? [];
  const video = streams.find(stream => stream.Type === 'Video');
  const audio = streams.filter(stream => stream.Type === 'Audio');
  const badges: string[] = [];
  if (typeof video?.Width === 'number' && video.Width >= 3800) badges.push('4K');
  const range = video?.VideoRangeType ?? '';
  if (/^DOVI/i.test(range) || typeof video?.DvProfile === 'number') badges.push('Dolby Vision');
  else if (/HDR|HLG/i.test(range)) badges.push('HDR');
  const channels = Math.max(0, ...audio.map(stream => typeof stream.Channels === 'number' ? stream.Channels : 0));
  if (channels >= 8) badges.push('7.1');
  else if (channels >= 6) badges.push('5.1');
  if (audio.some(stream => stream.AudioSpatialFormat === 'DolbyAtmos' || /atmos/i.test(stream.Profile ?? ''))) badges.push('Atmos');
  if (streams.some(stream => stream.Type === 'Subtitle')) badges.push('CC');
  return badges;
}

/** A finite community rating, or undefined when the server sends nothing usable. */
export function communityRating(item: MediaItem): number | undefined {
  const value = item.CommunityRating;
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : undefined;
}
