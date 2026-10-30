import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:net';
import { fileURLToPath } from 'node:url';

test('disposable browse metadata and filtered HTTP results describe the same catalog', async t => {
  const probe = createServer(); probe.listen(0, '127.0.0.1'); await once(probe, 'listening');
  const address = probe.address(); assert.ok(address && typeof address === 'object'); const port = address.port;
  await new Promise<void>((done, reject) => probe.close(error => error ? reject(error) : done()));
  const child = spawn(process.execPath, [fileURLToPath(new URL('../scripts/fixture-server.mjs', import.meta.url))], { env: { ...process.env, REEL_FIXTURE_PORT: String(port) }, stdio: ['ignore', 'pipe', 'pipe'] });
  t.after(async () => { if (child.exitCode === null && child.signalCode === null) { const closed = once(child, 'close'); child.kill('SIGTERM'); await closed; } });
  await new Promise<void>((done, reject) => {
    const timeout = setTimeout(() => reject(new Error('Fixture did not start')), 5000);
    child.once('error', error => { clearTimeout(timeout); reject(error); });
    child.once('exit', code => { clearTimeout(timeout); reject(new Error('Fixture exited: ' + code)); });
    child.stdout.on('data', chunk => { if (String(chunk).includes('Disposable Reel fixture:')) { clearTimeout(timeout); done(); } });
  });
  const request = (path: string, user: string | null = 'fixture-browse') => fetch(`http://127.0.0.1:${port}${path}`, { headers: user ? { Authorization: `MediaBrowser Token="fixture-${user}"` } : {}, signal: AbortSignal.timeout(5000) });
  const page = async (path: string, user?: string) => { const response = await request(path, user); assert.equal(response.status, 200); return response.json(); };
  await t.test('library and genre metadata require authentication and return usable choices', async () => {
    for (const path of ['/UserViews', '/Genres']) { const response = await request(path, null); assert.equal(response.status, 401); await response.arrayBuffer(); }
    const views = await page('/UserViews'); assert.equal(views.TotalRecordCount, 5); assert.ok(views.Items.some((item: any) => item.Id === 'library-movies' && item.Type === 'CollectionFolder'));
    const genres = await page('/Genres?includeItemTypes=Movie&parentId=library-movies'); assert.ok(genres.Items.some((item: any) => item.Id === 'genre-documentary'));
    assert.deepEqual((await page('/Genres?includeItemTypes=Movie&parentId=library-music')).Items, []);
  });
  await t.test('library and genre selection narrow rows, and pagination counts the filtered result', async () => {
    const movies = await page('/Items?parentId=library-movies&limit=200'); assert.ok(movies.Items.length > 60); assert.ok(movies.Items.every((item: any) => item.Type === 'Movie'));
    const filtered = await page('/Items?parentId=library-movies&genreIds=genre-documentary&limit=200');
    assert.ok(filtered.Items.length > 0 && filtered.Items.length < movies.Items.length); assert.ok(filtered.Items.every((item: any) => item.Genres.includes('Documentary')));
    const slice = await page('/Items?parentId=library-movies&genreIds=genre-documentary&startIndex=1&limit=2'); assert.equal(slice.TotalRecordCount, filtered.Items.length); assert.deepEqual(slice.Items.map((item: any) => item.Id), filtered.Items.slice(1, 3).map((item: any) => item.Id));
    const music = await page('/Items?parentId=album-1'); assert.deepEqual(music.Items.map((item: any) => item.Id), ['audio-1']);
  });
  await t.test('retired filter values return an honest empty page', async () => {
    for (const query of ['parentId=missing-library', 'genreIds=missing-genre', 'parentId=library-movies&includeItemTypes=Series']) {
      const result = await page('/Items?' + query); assert.deepEqual(result, { Items: [], TotalRecordCount: 0 });
    }
  });
  await t.test('recent episodes honor library and genre filters before paging', async () => {
    const result = await page('/Items?includeItemTypes=Episode&sortBy=DateCreated&parentId=library-series&genreIds=genre-drama&startIndex=1&limit=1');
    assert.equal(result.TotalRecordCount, 3); assert.equal(result.Items.length, 1); assert.equal(result.Items[0].Type, 'Episode');
    assert.deepEqual(await page('/Items?includeItemTypes=Episode&sortBy=DateCreated&parentId=library-movies'), { Items: [], TotalRecordCount: 0 });
    assert.deepEqual((await page('/Genres?parentId=library-series', 'empty')).Items, []);
  });
});
