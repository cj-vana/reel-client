import { test } from 'node:test';
import assert from 'node:assert/strict';
import { updatesBridge, updateSummary, type UpdateState } from '../src/desktop-updates.ts';

const state = (status: UpdateState['status'], version: string | null = null, extra: Partial<UpdateState> = {}): UpdateState => ({ status, version, mode: 'download', checkedAt: null, ...extra });

test('the updates bridge is used only when it has every operation', () => {
  const methods = { state: async () => ({ ok: true }), check: async () => ({ ok: true }), install: async () => ({ ok: true }), download: async () => ({ ok: true }), onChange: () => () => {} };
  assert.equal(updatesBridge(methods), methods);
  assert.equal(updatesBridge({ ...methods, install: undefined }), undefined);
  assert.equal(updatesBridge(undefined), undefined);
});

test('Settings offers one action that fits where the update stands', () => {
  assert.deepEqual(updateSummary(state('ready', '0.3.0', { mode: 'install' })), { text: 'Reel 0.3.0 is ready. It installs when Reel restarts or quits.', action: { id: 'install-update', label: 'Restart to update' } });
  assert.deepEqual(updateSummary(state('available', '0.3.0')), { text: 'Reel 0.3.0 is available.', action: { id: 'download-update', label: 'Download' } });
  assert.deepEqual(updateSummary(state('ready')), { text: 'A new version of Reel is ready. It installs when Reel restarts or quits.', action: { id: 'install-update', label: 'Restart to update' } });
  assert.equal(updateSummary(state('checking')).action, undefined);
  assert.equal(updateSummary(state('downloading')).action, undefined);
  for (const status of ['current', 'error', 'off', 'idle'] as const) assert.equal(updateSummary(state(status)).action?.id, 'check-update');
  assert.equal(updateSummary(undefined).action?.id, 'check-update');
});

test('a download shows its progress in steps of ten percent', () => {
  assert.equal(updateSummary(state('downloading', '0.3.0', { progress: 0 })).text, 'Downloading Reel 0.3.0, 0%');
  assert.equal(updateSummary(state('downloading', '0.3.0', { progress: 0.47 })).text, 'Downloading Reel 0.3.0, 40%');
  assert.equal(updateSummary(state('downloading', '0.3.0', { progress: 1 })).text, 'Downloading Reel 0.3.0, 100%');
});

test('a copy that cannot update itself says what the person can do about it', () => {
  assert.match(updateSummary(state('available', '0.3.0', { problem: 'location' })).text, /Move Reel to your Applications folder/);
  assert.match(updateSummary(state('available', '0.3.0', { problem: 'translocated' })).text, /Move Reel to your Applications folder/);
  assert.match(updateSummary(state('available', '0.3.0', { problem: 'permission' })).text, /download new versions yourself/);
  assert.match(updateSummary(state('available', '0.3.0', { problem: 'install' })).text, /could not install the last update/);
  assert.match(updateSummary(state('idle', null, { problem: 'location' })).text, /^Reel checks for a new version twice a day\. Move Reel/);
  assert.equal(updateSummary(state('idle', null, { mode: 'install', problem: null })).text, 'Reel checks for a new version twice a day.');
});

test('a failed update says which part failed and offers to try again', () => {
  for (const problem of ['signature', 'package'] as const) assert.deepEqual(updateSummary(state('error', '0.3.0', { problem })), { text: 'The update did not pass Reel’s checks, so it was not installed.', action: { id: 'check-update', label: 'Try again' } });
  assert.equal(updateSummary(state('error', '0.3.0', { problem: 'download' })).text, 'The update could not be downloaded.');
  assert.equal(updateSummary(state('error', null, { problem: null })).text, 'Reel could not check for updates.');
});
