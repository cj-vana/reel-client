import { test, expect, type Page } from '@playwright/test';

// One couch session with a five-way remote: arrows, OK (Enter) and Back. Back is sent as Escape,
// which the app treats the same as the webOS Back key (keyCode 461) and Tizen's Return.
async function connect(page: Page, user: string) {
  await page.route('**/reel-config.js', route => route.fulfill({ contentType: 'text/javascript', body: 'window.REEL_CONFIG={platform:"webos",previewMode:true};' }));
  await page.goto('/');
  for (const [field, value] of [['server', 'http://127.0.0.1:18771'], ['username', 'tv-journey-' + user], ['password', 'demo']]) {
    await expect(page.locator(`[data-tv-field="${field}"]`)).toBeFocused();
    await page.keyboard.press('Enter'); await page.locator('#tv-entry-input').fill(value); await page.keyboard.press('Enter');
    await page.keyboard.press('ArrowDown');
  }
  await page.keyboard.press('ArrowDown'); await page.keyboard.press('Enter');
  await expect(page.locator('.hero h1')).toBeVisible();
}

// Exactly one focused element: shown, fully inside the viewport, and drawn as focused (ring,
// shadow or scale). The picture itself has no ring; while it holds focus the transport must show.
function focusProblem(): string {
  const node = document.activeElement as HTMLElement | null;
  if (!node || node === document.body || node === document.documentElement) return 'nothing is focused';
  const name = `${node.tagName.toLowerCase()} "${(node.getAttribute('aria-label') ?? node.textContent ?? '').trim().slice(0, 40)}"`;
  const box = node.getBoundingClientRect(), style = getComputedStyle(node);
  if (box.width < 1 || box.height < 1 || style.visibility === 'hidden' || node.closest('[hidden],[inert]')) return name + ' is not shown';
  for (let parent: HTMLElement | null = node; parent; parent = parent.parentElement) if (Number(getComputedStyle(parent).opacity) < .9) return name + ' is faded out';
  if (box.left < -1 || box.top < -1 || box.right > innerWidth + 1 || box.bottom > innerHeight + 1) return `${name} is outside the viewport at ${[box.left, box.top, box.right, box.bottom].map(Math.round).join(',')}`;
  if (node.tagName === 'VIDEO') return document.querySelector('#player')?.getAttribute('data-controls') === 'visible' ? '' : 'the picture is focused with the transport hidden';
  // Cards draw their ring on the artwork, so a card counts as drawn when its artwork has the ring.
  const ringed = (element: Element) => { const own = getComputedStyle(element); return own.outlineStyle !== 'none' && parseFloat(own.outlineWidth) > 0 || own.boxShadow !== 'none'; };
  const art = node.querySelector('.card-art, .artwork, .episode-art');
  const drawn = ringed(node) || style.transform !== 'none' || !!art && ringed(art);
  return drawn ? '' : name + ' has no focus style';
}
async function press(page: Page, key: string, step: string) {
  await page.keyboard.press(key);
  await expect.poll(() => page.evaluate(focusProblem), { message: `${step} (${key})` }).toBe('');
}
async function pressUntil(page: Page, key: string, step: string, arrived: () => boolean, limit = 8) {
  for (let count = 0; count < limit && !await page.evaluate(arrived); count++) await press(page, key, step);
  expect(await page.evaluate(arrived), step).toBe(true);
}

for (const viewport of [{ width: 1920, height: 1080 }, { width: 1280, height: 720 }]) {
  test(`TV remote drives Home, a series, an episode, the info panel and back at ${viewport.width}x${viewport.height}`, async ({ page }) => {
    await page.setViewportSize(viewport);
    await connect(page, String(viewport.width));
    await expect.poll(() => page.evaluate(focusProblem), { message: 'Home opens with focus' }).toBe('');

    // Home: down through the rows to the series row, then across it to the series.
    await pressUntil(page, 'ArrowDown', 'Home rows', () => document.activeElement?.closest('.shelf')?.querySelector('h2')?.textContent === 'Recently added series');
    await pressUntil(page, 'ArrowRight', 'Series row', () => !!document.activeElement?.textContent?.includes('Out of the Blue'));
    await press(page, 'Enter', 'Open the series');
    await expect(page.locator('.detail-intro h1')).toHaveText('Out of the Blue');
    await expect(page.locator('.detail-intro [data-action="play"]')).toBeFocused();

    // Details: down past the actions and the season tabs to the first episode, then its Play button.
    await pressUntil(page, 'ArrowDown', 'Details to episodes', () => !!document.activeElement?.matches('.episode-main'));
    await press(page, 'ArrowDown', 'Episode Play');
    await expect(page.locator(':focus')).toHaveClass(/episode-play/);
    await press(page, 'Enter', 'Start the episode');
    await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeGreaterThan(.3);
    await expect(page.locator('#video')).toBeFocused();
    await press(page, 'Enter', 'OK pauses the picture');
    await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).paused)).toBe(true);

    // Player: Down reaches the timeline, then the transport, then opens the info panel.
    await press(page, 'ArrowDown', 'Timeline');
    await expect(page.getByRole('slider', { name: 'Playback position', exact: true })).toBeFocused();
    await press(page, 'ArrowDown', 'Transport');
    await expect(page.getByRole('button', { name: 'Play / pause', exact: true })).toBeFocused();
    await press(page, 'ArrowDown', 'Open the info panel');
    await expect(page.locator('#player-format')).toBeVisible();
    await expect(page.getByRole('tab', { name: 'Episodes', exact: true })).toBeFocused();
    await press(page, 'ArrowRight', 'Audio tab');
    await expect(page.getByRole('tab', { name: 'Audio', exact: true })).toHaveAttribute('aria-selected', 'true');
    await press(page, 'ArrowDown', 'Audio choice');
    await expect(page.locator('#player-audio')).toBeFocused();

    // Back closes the panel, then the player, then Details, then returns to the current tab.
    await press(page, 'Escape', 'Close the info panel');
    await expect(page.locator('#player-format')).toBeHidden();
    await expect(page.getByRole('button', { name: 'Play / pause', exact: true })).toBeFocused();
    await press(page, 'Escape', 'Leave the player');
    await expect(page.locator('#player')).toBeHidden();
    await expect(page.locator('.detail-intro h1')).toHaveText('Out of the Blue');
    await press(page, 'Escape', 'Back to Home');
    await expect(page.locator('.hero h1')).toBeVisible();
    await expect.poll(() => page.evaluate(() => document.activeElement?.closest('.shelf')?.querySelector('h2')?.textContent)).toBe('Recently added series');
    await press(page, 'Escape', 'Back to the tab bar');
    await expect(page.locator('#rail [aria-current="page"]')).toBeFocused();
  });
}
