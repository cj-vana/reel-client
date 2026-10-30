// A small, realistic library for demos and screenshots. The test suites use fixture-library.mjs;
// fixture-server.mjs serves this catalog instead when REEL_FIXTURE_DEMO=1.
import { readFile, stat } from 'node:fs/promises';
import { resolve } from 'node:path';
import { filterFixtureItems, fixtureGenres, fixtureLibraries, sortFixtureItems } from './fixture-library.mjs';

const TICKS = 10_000_000;
const MINUTE = 60 * TICKS;

const FILMS = [
  ['saltwater-kings', 'Saltwater Kings', 2025, 'PG-13', 118, ['Crime', 'Drama'], 7.6, 'Three old friends sail home to the island they grew up on to steal back the one thing the town sold away. The harbor remembers them, and so does the man who bought it.'],
  ['conservatory', 'Conservatory', 2026, 'R', 104, ['Science Fiction', 'Thriller'], 7.1, 'A night-shift botanist discovers that the plants in a sealed Victorian glasshouse are listening. By morning, one of them has learned her name.'],
  ['the-cartographers-daughter', "The Cartographer's Daughter", 2024, 'PG', 131, ['Adventure', 'Drama'], 8.0, 'After her father vanishes mapping an uncharted pass, a young surveyor finishes his last map by walking it, one ridge at a time.'],
  ['neon-orchard', 'Neon Orchard', 2026, 'R', 112, ['Mystery', 'Thriller'], 7.4, 'In a city where fruit trees break through the pavement every spring, a detective follows a trail of blossoms to a disappearance nobody reported.'],
  ['paper-moons', 'Paper Moons', 2025, 'G', 92, ['Animation', 'Family'], 7.9, 'A boy and a paper fox fish for fallen stars from a village folded on the edge of the moon, until the night they catch one that wants to go home.'],
  ['thunder-prairie', 'Thunder Prairie', 2023, 'PG', 88, ['Documentary'], 8.3, 'One summer on the last wild grassland, following a bison herd through drought, fire and the storms that bring the land back to life.'],
  ['kestrel-point', 'Kestrel Point', 2024, 'PG-13', 109, ['Mystery', 'Drama'], 7.2, 'When the keeper of a remote lighthouse stops answering the radio, his estranged daughter rows out through the fog and finds the light still burning.'],
  ['deep-end-summer', 'Deep End Summer', 2025, 'PG-13', 101, ['Comedy', 'Drama'], 7.5, 'Four friends spend their last summer before college working nights at a desert motel, swimming in the pool they were never allowed to use.'],
  ['iron-and-velvet', 'Iron & Velvet', 2026, 'R', 123, ['Drama', 'Sport'], 7.8, 'A retired champion returns to the gym where she learned to fight, to train the one opponent she never beat: the woman who replaced her.'],
  ['low-orbit', 'Low Orbit', 2024, 'PG-13', 116, ['Science Fiction', 'Drama'], 7.7, 'Ninety minutes a lap, sixteen sunrises a day. An engineer alone on a failing station has to decide which of them will be her last.'],
  ['mile-marker-9', 'Mile Marker 9', 2023, 'R', 107, ['Comedy', 'Drama'], 7.0, "Two brothers, one borrowed convertible, and a road trip to scatter their father's ashes somewhere he never actually went."],
  ['hollowmere', 'Hollowmere', 2025, 'R', 99, ['Fantasy', 'Horror'], 6.9, 'Every autumn a lantern appears on the black lake below the old manor. This year, someone rows out to meet it.'],
];

const SHOWS = [
  ['pier-seventeen', 'Pier Seventeen', 2024, 'TV-MA', 52, ['Crime', 'Drama'], 8.4, 'A harbor detective works nights at the busiest container port in the country, where everything that matters arrives in a box nobody opens.',
    [['Night Shift', 'Manifest', 'Dead Reckoning'], ['High Water', 'Customs', 'The Long Berth']]],
  ['wheatland', 'Wheatland', 2023, 'TV-14', 47, ['Drama', 'Family'], 8.1, 'Three generations of the Halvorsen family try to hold on to their farm through the hardest year it has seen.',
    [['First Cut', 'Hail', 'Harvest Moon'], ['Thaw', 'Seed Money', 'Open Range']]],
  ['far-array', 'Far Array', 2025, 'TV-14', 55, ['Science Fiction', 'Mystery'], 8.2, 'At a remote radio observatory, the night crew picks up a repeating signal. Then it starts answering back.',
    [['First Light', 'Noise Floor', 'Handshake'], ['Polar Night', 'Interference', 'The Reply']]],
  ['back-of-house', 'Back of House', 2026, 'TV-MA', 32, ['Comedy', 'Drama'], 8.0, "A burned-out chef takes over her late mentor's restaurant, and the kitchen crew that never wanted her there.",
    [['Mise en Place', 'Family Meal', 'Eighty-Six'], ['Soft Opening', 'The Pass', 'Last Seating']]],
];

