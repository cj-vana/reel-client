import { APP_URL } from './policy.mjs';
export const UPDATES_CHANNEL = 'reel:updates:v1';
export const UPDATES_STATE_CHANNEL = 'reel:updates:state:v1';

// The window's own document may read the update state, check now, restart into a downloaded update, or open the
// release page. It cannot choose a URL, a feed or a file.
export function installUpdatesBridge(window, service, ipcMain) {
  const contents = window.webContents;
  const valid = event => {
    try { return !window.isDestroyed() && !contents.isDestroyed() && event.sender === contents && event.senderFrame === contents.mainFrame && event.senderFrame.url === APP_URL; }
    catch { return false; }
  };
  const handle = async (event, message) => {
    if (!valid(event) || !message || typeof message !== 'object' || Array.isArray(message) || Object.keys(message).length !== 1) return { ok: false, code: 'invalid' };
    if (message.operation === 'state') return { ok: true, state: service.state };
    if (message.operation === 'check') return { ok: true, state: await service.check({ manual: true }) };
    if (message.operation === 'install') return { ok: service.install() };
    if (message.operation === 'download') return { ok: await service.download() };
    return { ok: false, code: 'invalid' };
  };
  ipcMain.handle(UPDATES_CHANNEL, (event, message) => handle(event, message).catch(() => ({ ok: false, code: 'io' })));
  const unsubscribe = service.subscribe(state => { if (!contents.isDestroyed()) contents.send(UPDATES_STATE_CHANNEL, state); });
  window.once('closed', () => { unsubscribe(); ipcMain.removeHandler(UPDATES_CHANNEL); });
}
