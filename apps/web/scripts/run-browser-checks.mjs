import { spawn } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { packageProof } from './package-proof.mjs';
import { projectRoot, sourceRevision } from './source-revision.mjs';

await mkdir(resolve(projectRoot, '.cache'), { recursive: true });
const before = await sourceRevision();
const args = process.argv.slice(2);
const proof = async () => { try { return await packageProof(before.revision); } catch { return null; } };
const packageBefore = await proof();
const log = [];
const child = spawn(process.execPath, [resolve(projectRoot, 'node_modules/playwright/cli.js'), 'test', ...args], { cwd: projectRoot, stdio: ['inherit', 'pipe', 'pipe'] });
for (const [stream, output] of [[child.stdout, process.stdout], [child.stderr, process.stderr]]) stream.on('data', chunk => { log.push(chunk); output.write(chunk); });
const exitCode = await new Promise(resolveExit => child.on('close', code => resolveExit(code ?? 1)));
const after = await sourceRevision();
const packageAfter = await proof();
let packagedTVSelected = false;
try {
  const results = JSON.parse(await readFile(resolve(projectRoot, '.cache/browser-results.json'), 'utf8'));
  const includesTV = suites => suites.some(suite => (suite.specs ?? []).some(spec => spec.title.startsWith('packaged TV classic bundle')) || includesTV(suite.suites ?? []));
  packagedTVSelected = includesTV(results.suites ?? []);
} catch { /* A failed browser launch cannot qualify any package. */ }
const packageQualified = packageBefore !== null && packageAfter !== null && JSON.stringify(packageBefore) === JSON.stringify(packageAfter);
await writeFile(resolve(projectRoot, '.cache/browser-final.log'), Buffer.concat(log));
await writeFile(resolve(projectRoot, '.cache/browser-run-revision.json'), JSON.stringify({ revision: before.revision, unchangedDuringRun: before.revision === after.revision, exitCode, arguments: args, packageSha256: packageAfter?.ipkSha256 ?? null, packagedTVSelected, packageQualified, packageBefore, packageAfter, recordedAt: new Date().toISOString() }, null, 2) + '\n');
await writeFile(resolve(projectRoot, '.cache/source-hashes.json'), JSON.stringify(after, null, 2) + '\n');
if (before.revision !== after.revision) { console.error('Source changed during browser verification; evidence requires a fresh run.'); process.exit(2); }
if (packagedTVSelected && !packageQualified) { console.error('Packaged TV evidence is not bound to an unchanged inspected IPK/payload.'); process.exit(2); }
process.exit(exitCode);
