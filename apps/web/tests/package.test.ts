import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { verifyPayloadFiles } from '../scripts/package-proof.mjs';

test('package evidence rejects changed, extra and linked extracted application files', async () => {
  const folder = await mkdtemp(join(tmpdir(), 'reel-payload-proof-'));
  const expected = { 'reel.js': createHash('sha256').update('original').digest('hex') };
  try {
    await writeFile(join(folder, 'reel.js'), 'original'); await verifyPayloadFiles(folder, expected);
    await writeFile(join(folder, 'extra.js'), 'unexpected'); await assert.rejects(verifyPayloadFiles(folder, expected));
    await rm(join(folder, 'extra.js')); await writeFile(join(folder, 'reel.js'), 'changed'); await assert.rejects(verifyPayloadFiles(folder, expected));
    await rm(join(folder, 'reel.js')); await symlink('/dev/null', join(folder, 'reel.js')); await assert.rejects(verifyPayloadFiles(folder, expected), /link/);
  } finally { await rm(folder, { recursive: true, force: true }); }
});

test('IPK inspection rejects service files, links, duplicates, install hooks and extra archives', async () => {
  const { execFile } = await import('node:child_process');
  await new Promise<void>((resolve, reject) => {
    execFile('python3', ['tests/package_inspection_test.py'], { cwd: new URL('..', import.meta.url).pathname }, (error, _stdout, stderr) => error ? reject(new Error(stderr)) : resolve());
  });
});
