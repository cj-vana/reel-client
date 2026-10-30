import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdtemp, mkdir, cp, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash, webcrypto } from 'node:crypto';
import { runInNewContext } from 'node:vm';
import { pwaEligible } from '../src/pwa.ts';
import { reelPWA, publicShell } from '../src/pwa-build.mjs';

const template = await readFile(new URL('../src/pwa-worker.js', import.meta.url), 'utf8');
const digest = (value: string | Uint8Array) => createHash('sha256').update(value).digest('hex');
async function worker({ base = 'https://reel.example/app/', corrupt = false, windows = [] as Array<{ id: string; url: string }> } = {}) {
  const content = new Map([['index.html', '<main>owned shell</main>'], ['assets/app-abcd.js', 'console.log("owned")']]);
  const entries = [...content].map(([path, bytes]) => ({ path, sha256: digest(bytes) }));
  const cachesData = new Map<string, Map<string, Response>>(), requests: Request[] = [], handlers = new Map<string, (event: any) => void>();
  let claims = 0, skips = 0;
  const cacheStorage = {
    async open(name: string) { const values = cachesData.get(name) ?? new Map(); cachesData.set(name, values); return { async put(url: string, response: Response) { values.set(url, response.clone()); }, async match(url: string) { return values.get(url)?.clone(); } }; },
    async keys() { return [...cachesData.keys()]; }, async delete(name: string) { return cachesData.delete(name); }
  };
  runInNewContext(template.replace('__REEL_ASSETS__', JSON.stringify(entries)).replace('__REEL_REVISION__', '"test-revision"'), {
    URL, Map, Request, Response, crypto: webcrypto, caches: cacheStorage,
    fetch: async (request: Request) => {
      requests.push(request); const path = request.url.slice(base.length); const body = content.get(path);
      const response = new Response(corrupt ? 'wrong build' : body ?? 'uncached network', { status: 200 });
      Object.defineProperty(response, 'url', { value: request.url }); return response;
    },
    self: { registration: { scope: base }, addEventListener(type: string, handler: (event: any) => void) { handlers.set(type, handler); }, clients: { async claim() { claims++; }, async matchAll() { return windows; } }, async skipWaiting() { skips++; } }
  });
  async function fire(type: string, input: object = {}) {
    let pending: Promise<unknown> | undefined, response: Promise<Response> | undefined;
    handlers.get(type)!({ ...input, waitUntil(value: Promise<unknown>) { pending = value; }, respondWith(value: Promise<Response>) { response = value; } });
    await pending; return response ? await response : undefined;
  }
  return { fire, requests, cachesData, cacheStorage, get claims() { return claims; }, get skips() { return skips; }, prefix: 'reel-shell-v1:' + encodeURIComponent(base) + ':' };
}

