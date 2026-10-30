import { normalizeServer } from './api.ts';
import { LibraryPreferenceError, LibraryPreferences, type LibraryPreferenceSnapshot } from './library-preferences.ts';
import { defaultLibraryChoices, librarySorts, supportsWatchedMutation, defaultSortDirection, libraryRequest, LibraryPagination, newestEpisodeChoices, playlistScope, watchedPlan, type LibraryChoices, type LibraryScope, type WatchedPlan } from './library-query.ts';
import type { ItemPage, MediaItem } from './types.ts';
import type { StorageLike } from './storage.ts';

export interface BrowsePreferenceSnapshot extends LibraryPreferenceSnapshot { retention?: 'device' | 'session'; previousPending?: boolean; canRetry?: boolean }
type MaybePromise<T> = T | Promise<T>;
export interface BrowsePreferenceStore {
  load(account: BrowseAccount, scope: LibraryScope): MaybePromise<BrowsePreferenceSnapshot>;
  update(account: BrowseAccount, scope: LibraryScope, patch: Partial<LibraryChoices>): MaybePromise<void>;
  retry(account: BrowseAccount, scope: LibraryScope): MaybePromise<BrowsePreferenceSnapshot>;
  reset(account: BrowseAccount): MaybePromise<void>;
  removeAccount(account: BrowseAccount): MaybePromise<void>;
  drain?(): Promise<void>;
}
const isPromise = <T>(value: MaybePromise<T>): value is Promise<T> => !!value && typeof (value as Promise<T>).then === 'function';
export interface BrowseAccount { server: string; userId: string }
/** Shared preference ownership follows normalized account identity, not one connection alias ID. */
export function hasBrowseAlias(account: BrowseAccount, remaining: readonly BrowseAccount[]): boolean {
  try { const server = normalizeServer(account.server); return remaining.some(value => value.userId === account.userId && normalizeServer(value.server) === server); }
  catch { return true; } // Unknown identity is preserved rather than destructively guessed.
}
export interface BrowseProvider {
  page(path: string, query: Record<string, string | number | boolean | undefined>, signal: AbortSignal): Promise<ItemPage>;
}
export interface BrowseEntry { account: BrowseAccount; owner: string; scope: LibraryScope; query: string; title: string; newestEpisodes?: boolean; session?: string; restore?: boolean; clearFilters?: boolean }
export interface BrowseSnapshot {
  entry: BrowseEntry; choices: LibraryChoices; page: LibraryPagination; loading: boolean; refreshing: boolean; appending: boolean;
  error?: string; errorKind?: 'first' | 'append' | 'refresh'; libraries: MediaItem[]; genres: MediaItem[];
  optionsLoading: boolean; optionsError?: string; librariesLoaded: boolean; genresLoaded: boolean; filtersValidated: boolean; validationError?: string; preferences: BrowsePreferenceSnapshot; preferencesSaving?: boolean; selecting: boolean; selected: Set<string>; dirty?: boolean;
  /** A choice was made while the library and genre lists were still loading; its titles load once it validates. */
  awaitingOptions?: boolean;
}
const message = (error: unknown): string => error instanceof Error ? error.message : 'This library could not be reached. Try again.';

/** Accesses only noncredential browse keys. Denied storage remains an error, never a memory-only success. */
export function durableBrowseStorage(resolve: () => StorageLike): StorageLike {
  return {
    getItem(key) { return resolve().getItem(key); },
    setItem(key, value) { resolve().setItem(key, value); },
    removeItem(key) { resolve().removeItem(key); }
  };
}

