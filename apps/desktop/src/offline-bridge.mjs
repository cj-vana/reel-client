import { readFile } from 'node:fs/promises';
import { APP_URL, SECURITY_HEADERS } from './policy.mjs';
import { validRequest } from './offline.mjs';
export const OFFLINE_CHANNEL = 'reel:offline:v1';
export const OFFLINE_CHANGED_CHANNEL = 'reel:offline:changed:v1';
const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const TYPES = { m3u8: 'application/vnd.apple.mpegurl', ts: 'video/mp2t', jpg: 'image/jpeg' };

// The window's own document may list, start and remove downloads for an account, and save where playback
// stopped. Each operation takes exactly its own fields.
export function installOfflineBridge(window, downloads, ipcMain, { allowServer = () => true } = {}) {
  const contents = window.webContents;
  const valid = event => {
    try { return !window.isDestroyed() && !contents.isDestroyed() && event.sender === contents && event.senderFrame === contents.mainFrame && event.senderFrame.url === APP_URL; }
    catch { return false; }
  };
  const exact = (message, keys) => Object.keys(message).length === keys.length && keys.every(key => Object.hasOwn(message, key));
  const account = value => typeof value === 'string' && value.length > 0 && value.length <= 2600;
  const handle = async (event, message) => {
    if (!valid(event) || !message || typeof message !== 'object' || Array.isArray(message)) return { ok: false, code: 'invalid' };
    if (message.operation === 'list' && exact(message, ['operation', 'accountId']) && account(message.accountId)) return { ok: true, items: downloads.list(message.accountId) };
    if (message.operation === 'start' && exact(message, ['operation', 'request']) && validRequest(message.request)) {
      if (!allowServer(message.request.server)) return { ok: false, code: 'invalid' };
      return { ok: true, item: await downloads.start(message.request) };
    }
    if (message.operation === 'remove' && exact(message, ['operation', 'accountId', 'id']) && account(message.accountId) && ID.test(message.id)) return { ok: await downloads.remove(message.accountId, message.id) };
    if (message.operation === 'forget' && exact(message, ['operation', 'accountId']) && account(message.accountId)) { await downloads.forget(message.accountId); return { ok: true }; }
    if (message.operation === 'position' && exact(message, ['operation', 'accountId', 'id', 'seconds']) && account(message.accountId) && ID.test(message.id)) return { ok: await downloads.setPosition(message.accountId, message.id, message.seconds) };
    return { ok: false, code: 'invalid' };
  };
  ipcMain.handle(OFFLINE_CHANNEL, (event, message) => handle(event, message).catch(() => ({ ok: false, code: 'io' })));
  const unsubscribe = downloads.subscribe(() => { if (!contents.isDestroyed()) contents.send(OFFLINE_CHANGED_CHANNEL); });
  window.once('closed', () => { unsubscribe(); ipcMain.removeHandler(OFFLINE_CHANNEL); });
}

/** A finished download's playlist, segment or artwork at reel://app/offline/<id>/<file>; undefined for other paths. */
export async function offlineResponse(downloads, request) {
  const url = new URL(request.url), match = /^\/offline\/([^/]+)\/([^/]+)$/.exec(url.pathname);
  if (url.protocol !== 'reel:' || url.host !== 'app' || !match) return undefined;
  const file = ID.test(match[1]) ? downloads.file(match[1], match[2]) : undefined;
  if (!file || !['GET', 'HEAD'].includes(request.method)) return new Response('Not found', { status: 404, headers: { ...SECURITY_HEADERS, 'Content-Type': 'text/plain; charset=utf-8' } });
  const bytes = await readFile(file);
  return new Response(request.method === 'HEAD' ? null : bytes, { headers: { ...SECURITY_HEADERS, 'Content-Type': TYPES[file.split('.').pop()], 'Content-Length': String(bytes.length) } });
}
