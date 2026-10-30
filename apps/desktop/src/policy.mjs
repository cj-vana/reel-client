export const APP_URL = 'reel://app/index.html';
export const APP_ORIGIN = 'reel://app';
export const CONTENT_POLICY = [
  "default-src 'none'", "script-src 'self'", "style-src 'self' 'unsafe-inline'",
  "img-src 'self' blob: data:", "media-src http: https: blob:",
  "connect-src 'self' http: https:", "font-src 'self'", "worker-src 'none'",
  "frame-src 'none'", "object-src 'none'", "base-uri 'none'", "form-action 'none'"
].join('; ');
export const SECURITY_HEADERS = {
  'Content-Security-Policy': CONTENT_POLICY,
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'Cache-Control': 'no-store',
  'Cross-Origin-Resource-Policy': 'same-origin'
};
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.txt': 'text/plain; charset=utf-8', '.webmanifest': 'application/manifest+json; charset=utf-8' };
export function assetMime(name) {
  const extension = /\.[a-z]+$/.exec(name)?.[0];
  if (!extension || !MIME[extension]) throw new Error('Unsupported app asset type');
  return MIME[extension];
}
export function assetPath(url, method = 'GET') {
  if (!['GET', 'HEAD'].includes(method) || typeof url !== 'string' || url.length > 1024) return null;
  // Require canonical owned names before URL parsing can normalize dot segments.
  if (!/^reel:\/\/app\/(?:[A-Za-z0-9_-]+\/?|[A-Za-z0-9_-]+\.[A-Za-z0-9]+\/?)*$/.test(url)) return null;
  const name = url.slice('reel://app/'.length) || 'index.html';
  if (name.includes('//') || name.endsWith('/')) return null;
  return name;
}
export function isOwnedDocument(url) { return url === APP_URL; }
export function allowFullscreenRequest(contents, ownedContents, permission, details) {
  return permission === 'fullscreen' && contents === ownedContents && Boolean(contents) &&
    !contents.isDestroyed() && isOwnedDocument(contents.getURL()) && isOwnedDocument(contents.mainFrame?.url) &&
    details?.isMainFrame === true && isOwnedDocument(details.requestingUrl);
}
export function allowFullscreenCheck(contents, ownedContents, permission, requestingOrigin, details) {
  return [APP_ORIGIN, APP_ORIGIN + '/'].includes(requestingOrigin) &&
    allowFullscreenRequest(contents, ownedContents, permission, details);
}
export function windowOptions(partition, preload) {
  if (typeof partition !== 'string' || !/^reel-[a-z0-9-]+$/.test(partition)) throw new Error('An in-memory Reel partition is required');
  return {
    width: 1440, height: 940, minWidth: 320, minHeight: 560, show: false,
    backgroundColor: '#0c0c0e', title: 'Reel', autoHideMenuBar: true,
    webPreferences: {
      partition, sandbox: true, contextIsolation: true, nodeIntegration: false,
      nodeIntegrationInWorker: false, nodeIntegrationInSubFrames: false,
      webviewTag: false, webSecurity: true, allowRunningInsecureContent: false,
      navigateOnDragDrop: false, spellcheck: false, devTools: false,
      ...(preload ? { preload } : {})
    }
  };
}
export function validQAProfile(value, temporaryRoot) {
  // Only a descendant named by this tool can be used; never accept a real profile path.
  return typeof value === 'string' && value.startsWith(temporaryRoot + '/') && /^qa-profile-[A-Za-z0-9-]+$/.test(value.slice(temporaryRoot.length + 1));
}
