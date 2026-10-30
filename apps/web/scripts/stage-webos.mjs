import { cp, mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import { resolve, relative } from 'node:path';
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { sourceRevision } from './source-revision.mjs';

const root = resolve(import.meta.dirname, '..');
const mode = process.env.REEL_PROTECTED_PREVIEW;
if (mode !== undefined && mode !== '0' && mode !== '1') throw new Error('REEL_PROTECTED_PREVIEW must be 0 or 1');
const protectedPreview = mode === '1';
const before = await sourceRevision();
for (const args of [[resolve(root, 'node_modules/typescript/bin/tsc'), '--noEmit'], [resolve(root, 'node_modules/vite/bin/vite.js'), 'build', '--config', 'vite.tv.config.ts']]) {
  const child = spawn(process.execPath, args, { cwd: root, stdio: 'inherit' });
  const code = await new Promise(resolveExit => child.on('close', code => resolveExit(code ?? 1)));
  if (code !== 0) process.exit(code);
}
const destination = resolve(root, 'webos-package');
await rm(destination, { recursive: true, force: true });
await mkdir(destination, { recursive: true });
await cp(resolve(root, 'dist-tv'), destination, { recursive: true });
await cp(resolve(root, 'public/THIRD_PARTY_NOTICES.txt'), resolve(destination, 'THIRD_PARTY_NOTICES.txt'));
await cp(resolve(root, 'webos/appinfo.json'), resolve(destination, 'appinfo.json'));
await mkdir(resolve(destination, 'brand'), { recursive: true });
await cp(resolve(root, 'public/brand/mark.svg'), resolve(destination, 'brand/mark.svg'));
await cp(resolve(root, 'webos/icon.png'), resolve(destination, 'icon.png'));
await cp(resolve(root, 'webos/largeIcon.png'), resolve(destination, 'largeIcon.png'));
await writeFile(resolve(destination, 'reel-config.js'), `window.REEL_CONFIG = { previewMode: ${protectedPreview}, appName: 'Reel', platform: 'webos' };\n`);
await writeFile(resolve(destination, 'index.html'), `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=1920,height=1080,initial-scale=1"><meta name="referrer" content="no-referrer"><link rel="stylesheet" href="reel.css"><title>Reel</title></head><body><div id="app"></div><script src="reel-config.js"></script><script src="reel.js"></script></body></html>\n`);
const info = JSON.parse(await readFile(resolve(destination, 'appinfo.json'), 'utf8'));
if (info.id !== 'app.reelclient.tv') throw new Error('Unexpected TV package identity');
const files = {};
async function inventory(folder) {
  for (const entry of await readdir(folder, { withFileTypes: true })) {
    const path = resolve(folder, entry.name);
    if (entry.isDirectory()) await inventory(path);
    else if (entry.isFile()) files[relative(destination, path).split('\\').join('/')] = createHash('sha256').update(await readFile(path)).digest('hex');
    else throw new Error('Unexpected non-file in staged application');
  }
}
await inventory(destination);
const after = await sourceRevision();
if (before.revision !== after.revision) throw new Error('Source changed during TV build/staging. Rerun staging before packaging.');
await mkdir(resolve(root, '.cache'), { recursive: true });
await writeFile(resolve(root, '.cache/webos-stage-manifest.json'), JSON.stringify({ source_revision: before.revision, protected_preview: protectedPreview, files }, null, 2) + '\n');
console.log(`Staged ${info.id} ${info.version} at ${destination}. No TV installation was performed.`);
