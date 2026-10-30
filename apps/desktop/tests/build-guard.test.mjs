import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { cp, mkdtemp, mkdir, readFile, rm, stat, symlink, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { root, assertBuildCurrent } from '../scripts/source-revision.mjs';

// Builds a small synthetic web client with the real desktop build script, then checks the
// packaging guard against the record that build wrote.
async function workspace(base) {
  const desktop = join(base, 'apps/desktop'), web = join(base, 'apps/web');
  await writeFile(join(base, 'LICENSE'), 'MIT License\n');
  for (const name of ['src', 'scripts']) await cp(resolve(root, name), join(desktop, name), { recursive: true });
  for (const name of ['package.json', 'package-lock.json']) await cp(resolve(root, name), join(desktop, name));
  await mkdir(join(desktop, 'tests'));
  await writeFile(join(desktop, 'tests/synthetic.test.mjs'), '// synthetic\n');
  await symlink(resolve(root, 'node_modules'), join(desktop, 'node_modules'), 'junction');
  await mkdir(join(web, 'src'), { recursive: true }); await mkdir(join(web, 'public')); await mkdir(join(web, 'tests'));
  await writeFile(join(web, 'index.html'), '<!doctype html>\n<html><head><meta charset="utf-8"><title>Reel</title></head><body><script type="module" src="./src/main.js"></script></body></html>\n');
  await writeFile(join(web, 'src/main.js'), "document.body.dataset.ready = 'yes';\n");
  await writeFile(join(web, 'vite.config.ts'), "export default { base: './', build: { sourcemap: false } };\n");
  await writeFile(join(web, 'public/THIRD_PARTY_NOTICES.txt'), 'Synthetic notices\n');
  await writeFile(join(web, 'tests/journey.spec.ts'), '// synthetic\n');
  await writeFile(join(web, 'package.json'), '{ "private": true }\n');
  return { desktop, web, stage: join(desktop, '.cache/stage') };
}
function run(cwd, script, ...args) {
  return spawnSync(process.execPath, [join('scripts', script), ...args], { cwd, encoding: 'utf8', timeout: 120000 });
}
async function edit(file, change, check) {
  const original = await readFile(file);
  await writeFile(file, change(original.toString('utf8')));
  try { await check(); } finally { await writeFile(file, original); }
}

test('packaging accepts the build it was given and rejects changed web inputs, desktop source or stage', async () => {
  const base = await mkdtemp(join(tmpdir(), 'reel-build-guard-'));
  try {
    const { desktop, web, stage } = await workspace(base);
    const built = run(desktop, 'build.mjs');
    assert.equal(built.status, 0, built.stderr);
    const build = JSON.parse(await readFile(join(desktop, '.cache/build.json'), 'utf8'));
    const roots = { desktop, web, stage };
    const current = () => assertBuildCurrent(build, roots);

    assert.deepEqual(await current(), { desktopRevision: build.desktopRevision, webRevision: build.webRevision });
    const manifest = JSON.parse(await readFile(join(stage, 'web/asset-manifest.json'), 'utf8'));
    assert.equal(manifest.sourceRevision, build.webRevision);

    // Web files the desktop build does not compile do not invalidate it.
    await writeFile(join(web, 'tests/journey.spec.ts'), '// changed after build\n');
    await writeFile(join(web, 'package.json'), '{ "private": true, "version": "9.9.9" }\n');
    await current();

    const packaged = () => run(desktop, 'package.mjs', '--platform=linux', '--arch=x64');
    await edit(join(web, 'src/main.js'), text => text + '// changed after build\n', async () => {
      await assert.rejects(current(), /Shared-web build input changed/);
      const result = packaged();
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /Shared-web build input changed/);
    });
    await edit(join(web, 'vite.config.ts'), text => text.replace("'./'", "'/'"), () => assert.rejects(current(), /Shared-web build input changed/));
    await writeFile(join(web, 'public/extra.txt'), 'new input\n');
    await assert.rejects(current(), /Shared-web build input changed/);
    await rm(join(web, 'public/extra.txt'));
    await current();

    await edit(join(desktop, 'src/lifecycle.mjs'), text => text + '// changed after build\n', async () => {
      await assert.rejects(current(), /Rebuild the current desktop revision before packaging/);
      const result = packaged();
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /Rebuild the current desktop revision before packaging/);
    });
    await current();

    await edit(join(stage, 'web/index.html'), text => text + '<!-- changed -->\n', () => assert.rejects(current(), /verified build/));
    await current();
    await assert.rejects(assertBuildCurrent({ ...build, webRevision: undefined }, roots), /Shared-web build input changed/);
  } finally {
    // Remove the dependency link first so cleanup never descends into the real node_modules.
    await rm(join(base, 'apps/desktop/node_modules'), { force: true });
    await rm(base, { recursive: true, force: true });
  }
  assert.ok((await stat(resolve(root, 'node_modules/vite/package.json'))).isFile());
});
