import { test, expect, type Page } from '@playwright/test';

const fixture = 'http://127.0.0.1:18771';
async function connect(page: Page): Promise<void> {
  await page.goto('/');
  await page.getByLabel('Server address', { exact: true }).fill(fixture);
  await page.getByLabel('Username', { exact: true }).fill('experience');
  await page.getByLabel('Password', { exact: true }).fill('demo');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.locator('.hero h1')).toBeVisible();
}
async function artworkReady(page: Page): Promise<void> {
  await expect.poll(() => page.locator('.hero-stage img[data-art]').evaluate(node => {
    const image = node as HTMLImageElement;
    return image.complete && image.naturalWidth > 0;
  })).toBe(true);
}

test.beforeEach(async ({ request }) => { await request.post(fixture + '/qa/reset'); });

test('featured choices update the real title and preserve focus, with working details and play actions', async ({ page }, info) => {
  await connect(page);
  const choice = page.getByRole('button', { name: 'Feature After the Last Light', exact: true });
  await choice.click();
  await expect(choice).toHaveAttribute('aria-pressed', 'true');
  await expect(choice).toBeFocused();
  await expect(page.locator('.hero h1')).toHaveText('After the Last Light');
  await artworkReady(page);
  await page.screenshot({ path: info.outputPath('home-wide.png'), fullPage: false });
  await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  await expect(page.locator('.detail-intro h1')).toHaveText('After the Last Light');
  await page.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(page.locator('.hero h1')).toHaveText('After the Last Light');
  await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click();
  await expect(page.locator('#player-title')).toHaveText('After the Last Light');
  await expect.poll(() => page.locator('#video').evaluate(node => (node as HTMLVideoElement).currentTime)).toBeGreaterThan(1);
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await expect(page.locator('.hero h1')).toHaveText('After the Last Light');
});

test('home shortcuts open the intended catalog and sidebar Search finds a title without extra navigation', async ({ page }) => {
  await connect(page);
  for (const category of ['Movies', 'Series']) {
    await page.locator('.home-categories').getByRole('button', { name: category, exact: true }).click();
    await expect(page.locator('#browse-category-' + category)).toHaveAttribute('aria-pressed', 'true');
    await page.locator('#rail').getByRole('button', { name: 'Home', exact: true }).click();
  }
  await page.locator('.home-categories').getByRole('button', { name: 'New episodes', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'New episodes', exact: true })).toBeVisible();
  await expect(page.locator('#browse-category-Episodes')).toHaveAttribute('aria-pressed', 'true');
  await page.locator('#rail').getByRole('button', { name: 'Home', exact: true }).click();
  // Home does not repeat Search in its chips; the sidebar (or the phone tab bar) is the one way in.
  await expect(page.locator('.home-categories').getByRole('button', { name: 'Movies', exact: true })).toBeVisible();
  await expect(page.locator('.home-categories').getByRole('button', { name: /search/i })).toHaveCount(0);
  await page.locator('#rail').getByRole('button', { name: 'Search', exact: true }).click();
  await expect(page.getByRole('searchbox')).toBeFocused();
  await page.getByRole('searchbox').fill('After the Last Light');
  await expect(page.locator('.media-grid .media-card').first()).toContainText('After the Last Light');
});

test('series episodes expose separate detail and playback actions with real resume state', async ({ page }, info) => {
  await connect(page);
  await page.getByRole('button', { name: 'Feature Out of the Blue', exact: true }).click();
  await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  await expect(page.locator('.episode-row')).toHaveCount(3);
  await page.screenshot({ path: info.outputPath('series-details.png'), fullPage: true });
  const first = page.locator('.episode-row[data-id="episode-1-1"]');
  await first.locator('.episode-main').click();
  await expect(page.locator('.detail-intro h1')).toHaveText('A new beginning');
  await page.getByRole('button', { name: 'Back', exact: true }).click();
  await first.locator('.episode-play').click();
  await expect(page.locator('#player-title')).toHaveText('Out of the Blue');
  await expect.poll(() => page.locator('#video').evaluate(node => (node as HTMLVideoElement).currentTime)).toBeGreaterThan(1);
  await page.locator('#video').focus(); await page.keyboard.press('Space');
  await expect.poll(() => page.locator('#video').evaluate(node => (node as HTMLVideoElement).paused)).toBe(true);
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await expect(page.locator('.episode-row[data-id="episode-1-1"] .episode-main')).toBeVisible();
});

test('finished video can replay from the player with a fresh advancing timeline', async ({ page }) => {
  await connect(page);
  await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click();
  await expect.poll(() => page.locator('#video').evaluate(node => (node as HTMLVideoElement).currentTime)).toBeGreaterThan(1);
  await page.getByRole('button', { name: 'Playback options', exact: true }).click();
  await page.getByLabel('Chapter', { exact: true }).selectOption('5');
  await page.getByRole('button', { name: 'Close playback options', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Play again', exact: true })).toBeVisible({ timeout: 20000 });
  await page.getByRole('button', { name: 'Play again', exact: true }).click();
  await expect.poll(() => page.locator('#video').evaluate(node => {
    const video = node as HTMLVideoElement;
    return !video.ended && !video.paused && video.currentTime > 0.2 && video.currentTime < 5;
  })).toBe(true);
  await expect(page.getByRole('button', { name: 'Play again', exact: true })).toBeHidden();
});

for (const width of [320, 390, 800, 1440, 1920]) {
  test(`discovery stays usable at ${width}px with keyboard and no document overflow`, async ({ page }, info) => {
    await page.setViewportSize({ width, height: width < 500 ? 844 : 900 });
    await connect(page);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    const choice = page.getByRole('button', { name: 'Feature After the Last Light', exact: true });
    await choice.focus();
    await choice.press('Enter');
    await expect(page.locator('.hero h1')).toHaveText('After the Last Light');
    await expect(choice).toBeFocused();
    await artworkReady(page);
    await page.screenshot({ path: info.outputPath(`home-${width}.png`), fullPage: false });
    await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
    await expect(page.locator('.detail-intro h1')).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.getByRole('button', { name: 'Back', exact: true }).click();
    await page.locator('.home-categories').getByRole('button', { name: 'New episodes', exact: true }).click();
    await expect(page.getByRole('heading', { name: 'New episodes', exact: true })).toBeVisible();
  });
}
