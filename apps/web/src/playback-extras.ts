import { ApiError, type JellyfinAPI } from './api.ts';
import { type ItemPage, type MediaItem, TICKS } from './types.ts';

type EpisodeAPI = Pick<JellyfinAPI, 'page'>;
export interface IntroSegment { start: number; end: number }
/** Seconds into the item: the intro to skip, and where the credits begin. */
export interface Markers { intro?: IntroSegment; credits?: number }
export interface EpisodeContext {
  previous?: MediaItem;
  next?: MediaItem;
  seasons: MediaItem[];
  selectedSeason: string;
  episodes: MediaItem[];
}

function checkCancellation(signal: AbortSignal): void {
  if (signal.aborted) throw new DOMException('Cancelled', 'AbortError');
}

function catalogItems(page: ItemPage, type: 'Episode' | 'Season', seriesId: string): MediaItem[] {
  if (!Array.isArray(page?.Items) || page.Items.some(item => !item || typeof item.Id !== 'string' || !item.Id || typeof item.Name !== 'string')) {
    throw new ApiError('The episode list could not be read. Try again.');
  }
  return page.Items.filter(item => item.Type === type && (!item.SeriesId || item.SeriesId === seriesId));
}

async function catalog(api: EpisodeAPI, path: string, type: 'Episode' | 'Season', seriesId: string, query: Record<string, string | number | boolean>, signal: AbortSignal): Promise<MediaItem[]> {
  const items: MediaItem[] = [], seen = new Set<string>();
  let start = 0;
  for (let requests = 0; requests < 100 && start < 10_000; requests++) {
    checkCancellation(signal);
    const page = await api.page(path, { ...query, startIndex: start, limit: 200, enableTotalRecordCount: true }, signal);
    checkCancellation(signal);
    const values = catalogItems(page, type, seriesId);
    for (const item of values) {
      if (seen.has(item.Id)) throw new ApiError('The episode list changed while loading. Try again.');
      seen.add(item.Id); items.push(item);
    }
    const total = page.TotalRecordCount;
    if (total !== undefined && (!Number.isSafeInteger(total) || total < 0)) throw new ApiError('The episode count could not be read. Try again.');
    if (page.Items.length < 200 && (total === undefined || start + page.Items.length >= total)) return items;
    if (total !== undefined && start + page.Items.length >= total) return items;
    if (!page.Items.length) throw new ApiError('The episode list stopped loading. Try again.');
    start += page.Items.length;
  }
  throw new ApiError('This episode list is too large to load. Choose a smaller library on your server.');
}

export async function loadSeasonEpisodes(api: EpisodeAPI, seriesId: string, seasonId: string, signal: AbortSignal): Promise<MediaItem[]> {
  if (!seriesId || !seasonId) return [];
  return catalog(api, `Shows/${encodeURIComponent(seriesId)}/Episodes`, 'Episode', seriesId, { seasonId, isMissing: false }, signal);
}

export async function loadEpisodeContext(api: EpisodeAPI, item: MediaItem, signal: AbortSignal): Promise<EpisodeContext> {
  checkCancellation(signal);
  if (item.Type !== 'Episode' || !item.SeriesId) return { seasons: [], selectedSeason: '', episodes: [] };
  const series = item.SeriesId;
  const [adjacentPage, seasonsPage] = await Promise.all([
    api.page(`Shows/${encodeURIComponent(series)}/Episodes`, { adjacentTo: item.Id, isMissing: false }, signal),
    api.page(`Shows/${encodeURIComponent(series)}/Seasons`, { isMissing: false }, signal)
  ]);
  checkCancellation(signal);
  const seasons = catalogItems(seasonsPage, 'Season', series);
  if (new Set(seasons.map(season => season.Id)).size !== seasons.length) throw new ApiError('The season list could not be read. Try again.');
  const adjacent = catalogItems(adjacentPage, 'Episode', series);
  if (new Set(adjacent.map(episode => episode.Id)).size !== adjacent.length) throw new ApiError('The episode order could not be read. Try again.');
  const index = adjacent.findIndex(episode => episode.Id === item.Id);
  const selectedSeason = seasons.find(season => season.Id === item.SeasonId)?.Id
    ?? seasons.find(season => item.ParentIndexNumber !== undefined && season.IndexNumber === item.ParentIndexNumber)?.Id
    ?? seasons[0]?.Id ?? '';
  const episodes = await loadSeasonEpisodes(api, series, selectedSeason, signal);
  checkCancellation(signal);
  return { previous: index > 0 ? adjacent[index - 1] : undefined, next: index >= 0 ? adjacent[index + 1] : undefined, seasons, selectedSeason, episodes };
}

/**
 * The intro and the start of the credits as the server marks them (Jellyfin's Intro and Outro media segments).
 * Chapter names are never read as markers.
 */
export async function loadServerMarkers(api: Pick<JellyfinAPI, 'request'>, item: MediaItem, signal: AbortSignal): Promise<Markers> {
  checkCancellation(signal);
  if (item.Type !== 'Episode' && item.Type !== 'Movie') return {};
  let response: { Items?: unknown[] } | undefined;
  try {
    response = await api.request(`MediaSegments/${encodeURIComponent(item.Id)}`, { signal });
  } catch (error) {
    checkCancellation(signal);
    if (error instanceof ApiError && [404, 405, 501].includes(error.status)) return {};
    throw error;
  }
  checkCancellation(signal);
  if (!Array.isArray(response?.Items)) return {};
  const runtime = typeof item.RunTimeTicks === 'number' && Number.isFinite(item.RunTimeTicks) && item.RunTimeTicks > 0 ? item.RunTimeTicks / TICKS : undefined;
  const intros: IntroSegment[] = [], outros: IntroSegment[] = [];
  for (const value of response.Items.slice(0, 1000)) {
    if (!value || typeof value !== 'object') continue;
    const segment = value as Record<string, unknown>;
    if (segment.Type !== 'Intro' && segment.Type !== 'Outro' || segment.ItemId !== undefined && segment.ItemId !== item.Id) continue;
    const start = segment.StartTicks, end = segment.EndTicks;
    if (typeof start !== 'number' || typeof end !== 'number' || !Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || end <= start) continue;
    if (runtime !== undefined && end / TICKS > runtime) continue;
    (segment.Type === 'Intro' ? intros : outros).push({ start: start / TICKS, end: end / TICKS });
  }
  const first = (list: IntroSegment[]) => list.sort((a, b) => a.start - b.start || a.end - b.end)[0];
  const intro = first(intros), outro = first(outros);
  return { ...(intro ? { intro } : {}), ...(outro && outro.start > 0 ? { credits: outro.start } : {}) };
}