const EPISODE_OVERVIEWS = [
  'A routine night turns when something arrives that should not be on the manifest.',
  'Old loyalties are tested, and someone finally says what everyone has been thinking.',
  'The choice everyone has been avoiding cannot wait another day.',
];

// Invented names for the demo credits.
const FIRST_NAMES = ['Mara', 'Tobias', 'Ines', 'Callum', 'Priya', 'Dario', 'Elske', 'Jonah', 'Wren', 'Anouk', 'Felix', 'Sade', 'Rafael', 'Noor', 'Quinn', 'Hana', 'Oskar'];
const LAST_NAMES = ['Okafor', 'Lindqvist', 'Varga', 'Ashdown', 'Reyes', 'Kowal', 'Brennan', 'Sato', 'Moreau', 'Adeyemi', 'Hollis', 'Petrov', 'Caird', 'Navarro', 'Ferris', 'Iwata', 'Delacroix'];
const CHARACTERS = ['Nico Vale', 'Ada Brandt', 'Rook', 'Elena Marsh', 'Teddy Quill', 'June Okoro', 'Captain Ilse Hart', 'Sam Lowry', 'Della Frost', 'Ivo', 'Marguerite', 'Ben Ashby', 'Lena Sorel', 'Coach Ramos', 'Dr. Aiko Tan'];

const HDR_TITLES = new Set(['conservatory', 'low-orbit', 'thunder-prairie', 'far-array']);

function addedDate(rank) {
  return new Date(Date.UTC(2026, 9, 24, 20) - rank * 26 * 3600000).toISOString();
}

function mediaSource(id, slug) {
  const uhd = HDR_TITLES.has(slug);
  return {
    Id: id + '-source', Container: 'mkv',
    MediaStreams: [
      { Type: 'Video', Index: 0, Codec: 'hevc', Width: uhd ? 3840 : 1920, Height: uhd ? 2160 : 1080, VideoRange: uhd ? 'HDR' : 'SDR', VideoRangeType: uhd ? 'HDR10' : 'SDR' },
      { Type: 'Audio', Index: 1, Codec: 'eac3', Channels: 6, ChannelLayout: '5.1', Language: 'eng', DisplayTitle: 'English 5.1', IsDefault: true },
      { Type: 'Audio', Index: 2, Codec: 'aac', Channels: 2, Language: 'eng', DisplayTitle: 'English Stereo' },
      { Type: 'Subtitle', Index: 3, Codec: 'srt', Language: 'eng', DisplayTitle: 'English', IsExternal: false },
      { Type: 'Subtitle', Index: 4, Codec: 'srt', Language: 'spa', DisplayTitle: 'Spanish', IsExternal: false },
    ],
  };
}

function userData(state, user, id, extra = {}) {
  const key = user + '|' + id;
  const data = { ...extra };
  if (state.positions.has(key)) data.PlaybackPositionTicks = state.positions.get(key);
  if (state.favorites.has(key)) data.IsFavorite = state.favorites.get(key);
  if (state.watched.has(key)) data.Played = state.watched.get(key);
  return data;
}

// Seeded progress so Home has something to resume. Values are minutes into the title.
const RESUME_MINUTES = { 'movie-neon-orchard': 47, 'movie-low-orbit': 12, 'episode-pier-seventeen-1-2': 31 };
const PLAYED = new Set(['movie-paper-moons', 'episode-pier-seventeen-1-1', 'episode-far-array-1-1', 'episode-back-of-house-1-1', 'episode-back-of-house-1-2', 'episode-back-of-house-1-3']);
const FAVORITES = new Set(['movie-the-cartographers-daughter', 'series-pier-seventeen', 'movie-iron-and-velvet']);

function seededUserData(state, user, id, runtimeMinutes) {
  const minutes = RESUME_MINUTES[id];
  return userData(state, user, id, {
    IsFavorite: FAVORITES.has(id), Played: PLAYED.has(id),
    ...(minutes ? { PlaybackPositionTicks: minutes * MINUTE, PlayedPercentage: (minutes / runtimeMinutes) * 100 } : {}),
  });
}

