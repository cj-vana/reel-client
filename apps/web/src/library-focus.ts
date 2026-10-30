import type { MediaItem } from './types.ts';

export interface BrowseFocus {
  media?: string;
  id?: string;
  action?: string;
  category?: string;
  view?: string;
  value?: string;
  selection?: string;
  caret?: [number | null, number | null];
}
/** Playlist entry IDs identify occurrences; legacy responses fall back to per-ID occurrence numbers. */
export function mediaFocusIdentity(items: readonly MediaItem[], index: number, playlist: boolean): string {
  const item = items[index];
  if (!playlist) return 'item:' + item.Id;
  if (item.PlaylistItemId) return 'entry:' + item.PlaylistItemId;
  return 'occurrence:' + item.Id + ':' + items.slice(0, index).filter(previous => previous.Id === item.Id).length;
}
export function captureBrowseFocus(root: HTMLElement): BrowseFocus | undefined {
  const active = document.activeElement as HTMLInputElement | null;
  if (!active || !root.contains(active)) return;
  const media = active.closest<HTMLElement>('[data-browse-identity]')?.dataset.browseIdentity;
  if (media) return { media, selection: active.dataset.browseSelect };
  return { id: active.id || undefined, action: active.dataset.action, category: active.dataset.category, view: active.dataset.view,
    value: active.dataset.value, selection: active.dataset.browseSelect,
    caret: active.tagName === 'INPUT' && active.type === 'search' ? [active.selectionStart, active.selectionEnd] : undefined };
}
export function restoreBrowseFocus(root: HTMLElement, captured: BrowseFocus | undefined): 'restored' | 'removed' | 'none' {
  if (!captured) return 'none';
  const target = captured.media ? [...root.querySelectorAll<HTMLElement>('[data-browse-identity]')].find(node => node.dataset.browseIdentity === captured.media && (captured.selection !== undefined ? node.dataset.browseSelect === captured.selection : !node.dataset.browseSelect))
    : captured.id ? [...root.querySelectorAll<HTMLElement>('[id]')].find(node => node.id === captured.id)
    : [...root.querySelectorAll<HTMLElement>('[data-action],[data-browse-select]')].find(node => captured.selection !== undefined ? node.dataset.browseSelect === captured.selection
      : !!captured.action && node.dataset.action === captured.action && node.dataset.category === captured.category && node.dataset.view === captured.view && node.dataset.value === captured.value);
  if (target && !target.hasAttribute('disabled')) {
    target.focus({ preventScroll: true });
    if (target instanceof HTMLInputElement && captured.caret && captured.caret[0] !== null && captured.caret[1] !== null) target.setSelectionRange(captured.caret[0], captured.caret[1]);
    if (captured.media) (target.querySelector<HTMLElement>('.browse-item-copy') ?? target).scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'auto' });
    return 'restored';
  }
  if (captured.media) {
    const fallback = root.querySelector<HTMLElement>('#browse-count');
    fallback?.focus({ preventScroll: true }); fallback?.scrollIntoView({ block: 'nearest', behavior: 'auto' });
    return 'removed';
  }
  return 'none';
}
