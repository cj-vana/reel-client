import test from 'node:test';
import assert from 'node:assert/strict';
import { type BrowsePreferenceStore, hasBrowseAlias, LibraryBrowser, WatchedActions, durableBrowseStorage, type BrowseEntry, type BrowseProvider } from '../src/library-browser.ts';
import { LibraryPreferences } from '../src/library-preferences.ts';
import { renderLibrary, renderWatchedDialog, watchedActionLabel } from '../src/library-view.ts';
import { defaultLibraryChoices, type LibraryScope } from '../src/library-query.ts';
import type { ItemPage, MediaItem } from '../src/types.ts';

const item = (id: string, extra: Partial<MediaItem> = {}): MediaItem => ({ Id: id, Name: id, Type: 'Movie', ...extra });
const scope = (extra: Partial<LibraryScope> = {}): LibraryScope => ({ kind: 'library', category: 'All', libraryId: '', parentId: '', parentType: '', ...extra });
const entry = (extra: Partial<BrowseEntry> = {}): BrowseEntry => ({ account: { server: 'https://jellyfin.example.test/base', userId: 'viewer' }, owner: 'viewer|1', scope: scope(), query: '', title: 'The collection', ...extra });
function storage() {
  const values = new Map<string, string>(); let reads = 0, writes = 0, removes = 0;
  return { values, get reads() { return reads; }, get writes() { return writes; }, get removes() { return removes; }, failRead: false, failWrite: false, failRemove: false,
    getItem(key: string) { reads++; if (this.failRead) throw new Error('Denied'); return values.get(key) ?? null; },
    setItem(key: string, value: string) { if (this.failWrite) throw new Error('Quota'); writes++; values.set(key, value); },
    removeItem(key: string) { if (this.failRemove) throw new Error('Denied'); removes++; values.delete(key); }
  };
}
function deferred<T>() { let resolve!: (value: T) => void; let reject!: (error: unknown) => void; const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
function provider(items: MediaItem[] = [item('one')]): BrowseProvider { return { async page(path) { return { Items: path === 'Items' || path.startsWith('Playlists/') ? items : [] }; } }; }
const settle = () => new Promise<void>(resolve => setImmediate(resolve));

test('browse initial loading is published before a complete first page with a truthful unknown count', async () => {
  const browser = new LibraryBrowser(storage()), response = deferred<ItemPage>(), phases: boolean[] = [];
  browser.onChange = () => phases.push(browser.state?.loading ?? false);
  const open = browser.open(entry(), { page: path => path === 'Items' ? response.promise : Promise.resolve({ Items: [] }) });
  assert.equal(browser.state!.loading, true); assert.equal(browser.state!.page.items.length, 0);
  response.resolve({ Items: [item('one')] }); await open;
  assert.equal(browser.state!.page.total, undefined); assert.equal(browser.state!.page.items[0].Id, 'one'); assert(phases.includes(true));
  assert.match(renderLibrary(browser.state!, false, () => ''), /1 loaded/); assert.doesNotMatch(renderLibrary(browser.state!, false, () => ''), /1 matching/);
});
test('optional genre and library failure does not delay healthy content and can recover independently', async () => {
  const browser = new LibraryBrowser(storage()), options = deferred<ItemPage>(); let fail = true;
  const api: BrowseProvider = { page(path) { if (path === 'Items') return Promise.resolve({ Items: [item('healthy')] }); return fail ? options.promise : Promise.resolve({ Items: [item(path + '-choice')] }); } };
  await browser.open(entry(), api); assert.equal(browser.state!.page.items[0].Id, 'healthy'); assert.equal(browser.state!.optionsLoading, true);
  options.reject(new Error('Options unavailable')); await settle(); assert.match(browser.state!.optionsError!, /Options unavailable/);
  fail = false; await browser.loadOptions(); assert.equal(browser.state!.optionsError, undefined); assert.equal(browser.state!.genres[0].Id, 'Genres-choice');
});
test('late first page and late options cannot replace another account', async () => {
  const browser = new LibraryBrowser(storage()), old = deferred<ItemPage>();
  const pending = browser.open(entry(), { page: () => old.promise });
  await browser.open(entry({ owner: 'second|2', account: { server: 'https://jellyfin.example.test/base', userId: 'second' } }), provider([item('second')]));
  old.resolve({ Items: [item('old')] }); await pending; await settle();
  assert.equal(browser.state!.entry.owner, 'second|2'); assert.deepEqual(browser.state!.page.items.map(x => x.Id), ['second']);
  assert.deepEqual(browser.state!.genres, []);
});
test('closing the view aborts requests and prevents stale failure publication', async () => {
  const browser = new LibraryBrowser(storage()), old = deferred<ItemPage>(); const signals: AbortSignal[] = [];
  const pending = browser.open(entry(), { page(_path, _query, signal) { signals.push(signal); return old.promise; } });
  browser.close(); old.reject(new Error('Late network failure')); await pending; await settle();
  assert.equal(browser.state, undefined); assert(signals.every(signal => signal.aborted));
});
test('first page error has a real retry which replaces the empty page', async () => {
  const browser = new LibraryBrowser(storage()); let calls = 0;
  await browser.open(entry(), { async page(path) { if (path !== 'Items') return { Items: [] }; if (++calls === 1) throw new Error('503'); return { Items: [item('recovered')], TotalRecordCount: 1 }; } });
  assert.equal(browser.state!.errorKind, 'first'); assert.match(renderLibrary(browser.state!, false, () => ''), /Try again/);
  await browser.load('first'); assert.equal(browser.state!.error, undefined); assert.equal(browser.state!.page.items[0].Id, 'recovered');
});
test('refresh failure retains visible titles and retry commits changed empty and changed full responses', async () => {
  const browser = new LibraryBrowser(storage()); let response: ItemPage | Error = { Items: [item('original')], TotalRecordCount: 1 };
  await browser.open(entry(), { async page(path) { if (path !== 'Items') return { Items: [] }; if (response instanceof Error) throw response; return response; } });
  response = new Error('Refresh failed'); await browser.load('refresh');
  assert.equal(browser.state!.page.items[0].Id, 'original'); assert.equal(browser.state!.errorKind, 'refresh');
  assert.match(renderLibrary(browser.state!, false, () => ''), /Retry refresh/);
  response = { Items: [], TotalRecordCount: 0 }; await browser.load('refresh'); assert.equal(browser.state!.page.items.length, 0); assert.equal(browser.state!.page.total, 0);
  response = { Items: [item('replacement')], TotalRecordCount: 1 }; await browser.load('refresh'); assert.equal(browser.state!.page.items[0].Id, 'replacement');
});
test('append uses raw cursor, deduplicates overlap, retries failed offset and stops on empty', async () => {
  const browser = new LibraryBrowser(storage()), starts: number[] = []; let fail = true;
  await browser.open(entry(), { async page(path, query) {
    if (path !== 'Items') return { Items: [] };
    const start = Number(query.startIndex); starts.push(start);
    if (start === 0) return { Items: Array.from({ length: 60 }, (_, i) => item(String(i))) };
    if (start === 60 && fail) throw new Error('Later failed');
    if (start === 60) return { Items: Array.from({ length: 60 }, (_, i) => item(String(i + 59))) };
    return { Items: [] };
  } });
  await browser.load('append'); assert.equal(browser.state!.page.items.length, 60); assert.equal(browser.state!.page.nextIndex, 60);
  fail = false; await browser.load('append'); assert.equal(browser.state!.page.items.length, 119); assert.equal(browser.state!.page.nextIndex, 120);
  await browser.load('append'); assert.equal(browser.state!.page.hasMore, false); assert.deepEqual(starts, [0, 60, 60, 120]);
});
test('repeated append gestures cannot start two concurrent page requests', async () => {
  const browser = new LibraryBrowser(storage()), more = deferred<ItemPage>(); let starts = 0;
  await browser.open(entry(), { page(path, query) { if (path !== 'Items') return Promise.resolve({ Items: [] }); if (!query.startIndex) return Promise.resolve({ Items: Array.from({ length: 60 }, (_, i) => item(String(i))) }); starts++; return more.promise; } });
  const first = browser.load('append'); await browser.load('append'); assert.equal(starts, 1); more.resolve({ Items: [] }); await first;
});
test('view style persists without refetch and all query conjuncts reach the provider together', async () => {
  const browser = new LibraryBrowser(storage()), queries: Record<string, unknown>[] = [];
  await browser.open(entry({ scope: scope({ category: 'Episodes', libraryId: 'lib' }) }), { async page(path, query) { if (path === 'Items') queries.push(query); return { Items: path === 'UserViews' ? [item('lib')] : path === 'Genres' ? [item('genre')] : [] }; } });
  await browser.change({ view: 'list' }); assert.equal(queries.length, 1);
  await browser.change({ genreId: 'genre', watchStatus: 'Unwatched', favoritesOnly: true, sort: 'ProductionYear', direction: 'Ascending' });
  assert.deepEqual(Object.fromEntries(['genreIds', 'isPlayed', 'filters', 'includeItemTypes', 'parentId', 'sortBy', 'sortOrder'].map(key => [key, queries.at(-1)![key]])), { genreIds: 'genre', isPlayed: false, filters: 'IsFavorite', includeItemTypes: 'Episode', parentId: 'lib', sortBy: 'ProductionYear,SortName', sortOrder: 'Ascending,Ascending' });
  await browser.clearFilters(); assert.equal(browser.state!.choices.genreId, ''); assert.equal(browser.state!.choices.sort, 'ProductionYear'); assert.equal(browser.state!.choices.view, 'list');
});
test('newest episode intent retains only view and never overwrites saved filter/sort choices', async () => {
  const store = storage(), prefs = new LibraryPreferences(store), context = entry({ scope: scope({ category: 'Episodes' }) });
  prefs.update(context.account, context.scope, { genreId: 'old', watchStatus: 'Watched', sort: 'SortName', view: 'list' });
  const browser = new LibraryBrowser(store); await browser.open({ ...context, newestEpisodes: true }, provider());
  assert.deepEqual(browser.state!.choices, { ...defaultLibraryChoices(), view: 'list', sort: 'DateCreated', direction: 'Descending' });
  await browser.change({ genreId: 'temporary' }); await browser.change({ view: 'grid' });
  const saved = prefs.load(context.account, context.scope).choices; assert.equal(saved.genreId, 'old'); assert.equal(saved.watchStatus, 'Watched'); assert.equal(saved.sort, 'SortName'); assert.equal(saved.view, 'grid');
});
test('a dedicated durable adapter exposes denial rather than pretending to save in memory', async () => {
  const store = storage(); store.failWrite = true;
  const browser = new LibraryBrowser(durableBrowseStorage(() => store)); await browser.open(entry(), provider());
  await browser.change({ view: 'list' }); assert.equal(browser.state!.choices.view, 'list'); assert(browser.state!.preferences.error); assert.equal(store.values.size, 0);
  store.failWrite = false; await browser.retryPreferences(); assert.equal(browser.state!.preferences.error, undefined); assert.equal(store.values.size, 1);
  const reopened = new LibraryBrowser(durableBrowseStorage(() => store)); await reopened.open(entry(), provider()); assert.equal(reopened.state!.choices.view, 'list');
});
test('blocked localStorage getter is a visible read error and does not trigger a memory fallback', async () => {
  const browser = new LibraryBrowser(durableBrowseStorage(() => { throw new Error('SecurityError'); })); await browser.open(entry(), provider());
  assert(browser.state!.preferences.error); assert.equal(browser.state!.preferences.canReset, false);
});
test('reset failure stays visible, then a successful reset clears current choices and data is refetched', async () => {
  const store = storage(), browser = new LibraryBrowser(store); await browser.open(entry(), provider()); await browser.change({ view: 'list' });
  store.failRemove = true; await browser.resetPreferences(); assert(browser.state!.preferences.error); assert.equal(browser.state!.choices.view, 'list');
  store.failRemove = false; await browser.resetPreferences(); assert.equal(browser.state!.choices.view, 'grid'); assert.equal(store.removes, 1);
});
test('search blank issues no Items GET and an immediately invalidated query cannot publish its late result', async () => {
  const browser = new LibraryBrowser(storage()), old = deferred<ItemPage>(), terms: unknown[] = [];
  const api: BrowseProvider = { page(path, query) { if (path !== 'Items') return Promise.resolve({ Items: [] }); terms.push(query.searchTerm); return query.searchTerm === 'old' ? old.promise : Promise.resolve({ Items: [item('new')] }); } };
  await browser.open(entry({ scope: scope({ kind: 'search' }) }), api); assert.deepEqual(terms, []);
  const pending = browser.search('old'); browser.cancelPendingQuery('new'); old.resolve({ Items: [item('old')] }); await pending;
  assert.equal(browser.state!.page.items.length, 0); await browser.search('new'); assert.equal(browser.state!.page.items[0].Id, 'new');
  await browser.search(''); assert.equal(browser.state!.page.items.length, 0); assert.deepEqual(terms, ['old', 'new']);
});
test('playlist path preserves repeated entries and contains no pretend sort/search/filter controls', async () => {
  const browser = new LibraryBrowser(storage()), calls: string[] = [];
  await browser.open(entry({ scope: scope({ kind: 'container', parentId: 'playlist', parentType: 'Playlist' }) }), { async page(path) { calls.push(path); return { Items: path.startsWith('Playlists/') ? [item('same'), item('same')] : [] }; } });
  assert.equal(browser.state!.page.items.length, 2); assert(calls.includes('Playlists/playlist/Items'));
  const html = renderLibrary(browser.state!, false, () => ''); assert.doesNotMatch(html, /id="sort"|id="search"|id="browse-genre"/); assert.match(html, /Playlist order/);
});
test('retired option IDs remain explicit and no missing dates or unknown watched count is invented', async () => {
  const store = storage(), prefs = new LibraryPreferences(store), context = entry({ scope: scope({ category: 'Series', libraryId: 'gone' }) });
  prefs.update(context.account, context.scope, { genreId: 'goneGenre', sort: 'DateLastContentAdded' });
  const browser = new LibraryBrowser(store); await browser.open(context, provider([item('series', { Type: 'Series', DateLastMediaAdded: null, UserData: { Played: true } })]));
  const html = renderLibrary(browser.state!, false, () => ''); assert.match(html, /Saved library unavailable/); assert.match(html, /Saved genre unavailable/); assert.equal(browser.state!.filtersValidated, false); assert.match(html, /saved library is no longer available/);
});
test('all metadata, option names, confirmation names and retained errors are escaped', async () => {
  const browser = new LibraryBrowser(storage()), unsafe = '<img src=x onerror=alert(1)>';
  await browser.open(entry({ title: unsafe, query: '\" onfocus=alert(1)' }), provider([item('unsafe', { Name: unsafe, Type: 'Episode', ParentIndexNumber: 0, IndexNumber: 0 })]));
  const html = renderLibrary(browser.state!, false, () => ''); assert.doesNotMatch(html, /<img src=x|value="" onfocus/); assert.match(html, /S0 E0/);
  const actions = new WatchedActions(); actions.prepare([item('x', { Name: unsafe })], true, { owner: '1', current: () => '1', protected: false, write: async () => undefined });
  assert.doesNotMatch(renderWatchedDialog(actions), /<img src=x/);
});
test('protected selection controls are disabled and protected mutation preparation refuses without writes', async () => {
  const browser = new LibraryBrowser(storage()); await browser.open(entry(), provider()); const html = renderLibrary(browser.state!, true, () => '');
  assert.match(html, /data-action="browse-selection" disabled/);
  const actions = new WatchedActions(); let writes = 0;
  assert.throws(() => actions.prepare([item('one')], true, { owner: '1', current: () => '1', protected: true, write: async () => { writes++; } }), /Protected/);
  assert.equal(writes, 0); assert.equal(actions.plan, undefined);
});
test('Cancel of captured container and duplicate bulk plans sends no writes', () => {
  const actions = new WatchedActions(); let writes = 0; const original = item('one', { Type: 'Series' });
  actions.prepare([original, item('one'), item('two')], true, { owner: '1', current: () => '1', protected: false, write: async () => { writes++; } });
  original.Name = 'Changed'; assert.equal(actions.plan!.items[0].Name, 'one'); assert.equal(actions.plan!.items.length, 2);
  actions.cancel(); assert.equal(writes, 0); assert.equal(actions.plan, undefined);
});
test('partial watched failure reports exact successes, and retry includes only failed captured IDs', async () => {
  const actions = new WatchedActions(), written: string[] = []; let fail = true;
  actions.prepare([item('a'), item('b'), item('c')], false, { owner: '1', current: () => '1', protected: false, async write(item, value) { assert.equal(value, false); written.push(item.Id); if (item.Id === 'b' && fail) throw new Error('403'); } });
  await actions.confirm(); assert.deepEqual(actions.result!.succeeded.map(x => x.Id), ['a', 'c']); assert.equal(actions.result!.failed[0].error, '403');
  actions.retry(); assert.deepEqual(actions.plan!.items.map(x => x.Id), ['b']); fail = false; await actions.confirm(); assert.deepEqual(written, ['a', 'b', 'c', 'b']);
});
test('account or route generation changes stop remaining bulk writes and reject stale confirmation', async () => {
  for (const next of ['new-account', 'new-route']) {
    let owner = 'initial'; const first = deferred<void>(), written: string[] = [], actions = new WatchedActions();
    actions.prepare([item('a'), item('b')], true, { owner, current: () => owner, protected: false, async write(item) { written.push(item.Id); await first.promise; } });
    const update = actions.confirm(); owner = next; first.resolve(); const result = await update;
    assert.deepEqual(written, ['a']); assert.equal(result!.cancelled, true); assert.equal(actions.result, undefined);
    await actions.confirm(); assert.deepEqual(written, ['a']); actions.cancel();
  }
});
test('cancelling an in-flight update aborts its request, does not queue another, and admits uncertainty', async () => {
  const first = deferred<void>(), actions = new WatchedActions(); let signal: AbortSignal | undefined, writes = 0;
  actions.prepare([item('a'), item('b')], true, { owner: '1', current: () => '1', protected: false, async write(_item, _value, incoming) { signal = incoming; writes++; await first.promise; } });
  const work = actions.confirm(); actions.cancel(); first.reject(new Error('Aborted')); const result = await work;
  assert.equal(signal!.aborted, true); assert.equal(writes, 1); assert.equal(result!.uncertain, true); assert.equal(actions.result, undefined);
});
test('the same confirmation cannot be sent twice while its first request is still pending', async () => {
  const first = deferred<void>(), actions = new WatchedActions(); let writes = 0;
  actions.prepare([item('a')], true, { owner: '1', current: () => '1', protected: false, async write() { writes++; await first.promise; } });
  const work = actions.confirm(); await actions.confirm(); assert.equal(writes, 1); first.resolve(); await work;
});

test('Retry after a denied read restores the durable choices and refetches their query', async () => {
  const store = storage(), context = entry(), preferences = new LibraryPreferences(store);
  preferences.update(context.account, context.scope, { sort: 'DateCreated', direction: 'Descending', genreId: 'saved' });
  store.failRead = true; const browser = new LibraryBrowser(store); const sorts: unknown[] = [];
  await browser.open(context, { async page(path, query) { if (path === 'Items') sorts.push(query.sortBy); return { Items: path === 'Genres' ? [item('saved')] : [] }; } });
  assert.equal(browser.state!.choices.sort, 'SortName'); store.failRead = false; await browser.retryPreferences();
  assert.equal(browser.state!.choices.sort, 'DateCreated'); assert.equal(browser.state!.choices.genreId, 'saved'); assert.deepEqual(sorts, ['SortName', 'DateCreated,SortName']);
});

test('Back restores a loaded tail and its raw cursor without another Items GET, but another session refetches', async () => {
  const browser = new LibraryBrowser(storage()); let calls = 0;
  const api: BrowseProvider = { async page(path, query) { if (path !== 'Items') return { Items: [] }; calls++; return { Items: Array.from({ length: 60 }, (_, i) => item(String(Number(query.startIndex) + i))), TotalRecordCount: 180 }; } };
  await browser.open(entry({ session: 'revision1' }), api); await browser.load('append'); browser.close();
  await browser.open(entry({ owner: 'viewer|different-route', session: 'revision1', restore: true }), api);
  assert.equal(calls, 2); assert.equal(browser.state!.page.items.length, 120); assert.equal(browser.state!.page.nextIndex, 120);
  browser.close(); await browser.open(entry({ session: 'revision2', restore: true }), api); assert.equal(calls, 3); assert.equal(browser.state!.page.items.length, 60);
});
test('changed durable choices invalidate a cached Back page and account cleanup clears history', async () => {
  const store = storage(), browser = new LibraryBrowser(store), context = entry({ session: 'same' }); let calls = 0;
  const api: BrowseProvider = { async page(path) { if (path === 'Items') calls++; return { Items: path === 'Items' ? [item('one')] : path === 'Genres' ? [item('changed')] : [] }; } };
  await browser.open(context, api); browser.close(); browser.preferences.update(context.account, context.scope, { genreId: 'changed' });
  await browser.open({ ...context, restore: true }, api); assert.equal(calls, 2); browser.close(); browser.clearHistory();
  await browser.open({ ...context, restore: true }, api); assert.equal(calls, 3);
});
test('a genre picked on a restored view before its choices arrive loads once they validate', async () => {
  const browser = new LibraryBrowser(storage()), context = entry({ session: 'same' }), loads: unknown[] = []; let genres = deferred<ItemPage>();
  const api: BrowseProvider = { page(path, query) {
    if (path === 'Genres') return genres.promise;
    if (path === 'Items') { loads.push(query.genreIds); return Promise.resolve({ Items: query.genreIds ? [item('adventure-only')] : [item('one'), item('two')] }); }
    return Promise.resolve({ Items: [] });
  } };
  const first = browser.open(context, api); genres.resolve({ Items: [item('adventure')] }); await first; await settle(); browser.close();
  genres = deferred<ItemPage>(); await browser.open({ ...context, restore: true }, api);
  assert.equal(browser.state!.optionsLoading, true); assert.deepEqual(browser.state!.page.items.map(x => x.Id), ['one', 'two']);
  const change = browser.change({ genreId: 'adventure' });
  assert.equal(browser.state!.validationError, undefined);
  genres.resolve({ Items: [item('adventure')] }); await change; await settle(); await settle();
  assert.deepEqual(loads, [undefined, 'adventure']); assert.deepEqual(browser.state!.page.items.map(x => x.Id), ['adventure-only']);
});
test('leaving a restored view while a picked genre waits for its choices never caches the old titles for Back', async () => {
  const browser = new LibraryBrowser(storage()), context = entry({ session: 'same' }), loads: unknown[] = []; let genres = deferred<ItemPage>();
  const api: BrowseProvider = { page(path, query) {
    if (path === 'Genres') return genres.promise;
    if (path === 'Items') { loads.push(query.genreIds); return Promise.resolve({ Items: query.genreIds ? [item('adventure-only')] : [item('one'), item('two')] }); }
    return Promise.resolve({ Items: [] });
  } };
  const first = browser.open(context, api); genres.resolve({ Items: [item('adventure')] }); await first; await settle(); browser.close();
  genres = deferred<ItemPage>(); await browser.open({ ...context, restore: true }, api);
  const change = browser.change({ genreId: 'adventure' }); await change; browser.close();
  genres = deferred<ItemPage>(); const reopen = browser.open({ ...context, restore: true }, api);
  genres.resolve({ Items: [item('adventure')] }); await reopen; await settle();
  assert.deepEqual(loads, [undefined, 'adventure']); assert.deepEqual(browser.state!.page.items.map(x => x.Id), ['adventure-only']);
});

test('accepted mutations invalidate only their account Back cache and force a fresh filtered page', async () => {
  const browser = new LibraryBrowser(storage()); let played = false, calls = 0;
  const api: BrowseProvider = { async page(path) { if (path !== 'Items') return { Items: [] }; calls++; return { Items: played ? [] : [item('unwatched')], TotalRecordCount: played ? 0 : 1 }; } };
  const a = entry({ session: 'a' }), b = entry({ session: 'b', owner: 'b', account: { ...entry().account, userId: 'b' } });
  await browser.open(a, api); browser.close(); await browser.open(b, api); browser.close();
  played = true; browser.invalidateAccount(a.account);
  await browser.open({ ...b, restore: true }, api); assert.equal(calls, 2); assert.equal(browser.state!.page.items.length, 1);
  browser.close(); await browser.open({ ...a, restore: true }, api); assert.equal(calls, 3); assert.equal(browser.state!.page.items.length, 0);
});
test('accepted bulk effects survive repeated failed-only retry and notify the captured account once per accepted write', async () => {
  const actions = new WatchedActions(), accepted: string[] = [];
  actions.prepare([item('a'), item('b')], true, { owner: '1', current: () => '1', protected: false, async write(item) { if (item.Id === 'b') throw new Error('403'); }, onAccepted: item => accepted.push(item.Id) });
  await actions.confirm(); assert.deepEqual(actions.acceptedItems.map(item => item.Id), ['a']);
  actions.retry(); await actions.confirm(); assert.equal(actions.result!.succeeded.length, 0); assert.equal(actions.result!.failed.length, 1);
  assert.deepEqual(actions.acceptedItems.map(item => item.Id), ['a']); assert.deepEqual(accepted, ['a']);
});
test('old accepted response invalidates its own context without contaminating a replacement plan effects', async () => {
  const actions = new WatchedActions(), old = deferred<void>(), callbacks: string[] = [];
  actions.prepare([item('a')], true, { owner: '1', current: () => '1', protected: false, write: () => old.promise, onAccepted: () => callbacks.push('old') });
  const work = actions.confirm(); actions.cancel(); actions.prepare([item('new')], true, { owner: '2', current: () => '2', protected: false, write: async () => undefined, onAccepted: () => callbacks.push('new') });
  old.resolve(); await work; assert.deepEqual(actions.acceptedItems, []); assert.deepEqual(callbacks, ['old']); assert.equal(actions.plan!.items[0].Id, 'new');
});
test('Clear on the destination scope retains its sort/view but excludes every saved predicate before the first request', async () => {
  const store = storage(), prefs = new LibraryPreferences(store), context = entry(), queries: Record<string, unknown>[] = [];
  prefs.update(context.account, context.scope, { genreId: 'oldAll', watchStatus: 'Watched', favoritesOnly: true, sort: 'DateCreated', view: 'list' });
  const browser = new LibraryBrowser(store); await browser.open({ ...context, clearFilters: true }, { async page(path, query) { if (path === 'Items') queries.push(query); return { Items: path === 'UserViews' ? [item('lib')] : path === 'Genres' ? [item('genre')] : [] }; } });
  assert.equal(queries.length, 1); assert.equal(queries[0].genreIds, undefined); assert.equal(queries[0].isPlayed, undefined); assert.equal(queries[0].filters, undefined); assert.equal(queries[0].parentId, undefined);
  assert.equal(browser.state!.choices.sort, 'DateCreated'); assert.equal(browser.state!.choices.view, 'list'); assert.equal(prefs.load(context.account, context.scope).choices.genreId, '');
});

test('saved library and genre await positive metadata validation before any Items request', async () => {
  const store = storage(), prefs = new LibraryPreferences(store), context = entry({ scope: scope({ libraryId: 'lib' }) });
  prefs.update(context.account, context.scope, { genreId: 'genre' });
  const browser = new LibraryBrowser(store), views = deferred<ItemPage>(), genres = deferred<ItemPage>(), calls: string[] = [];
  const pending = browser.open(context, { page(path) { calls.push(path); return path === 'UserViews' ? views.promise : path === 'Genres' ? genres.promise : Promise.resolve({ Items: [item('validated')] }); } });
  assert.deepEqual(calls, ['UserViews']); assert.equal(browser.state!.filtersValidated, false);
  views.resolve({ Items: [item('lib')] }); await settle(); assert.deepEqual(calls, ['UserViews', 'Genres']);
  genres.resolve({ Items: [item('genre')] }); await pending; assert.deepEqual(calls, ['UserViews', 'Genres', 'Items']); assert.equal(browser.state!.page.items[0].Id, 'validated');
});
test('failed option validation blocks saved predicates until real Retry succeeds', async () => {
  const store = storage(), context = entry(), prefs = new LibraryPreferences(store); prefs.update(context.account, context.scope, { genreId: 'genre' });
  const browser = new LibraryBrowser(store); let fail = true, reads = 0;
  await browser.open(context, { async page(path) { if (path === 'Genres' && fail) throw new Error('503'); if (path === 'Items') reads++; return { Items: path === 'Genres' ? [item('genre')] : [] }; } });
  assert.equal(reads, 0); assert.equal(browser.state!.filtersValidated, false); assert.match(browser.state!.validationError!, /could not be validated/);
  fail = false; await browser.retryOptions(); assert.equal(reads, 1); assert.equal(browser.state!.filtersValidated, true);
});
test('retired saved library blocks Items and its child Genres until an explicit safe scope is selected', async () => {
  const browser = new LibraryBrowser(storage()), calls: Array<{ path: string; parent: unknown }> = [];
  const api: BrowseProvider = { async page(path, query) { calls.push({ path, parent: query.parentId }); return { Items: [] }; } };
  await browser.open(entry({ scope: scope({ libraryId: 'retired' }) }), api); assert.deepEqual(calls.map(call => call.path), ['UserViews']); assert.equal(browser.state!.filtersValidated, false);
  await browser.open(entry({ clearFilters: true }), api); assert.equal(calls.filter(call => call.path === 'Items').length, 1); assert.equal(calls.find(call => call.path === 'Items')!.parent, undefined);
});
test('retired genre issues zero stale-predicate Items GET, and Clear commits a safe query', async () => {
  const store = storage(), context = entry(), prefs = new LibraryPreferences(store); prefs.update(context.account, context.scope, { genreId: 'retired' });
  const browser = new LibraryBrowser(store), queries: Record<string, unknown>[] = [];
  await browser.open(context, { async page(path, query) { if (path === 'Items') queries.push(query); return { Items: [] }; } });
  assert.equal(queries.length, 0); assert.match(browser.state!.validationError!, /no longer available/);
  await browser.clearFilters(); assert.equal(queries.length, 1); assert.equal(queries[0].genreIds, undefined);
});

test('async preference commit keeps Saving visible and cannot publish a later failure into another account', async () => {
  const baseline = new LibraryPreferences(storage()), committed = deferred<void>(); let fail = false;
  const preferences: BrowsePreferenceStore = { load: (account, scope) => baseline.load(account, scope), async update(account, scope, patch) { await committed.promise; if (fail) throw new Error('Disk denied'); baseline.update(account, scope, patch); }, retry: (a, s) => baseline.retry(a, s), reset: a => baseline.reset(a), removeAccount: a => baseline.removeAccount(a) };
  const browser = new LibraryBrowser(storage(), preferences); await browser.open(entry(), provider());
  const work = browser.change({ view: 'list' }); assert.equal(browser.state!.choices.view, 'list'); assert.equal(browser.state!.preferencesSaving, true);
  await browser.open(entry({ owner: 'second', account: { ...entry().account, userId: 'second' } }), provider([item('second')]));
  fail = true; committed.resolve(); await work; assert.equal(browser.state!.entry.owner, 'second'); assert.equal(browser.state!.preferencesSaving, undefined); assert.equal(browser.state!.page.items[0].Id, 'second');
});
test('a delayed async preferences read is fenced before any old-account Items request', async () => {
  const stored = new LibraryPreferences(storage()), old = deferred<ReturnType<LibraryPreferences['load']>>();
  const preferences: BrowsePreferenceStore = { load: (account, scope) => account.userId === 'viewer' ? old.promise : stored.load(account, scope), update: (a, s, p) => stored.update(a, s, p), retry: (a, s) => stored.retry(a, s), reset: a => stored.reset(a), removeAccount: a => stored.removeAccount(a) };
  const browser = new LibraryBrowser(storage(), preferences); let oldReads = 0;
  const pending = browser.open(entry(), { async page() { oldReads++; return { Items: [] }; } });
  await browser.open(entry({ owner: 'new', account: { ...entry().account, userId: 'new' } }), provider([item('new')]));
  old.resolve(stored.load(entry().account, entry().scope)); await pending; assert.equal(oldReads, 0); assert.equal(browser.state!.entry.owner, 'new');
});
test('session-only retention is explicitly rendered and cannot be mistaken for device durability', async () => {
  const stored = new LibraryPreferences(storage());
  const preferences: BrowsePreferenceStore = { load: async (a, s) => ({ ...stored.load(a, s), retention: 'session' }), update: (a, s, p) => stored.update(a, s, p), retry: async (a, s) => ({ ...stored.retry(a, s), retention: 'session' }), reset: a => stored.reset(a), removeAccount: a => stored.removeAccount(a) };
  const browser = new LibraryBrowser(storage(), preferences); await browser.open(entry(), provider());
  assert.match(renderLibrary(browser.state!, false, () => ''), /This connection is not remembered, so browse choices last until you close Reel/);
});

test('removing one normalized connection alias preserves shared browse preferences until the last alias', () => {
  const account = { server: 'https://MEDIA.example.test/base/', userId: 'same' };
  assert.equal(hasBrowseAlias(account, [{ server: 'https://media.example.test/base', userId: 'same' }]), true);
  assert.equal(hasBrowseAlias(account, [{ server: 'https://media.example.test/other', userId: 'same' }]), false);
  assert.equal(hasBrowseAlias(account, [{ server: 'https://media.example.test/base', userId: 'other' }]), false);
  assert.equal(hasBrowseAlias(account, []), false);
  assert.equal(hasBrowseAlias(account, [{ server: 'malformed', userId: 'same' }]), true);
});

test('a delayed accepted Details write reconciles the visible filtered page after Back', async () => {
  const browser = new LibraryBrowser(storage()); let favorite = true, reads = 0;
  const api: BrowseProvider = { async page(path) { if (path !== 'Items') return { Items: [] }; reads++; return { Items: favorite ? [item('removed-favorite')] : [], TotalRecordCount: favorite ? 1 : 0 }; } };
  const context = entry({ session: 'same' }); await browser.open(context, api); browser.close();
  await browser.open({ ...context, restore: true }, api); assert.equal(reads, 1);
  favorite = false; browser.invalidateAccount(context.account); await settle();
  assert.equal(reads, 2); assert.deepEqual(browser.state!.page.items, []); assert.equal(browser.state!.page.total, 0);
  assert.equal(browser.state!.dirty, false); assert.equal(browser.state!.refreshing, false);
});
test('accepted mutation during a held first load replaces its cancelled request and rejects old data', async () => {
  const browser = new LibraryBrowser(storage()), old = deferred<ItemPage>(); let reads = 0, oldSignal: AbortSignal | undefined;
  const context = entry(); const opening = browser.open(context, { page(path, _query, signal) { if (path !== 'Items') return Promise.resolve({ Items: [] }); reads++; if (reads === 1) { oldSignal = signal; return old.promise; } return Promise.resolve({ Items: [item('current-after-write')], TotalRecordCount: 1 }); } });
  assert.equal(browser.state!.loading, true); browser.invalidateAccount(context.account); await settle();
  assert.equal(reads, 2); assert.equal(oldSignal!.aborted, true); assert.equal(browser.state!.loading, false);
  assert.equal(browser.state!.page.items[0].Id, 'current-after-write');
  old.resolve({ Items: [item('stale-before-write')] }); await opening;
  assert.equal(browser.state!.page.items[0].Id, 'current-after-write');
});
test('old-account mutation cannot refresh another account and visible reconciliation failure has real Retry', async () => {
  const browser = new LibraryBrowser(storage()), oldAccount = entry().account; let reads = 0, fail = false;
  const current = entry({ owner: 'b', account: { ...oldAccount, userId: 'b' } });
  const api: BrowseProvider = { async page(path) { if (path !== 'Items') return { Items: [] }; reads++; if (fail) throw new Error('Readback denied'); return { Items: [item('b')], TotalRecordCount: 1 }; } };
  await browser.open(current, api); browser.invalidateAccount(oldAccount); await settle(); assert.equal(reads, 1);
  fail = true; browser.invalidateAccount(current.account); await settle(); assert.equal(reads, 2);
  assert.equal(browser.state!.page.items[0].Id, 'b'); assert.equal(browser.state!.errorKind, 'refresh'); assert.equal(browser.state!.refreshing, false);
  assert.match(renderLibrary(browser.state!, false, () => ''), /Retry refresh/);
  fail = false; await browser.load('refresh'); assert.equal(reads, 3); assert.equal(browser.state!.error, undefined);
});
test('retired or failed cached filter validation never exposes hidden rows to a watched plan', async () => {
  for (const mode of ['retired-library', 'retired-genre', 'error', 'held'] as const) {
    const store = storage(), preferences = new LibraryPreferences(store), context = entry({ session: mode, scope: scope({ libraryId: 'lib' }) });
    preferences.update(context.account, context.scope, { genreId: 'genre' });
    const browser = new LibraryBrowser(store); let validation = false; const hold = deferred<ItemPage>();
    const api: BrowseProvider = { async page(path) {
      if (path === 'Items') return { Items: [item('hidden')] };
      if (validation && mode === 'held') return hold.promise;
      if (validation && mode === 'error') throw new Error('503');
      return { Items: path === 'UserViews' ? validation && mode === 'retired-library' ? [] : [item('lib')] : validation && mode === 'retired-genre' ? [] : [item('genre')] };
    } };
    await browser.open(context, api); browser.close(); validation = true;
    const opening = browser.open({ ...context, restore: true }, api); await settle();
    assert.equal(browser.state!.page.items.length, 1); assert.equal(browser.state!.filtersValidated, false);
    browser.toggleSelection(); browser.toggleSelection('hidden'); browser.selectLoaded();
    assert.equal(browser.state!.selecting, false); assert.equal(browser.state!.selected.size, 0); assert.deepEqual(browser.selectedItems(), []);
    assert.doesNotMatch(renderLibrary(browser.state!, false, () => ''), /data-action="browse-selection"|data-action="browse-selected-watched"/);
    if (mode === 'held') hold.resolve({ Items: [] }); await opening;
    assert.equal(browser.state!.filtersValidated, false); assert.deepEqual(browser.selectedItems(), []);
  }
});
test('losing validation clears an active selection while valid retained refresh-error rows remain selectable', async () => {
  const store = storage(), context = entry(), prefs = new LibraryPreferences(store); prefs.update(context.account, context.scope, { genreId: 'genre' });
  const browser = new LibraryBrowser(store); let missing = false, fail = false;
  await browser.open(context, { async page(path) { if (path === 'Items') { if (fail) throw new Error('503'); return { Items: [item('safe'), item('unknown', { Type: undefined, UserData: { Played: true } })] }; } return { Items: path === 'Genres' && !missing ? [item('genre')] : [] }; } });
  browser.toggleSelection(); browser.selectLoaded(); assert.deepEqual(browser.selectedItems().map(value => value.Id), ['safe']);
  fail = true; await browser.load('refresh'); assert.equal(browser.state!.filtersValidated, true); browser.selectLoaded(); assert.equal(browser.selectedItems().length, 1);
  missing = true; await browser.loadOptions(); assert.equal(browser.state!.filtersValidated, false); assert.equal(browser.state!.selected.size, 0); assert.equal(browser.state!.selecting, false);
});
test('a failed Reset reloads current capability and cannot publish across an account change', async () => {
  const baseline = new LibraryPreferences(storage()); let resettable = true, held: ReturnType<typeof deferred<void>> | undefined;
  const preferences: BrowsePreferenceStore = { load: (a, s) => ({ ...baseline.load(a, s), canReset: resettable }), update: (a, s, p) => baseline.update(a, s, p), retry: (a, s) => baseline.retry(a, s), removeAccount: a => baseline.removeAccount(a), async reset() { if (held) await held.promise; resettable = false; throw new Error('Reset could not be confirmed'); } };
  const browser = new LibraryBrowser(storage(), preferences); await browser.open(entry(), provider());
  assert.equal(browser.state!.preferences.canReset, true); await browser.resetPreferences(); assert.equal(browser.state!.preferences.canReset, false);
  assert.match(browser.state!.preferences.error!.message, /could not be confirmed/); assert.doesNotMatch(renderLibrary(browser.state!, false, () => ''), /data-action="browse-reset"/);
  resettable = true; held = deferred<void>(); const reset = browser.resetPreferences();
  await browser.open(entry({ owner: 'b', account: { ...entry().account, userId: 'b' } }), provider([item('b')])); held.resolve(); await reset;
  assert.equal(browser.state!.entry.owner, 'b'); assert.equal(browser.state!.preferences.error, undefined); assert.equal(browser.state!.page.items[0].Id, 'b');
});
test('music and photo containers warn about descendants and linked users while unknown metadata cannot be selected', async () => {
  const browser = new LibraryBrowser(storage()); await browser.open(entry(), provider([item('album', { Type: 'MusicAlbum', UserData: { Played: true, UnplayedItemCount: 0 } }), item('artist', { Type: 'MusicArtist' }), item('photos', { Type: 'PhotoAlbum' }), item('unknown', { Type: undefined, UserData: { Played: false } })]));
  browser.toggleSelection(); browser.selectLoaded(); assert.deepEqual(browser.selectedItems().map(value => value.Id), ['album', 'artist', 'photos']);
  const actions = new WatchedActions(); let writes = 0;
  actions.prepare(browser.selectedItems(), true, { owner: '1', current: () => '1', protected: false, async write() { writes++; } });
  const html = renderWatchedDialog(actions); assert.match(html, /titles inside them/); assert.match(html, /users linked to this server session/);
  actions.cancel(); assert.equal(writes, 0); assert.throws(() => actions.prepare([item('missing', { Type: undefined, UserData: { Played: true } })], true, { owner: '1', current: () => '1', protected: false, async write() { writes++; } }), /unsupported|metadata/i);
});

test('watched labels name a season or series scope and stay plain for one title or a selection', () => {
  assert.equal(watchedActionLabel([item('movie')], true), 'Mark as watched');
  assert.equal(watchedActionLabel([item('episode', { Type: 'Episode' })], false), 'Mark as unwatched');
  assert.equal(watchedActionLabel([item('season', { Type: 'Season' })], true), 'Mark season as watched');
  assert.equal(watchedActionLabel([item('season', { Type: 'Season' })], false), 'Mark season as unwatched');
  assert.equal(watchedActionLabel([item('series', { Type: 'Series' })], true), 'Mark series as watched');
  assert.equal(watchedActionLabel([item('season', { Type: 'Season' }), item('series', { Type: 'Series' })], true), 'Mark as watched');
});

test('normalized API mutation identity reconciles a raw saved URL alias without invalidating another base path', async () => {
  const browser = new LibraryBrowser(storage()); let reads = 0;
  const context = entry({ account: { server: 'https://JELLYFIN.example.test:443/base', userId: 'viewer' } });
  await browser.open(context, { async page(path) { if (path === 'Items') reads++; return { Items: path === 'Items' ? [item(String(reads))] : [] }; } });
  browser.invalidateAccount({ server: 'https://jellyfin.example.test/other', userId: 'viewer' }); await settle(); assert.equal(reads, 1);
  browser.invalidateAccount({ server: 'https://jellyfin.example.test/base', userId: 'viewer' }); await settle(); assert.equal(reads, 2); assert.equal(browser.state!.page.items[0].Id, '2');
});

test('a refreshed unsupported type clears its previously valid selection and disables its checkbox', async () => {
  const browser = new LibraryBrowser(storage()); let row = item('changed', { UserData: { Played: false } });
  await browser.open(entry(), { async page(path) { return { Items: path === 'Items' ? [row] : [] }; } });
  browser.toggleSelection(); browser.selectLoaded(); assert.equal(browser.state!.selected.size, 1);
  row = { ...row, Type: undefined }; await browser.load('refresh');
  assert.equal(browser.state!.selected.size, 0); assert.deepEqual(browser.selectedItems(), []);
  assert.match(renderLibrary(browser.state!, false, () => ''), /aria-label="Select changed" disabled/);
});


test('Back after an unsubmitted Search draft refetches its own query instead of caching the previous page', async () => {
  const browser = new LibraryBrowser(storage()), terms: unknown[] = [];
  const context = entry({ scope: scope({ kind: 'search' }), session: 'same', query: 'old' });
  const api: BrowseProvider = { async page(path, query) {
    if (path !== 'Items') return { Items: [] };
    terms.push(query.searchTerm); return { Items: [item(String(query.searchTerm))], TotalRecordCount: 1 };
  } };
  await browser.open(context, api); assert.equal(browser.state!.page.items[0].Id, 'old');
  browser.cancelPendingQuery('new'); browser.close();
  await browser.open({ ...context, owner: 'returned', query: 'new', restore: true }, api);
  assert.deepEqual(terms, ['old', 'new']); assert.equal(browser.state!.page.items[0].Id, 'new');
  assert.equal(browser.state!.entry.query, 'new'); assert.equal(browser.state!.dirty, false);
});

test('Back after a pending Search Clear cannot restore old rows or send a blank Items request', async () => {
  const browser = new LibraryBrowser(storage()), terms: unknown[] = [];
  const context = entry({ scope: scope({ kind: 'search' }), session: 'same', query: 'old' });
  const api: BrowseProvider = { async page(path, query) {
    if (path !== 'Items') return { Items: [] };
    terms.push(query.searchTerm); return { Items: [item('old')], TotalRecordCount: 1 };
  } };
  await browser.open(context, api); browser.cancelPendingQuery(''); browser.close();
  await browser.open({ ...context, owner: 'returned', query: '', restore: true }, api);
  assert.deepEqual(terms, ['old']); assert.equal(browser.state!.page.items.length, 0);
});
