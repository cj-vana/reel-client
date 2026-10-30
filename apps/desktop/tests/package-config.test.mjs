import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createHash } from 'node:crypto';
import { runInNewContext } from 'node:vm';
import { applyPackageFlavor, runtimeConfig } from '../scripts/package-config.mjs';
import { payloadManifest } from '../scripts/source-revision.mjs';

for (const qa of [false, true]) test(`${qa ? 'QA' : 'production'} package config and asset manifest agree with its build flavor`, async () => {
  const input = await mkdtemp(join(tmpdir(), 'reel-package-config-'));
  try {
    await mkdir(join(input, 'web'));
    await writeFile(join(input, 'build-flavor.json'), '{"qa":false}\n');
    await writeFile(join(input, 'web/reel-config.js'), runtimeConfig(false));
    await writeFile(join(input, 'web/asset-manifest.json'), JSON.stringify({ schema: 1, sourceRevision: 'synthetic', files: { 'reel-config.js': { sha256: 'old', bytes: 0 } } }));
    const expected = await applyPackageFlavor(input, qa, await payloadManifest(input));
    assert.deepEqual(await payloadManifest(input), expected);
    const code = await readFile(join(input, 'web/reel-config.js'), 'utf8'), context = { window: {} };
    runInNewContext(code, context);
    assert.equal(context.window.REEL_CONFIG.previewMode, qa);
    assert.equal(Object.isFrozen(context.window.REEL_CONFIG), true);
    assert.equal(context.window.REEL_CONFIG.platform, 'desktop');
    const manifest = JSON.parse(await readFile(join(input, 'web/asset-manifest.json'), 'utf8'));
    assert.deepEqual(manifest.files['reel-config.js'], { sha256: createHash('sha256').update(code).digest('hex'), bytes: Buffer.byteLength(code) });
    assert.equal(JSON.parse(await readFile(join(input, 'build-flavor.json'), 'utf8')).qa, qa);
  } finally { await rm(input, { recursive: true, force: true }); }
});
