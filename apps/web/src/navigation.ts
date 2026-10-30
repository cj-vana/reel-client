import { installTVChoices } from './tv-select.ts';
import { nativeVideoFullscreen } from './player-presentation.ts';
export type Direction = 'left' | 'right' | 'up' | 'down';
export interface Rect { left: number; top: number; width: number; height: number }

export function directionalScore(origin: Rect, candidate: Rect, direction: Direction): number {
  const dx = candidate.left + candidate.width / 2 - origin.left - origin.width / 2;
  const dy = candidate.top + candidate.height / 2 - origin.top - origin.height / 2;
  const forward = direction === 'left' ? -dx : direction === 'right' ? dx : direction === 'up' ? -dy : dy;
  const sideways = direction === 'left' || direction === 'right' ? Math.abs(dy) : Math.abs(dx);
  if (forward <= 1) return Infinity;
  return forward + sideways * 3 + sideways * sideways / Math.max(forward, 1);
}

export function navigationVisible(element: HTMLElement): boolean {
  const rect = element.getBoundingClientRect();
  // A closed disclosure keeps layout boxes for its content, but only its summary can take focus.
  const closed = element.closest('details:not([open])');
  if (closed && !element.closest('summary')) return false;
  return rect.width > 0 && rect.height > 0 && getComputedStyle(element).visibility !== 'hidden' && !element.closest('[hidden],[inert],[aria-hidden="true"]');
}

// webOS reports its on-screen keyboard with keyboardStateChange; installNavigation keeps this current.
let systemKeyboardVisible = false;

function keepsArrowKey(element: HTMLElement | null, direction: Direction, tv: boolean): boolean {
  if (!element) return false;
  if (element.isContentEditable || element.tagName === 'TEXTAREA') return true;
  // On TV the picture itself seeks with Left and Right.
  if (element.tagName === 'VIDEO') return tv && (direction === 'left' || direction === 'right');
  if (element.tagName === 'SELECT') return !tv;
  if (element.tagName !== 'INPUT') return false;
  const type = element.getAttribute('type') ?? 'text';
  if (!tv) return true;
  if (['checkbox', 'radio', 'button', 'submit', 'reset'].includes(type)) return false;
  // While the TV's own keyboard is up, every arrow belongs to it.
  if (systemKeyboardVisible) return true;
  if (direction === 'up' || direction === 'down') return false;
  // On TV a text field keeps Left and Right while its caret can move; at either end they leave the field.
  const field = element as HTMLInputElement;
  if (field.selectionStart === null || field.selectionEnd === null) return true;
  return direction === 'left' ? field.selectionStart > 0 : field.selectionEnd < field.value.length;
}

// On TV, Left and Right stay inside a horizontal row, and each row remembers its last focused item.
const tvRow = '.shelf-track,.tv-row';
const tvBar = '#rail';
const reducedMotion = () => typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;

/** Keeps a TV focus target on screen: rows page so a whole card sits on the left edge, pages scroll vertically. */
export function revealTV(element: HTMLElement): void {
  const behavior: ScrollBehavior = reducedMotion() ? 'auto' : 'smooth';
  const track = element.closest<HTMLElement>(tvRow);
  if (track && track.scrollWidth > track.clientWidth + 1) {
    const style = getComputedStyle(track), frame = track.getBoundingClientRect(), box = element.getBoundingClientRect();
    const start = frame.left + (parseFloat(style.scrollPaddingLeft) || 0), end = frame.right - (parseFloat(style.scrollPaddingRight) || 0);
    const current = track.scrollLeft;
    let left = current;
    if (box.left < start) left = current + box.left - start;
    else if (box.right > end) {
      const needed = current + box.right - end;
      const anchors = [...track.children].map(child => child.getBoundingClientRect().left - start + current).filter(position => position >= needed - 1);
      left = anchors.length ? Math.min(...anchors) : needed;
    }
    left = Math.max(0, Math.min(left, track.scrollWidth - track.clientWidth));
    if (Math.abs(left - current) > 1) track.scrollTo({ left, behavior });
  }
  if (element.closest(tvBar)) return;
  if (!element.closest('#content')) { element.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior }); return; }
  // A pinned row keeps its top on a fixed line (TV Home); "top" returns the page to the start.
  const pinned = element.closest<HTMLElement>('[data-tv-pin]');
  let top: number | undefined;
  if (pinned) {
    top = pinned.dataset.tvPin === 'top' ? 0 : pinned.getBoundingClientRect().top + window.scrollY - (parseFloat(getComputedStyle(pinned).scrollMarginTop) || 0);
    // A row taller than the space below the pin line (posters with their caption) rises until the focused item fits.
    const box = element.getBoundingClientRect(), below = parseFloat(getComputedStyle(element).scrollMarginBottom) || 0;
    const overflow = box.bottom - (top - window.scrollY) + below - window.innerHeight;
    if (pinned.dataset.tvPin !== 'top' && overflow > 0) top += overflow;
  } else {
    // A group (the episodes of a season) comes into view whole when it fits on screen.
    const group = element.closest<HTMLElement>('[data-tv-group]'), style = getComputedStyle(element);
    const above = parseFloat(style.scrollMarginTop) || 0, below = parseFloat(style.scrollMarginBottom) || 0;
    const whole = group?.getBoundingClientRect();
    const box = whole && whole.height + above + below <= window.innerHeight ? whole : element.getBoundingClientRect();
    if (box.top - above < 0) top = window.scrollY + box.top - above;
    else if (box.bottom + below > window.innerHeight) top = window.scrollY + box.bottom + below - window.innerHeight;
  }
  if (top !== undefined && Math.abs(Math.max(0, top) - window.scrollY) > 1) window.scrollTo({ top: Math.max(0, top), behavior });
}

