import { spawn } from 'node:child_process';
import { mkdir, readdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { projectRoot, sourceRevision } from './source-revision.mjs';

await mkdir(resolve(projectRoot, '.cache'), { recursive: true });
const before = await sourceRevision(), log = [];
const tests = (await readdir(resolve(projectRoot, 'tests'))).filter(name => name.endsWith('.test.ts')).map(name => resolve(projectRoot, 'tests', name));
const child = spawn(process.execPath, ['--experimental-strip-types', '--test', ...tests], { cwd: projectRoot, stdio: ['inherit', 'pipe', 'pipe'] });
for (const [stream, output] of [[child.stdout, process.stdout], [child.stderr, process.stderr]]) stream.on('data', chunk => { log.push(chunk); output.write(chunk); });
const exitCode = await new Promise(resolveExit => child.on('close', code => resolveExit(code ?? 1)));
const after = await sourceRevision();
await writeFile(resolve(projectRoot, '.cache/unit-final.log'), Buffer.concat(log));
await writeFile(resolve(projectRoot, '.cache/unit-run-revision.json'), JSON.stringify({ revision: before.revision, unchangedDuringRun: before.revision === after.revision, exitCode, recordedAt: new Date().toISOString() }, null, 2) + '\n');
if (before.revision !== after.revision) { console.error('Source changed during unit verification; evidence requires a fresh run.'); process.exit(2); }
process.exit(exitCode);
