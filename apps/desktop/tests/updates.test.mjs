import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign, createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { compareVersions, releasePage, UpdateService, REPOSITORY } from '../src/updates.mjs';
import { MANIFEST, RELEASES, SIGNATURE } from '../src/update-package.mjs';

const API = `https://api.github.com/repos/${REPOSITORY}/releases/latest`;
const latest = (tag, extra = {}) => async url => {
  assert.equal(url, API);
  return { ok: true, status: 200, json: async () => ({ tag_name: tag, draft: false, prerelease: false, ...extra }) };
};
const installed = { ok: true, folder: '/Applications/Reel.app', parent: '/Applications', top: 'Reel.app', target: 'darwin-arm64' };
const service = (options = {}) => new UpdateService({
  version: '0.2.0', platform: 'darwin', arch: 'arm64', execPath: '/Applications/Reel.app/Contents/MacOS/Reel', name: 'Reel',
  userData: '/nowhere', publicKey: null, fetch: latest('v0.3.0'), openExternal: async () => {}, enabled: () => true,
  setTimer: () => 0, clearTimer: () => {}, now: () => 1000, locate: async () => installed, quit: () => {}, ...options
});

// A release server for the signed path: a manifest for 0.3.0, its signature, and the ZIP it names.
function signedRelease({ version = '0.3.0', zip = Buffer.from('zip bytes for the test'), tamper = false } = {}) {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const name = `reel-desktop-macos-arm64-v${version}.zip`;
  const manifest = Buffer.from(JSON.stringify({ schema: 1, product: 'reel-desktop', repository: REPOSITORY, version, tag: 'v' + version, date: '2026-10-30T00:00:00.000Z',
    files: { 'darwin-arm64': { name, sha256: createHash('sha256').update(zip).digest('hex'), size: zip.length } } }));
  const signature = sign(null, tamper ? Buffer.concat([manifest, Buffer.from(' ')]) : manifest, privateKey).toString('base64');
  const requests = [];
  const fetch = async url => {
    requests.push(url);
    if (url === `${RELEASES}/latest/download/${MANIFEST}`) return new Response(manifest);
    if (url === `${RELEASES}/latest/download/${SIGNATURE}`) return new Response(signature);
    if (url === `${RELEASES}/download/v${version}/${name}`) return new Response(zip);
    return new Response(null, { status: 404 });
  };
  return { fetch, requests, key: publicKey.export({ format: 'der', type: 'spki' }).toString('base64'), name };
}

test('versions compare by number, and a pre-release sorts before its release', () => {
  assert.equal(compareVersions('v0.10.0', '0.9.9'), 1);
  assert.equal(compareVersions('1.0.0', 'v1.0.0'), 0);
  assert.equal(compareVersions('1.0.0-rc.1', '1.0.0'), -1);
  assert.ok(Number.isNaN(compareVersions('latest', '1.0.0')));
});

test('release links stay on this repository', () => {
  assert.equal(releasePage('v1.2.3'), `https://github.com/${REPOSITORY}/releases/tag/v1.2.3`);
  for (const tag of ['v1.2', '1.2.3', 'v1.2.3/../../evil', 'v1.2.3?x']) assert.throws(() => releasePage(tag));
});

test('a build without the update key reports a newer release and opens its page', async () => {
  const opened = [], updates = service({ openExternal: async url => { opened.push(url); } }), states = [];
  await updates.start();
  assert.equal(updates.state.mode, 'download');
  assert.equal(updates.state.problem, null, 'no key is not something the person can fix');
  updates.subscribe(state => states.push(state.status));
  assert.equal((await updates.check()).status, 'available');
  assert.equal(updates.state.version, '0.3.0');
  assert.deepEqual(states, ['checking', 'available']);
  assert.equal(await updates.download(), true);
  assert.deepEqual(opened, [`https://github.com/${REPOSITORY}/releases/tag/v0.3.0`]);
  assert.equal(updates.install(), false);
});

