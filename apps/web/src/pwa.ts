import type { RuntimePlatform } from './types.ts';

type InstallPrompt = Event & { prompt(): Promise<void>; userChoice: Promise<{ outcome: 'accepted' | 'dismissed' }> };
export type PWAOptions = { platform: RuntimePlatform; production: boolean; canUpdate(): boolean };
export function pwaEligible(platform: RuntimePlatform, production: boolean, secure: boolean, protocol: string): boolean {
  return platform === 'web' && production && secure && (protocol === 'http:' || protocol === 'https:');
}

export function setupPWA(options: PWAOptions): () => void {
  if (!pwaEligible(options.platform, options.production, window.isSecureContext, location.protocol) || !('serviceWorker' in navigator)) return () => {};
  const base = new URL('./', document.baseURI);
  let registration: ServiceWorkerRegistration | undefined;
  let installPrompt: InstallPrompt | undefined;
  let applying = false, disposed = false, dismissed = false, returnedOnline = false, registrationFailed = false;
  const panel = document.createElement('aside');
  panel.id = 'pwa-tools'; panel.setAttribute('aria-label', 'Reel app');
  panel.innerHTML = '<button type="button" class="pwa-install">Install Reel</button><section class="pwa-network" role="status" hidden><p></p><button type="button">Reload library</button></section><button type="button" class="pwa-update-ready" hidden>Update ready</button><section class="pwa-update" aria-label="App update" hidden><strong>A new Reel is ready.</strong><p class="pwa-update-detail">Update when you are ready. Session-only connections will need sign-in after reloading.</p><p class="pwa-update-status" role="status"></p><div><button type="button" class="pwa-apply">Update Reel</button><button type="button" class="pwa-later">Later</button></div></section>';
  document.body.append(panel);
  const install = panel.querySelector<HTMLButtonElement>('.pwa-install')!;
  const network = panel.querySelector<HTMLElement>('.pwa-network')!;
  const retry = network.querySelector<HTMLButtonElement>('button')!;
  const update = panel.querySelector<HTMLElement>('.pwa-update')!;
  const ready = panel.querySelector<HTMLButtonElement>('.pwa-update-ready')!;
  const apply = panel.querySelector<HTMLButtonElement>('.pwa-apply')!;
  const status = panel.querySelector<HTMLElement>('.pwa-update-status')!;
  const modal = document.createElement('dialog'); modal.className = 'pwa-dialog';
  modal.innerHTML = '<h2></h2><p></p><button type="button">Done</button>';
  document.body.append(modal);
  const done = modal.querySelector<HTMLButtonElement>('button')!;
  done.onclick = () => { if (applying) location.reload(); else modal.close(); };
  modal.addEventListener('cancel', event => { if (applying) event.preventDefault(); });
  function message(title: string, detail: string, locked = false) {
    modal.querySelector('h2')!.textContent = title; modal.querySelector('p')!.textContent = detail;
    done.hidden = locked;
    done.textContent = applying ? 'Reload Reel' : 'Done';
    if (!modal.open) modal.showModal();
  }
  function refresh() {
    if (disposed) return;
    const connectionColumn = document.querySelector<HTMLElement>('.connection-form-column');
    const host = connectionColumn ?? document.body;
    if (panel.parentElement !== host) host.append(panel);
    panel.classList.toggle('pwa-inline', Boolean(connectionColumn));
    const appModal = [...document.querySelectorAll<HTMLElement>('#app [role="dialog"][aria-modal="true"]')].some(element => !element.closest('[hidden]') && getComputedStyle(element).display !== 'none');
    panel.hidden = appModal; panel.inert = appModal; panel.setAttribute('aria-hidden', String(appModal));
    const standalone = matchMedia('(display-mode: standalone)').matches || (navigator as Navigator & { standalone?: boolean }).standalone === true;
    install.hidden = standalone; install.disabled = applying || !options.canUpdate();
    network.hidden = navigator.onLine && !returnedOnline && !registrationFailed;
    network.querySelector('p')!.textContent = !navigator.onLine ? 'You’re offline. Reel can open, but your library and playback need a connection.' : registrationFailed ? 'Offline access couldn’t be prepared. Reel can still work online. Reload to try again.' : 'You’re back online. Reload to reconnect to your library.';
    retry.disabled = applying || !options.canUpdate();
    update.hidden = !registration?.waiting || dismissed; ready.hidden = !registration?.waiting || !dismissed;
    apply.disabled = applying || !options.canUpdate();
    if (!options.canUpdate() && registration?.waiting) status.textContent = 'Finish playback or your current change before updating.';
    else if (status.textContent === 'Finish playback or your current change before updating.') status.textContent = '';
  }
  function beforeInstall(event: Event) { event.preventDefault(); installPrompt = event as InstallPrompt; refresh(); }
  function installed() { installPrompt = undefined; install.hidden = true; }
  function online() { returnedOnline = true; refresh(); }
  function offline() { returnedOnline = false; refresh(); }
  function changed() { if (applying) location.reload(); }
  install.onclick = async () => {
    if (!options.canUpdate() || applying) return;
    if (!installPrompt) { message('Install Reel', 'Use your browser’s Install app or Add to Home Screen command. On iPhone or iPad, open Reel in Safari, tap Share, then Add to Home Screen. Your library still needs a network connection.'); return; }
    const prompt = installPrompt; installPrompt = undefined;
    try { await prompt.prompt(); await prompt.userChoice; } catch { message('Install Reel', 'Use your browser’s Install app or Add to Home Screen command.'); }
    refresh();
  };
  retry.onclick = () => { if (options.canUpdate() && !applying) location.reload(); };
  ready.onclick = () => { dismissed = false; refresh(); apply.focus(); };
  panel.querySelector<HTMLButtonElement>('.pwa-later')!.onclick = () => { dismissed = true; refresh(); ready.focus(); };
  apply.onclick = async () => {
    const worker = registration?.waiting;
    if (!worker || applying || !options.canUpdate()) return;
    applying = true; refresh(); message('Updating Reel…', 'Your saved connections and settings will stay on this device.', true);
    const channel = new MessageChannel();
    try {
      const response = await new Promise<{ accepted: boolean; reason?: string }>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('The update did not respond. Try again.')), 5000);
        channel.port1.onmessage = event => { clearTimeout(timer); resolve(event.data); };
        worker.postMessage({ type: 'REEL_ACTIVATE', expiresAt: Date.now() + 4000 }, [channel.port2]);
      });
      if (!response?.accepted) throw new Error(response?.reason === 'other-windows' ? 'Close other Reel tabs or app windows, then try the update again.' : 'The update request expired. Try again when you are ready.');
      // The controller change reloads only the window that explicitly requested this update.
      setTimeout(() => { if (!disposed && applying) message('Finish updating Reel', 'The update is taking longer than expected. Reload to finish opening the latest version.'); }, 10000);
    } catch (error) {
      applying = false; modal.close(); status.textContent = error instanceof Error ? error.message : 'The update could not start. Try again.'; refresh();
    } finally { channel.port1.close(); }
  };
  window.addEventListener('beforeinstallprompt', beforeInstall);
  window.addEventListener('appinstalled', installed);
  window.addEventListener('online', online); window.addEventListener('offline', offline);
  navigator.serviceWorker.addEventListener('controllerchange', changed);
  void navigator.serviceWorker.register(new URL('reel-sw.js', base), { scope: base.href, updateViaCache: 'none' }).then(value => {
    if (disposed) return;
    registration = value;
    function observeInstall() {
      const worker = value.installing;
      worker?.addEventListener('statechange', () => { if (worker.state === 'redundant' && !value.active) registrationFailed = true; refresh(); });
    }
    value.addEventListener('updatefound', observeInstall); observeInstall();
    refresh();
  }).catch(() => { if (!disposed) { registrationFailed = true; refresh(); } });
  const appObserver = new MutationObserver(records => { if (records.some(record => !panel.contains(record.target))) refresh(); });
  const app = document.querySelector('#app'); if (app) appObserver.observe(app, { subtree: true, childList: true, attributes: true, attributeFilter: ['hidden', 'aria-modal', 'style', 'class'] });
  const interval = setInterval(refresh, 1000); refresh();
  return () => {
    disposed = true; clearInterval(interval); appObserver.disconnect(); panel.remove(); modal.remove();
    window.removeEventListener('beforeinstallprompt', beforeInstall); window.removeEventListener('appinstalled', installed);
    window.removeEventListener('online', online); window.removeEventListener('offline', offline);
    navigator.serviceWorker.removeEventListener('controllerchange', changed);
  };
}
