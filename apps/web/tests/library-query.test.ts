import test from 'node:test';
import assert from 'node:assert/strict';
import { watchedItemKind, isKnownLeafItem, isAggregateItem, supportsWatchedMutation, watchedUnavailableReason, serverPlayed, addedDateText, aggregateUnplayedCount, catalogueDate, defaultLibraryChoices, defaultSortDirection, effectiveLibrarySort, itemWatched, libraryCategories, libraryRequest, LibraryPagination, newestEpisodeChoices, watchedPlan, watchStatusText, type LibraryScope } from '../src/library-query.ts';
import { subtitle, type MediaItem } from '../src/types.ts';

const scope = (changes: Partial<LibraryScope> = {}): LibraryScope => ({ kind: 'library', category: 'All', libraryId: '', parentId: '', parentType: '', ...changes });
const item = (id: string, changes: Partial<MediaItem> = {}): MediaItem => ({ Id: id, Name: id, Type: 'Movie', ...changes });

test('every video category has an explicit server type and an unfiltered default', () => {
  const types = ['Movie,Series', 'Movie', 'Series', 'Episode', 'BoxSet', 'Playlist'];
  libraryCategories.forEach((category, index) => {
    const request = libraryRequest(scope({ category }), defaultLibraryChoices(), '', 0);
    assert.equal(request.path, 'Items'); assert.equal(request.query.includeItemTypes, types[index]);
    assert.equal(request.query.genreIds, undefined); assert.equal(request.query.isPlayed, undefined); assert.equal(request.query.filters, undefined);
  });
});
test('individual added date and latest content added use distinct valid server contracts', () => {
  const recent = { ...defaultLibraryChoices(), sort: 'DateCreated' as const, direction: 'Descending' as const };
  const episode = libraryRequest(scope({ category: 'Episodes' }), recent, '', 0);
  assert.equal(episode.query.sortBy, 'DateCreated,SortName'); assert.equal(episode.query.sortOrder, 'Descending,Ascending');
  const latest = { ...recent, sort: 'DateLastContentAdded' as const };
  const series = libraryRequest(scope({ category: 'Series' }), latest, '', 0);
  assert.equal(series.query.sortBy, 'DateLastContentAdded,SortName');
  assert.equal(series.query.fields, 'Overview,Genres,DateCreated,DateLastMediaAdded');
  assert.equal(effectiveLibrarySort(scope({ category: 'Movies' }), latest), 'DateCreated');
  assert.equal(defaultSortDirection('SortName'), 'Ascending'); assert.equal(defaultSortDirection('DateLastContentAdded'), 'Descending');
});
test('explicit reverse direction retains an ascending secondary title and every conjunct', () => {
  const choices = { ...defaultLibraryChoices(), sort: 'ProductionYear' as const, direction: 'Ascending' as const, genreId: 'genre|safe', watchStatus: 'Unwatched' as const, favoritesOnly: true };
  const request = libraryRequest(scope({ category: 'Episodes', libraryId: 'library/one' }), choices, '  The pilot  ', 120);
  assert.deepEqual(request.query, { startIndex: 120, limit: 60, enableTotalRecordCount: true, recursive: true,
    includeItemTypes: 'Episode', fields: 'Overview,Genres,DateCreated,DateLastMediaAdded', sortBy: 'ProductionYear,SortName', sortOrder: 'Ascending,Ascending',
    searchTerm: 'The pilot', genreIds: 'genre|safe', isPlayed: false, filters: 'IsFavorite', parentId: 'library/one' });
  assert.equal(libraryRequest(scope({ kind: 'favorites' }), defaultLibraryChoices(), '', 0).query.filters, 'IsFavorite');
});
test('blank search does not issue a browse and special media roots preserve their types', () => {
  assert.equal(libraryRequest(scope({ kind: 'search' }), defaultLibraryChoices(), ' \n ', 0).canLoad, false);
  for (const [kind, types] of [['music', 'MusicAlbum,MusicArtist,Audio,AudioBook'], ['photos', 'Photo,PhotoAlbum'], ['books', 'Book,AudioBook']] as const) {
    assert.equal(libraryRequest(scope({ kind }), defaultLibraryChoices(), '', 0).query.includeItemTypes, types);
  }
});
test('playlist contents retain the dedicated endpoint and refuse decorative filters and sort', () => {
  const request = libraryRequest(scope({ kind: 'container', parentId: 'list/one', parentType: 'Playlist', libraryId: 'ignored' }),
    { ...defaultLibraryChoices(), favoritesOnly: true, genreId: 'ignored', sort: 'DateCreated', watchStatus: 'Watched' }, 'ignored', 4, 2);
  assert.deepEqual(request, { path: 'Playlists/list%2Fone/Items', query: { startIndex: 4, limit: 2, enableTotalRecordCount: true }, canLoad: true });
});
test('nonvideo folder navigation preserves album, artist and photo children', () => {
  for (const [parentType, types] of [['MusicArtist', 'MusicAlbum,Audio,AudioBook'], ['MusicAlbum', 'Audio'], ['PhotoAlbum', 'Photo,PhotoAlbum']] as const) {
    const request = libraryRequest(scope({ kind: 'container', parentId: 'parent', parentType }), defaultLibraryChoices(), '', 0);
    assert.equal(request.query.includeItemTypes, types); assert.equal(request.query.parentId, 'parent');
  }
});
test('raw page offset advances across overlapping records rather than re-requesting the displayed count', () => {
  const page = new LibraryPagination();
  page.append({ Items: [item('a'), item('b')], TotalRecordCount: 6 }, false, 2);
  page.append({ Items: [item('b'), item('c')] }, false, 2);
  assert.equal(page.nextIndex, 4); assert.deepEqual(page.items.map(x => x.Id), ['a', 'b', 'c']); assert.equal(page.hasMore, true);
  page.append({ Items: [] }, false, 2); assert.equal(page.hasMore, false); assert.equal(page.items.length, 3);
});
test('no-total pagination follows raw page length; repeated playlist entries stay repeated', () => {
  const page = new LibraryPagination();
  page.append({ Items: [item('a'), item('a')], TotalRecordCount: -1 }, true, 2);
  assert.equal(page.total, undefined); assert.equal(page.hasMore, true); assert.equal(page.items.length, 2);
  page.append({ Items: [item('a')] }, true, 2); assert.equal(page.hasMore, false); assert.equal(page.nextIndex, 3); assert.equal(page.items.length, 3);
});
test('a malformed later page cannot partially advance the cursor or erase retained titles', () => {
  const page = new LibraryPagination(); page.append({ Items: [item('a')], TotalRecordCount: 3 }, false, 1);
  assert.throws(() => page.append({ Items: [item('b'), { Id: '', Name: 'bad' }] }, false, 1), /invalid library page/);
  assert.equal(page.nextIndex, 1); assert.equal(page.items.length, 1); assert.equal(page.hasMore, true);
});
test('aggregate missing, null, negative, fractional and unsafe counts remain unknown', () => {
  for (const count of [undefined, null, -1, 1.2, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]) {
    const series = item('s', { Type: 'Series', UserData: { UnplayedItemCount: count, Played: true } });
    assert.equal(aggregateUnplayedCount(series), undefined); assert.equal(itemWatched(series), undefined); assert.equal(watchStatusText(series), undefined);
  }
  assert.equal(watchStatusText(item('s', { Type: 'Series', UserData: { UnplayedItemCount: 4, Played: true } })), '4 unwatched');
  assert.equal(itemWatched(item('s', { Type: 'Season', UserData: { UnplayedItemCount: 0, Played: false } })), undefined);
  assert.equal(aggregateUnplayedCount(item('m', { Type: 'Movie', UserData: { UnplayedItemCount: 9 } })), undefined);
  assert.equal(itemWatched(item('m', { Type: 'Movie', UserData: { Played: false } })), false);
});
test('date metadata rejects sentinels and impossible calendar dates instead of rolling them forward', () => {
  for (const value of [undefined, null, '', 'not a date', '0001-01-01T00:00:00Z', '2025-02-29T10:00:00Z', '2024-04-31T10:00:00Z', '2024-00-01T00:00:00Z', '2024-01-01T24:00:00Z', '2024-01-01T00:60:00Z', '2024-01-01T00:00:00', '2024-01-01T00:00:00+99:00']) assert.equal(catalogueDate(value), undefined, String(value));
  assert.equal(catalogueDate('2024-02-29T10:20:30.1234567Z')?.toISOString(), '2024-02-29T10:20:30.123Z');
  assert.equal(catalogueDate('2024-02-29T10:20:30-05:00')?.toISOString(), '2024-02-29T15:20:30.000Z');
  const series = item('s', { Type: 'Series', DateCreated: '2020-01-01T12:00:00Z', DateLastMediaAdded: '2024-02-29T12:00:00Z' });
  assert.match(addedDateText(series, 'DateCreated', 'en-US')!, /^Added /);
  assert.match(addedDateText(series, 'DateLastContentAdded', 'en-US')!, /^Content added /);
  assert.equal(addedDateText({ ...series, DateLastMediaAdded: null }, 'DateLastContentAdded'), undefined);
});
test('See all newest episodes resets query choices while retaining only the scoped view style', () => {
  assert.deepEqual(newestEpisodeChoices('list'), { sort: 'DateCreated', direction: 'Descending', genreId: '', watchStatus: 'Any', favoritesOnly: false, view: 'list' });
});
test('missing episode numbers are not invented and season zero remains meaningful', () => {
  assert.equal(subtitle(item('e', { Type: 'Episode', Name: 'Special' })), 'Special');
  assert.equal(subtitle(item('e', { Type: 'Episode', Name: 'Special', ParentIndexNumber: 0, IndexNumber: 0 })), 'S0 E0 Special');
  assert.equal(subtitle(item('e', { Type: 'Episode', Name: 'Pilot', ParentIndexNumber: -1, IndexNumber: 2 })), 'E2 Pilot');
});
test('watched plans require confirmation for containers and multiple unique titles without sending anything', () => {
  assert.equal(watchedPlan([item('one', { Type: 'Movie' })], true).needsConfirmation, false);
  for (const type of ['Series', 'Season', 'BoxSet', 'Playlist', 'Folder', 'CollectionFolder']) {
    assert.equal(watchedPlan([item(type, { Type: type })], true).needsConfirmation, true);
  }
  const plan = watchedPlan([item('one'), item('one'), item('two')], false);
  assert.equal(plan.items.length, 2); assert.equal(plan.needsConfirmation, true); assert.equal(plan.value, false);
  assert.equal(plan.includesContainers, false);
  const original = item('stable'); const captured = watchedPlan([original], true); original.Id = 'changed';
  assert.equal(captured.items[0].Id, 'stable');
});

