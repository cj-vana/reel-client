import { test, expect, type Page } from '@playwright/test';

async function connect(page: Page, remember = false): Promise<void> {
  await page.goto('/');
  await page.getByLabel('Server address', { exact: true }).fill('http://127.0.0.1:18771');
  await page.getByLabel('Username', { exact: true }).fill('shell-experience');
  await page.getByLabel('Password', { exact: true }).fill('demo');
  if (remember) await page.getByRole('checkbox', { name: 'Remember this connection on this device' }).check();
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.locator('.hero h1')).toBeVisible();
}
async function destination(page: Page, name: string): Promise<void> {
  if (page.viewportSize()!.width <= 767 && !['Home', 'Library', 'Search', 'Favorites'].includes(name)) {
    await page.getByRole('button', { name: 'More', exact: true }).click();
    await expect(page.getByRole('dialog', { name: 'More destinations' })).toBeVisible();
  }
  await page.locator('#rail').getByRole('button', { name, exact: true }).click();
}

for (const width of [390, 1440]) {
  test(`all navigation destinations are reachable at ${width}px`, async ({ page }, info) => {
    await page.setViewportSize({ width, height: 900 });
    await connect(page);
    for (const name of ['Library', 'Search', 'Favorites', 'Music', 'Photos', 'Books', 'Live TV', 'Devices', 'Settings', 'Servers']) {
      await destination(page, name);
      await expect(page.locator('#rail [aria-current="page"]')).toHaveAttribute('data-route', name === 'Servers' ? 'Connections' : name);
      await expect(page.locator('#content h1')).toBeVisible();
      await expect(page.locator('#content')).not.toHaveAttribute('inert', '');
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      if (name === 'Settings') await expect(page.getByLabel('Streaming quality')).toBeVisible();
      if (name === 'Search') await expect(page.getByRole('searchbox')).toBeFocused();
    }
    await destination(page, 'Home');
    await expect(page.locator('.hero h1')).toBeVisible();
    await page.screenshot({ path: info.outputPath(`navigation-${width}.png`) });
  });
}

test('More traps keyboard focus, closes without activating the background, and survives resize', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await connect(page);
  const more = page.getByRole('button', { name: 'More', exact: true });
  const menu = page.locator('#mobile-more-menu');
  await more.click();
  await expect(page.locator('#content')).toHaveAttribute('inert', '');
  await expect(menu.getByRole('button', { name: 'Music', exact: true })).toBeFocused();
  for (let i = 0; i < 14; i++) {
    await page.keyboard.press('Tab');
    expect(await menu.evaluate(node => node.contains(document.activeElement))).toBe(true);
  }
  await page.keyboard.press('Escape');
  await expect(menu).toBeHidden(); await expect(more).toBeFocused();
  await more.click();
  await page.getByRole('button', { name: 'Close more destinations' }).click();
  await expect(more).toBeFocused();
  await more.click();
  await page.mouse.click(12, 90);
  await expect(menu).toBeHidden();
  await expect(page.locator('.hero h1')).toBeVisible();
  await more.click();
  await page.setViewportSize({ width: 1440, height: 900 });
  await expect(menu).toBeVisible(); await expect(menu).not.toHaveAttribute('role', 'dialog');
  await expect(page.locator('#content')).not.toHaveAttribute('inert', '');
  await menu.getByRole('button', { name: 'Books', exact: true }).click();
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(menu).toBeHidden(); await expect(more).toBeFocused();
  await expect(more).toHaveClass(/active/);
});

test('signed-out Settings keeps branding, preference persistence, and a usable connection return', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto('/');
  await page.locator('#rail').getByRole('button', { name: 'Settings', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Settings', exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Reel home', exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'More', exact: true })).toHaveCount(0);
  await page.getByLabel('Streaming quality').selectOption('8000000');
  await page.getByRole('button', { name: 'Manage servers', exact: true }).click();
  await expect(page.getByLabel('Server address', { exact: true })).toBeVisible();
  await page.reload();
  await page.locator('#rail').getByRole('button', { name: 'Settings', exact: true }).click();
  await expect(page.getByLabel('Streaming quality')).toHaveValue('8000000');
  await page.getByRole('button', { name: 'Reel home', exact: true }).click();
  await expect(page.getByLabel('Server address', { exact: true })).toBeVisible();
});