test('PWA registration is restricted to secure production web, never native hosts or development', () => {
  assert.equal(pwaEligible('web', true, true, 'https:'), true); assert.equal(pwaEligible('web', true, true, 'http:'), true);
  for (const platform of ['desktop', 'webos', 'tizen'] as const) assert.equal(pwaEligible(platform, true, true, 'https:'), false);
  assert.equal(pwaEligible('web', false, true, 'https:'), false); assert.equal(pwaEligible('web', true, false, 'http:'), false); assert.equal(pwaEligible('web', true, true, 'file:'), false);
});
test('manifest uses relative app identity/scope and real existing brand icon sizes', async () => {
  const manifest = JSON.parse(await readFile(new URL('../public/manifest.webmanifest', import.meta.url), 'utf8'));
  assert.equal(manifest.id, './'); assert.equal(manifest.start_url, './'); assert.equal(manifest.scope, './'); assert.equal(manifest.display, 'standalone');
  for (const size of [192, 512]) {
    const entry = manifest.icons.find((icon: { sizes: string }) => icon.sizes === `${size}x${size}`); assert.equal(entry.type, 'image/png');
    const bytes = await readFile(new URL('../public/' + entry.src, import.meta.url)); assert.equal(bytes.readUInt32BE(16), size); assert.equal(bytes.readUInt32BE(20), size);
  }
});
test('real Vite build worker pins final module-preload bytes and explicitly enumerated public files', async () => {
  const source = new URL('..', import.meta.url).pathname, root = await mkdtemp(resolve(tmpdir(), 'reel-pwa-build-'));
  try {
    await mkdir(resolve(root, 'src')); await cp(resolve(source, 'public'), resolve(root, 'public'), { recursive: true });
    for (const name of ['pwa-build.mjs', 'pwa-worker.js']) await cp(resolve(source, 'src', name), resolve(root, 'src', name));
    await symlink(resolve(source, 'node_modules'), resolve(root, 'node_modules'), 'dir');
    await writeFile(resolve(root, 'vite.config.mjs'), "import {reelPWA} from './src/pwa-build.mjs'; export default {base:'./',plugins:[reelPWA()]};");
    await writeFile(resolve(root, 'index.html'), '<script type="module" src="/src/main.js"></script>');
    await writeFile(resolve(root, 'src/main.js'), "window.loadOwned=()=>import('./lazy.js');"); await writeFile(resolve(root, 'src/lazy.js'), 'export const value = 42;');
    const build = spawnSync(process.execPath, [resolve(source, 'node_modules/vite/bin/vite.js'), 'build', root], { encoding: 'utf8' });
    assert.equal(build.status, 0, build.stdout + build.stderr);
    const script = await readFile(resolve(root, 'dist/reel-sw.js'), 'utf8');
    const assets = JSON.parse(/const ASSETS = (.*);/.exec(script)![1]);
    for (const asset of assets) assert.equal(asset.sha256, digest(await readFile(resolve(root, 'dist', asset.path))), asset.path);
    for (const name of publicShell) assert.ok(assets.some((asset: { path: string }) => asset.path === name));
    assert.ok(!script.includes('__REEL_ASSETS__')); assert.ok(!script.includes('__REEL_REVISION__'));
    await writeFile(resolve(root, 'dist/secret.json'), '{}');
    const plugin = reelPWA() as any; plugin.configResolved({ root });
    await assert.rejects(plugin.writeBundle({ dir: resolve(root, 'dist') }, { 'secret.json': {} }), /Unreviewed/);
  } finally { await rm(root, { recursive: true, force: true }); }
});
test('installation verifies all build bytes before caching and fetches without credentials', async () => {
  const run = await worker(); await run.fire('install');
  assert.equal(run.cachesData.size, 1); assert.equal([...run.cachesData.values()][0].size, 2);
  assert.equal(run.requests.length, 2); for (const request of run.requests) { assert.equal(request.credentials, 'omit'); assert.equal(request.redirect, 'error'); assert.equal(request.cache, 'reload'); }
});
test('failed install retains previous version and unrelated caches', async () => {
  const run = await worker({ corrupt: true }); run.cachesData.set(run.prefix + 'previous', new Map()); run.cachesData.set('another-app', new Map());
  await assert.rejects(run.fire('install'), /integrity/); assert.deepEqual([...run.cachesData.keys()], [run.prefix + 'previous', 'another-app']);
});
test('activation cleanup is isolated to the registration scope namespace', async () => {
  const run = await worker(); await run.fire('install'); run.cachesData.set(run.prefix + 'old', new Map()); run.cachesData.set('reel-shell-v1:' + encodeURIComponent('https://reel.example/another/') + ':old', new Map()); run.cachesData.set('other-app', new Map());
  await run.fire('activate'); assert.equal(run.claims, 1); assert.equal(run.cachesData.size, 3); assert.ok(!run.cachesData.has(run.prefix + 'old')); assert.ok(run.cachesData.has('other-app'));
});
test('only exact shell URLs and canonical shell navigation are intercepted', async () => {
  const run = await worker(); await run.fire('install');
  const before = run.requests.length;
  assert.equal(await (await run.fire('fetch', { request: new Request('https://reel.example/app/assets/app-abcd.js') }))!.text(), 'console.log("owned")');
  const navigation = new Request('https://reel.example/app/'); Object.defineProperty(navigation, 'mode', { value: 'navigate' });
  assert.equal(await (await run.fire('fetch', { request: navigation }))!.text(), '<main>owned shell</main>');
  assert.equal(run.requests.length, before);
  for (const url of ['https://reel.example/app/Items/1', 'https://reel.example/app/artwork.jpg', 'https://reel.example/app/video.mp4', 'https://media.example/Items/1', 'https://reel.example/app/index.html?api_key=secret', 'https://reel.example/app/unknown']) assert.equal(await run.fire('fetch', { request: new Request(url) }), undefined);
  assert.equal([...run.cachesData.values()][0].size, 2);
});
test('authorization, range and all writes bypass even an exact shell path', async () => {
  const run = await worker(); await run.fire('install');
  for (const headers of [{ Authorization: 'synthetic' }, { 'X-Emby-Authorization': 'synthetic' }, { 'X-Emby-Token': 'synthetic' }, { Range: 'bytes=0-10' }]) assert.equal(await run.fire('fetch', { request: new Request('https://reel.example/app/index.html', { headers }) }), undefined);
  for (const method of ['POST', 'PUT', 'PATCH', 'DELETE', 'HEAD']) assert.equal(await run.fire('fetch', { request: new Request('https://reel.example/app/index.html', { method }) }), undefined);
});
test('a shell cache miss never stores an unverified network result', async () => {
  const run = await worker(); assert.ok(await run.fire('fetch', { request: new Request('https://reel.example/app/index.html') })); assert.equal([...run.cachesData.values()][0].size, 0);
});
test('activation requires an owned document and refuses another open Reel window', async () => {
  const replies: unknown[] = [];
  const run = await worker({ windows: [{ id: 'one', url: 'https://reel.example/app/' }, { id: 'two', url: 'https://reel.example/app/index.html' }] });
  await run.fire('message', { data: { type: 'REEL_ACTIVATE', expiresAt: Date.now() + 4000 }, source: { id: 'one', url: 'https://reel.example/app/' }, ports: [{ postMessage(value: unknown) { replies.push(value); } }] });
  assert.equal((replies[0] as any).accepted, false); assert.equal(run.skips, 0);
  await run.fire('message', { data: { type: 'REEL_ACTIVATE', expiresAt: Date.now() + 4000 }, source: { id: 'one', url: 'https://reel.example/api' }, ports: [] }); assert.equal(run.skips, 0);
});
test('explicit activation from the only app window permits the waiting worker', async () => {
  const run = await worker({ windows: [{ id: 'one', url: 'https://reel.example/app/' }] }); let accepted = false;
  await run.fire('message', { data: { type: 'REEL_ACTIVATE', expiresAt: Date.now() + 4000 }, source: { id: 'one', url: 'https://reel.example/app/' }, ports: [{ postMessage(value: { accepted: boolean }) { accepted = value.accepted; } }] });
  assert.equal(accepted, true); assert.equal(run.skips, 1);
});
test('query, hash and nested in-scope clients block activation independently of the strict cache URL policy', async () => {
  for (const url of ['https://reel.example/app/?source=bookmark', 'https://reel.example/app/index.html#watching', 'https://reel.example/app/nested?view=watching']) {
    const run = await worker({ windows: [{ id: 'one', url: 'https://reel.example/app/?launch=1' }, { id: 'two', url }] }); let accepted: boolean | undefined;
    await run.fire('message', { data: { type: 'REEL_ACTIVATE', expiresAt: Date.now() + 4000 }, source: { id: 'one', url: 'https://reel.example/app/?launch=1' }, ports: [{ postMessage(value: { accepted: boolean }) { accepted = value.accepted; } }] });
    assert.equal(accepted, false); assert.equal(run.skips, 0);
  }
});
test('a delayed activation request expires before it can replace the active worker', async () => {
  const run = await worker({ windows: [{ id: 'one', url: 'https://reel.example/app/' }] }); let accepted: boolean | undefined;
  await run.fire('message', { data: { type: 'REEL_ACTIVATE', expiresAt: Date.now() - 1 }, source: { id: 'one', url: 'https://reel.example/app/' }, ports: [{ postMessage(value: { accepted: boolean }) { accepted = value.accepted; } }] });
  assert.equal(accepted, false); assert.equal(run.skips, 0);
});
