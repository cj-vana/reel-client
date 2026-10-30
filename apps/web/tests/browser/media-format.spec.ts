import { test, expect } from '@playwright/test';
import { assertOpenFormatPanel } from './media-format-checks.ts';

const fixture = 'http://127.0.0.1:18771';

test('format disclosure preserves its controls with long captions, narrow windows and enlarged text', async ({ page, request }) => {
  await request.post(fixture + '/qa/reset');
  const caption = ('The original synthetic episode with a deliberately long descriptive caption ').repeat(3).trim();
  await page.route('**/Items/episode-1-1?*', async route => {
    const response = await route.fetch({ maxRedirects: 0 }); expect(response.status()).toBe(200);
    const item = await response.json(); item.Name = caption; item.UserData = { PlaybackPositionTicks: 0 };
    await route.fulfill({ response, json: item });
  });
  await page.goto('/');
  await page.getByLabel('Server address', { exact: true }).fill(fixture);
  await page.getByLabel('Username', { exact: true }).fill('media-format');
  await page.getByLabel('Password', { exact: true }).fill('demo');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.locator('.hero')).toBeVisible();
  await page.locator('#rail').getByRole('button', { name: 'Settings', exact: true }).click();
  // Private viewing starts off, so watch history is sent.
  await expect(page.locator('#history')).not.toBeChecked();
  await page.locator('#rail').getByRole('button', { name: 'Home', exact: true }).click();
  await page.locator('.media-card[data-id="series-7"]').first().click();
  await page.locator('.episode-row[data-id="episode-1-1"] .episode-main').click();
  await expect(page.locator('.detail-intro h1')).toHaveText(caption);
  await page.getByRole('button', { name: 'Play', exact: true }).click();
  await expect(page.locator('#player-state')).toBeHidden();
  await expect.poll(() => page.locator('#video').evaluate(element => (element as HTMLVideoElement).currentTime)).toBeGreaterThan(.1);
  await page.locator('#video').focus(); await page.keyboard.press('Space');
  await expect.poll(() => page.locator('#video').evaluate(element => (element as HTMLVideoElement).paused)).toBe(true);
  for (const viewport of [{ width: 320, height: 874 }, { width: 390, height: 844 }, { width: 844, height: 390 }]) {
    await page.setViewportSize(viewport); await page.getByRole('button', { name: 'Playback options', exact: true }).click();
    await assertOpenFormatPanel(page, viewport);
  }
  await page.setViewportSize({ width: 320, height: 874 });
  await page.addStyleTag({ content: ':root { font-size: 32px !important; }' });
  await page.getByRole('button', { name: 'Playback options', exact: true }).click();
  await assertOpenFormatPanel(page, { width: 320, height: 874 });
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await expect(page.locator('#player')).toBeHidden(); await expect(page.locator('.detail-intro h1')).toHaveText(caption);
  const state = async () => (await request.get(fixture + '/qa/state')).json();
  // Watch history reports the episode's start and stop; playing never marks it watched or favorite.
  await expect.poll(async () => (await state()).reports.map((entry: { path: string }) => entry.path))
    .toEqual(expect.arrayContaining(['/Sessions/Playing', '/Sessions/Playing/Stopped']));
  expect((await state()).calls.filter((entry: { path: string }) => /^\/User(?:Played|Favorite)Items/.test(entry.path))).toHaveLength(0);
});
