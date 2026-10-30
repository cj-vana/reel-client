import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { readFile, stat } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { fixtureAddedDate, sortFixtureItems, filterFixtureItems, fixtureGenres, fixtureLibraries } from './fixture-library.mjs';
import { createDemoLibrary } from './demo-library.mjs';
import { INTRO_EPISODES, INTRO_RUNTIME, INTRO_TAIL_START } from './intro-fixture.mjs';

const port = Number(process.env.REEL_FIXTURE_PORT ?? 18771);
const media = resolve(process.env.REEL_FIXTURE_MEDIA ?? '.cache/fixture');
// --demo (or REEL_FIXTURE_DEMO=1) serves the screenshot library in fixtures/demo instead of the test catalog,
// and plays each title's clip from `npm run qa:prepare-demo` when it exists.
const demo = process.argv.includes('--demo') || process.env.REEL_FIXTURE_DEMO === '1'
  ? createDemoLibrary({ artworkDir: fileURLToPath(new URL('../fixtures/demo', import.meta.url)) })
  : undefined;
const TICKS = 10_000_000;
const state = { positions: new Map(), favorites: new Map(), watched: new Map(), reports: [], calls: [], failures: 0, artworkCancellations: 0, bookFailures: 0, episodeModes: new Map(), episodeCancellations: 0, episodeCounter: 0, episodeEvents: [], episodeRequests: [], episodeHolds: new Map() };
const names = ['The Quiet Earth', 'After the Last Light', 'North of Nowhere', 'Blue Hours', 'The Long Way Home', 'A Forest, Remembered'];
const colors = ['#283b4a', '#284b4d', '#293c61', '#274f68', '#526249', '#44544b'];
function episode(number, user, season = 1) {
  const Id = `episode-${season}-${number}`;
  // The intro-scan account plays the longer synthetic episodes built for the intro and credits scan.
  const runtime = user?.startsWith('intro-scan') && INTRO_EPISODES.includes(Id) ? INTRO_RUNTIME : 14;
  return { Id, Name: ['A new beginning', 'Below the surface', 'The way back'][number - 1] ?? `Synthetic episode ${number}`, Type: 'Episode', SeriesId: 'series-7', SeasonId: 'season-' + season, Genres: ['Drama', 'Adventure'], SeriesName: 'Out of the Blue', SeriesPrimaryImageTag: 'v1', ParentBackdropItemId: 'series-7', ParentBackdropImageTags: ['v1'], IndexNumber: number, ParentIndexNumber: season, RunTimeTicks: runtime * TICKS, Overview: 'A new chapter, and a different way of seeing the world.', ImageTags: { Primary: 'v1' }, UserData: { PlaybackPositionTicks: state.positions.get(user + '|' + Id) ?? 0 }, MediaSources: [source(Id)] };
}
function recentEpisodes(user, order) {
  if (user === 'empty') return [];
  const dates = ['2026-10-21T12:00:00Z', '2026-10-24T12:00:00Z', '2026-10-23T12:00:00Z'];
  return (order ?? [1, 2, 3]).map((n, i) => ({ ...episode(n, user), DateCreated: order ? new Date(Date.UTC(2026, 9, 24, 12) - i * 60000).toISOString() : dates[i], ...(user.startsWith('recent-second') ? { SeriesName: 'Second account series', Name: 'Other account: ' + episode(n, user).Name } : {}) }));
}
function source(id) { return { Id: id + '-source', Container: 'mp4', MediaStreams: [{ Type: 'Video', Index: 0, Codec: 'h264' }, { Type: 'Audio', Index: 1, Codec: 'aac', DisplayTitle: 'English · AAC stereo' }, { Type: 'Subtitle', Index: 2, Codec: 'vtt', DisplayTitle: 'English captions' }] }; }
function bookPDF() {
  const text = 'BT /F1 20 Tf 72 720 Td (Reel original synthetic test book) Tj ET';
  const objects = ['<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>', '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>', `<< /Length ${text.length} >>\nstream\n${text}\nendstream`, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'];
  let pdf = '%PDF-1.4\n', offsets = [0];
  objects.forEach((object, index) => { offsets.push(Buffer.byteLength(pdf)); pdf += `${index + 1} 0 obj\n${object}\nendobj\n`; });
  const xref = Buffer.byteLength(pdf);
  pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n${offsets.slice(1).map(offset => String(offset).padStart(10, '0') + ' 00000 n \n').join('')}trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(pdf);
}
function catalog(user) {
  if (user === 'empty') return [];
  const result = Array.from({ length: 75 }, (_, i) => {
    const n = i + 1, series = [7, 8, 9].includes(n), Id = `${series ? 'series' : 'movie'}-${n}`;
    return { Id, Name: series ? ['Out of the Blue', 'Wild Country', 'The Other Side'][n - 7] : names[i % 6] + (n > 9 ? ` · Volume ${n}` : ''), Type: series ? 'Series' : 'Movie', Overview: 'Some journeys bring you somewhere new. Others bring you back to yourself. A quiet story of unexpected connections and the places we call home.', RunTimeTicks: 14 * TICKS, DateCreated: fixtureAddedDate(n), ProductionYear: 2026 - n % 5, OfficialRating: 'PG-13', CommunityRating: 8.2, Genres: n <= 9 ? ['Drama', 'Adventure'] : n % 3 === 0 ? ['Documentary'] : n % 3 === 1 ? ['Drama'] : ['Adventure'], ImageTags: { Primary: 'v1' }, BackdropImageTags: ['v1'], UserData: { PlaybackPositionTicks: state.positions.get(user + '|' + Id) ?? (Id === 'movie-4' ? 3 * TICKS : 0), IsFavorite: state.favorites.get(user + '|' + Id) ?? false, Played: state.watched.get(user + '|' + Id) ?? false }, MediaSources: [source(Id)], Chapters: [{ Name: 'Opening', StartPositionTicks: 0 }, { Name: 'A new perspective', StartPositionTicks: 5 * TICKS }] };
  });
  result.push({ Id: 'album-1', Name: 'Evening Light', Type: 'MusicAlbum', ImageTags: { Primary: 'v1' } }, { Id: 'audio-1', Name: 'A quiet place', Type: 'Audio', MediaType: 'Audio', RunTimeTicks: 14 * TICKS, ImageTags: { Primary: 'v1' }, MediaSources: [source('audio-1')] }, { Id: 'photo-album-1', Name: 'The coast, remembered', Type: 'PhotoAlbum', ImageTags: { Primary: 'v1' } }, { Id: 'photo-1', Name: 'Blue hour', Type: 'Photo', ImageTags: { Primary: 'v1' } }, { Id: 'book-1', Name: 'A field guide to the quiet', Type: 'Book', ImageTags: { Primary: 'v1' } });
  return result;
}

const server = createServer(async (request, response) => {
  const url = new URL(request.url, 'http://127.0.0.1:' + port), path = url.pathname.replace(/^\/jellyfin(?=\/|$)/, '') || '/';
  const query = Object.fromEntries(Array.from(url.searchParams.entries()).map(([k, v]) => [k.toLowerCase(), v]));
  const origin = request.headers.origin;
  if (origin && (/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(origin) || origin === 'null')) response.setHeader('Access-Control-Allow-Origin', origin);
  response.setHeader('Vary', 'Origin'); response.setHeader('Access-Control-Allow-Headers', 'Authorization,Content-Type'); response.setHeader('Access-Control-Allow-Methods', 'GET,HEAD,POST,DELETE,OPTIONS'); response.setHeader('Cache-Control', 'no-store');
  const send = (value = null, status = 200, type = 'application/json') => { const data = Buffer.isBuffer(value) ? value : Buffer.from(JSON.stringify(value)); response.writeHead(status, { 'Content-Type': type, 'Content-Length': data.length }); response.end(data); };
  if (request.method === 'OPTIONS') { response.writeHead(204); response.end(); return; }
  const user = /Token="fixture-([^"\r\n]+)"/.exec(request.headers.authorization ?? '')?.[1];
  let body = {};
  try { if (request.method === 'POST') { let text = ''; for await (const chunk of request) { text += chunk; if (text.length > 262144) throw new Error('Too large'); } body = text ? JSON.parse(text) : {}; } } catch { send({ error: 'Invalid body' }, 400); return; }
  state.calls.push({ path, method: request.method, user: user ?? null, query: Object.fromEntries(Object.entries(query).filter(([key]) => !['apikey','api_key','token'].includes(key))) });
  try {
    if (path === '/qa/state') { send({ reports: state.reports, calls: state.calls, artworkCancellations: state.artworkCancellations, episodeCancellations: state.episodeCancellations, episodeCounter: state.episodeCounter, episodeEvents: state.episodeEvents, episodeRequests: state.episodeRequests, episodeHolds: [...state.episodeHolds].map(([id, gate]) => ({ id, user: gate.user, released: gate.released, waiting: [...gate.waiters.keys()] })) }); return; }
    if (path === '/qa/episodes' && request.method === 'POST') {
      if (typeof body.user !== 'string' || !body.user.startsWith('recent-') || Object.keys(body).some(key => !['user','empty','fail','delayMs','othersEmpty','allFail','malformed','holdId','baseFail','episodeOrder'].includes(key)) || ['empty','fail','othersEmpty','allFail','malformed','baseFail'].some(key => body[key] !== undefined && typeof body[key] !== 'boolean') || body.holdId !== undefined && (typeof body.holdId !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(body.holdId)) || body.delayMs !== undefined && (!Number.isInteger(body.delayMs) || body.delayMs < 0 || body.delayMs > 4000) || body.episodeOrder !== undefined && (!Array.isArray(body.episodeOrder) || body.episodeOrder.length > 12 || new Set(body.episodeOrder).size !== body.episodeOrder.length || body.episodeOrder.some(n => !Number.isInteger(n) || n < 1 || n > 12))) { send({}, 400); return; }
      if (body.holdId) {
        if (state.episodeHolds.has(body.holdId) || state.episodeHolds.size >= 64) { send({}, 409); return; }
        state.episodeHolds.set(body.holdId, { user: body.user, released: false, waiters: new Map() });
      }
      state.episodeModes.set(body.user, { ...body }); send({ ok: true }); return;
    }
    if (path === '/qa/episode-release' && request.method === 'POST') {
      const gate = state.episodeHolds.get(body.holdId);
      if (Object.keys(body).some(key => !['holdId','user'].includes(key)) || !gate || gate.user !== body.user || gate.released) { send({}, 409); return; }
      gate.released = true;
      const waiting = [...gate.waiters.keys()];
      state.episodeEvents.push({ event: 'release', holdId: body.holdId, user: body.user, waiting });
      for (const waiter of gate.waiters.values()) waiter();
      gate.waiters.clear(); send({ released: true, holdId: body.holdId, user: body.user, waiting }); return;
    }
    if (path === '/qa/reset') { state.positions.clear(); state.favorites.clear(); state.watched.clear(); state.reports = []; state.calls = []; state.failures = 0; state.artworkCancellations = 0; state.bookFailures = 0; state.episodeModes.clear(); state.episodeCancellations = 0; send({ ok: true }); return; }
    if (path === '/System/Info/Public') { send({ ServerName: demo ? demo.serverName : 'Reel Test Library', Version: '12.3.0' }); return; }
    if (path === '/Users/AuthenticateByName') { if (body.Pw !== 'demo') send({}, 401); else send({ AccessToken: 'fixture-' + body.Username, User: { Id: body.Username, Name: body.Username === 'second' ? 'Sam' : 'Alex' } }); return; }
    // The intro scan's audio, as Jellyfin's progressive MP3 transcode would send it. The scan signs in with the
    // Authorization header, and must use its own play session and no device id.
    if (request.method === 'GET' && /^\/Audio\/[^/]+\/stream\.mp3$/.test(path)) {
      const id = path.split('/')[2], start = Number(query.starttimeticks ?? 0) / TICKS;
      if (!user) { send({}, 401); return; }
      if (!user.startsWith('intro-scan') || !INTRO_EPISODES.includes(id)) { send({}, 404); return; }
      if (query.deviceid !== undefined || !/^reel-scan-[0-9a-f]{24}$/.test(query.playsessionid ?? '') || query.audiocodec !== 'mp3') { send({ error: 'Unexpected scan request' }, 400); return; }
      const file = start === 0 ? id + '.mp3' : Math.abs(start - INTRO_TAIL_START) < 0.01 ? id + '-tail.mp3' : undefined;
      if (!file) { send({ error: 'Unexpected scan start' }, 400); return; }
      send(await readFile(resolve(media, 'intro', file)), 200, 'audio/mpeg'); return;
    }
    if ((request.method === 'GET' || request.method === 'HEAD') && (path.startsWith('/Videos/') || path.startsWith('/Audio/'))) {
      if (!query.apikey?.startsWith('fixture-')) { send({}, 401); return; }
      if (query.apikey === 'fixture-fallback' && path.endsWith('/stream')) { send({}, 415); return; }
      if (path.endsWith('master.m3u8')) {
        let playlist = await readFile(resolve(media, 'hls/index.m3u8'), 'utf8');
        playlist = playlist.replace(/^(segment\d+\.ts)$/gm, filename => `/Videos/fixture/${filename}?ApiKey=${encodeURIComponent(query.apikey)}`);
        send(Buffer.from(playlist), 200, 'application/vnd.apple.mpegurl'); return;
      }
      const scanEpisode = query.apikey.startsWith('fixture-intro-scan') && INTRO_EPISODES.includes(path.split('/')[2]);
      const file = path.endsWith('.ts') ? resolve(media, 'hls', path.split('/').at(-1)) : scanEpisode ? resolve(media, 'intro', path.split('/')[2] + '.mp4') : await demo?.clip(media, path.split('/')[2]) ?? resolve(media, 'sample.mp4');
      const data = await readFile(file); let start = 0, end = data.length - 1;
      const range = /^bytes=(\d+)-(\d*)$/.exec(request.headers.range ?? '');
      if (range) { start = Number(range[1]); if (range[2]) end = Math.min(end, Number(range[2])); }
      if (start > end) { response.writeHead(416, { 'Content-Length': 0 }); response.end(); return; }
      response.writeHead(range ? 206 : 200, { 'Content-Type': path.endsWith('.ts') ? 'video/mp2t' : 'video/mp4', 'Content-Length': end - start + 1, 'Accept-Ranges': 'bytes', ...(range ? { 'Content-Range': `bytes ${start}-${end}/${data.length}` } : {}) });
      const payload = data.subarray(start, end + 1);
      if (query.apikey === 'fixture-buffering' && path.includes('/movie-1/') && payload.length > 260000) {
        response.write(payload.subarray(0, 260000));
        const timer = setTimeout(() => response.end(payload.subarray(260000)), 6500);
        response.on('close', () => clearTimeout(timer));
      } else response.end(payload);
      return;
    }
    if (!user || user === 'expired') { send({}, 401); return; }
    if (demo && await demo.handle({ path, query, user, state, send })) return;
    if (user === 'slow') await new Promise(resolve => setTimeout(resolve, 700));
    if (user === 'flaky' && path === '/Items/Latest' && state.failures++ === 0) { send({}, 503); return; }
    const episodeMode = state.episodeModes.get(user) ?? {};
    const isRecentEpisodes = path === '/Items' && query.includeitemtypes === 'Episode' && query.sortby === 'DateCreated';
    const otherHome = path === '/UserItems/Resume' || path === '/Shows/NextUp' || path === '/Items/Latest' && ['Movie', 'Series'].includes(query.includeitemtypes);
    if ((episodeMode.allFail && (isRecentEpisodes || otherHome)) || episodeMode.baseFail && otherHome) { send({}, 503); return; }
    if (isRecentEpisodes) {
      const receipt = { id: randomUUID(), counter: ++state.episodeCounter, user, holdId: episodeMode.holdId ?? null, phase: 'started', query: { ...query } };
      state.episodeRequests.push(receipt);
      state.episodeEvents.push({ event: 'started', ...receipt });
      const gate = state.episodeHolds.get(episodeMode.holdId);
      let timedOut = false;
      if (gate && !gate.released) {
        receipt.phase = 'held'; state.episodeEvents.push({ event: 'held', requestId: receipt.id, counter: receipt.counter, user, holdId: receipt.holdId });
        await new Promise(resolve => {
          let done = false;
          const finish = () => { if (done) return; done = true; clearTimeout(timer); gate.waiters.delete(receipt.id); resolve(); };
          const timer = setTimeout(() => { timedOut = true; finish(); }, 12000);
          gate.waiters.set(receipt.id, finish);
          response.once('close', finish);
        });
      }
      if (episodeMode.delayMs) await new Promise(resolve => setTimeout(resolve, episodeMode.delayMs));
      if (response.destroyed) { receipt.phase = 'cancelled'; state.episodeCancellations++; state.episodeEvents.push({ event: 'cancelled', requestId: receipt.id, counter: receipt.counter, user, holdId: receipt.holdId }); return; }
      const code = timedOut ? 504 : episodeMode.fail ? 503 : 200;
      receipt.phase = 'responded'; receipt.status = code;
      state.episodeEvents.push({ event: timedOut ? 'hold-timeout' : 'responded', requestId: receipt.id, counter: receipt.counter, user, holdId: receipt.holdId, status: code });
      if (code !== 200) { send({}, code); return; }
      if (episodeMode.malformed) { send({ Items: [{ Id: 'series-group', Name: 'Unexpected parent', Type: 'Series' }] }); return; }
      const values = filterFixtureItems(episodeMode.empty ? [] : recentEpisodes(user, episodeMode.episodeOrder), query);
      values.sort((a, b) => Date.parse(b.DateCreated) - Date.parse(a.DateCreated));
      const start = Number(query.startindex ?? 0); send({ Items: values.slice(start, start + Number(query.limit ?? 18)), TotalRecordCount: values.length }); return;
    }
    if (episodeMode.othersEmpty && otherHome) { send(path === '/Items/Latest' ? [] : { Items: [] }); return; }
    let items = catalog(user);
    if (path === '/UserViews') { send({ Items: fixtureLibraries, TotalRecordCount: fixtureLibraries.length }); return; }
    if (path === '/Genres') { const values = fixtureGenres([...items, ...recentEpisodes(user)], query); send({ Items: values, TotalRecordCount: values.length }); return; }
    if (/\/Images\//.test(path)) {
      if (user === 'cancel-art') {
        response.writeHead(200, { 'Content-Type': 'image/svg+xml' });
        response.write('<svg xmlns="http://www.w3.org/2000/svg" width="600" height="900">');
        const timer = setTimeout(() => response.end('<rect width="600" height="900" fill="blue"/></svg>'), 10000);
        response.on('close', () => { clearTimeout(timer); if (!response.writableEnded) state.artworkCancellations++; });
        return;
      }
      if (user === 'missingart') { send({}, 404); return; }
      const n = Number(/\d+/.exec(path)?.[0] ?? 1) % 6, backdrop = path.endsWith('/Backdrop');
      const title = names[n];
      for (const [extension, type] of [['jpg', 'image/jpeg'], ['png', 'image/png']]) {
        const optional = resolve(media, 'artwork', `${backdrop ? 'backdrop' : 'poster'}-${n}.${extension}`);
        try { await stat(optional); send(await readFile(optional), 200, type); return; } catch { /* Try the next optional format, then the self-contained artwork below. */ }
      }
      const w = backdrop ? 1440 : 600, h = backdrop ? 810 : 900;
      const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><defs><linearGradient id="a" x2="1" y2="1"><stop stop-color="${colors[n]}"/><stop offset="1" stop-color="#0b1823"/></linearGradient></defs><rect width="100%" height="100%" fill="url(#a)"/><circle cx="${w * .72}" cy="${h * .32}" r="${h * .22}" fill="#bad8dc" opacity=".18"/><path d="M0 ${h * .8} ${w * .35} ${h * .32} ${w * .8} ${h}H0z" fill="#152c39"/><path d="M${w * .35} ${h} ${w * .7} ${h * .42} ${w} ${h * .8}V${h}z" fill="#0c202d"/>${!backdrop ? `<text x="40" y="${h * .77}" fill="#eaf4f7" font-family="Arial,sans-serif" font-size="42" font-weight="700">${title.split(' ').slice(0, 3).join(' ')}</text><text x="40" y="${h * .84}" fill="#b3d2df" font-family="Arial,sans-serif" font-size="15" letter-spacing="4">REEL TEST LIBRARY</text>` : ''}</svg>`;
      send(Buffer.from(svg), 200, 'image/svg+xml'); return;
    }
    if (path === '/Items/Latest' && query.includeitemtypes === 'Episode') {
      const values = recentEpisodes(user).sort((a, b) => Date.parse(b.DateCreated) - Date.parse(a.DateCreated));
      send(query.groupitems === 'false' ? values : values.length ? [{ Id: 'series-7', Name: 'Out of the Blue', Type: 'Series', ChildCount: values.length }] : []); return;
    }
    if (path === '/Items/Latest') { send(items.filter(item => item.Type === query.includeitemtypes).slice(0, 18)); return; }
    if (path === '/UserItems/Resume') { send({ Items: items.length ? [episode(1, user), { ...items[3], UserData: { ...items[3].UserData, PlaybackPositionTicks: 3 * TICKS } }] : [] }); return; }
    if (path === '/Shows/NextUp') { send({ Items: items.length ? [episode(2, user)] : [] }); return; }
    if (path.endsWith('/Seasons')) { send({ Items: [1, 2].map(n => ({ Id: 'season-' + n, Name: 'Season ' + n, Type: 'Season', SeriesId: 'series-7', IndexNumber: n })) }); return; }
    if (path.endsWith('/Episodes')) {
      const all = query.adjacentto ? [1, 2].flatMap(season => [1, 2, 3].map(n => episode(n, user, season))) : [1, 2, 3].map(n => episode(n, user, Number(query.seasonid?.split('-').at(-1) ?? 1)));
      const index = all.findIndex(item => item.Id === query.adjacentto);
      const values = query.adjacentto ? index >= 0 ? all.slice(Math.max(0, index - 1), index + 2) : [] : all;
      const start = Number(query.startindex ?? 0);
      send({ Items: values.slice(start, start + Number(query.limit ?? values.length)), TotalRecordCount: values.length }); return;
    }
    if (path.startsWith('/MediaSegments/')) {
      const id = path.split('/').at(-1);
      if (user === 'segments-unavailable') { send({ error: 'No segment provider' }, 404); return; }
      if (user.startsWith('intro-scan')) { send({ Items: [] }); return; }
      send({ Items: id.startsWith('episode-') ? [{ Id: 'intro-' + id, ItemId: id, Type: 'Intro', StartTicks: 1 * TICKS, EndTicks: 5 * TICKS }] : [] }); return;
    }
    if (path.endsWith('/PlaybackInfo')) {
      state.reports.push({ path, user, body });
      const id = path.split('/')[2]; send({ MediaSources: [{ ...source(id), Id: body.MediaSourceId ?? id + '-source', SupportsDirectPlay: !!body.EnableDirectPlay && body.MaxStreamingBitrate > 2_000_000, TranscodingUrl: `/Videos/${id}/master.m3u8` }], PlaySessionId: 'session-' + Math.random().toString(16).slice(2) }); return;
    }
    if (path.startsWith('/Sessions/Playing')) { state.reports.push({ path, user, body }); state.positions.set(user + '|' + body.ItemId, body.PositionTicks ?? 0); send(); return; }
    if (path.startsWith('/UserFavoriteItems/')) { state.favorites.set(user + '|' + path.split('/').at(-1), request.method === 'POST'); send(); return; }
    if (path.startsWith('/UserPlayedItems/')) { state.watched.set(user + '|' + path.split('/').at(-1), request.method === 'POST'); send(); return; }
    if (path === '/Items') {
      if (query.includeitemtypes?.includes('Episode')) items.push(...[1, 2, 3].map(n => episode(n, user)));
      items = filterFixtureItems(items, query);
      items = sortFixtureItems(items, query.sortby, query.sortorder);
      const total = items.length, start = Number(query.startindex ?? 0); send({ Items: items.slice(start, start + Number(query.limit ?? 60)), TotalRecordCount: total }); return;
    }
    if (path.startsWith('/Items/')) {
      if (path === '/Items/book-1/Download') {
        if (user === 'book-timeout' && state.bookFailures++ === 0) {
          const data = bookPDF(); response.writeHead(200, { 'Content-Type': 'application/pdf' }); response.write(data.subarray(0, 20));
          const timer = setTimeout(() => response.end(data.subarray(20)), 25000);
          response.on('close', () => clearTimeout(timer)); return;
        }
        send(bookPDF(), 200, 'application/pdf'); return;
      }
      const id = path.split('/')[2];
      const item = id === 'channel-1' ? { Id: id, Name: 'Reel Live', Type: 'TvChannel', MediaSources: [source(id)] } : id.startsWith('episode-') ? episode(Number(id.split('-')[2]), user, Number(id.split('-')[1])) : items.find(item => item.Id === id);
      send(item ?? {}, item ? 200 : 404); return;
    }
    if (path === '/LiveTv/Channels') { send({ Items: [{ Id: 'channel-1', Name: 'Reel Live', Type: 'TvChannel', MediaSources: [source('channel-1')] }] }); return; }
    if (path === '/LiveTv/Recordings') { send({ Items: [] }); return; }
    if (path === '/Sessions') { send([{ Id: 'receiver-1', DeviceName: 'Fixture living room', Client: 'Reel', UserName: user, SupportsRemoteControl: true }]); return; }
    if (path === '/Sessions/Logout' || path === '/Videos/ActiveEncodings' || path === '/LiveStreams/Close') { send(); return; }
    send({}, 404);
  } catch { if (!response.headersSent) send({ error: 'Fixture resource unavailable' }, 500); else response.end(); }
});
server.listen(port, '127.0.0.1', () => console.log(`Disposable Reel ${demo ? 'demo library' : 'fixture'}: http://127.0.0.1:${port}. Media directory: ${media}`));
