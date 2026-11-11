/** Addresses for Reel's screens in a plain browser, so the browser's Back and Forward buttons, a reload and
    a copied link all work. The address names a screen and, at most, the id of one title. It never carries a
    server, an account, a sign-in, a filter or anything typed into a search field. */

export interface LinkRoute { name: string; item?: string }

const PAGES: readonly (readonly [string, string])[] = [
  ['Home', ''], ['Library', 'library'], ['Favorites', 'favorites'], ['Search', 'search'], ['Music', 'music'], ['Photos', 'photos'],
  ['Books', 'books'], ['Live TV', 'live-tv'], ['Devices', 'devices'], ['Settings', 'settings'], ['Connections', 'servers']
];
// A Jellyfin id is 32 hexadecimal digits, with or without dashes. Anything else in an address is refused.
const ID = /^[0-9A-Za-z-]{1,64}$/;

/** The address of a screen. A screen with no address of its own (a download list, say) reads as Home, and a
    folder inside a library reads as the Library. */
export function routeAddress(route: LinkRoute): string {
  if (route.name === 'Details') return route.item && ID.test(route.item) ? '#/title/' + route.item : '#/';
  const page = PAGES.find(([name]) => name === route.name);
  return '#/' + (page ? page[1] : '');
}

/** The screen an address names, or undefined when the address is not one of Reel's. An address is typed or
    pasted by anyone, so only the known shapes are read and nothing in it is ever run or shown. The bare page
    is Home. */
export function addressRoute(hash: string): LinkRoute | undefined {
  if (hash === '' || hash === '#') return { name: 'Home' };
  if (!hash.startsWith('#/') || hash.length > 120) return undefined;
  const parts = hash.slice(2).split('/');
  if (parts.length === 1) {
    const page = PAGES.find(([, slug]) => slug === parts[0]);
    return page ? { name: page[0] } : undefined;
  }
  if (parts.length === 2 && parts[0] === 'title' && ID.test(parts[1])) return { name: 'Details', item: parts[1] };
  return undefined;
}

interface HistoryLike { state: unknown; pushState: (state: unknown, unused: string, url: string) => void; replaceState: (state: unknown, unused: string, url: string) => void; go: (delta: number) => void }
export type HistoryMove =
  /** Back by this many entries. The screens kept in memory may be used only when the last of them has this
      address; entries made before a reload are not in memory and are opened by address instead. */
  | { kind: 'back'; steps: number; address: string; route: LinkRoute | undefined }
  /** Forward, or an address the viewer typed: show the screen the address names. */
  | { kind: 'open'; route: LinkRoute | undefined };

/** Keeps the browser's history one entry per screen. Each entry carries its place in the visit, which the
    browser keeps through a reload, so a move can always be told apart as Back or Forward. */
export class ScreenHistory {
  private history: HistoryLike;
  private depth: number;
  private skip = 0;
  /** The place of the entry the browser has moved to, until that move is shown or undone. */
  private arriving?: number;
  private home: () => string;
  /** @param home The page's own address without a screen, which is what Home shows. */
  constructor(history: HistoryLike, home: () => string) { this.history = history; this.home = home; this.depth = ScreenHistory.place(history.state) ?? 0; }
  private static place(state: unknown): number | undefined {
    const value = (state as { reel?: unknown } | null)?.reel;
    return typeof value === 'number' && Number.isInteger(value) && value >= 0 ? value : undefined;
  }
  /** Record the screen now showing. After a move by the browser this corrects the entry it landed on;
      otherwise a new screen adds an entry and anything else corrects the current one. */
  show(route: LinkRoute, added: boolean): void {
    const link = routeAddress(route), address = link === '#/' ? this.home() : link;
    if (this.arriving !== undefined) { this.depth = this.arriving; this.arriving = undefined; added = false; }
    else if (added) this.depth++;
    if (added) this.history.pushState({ reel: this.depth }, '', address); else this.history.replaceState({ reel: this.depth }, '', address);
  }
  /** True when the browser holds an earlier entry of this visit, so its Back can be used. */
  get canGoBack(): boolean { return this.depth > 0; }
  goBack(): void { this.history.go(-1); }
  /** The browser moved. Returns what to show, or undefined for a move this class made itself. Every move
      returned must be followed by show() or undo(). */
  moved(state: unknown, hash: string): HistoryMove | undefined {
    if (this.skip > 0) { this.skip--; return undefined; }
    const place = ScreenHistory.place(state), route = addressRoute(hash);
    // A typed address makes a new entry with no place of its own: it is the next one.
    this.arriving = place ?? this.depth + 1;
    if (place !== undefined && place < this.depth) return { kind: 'back', steps: this.depth - place, address: route ? routeAddress(route) : hash, route };
    return { kind: 'open', route };
  }
  /** A sheet, a dialog or the player was open, so the move is undone and the screen stays where it was. */
  undo(): void {
    if (this.arriving === undefined) return;
    const delta = this.depth - this.arriving; this.arriving = undefined;
    if (delta === 0) return;
    this.skip++; this.history.go(delta);
  }
}
