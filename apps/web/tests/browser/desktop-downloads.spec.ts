import { test, expect, type Page } from '@playwright/test';
import type { DesktopBridge, DesktopInitialization } from '../../src/desktop.ts';
import type { DownloadRequest, OfflineBridge, OfflineEntry } from '../../src/desktop-offline.ts';

// The desktop download screens, with fake preload bridges standing in for the main process. The download
// manager itself is tested in apps/desktop/tests/offline.test.mjs.
const fixture = 'http://127.0.0.1:18771';
type OfflineQA = { starts: DownloadRequest[]; removes: string[]; update(change: Partial<OfflineEntry>): void };
declare global { interface Window { __offlineQA: OfflineQA } }

async function desktopWithDownloads(page: Page): Promise<void> {
  await page.route('**/reel-config.js', route => route.fulfill({ contentType: 'application/javascript', body: "window.REEL_CONFIG={platform:'desktop',previewMode:true};" }));
  await page.addInitScript(() => {
    const initial: Extract<DesktopInitialization, { ok: true }> = { ok: true, storeState: 'ready', revision: 0, savedConnections: { accounts: [], activeId: null }, deviceId: '12345678-1234-1234-1234-123456789abc', preferences: { quality: 120000000, history: false }, preferenceRevision: 0 };
    const desktop: DesktopBridge = {
      initialize: async () => structuredClone(initial),
      saveConnections: async value => { initial.revision = value.expectedRevision + 1; initial.savedConnections = { accounts: value.accounts, activeId: value.activeId }; return { ok: true, revision: initial.revision }; },
      savePreferences: async value => ({ ok: true, revision: value.expectedRevision + 1 }),
      onCloseRequested: () => () => {}, acknowledgeClose: async () => ({ ok: true })
    };
    let entries: OfflineEntry[] = [], listener: () => void = () => {};
    const qa: OfflineQA = { starts: [], removes: [], update: change => { entries = entries.map(entry => ({ ...entry, ...change })); listener(); } };
    const offline: OfflineBridge = {
      list: async () => ({ ok: true, items: structuredClone(entries) }),
      start: async request => {
        qa.starts.push(structuredClone(request));
        const entry: OfflineEntry = { id: '11111111-1111-4111-8111-111111111111', itemId: request.itemId, title: request.title, subtitle: request.subtitle, runtime: request.runtime, size: request.size, state: 'downloading', progress: 0.4, bytes: 0, position: 0, error: null, art: false, createdAt: 1 };
        entries = [entry]; return { ok: true, item: entry };
      },
      remove: async (_account, id) => { qa.removes.push(id); entries = entries.filter(entry => entry.id !== id); listener(); return { ok: true }; },
      forget: async () => ({ ok: true }), position: async () => ({ ok: true }),
      onChange: callback => { listener = callback; return () => {}; }
    };
    Object.defineProperty(window, 'ReelDesktop', { value: Object.freeze(desktop) });
    Object.defineProperty(window, 'ReelOffline', { value: Object.freeze(offline) });
    window.__offlineQA = qa;
  });
}

test('a film downloads at a chosen size, shows its progress, and can be removed', async ({ page, request }) => {
  await request.post(fixture + '/qa/reset');
  await desktopWithDownloads(page);
  await page.goto('/');
  for (const [label, value] of [['Server address', fixture], ['Username', 'downloads-desk'], ['Password', 'demo']]) await page.getByLabel(label, { exact: true }).fill(value);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.locator('.hero h1')).toBeVisible();
  await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  const menu = page.locator('#download-menu');
  await menu.locator('summary').click();
  await expect(menu.getByRole('button', { name: /High · 1080p/ })).toContainText('About 2.8 GB an hour');
  await expect(menu.getByRole('button', { name: /Data saver · 480p/ })).toContainText('About 0.5 GB an hour');
  await menu.getByRole('button', { name: /Standard · 720p/ }).click();
  const starts = await page.evaluate(() => window.__offlineQA.starts);
  expect(starts).toHaveLength(1);
  expect(starts[0]).toMatchObject({ server: fixture, token: 'fixture-downloads-desk', userId: 'downloads-desk', size: 'standard', deviceId: '12345678-1234-1234-1234-123456789abc' });
  expect(starts[0].mediaSourceId).toBe(starts[0].itemId + '-source');
  await expect(page.locator('#download-control')).toContainText('40%');

  await page.locator('#rail').getByRole('button', { name: 'Downloads', exact: true }).click();
  const row = page.locator('.download-row');
  await expect(row).toContainText(starts[0].title);
  await expect(row).toContainText('Downloading, 40%');
  await expect(row.getByRole('button', { name: 'Cancel', exact: true })).toBeVisible();
  await page.evaluate(() => window.__offlineQA.update({ state: 'complete', progress: 1, bytes: 5_200_000 }));
  await expect(row).toContainText('Standard · 720p · 5 MB');
  await expect(row.getByRole('button', { name: 'Play', exact: true })).toBeVisible();
  await row.getByRole('button', { name: 'Remove', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'No downloads yet' })).toBeVisible();
  expect(await page.evaluate(() => window.__offlineQA.removes)).toEqual(['11111111-1111-4111-8111-111111111111']);
});
