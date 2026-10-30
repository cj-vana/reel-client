import { test, expect, type Page } from '@playwright/test';

async function connect(page: Page, user: string) {
  await page.route('**/reel-config.js', route => route.fulfill({ contentType: 'text/javascript', body: 'window.REEL_CONFIG={platform:"webos",previewMode:true};' }));
  await page.goto('/');
  for (const [field, value] of [['server', 'http://127.0.0.1:18771'], ['username', 'remote-navigation-' + user], ['password', 'demo']]) {
    await expect(page.locator(`[data-tv-field="${field}"]`)).toBeFocused();
    await page.keyboard.press('Enter'); await page.locator('#tv-entry-input').fill(value); await page.keyboard.press('Enter');
    await page.keyboard.press('ArrowDown');
  }
  await expect(page.getByRole('checkbox', { name: 'Remember this connection on this TV', exact: true })).toBeFocused();
  await page.keyboard.press('ArrowDown'); await page.keyboard.press('Enter');
  await expect(page.locator('.hero h1')).toBeVisible();
  await expect(page.locator('.hero [data-action="play"]')).toBeFocused();
}

async function start(page: Page) {
  await page.keyboard.press('Enter');
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeGreaterThan(.3);
}

test('TV remote leaves the timeline vertically while horizontal arrows still seek', async ({ page }) => {
  await page.setViewportSize({ width: 1920, height: 1080 });
  await connect(page, 'timeline'); await start(page);
  await page.keyboard.press('ArrowDown');
  const seek = page.getByRole('slider', { name: 'Playback position', exact: true });
  await expect(seek).toBeFocused();
  await page.keyboard.press('ArrowRight');
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeGreaterThan(1);
  await expect(seek).toBeFocused();
  await page.keyboard.press('ArrowDown');
  await expect(page.getByRole('button', { name: 'Play / pause', exact: true })).toBeFocused();
  await page.keyboard.press('Enter');
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).paused)).toBe(true);
  await page.keyboard.press('ArrowUp'); await expect(seek).toBeFocused();
  await page.keyboard.press('Escape'); await expect(page.locator('#player')).toBeHidden();
  await expect(page.locator('.hero [data-action="play"]')).toBeFocused();
});

test('TV tab bar keeps horizontal navigation inside the bar and restores the same content action', async ({ page }) => {
  await page.setViewportSize({ width: 1920, height: 1080 }); await connect(page, 'rail');
  const play = page.locator('.hero [data-action="play"]');
  await page.keyboard.press('ArrowUp');
  await expect(page.locator('#rail [aria-current="page"]')).toBeFocused();
  for (const key of ['ArrowRight', 'ArrowRight', 'ArrowLeft', 'ArrowUp']) {
    await page.keyboard.press(key);
    await expect.poll(() => page.evaluate(() => !!document.activeElement?.closest('#rail'))).toBe(true);
  }
  await page.keyboard.press('ArrowDown'); await expect(play).toBeFocused();
  await page.keyboard.press('ArrowRight'); await expect(page.locator('.hero [data-action="detail"]')).toBeFocused();
  await page.keyboard.press('Enter'); await expect(page.locator('.detail-intro h1')).toBeVisible();
  await page.keyboard.press('Escape'); await expect(page.locator('.hero h1')).toBeVisible();
});

