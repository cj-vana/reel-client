import { app, autoUpdater, BrowserWindow, Menu, dialog, net, protocol, session, ipcMain, safeStorage, shell } from 'electron';
import { readFile, mkdir, lstat } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { randomUUID } from 'node:crypto';
import { installBridge } from './bridge.mjs';
import { installBrowseBridge } from './browse-bridge.mjs';
import { BrowseOwner } from './browse-owner.mjs';
import { CloseGate } from './lifecycle.mjs';
import { DesktopStore } from './store.mjs';
import { desktopCryptoProvider } from './crypto-provider.mjs';
import { installFullscreenSync } from './fullscreen-sync.mjs';
import { loadAssets, assetResponse } from './assets.mjs';
import { assertQAProfile } from './qa-profile.mjs';
import { APP_URL, isOwnedDocument, windowOptions, allowFullscreenRequest, allowFullscreenCheck } from './policy.mjs';
import { UpdateService } from './updates.mjs';
import { installUpdatesBridge } from './updates-bridge.mjs';

protocol.registerSchemesAsPrivileged([{ scheme: 'reel', privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true } }]);
const flavor = JSON.parse(await readFile(resolve(import.meta.dirname, '../build-flavor.json'), 'utf8'));
const qa = flavor.qa === true;
const qaVisible = qa && process.argv.includes('--reel-qa-visible');
let qaProfile, qaOwner;
app.setName(qa ? 'Reel Desktop QA' : 'Reel Client Desktop');
if (qa) process.on('uncaughtException', error => { console.error('QA process error: ' + error.name); app.exit(1); });
app.setAppUserModelId(qa ? 'app.reelclient.desktop.qa' : 'app.reelclient.desktop');
for (const option of ['remote-debugging-port', 'remote-debugging-pipe', 'remote-debugging-address', 'inspect', 'inspect-brk']) app.commandLine.removeSwitch(option);
if (qa) {
  const profile = process.argv.find(value => value.startsWith('--reel-qa-profile='))?.slice('--reel-qa-profile='.length);
  const owner = process.argv.find(value => value.startsWith('--reel-qa-owner='))?.slice('--reel-qa-owner='.length);
  await assertQAProfile(profile, tmpdir(), owner, { checkContents: false });
  qaProfile = profile; qaOwner = owner;
  const sessionPath = join(profile, 'chromium');
  try { if (!(await lstat(sessionPath)).isDirectory() || (await lstat(sessionPath)).isSymbolicLink()) throw new Error('Invalid private session directory'); }
  catch (error) { if (error.code !== 'ENOENT') throw error; await mkdir(sessionPath, { mode: 0o700 }); }
  app.setPath('userData', profile); app.setPath('sessionData', sessionPath);
  const port = process.argv.find(value => value.startsWith('--reel-qa-port='))?.slice('--reel-qa-port='.length);
  if (!/^\d{5}$/.test(port ?? '') || Number(port) < 19000 || Number(port) > 19999) throw new Error('QA requires its scoped loopback debug port');
  app.commandLine.appendSwitch('remote-debugging-address', '127.0.0.1');
  app.commandLine.appendSwitch('remote-debugging-port', port);
  app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required');
  app.commandLine.appendSwitch('mute-audio');
} else {
  const dataPath = join(app.getPath('appData'), 'Reel Client Desktop'), sessionPath = join(dataPath, 'chromium');
  await mkdir(sessionPath, { recursive: true, mode: 0o700 });
  app.setPath('userData', dataPath);
  app.setPath('sessionData', sessionPath);
}
const primary = app.requestSingleInstanceLock();
if (!primary) app.quit();
else {
  if (qa) await assertQAProfile(qaProfile, tmpdir(), qaOwner);
  // The owner outlives every macOS window. A new window cannot clear an uncertain commit.
  const store=new DesktopStore(join(app.getPath('userData'),'secure-store'),desktopCryptoProvider({qa,platform:process.platform,safeStorage}));
  const browseOwner=new BrowseOwner(app.getPath('userData'),store);
  // QA builds never contact anything but loopback, so they do not check for updates.
  const updates = qa ? undefined : new UpdateService({
    version: app.getVersion(), arch: process.arch, install: flavor.signed === true && process.platform === 'darwin',
    fetch: (url, options) => net.fetch(url, options), updater: autoUpdater, openExternal: url => shell.openExternal(url),
    enabled: () => store.preferences?.updates !== false
  });
  let window, assets, ses, quitting = false, crashRestarts = 0, lastCrash = 0;
  function createWindow() {
    // macOS: content runs under an inset title bar; the web layout clears the traffic lights and marks drag regions.
    const chrome = process.platform === 'darwin' ? { titleBarStyle: 'hiddenInset', trafficLightPosition: { x: 18, y: 16 } } : {};
    window = new BrowserWindow({ ...windowOptions('reel-' + randomUUID(), resolve(import.meta.dirname, 'preload.cjs')), ...chrome });
    const ownedWindow=window,browseBridge=installBrowseBridge(ownedWindow,browseOwner,ipcMain);
    const bridge=installBridge(ownedWindow,store,ipcMain,{saveConnections:(value,context)=>browseOwner.commitConnections(value,context),closeResources:()=>browseBridge.beginClose()});
    if (updates) installUpdatesBridge(ownedWindow, updates, ipcMain);
    let allowedClose = false;
    const closeGate = new CloseGate({ request: () => bridge.requestClose(), finish: () => { allowedClose = true; if (!ownedWindow.isDestroyed()) ownedWindow.close(); if (quitting) app.quit(); } });
    ownedWindow.on('close', event => { if (!allowedClose) { event.preventDefault(); closeGate.begin(); } });
    // Reuse the one memory-only session after macOS closes its last window.
    if (ses) throw new Error('Session must be established before creating a window');
    ses = window.webContents.session;
    ses.protocol.handle('reel', request => assetResponse(assets, request));
    // User-initiated fullscreen belongs only to this window's verified main document.
    // Automatic fullscreen and every device, capture, notification or external permission stay denied.
    ses.setPermissionRequestHandler((contents, permission, callback, details) => callback(allowFullscreenRequest(contents, ownedWindow.webContents, permission, details)));
    ses.setPermissionCheckHandler((contents, permission, origin, details) => allowFullscreenCheck(contents, ownedWindow.webContents, permission, origin, details));
    ses.setDevicePermissionHandler(() => false);
    ses.setDisplayMediaRequestHandler((_request, callback) => callback({}));
    ses.on('will-download', event => event.preventDefault());
    if (qa) ses.webRequest.onBeforeRequest((details, callback) => {
      const url = new URL(details.url);
      callback({ cancel: !['reel:', 'blob:', 'data:'].includes(url.protocol) && !(url.protocol === 'http:' && ['127.0.0.1', 'localhost'].includes(url.hostname)) });
    });
    const contents = window.webContents;
    installFullscreenSync(ownedWindow);
    if (qa) for (const event of ['enter-full-screen', 'leave-full-screen']) ownedWindow.on(event, () => {
      if (!ownedWindow.isDestroyed()) console.log('REEL_QA_WINDOW ' + JSON.stringify({ event, fullscreen: ownedWindow.isFullScreen(), bounds: ownedWindow.getBounds(), contentBounds: ownedWindow.getContentBounds() }));
    });
    contents.setWindowOpenHandler(() => ({ action: 'deny' }));
    contents.on('will-navigate', (event, url) => { if (!isOwnedDocument(url)) event.preventDefault(); });
    contents.on('will-redirect', event => event.preventDefault());
    contents.on('will-attach-webview', event => event.preventDefault());
    contents.on('render-process-gone', () => {
      if (quitting || window?.isDestroyed()) return;
      if (Date.now() - lastCrash > 60000) crashRestarts = 0;
      lastCrash = Date.now();
      if (crashRestarts++ === 0) void contents.loadURL(APP_URL);
      else { dialog.showErrorBox('Reel could not open', 'The app stopped responding. Quit and reopen Reel to try again.'); window.destroy(); }
    });
    window.once('ready-to-show', () => { if (!qa || qaVisible) window.show(); });
    window.on('closed', () => { window = undefined; ses.protocol.unhandle('reel'); ses = undefined; });
    void contents.loadURL(APP_URL);
  }
  app.on('second-instance', () => { if (window) { if (window.isMinimized()) window.restore(); if (!qa) window.focus(); } });
  app.on('certificate-error', (event, _contents, _url, _error, _certificate, callback) => { event.preventDefault(); callback(false); });
  app.on('before-quit', () => { quitting = true; });
  // Restarting into an update closes the window through the usual close handshake, then quits.
  autoUpdater.on('before-quit-for-update', () => { quitting = true; });
  app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
  app.on('activate', () => { if (!window && assets) createWindow(); });
  async function bootstrap() {
  try {
    assets = await loadAssets(resolve(import.meta.dirname, '../web'));
    await app.whenReady();
    if (qa && !qaVisible && app.dock) app.dock.hide();
    Menu.setApplicationMenu(Menu.buildFromTemplate([
      ...(process.platform === 'darwin' ? [{ label: 'Reel', submenu: [{ role: 'about' }, { type: 'separator' }, { role: 'hide' }, { role: 'hideOthers' }, { role: 'unhide' }, { type: 'separator' }, { role: 'quit' }] }] : []),
      { label: 'Edit', submenu: [{ role: 'undo' }, { role: 'redo' }, { type: 'separator' }, { role: 'cut' }, { role: 'copy' }, { role: 'paste' }, { role: 'selectAll' }] },
      { label: 'Window', submenu: [{ role: 'minimize' }, { role: 'zoom' }, { role: 'togglefullscreen' }, { role: 'close' }, ...(process.platform !== 'darwin' ? [{ role: 'quit' }] : [])] }
    ]));
    createWindow();
    updates?.start();
  } catch (error) {
    if (qa) { console.error('QA startup verification failed: ' + error.name); app.exit(1); }
    await app.whenReady();
    dialog.showErrorBox('Reel could not open', 'Application files could not be verified. Install a fresh copy from the project release.');
    app.quit();
  }
  }
  void bootstrap();
}
