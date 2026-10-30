import type { ItemPage, MediaItem } from './types.ts';

export const libraryCategories = ['All', 'Movies', 'Series', 'Episodes', 'Collections', 'Playlists'] as const;
export const librarySorts = ['SortName', 'DateCreated', 'ProductionYear', 'DateLastContentAdded'] as const;
export type LibraryCategory = typeof libraryCategories[number];
export type LibrarySort = typeof librarySorts[number];
export type LibraryDirection = 'Ascending' | 'Descending';
export type LibraryWatchStatus = 'Any' | 'Watched' | 'Unwatched';
export type LibraryView = 'grid' | 'list';
export interface LibraryChoices {
  sort: LibrarySort;
  direction: LibraryDirection;
  genreId: string;
  watchStatus: LibraryWatchStatus;
  favoritesOnly: boolean;
  view: LibraryView;
}
export interface LibraryScope {
  kind: 'library' | 'search' | 'favorites' | 'music' | 'photos' | 'books' | 'container';
  category: LibraryCategory;
  libraryId: string;
  parentId: string;
  parentType: string;
}
export const defaultLibraryChoices = (): LibraryChoices => ({
  sort: 'SortName', direction: 'Ascending', genreId: '', watchStatus: 'Any', favoritesOnly: false, view: 'grid'
});
export function defaultSortDirection(sort: LibrarySort): LibraryDirection { return sort === 'SortName' ? 'Ascending' : 'Descending'; }
export function effectiveLibrarySort(scope: LibraryScope, choices: LibraryChoices): LibrarySort {
  return choices.sort === 'DateLastContentAdded' && scope.category !== 'Series' ? 'DateCreated' : choices.sort;
}
export function newestEpisodeChoices(view: LibraryView): LibraryChoices {
  return { ...defaultLibraryChoices(), sort: 'DateCreated', direction: 'Descending', view };
}
export function playlistScope(scope: LibraryScope): boolean { return scope.parentType === 'Playlist' && !!scope.parentId; }

export function libraryRequest(scope: LibraryScope, choices: LibraryChoices, search: string, start: number, limit = 60): {
  path: string; query: Record<string, string | number | boolean | undefined>; canLoad: boolean;
} {
  const query: Record<string, string | number | boolean | undefined> = {
    startIndex: Number.isSafeInteger(start) ? Math.max(0, start) : 0,
    limit: Number.isSafeInteger(limit) ? Math.max(1, Math.min(200, limit)) : 60,
    enableTotalRecordCount: true
  };
  // Playlist entries are an ordered sequence, including repeated media IDs.
  if (playlistScope(scope)) return { path: `Playlists/${encodeURIComponent(scope.parentId)}/Items`, query, canLoad: true };
  const term = search.trim(), sort = effectiveLibrarySort(scope, choices);
  const types: Record<LibraryCategory, string> = {
    All: scope.kind === 'search' ? 'Movie,Series,Episode,MusicAlbum,Audio,Book,PhotoAlbum' : 'Movie,Series',
    Movies: 'Movie', Series: 'Series', Episodes: 'Episode', Collections: 'BoxSet', Playlists: 'Playlist'
  };
  let includeItemTypes = types[scope.category];
  if (scope.kind === 'music') includeItemTypes = 'MusicAlbum,MusicArtist,Audio,AudioBook';
  if (scope.kind === 'photos') includeItemTypes = 'Photo,PhotoAlbum';
  if (scope.kind === 'books') includeItemTypes = 'Book,AudioBook';
  if (scope.parentId) {
    if (scope.parentType === 'MusicArtist') includeItemTypes = 'MusicAlbum,Audio,AudioBook';
    else if (scope.parentType === 'MusicAlbum') includeItemTypes = 'Audio';
    else if (scope.parentType === 'PhotoAlbum') includeItemTypes = 'Photo,PhotoAlbum';
    else includeItemTypes = 'Movie,Series,Episode,Video,MusicVideo,BoxSet,Playlist';
  }
  Object.assign(query, {
    recursive: true, includeItemTypes, fields: 'Overview,Genres,DateCreated,DateLastMediaAdded',
    sortBy: sort === 'SortName' ? sort : `${sort},SortName`,
    sortOrder: sort === 'SortName' ? choices.direction : `${choices.direction},Ascending`,
    searchTerm: term || undefined, genreIds: choices.genreId || undefined,
    isPlayed: choices.watchStatus === 'Any' ? undefined : choices.watchStatus === 'Watched',
    filters: scope.kind === 'favorites' || choices.favoritesOnly ? 'IsFavorite' : undefined,
    parentId: scope.parentId || scope.libraryId || undefined
  });
  return { path: 'Items', query, canLoad: scope.kind !== 'search' || !!term };
}

