import { isOwnedDocument } from './policy.mjs';

export function installFullscreenSync(window, { platform = process.platform, schedule = setImmediate } = {}) {
  if (platform !== 'darwin') return () => {};
  const contents = window.webContents;
  let htmlSession = false, generation = 0;
  const ownsDocument = () => !window.isDestroyed() && !contents.isDestroyed() &&
    isOwnedDocument(contents.getURL()) && isOwnedDocument(contents.mainFrame?.url);
  const invalidate = () => { htmlSession = false; generation++; };
  const enter = () => { generation++; htmlSession = ownsDocument(); };
  const leave = () => {
    if (!htmlSession) return;
    const current = generation;
    schedule(() => {
      if (current !== generation || !htmlSession || !ownsDocument() || window.isFullScreen()) return;
      htmlSession = false;
      // Electron 45 can leave Chromium's HTML fullscreen exit pending after the
      // macOS animation. A resize sends the final visual state to the renderer.
      const bounds = window.getBounds(), minimum = window.getMinimumSize(), maximum = window.getMaximumSize();
      let changed;
      for (const [dimension, index] of [['width', 0], ['height', 1]]) {
        const delta = !maximum[index] || bounds[dimension] < maximum[index] ? 1 : bounds[dimension] > minimum[index] ? -1 : 0;
        if (delta) { changed = { ...bounds, [dimension]: bounds[dimension] + delta }; break; }
      }
      if (!changed) return;
      try { window.setBounds(changed, false); }
      catch { /* A closing native window may reject the resize. */ }
      finally { if (!window.isDestroyed()) try { window.setBounds(bounds, false); } catch { /* Closing window. */ } }
    });
  };
  const dispose = () => {
    invalidate();
    window.off('enter-html-full-screen', enter);
    window.off('leave-full-screen', leave);
    window.off('closed', dispose);
    contents.off('did-start-navigation', invalidate);
  };
  window.on('enter-html-full-screen', enter);
  window.on('leave-full-screen', leave);
  window.once('closed', dispose);
  contents.on('did-start-navigation', invalidate);
  return dispose;
}
