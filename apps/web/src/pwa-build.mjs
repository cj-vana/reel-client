import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';

export const publicShell = ['reel-config.js', 'manifest.webmanifest', 'brand/mark.svg', 'brand/icon.png', 'brand/icon-192.png', 'brand/icon-512.png', 'THIRD_PARTY_NOTICES.txt'];

export function reelPWA() {
  let root = '';
  return {
    name: 'reel-offline-shell', apply: 'build', enforce: 'post',
    configResolved(config) { root = config.root; },
    async writeBundle(options, bundle) {
      if (!options.dir) throw new Error('Offline shell requires a directory build');
      const output = resolve(root, options.dir);
      const assets = [];
      function add(path, data) {
        if (!/^(?:index\.html|assets\/[A-Za-z0-9_.-]+\.(?:js|css)|reel-config\.js|manifest\.webmanifest|brand\/(?:mark\.svg|icon(?:-192|-512)?\.png)|THIRD_PARTY_NOTICES\.txt)$/.test(path)) throw new Error('Unreviewed offline shell asset: ' + path);
        assets.push({ path, sha256: createHash('sha256').update(data).digest('hex') });
      }
      // Vite can finish module-preload rewrites after generateBundle. Pin the bytes
      // actually written, including those final rewrites, rather than earlier chunks.
      for (const path of Object.keys(bundle)) add(path, await readFile(resolve(output, path)));
      if (!assets.some(asset => asset.path === 'index.html')) throw new Error('Offline shell requires its emitted index');
      for (const path of publicShell) add(path, await readFile(resolve(output, path)));
      assets.sort((a, b) => a.path.localeCompare(b.path));
      const template = await readFile(resolve(root, 'src/pwa-worker.js'), 'utf8');
      const revision = createHash('sha256').update(template).update(JSON.stringify(assets)).digest('hex');
      await writeFile(resolve(output, 'reel-sw.js'), template.replace('__REEL_ASSETS__', JSON.stringify(assets)).replace('__REEL_REVISION__', JSON.stringify(revision)));
    }
  };
}