/** Owns one visible catalogue. Every async publication is fenced by the current entry and request. */
export class LibraryBrowser {
  readonly preferences: BrowsePreferenceStore;
  state?: BrowseSnapshot;
  onChange: () => void = () => undefined;
  private provider?: BrowseProvider;
  private epoch = 0;
  private request = 0;
  private preferenceRequest = 0;
  private reconcileQueued?: { state: BrowseSnapshot; epoch: number };
  private dataController?: AbortController;
  private optionsController?: AbortController;
  private readonly recent = new Map<string, BrowseSnapshot>();
  private historyKey(entry: BrowseEntry): string { return JSON.stringify([entry.account.server, entry.account.userId, entry.session ?? entry.owner, entry.scope, entry.query, !!entry.newestEpisodes]); }
  clearHistory(): void { this.recent.clear(); }
  invalidateAccount(account: BrowseAccount, reconcile = true): void {
    const owns = (entry: BrowseEntry) => { try { return normalizeServer(entry.account.server) === normalizeServer(account.server) && entry.account.userId === account.userId; } catch { return false; } };
    for (const [key, state] of this.recent) if (owns(state.entry)) this.recent.delete(key);
    if (this.state && owns(this.state.entry)) {
      const state = this.state, epoch = this.epoch;
      state.dirty = true; this.dataController?.abort(); this.request++; state.loading = false; state.refreshing = false; state.appending = false; this.publish();
      if (reconcile && (this.reconcileQueued?.state !== state || this.reconcileQueued?.epoch !== epoch)) {
        const queued = { state, epoch }; this.reconcileQueued = queued;
        void Promise.resolve().then(async () => {
          if (this.reconcileQueued === queued) this.reconcileQueued = undefined;
          if (epoch === this.epoch && state === this.state && state.dirty && state.filtersValidated) await this.load(state.page.items.length ? 'refresh' : 'first');
        });
      }
    }
  }
  constructor(storage: StorageLike, preferences?: BrowsePreferenceStore) { this.preferences = preferences ?? new LibraryPreferences(storage); }
  close(): void {
    if (this.state && !this.state.loading && !this.state.dirty) {
      this.recent.set(this.historyKey(this.state.entry), this.state);
      while (this.recent.size > 8) this.recent.delete(this.recent.keys().next().value!);
    }
    this.epoch++; this.preferenceRequest++; this.dataController?.abort(); this.optionsController?.abort();
    this.dataController = undefined; this.optionsController = undefined; this.state = undefined; this.provider = undefined;
  }
  async open(entry: BrowseEntry, provider: BrowseProvider): Promise<void> {
    this.close(); this.provider = provider; const epoch = this.epoch;
    if (entry.clearFilters) {
      try { const operation = this.preferences.update(entry.account, entry.scope, { genreId: '', watchStatus: 'Any', favoritesOnly: false }); if (isPromise(operation)) await operation; }
      catch { /* The pending patch remains visible, even when the durable write is denied. */ }
    }
    if (epoch !== this.epoch) return;
    const loaded = this.preferences.load(entry.account, entry.scope);
    const preferences = isPromise(loaded) ? await loaded : loaded;
    if (epoch !== this.epoch) return;
    let choices = entry.newestEpisodes ? newestEpisodeChoices(preferences.choices.view) : { ...preferences.choices };
    if (entry.clearFilters) choices = { ...choices, genreId: '', watchStatus: 'Any', favoritesOnly: false };
    const previous = entry.restore && !entry.clearFilters ? this.recent.get(this.historyKey(entry)) : undefined;
    const restored = previous && (entry.newestEpisodes ? previous.choices.view === preferences.choices.view : JSON.stringify(previous.choices) === JSON.stringify(choices)) ? previous : undefined;
    if (restored) choices = { ...restored.choices };
    this.state = { entry: { ...entry, account: { ...entry.account }, scope: { ...entry.scope } }, choices, preferences,
      page: new LibraryPagination(), loading: false, refreshing: false, appending: false,
      libraries: [], genres: [], librariesLoaded: false, genresLoaded: false, filtersValidated: !entry.scope.libraryId && !choices.genreId, optionsLoading: false, selecting: false, selected: new Set() };
    if (restored) {
      const page = new LibraryPagination(); Object.assign(page, restored.page, { items: [...restored.page.items] });
      Object.assign(this.state, { page, libraries: [...restored.libraries], genres: [...restored.genres], error: restored.error, errorKind: restored.errorKind });
    }
    this.onChange();
    if (!this.state.filtersValidated) {
      await this.loadOptions();
      if (epoch !== this.epoch || !this.state || !this.validateFilters()) return;
      if (!restored || this.state.dirty) await this.load(restored ? 'refresh' : 'first');
    } else { void this.loadOptions(); if (!restored || this.state.dirty) await this.load(restored ? 'refresh' : 'first'); }
  }
  private publish(): void { this.onChange(); }
  async load(kind: 'first' | 'append' | 'refresh'): Promise<void> {
    const state = this.state, provider = this.provider;
    if (!state || !provider || !state.filtersValidated || kind === 'append' && (state.loading || state.appending || state.refreshing || !state.page.hasMore)) return;
    this.dataController?.abort(); const controller = new AbortController(); this.dataController = controller;
    const epoch = this.epoch, requestID = ++this.request;
    const current = () => this.epoch === epoch && this.request === requestID && this.state === state && !controller.signal.aborted;
    const start = kind === 'append' ? state.page.nextIndex : 0;
    const spec = libraryRequest(state.entry.scope, state.choices, state.entry.query, start);
    state.error = undefined; state.errorKind = undefined;
    state.loading = kind === 'first'; state.refreshing = kind === 'refresh'; state.appending = kind === 'append';
    if (kind === 'first') { state.page = new LibraryPagination(); state.selected.clear(); }
    this.publish();
    if (!spec.canLoad) { state.loading = false; state.refreshing = false; state.appending = false; this.publish(); return; }
    try {
      const page = await provider.page(spec.path, spec.query, controller.signal);
      if (!current()) return;
      // Validate a complete replacement before committing. A failed refresh leaves the visible page intact.
      const next = kind === 'append' ? state.page : new LibraryPagination();
      next.append(page, playlistScope(state.entry.scope)); state.page = next; if (kind !== 'append') state.dirty = false;
      state.selected = new Set([...state.selected].filter(id => next.items.some(item => item.Id === id && supportsWatchedMutation(item))));
    } catch (error) {
      if (!current()) return;
      state.error = message(error); state.errorKind = kind;
    } finally {
      if (current()) { state.loading = false; state.refreshing = false; state.appending = false; this.publish(); }
    }
  }
  private validateFilters(): boolean {
    const state = this.state; if (!state) return false;
    const library = state.entry.scope.libraryId, genre = state.choices.genreId;
    state.validationError = library && (!state.librariesLoaded || !state.libraries.some(item => item.Id === library))
      ? state.librariesLoaded ? 'This saved library is no longer available. Clear filters to choose another library, or retry its choices.' : 'The saved library could not be validated. Retry filter choices or clear filters before browsing.'
      : genre && (!state.genresLoaded || !state.genres.some(item => item.Id === genre))
        ? state.genresLoaded ? 'This saved genre is no longer available. Clear filters or retry its choices.' : 'The saved genre could not be validated. Retry filter choices or clear filters before browsing.'
        : undefined;
    state.filtersValidated = !state.validationError; if (!state.filtersValidated) { state.selecting = false; state.selected.clear(); } this.publish(); return state.filtersValidated;
  }
  async retryOptions(): Promise<void> {
    const state = this.state; if (!state) return;
    const wasBlocked = !state.filtersValidated; await this.loadOptions();
    if (state !== this.state) return;
    if (this.validateFilters() && wasBlocked) await this.load('first');
  }
  async loadOptions(): Promise<void> {
    const state = this.state, provider = this.provider;
    if (!state || !provider) return;
    this.optionsController?.abort(); const controller = new AbortController(); this.optionsController = controller;
    const epoch = this.epoch; state.optionsLoading = true; state.optionsError = undefined; this.publish();
    const current = () => epoch === this.epoch && this.state === state && !controller.signal.aborted;
    const spec = libraryRequest(state.entry.scope, state.choices, state.entry.query, 0);
    const errors: string[] = [];
    const accept = (result: PromiseSettledResult<ItemPage>, kind: 'libraries' | 'genres'): boolean => {
      if (result.status === 'rejected') { errors.push(message(result.reason)); return false; }
      const page = result.value;
      if (!page || !Array.isArray(page.Items) || page.Items.some(item => !item || typeof item.Id !== 'string' || !item.Id || typeof item.Name !== 'string')) { errors.push('Jellyfin returned invalid filter options.'); return false; }
      state[kind] = [...new Map(page.Items.map(item => [item.Id, item])).values()]; return true;
    };
    const tags = () => provider.page('Genres', { includeItemTypes: spec.query.includeItemTypes, parentId: state.entry.scope.parentId || state.entry.scope.libraryId || undefined }, controller.signal);
    if (state.entry.scope.libraryId) {
      // Never query even genre metadata under a retired restored library.
      const [views] = await Promise.allSettled([provider.page('UserViews', {}, controller.signal)]);
      if (!current()) return; state.librariesLoaded = accept(views, 'libraries');
      if (state.librariesLoaded && state.libraries.some(item => item.Id === state.entry.scope.libraryId)) {
        const [genres] = await Promise.allSettled([tags()]); if (!current()) return; state.genresLoaded = accept(genres, 'genres');
      } else state.genresLoaded = false;
    } else {
      const values = await Promise.allSettled([provider.page('UserViews', {}, controller.signal), tags()]);
      if (!current()) return;
      state.librariesLoaded = accept(values[0], 'libraries'); state.genresLoaded = accept(values[1], 'genres');
    }
    state.optionsLoading = false; state.optionsError = errors.length ? errors.join(' ') : undefined;
    const reload = state.awaitingOptions; state.awaitingOptions = false;
    if (state.entry.scope.libraryId || state.choices.genreId) this.validateFilters(); else this.publish();
    if (reload && state.filtersValidated) await this.load('first');
  }
  cancelPendingQuery(query: string): void {
    if (!this.state) return;
    this.dataController?.abort(); this.request++; this.state.entry.query = query; this.state.dirty = true;
  }
  async change(patch: Partial<LibraryChoices>): Promise<void> {
    const state = this.state; if (!state) return;
    const candidate = { ...state.choices, ...patch };
    if (!librarySorts.includes(candidate.sort) || !['Ascending', 'Descending'].includes(candidate.direction)
      || typeof candidate.genreId !== 'string' || new TextEncoder().encode(candidate.genreId).byteLength > 512
      || !['Any', 'Watched', 'Unwatched'].includes(candidate.watchStatus) || typeof candidate.favoritesOnly !== 'boolean'
      || !['grid', 'list'].includes(candidate.view)) throw new Error('This browse choice is invalid.');
    const onlyView = Object.keys(patch).every(key => key === 'view');
    const next = { ...state.choices, ...patch };
    if (patch.sort && patch.direction === undefined) next.direction = defaultSortDirection(patch.sort);
    // View-only See All is an ephemeral intent; changing its filters never overwrites the saved Episodes view.
    const persisted = state.entry.newestEpisodes ? patch.view ? { view: patch.view } : {} : { ...patch, ...(patch.sort && patch.direction === undefined ? { direction: next.direction } : {}) };
    const epoch = this.epoch, operationID = ++this.preferenceRequest;
    // A restored view shows its earlier genre list while the server's list reloads. A genre picked from it waits for
    // that list instead of failing validation, and loadOptions loads its titles. Until then the visible page belongs
    // to the old choices: any load still running for them stops, and the view is dirty so Back never restores it.
    const waiting = state.optionsLoading && (!!next.genreId && !state.genresLoaded || !!state.entry.scope.libraryId && !state.librariesLoaded);
    state.choices = next; state.awaitingOptions = waiting;
    if (waiting) {
      this.dataController?.abort(); this.request++;
      Object.assign(state, { filtersValidated: false, validationError: undefined, loading: false, refreshing: false, appending: false, selecting: false, dirty: true });
      state.selected.clear();
    } else this.validateFilters();
    state.preferencesSaving = Object.keys(persisted).length > 0; this.publish();
    const commit = (async () => {
      try { if (Object.keys(persisted).length) await this.preferences.update(state.entry.account, state.entry.scope, persisted); }
      catch { /* The store snapshot retains the exact pending field patch and durable error. */ }
      if (epoch !== this.epoch || state !== this.state || operationID !== this.preferenceRequest) return;
      let snapshot: BrowsePreferenceSnapshot;
      try { snapshot = await this.preferences.load(state.entry.account, state.entry.scope); }
      catch (error) { snapshot = { ...state.preferences, error: error instanceof LibraryPreferenceError ? error : new LibraryPreferenceError(message(error)), canReset: false }; }
      if (epoch !== this.epoch || state !== this.state || operationID !== this.preferenceRequest) return;
      state.preferences = snapshot; state.preferencesSaving = false; this.publish();
    })();
    await Promise.all([commit, onlyView ? Promise.resolve() : this.load('first')]);
  }

