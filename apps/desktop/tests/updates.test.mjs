import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { compareVersions, feedURL, releasePage, UpdateService, REPOSITORY } from '../src/updates.mjs';
import { updateFeed } from '../scripts/update-feed.mjs';

const release = (tag, extra = {}) => async url => {
  assert.equal(url, `https://api.github.com/repos/${REPOSITORY}/releases/latest`);
  return { ok: true, json: async () => ({ tag_name: tag, draft: false, prerelease: false, ...extra }) };
};
const service = (options = {}) => new UpdateService({ version: '0.2.0', arch: 'arm64', install: false, fetch: release('v0.3.0'), openExternal: async () => {}, enabled: () => true, setTimer: () => 0, clearTimer: () => {}, now: () => 1000, ...options });

test('versions compare by number, and a pre-release sorts before its release', () => {
  assert.equal(compareVersions('v0.10.0', '0.9.9'), 1);
  assert.equal(compareVersions('1.0.0', 'v1.0.0'), 0);
  assert.equal(compareVersions('1.0.0-rc.1', '1.0.0'), -1);
  assert.ok(Number.isNaN(compareVersions('latest', '1.0.0')));
});

test('feed and release links stay on this repository', () => {
  assert.equal(feedURL('arm64'), `https://github.com/${REPOSITORY}/releases/latest/download/reel-desktop-macos-arm64.json`);
  assert.equal(releasePage('v1.2.3'), `https://github.com/${REPOSITORY}/releases/tag/v1.2.3`);
  for (const tag of ['v1.2', '1.2.3', 'v1.2.3/../../evil', 'v1.2.3?x']) assert.throws(() => releasePage(tag));
});

test('an unsigned build reports a newer release and opens its page', async () => {
  const opened = [], updates = service({ openExternal: async url => { opened.push(url); } }), states = [];
  updates.subscribe(state => states.push(state.status));
  assert.deepEqual(await updates.check(), { status: 'available', version: '0.3.0', mode: 'download', checkedAt: 1000 });
  assert.deepEqual(states, ['checking', 'available']);
  assert.equal(await updates.download(), true);
  assert.deepEqual(opened, [`https://github.com/${REPOSITORY}/releases/tag/v0.3.0`]);
  assert.equal(updates.install(), false);
});

test('the same or an older release, drafts, pre-releases and bad answers offer nothing', async () => {
  assert.equal((await service({ fetch: release('v0.2.0') }).check()).status, 'current');
  assert.equal((await service({ fetch: release('v0.1.9') }).check()).status, 'current');
  for (const extra of [{ draft: true }, { prerelease: true }]) assert.equal((await service({ fetch: release('v0.3.0', extra) }).check()).status, 'error');
  assert.equal((await service({ fetch: release('nightly') }).check()).status, 'error');
  assert.equal((await service({ fetch: async () => ({ ok: false, status: 500 }) }).check()).status, 'error');
  assert.equal((await service({ fetch: async () => ({ ok: false, status: 404 }) }).check()).status, 'current', 'no published release yet');
  assert.equal((await service({ fetch: async () => { throw new Error('offline'); } }).check()).status, 'error');
  const nothing = service({ fetch: release('v0.2.0') });
  await nothing.check();
  assert.equal(await nothing.download(), false);
});

test('scheduled checks respect the setting; a check from Settings runs anyway', async () => {
  let calls = 0, enabled = false;
  const updates = service({ enabled: () => enabled, fetch: async (...args) => { calls++; return release('v0.3.0')(...args); } });
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
  updates.start();
  assert.equal(timers[0].delay, 30_000);
  timers[0].callback();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(updates.state.status, 'available');
  assert.equal(timers[1].delay, 12 * 3_600_000);
  updates.stop();
  assert.ok(cleared.includes(2));
});

class FakeUpdater extends EventEmitter {
  feeds = []; checks = 0; installs = 0;
  setFeedURL(options) { this.feeds.push(options); }
  checkForUpdates() { this.checks++; }
  quitAndInstall() { this.installs++; }
}

test('a signed macOS build downloads through Squirrel and restarts into the update', async () => {
  const updater = new FakeUpdater(), updates = service({ install: true, updater, fetch: async () => { throw new Error('not used'); } });
  assert.equal(updates.state.mode, 'install');
  await updates.check();
  assert.deepEqual(updater.feeds, [{ url: feedURL('arm64'), serverType: 'json' }]);
  updater.emit('update-available');
  assert.equal(updates.state.status, 'downloading');
  assert.equal((await updates.check()).status, 'downloading', 'no second check while downloading');
  assert.equal(updater.checks, 1);
  updater.emit('update-downloaded', {}, '', '0.3.0');
  assert.deepEqual(updates.state, { status: 'ready', version: '0.3.0', mode: 'install', checkedAt: 1000 });
  assert.equal(updates.install(), true);
  assert.equal(updater.installs, 1);
});

test('when Squirrel cannot update, the release check still offers the download', async () => {
  const updater = new FakeUpdater(), opened = [];
  const updates = service({ install: true, updater, openExternal: async url => { opened.push(url); } });
  await updates.check();
  updater.emit('error', new Error('Cannot update while running from a read-only volume'));
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(updates.state, { status: 'available', version: '0.3.0', mode: 'download', checkedAt: 1000 });
  assert.equal(await updates.download(), true);
  assert.equal(opened.length, 1);
  updater.emit('update-not-available');
  assert.equal(updates.state.status, 'current');
});

test('the release feed names one version, its ZIP on the release, and the ZIP digest and size', () => {
  const url = `https://github.com/${REPOSITORY}/releases/download/v0.3.0/reel-desktop-macos-arm64-v0.3.0.zip`, sha256 = 'a'.repeat(64);
  assert.deepEqual(updateFeed({ version: '0.3.0', url, sha256, size: 1234, date: '2026-10-30T00:00:00.000Z' }), {
    currentRelease: '0.3.0',
    releases: [{ version: '0.3.0', updateTo: { version: '0.3.0', pub_date: '2026-10-30T00:00:00.000Z', notes: '', name: '0.3.0', url, sha256, size: 1234 } }]
  });
  assert.throws(() => updateFeed({ version: '0.3.0-rc.1', url, sha256, size: 1, date: '' }));
  assert.throws(() => updateFeed({ version: '0.3.0', url: 'https://example.com/reel.zip', sha256, size: 1, date: '' }));
  assert.throws(() => updateFeed({ version: '0.3.0', url, sha256: 'nope', size: 1, date: '' }));
});
