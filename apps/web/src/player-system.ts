/** What the player shares with the device around it: the system's media controls, the screen's sleep timer
    and touch gestures on the picture. Each piece takes the browser object it needs, so it runs in tests. */

export interface NowPlaying { title: string; artist?: string; album?: string }
export type SystemPlaybackState = 'none' | 'paused' | 'playing';
interface SessionLike {
  metadata: unknown;
  playbackState: SystemPlaybackState;
  // Method syntax: the browser's own type narrows the action names and the details it passes.
  setActionHandler(action: string, handler: ((details: { seekOffset?: number; seekTime?: number }) => void) | null): void;
  setPositionState?(state?: { duration: number; position: number; playbackRate: number }): void;
}
export interface SystemMediaActions {
  play: () => void;
  pause: () => void;
  stop: () => void;
  /** Seconds to move, negative for back. */
  seekBy: (seconds: number) => void;
  seekTo: (seconds: number) => void;
  previous: () => void;
  next: () => void;
}
const SESSION_ACTIONS = ['play', 'pause', 'stop', 'seekbackward', 'seekforward', 'seekto', 'previoustrack', 'nexttrack'] as const;

/** The lock screen, headset buttons, keyboard media keys and the browser's media hub. A browser may know
    only some actions, so each handler is set on its own and a refusal is ignored. */
export class SystemMediaControls {
  private session?: SessionLike;
  private metadata: (init: { title: string; artist: string; album: string; artwork: { src: string }[] }) => unknown;
  private actions: SystemMediaActions;
  private step: number;
  private now?: NowPlaying;
  private art?: string;
  private opened = false;
  constructor(session: SessionLike | undefined, metadata: (init: { title: string; artist: string; album: string; artwork: { src: string }[] }) => unknown, actions: SystemMediaActions, step = 10) {
    this.session = session; this.metadata = metadata; this.actions = actions; this.step = step;
  }
  private handle(action: string, handler: ((details: { seekOffset?: number; seekTime?: number }) => void) | null): void {
    try { this.session?.setActionHandler(action, handler); } catch { /* This browser does not know the action. */ }
  }
  private describe(): void {
    if (!this.session || !this.now) return;
    this.session.metadata = this.metadata({ title: this.now.title, artist: this.now.artist ?? '', album: this.now.album ?? '', artwork: this.art ? [{ src: this.art }] : [] });
  }
  open(now: NowPlaying): void {
    if (!this.session) return;
    this.opened = true; this.now = now; this.art = undefined; this.describe();
    this.handle('play', () => this.actions.play());
    this.handle('pause', () => this.actions.pause());
    this.handle('stop', () => this.actions.stop());
    this.handle('seekbackward', details => this.actions.seekBy(-(details.seekOffset || this.step)));
    this.handle('seekforward', details => this.actions.seekBy(details.seekOffset || this.step));
    this.handle('seekto', details => { if (typeof details.seekTime === 'number' && Number.isFinite(details.seekTime)) this.actions.seekTo(details.seekTime); });
    this.setEpisodes(false, false);
  }
  /** Artwork arrives after the title; a picture for a title that has since closed is dropped. */
  setArtwork(url: string, title: string): void {
    if (!this.opened || this.now?.title !== title) return;
    this.art = url; this.describe();
  }
  /** Previous and next show only when there is an episode to go to. */
  setEpisodes(previous: boolean, next: boolean): void {
    if (!this.opened) return;
    this.handle('previoustrack', previous ? () => this.actions.previous() : null);
    this.handle('nexttrack', next ? () => this.actions.next() : null);
  }
  setState(state: SystemPlaybackState): void { if (this.session && this.opened) this.session.playbackState = state; }
  /** Live and unloaded media have no finite length, and a browser throws on one. */
  setPosition(duration: number, position: number, rate: number): void {
    if (!this.session?.setPositionState || !this.opened) return;
    try {
      if (!Number.isFinite(duration) || duration <= 0 || !Number.isFinite(position)) { this.session.setPositionState(); return; }
      this.session.setPositionState({ duration, position: Math.min(Math.max(0, position), duration), playbackRate: rate > 0 && Number.isFinite(rate) ? rate : 1 });
    } catch { /* A stale position is harmless; the next update corrects it. */ }
  }
  close(): void {
    if (!this.session || !this.opened) return;
    for (const action of SESSION_ACTIONS) this.handle(action, null);
    this.session.metadata = null; this.session.playbackState = 'none';
    try { this.session.setPositionState?.(); } catch { /* Nothing to clear. */ }
    this.opened = false; this.now = undefined; this.art = undefined;
  }
}

interface WakeSentinel { release: () => Promise<void>; addEventListener: (type: 'release', listener: () => void) => void }
interface WakeLockLike { request: (type: 'screen') => Promise<WakeSentinel> }
/** Keeps the screen on while a video plays. Browsers offer this on secure pages only, drop it when the page
    is hidden and refuse it on a low battery, so it is asked for again whenever playback is showing. */
export class ScreenWake {
  private lock?: WakeLockLike;
  private sentinel?: WakeSentinel;
  private wanted = false;
  private request = 0;
  constructor(lock: WakeLockLike | undefined) { this.lock = lock; }
  get held(): boolean { return !!this.sentinel; }
  /** Call with whether a video is playing on a visible page. */
  set(playing: boolean): void {
    this.wanted = playing;
    if (!playing) { this.drop(); return; }
    if (this.sentinel || !this.lock) return;
    const request = ++this.request;
    let pending: Promise<WakeSentinel>;
    try { pending = this.lock.request('screen'); } catch { return; }
    pending.then(sentinel => {
      if (request !== this.request || !this.wanted) { void sentinel.release().catch(() => undefined); return; }
      this.sentinel = sentinel;
      sentinel.addEventListener('release', () => { if (this.sentinel === sentinel) this.sentinel = undefined; });
    }, () => undefined);
  }
  private drop(): void {
    this.request++;
    const sentinel = this.sentinel; this.sentinel = undefined;
    if (sentinel) void sentinel.release().catch(() => undefined);
  }
}

/** Two quick taps on one side of the picture seek back or forward; each further tap adds another step.
    A single tap is never held back: the first tap of a pair has already done whatever one tap does. */
export class DoubleTapSeek {
  private lastTime = -Infinity;
  private lastX = 0;
  private lastY = 0;
  private run = 0;
  private side?: -1 | 1;
  private window: number;
  private reach: number;
  constructor(window = 320, reach = 48) { this.window = window; this.reach = reach; }
  /** The direction to seek for this tap, or undefined for a first or stray tap. The middle fifth of the
      picture belongs to play and pause and never seeks. */
  tap(x: number, y: number, width: number, now: number): -1 | 1 | undefined {
    const near = now - this.lastTime <= this.window && Math.abs(x - this.lastX) <= this.reach && Math.abs(y - this.lastY) <= this.reach;
    this.lastTime = now; this.lastX = x; this.lastY = y;
    const side = width > 0 && x < width * .4 ? -1 : width > 0 && x > width * .6 ? 1 : undefined;
    if (!near || !side || side !== this.side) { this.side = side; this.run = side ? 1 : 0; return undefined; }
    this.run++;
    return side;
  }
  reset(): void { this.lastTime = -Infinity; this.run = 0; this.side = undefined; }
}
