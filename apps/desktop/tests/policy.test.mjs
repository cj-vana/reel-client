import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { APP_URL, APP_ORIGIN, assetPath, assetMime, windowOptions, CONTENT_POLICY, validQAProfile, allowFullscreenRequest, allowFullscreenCheck } from '../src/policy.mjs';
import { loadAssets, assetResponse } from '../src/assets.mjs';
import { CloseGate } from '../src/lifecycle.mjs';

for (const url of ['https://app/index.html', 'file:///etc/passwd', 'reel://else/index.html', 'reel://user@app/index.html', 'reel://app:80/index.html', 'reel://app/../secret.js', 'reel://app/%2e%2e/secret.js', 'reel://app/a/%2fsecret.js', 'reel://app/a\\secret.js', 'reel://app//index.html', 'reel://app/index.html?token=x', 'reel://app/index.html#x', 'reel://app/asset-manifest.json/']) test('protocol rejects ' + url, () => assert.equal(assetPath(url), null));
test('protocol accepts only canonical owned asset names and GET/HEAD', () => {
  assert.equal(assetPath(APP_URL), 'index.html'); assert.equal(assetPath('reel://app/'), 'index.html');
  assert.equal(assetPath('reel://app/assets/index-Ab1_2.js', 'HEAD'), 'assets/index-Ab1_2.js');
  assert.equal(assetPath(APP_URL, 'POST'), null);
});
test('shared PWA manifest is a static desktop asset without enabling workers', () => {
  assert.equal(assetMime('manifest.webmanifest'), 'application/manifest+json; charset=utf-8');
  assert.equal(assetPath('reel://app/manifest.webmanifest'), 'manifest.webmanifest');
  assert.match(CONTENT_POLICY, /worker-src 'none'/);
  assert.throws(() => assetMime('secret.json'), /Unsupported/);
});
test('window security cannot use persistent or unowned partitions', () => {
  assert.throws(() => windowOptions('persist:reel')); assert.throws(() => windowOptions(''));
  const options = windowOptions('reel-test').webPreferences;
  for (const flag of ['sandbox', 'contextIsolation', 'webSecurity']) assert.equal(options[flag], true);
  for (const flag of ['nodeIntegration', 'webviewTag', 'nodeIntegrationInWorker', 'nodeIntegrationInSubFrames', 'allowRunningInsecureContent', 'devTools']) assert.equal(options[flag], false);
  assert.match(CONTENT_POLICY, /script-src 'self';/); assert.match(CONTENT_POLICY, /frame-src 'none'/); assert.doesNotMatch(CONTENT_POLICY, /unsafe-eval/);
});
test('window background matches the shared web canvas so opening and resizing show no color flash', async () => {
  const tokens = await readFile(new URL('../../web/src/styles/tokens.css', import.meta.url), 'utf8');
  const canvas = /--canvas:\s*(#[0-9a-fA-F]{6})\s*;/.exec(tokens)?.[1];
  assert.ok(canvas, 'shared web canvas token');
  assert.equal(windowOptions('reel-test').backgroundColor.toLowerCase(), canvas.toLowerCase());
});
test('fullscreen permission accepts only the live owned main document and exact origin', () => {
  const contents = { isDestroyed: () => false, getURL: () => APP_URL, mainFrame: { url: APP_URL } };
  const details = { isMainFrame: true, requestingUrl: APP_URL };
  assert.equal(allowFullscreenRequest(contents, contents, 'fullscreen', details), true);
  for (const origin of [APP_ORIGIN, APP_ORIGIN + '/']) assert.equal(allowFullscreenCheck(contents, contents, 'fullscreen', origin, details), true);
  for (const origin of ['https://app', 'null', 'reel://else', APP_URL, APP_ORIGIN + '?x', undefined]) assert.equal(allowFullscreenCheck(contents, contents, 'fullscreen', origin, details), false);
});
test('fullscreen permission denies foreign windows, subframes, stale documents and all other permissions', () => {
  const contents = { isDestroyed: () => false, getURL: () => APP_URL, mainFrame: { url: APP_URL } };
  const details = { isMainFrame: true, requestingUrl: APP_URL };
  for (const permission of ['automatic-fullscreen', 'media', 'display-capture', 'notifications', 'openExternal', 'unknown', undefined]) assert.equal(allowFullscreenRequest(contents, contents, permission, details), false);
  for (const request of [undefined, {}, { ...details, isMainFrame: false }, { ...details, requestingUrl: 'https://example.invalid/' }, { ...details, requestingUrl: APP_URL + '?x' }]) assert.equal(allowFullscreenRequest(contents, contents, 'fullscreen', request), false);
  assert.equal(allowFullscreenRequest({ ...contents }, contents, 'fullscreen', details), false);
  assert.equal(allowFullscreenRequest(null, contents, 'fullscreen', details), false);
  for (const modified of [{ ...contents, isDestroyed: () => true }, { ...contents, getURL: () => 'https://example.invalid/' }, { ...contents, mainFrame: { url: 'reel://app/other.html' } }]) assert.equal(allowFullscreenRequest(modified, modified, 'fullscreen', details), false);
});
test('QA rejects all ordinary and nested profile locations', () => {
  assert.equal(validQAProfile('/tmp/qa-profile-example', '/tmp'), true);
  assert.equal(validQAProfile('/tmp/qa-profile-reel-AbC123', '/tmp'), true);
  for (const value of ['/tmp/Default', '/Users/test/Library/Application Support/Reel', '/tmp/qa-profile-a/Default', '/tmp/qa-profile-../x']) assert.equal(validQAProfile(value, '/tmp'), false);
});
async function fixture(run) {
  const folder = await mkdtemp(join(tmpdir(), 'reel-assets-'));
  const files = { 'index.html': '<div id="app"></div>', 'reel-config.js': 'window.REEL_CONFIG={previewMode:true}', 'THIRD_PARTY_NOTICES.txt': 'Test notice' };
  for (const [name, value] of Object.entries(files)) await writeFile(join(folder, name), value);
  const records = Object.fromEntries(Object.entries(files).map(([name, value]) => [name, { bytes: Buffer.byteLength(value), sha256: createHash('sha256').update(value).digest('hex') }]));
  await writeFile(join(folder, 'asset-manifest.json'), JSON.stringify({ schema: 1, files: records }));
  try { await run(folder); } finally { await rm(folder, { recursive: true, force: true }); }
}
test('asset handler serves immutable verified bytes with CSP and denies absent paths', async () => fixture(async folder => {
  const assets = await loadAssets(folder); await writeFile(join(folder, 'index.html'), 'replaced');
  const response = assetResponse(assets, { url: APP_URL, method: 'GET' });
  assert.equal(await response.text(), '<div id="app"></div>'); assert.match(response.headers.get('content-security-policy'), /object-src 'none'/);
  assert.equal((await assetResponse(assets, { url: APP_URL, method: 'HEAD' }).text()), '');
  assert.equal(assetResponse(assets, { url: 'reel://app/secret.js', method: 'GET' }).status, 404);
}));
test('asset integrity failure prevents application startup', async () => fixture(async folder => {
  await writeFile(join(folder, 'index.html'), 'tampered'); await assert.rejects(loadAssets(folder), /integrity/);
}));
test('symlink asset is rejected even when its target bytes match', async () => fixture(async folder => {
  const original = '<div id="app"></div>'; await writeFile(join(folder, 'target.html'), original); await rm(join(folder, 'index.html')); await symlink(join(folder, 'target.html'), join(folder, 'index.html'));
  await assert.rejects(loadAssets(folder), /escapes/);
}));
test('parent directory symlink cannot escape the owned root', async () => fixture(async folder => {
  const outside = await mkdtemp(join(tmpdir(), 'reel-outside-'));
  try { await writeFile(join(outside, 'x.js'), 'x'); await symlink(outside, join(folder, 'assets'));
    const manifest = JSON.parse(await (await import('node:fs/promises')).readFile(join(folder, 'asset-manifest.json')));
    manifest.files['assets/x.js'] = { bytes: 1, sha256: createHash('sha256').update('x').digest('hex') };
    await writeFile(join(folder, 'asset-manifest.json'), JSON.stringify(manifest)); await assert.rejects(loadAssets(folder), /escapes|parent is a link/);
  } finally { await rm(outside, { recursive: true, force: true }); }
}));
test('close gate reuses one request and finishes after completion', async () => {
  let requests = 0, finished = 0, resolveRequest;
  const gate = new CloseGate({ request: () => { requests++; return new Promise(resolve => { resolveRequest = resolve; }); }, finish: () => finished++ });
  gate.begin(); gate.begin(); await Promise.resolve(); assert.equal(requests, 1); assert.equal(finished, 0);
  resolveRequest(); await new Promise(resolve => setImmediate(resolve)); assert.equal(finished, 1); assert.equal(gate.pending, false);
});
test('close gate timeout and late completion finish once', async () => {
  let timeout, resolveRequest, finished = 0;
  const gate = new CloseGate({ request: () => new Promise(resolve => { resolveRequest = resolve; }), finish: () => finished++, schedule: callback => { timeout = callback; return 1; }, cancel: () => {} });
  gate.begin(); await Promise.resolve(); timeout(); resolveRequest(); await new Promise(resolve => setImmediate(resolve)); assert.equal(finished, 1);
});
test('failed close request still releases the window', async () => {
  let finished = 0; const gate = new CloseGate({ request: async () => { throw new Error('renderer gone'); }, finish: () => finished++ });
  gate.begin(); await new Promise(resolve => setImmediate(resolve)); assert.equal(finished, 1);
});

test('actual filesystem QA profile ownership rejects symlink targets and missing marker', async () => {
  const { assertQAProfile } = await import('../src/qa-profile.mjs');
  const { chmod } = await import('node:fs/promises');
  const parent = await mkdtemp(join(tmpdir(), 'reel-qa-root-'));
  const owner = 'a'.repeat(64), profile = join(parent, 'qa-profile-owned');
  try {
    await mkdir(profile, { mode: 0o700 });
    await assert.rejects(assertQAProfile(profile, parent, owner), /ENOENT/);
    await writeFile(join(profile, '.reel-qa-owner'), owner, { mode: 0o600 });
    await assertQAProfile(profile, parent, owner);
    await assert.rejects(assertQAProfile(profile, parent, 'b'.repeat(64)), /ownership/);
    await symlink(profile, join(parent, 'qa-profile-link'));
    await assert.rejects(assertQAProfile(join(parent, 'qa-profile-link'), parent, owner), /owned temporary/);
    await symlink(profile, join(profile, 'nested'));
    await assert.rejects(assertQAProfile(profile, parent, owner), /unexpected link/);
    await rm(join(profile, 'nested')); await chmod(profile, 0o755);
    await assert.rejects(assertQAProfile(profile, parent, owner), /permissions/);
  } finally { await rm(parent, { recursive: true, force: true }); }
});

test('only exact root Chromium coordination links are accepted and never followed',async()=>{
  const {assertQAProfile}=await import('../src/qa-profile.mjs');const parent=await mkdtemp(join(tmpdir(),'reel-lock-test-')),profile=join(parent,'qa-profile-Owned1'),owner='d'.repeat(64);
  try {await mkdir(profile,{mode:0o700});await writeFile(join(profile,'.reel-qa-owner'),owner,{mode:0o600});
    for(const name of ['SingletonLock','SingletonSocket','SingletonCookie'])await symlink('/nonexistent-outside-target',join(profile,name));await assertQAProfile(profile,parent,owner);
    await mkdir(join(profile,'nested'));
    for(const name of ['SingletonLock','SingletonSocket','SingletonCookie']){await symlink('/nonexistent-outside-target',join(profile,'nested',name));await assert.rejects(assertQAProfile(profile,parent,owner),/unexpected link/);await rm(join(profile,'nested',name));}
  }finally{await rm(parent,{recursive:true,force:true});}
});
