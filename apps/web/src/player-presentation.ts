/** A stable clock label for unloaded, live and finite media. */
export function playbackTime(seconds: number): string {
  const total = Number.isFinite(seconds) ? Math.max(0, Math.floor(seconds)) : 0;
  const hours = Math.floor(total / 3600), minutes = Math.floor(total / 60) % 60;
  return (hours ? hours + ':' + String(minutes).padStart(2, '0') : String(minutes)) + ':' + String(total % 60).padStart(2, '0');
}

export type PlayerViewState = 'preparing' | 'buffering' | 'playing' | 'paused' | 'ended' | 'error';
interface Clock { set: (callback: () => void, milliseconds: number) => unknown; clear: (handle: unknown) => void }

interface ControlsView {
  visible: (value: boolean) => void;
  focused: () => boolean;
  /** Milliseconds of idle playback before the controls hide (3000 by default). */
  delay?: number;
  /** TV: hide even while a control holds focus, after handing focus to the picture. */
  yieldFocus?: () => void;
}

/** Only idle, actively playing video may hide its controls. Focus and dialogs keep them reachable. */
export class PlayerControls {
  private timer?: unknown;
  private opened = false;
  private wakeID = 0;
  private panel = false;
  private state: PlayerViewState = 'preparing';
  private view: ControlsView;
  private clock: Clock;
  constructor(view: ControlsView, clock: Clock = {
    set: (callback, milliseconds) => setTimeout(callback, milliseconds), clear: handle => clearTimeout(handle as ReturnType<typeof setTimeout>)
  }) { this.view = view; this.clock = clock; }
  private clear(): void { this.wakeID++; if (this.timer !== undefined) this.clock.clear(this.timer); this.timer = undefined; }
  open(): void { this.opened = true; this.state = 'preparing'; this.panel = false; this.wake(); }
  close(): void { this.opened = false; this.panel = false; this.clear(); this.view.visible(false); }
  setState(state: PlayerViewState): void { this.state = state; this.wake(); }
  setPanel(open: boolean): void { this.panel = open; this.wake(); }
  wake(): void {
    this.clear(); if (!this.opened) return;
    this.view.visible(true);
    const yieldFocus = this.view.yieldFocus;
    if (this.state !== 'playing' || this.panel || !yieldFocus && this.view.focused()) return;
    const owner = this.wakeID;
    this.timer = this.clock.set(() => {
      if (owner !== this.wakeID) return;
      this.timer = undefined;
      if (!this.opened || this.state !== 'playing' || this.panel) return;
      if (this.view.focused()) { if (!yieldFocus) return; yieldFocus(); }
      this.view.visible(false);
    }, this.view.delay ?? 3000);
  }
}

export function nativeVideoFullscreen(element: Element | null): boolean { return element?.tagName === 'VIDEO'; }
export async function togglePlayerFullscreen(player: HTMLElement): Promise<void> {
  const doc = player.ownerDocument;
  if (doc.fullscreenElement) { await doc.exitFullscreen(); return; }
  if (typeof player.requestFullscreen !== 'function') throw new Error('Full screen is unavailable on this browser. Video still fills the player.');
  await player.requestFullscreen();
}
export async function exitPlayerFullscreen(player: HTMLElement): Promise<void> {
  const doc = player.ownerDocument;
  if (doc.fullscreenElement && player.contains(doc.fullscreenElement)) await doc.exitFullscreen();
}

