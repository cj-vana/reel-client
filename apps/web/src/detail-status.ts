import type { ItemPage, MediaItem } from './types.ts';

export interface WatchedDetailState {
  owner: string;
  item: MediaItem;
  season: string;
  episodes: readonly MediaItem[];
}

function watchedFields(current: MediaItem, fresh?: MediaItem): MediaItem {
  // A watched readback must not replace concurrent favorites, local progress or media choices.
  return { ...current, UserData: { ...current.UserData, Played: fresh?.UserData?.Played, UnplayedItemCount: fresh?.UserData?.UnplayedItemCount } };
}

/** Reconcile authoritative watched metadata without remounting Details or assigning default choices. */
export async function refreshWatchedDetail(options: {
  current: () => WatchedDetailState | undefined;
  signal: AbortSignal;
  readItem: (id: string, signal: AbortSignal) => Promise<MediaItem>;
  readSeason: (id: string, season: string, signal: AbortSignal) => Promise<ItemPage>;
  publish: (state: WatchedDetailState) => void;
}): Promise<boolean> {
  const captured = options.current();
  if (!captured || options.signal.aborted) return false;
  const [item, season] = await Promise.all([
    options.readItem(captured.item.Id, options.signal),
    captured.item.Type === 'Series' && captured.season ? options.readSeason(captured.item.Id, captured.season, options.signal) : undefined
  ]);
  const current = options.current();
  if (options.signal.aborted || !current || current.owner !== captured.owner || current.item.Id !== captured.item.Id) return false;
  if (item.Id !== captured.item.Id || season && !Array.isArray(season.Items)) throw new Error('Jellyfin returned invalid watched status.');
  const byId = new Map(season?.Items.map(value => [value.Id, value]));
  options.publish({ ...current, item: watchedFields(current.item, item),
    episodes: season && current.season === captured.season ? current.episodes.map(value => watchedFields(value, byId.get(value.Id))) : current.episodes });
  return true;
}