export class LibraryPagination {
  items: MediaItem[] = [];
  total: number | undefined;
  nextIndex = 0;
  hasMore = false;
  append(page: ItemPage, playlist: boolean, limit = 60): void {
    if (!page || !Array.isArray(page.Items) || page.Items.some(item => !item || typeof item.Id !== 'string' || !item.Id || typeof item.Name !== 'string')) {
      throw new Error('Jellyfin returned an invalid library page. Try again.');
    }
    this.nextIndex += page.Items.length;
    if (playlist) this.items.push(...page.Items);
    else {
      const known = new Set(this.items.map(item => item.Id));
      for (const item of page.Items) if (!known.has(item.Id)) { known.add(item.Id); this.items.push(item); }
    }
    if (Number.isSafeInteger(page.TotalRecordCount) && page.TotalRecordCount! >= 0) this.total = page.TotalRecordCount;
    this.hasMore = page.Items.length > 0 && (this.total === undefined ? page.Items.length >= limit : this.nextIndex < this.total);
  }
}

const leafTypes = new Set(['Movie', 'Episode', 'Video', 'MusicVideo', 'Audio', 'AudioBook', 'Book', 'Photo', 'Trailer']);
const containerTypes = new Set(['Series', 'Season', 'BoxSet', 'Playlist', 'Folder', 'CollectionFolder', 'MusicAlbum', 'MusicArtist', 'PhotoAlbum', 'AggregateFolder', 'BasePluginFolder', 'ChannelFolderItem', 'ManualPlaylistsFolder', 'PlaylistsFolder', 'UserRootFolder', 'UserView']);
export function watchedItemKind(item: MediaItem): 'leaf' | 'container' | 'unknown' {
  if (item.IsFolder === true) return 'container';
  if (typeof item.Type !== 'string' || item.IsFolder !== undefined && item.IsFolder !== null && typeof item.IsFolder !== 'boolean') return 'unknown';
  if (containerTypes.has(item.Type)) return 'container';
  return leafTypes.has(item.Type) ? 'leaf' : 'unknown';
}
export function isKnownLeafItem(item: MediaItem): boolean { return watchedItemKind(item) === 'leaf'; }
export function isAggregateItem(item: MediaItem): boolean { return watchedItemKind(item) === 'container'; }
export function supportsWatchedMutation(item: MediaItem): boolean { return watchedItemKind(item) !== 'unknown'; }
export function watchedUnavailableReason(item: MediaItem): string | undefined { return supportsWatchedMutation(item) ? undefined : 'Jellyfin has not supplied supported type metadata. Watched status cannot be changed for this title.'; }
export function serverPlayed(item: MediaItem): boolean | undefined { return typeof item.UserData?.Played === 'boolean' ? item.UserData.Played : undefined; }
export function aggregateUnplayedCount(item: MediaItem): number | undefined {
  const count = item.UserData?.UnplayedItemCount;
  return isAggregateItem(item) && Number.isSafeInteger(count) && count! >= 0 ? count! : undefined;
}
export function itemWatched(item: MediaItem): boolean | undefined {
  return isKnownLeafItem(item) ? serverPlayed(item) : undefined;
}
export function watchStatusText(item: MediaItem): string | undefined {
  const count = aggregateUnplayedCount(item);
  if (count !== undefined) return `${count} unwatched`;
  if (!isAggregateItem(item) && itemWatched(item) === true) return 'Watched';
  return undefined;
}

export function catalogueDate(value: unknown): Date | undefined {
  if (typeof value !== 'string') return undefined;
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$/.exec(value);
  if (!match) return undefined;
  const [year, month, day, hour, minute, second] = match.slice(1).map(Number);
  if (year <= 1 || month < 1 || month > 12 || day < 1 || hour > 23 || minute > 59 || second > 59) return undefined;
  const calendar = new Date(0); calendar.setUTCFullYear(year, month - 1, day);
  if (calendar.getUTCFullYear() !== year || calendar.getUTCMonth() !== month - 1 || calendar.getUTCDate() !== day) return undefined;
  // Date has millisecond precision; normalize server's seven-digit fractions for older engines.
  const time = Date.parse(value.replace(/(\.\d{3})\d+/, '$1'));
  return Number.isFinite(time) ? new Date(time) : undefined;
}
export function addedDateText(item: MediaItem, sort: LibrarySort, locale?: string): string | undefined {
  const latest = item.Type === 'Series' && sort === 'DateLastContentAdded';
  const date = catalogueDate(latest ? item.DateLastMediaAdded : item.DateCreated);
  return date ? `${latest ? 'Content added' : 'Added'} ${date.toLocaleDateString(locale)}` : undefined;
}

export interface WatchedPlan { items: readonly MediaItem[]; value: boolean; includesContainers: boolean; needsConfirmation: boolean }
export function watchedPlan(items: readonly MediaItem[], value: boolean): WatchedPlan {
  const unique = new Map<string, MediaItem>();
  for (const item of items) if (item.Id) unique.set(item.Id, item);
  const selected = [...unique.values()].map(item => ({ ...item, UserData: item.UserData ? { ...item.UserData } : undefined }));
  const unsupported = selected.find(item => !supportsWatchedMutation(item));
  if (unsupported) throw new Error(watchedUnavailableReason(unsupported));
  const includesContainers = selected.some(isAggregateItem);
  return { items: selected, value, includesContainers, needsConfirmation: selected.length > 1 || includesContainers };
}
