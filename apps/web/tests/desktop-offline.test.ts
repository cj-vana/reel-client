import { test } from 'node:test';
import assert from 'node:assert/strict';
import { downloadable, downloadRequest, downloadStatus, offlineBridge, offlineURL, perHour, type OfflineEntry } from '../src/desktop-offline.ts';
import { type Account, type MediaItem, TICKS } from '../src/types.ts';

const account: Account = { id: 'https://media.example.test|user', server: 'https://media.example.test', token: 'synthetic-token', userId: 'user', name: 'Alex', serverName: 'Test', remember: true };
const episode: MediaItem = { Id: 'episode-1', Name: 'The way back', Type: 'Episode', SeriesName: 'Out of the Blue', ParentIndexNumber: 1, IndexNumber: 3, RunTimeTicks: 1500 * TICKS, MediaSources: [{ Id: 'source-a' }, { Id: 'source-b' }] };
const entry = (change: Partial<OfflineEntry>): OfflineEntry => ({ id: '11111111-1111-4111-8111-111111111111', itemId: 'episode-1', title: 'Out of the Blue', subtitle: 'S1 E3 · The way back', runtime: 1500, size: 'small', state: 'complete', progress: 1, bytes: 0, position: 0, error: null, art: false, createdAt: 1, ...change });

test('films and episodes with a version can be downloaded', () => {
  assert.equal(downloadable(episode), true);
  assert.equal(downloadable({ ...episode, Type: 'Series' }), false);
  assert.equal(downloadable({ ...episode, MediaSources: [] }), false);
});

test('a download request names the account, the chosen version and how the title reads offline', () => {
  assert.deepEqual(downloadRequest(account, 'device-1', episode, 'high', 'source-b'), {
    accountId: account.id, server: account.server, token: 'synthetic-token', userId: 'user', deviceId: 'device-1', itemId: 'episode-1', mediaSourceId: 'source-b',
    size: 'high', title: 'Out of the Blue', subtitle: 'S1 E3 · The way back', runtime: 1500
  });
  assert.equal(downloadRequest(account, 'device-1', episode, 'small').mediaSourceId, 'source-a');
  const film = downloadRequest(account, 'device-1', { Id: 'movie-1', Name: 'A quiet film', Type: 'Movie', ProductionYear: 2024, MediaSources: [{ Id: 'm' }] }, 'standard');
  assert.equal(film.title, 'A quiet film'); assert.equal(film.subtitle, '2024'); assert.equal(film.runtime, 0);
});

test('storage per hour comes from the bitrates; statuses read plainly', () => {
  assert.equal(perHour(1_872_000), 'About 0.9 GB an hour');
  assert.equal(downloadStatus(entry({ state: 'queued' })), 'Waiting to download');
  assert.equal(downloadStatus(entry({ state: 'downloading', progress: 0.427 })), 'Downloading, 42%');
  assert.equal(downloadStatus(entry({ state: 'failed', error: 'Your server answered 500.' })), 'Your server answered 500.');
  assert.equal(downloadStatus(entry({ bytes: 2_400_000_000 })), 'Data saver · 480p · 2.4 GB');
  assert.equal(offlineURL(entry({})), 'reel://app/offline/11111111-1111-4111-8111-111111111111/index.m3u8');
});

test('the downloads bridge is used only when it has every operation', () => {
  const bridge = { list: async () => ({ ok: true }), start: async () => ({ ok: true }), remove: async () => ({ ok: true }), forget: async () => ({ ok: true }), position: async () => ({ ok: true }), onChange: () => () => {} };
  assert.equal(offlineBridge(bridge), bridge);
  assert.equal(offlineBridge({ ...bridge, forget: undefined }), undefined);
});
