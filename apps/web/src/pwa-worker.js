/* Only build-enumerated public shell files belong in this cache. Never add a runtime cache. */
const ASSETS = __REEL_ASSETS__;
const REVISION = __REEL_REVISION__;
const scope = new URL(self.registration.scope);
const prefix = 'reel-shell-v1:' + encodeURIComponent(scope.href) + ':';
const cacheName = prefix + REVISION;
const shell = new Map(ASSETS.map(asset => [new URL(asset.path, scope).href, asset]));
const indexURL = new URL('index.html', scope).href;
const appDocument = value => {
  const url = new URL(value);
  return !url.search && (url.href === scope.href || url.href === indexURL);
};
const scopedClient = value => {
  const url = new URL(value);
  return url.origin === scope.origin && url.pathname.startsWith(scope.pathname);
};

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    try {
      const verified = await Promise.all(ASSETS.map(async asset => {
        const url = new URL(asset.path, scope).href;
        const response = await fetch(new Request(url, { credentials: 'omit', cache: 'reload', redirect: 'error' }));
        if (!response.ok || response.redirected || response.url !== url) throw new Error('Offline shell fetch failed');
        const bytes = await response.clone().arrayBuffer();
        const digest = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)), byte => byte.toString(16).padStart(2, '0')).join('');
        if (digest !== asset.sha256) throw new Error('Offline shell integrity failed');
        return [url, response];
      }));
      const cache = await caches.open(cacheName);
      for (const [url, response] of verified) await cache.put(url, response);
    } catch (error) {
      await caches.delete(cacheName);
      throw error;
    }
  })());
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    for (const name of await caches.keys()) if (name.startsWith(prefix) && name !== cacheName) await caches.delete(name);
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET' || request.headers.has('authorization') || request.headers.has('x-emby-authorization') || request.headers.has('x-emby-token') || request.headers.has('range')) return;
  const url = new URL(request.url);
  if (url.origin !== scope.origin || url.search) return;
  const key = request.mode === 'navigate' && appDocument(url.href) ? indexURL : url.href;
  if (!shell.has(key)) return;
  event.respondWith((async () => {
    const cached = await (await caches.open(cacheName)).match(key);
    // A cache miss must never add an unverified network response to the shell.
    return cached || fetch(request);
  })());
});

self.addEventListener('message', event => {
  if (event.data?.type !== 'REEL_ACTIVATE' || !event.source?.id || !scopedClient(event.source.url) || !event.ports[0]) return;
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const other = windows.some(client => client.id !== event.source.id && scopedClient(client.url));
    if (other) { event.ports[0].postMessage({ accepted: false, reason: 'other-windows' }); return; }
    if (!Number.isFinite(event.data.expiresAt) || event.data.expiresAt <= Date.now() || event.data.expiresAt > Date.now() + 10000) { event.ports[0].postMessage({ accepted: false, reason: 'expired' }); return; }
    event.ports[0].postMessage({ accepted: true });
    await self.skipWaiting();
  })());
});
