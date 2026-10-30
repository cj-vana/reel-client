import { createHash } from 'node:crypto';
import { readdir, readFile, lstat } from 'node:fs/promises';
import { resolve, relative } from 'node:path';
export const root = resolve(import.meta.dirname, '..');
export const webRoot = resolve(root, '../web');
// Desktop files that define the shell and its build. Any change requires a new build.
export const DESKTOP_INPUTS = Object.freeze(['src', 'scripts', 'tests', 'package.json', 'package-lock.json']);
// Shared-web files the desktop build copies and compiles. Build and package hash exactly this set.
export const WEB_INPUTS = Object.freeze(['src', 'public', 'index.html', 'vite.config.ts']);
export async function treeFiles(base) {
  const files = [];
  async function walk(folder) {
    for (const entry of await readdir(folder, { withFileTypes: true })) {
      if (entry.name === '.DS_Store') continue;
      const full = resolve(folder, entry.name);
      if (entry.isDirectory()) await walk(full);
      else if (entry.isFile()) files.push(full);
      else throw new Error('Links and special files are not valid source input');
    }
  }
  await walk(base); return files.sort();
}
async function inputRevision(base, names) {
  const files = [];
  for (const name of names) {
    const full = resolve(base, name), info = await lstat(full);
    if (info.isDirectory()) files.push(...await treeFiles(full));
    else if (info.isFile()) files.push(full);
    else throw new Error('Links and special files are not valid source input');
  }
  const hash = createHash('sha256'), entries = {};
  for (const full of files.sort()) {
    const name = relative(base, full).split('\\').join('/');
    entries[name] = createHash('sha256').update(await readFile(full)).digest('hex');
    hash.update(name + '\0' + entries[name] + '\n');
  }
  return { revision: 'sha256:' + hash.digest('hex'), files: entries };
}
export function sourceRevision(base = root) { return inputRevision(base, DESKTOP_INPUTS); }
// Names are relative to the base, so the web folder and its build copy hash identically.
export function webInputRevision(base = webRoot) { return inputRevision(base, WEB_INPUTS); }

export async function payloadManifest(base) {
  const entries = {};
  for (const full of await treeFiles(base)) entries[relative(base, full).split('\\').join('/')] = createHash('sha256').update(await readFile(full)).digest('hex');
  return entries;
}
export function manifestsEqual(left, right) { return JSON.stringify(Object.entries(left).sort()) === JSON.stringify(Object.entries(right).sort()); }
export async function assertPayload(base, expected) {
  if (!expected || !manifestsEqual(await payloadManifest(base), expected)) throw new Error('Payload does not match verified build');
}
// Packaging guard: the recorded build must match the current desktop source, shared-web inputs and stage.
export async function assertBuildCurrent(build, { desktop = root, web = webRoot, stage } = {}) {
  const desktopRevision = (await sourceRevision(desktop)).revision;
  if (typeof build?.desktopRevision !== 'string' || build.desktopRevision !== desktopRevision) throw new Error('Rebuild the current desktop revision before packaging');
  const webRevision = (await webInputRevision(web)).revision;
  if (typeof build.webRevision !== 'string' || build.webRevision !== webRevision) throw new Error('Shared-web build input changed');
  if (stage !== undefined) await assertPayload(stage, build.stagePayload);
  return { desktopRevision, webRevision };
}