export function createDemoLibrary({ artworkDir }) {
  // Every item id the demo can return, mapped to the artwork folder it uses.
  const slugs = new Map();
  for (const [slug] of FILMS) slugs.set('movie-' + slug, slug);
  for (const [slug, , , , , , , , names] of SHOWS) {
    slugs.set('series-' + slug, slug);
    names.forEach((seasonNames, s) => {
      slugs.set(`season-${slug}-${s + 1}`, slug);
      seasonNames.forEach((_, e) => slugs.set(`episode-${slug}-${s + 1}-${e + 1}`, slug));
    });
  }
  const titles = (state, user) => {
    const films = FILMS.map(([slug, Name, ProductionYear, OfficialRating, minutes, Genres, CommunityRating, Overview], rank) => {
      const Id = 'movie-' + slug;
      return { Id, Name, Type: 'Movie', ProductionYear, OfficialRating, CommunityRating, Genres, Overview, RunTimeTicks: minutes * MINUTE,
        DateCreated: addedDate(rank * 2), ImageTags: { Primary: 'demo' }, BackdropImageTags: ['demo'],
        MediaSources: [mediaSource(Id, slug)], UserData: seededUserData(state, user, Id, minutes) };
    });
    const shows = SHOWS.map(([slug, Name, ProductionYear, OfficialRating, minutes, Genres, CommunityRating, Overview], rank) => {
      const Id = 'series-' + slug;
      return { Id, Name, Type: 'Series', ProductionYear, OfficialRating, CommunityRating, Genres, Overview, RunTimeTicks: minutes * MINUTE,
        DateCreated: addedDate(rank * 2 + 1), ChildCount: 2, ImageTags: { Primary: 'demo' }, BackdropImageTags: ['demo'],
        UserData: seededUserData(state, user, Id, minutes) };
    });
    return [...films, ...shows];
  };

  // Invented credits so Details shows a cast row. Built from fixed lists, so every run gives the same names.
  const people = (slug, index) => [
    ...[0, 1, 2, 3].map(i => ({ Id: `person-${slug}-${i}`, Type: 'Actor', Name: FIRST_NAMES[(index * 4 + i) % FIRST_NAMES.length] + ' ' + LAST_NAMES[(index * 3 + i * 5) % LAST_NAMES.length], Role: CHARACTERS[(index * 2 + i * 3) % CHARACTERS.length] })),
    { Id: `person-${slug}-director`, Type: 'Director', Name: FIRST_NAMES[(index * 4 + 7) % FIRST_NAMES.length] + ' ' + LAST_NAMES[(index * 7 + 2) % LAST_NAMES.length], Role: 'Director' }
  ];
  const credited = item => {
    const slug = slugs.get(item.Id), index = [...FILMS, ...SHOWS].findIndex(entry => entry[0] === slug);
    return (item.Type === 'Movie' || item.Type === 'Series') && index >= 0 ? { ...item, People: people(slug, index) } : item;
  };
  // Titles sharing the most genres with this one, best rated first.
  const similar = (items, id, limit) => {
    const source = items.find(item => item.Id === id);
    if (!source) return [];
    const shared = item => item.Genres.filter(genre => source.Genres.includes(genre)).length;
    return items.filter(item => item.Id !== id && shared(item) > 0)
      .sort((a, b) => shared(b) - shared(a) || b.CommunityRating - a.CommunityRating)
      .slice(0, limit);
  };

  const seasons = seriesSlug => [1, 2].map(n => ({ Id: `season-${seriesSlug}-${n}`, Name: 'Season ' + n, Type: 'Season', SeriesId: 'series-' + seriesSlug, IndexNumber: n }));

  const episodes = (state, user, seriesSlug) => {
    const show = SHOWS.find(entry => entry[0] === seriesSlug);
    if (!show) return [];
    const [, seriesName, year, rating, minutes, genres, , , names] = show;
    return names.flatMap((seasonNames, s) => seasonNames.map((Name, e) => {
      const season = s + 1, number = e + 1, Id = `episode-${seriesSlug}-${season}-${number}`;
      return { Id, Name, Type: 'Episode', SeriesId: 'series-' + seriesSlug, SeriesName: seriesName, SeasonId: `season-${seriesSlug}-${season}`,
        IndexNumber: number, ParentIndexNumber: season, ProductionYear: year, OfficialRating: rating, Genres: genres,
        RunTimeTicks: minutes * MINUTE, Overview: EPISODE_OVERVIEWS[e], DateCreated: addedDate(season === 2 ? 8 - number : 20 + number),
        ImageTags: { Primary: 'demo' }, SeriesPrimaryImageTag: 'demo', ParentBackdropItemId: 'series-' + seriesSlug, ParentBackdropImageTags: ['demo'],
        MediaSources: [mediaSource(Id, seriesSlug)], UserData: seededUserData(state, user, Id, minutes) };
    }));
  };

  const allEpisodes = (state, user) => SHOWS.flatMap(show => episodes(state, user, show[0]));

  async function artwork(path, send) {
    const match = /^\/Items\/([^/]+)\/Images\/(Primary|Backdrop|Thumb)/.exec(path);
    if (!match) return false;
    const [, id, kind] = match;
    // Cast and crew have no photos here, so they get Jellyfin's answer for a missing image.
    if (id.startsWith('person-')) { send({}, 404); return true; }
    const slug = slugs.get(id);
    if (!slug) return false;
    let file = kind === 'Backdrop' || kind === 'Thumb' ? 'backdrop.jpg' : 'poster.jpg';
    const episode = /^episode-.+-(\d+)-(\d+)$/.exec(id);
    if (episode && kind === 'Primary') file = `episode-${(Number(episode[1]) - 1) * 3 + Number(episode[2])}.jpg`;
    try { send(await readFile(resolve(artworkDir, slug, file)), 200, 'image/jpeg'); } catch { send({}, 404); }
    return true;
  }

  // Returns true when the demo catalog answered the request.
  async function handle({ path, query, user, state, send }) {
    if (await artwork(path, send)) return true;
    const items = titles(state, user);
    const everything = () => [...items, ...allEpisodes(state, user)];
    if (path === '/UserViews') { send({ Items: fixtureLibraries, TotalRecordCount: fixtureLibraries.length }); return true; }
    if (path === '/Genres') { const values = fixtureGenres(everything(), query); send({ Items: values, TotalRecordCount: values.length }); return true; }
    if (path === '/UserItems/Resume') {
      const values = everything().filter(item => item.UserData.PlaybackPositionTicks > 0 && !item.UserData.Played);
      send({ Items: values, TotalRecordCount: values.length }); return true;
    }
    if (path === '/Shows/NextUp') {
      // Jellyfin's rule: the first unplayed episode after the last played one, which may be one
      // already started. Series with nothing played yet have no next episode.
      const values = SHOWS.map(show => {
        const list = episodes(state, user, show[0]);
        const last = list.map(episode => episode.UserData.Played).lastIndexOf(true);
        return last < 0 ? undefined : list.slice(last + 1).find(episode => !episode.UserData.Played);
      }).filter(Boolean);
      send({ Items: values, TotalRecordCount: values.length }); return true;
    }
    if (path === '/Items/Latest') {
      const type = query.includeitemtypes;
      if (type === 'Episode') {
        const values = allEpisodes(state, user).sort((a, b) => Date.parse(b.DateCreated) - Date.parse(a.DateCreated));
        send(query.groupitems === 'false' ? values.slice(0, 18) : items.filter(item => item.Type === 'Series')); return true;
      }
      send(sortFixtureItems(items.filter(item => item.Type === type), 'DateCreated', 'Descending').slice(0, 18)); return true;
    }
    const showPath = /^\/Shows\/series-([^/]+)\/(Seasons|Episodes)$/.exec(path);
    if (showPath) {
      const [, slug, kind] = showPath;
      if (kind === 'Seasons') { send({ Items: seasons(slug) }); return true; }
      let values = episodes(state, user, slug);
      if (query.adjacentto) {
        const index = values.findIndex(item => item.Id === query.adjacentto);
        values = index >= 0 ? values.slice(Math.max(0, index - 1), index + 2) : [];
      } else if (query.seasonid) values = values.filter(item => item.SeasonId === query.seasonid);
      const start = Number(query.startindex ?? 0);
      send({ Items: values.slice(start, start + Number(query.limit ?? values.length)), TotalRecordCount: values.length }); return true;
    }
    if (path === '/Items') {
      let values = query.includeitemtypes?.includes('Episode') ? everything() : items;
      values = sortFixtureItems(filterFixtureItems(values, query), query.sortby, query.sortorder);
      const start = Number(query.startindex ?? 0);
      send({ Items: values.slice(start, start + Number(query.limit ?? 60)), TotalRecordCount: values.length }); return true;
    }
    const similarPath = /^\/Items\/([^/]+)\/Similar$/.exec(path);
    if (similarPath) {
      const values = similar(items, similarPath[1], Number(query.limit ?? 12));
      send({ Items: values, TotalRecordCount: values.length }); return true;
    }
    const itemPath = /^\/Items\/([^/]+)$/.exec(path);
    if (itemPath) {
      const id = itemPath[1];
      const item = everything().find(entry => entry.Id === id) ?? (id.startsWith('season-') ? seasons(id.replace(/^season-|-\d+$/g, '')).find(entry => entry.Id === id) : undefined);
      if (!item) return false;
      send(credited(item)); return true;
    }
    return false;
  }

  // The clip `npm run qa:prepare-demo` rendered for a title (an episode plays its series' clip), or
  // undefined when there is none, so the stream route falls back to the test video.
  async function clip(media, id) {
    const slug = slugs.get(id);
    if (!slug) return undefined;
    const file = resolve(media, 'demo', slug + '.mp4');
    return stat(file).then(() => file, () => undefined);
  }

  return { handle, clip, serverName: 'Home Library' };
}