test('the same or an older release, drafts, pre-releases and bad answers offer nothing', async () => {
  assert.equal((await service({ fetch: latest('v0.2.0') }).check()).status, 'current');
  assert.equal((await service({ fetch: latest('v0.1.9') }).check()).status, 'current');
  for (const extra of [{ draft: true }, { prerelease: true }]) assert.equal((await service({ fetch: latest('v0.3.0', extra) }).check()).status, 'error');
  assert.equal((await service({ fetch: latest('nightly') }).check()).status, 'error');
  assert.equal((await service({ fetch: async () => ({ ok: false, status: 500 }) }).check()).status, 'error');
  assert.equal((await service({ fetch: async () => ({ ok: false, status: 404 }) }).check()).status, 'current', 'no published release yet');
  assert.equal((await service({ fetch: async () => { throw new Error('offline'); } }).check()).status, 'error');
  const nothing = service({ fetch: latest('v0.2.0') });
  await nothing.check();
  assert.equal(await nothing.download(), false);
});

test('scheduled checks respect the setting; a check from Settings runs anyway', async () => {
  let calls = 0, enabled = false;
  const updates = service({ enabled: () => enabled, fetch: async (...args) => { calls++; return latest('v0.3.0')(...args); } });
  assert.equal((await updates.check()).status, 'off');
  assert.equal(calls, 0);
  assert.equal((await updates.check({ manual: true })).status, 'available');
  enabled = true;
  assert.equal((await updates.check()).status, 'available');
  assert.equal(calls, 2);
});

test('the schedule checks soon after launch, then every twelve hours, until stopped', async () => {
  const timers = [], cleared = [];
  const updates = service({ setTimer: (callback, delay) => { timers.push({ callback, delay }); return timers.length; }, clearTimer: id => cleared.push(id) });
  await updates.start();
  assert.equal(timers[0].delay, 30_000);
  timers[0].callback();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(updates.state.status, 'available');
  assert.equal(timers[1].delay, 12 * 3_600_000);
  updates.stop();
  assert.ok(cleared.includes(2));
});

test('a copy that cannot replace itself says why and offers the release page', async () => {
  const { fetch, key } = signedRelease();
  for (const reason of ['location', 'translocated', 'permission', 'sandbox']) {
    const updates = service({ publicKey: key, locate: async () => ({ ok: false, reason }), fetch: async url => url === API ? latest('v0.3.0')(url) : fetch(url) });
    await updates.start();
    assert.deepEqual([updates.state.mode, updates.state.problem], ['download', reason]);
    assert.equal((await updates.check()).status, 'available');
    assert.equal(updates.state.problem, reason, 'the reason stays after a check');
  }
});