  async search(query: string): Promise<void> { if (!this.state) return; this.state.entry.query = query; await this.load('first'); }
  async clearFilters(): Promise<void> {
    const state = this.state; if (!state) return;
    await this.change({ genreId: '', watchStatus: 'Any', favoritesOnly: false });
  }
  async retryPreferences(): Promise<void> {
    const state = this.state; if (!state || state.preferencesSaving) return;
    const epoch = this.epoch, operationID = ++this.preferenceRequest; state.preferencesSaving = true; this.publish();
    try {
      const snapshot = await this.preferences.retry(state.entry.account, state.entry.scope);
      if (epoch !== this.epoch || state !== this.state || operationID !== this.preferenceRequest) return;
      state.preferences = snapshot;
      if (!snapshot.error) {
        const next = state.entry.newestEpisodes ? { ...state.choices, view: snapshot.choices.view } : { ...snapshot.choices };
        const changed = JSON.stringify(next) !== JSON.stringify(state.choices); state.choices = next;
        if (!this.validateFilters()) await this.retryOptions();
        else if (changed) await this.load('first');
      }
    } catch (error) {
      if (epoch === this.epoch && state === this.state && operationID === this.preferenceRequest) state.preferences = { ...state.preferences, error: error instanceof LibraryPreferenceError ? error : new LibraryPreferenceError(message(error)), canReset: false };
    } finally {
      if (epoch === this.epoch && state === this.state && operationID === this.preferenceRequest) { state.preferencesSaving = false; this.publish(); }
    }
  }
  async resetPreferences(): Promise<void> {
    const state = this.state; if (!state || state.preferencesSaving) return;
    const epoch = this.epoch, operationID = ++this.preferenceRequest; state.preferencesSaving = true; this.publish();
    try {
      await this.preferences.reset(state.entry.account);
      const snapshot = await this.preferences.load(state.entry.account, state.entry.scope);
      if (epoch !== this.epoch || state !== this.state || operationID !== this.preferenceRequest) return;
      state.preferences = snapshot;
      state.choices = state.entry.newestEpisodes ? newestEpisodeChoices(state.choices.view) : defaultLibraryChoices();
      this.validateFilters(); this.publish(); if (state.filtersValidated) await this.load('first');
    } catch (error) {
      if (epoch === this.epoch && state === this.state && operationID === this.preferenceRequest) {
        let snapshot: BrowsePreferenceSnapshot;
        try { snapshot = await this.preferences.load(state.entry.account, state.entry.scope); }
        catch { snapshot = { ...state.preferences, canReset: false }; }
        if (epoch === this.epoch && state === this.state && operationID === this.preferenceRequest) state.preferences = { ...snapshot, error: error instanceof LibraryPreferenceError ? error : new LibraryPreferenceError(message(error)) };
      }
    } finally {
      if (epoch === this.epoch && state === this.state && operationID === this.preferenceRequest) { state.preferencesSaving = false; this.publish(); }
    }
  }
  toggleSelection(id?: string): void {
    const state = this.state; if (!state || !state.filtersValidated) return;
    if (id === undefined) { state.selecting = !state.selecting; if (!state.selecting) state.selected.clear(); }
    else if (state.page.items.some(item => item.Id === id && supportsWatchedMutation(item))) { if (state.selected.has(id)) state.selected.delete(id); else state.selected.add(id); }
    this.publish();
  }
  selectLoaded(): void { const state = this.state; if (!state || !state.filtersValidated) return; state.selected = new Set(state.page.items.filter(supportsWatchedMutation).map(item => item.Id)); this.publish(); }
  selectedItems(): MediaItem[] { const state = this.state; return state && state.filtersValidated ? state.page.items.filter(item => state.selected.has(item.Id) && supportsWatchedMutation(item)) : []; }
}