/** The tab a remote returns to from content: the current section, else Home. */
export function currentTab(root: ParentNode = document): HTMLElement | null {
  const tab = root.querySelector<HTMLElement>('#rail .tv-current') ?? root.querySelector<HTMLElement>('#rail [data-route="Home"]');
  return tab && navigationVisible(tab) && !(tab as HTMLButtonElement).disabled ? tab : null;
}

const overlaps = (box: DOMRect, line: DOMRect) => box.top < line.top + line.height && box.top + box.height > line.top;

/** TV Up and Down: the nearest line of controls in that direction, then the remembered or horizontally nearest item on it. */
function nextLine(candidates: HTMLElement[], active: HTMLElement, origin: DOMRect, direction: Direction, memory: WeakMap<Element, HTMLElement>): HTMLElement | undefined {
  const down = direction === 'down', middle = origin.top + origin.height / 2, center = origin.left + origin.width / 2;
  const sideways = (node: HTMLElement) => { const box = node.getBoundingClientRect(); return Math.abs(box.left + box.width / 2 - center); };
  const ahead = candidates.filter(node => {
    if (node === active) return false;
    const box = node.getBoundingClientRect(), mid = box.top + box.height / 2;
    // A surface behind the control (the full-screen video) is never the next line.
    if (box.left <= origin.left && box.right >= origin.right && box.top <= origin.top && box.bottom >= origin.bottom) return false;
    return down ? mid > middle + 1 : mid < middle - 1;
  });
  const gap = (node: HTMLElement) => { const box = node.getBoundingClientRect(); return down ? box.top - origin.bottom : origin.top - box.bottom; };
  let nearest = ahead.reduce<HTMLElement | undefined>((found, node) => !found || gap(node) < gap(found) - 1 || Math.abs(gap(node) - gap(found)) <= 1 && sideways(node) < sideways(found) ? node : found, undefined);
  if (!nearest) return undefined;
  // Entering a row from outside lands on its items, not on the buttons in its heading.
  const shelf = nearest.closest('.shelf');
  if (nearest.closest('.shelf > header') && shelf && !shelf.contains(active)) {
    const items = ahead.filter(node => node.closest(tvRow) && shelf.contains(node));
    if (items.length) nearest = items.reduce((found, node) => gap(node) < gap(found) ? node : found);
  }
  const row = nearest.closest(tvRow), line = nearest.getBoundingClientRect();
  const remembered = row && !row.contains(active) ? memory.get(row) : undefined;
  if (remembered && candidates.includes(remembered)) return remembered;
  const peers = ahead.filter(node => overlaps(node.getBoundingClientRect(), line) && (!row || row.contains(node)));
  return peers.reduce((found, node) => sideways(node) < sideways(found) ? node : found, nearest);
}

export interface NavigationHooks {
  /** Called when a TV arrow finds no target. Return true when the key was handled. */
  edge?: (direction: Direction, active: HTMLElement) => boolean;
}

