import { spawn } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { projectRoot, sourceRevision } from './source-revision.mjs';

const before = await sourceRevision(), log = [], checks = [];
await mkdir(resolve(projectRoot, '.cache'), { recursive: true });
const commands = [
  ['typecheck', [resolve(projectRoot, 'node_modules/typescript/bin/tsc'), '--noEmit']],
  ['web-build', [resolve(projectRoot, 'node_modules/vite/bin/vite.js'), 'build']],
  ['notices', [resolve(projectRoot, 'scripts/check-notices.mjs')]],
  ...['stage-webos.mjs', 'fixture-server.mjs', 'prepare-fixtures.mjs', 'source-revision.mjs', 'run-browser-checks.mjs', 'run-unit-checks.mjs', 'run-static-checks.mjs', 'demo-library.mjs', 'fixture-library.mjs', 'package-proof.mjs', 'check-notices.mjs'].map(file => ['script-' + file, ['--check', resolve(projectRoot, 'scripts', file)]])
];
for (const [id, args] of commands) {
  const child = spawn(process.execPath, args, { cwd: projectRoot, stdio: ['inherit', 'pipe', 'pipe'] });
  for (const [stream, output] of [[child.stdout, process.stdout], [child.stderr, process.stderr]]) stream.on('data', chunk => { log.push(chunk); output.write(chunk); });
  const exitCode = await new Promise(resolveExit => child.on('close', code => resolveExit(code ?? 1)));
  checks.push({ id, exitCode });
  if (exitCode !== 0) break;
}
const after = await sourceRevision();
await writeFile(resolve(projectRoot, '.cache/static-final.log'), Buffer.concat(log));
await writeFile(resolve(projectRoot, '.cache/static-run-revision.json'), JSON.stringify({ revision: before.revision, unchangedDuringRun: before.revision === after.revision, checks, recordedAt: new Date().toISOString() }, null, 2) + '\n');
if (before.revision !== after.revision || checks.some(check => check.exitCode !== 0)) process.exit(1);