export interface WatchedResult { succeeded: MediaItem[]; failed: Array<{ item: MediaItem; error: string }>; cancelled: boolean; uncertain: boolean }
export interface WatchedContext {
  owner: string; protected: boolean; current: () => string;
  write: (item: MediaItem, value: boolean, signal: AbortSignal) => Promise<void>;
  onAccepted?: (item: MediaItem) => void;
}
/** Captured plan + sequential writes. Cancelling cannot undo an already accepted server write. */
export class WatchedActions {
  plan?: WatchedPlan;
  result?: WatchedResult;
  busy = false;
  private context?: WatchedContext;
  private readonly accepted = new Map<string, MediaItem>();
  get acceptedItems(): readonly MediaItem[] { return [...this.accepted.values()]; }
  private controller?: AbortController;
  private epoch = 0;
  onChange: () => void = () => undefined;
  prepare(items: readonly MediaItem[], value: boolean, context: WatchedContext): void {
    if (this.busy) throw new Error('Wait for the current watched update to finish.');
    if (context.protected) throw new Error('Protected preview blocks watched changes.');
    if (context.current() !== context.owner) return;
    const plan = watchedPlan(items, value);
    if (!plan.items.length) return;
    this.epoch++; this.accepted.clear(); this.plan = plan; this.context = context; this.result = undefined; this.onChange();
  }
  cancel(): void {
    this.epoch++; this.controller?.abort(); this.controller = undefined; this.plan = undefined; this.context = undefined; this.busy = false; this.result = undefined; this.accepted.clear(); this.onChange();
  }
  async confirm(): Promise<WatchedResult | undefined> {
    const plan = this.plan, context = this.context;
    if (!plan || !context || this.busy || context.protected || context.current() !== context.owner) return;
    const epoch = this.epoch, controller = new AbortController(); this.controller = controller; this.busy = true;
    const result: WatchedResult = { succeeded: [], failed: [], cancelled: false, uncertain: false };
    const current = () => epoch === this.epoch && !controller.signal.aborted && context.current() === context.owner;
    this.onChange();
    for (const item of plan.items) {
      if (!current()) { result.cancelled = true; break; }
      try { await context.write(item, plan.value, controller.signal); result.succeeded.push(item); if (epoch === this.epoch) this.accepted.set(item.Id, item); context.onAccepted?.(item); }
      catch (error) {
        if (!current()) { result.cancelled = true; result.uncertain = true; break; }
        result.failed.push({ item, error: message(error) });
      }
    }
    if (!current()) result.cancelled = true;
    if (current()) { this.busy = false; this.controller = undefined; this.result = result; this.onChange(); }
    return result;
  }
  retry(): void {
    if (!this.result?.failed.length || !this.plan || !this.context) return;
    this.plan = watchedPlan(this.result.failed.map(entry => entry.item), this.plan.value); this.result = undefined; this.onChange();
  }
}
