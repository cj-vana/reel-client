import { createHash } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import { resolve, relative } from 'node:path';

export const projectRoot = resolve(import.meta.dirname, '..');
export async function sourceRevision() {
  const files = [];
  async function walk(path) {
    for (const entry of await readdir(path, { withFileTypes: true })) {
      if (entry.name === '__pycache__' || entry.name === '.DS_Store') continue;
      const child = resolve(path, entry.name);
      if (entry.isDirectory()) await walk(child);
      else if (entry.isFile()) files.push(child);
    }
  }
  for (const folder of ['src', 'tests', 'scripts', 'public', 'webos']) await walk(resolve(projectRoot, folder));
  for (const file of ['package.json', 'package-lock.json', 'tsconfig.json', 'vite.config.ts', 'vite.tv.config.ts', 'playwright.config.ts', 'index.html']) files.push(resolve(projectRoot, file));
  const hash = createHash('sha256'), entries = {};
  for (const file of files.sort()) {
    const name = relative(projectRoot, file).split('\\').join('/');
    const data = await readFile(file);
    entries[name] = createHash('sha256').update(data).digest('hex');
    hash.update(name + '\0' + entries[name] + '\n');
  }
  return { revision: 'sha256:' + hash.digest('hex'), files: entries };
}
