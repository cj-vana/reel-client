// The desktop app's update service, as the preload exposes it. Only the desktop window has it.
export type UpdateStatus = 'idle' | 'off' | 'checking' | 'current' | 'available' | 'downloading' | 'ready' | 'error';
export interface UpdateState { status: UpdateStatus; version: string | null; mode: 'install' | 'download'; checkedAt: number | null }
type Reply = { ok: boolean; state?: UpdateState };
export interface UpdatesBridge {
  state(): Promise<Reply>;
  check(): Promise<Reply>;
  install(): Promise<Reply>;
  download(): Promise<Reply>;
  onChange(callback: (state: UpdateState) => void): () => void;
}
declare global { interface Window { ReelUpdates?: UpdatesBridge } }

export function updatesBridge(value: unknown): UpdatesBridge | undefined {
  if (!value || typeof value !== 'object') return undefined;
  const bridge = value as Record<string, unknown>;
  return ['state', 'check', 'install', 'download', 'onChange'].every(name => typeof bridge[name] === 'function') ? value as UpdatesBridge : undefined;
}

export type UpdateAction = 'check-update' | 'install-update' | 'download-update';

/** What Settings says about updates, and the one action it offers. */
export function updateSummary(state: UpdateState | undefined): { text: string; action?: { id: UpdateAction; label: string } } {
  const version = state?.version ? 'Reel ' + state.version : 'A new version of Reel';
  switch (state?.status) {
    case 'checking': return { text: 'Checking for updates…' };
    case 'downloading': return { text: 'Downloading an update…' };
    case 'ready': return { text: version + ' is ready.', action: { id: 'install-update', label: 'Restart to update' } };
    case 'available': return { text: version + ' is available.', action: { id: 'download-update', label: 'Download' } };
    case 'error': return { text: 'Reel could not check for updates.', action: { id: 'check-update', label: 'Try again' } };
    case 'current': return { text: 'Reel is up to date.', action: { id: 'check-update', label: 'Check now' } };
    default: return { text: 'Reel checks for a new version twice a day.', action: { id: 'check-update', label: 'Check now' } };
  }
}
