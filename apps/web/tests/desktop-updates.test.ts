import { test } from 'node:test';
import assert from 'node:assert/strict';
import { updatesBridge, updateSummary, type UpdateState } from '../src/desktop-updates.ts';

const state = (status: UpdateState['status'], version: string | null = null): UpdateState => ({ status, version, mode: 'download', checkedAt: null });

test('the updates bridge is used only when it has every operation', () => {
  const methods = { state: async () => ({ ok: true }), check: async () => ({ ok: true }), install: async () => ({ ok: true }), download: async () => ({ ok: true }), onChange: () => () => {} };
  assert.equal(updatesBridge(methods), methods);
  assert.equal(updatesBridge({ ...methods, install: undefined }), undefined);
  assert.equal(updatesBridge(undefined), undefined);
});

test('Settings offers one action that fits where the update stands', () => {
  assert.deepEqual(updateSummary(state('ready', '0.3.0')), { text: 'Reel 0.3.0 is ready.', action: { id: 'install-update', label: 'Restart to update' } });
  assert.deepEqual(updateSummary(state('available', '0.3.0')), { text: 'Reel 0.3.0 is available.', action: { id: 'download-update', label: 'Download' } });
  assert.deepEqual(updateSummary(state('ready')), { text: 'A new version of Reel is ready.', action: { id: 'install-update', label: 'Restart to update' } });
  assert.equal(updateSummary(state('checking')).action, undefined);
  assert.equal(updateSummary(state('downloading')).action, undefined);
  for (const status of ['current', 'error', 'off', 'idle'] as const) assert.equal(updateSummary(state(status)).action?.id, 'check-update');
  assert.equal(updateSummary(undefined).action?.id, 'check-update');
});
