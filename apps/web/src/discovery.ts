import { type MediaItem, resumeSeconds, TICKS, duration } from './types.ts';

/** Keep recommendations deliberate and stable; never advance a hero while someone reads it. */
export function featuredTitles(movies: readonly MediaItem[], shows: readonly MediaItem[], fallback: readonly MediaItem[]): MediaItem[] {
  const seen = new Set<string>();
  return [...movies.slice(0, 3), ...shows.slice(0, 2), ...fallback].filter(item => {
    if (!item.Id || seen.has(item.Id)) return false;
    seen.add(item.Id); return true;
  }).slice(0, 5);
}

export function viewingProgress(item: MediaItem): { percent: number; remaining: string } | undefined {
  const total = (item.RunTimeTicks ?? 0) / TICKS;
  const position = resumeSeconds(item);
  if (!Number.isFinite(total) || total <= 0 || position <= 0 || position >= total) return undefined;
  return { percent: position / total * 100, remaining: `${duration(total - position)} left` };
}
