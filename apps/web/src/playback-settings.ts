import type { MediaItem, MediaSource, MediaStream } from './types.ts';

export interface PlaybackSelection { bitrate: number; source?: string; audio?: number; subtitle?: number }
export const playbackQualities = [
  { value: 120_000_000, label: 'Original / auto' },
  { value: 20_000_000, label: 'High · 20 Mbps' },
  { value: 8_000_000, label: 'Balanced · 8 Mbps' },
  { value: 2_000_000, label: 'Data saver · 2 Mbps' },
];
export function playbackSources(item: MediaItem): MediaSource[] {
  const sources = (Array.isArray(item.MediaSources) ? item.MediaSources : []).filter(source => source && typeof source.Id === 'string' && source.Id.length > 0);
  return sources.filter(source => sources.filter(candidate => candidate.Id === source.Id).length === 1);
}
export function playbackTracks(source: MediaSource | undefined, type: 'Audio' | 'Subtitle'): MediaStream[] {
  const streams = (Array.isArray(source?.MediaStreams) ? source.MediaStreams : []).filter(stream => stream && Number.isSafeInteger(stream.Index) && stream.Index >= 0);
  return streams.filter(stream => stream.Type === type && streams.filter(candidate => candidate.Index === stream.Index).length === 1);
}
export function validPlaybackSelection(item: MediaItem, selection: PlaybackSelection): boolean {
  if (!playbackQualities.some(quality => quality.value === selection.bitrate)) return false;
  const sources = playbackSources(item), source = selection.source === undefined ? sources[0] : sources.find(source => source.Id === selection.source);
  if (selection.source !== undefined && !source) return false;
  return (selection.audio === undefined || playbackTracks(source, 'Audio').some(track => track.Index === selection.audio))
    && (selection.subtitle === undefined || selection.subtitle === -1 || playbackTracks(source, 'Subtitle').some(track => track.Index === selection.subtitle));
}
export function selectPlaybackSource(selection: PlaybackSelection, source: string): PlaybackSelection {
  return { bitrate: selection.bitrate, source, subtitle: selection.subtitle === -1 ? -1 : undefined };
}