test('TV checkbox Select toggles autoplay and directional keys leave the control', async ({ page }) => {
  await page.setViewportSize({ width: 1920, height: 1080 }); await connect(page, 'checkbox'); await start(page);
  // Begin at the native player surface, then use its real remote routes into Options.
  await page.keyboard.press('ArrowUp');
  for (let i = 0; i < 6 && !(await page.locator('#format-toggle').evaluate(node => node === document.activeElement)); i++) await page.keyboard.press('ArrowRight');
  await expect(page.locator('#format-toggle')).toBeFocused(); await page.keyboard.press('Enter');
  // Closed TV choices allow vertical focus movement without changing their value.
  for (let i = 0; i < 14 && !(await page.locator('#player-autoplay').evaluate(node => node === document.activeElement)); i++) await page.keyboard.press('ArrowDown');
  const autoplay = page.locator('#player-autoplay'); await expect(autoplay).toBeFocused();
  const initial = await autoplay.isChecked(); await page.keyboard.press('Enter');
  await expect(autoplay).toBeChecked({ checked: !initial });
  await page.keyboard.press('ArrowUp'); await expect(autoplay).not.toBeFocused();
  await expect(page.locator('#player-format')).toBeVisible();
  await page.keyboard.press('ArrowUp'); await expect(page.locator('#speed')).toBeFocused();
  await page.keyboard.press('Enter');
  const choices = page.locator('.tv-choice-layer');
  await expect(choices.getByRole('option', { name: 'Normal', exact: true })).toBeFocused();
  await page.keyboard.press('Tab'); await expect(choices.getByRole('option', { name: '1.25×', exact: true })).toBeFocused();
  await page.keyboard.press('Shift+Tab'); await expect(choices.getByRole('option', { name: 'Normal', exact: true })).toBeFocused();
  for (let i = 0; i < 4; i++) await page.keyboard.press('ArrowDown');
  await expect(choices.getByRole('option', { name: '2×', exact: true })).toBeFocused();
  await expect(choices.getByRole('option', { name: '2×', exact: true })).toBeInViewport({ ratio: 1 });
  await page.keyboard.press('Escape'); await expect(choices).toHaveCount(0); await expect(page.locator('#speed')).toBeFocused();
  await expect(page.locator('#speed')).toHaveValue('1');
  await page.keyboard.press('Enter'); await page.keyboard.press('ArrowDown'); await page.keyboard.press('Enter');
  await expect(choices).toHaveCount(0); await expect(page.locator('#speed')).toHaveValue('1.25');
  expect(await page.locator('#video').evaluate(el => (el as HTMLVideoElement).playbackRate)).toBe(1.25);
  await page.keyboard.press('ArrowLeft'); await expect(page.locator('#speed')).toHaveValue('1');
  await page.keyboard.press('Escape'); await expect(page.locator('#format-toggle')).toBeFocused();
});


test('TV shelf edges stay within a row, rows remember their place and Up or Back reaches the current tab', async ({ page }) => {
  await page.setViewportSize({ width: 1920, height: 1080 }); await connect(page, 'shelf');
  await page.keyboard.press('ArrowRight'); await page.keyboard.press('ArrowDown');
  const continueFirst = page.locator('.shelf').filter({ has: page.getByRole('heading', { name: 'Continue watching', exact: true }) }).locator('.media-card').first();
  await expect(continueFirst).toBeFocused(); await page.keyboard.press('ArrowDown');
  const next = page.locator('.shelf').filter({ has: page.getByRole('heading', { name: 'Up next', exact: true }) }).locator('.media-card').first();
  await expect(next).toBeFocused(); await page.keyboard.press('ArrowRight'); await expect(next).toBeFocused();
  await page.keyboard.press('ArrowLeft'); await expect(next).toBeFocused();
  const tab = page.locator('#rail [aria-current="page"]');
  await page.keyboard.press('ArrowUp'); await expect(continueFirst).toBeFocused();
  await page.keyboard.press('ArrowUp'); await expect.poll(() => page.evaluate(() => !!document.activeElement?.closest('.hero'))).toBe(true);
  await page.keyboard.press('ArrowUp'); await expect(tab).toBeFocused();
  await page.keyboard.press('ArrowDown'); await expect.poll(() => page.evaluate(() => !!document.activeElement?.closest('.hero'))).toBe(true);
  await page.keyboard.press('ArrowDown'); await expect(continueFirst).toBeFocused();
  await page.keyboard.press('ArrowDown'); await expect(next).toBeFocused();
  // Back from Home content moves to the current tab before the platform is asked to exit.
  await page.keyboard.press('Escape'); await expect(tab).toBeFocused();
});

