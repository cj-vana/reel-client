import { cp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { resolve, relative } from 'node:path';
import { spawnSync } from 'node:child_process';
import { root, webRoot as web, WEB_INPUTS, sourceRevision, webInputRevision, treeFiles, payloadManifest } from './source-revision.mjs';
import { assetMime, assetPath } from '../src/policy.mjs';
import { runtimeConfig } from './package-config.mjs';

const { version } = JSON.parse(await readFile(resolve(root, 'package.json'), 'utf8'));
const desktop = await sourceRevision(), shared = await webInputRevision(web);
const input = resolve(root, '.cache/web-input'), stage = resolve(root, '.cache/stage');
await rm(input, { recursive: true, force: true }); await rm(stage, { recursive: true, force: true });
await mkdir(input, { recursive: true }); await mkdir(stage, { recursive: true });
for (const name of WEB_INPUTS) await cp(resolve(web, name), resolve(input, name), { recursive: true, dereference: false });
// Record the same input hash that packaging checks, and prove the copy is exactly those inputs.
const webRevision = shared.revision;
if ((await webInputRevision(input)).revision !== webRevision) throw new Error('Shared-web input copy does not match its source');
const built = spawnSync(process.execPath, [resolve(root, 'node_modules/vite/bin/vite.js'), 'build', input, '--outDir', resolve(stage, 'web'), '--emptyOutDir'], { cwd: root, stdio: 'inherit' });
if (built.status !== 0) throw new Error('Private shared-web build failed');
await writeFile(resolve(stage, 'web/reel-config.js'), runtimeConfig(false));
const files = {};
for (const file of await treeFiles(resolve(stage, 'web'))) {
  const name = relative(resolve(stage, 'web'), file).split('\\').join('/');
  if (assetPath('reel://app/' + name) !== name) throw new Error('Noncanonical app asset');
  assetMime(name);
  const data = await readFile(file);
  files[name] = { sha256: createHash('sha256').update(data).digest('hex'), bytes: data.length };
}
await writeFile(resolve(stage, 'web/asset-manifest.json'), JSON.stringify({ schema: 1, sourceRevision: webRevision, files }, null, 2) + '\n');
await cp(resolve(root, 'src'), resolve(stage, 'src'), { recursive: true });
await writeFile(resolve(stage, 'build-flavor.json'), JSON.stringify({ qa: false }) + '\n');
await writeFile(resolve(stage, 'package.json'), JSON.stringify({ name: 'reel-client-desktop', version, type: 'module', main: 'src/main.mjs', productName: 'Reel', author: 'Reel Client contributors', license: 'MIT' }, null, 2) + '\n');
await cp(resolve(root, '../../LICENSE'), resolve(stage, 'LICENSE'));
if (desktop.revision !== (await sourceRevision()).revision || webRevision !== (await webInputRevision(web)).revision) throw new Error('Source changed during build');
await writeFile(resolve(root, '.cache/build.json'), JSON.stringify({ desktopRevision: desktop.revision, webRevision, assets: files, stagePayload: await payloadManifest(stage) }, null, 2) + '\n');
console.log(JSON.stringify({ desktopRevision: desktop.revision, webRevision, assets: Object.keys(files).length }));