test('a copy that can replace itself downloads, checks and stages the signed release, then swaps it in as Reel quits', async () => {
  const root = await mkdtemp(join(tmpdir(), 'reel-updates-')), staging = join(root, '.reel-update-0.3.0-abcd1234');
  try {
    const release = signedRelease(), staged = [], launched = [], states = [];
    let quits = 0;
    const updates = service({
      publicKey: release.key, fetch: release.fetch, userData: root, quit: () => { quits++; },
      stage: async options => {
        // The ZIP is on disk, whole, by the time it is staged.
        staged.push({ ...options, bytes: await readFile(options.zip, 'utf8') });
        await mkdir(join(staging, 'Reel.app'), { recursive: true });
        return { staging, staged: join(staging, 'Reel.app') };
      },
      launch: (command, args, options) => { launched.push({ command, args, options }); return { unref() {} }; }
    });
    await updates.start();
    assert.equal(updates.state.mode, 'install');
    updates.subscribe(state => states.push(state.status));
    assert.equal((await updates.check()).status, 'ready');
    assert.equal(updates.state.version, '0.3.0');
    assert.ok(states.includes('downloading'));
    assert.equal(staged.length, 1);
    assert.equal(staged[0].bytes, 'zip bytes for the test');
    assert.equal(staged[0].location, installed);
    // The download folder is cleared once the release is staged.
    await assert.rejects(stat(join(root, 'updates')));
    assert.equal((await updates.check()).status, 'ready', 'no second download once ready');
    assert.equal(release.requests.filter(url => url.endsWith('.zip')).length, 1);

    assert.equal(updates.install(), true);
    assert.equal(quits, 1);
    assert.equal(updates.finishOnQuit(), true);
    assert.equal(updates.finishOnQuit(), false, 'the helper starts once');
    assert.equal(launched.length, 1);
    assert.deepEqual(launched[0].command, '/bin/sh');
    assert.equal(launched[0].options.detached, true);
    const script = await readFile(join(staging, 'finish-update.sh'), 'utf8');
    assert.match(script, /app='\/Applications\/Reel\.app'/);
    assert.match(script, /\/usr\/bin\/open -n "\$app"/);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('an update that is ready when Reel quits normally goes in without starting Reel again', async () => {
  const root = await mkdtemp(join(tmpdir(), 'reel-updates-')), staging = join(root, 'staging');
  try {
    const release = signedRelease();
    const updates = service({ publicKey: release.key, fetch: release.fetch, userData: root,
      stage: async () => { await mkdir(join(staging, 'Reel.app'), { recursive: true }); return { staging, staged: join(staging, 'Reel.app') }; },
      launch: () => ({ unref() {} }) });
    assert.equal(updates.finishOnQuit(), false, 'nothing to install yet');
    await updates.start();
    await updates.check();
    assert.equal(updates.finishOnQuit(), true);
    assert.doesNotMatch(await readFile(join(staging, 'finish-update.sh'), 'utf8'), /open -n/);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('a manifest with a bad signature is refused before anything is downloaded', async () => {
  const release = signedRelease({ tamper: true }), updates = service({ publicKey: release.key, fetch: release.fetch, stage: async () => assert.fail('nothing to stage') });
  await updates.start();
  const state = await updates.check();
  assert.deepEqual([state.status, state.problem], ['error', 'signature']);
  assert.equal(release.requests.filter(url => url.endsWith('.zip')).length, 0);
});

test('a manifest signed with another key is refused', async () => {
  const release = signedRelease(), other = signedRelease();
  const updates = service({ publicKey: other.key, fetch: release.fetch });
  await updates.start();
  assert.equal((await updates.check()).problem, 'signature');
});

test('a download that does not match the manifest is thrown away', async () => {
  const root = await mkdtemp(join(tmpdir(), 'reel-updates-'));
  try {
    const release = signedRelease();
    const fetch = async url => url.endsWith('.zip') ? new Response('zip bytes for the tesT') : release.fetch(url);
    const updates = service({ publicKey: release.key, fetch, userData: root, stage: async () => assert.fail('nothing to stage') });
    await updates.start();
    const state = await updates.check();
    assert.deepEqual([state.status, state.problem], ['error', 'download']);
    await assert.rejects(stat(join(root, 'updates')));
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('a release published without a manifest falls back to offering its page', async () => {
  const release = signedRelease();
  const fetch = async url => url === API ? latest('v0.4.0')(url) : url.includes('/latest/download/') ? new Response(null, { status: 404 }) : release.fetch(url);
  const updates = service({ publicKey: release.key, fetch });
  await updates.start();
  const state = await updates.check();
  assert.deepEqual([state.status, state.version, state.mode, state.problem], ['available', '0.4.0', 'install', null]);
});

test('an older or equal signed release is current', async () => {
  const release = signedRelease({ version: '0.2.0' }), updates = service({ publicKey: release.key, fetch: release.fetch });
  await updates.start();
  assert.equal((await updates.check()).status, 'current');
});

test('after a failed swap the next run offers the release page instead of trying again', async () => {
  const root = await mkdtemp(join(tmpdir(), 'reel-updates-'));
  try {
    await writeFile(join(root, 'update-result.json'), JSON.stringify({ version: '0.3.0', ok: false }));
    const release = signedRelease();
    const updates = service({ publicKey: release.key, userData: root, fetch: async url => url === API ? latest('v0.3.0')(url) : release.fetch(url) });
    await updates.start();
    assert.deepEqual([updates.state.mode, updates.state.problem], ['download', 'install']);
    assert.equal((await updates.check()).status, 'available');
    assert.equal(release.requests.length, 0, 'the signed release is not tried again');
    await assert.rejects(stat(join(root, 'update-result.json')), 'the outcome is read once');
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('a QA build checks only its loopback server', async () => {
  const calls = [];
  const updates = service({ releases: 'http://127.0.0.1:19999/releases', fetch: async url => { calls.push(url); return new Response(null, { status: 404 }); } });
  assert.equal((await updates.check()).status, 'current');
  assert.deepEqual(calls, []);
});
