// The disposable API follows Jellyfin's ordered sortBy/sortOrder vectors.
export function sortFixtureItems(items, sortBy = '', sortOrder = 'Ascending') {
  const fields = sortBy.split(','), directions = sortOrder.split(',');
  const value = (item, field) => {
    if (field === 'SortName') return item.SortName ?? item.Name;
    if (field === 'ProductionYear') return Number.isFinite(item.ProductionYear) ? item.ProductionYear : undefined;
    if (field === 'DateCreated' || field === 'DateLastContentAdded') {
      const date = Date.parse(item[field === 'DateCreated' ? 'DateCreated' : 'DateLastMediaAdded']);
      return Number.isFinite(date) ? date : undefined;
    }
  };
  return [...items].sort((left, right) => {
    for (let index = 0; index < fields.length; index++) {
      const a = value(left, fields[index]), b = value(right, fields[index]);
      if (a === undefined && b === undefined) continue;
      if (a === undefined) return 1;
      if (b === undefined) return -1;
      const comparison = typeof a === 'string' ? a.localeCompare(b) : a - b;
      if (comparison) return comparison * ((directions[index] ?? directions[0]) === 'Descending' ? -1 : 1);
    }
    return 0;
  });
}

export function fixtureAddedDate(number) {
  return new Date(Date.UTC(2026, 8, 1, 12) + number * 86400000).toISOString();
}


export const fixtureLibraries = [
  { Id: 'library-movies', Name: 'Films', Type: 'CollectionFolder', CollectionType: 'movies', IsFolder: true },
  { Id: 'library-series', Name: 'TV Shows', Type: 'CollectionFolder', CollectionType: 'tvshows', IsFolder: true },
  { Id: 'library-music', Name: 'Music', Type: 'CollectionFolder', CollectionType: 'music', IsFolder: true },
  { Id: 'library-photos', Name: 'Photos', Type: 'CollectionFolder', CollectionType: 'photos', IsFolder: true },
  { Id: 'library-books', Name: 'Books', Type: 'CollectionFolder', CollectionType: 'books', IsFolder: true }
];
const libraryTypes = {
  'library-movies': ['Movie'], 'library-series': ['Series', 'Season', 'Episode'],
  'library-music': ['MusicAlbum', 'Audio'], 'library-photos': ['PhotoAlbum', 'Photo'], 'library-books': ['Book'],
  'album-1': ['Audio'], 'photo-album-1': ['Photo']
};
const genreId = name => 'genre-' + name.toLowerCase().replace(/[^a-z0-9]+/g, '-');
export function filterFixtureItems(items, query = {}) {
  const types = query.includeitemtypes?.split(','), genres = query.genreids?.split(',');
  return items.filter(item => {
    if (query.parentid) {
      const allowed = libraryTypes[query.parentid];
      if (allowed ? !allowed.includes(item.Type) : item.SeriesId !== query.parentid && item.SeasonId !== query.parentid) return false;
    }
    if (types && !types.includes(item.Type)) return false;
    if (genres && !item.Genres?.some(name => genres.includes(genreId(name)))) return false;
    if (query.filters === 'IsFavorite' && !item.UserData?.IsFavorite) return false;
    if (query.isplayed === 'true' && item.UserData?.Played !== true) return false;
    if (query.isplayed === 'false' && item.UserData?.Played === true) return false;
    if (query.searchterm && !(item.Name + (item.SeriesName ?? '')).toLowerCase().includes(query.searchterm.toLowerCase())) return false;
    return true;
  });
}
export function fixtureGenres(items, query = {}) {
  return [...new Set(filterFixtureItems(items, { parentid: query.parentid, includeitemtypes: query.includeitemtypes }).flatMap(item => item.Genres ?? []))]
    .sort().map(Name => ({ Id: genreId(Name), Name, Type: 'Genre' }));
}