test('TV Library filters open as a sheet over the titles, Back closes it, and closed choices are never targets', async ({ page }) => {
  await page.setViewportSize({ width: 1920, height: 1080 }); await connect(page, 'library-filters');
  await page.keyboard.press('ArrowUp'); await expect(page.locator('#rail [aria-current="page"]')).toBeFocused();
  for (let step = 0; step < 6 && await page.evaluate(() => document.activeElement?.getAttribute('data-route')) !== 'Library'; step++) await page.keyboard.press('ArrowRight');
  await page.keyboard.press('Enter'); await expect(page.locator('.browse-card').first()).toBeVisible();
  // The loaded count and multi-select are for a pointer; the remote never meets them.
  await expect(page.getByRole('button', { name: 'Select titles', exact: true })).toBeHidden();
  await page.keyboard.press('ArrowDown'); await expect(page.locator(':focus')).toHaveClass(/browse-category/);
  const filters = page.locator('#browse-filter-toggle');
  for (let step = 0; step < 8 && !await filters.evaluate(node => node === document.activeElement); step++) await page.keyboard.press('ArrowRight');
  await expect(filters).toBeFocused();
  // Closed, the filter choices are not targets: Down goes straight to the titles.
  await page.keyboard.press('ArrowDown'); await expect(page.locator(':focus')).toHaveClass(/browse-card/);
  await filters.focus(); await page.keyboard.press('Enter');
  await expect(page.locator('#browse-filter-panel')).toHaveJSProperty('open', true);
  await expect(page.locator('.browse-results')).toHaveJSProperty('inert', true);
  await page.keyboard.press('ArrowDown'); await expect(page.locator('#browse-library')).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(page.locator('#browse-filter-panel')).toHaveJSProperty('open', false);
  await expect(filters).toBeFocused();
  await expect(page.locator('.browse-results')).toHaveJSProperty('inert', false);
});

test('TV choices stay inside fullscreen and remove stale disabled or replaced controls safely', async ({ page }, info) => {
  await page.setViewportSize({ width: 1280, height: 720 }); await connect(page, 'choice-lifecycle'); await start(page);
  // TVs already occupy the screen; explicitly exercise a browser fullscreen host for the overlay contract.
  await page.locator('#player').evaluate(node => node.requestFullscreen());
  await expect.poll(() => page.evaluate(() => document.fullscreenElement?.id)).toBe('player');
  await page.locator('#format-toggle').click(); await page.locator('#speed').click();
  const choices = page.locator('.tv-choice-layer'); await expect(choices).toBeVisible();
  expect(await choices.evaluate(node => document.fullscreenElement!.contains(node))).toBe(true);
  await page.screenshot({ path: info.outputPath('tv-choices-fullscreen.png') });
  await page.keyboard.press('Escape'); await expect(choices).toHaveCount(0); await expect(page.locator('#player-format')).toBeVisible();
  await expect(page.locator('#speed')).toBeFocused();
  for (const attribute of ['disabled', 'hidden', 'inert']) {
    await page.locator('#speed').click(); await page.locator('#speed').evaluate((node, name) => { node.setAttribute(name, ''); }, attribute);
    await expect(choices).toHaveCount(0);
    expect(await page.locator('.player-content').evaluate(node => node.hasAttribute('inert'))).toBe(false);
    await page.locator('#speed').evaluate((node, name) => { node.removeAttribute(name); }, attribute);
  }
  await page.locator('#speed').click(); await expect(choices).toBeVisible();
  const staleChoice = await choices.getByRole('option', { name: '2×', exact: true }).elementHandle();
  await page.locator('#speed').evaluate(node => { node.replaceWith(node.cloneNode(true)); });
  await expect(choices).toHaveCount(0);
  await staleChoice!.evaluate(node => (node as HTMLButtonElement).click());
  await expect(page.locator('#speed')).toHaveValue('1');
  expect(await page.locator('#video').evaluate(el => (el as HTMLVideoElement).playbackRate)).toBe(1);
  expect(await page.locator('.player-content').evaluate(node => node.hasAttribute('inert'))).toBe(false);
  await page.getByRole('button', { name: 'Close playback options', exact: true }).click();
  await page.getByRole('button', { name: 'Close player', exact: true }).click(); await expect(page.locator('#player')).toBeHidden();
  expect(await page.evaluate(() => document.fullscreenElement)).toBeNull();
});
