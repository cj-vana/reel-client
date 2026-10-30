import { test, expect } from '@playwright/test';

test('native media failure and Retry preserve an intentional pause and confirmed position', async ({ page }) => {
  const fixture = 'http://127.0.0.1:18771';
  await page.goto('/');
  await page.getByLabel('Server address', { exact: true }).fill(fixture);
  await page.getByLabel('Username', { exact: true }).fill('native-error-paused');
  await page.getByLabel('Password', { exact: true }).fill('demo');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click();
  const video = page.locator('#video');
  const position = () => video.evaluate(element => (element as HTMLVideoElement).currentTime);
  await expect.poll(position).toBeGreaterThan(1);
  await video.focus(); await page.keyboard.press('Space');
  await expect.poll(() => video.evaluate(element => (element as HTMLVideoElement).paused)).toBe(true);
  // The player learns of a native-controls pause only from the pause event. The load() below runs the media
  // load algorithm, which discards media events still queued, so injecting the failure before the player has
  // shown the pause would erase the pause this test is about.
  await expect(page.locator('#player')).toHaveAttribute('data-state', 'paused');
  const pausedAt = await position();
  const negotiation = (url: URL) => url.origin === fixture && url.pathname === '/Items/movie-1/PlaybackInfo';
  const badMedia = (url: URL) => url.origin === fixture && url.pathname === '/Videos/movie-1/stream' && url.searchParams.get('qaRecovery') === 'invalid';
  await page.route(negotiation, pending => pending.fulfill({ status: 503, json: {} }));
  await page.route(badMedia, pending => pending.fulfill({ status: 200, contentType: 'video/mp4', body: 'Owned invalid media bytes for native error coverage' }));
  const nativeError = await video.evaluate((element, url) => new Promise<{ trusted: boolean; code: number | undefined }>(resolve => {
    const media = element as HTMLVideoElement;
    media.addEventListener('error', event => resolve({ trusted: event.isTrusted, code: media.error?.code }), { once: true, capture: true });
    media.src = url; media.load();
  }), fixture + '/Videos/movie-1/stream?qaRecovery=invalid');
  expect(nativeError.trusted).toBe(true); expect(nativeError.code).toBeGreaterThanOrEqual(3);
  await expect(page.getByRole('button', { name: 'Retry from saved position', exact: true })).toBeVisible();
  await page.unroute(negotiation); await page.unroute(badMedia);
  await page.getByRole('button', { name: 'Retry from saved position', exact: true }).click();
  await expect(page.locator('#player')).toHaveAttribute('data-state', 'paused');
  await expect.poll(position).toBeGreaterThan(pausedAt - .25);
  const recoveredAt = await position();
  await page.waitForTimeout(500);
  expect(Math.abs(await position() - recoveredAt)).toBeLessThan(.05);
  await video.focus(); await page.keyboard.press('Space');
  await expect.poll(position).toBeGreaterThan(recoveredAt + .3);
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await expect(page.locator('#player')).toBeHidden();
});