test('saved connection relaunch restores the new shell while session-only reload returns to sign-in', async ({ page }) => {
  await connect(page, true);
  await page.reload(); await expect(page.locator('.hero h1')).toBeVisible();
  await destination(page, 'Servers');
  await page.getByRole('button', { name: 'Sign out', exact: true }).click();
  await expect(page.getByLabel('Server address', { exact: true })).toBeVisible();
  await connect(page, false);
  await page.reload();
  await expect(page.getByLabel('Server address', { exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Home', exact: true })).toHaveCount(0);
});


test('new destinations start at the top while Back and player Close restore the scrolled title', async ({ page }, info) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await connect(page);
  await page.getByRole('button', { name: 'Feature Out of the Blue', exact: true }).click();
  await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  // The last episode of the season sits below the fold on a phone, so reaching it scrolls Details.
  const episodePlay = page.locator('.episode-row[data-id="episode-1-3"] .episode-play');
  await episodePlay.scrollIntoViewIfNeeded();
  const detailScroll = await page.evaluate(() => scrollY);
  expect(detailScroll).toBeGreaterThan(200);
  await episodePlay.click();
  await expect.poll(() => page.locator('#video').evaluate(video => (video as HTMLVideoElement).currentTime)).toBeGreaterThan(.2);
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await expect(episodePlay).toBeFocused();
  await expect.poll(() => page.evaluate(() => scrollY)).toBeCloseTo(detailScroll, 0);
  await destination(page, 'Settings');
  await expect(page.getByRole('heading', { name: 'Settings', exact: true })).toBeVisible();
  await expect.poll(() => page.evaluate(() => scrollY)).toBe(0);
  await expect(page.getByLabel('Streaming quality')).toBeInViewport();
  await page.screenshot({ path: info.outputPath('settings-after-scrolled-detail.png') });
  await page.setViewportSize({ width: 390, height: 568 });
  await page.getByRole('heading', { name: 'About Reel', exact: true }).scrollIntoViewIfNeeded();
  expect(await page.evaluate(() => scrollY)).toBeGreaterThan(100);
  await destination(page, 'Library');
  await expect(page.getByRole('heading', { name: 'Library', exact: true })).toBeVisible();
  await expect.poll(() => page.evaluate(() => scrollY)).toBe(0);
  const title = page.locator('.browse-card').nth(18);
  await title.scrollIntoViewIfNeeded();
  const libraryScroll = await page.evaluate(() => scrollY);
  expect(libraryScroll).toBeGreaterThan(200);
  await title.click();
  await expect(page.locator('.detail-intro h1')).toBeVisible();
  await expect.poll(() => page.evaluate(() => scrollY)).toBe(0);
  await page.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(title).toBeFocused();
  await expect.poll(() => page.evaluate(() => scrollY)).toBeCloseTo(libraryScroll, 0);
  await destination(page, 'Home');
  await expect(page.locator('.hero h1')).toBeVisible();
  await expect.poll(() => page.evaluate(() => scrollY)).toBe(0);
});

test('the browser Back and Forward buttons, a reload and a typed address follow the screens', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await connect(page, true);
  await destination(page, 'Library'); await expect(page).toHaveURL(/#\/library$/);
  await destination(page, 'Search'); await expect(page).toHaveURL(/#\/search$/);
  await page.goBack(); await expect(page.locator('#content h1')).toHaveText('Library');
  await page.goForward(); await expect(page.locator('#content h1')).toHaveText('Search'); await expect(page).toHaveURL(/#\/search$/);
  // Back over an open sheet closes the sheet and stays on the screen.
  await page.getByRole('button', { name: 'More', exact: true }).click();
  await expect(page.getByRole('dialog', { name: 'More destinations' })).toBeVisible();
  await page.goBack();
  await expect(page.getByRole('dialog', { name: 'More destinations' })).toBeHidden();
  await expect(page.locator('#content h1')).toHaveText('Search'); await expect(page).toHaveURL(/#\/search$/);
  await page.reload(); await expect(page.locator('#content h1')).toHaveText('Search');
  // After a reload nothing is in memory, and Back and Forward still reach each screen in order.
  await page.goBack(); await expect(page.locator('#content h1')).toHaveText('Library'); await expect(page).toHaveURL(/#\/library$/);
  await page.goBack(); await expect(page.locator('.hero h1')).toBeVisible(); await expect(page).not.toHaveURL(/#/);
  await page.goForward(); await expect(page.locator('#content h1')).toHaveText('Library');
  await page.goForward(); await expect(page.locator('#content h1')).toHaveText('Search'); await expect(page).toHaveURL(/#\/search$/);
  // A title's address opens the title, and the page's own Back is the browser's.
  await page.goto('/#/title/series-7'); await expect(page.locator('.detail-intro h1')).toHaveText('Out of the Blue');
  await page.locator('#content').getByRole('button', { name: 'Back', exact: true }).click();
  await expect(page.locator('#content h1')).toHaveText('Search'); await expect(page).toHaveURL(/#\/search$/);
  // An address that is not one of Reel's changes nothing and is put right.
  await page.goto('/#/title/<b>not-a-title</b>');
  await expect(page).toHaveURL(/#\/search$/); await expect(page.locator('#content h1')).toHaveText('Search');
  // Search text never reaches the address.
  await page.getByRole('searchbox').fill('Out of the Blue'); await expect(page.locator('.media-card[data-id="series-7"]')).toBeVisible();
  await expect(page).toHaveURL(/#\/search$/);
});

test('a link opened while signed out shows its title after sign-in and leaves no address behind on sign-out', async ({ page }) => {
  await page.goto('/#/title/series-7');
  await expect(page.getByLabel('Username', { exact: true })).toBeVisible();
  await expect(page).not.toHaveURL(/series-7/);
  await page.getByLabel('Server address', { exact: true }).fill('http://127.0.0.1:18771');
  await page.getByLabel('Username', { exact: true }).fill('shell-experience');
  await page.getByLabel('Password', { exact: true }).fill('demo');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.locator('.detail-intro h1')).toHaveText('Out of the Blue'); await expect(page).toHaveURL(/#\/title\/series-7$/);
  await destination(page, 'Servers');
  await page.locator('#content [data-action="remove-connection"]').first().click();
  await expect(page.getByLabel('Username', { exact: true })).toBeVisible(); await expect(page).not.toHaveURL(/#/);
  await page.goBack();
  await expect(page.getByLabel('Username', { exact: true })).toBeVisible(); await expect(page).not.toHaveURL(/series-7/);
});
