import { spawnSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { root, treeFiles, sourceRevision } from './source-revision.mjs';
for (const folder of ['src', 'scripts', 'tests']) for (const file of await treeFiles(resolve(root, folder))) {
  if (file.endsWith('.mjs') || file.endsWith('.cjs')) { const result = spawnSync(process.execPath, ['--check', file], { stdio: 'inherit' }); if (result.status !== 0) process.exit(result.status ?? 1); }
}
const pkg = JSON.parse(await readFile(resolve(root, 'package.json'))), lock = JSON.parse(await readFile(resolve(root, 'package-lock.json')));
for (const [name, version] of Object.entries(pkg.devDependencies)) {
  if (!/^\d+\.\d+\.\d+$/.test(version) || lock.packages['node_modules/' + name]?.version !== version) throw new Error('Dependency is not pinned: ' + name);
}
const source = await sourceRevision();
console.log(JSON.stringify({ ...source, check: 'syntax, exact dependency pins and lock agreement' }, null, 2));
