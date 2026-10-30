import { test, expect } from '@playwright/test';

test('public configuration enables personal library actions and sends watch history by default', async ({ page, request }) => {
  const fixture = 'http://127.0.0.1:18771';
  await page.route('https://media.release.test/**', async route => {
    const url = new URL(route.request().url());
    const response = await route.fetch({ url: fixture + url.pathname + url.search });
    await route.fulfill({ response });
  });
  await page.goto('/');
  await page.getByLabel('Server address', { exact: true }).fill('https://media.release.test');
  await page.getByLabel('Username', { exact: true }).fill('release-defaults');
  await page.getByLabel('Password', { exact: true }).fill('demo');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  await page.getByRole('button', { name: 'Favorite', pressed: false, exact: true }).click();
  await expect(page.getByRole('button', { name: 'Favorite', pressed: true, exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Watched', pressed: false, exact: true }).click();
  await expect(page.getByRole('button', { name: 'Watched', pressed: true, exact: true })).toBeVisible();
  await page.locator('.detail-intro [data-action="play"]').click();
  await expect.poll(() => page.locator('#video').evaluate(node => (node as HTMLVideoElement).currentTime)).toBeGreaterThan(.3);
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await page.locator('#rail').getByRole('button', { name: 'Settings', exact: true }).click();
  const history = page.getByLabel('Private viewing');
  await expect(history).toBeEnabled();
  await expect(history).not.toBeChecked();
  const calls = async () => {
    const state = await (await request.get(fixture + '/qa/state')).json();
    return state.calls.filter((call: { user?: string }) => call.user === 'release-defaults') as { path: string }[];
  };
  expect((await calls()).some(call => call.path.includes('/UserFavoriteItems/'))).toBe(true);
  expect((await calls()).some(call => call.path.includes('/UserPlayedItems/'))).toBe(true);
  // Playback start and stop reach the server without changing a setting.
  await expect.poll(async () => (await calls()).filter(call => call.path.startsWith('/Sessions/Playing')).map(call => call.path))
    .toEqual(expect.arrayContaining(['/Sessions/Playing', '/Sessions/Playing/Stopped']));
});
