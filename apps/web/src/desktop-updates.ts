// The desktop app's update service, as the preload exposes it. Only the desktop window has it.
export type UpdateStatus = 'idle' | 'off' | 'checking' | 'current' | 'available' | 'downloading' | 'ready' | 'error';
/** Why Reel offers the release page instead of updating itself, or what went wrong. */
export type UpdateProblem = 'location' | 'translocated' | 'permission' | 'sandbox' | 'platform' | 'install' | 'manifest' | 'signature' | 'download' | 'package';
export interface UpdateState {
  status: UpdateStatus; version: string | null; mode: 'install' | 'download'; checkedAt: number | null;
  /** 0 to 1 while downloading. */
  progress?: number | null;
  problem?: UpdateProblem | null;
}
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

/** Why the next version has to come from the release page, in words a person can act on. */
function downloadReason(problem: UpdateProblem | null | undefined): string {
  switch (problem) {
    case 'location': case 'translocated': return ' Move Reel to your Applications folder and it will update itself.';
    case 'permission': return ' Reel cannot replace itself in the folder it runs from, so download new versions yourself.';
    case 'sandbox': return ' Reel was set up with administrator rights on this computer, so install new versions yourself.';
    case 'install': return ' Reel could not install the last update, so download this one yourself.';
    default: return '';
  }
}

/** What Settings says about updates, and the one action it offers. */
export function updateSummary(state: UpdateState | undefined): { text: string; action?: { id: UpdateAction; label: string } } {
  const version = state?.version ? 'Reel ' + state.version : 'A new version of Reel';
  switch (state?.status) {
    case 'checking': return { text: 'Checking for updates…' };
    // Tens of percent, so a screen reader announces about ten steps rather than a hundred.
    case 'downloading': return { text: `Downloading ${version}` + (typeof state.progress === 'number' ? `, ${Math.floor(state.progress * 10) * 10}%` : '…') };
    case 'ready': return { text: version + ' is ready. It installs when Reel restarts or quits.', action: { id: 'install-update', label: 'Restart to update' } };
    case 'available': return { text: version + ' is available.' + downloadReason(state.problem), action: { id: 'download-update', label: 'Download' } };
    case 'error':
      if (state.problem === 'signature' || state.problem === 'package') return { text: 'The update did not pass Reel’s checks, so it was not installed.', action: { id: 'check-update', label: 'Try again' } };
      if (state.problem === 'download') return { text: 'The update could not be downloaded.', action: { id: 'check-update', label: 'Try again' } };
      return { text: 'Reel could not check for updates.', action: { id: 'check-update', label: 'Try again' } };
    case 'current': return { text: 'Reel is up to date.', action: { id: 'check-update', label: 'Check now' } };
    default: return { text: 'Reel checks for a new version twice a day.' + (state?.mode === 'download' ? downloadReason(state.problem) : ''), action: { id: 'check-update', label: 'Check now' } };
  }
}