export function installNavigation(onBack: () => void, scope: () => HTMLElement, hooks: NavigationHooks = {}): void {
  const choices = installTVChoices();
  let lastContentFocus: HTMLElement | null = null;
  const rowMemory = new WeakMap<Element, HTMLElement>();
  document.addEventListener('keyboardStateChange', event => {
    const visible = (event as CustomEvent<{ visibility?: boolean }>).detail?.visibility;
    if (typeof visible === 'boolean') systemKeyboardVisible = visible;
  });
  document.addEventListener('focusin', event => {
    if (document.documentElement.dataset.layout !== 'tv') return;
    const target = event.target as HTMLElement;
    if (target.closest?.('#content')) lastContentFocus = target;
    const row = target.closest?.(tvRow);
    if (row) rowMemory.set(row, target);
  });
  document.addEventListener('keydown', event => {
    const active = document.activeElement as HTMLElement | null;
    const typing = active && (active.matches('input,textarea,select') || active.isContentEditable);
    if (choices.key(event)) return;
    const currentScope = choices.scope() ?? scope();
    const tv = document.documentElement.dataset.layout === 'tv';
    if (tv && event.key === 'Enter' && active?.matches('input[type="checkbox"]:not([disabled]),input[type="radio"]:not([disabled])') && currentScope.contains(active)) {
      event.preventDefault(); active.click(); return;
    }
    if (event.key === 'Escape' || event.key === 'BrowserBack' || event.keyCode === 461) {
      if (typing && event.key !== 'Escape') { active.blur(); return; }
      event.preventDefault(); onBack(); return;
    }
    if (nativeVideoFullscreen(document.fullscreenElement)) return;
    if (event.key === 'Tab' && currentScope.getAttribute('role') === 'dialog') {
      const controls = Array.from(currentScope.querySelectorAll<HTMLElement>('button:not([disabled]),input:not([disabled]),select:not([disabled]),video,[tabindex="0"]')).filter(navigationVisible);
      event.preventDefault();
      if (controls.length) {
        const index = active ? controls.indexOf(active) : -1;
        controls[(index + (event.shiftKey ? -1 : 1) + controls.length) % controls.length].focus();
      }
      return;
    }
    const directions: Record<string, Direction> = { ArrowLeft: 'left', ArrowRight: 'right', ArrowUp: 'up', ArrowDown: 'down' };
    const direction = directions[event.key];
    if (!direction || keepsArrowKey(active, direction, tv) || active?.tagName === 'VIDEO' && !tv) return;
    let candidates = Array.from(currentScope.querySelectorAll<HTMLElement>('button:not([disabled]),a[href],input:not([disabled]),select:not([disabled]),[tabindex="0"]')).filter(navigationVisible);
    const horizontal = direction === 'left' || direction === 'right';
    const move = (target: HTMLElement) => {
      target.focus({ preventScroll: true });
      if (tv) revealTV(target);
      else target.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'smooth' });
    };
    // The TV tab bar: Left and Right move along it, Down returns to the content the remote left.
    const bar = tv && active && !active.closest('#mobile-more-menu') ? active.closest<HTMLElement>(tvBar) : null;
    if (bar) {
      event.preventDefault();
      if (direction === 'up') return;
      if (direction === 'down') {
        if (lastContentFocus?.isConnected && !bar.contains(lastContentFocus) && candidates.includes(lastContentFocus)) { move(lastContentFocus); return; }
        candidates = candidates.filter(node => !bar.contains(node) || node === active);
      } else candidates = candidates.filter(node => bar.contains(node));
    }
    if (!candidates.length) return;
    event.preventDefault();
    if (!active || !candidates.includes(active)) {
      const primary = tv ? candidates.find(node => node.matches('#content .hero [data-action="play"]')) ?? candidates.find(node => node.closest('#content')) : undefined;
      (primary ?? candidates[0]).focus(); return;
    }
    const origin = active.getBoundingClientRect();
    // TV Left and Right never change lines, and never leave the row they are in.
    const row = tv && horizontal ? active.closest('.shelf-track,.tv-row,.feature-selector,.browse-results') : null;
    if (tv && horizontal) candidates = candidates.filter(node => (!row || row.contains(node)) && overlaps(node.getBoundingClientRect(), origin));
    let best: HTMLElement | undefined, bestScore = Infinity;
    // Down from the summary of an open disclosure (Filters, a Details menu) enters at its first choice.
    const disclosure = tv && direction === 'down' && active.tagName === 'SUMMARY' ? active.parentElement as HTMLDetailsElement | null : null;
    if (disclosure?.open) best = candidates.find(node => node !== active && disclosure.contains(node));
    if (best) { move(best); return; }
    if (tv && !horizontal) best = nextLine(candidates, active, origin, direction, rowMemory);
    else for (const candidate of candidates) {
      if (candidate === active) continue;
      const score = directionalScore(origin, candidate.getBoundingClientRect(), direction);
      if (score < bestScore) { bestScore = score; best = candidate; }
    }
    // Up from the top of the page reaches the current tab, even while the bar is faded out.
    if (tv && direction === 'up' && active.closest('#content') && (!best || best.closest(tvBar))) best = currentTab(currentScope) ?? best;
    if (!best && tv && hooks.edge?.(direction, active)) return;
    if (best) move(best);
  });
}

export function restoreFocus(root: HTMLElement, selector?: string): void {
  const target = selector ? root.querySelector<HTMLElement>(selector) : root.querySelector<HTMLElement>('[autofocus],button:not([disabled]),input:not([disabled])');
  target?.focus({ preventScroll: true });
}
