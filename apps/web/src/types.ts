export const TICKS = 10_000_000;

export interface UserData {
  PlaybackPositionTicks?: number;
  PlayedPercentage?: number;
  IsFavorite?: boolean;
  Played?: boolean;
  UnplayedItemCount?: number | null;
}

export interface MediaStream {
  Index: number; Type: string; Codec?: string; DisplayTitle?: string;
  Language?: string; IsExternal?: boolean; DeliveryUrl?: string;
  BitRate?: number; BitDepth?: number; Channels?: number; SampleRate?: number;
  Width?: number; Height?: number; RealFrameRate?: number; VideoRangeType?: string; DvProfile?: number;
  AudioSpatialFormat?: string; Profile?: string; DvBlSignalCompatibilityId?: number; Hdr10PlusPresentFlag?: boolean;
}

export interface MediaSource {
  Id: string; Container?: string; SupportsDirectPlay?: boolean;
  SupportsDirectStream?: boolean; TranscodingUrl?: string;
  RunTimeTicks?: number; MediaStreams?: MediaStream[];
  DefaultAudioStreamIndex?: number; DefaultSubtitleStreamIndex?: number;
  LiveStreamId?: string;
}

export interface MediaItem {
  Id: string; Name: string; Type?: string; IsFolder?: boolean | null; MediaType?: string;
  Overview?: string; ProductionYear?: number; OfficialRating?: string;
  CommunityRating?: number; RunTimeTicks?: number; Genres?: string[];
  DateCreated?: string | null; DateLastMediaAdded?: string | null; PlaylistItemId?: string;
  ImageTags?: Record<string, string>; BackdropImageTags?: string[];
  ParentBackdropItemId?: string; ParentBackdropImageTags?: string[];
  SeriesId?: string; SeriesName?: string; SeriesPrimaryImageTag?: string; SeasonId?: string;
  IndexNumber?: number; ParentIndexNumber?: number; UserData?: UserData;
  MediaSources?: MediaSource[]; CollectionType?: string;
  People?: Array<{ Id: string; Name: string; Role?: string; Type?: string }>;
  Chapters?: Array<{ Name?: string; StartPositionTicks: number }>;
}

export interface ItemPage { Items: MediaItem[]; TotalRecordCount?: number }
export interface PlaybackInfo { MediaSources: MediaSource[]; PlaySessionId?: string; ErrorCode?: string }
export interface Account {
  id: string; server: string; token: string; userId: string;
  name: string; serverName: string; remember: boolean;
}

export type RuntimePlatform = 'web' | 'webos' | 'tizen' | 'desktop';
export interface RuntimeConfig { previewMode: boolean; appName: string; platform: RuntimePlatform }
declare global { interface Window { REEL_CONFIG?: Partial<RuntimeConfig>; PalmSystem?: { platformBack?: () => void }; ReelTizen?: { platformBack?: () => void } } }
declare global { const __REEL_NATIVE_HLS_ONLY__: boolean; }

export function resumeSeconds(item: MediaItem): number {
  const ticks = item.UserData?.PlaybackPositionTicks ?? 0;
  return Number.isFinite(ticks) ? Math.max(0, ticks / TICKS) : 0;
}

export function duration(seconds: number): string {
  const bounded = Math.max(0, seconds);
  if (bounded < 60) return `${Math.round(bounded)}s`;
  const minutes = Math.floor(bounded / 60);
  return minutes >= 60 ? `${Math.floor(minutes / 60)}h ${minutes % 60}m` : `${minutes}m`;
}

/** "S1 E2", or as much of it as the server knows. */
export function episodeCode(item: MediaItem): string {
  const season = Number.isSafeInteger(item.ParentIndexNumber) && item.ParentIndexNumber! >= 0 ? `S${item.ParentIndexNumber}` : '';
  const episode = Number.isSafeInteger(item.IndexNumber) && item.IndexNumber! >= 0 ? `E${item.IndexNumber}` : '';
  return [season, episode].filter(Boolean).join(' ');
}

export function subtitle(item: MediaItem): string {
  if (item.Type === 'Episode') return [episodeCode(item), item.Name].filter(Boolean).join(' ');
  return [item.ProductionYear, item.Type === 'Series' ? 'Series' : item.RunTimeTicks ? duration(item.RunTimeTicks / TICKS) : typeLabel(item.Type)].filter(Boolean).join(' · ');
}

// Jellyfin type names read as words people use.
const typeLabels: Record<string, string> = {
  MusicAlbum: 'Album', PhotoAlbum: 'Album', MusicArtist: 'Artist', BoxSet: 'Collection', CollectionFolder: 'Library',
  TvChannel: 'Channel', Audio: 'Track', AudioBook: 'Audiobook', MusicVideo: 'Music video', Recording: 'Recording'
};
export function typeLabel(type: string | undefined): string | undefined { return type ? typeLabels[type] ?? type : undefined; }