/** DOM adapter only: source negotiation, video events and history remain owned by ReelPlayer. */
export function installPlayerPresentation(player: HTMLElement, video: HTMLVideoElement, background: readonly HTMLElement[], remote = false) {
  const overlays = [...player.querySelectorAll<HTMLElement>('[data-player-overlay]')];
  const contextual = [...player.querySelectorAll<HTMLElement>('[data-player-contextual]')];
  let panel = false;
  let nativeControls: boolean | undefined, nativeTabIndex = 0;
  const screen = player.querySelector<HTMLElement>('.screen');
  const focusGuard = (event: Event) => {
    if (player.hidden) return;
    const target = event.target as HTMLElement;
    if (!target?.closest?.('[inert]') || !player.contains(target) && !background.some(node => node.contains(target))) return;
    const fallback = panel ? player.querySelector<HTMLElement>('[data-action="close-format"]') : video;
    fallback?.focus({ preventScroll: true });
  };
  player.ownerDocument.addEventListener('focusin', focusGuard, true);
  const visible = (value: boolean) => {
    player.dataset.controls = value ? 'visible' : 'hidden';
    for (const overlay of overlays) {
      overlay.toggleAttribute('inert', !value || panel);
      overlay.setAttribute('aria-hidden', String(!value || panel));
    }
    for (const control of contextual) { control.toggleAttribute('inert', panel); control.setAttribute('aria-hidden', String(panel)); }
  };
  // A remote has no pointer to wake the controls by hovering, so TV keeps them a little longer and,
  // when they hide, moves focus from the transport to the picture (Skip intro keeps its focus).
  const controls = new PlayerControls({
    visible, focused: () => [...overlays, ...contextual].some(node => node.contains(player.ownerDocument.activeElement)),
    ...remote ? { delay: 4000, yieldFocus: () => { if (overlays.some(node => node.contains(player.ownerDocument.activeElement))) video.focus({ preventScroll: true }); } } : {}
  });
  const wake = () => controls.wake();
  const fullscreenChanged = () => {
    const button = player.querySelector<HTMLElement>('[data-action="fullscreen"]');
    const active = player.ownerDocument.fullscreenElement === player;
    button?.setAttribute('aria-label', active ? 'Exit full screen' : 'Full screen');
    if (button) button.querySelector('span')!.textContent = active ? 'Exit full screen' : 'Full screen';
    wake();
  };
  player.ownerDocument.addEventListener('fullscreenchange', fullscreenChanged);
  const focusOut = () => { void Promise.resolve().then(wake); };
  for (const name of ['pointermove', 'pointerdown', 'keydown', 'focusin', 'reel-player-wake']) player.addEventListener(name, wake, true);
  player.addEventListener('focusout', focusOut);
  return {
    open() {
      panel = false; player.hidden = false;
      for (const node of background) { node.setAttribute('aria-hidden', 'true'); node.setAttribute('inert', ''); }
      video.tabIndex = 0; video.removeAttribute('inert'); controls.open(); video.focus({ preventScroll: true });
    },
    close() {
      this.setPanel(false); controls.close(); player.hidden = true; video.removeAttribute('inert');
      const status = player.querySelector<HTMLElement>('#toast');
      if (status) { status.hidden = true; player.parentElement?.append(status); }
      for (const node of background) { node.removeAttribute('aria-hidden'); node.removeAttribute('inert'); }
    },
    setState(state: PlayerViewState) { player.dataset.state = state; controls.setState(state); },
    setPanel(open: boolean) {
      if (open && !panel) { nativeControls = video.controls; nativeTabIndex = video.tabIndex; video.controls = false; video.tabIndex = -1; }
      else if (!open && panel && nativeControls !== undefined) { video.controls = nativeControls; video.tabIndex = nativeTabIndex; nativeControls = undefined; }
      panel = open; video.toggleAttribute('inert', open); screen?.toggleAttribute('inert', open); screen?.setAttribute('aria-hidden', String(open)); controls.setPanel(open);
    },
    wake,
    dispose() {
      this.close();
      for (const name of ['pointermove', 'pointerdown', 'keydown', 'focusin', 'reel-player-wake']) player.removeEventListener(name, wake, true);
      player.removeEventListener('focusout', focusOut);
      player.ownerDocument.removeEventListener('fullscreenchange', fullscreenChanged);
      player.ownerDocument.removeEventListener('focusin', focusGuard, true);
    }
  };
}

export function installPageCacheRecovery(target: EventTarget, actions: { suspend: (persisted: boolean) => void; restore: () => void }): () => void {
  const hide = (event: Event) => actions.suspend((event as PageTransitionEvent).persisted);
  const show = (event: Event) => { if ((event as PageTransitionEvent).persisted) actions.restore(); };
  target.addEventListener('pagehide', hide); target.addEventListener('pageshow', show);
  return () => { target.removeEventListener('pagehide', hide); target.removeEventListener('pageshow', show); };
}


/** Wait for the actual route, then reject any superseded account or navigation before moving focus. */
export async function restoreAfterNavigation(navigation: Promise<void>, owner: string, current: () => string | undefined, restore: () => void): Promise<boolean> {
  await navigation;
  if (current() !== owner) return false;
  restore(); return true;
}

export function scrollFormatPanel(panel: HTMLElement, direction: number, page = false): boolean {
  const movable = direction < 0 ? panel.scrollTop > 0 : panel.scrollTop + panel.clientHeight < panel.scrollHeight - 1;
  if (!movable) return false;
  panel.scrollBy({ top: direction * (page ? panel.clientHeight * .8 : 50) }); return true;
}

export function statusContainer(player: HTMLElement, application: HTMLElement, playing: boolean): HTMLElement {
  return playing && !player.hidden ? player : application;
}

export function playerActivationAllowed(target: HTMLElement): boolean { return !target.closest('[inert]'); }
