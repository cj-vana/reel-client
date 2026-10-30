import { type Account, type MediaItem, TICKS } from './types.ts';

// Desktop downloads, as the preload exposes them. Only the desktop window has this bridge.
export type DownloadSize = 'high' | 'standard' | 'small';
export interface OfflineEntry {
  id: string; itemId: string; title: string; subtitle: string; runtime: number; size: DownloadSize;
  state: 'queued' | 'downloading' | 'complete' | 'failed'; progress: number; bytes: number; position: number; error: string | null; art: boolean; createdAt: number;
}
export interface DownloadRequest {
  accountId: string; server: string; token: string; userId: string; deviceId: string; itemId: string; mediaSourceId: string;
  size: DownloadSize; title: string; subtitle: string; runtime: number;
}
type Reply = { ok: boolean; items?: OfflineEntry[]; item?: OfflineEntry };
export interface OfflineBridge {
  list(accountId: string): Promise<Reply>;
  start(request: DownloadRequest): Promise<Reply>;
  remove(accountId: string, id: string): Promise<Reply>;
  forget(accountId: string): Promise<Reply>;
  position(accountId: string, id: string, seconds: number): Promise<Reply>;
  onChange(callback: () => void): () => void;
}
declare global { interface Window { ReelOffline?: OfflineBridge } }

export function offlineBridge(value: unknown): OfflineBridge | undefined {
  if (!value || typeof value !== 'object') return undefined;
  const bridge = value as Record<string, unknown>;
  return ['list', 'start', 'remove', 'forget', 'position', 'onChange'].every(name => typeof bridge[name] === 'function') ? value as OfflineBridge : undefined;
}

// The same sizes as the iPhone and iPad app, which the desktop main process converts at (apps/desktop/src/offline.mjs).
const AUDIO_BITRATE = 128_000;
export const DOWNLOAD_SIZES: ReadonlyArray<{ id: DownloadSize; title: string; videoBitRate: number }> = [
  { id: 'high', title: 'High · 1080p', videoBitRate: 6_000_000 },
  { id: 'standard', title: 'Standard · 720p', videoBitRate: 1_872_000 },
  { id: 'small', title: 'Data saver · 480p', videoBitRate: 900_000 }
];

/** Storage for an hour at a size, from its video and audio bitrates. */
export function perHour(videoBitRate: number): string {
  const gigabytes = (videoBitRate + AUDIO_BITRATE) * 3600 / 8 / 1e9;
  return `About ${gigabytes.toFixed(1)} GB an hour`;
}

export function downloadable(item: MediaItem): boolean {
  return (item.Type === 'Movie' || item.Type === 'Episode') && !!item.MediaSources?.[0]?.Id;
}

export function downloadRequest(account: Account, deviceId: string, item: MediaItem, size: DownloadSize, sourceId?: string): DownloadRequest {
  const source = item.MediaSources?.find(candidate => candidate.Id === sourceId) ?? item.MediaSources?.[0];
  if (!source?.Id) throw new Error('This title has no version to download.');
  const episode = item.Type === 'Episode' ? [Number.isSafeInteger(item.ParentIndexNumber) ? 'S' + item.ParentIndexNumber : '', Number.isSafeInteger(item.IndexNumber) ? 'E' + item.IndexNumber : ''].filter(Boolean).join(' ') : '';
  return {
    accountId: account.id, server: account.server, token: account.token, userId: account.userId, deviceId, itemId: item.Id, mediaSourceId: source.Id, size,
    title: (item.Type === 'Episode' ? item.SeriesName ?? item.Name : item.Name).slice(0, 300),
    subtitle: (item.Type === 'Episode' ? [episode, item.Name].filter(Boolean).join(' · ') : item.ProductionYear ? String(item.ProductionYear) : '').slice(0, 300),
    runtime: typeof item.RunTimeTicks === 'number' && item.RunTimeTicks > 0 ? Math.min(86_399, item.RunTimeTicks / TICKS) : 0
  };
}

export const offlineURL = (entry: OfflineEntry, file = 'index.m3u8') => `reel://app/offline/${entry.id}/${file}`;

/** One line for a download's state in a list. */
export function downloadStatus(entry: OfflineEntry): string {
  const size = DOWNLOAD_SIZES.find(value => value.id === entry.size)?.title ?? '';
  if (entry.state === 'queued') return 'Waiting to download';
  if (entry.state === 'downloading') return `Downloading, ${Math.floor(entry.progress * 100)}%`;
  if (entry.state === 'failed') return entry.error ?? 'The download stopped.';
  return [size, entry.bytes ? (entry.bytes / 1e9 >= 1 ? (entry.bytes / 1e9).toFixed(1) + ' GB' : Math.max(1, Math.round(entry.bytes / 1e6)) + ' MB') : ''].filter(Boolean).join(' · ');
}