const policyItem = (Type: unknown, extra: Partial<MediaItem> = {}): MediaItem => ({ Id: 'one', Name: 'one', Type: Type as string, ...extra });
test('only a known standalone media type admits one-item direct watched behavior', () => {
  for (const type of ['Movie', 'Episode', 'Video', 'MusicVideo', 'Audio', 'AudioBook', 'Book', 'Photo', 'Trailer']) {
    const leaf = policyItem(type, { UserData: { Played: false } }); assert.equal(isKnownLeafItem(leaf), true); assert.equal(itemWatched(leaf), false); assert.equal(watchedPlan([leaf], true).needsConfirmation, false);
  }
});
test('known video/music/photo folders require descendant confirmation even if Played is present or IsFolder is false', () => {
  for (const type of ['Series', 'Season', 'BoxSet', 'Playlist', 'Folder', 'CollectionFolder', 'MusicAlbum', 'MusicArtist', 'PhotoAlbum', 'AggregateFolder', 'BasePluginFolder', 'ChannelFolderItem', 'ManualPlaylistsFolder', 'PlaylistsFolder', 'UserRootFolder', 'UserView']) {
    for (const Played of [true, false]) {
      const folder = policyItem(type, { IsFolder: false, UserData: { Played } }); assert.equal(isAggregateItem(folder), true); assert.equal(isKnownLeafItem(folder), false); assert.equal(itemWatched(folder), undefined);
      const plan = watchedPlan([folder], !Played); assert.equal(plan.needsConfirmation, true); assert.equal(plan.includesContainers, true);
    }
  }
});
test('positive server IsFolder wins over a contradictory leaf or unknown Type', () => {
  for (const type of ['Movie', 'unknown', undefined, ['Episode']]) {
    const folder = policyItem(type, { IsFolder: true, UserData: { UnplayedItemCount: 2, Played: true } }); assert.equal(watchedItemKind(folder), 'container'); assert.equal(itemWatched(folder), undefined); assert.equal(serverPlayed(folder), true); assert.equal(watchedPlan([folder], true).needsConfirmation, true);
  }
});
test('missing unknown malformed or lookalike Type cannot become a leaf merely because Played exists', () => {
  for (const type of [undefined, null, '', 'Unknown', 'Recording', 'movie', ' Movie ', ['Movie'], { toString: () => 'Movie' }, 123]) {
    for (const Played of [true, false]) {
      const unknown = policyItem(type, { IsFolder: false, UserData: { Played, UnplayedItemCount: 0 } }); assert.equal(watchedItemKind(unknown), 'unknown'); assert.equal(isKnownLeafItem(unknown), false); assert.equal(itemWatched(unknown), undefined); assert.equal(aggregateUnplayedCount(unknown), undefined);
      assert.equal(supportsWatchedMutation(unknown), false); assert.match(watchedUnavailableReason(unknown)!, /supported type metadata/); assert.throws(() => watchedPlan([unknown], true), /supported type metadata/);
    }
  }
});
test('malformed IsFolder is not coerced into standalone admission', () => {
  for (const value of ['false', 0, [], {}]) { const ambiguous = policyItem('Movie', { IsFolder: value as never, UserData: { Played: false } }); assert.equal(isKnownLeafItem(ambiguous), false); assert.throws(() => watchedPlan([ambiguous], true), /supported type metadata/); }
});
test('new nonvideo aggregate status remains unknown without a valid descendant count', () => {
  for (const type of ['MusicAlbum', 'MusicArtist', 'PhotoAlbum']) {
    for (const count of [undefined, null, -1, 1.5, Infinity]) assert.equal(itemWatched(policyItem(type, { UserData: { Played: true, UnplayedItemCount: count } })), undefined);
    assert.equal(itemWatched(policyItem(type, { UserData: { Played: false, UnplayedItemCount: 0 } })), undefined);
  }
});
test('unsupported metadata refuses an entire bulk plan before any write and valid captures stay immutable', () => {
  const unknown = policyItem(undefined); assert.throws(() => watchedPlan([unknown, policyItem('Movie', { Id: 'two' })], false), /supported type metadata/);
  const folder = policyItem('MusicAlbum'); const plan = watchedPlan([folder, folder, policyItem('Movie', { Id: 'two' })], false); folder.Id = 'changed';
  assert.equal(plan.items.length, 2); assert.equal(plan.items[0].Id, 'one'); assert.equal(plan.includesContainers, true); assert.equal(plan.needsConfirmation, true); assert.equal(plan.value, false);
});
test('aggregate zero stays a literal count and never infers a complete flag from the count', () => {
  for (const Played of [true, false, undefined]) {
    const folder = policyItem('Series', { UserData: { UnplayedItemCount: 0, Played } });
    assert.equal(watchStatusText(folder), '0 unwatched'); assert.equal(itemWatched(folder), undefined); assert.equal(serverPlayed(folder), Played);
  }
});
