import { test, expect, type Page } from '@playwright/test';

const fixture = 'http://127.0.0.1:18771';
const field = (page: Page, name: string) => page.locator(`[data-tv-field="${name}"]`);
async function enter(page: Page, name: string, value: string): Promise<void> {
  await field(page, name).click();
  await expect(page.locator('#tv-entry-input')).toBeFocused();
  await page.locator('#tv-entry-input').fill(value);
  await page.keyboard.press('Enter');
  await expect(page.locator('#tv-entry-editor')).toHaveCount(0);
  await expect(field(page, name)).toBeFocused();
}
async function credentials(page: Page, username: string, password = 'demo'): Promise<void> {
  await enter(page, 'server', fixture);
  await enter(page, 'username', username);
  await enter(page, 'password', password);
}
const submit = (page: Page) => page.getByRole('button', { name: 'Sign in', exact: true });
const remember = (page: Page) => page.getByRole('checkbox', { name: 'Remember this connection on this TV', exact: true });

test.beforeEach(async ({ page, request }) => {
  await request.post(fixture + '/qa/reset');
  await page.setViewportSize({ width: 1920, height: 1080 });
  await page.route('**/reel-config.js', route => route.fulfill({ contentType: 'text/javascript', body: 'window.REEL_CONFIG={previewMode:true,platform:"webos"};' }));
  await page.goto('/');
  await expect(field(page, 'server')).toBeFocused();
});

test('TV remote reaches every connection control without opening the keyboard', async ({ page }) => {
  await expect(page.locator('#tv-entry-editor')).toHaveCount(0);
  await page.keyboard.press('ArrowDown'); await expect(field(page, 'username')).toBeFocused();
  await page.keyboard.press('ArrowDown'); await expect(field(page, 'password')).toBeFocused();
  await page.keyboard.press('ArrowDown'); await expect(remember(page)).toBeFocused();
  await page.keyboard.press('Enter'); await expect(remember(page)).toHaveAttribute('aria-checked', 'true');
  await page.keyboard.press('Enter'); await expect(remember(page)).toHaveAttribute('aria-checked', 'false');
  await page.keyboard.press('ArrowDown'); await expect(submit(page)).toBeFocused();
  await page.keyboard.press('ArrowUp'); await expect(remember(page)).toBeFocused();
  for (const viewport of [{ width: 1920, height: 1080 }, { width: 1280, height: 720 }]) {
    await page.setViewportSize(viewport);
    await expect(submit(page)).toBeInViewport({ ratio: 1 });
    await expect(field(page, 'server')).toBeInViewport({ ratio: 1 });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: `test-results/tv-connect-${viewport.width}.png` });
  }
});

test('TV field editor supports Done, Cancel, Back, masking and isolated Enter', async ({ page, request }) => {
  await page.keyboard.press('Enter');
  await expect(page.locator('#tv-entry-input')).toBeFocused();
  await page.locator('#tv-entry-input').fill(fixture);
  await page.keyboard.press('ArrowDown'); await expect(page.locator('#tv-entry-done')).toBeFocused();
  await page.keyboard.press('Enter'); await expect(field(page, 'server')).toContainText(fixture);
  await field(page, 'server').click();
  await page.locator('#tv-entry-input').fill('https://discarded.invalid');
  await page.keyboard.press('ArrowDown'); await page.keyboard.press('ArrowRight');
  await expect(page.locator('#tv-entry-cancel')).toBeFocused();
  await page.keyboard.press('Enter'); await expect(field(page, 'server')).toContainText(fixture);
  await field(page, 'username').click(); await page.locator('#tv-entry-input').fill('tv-editor');
  await page.keyboard.press('Escape'); await expect(field(page, 'username')).toBeFocused();
  await expect(field(page, 'username')).toContainText('tv-editor');
  await field(page, 'password').click(); await page.locator('#tv-entry-input').fill('private-demo');
  await expect(page.locator('#tv-entry-input')).toHaveAttribute('type', 'password');
  await page.keyboard.press('ArrowDown'); await page.keyboard.press('ArrowRight'); await page.keyboard.press('ArrowRight');
  await expect(page.locator('#tv-entry-reveal')).toBeFocused();
  await page.keyboard.press('Enter'); await expect(page.locator('#tv-entry-input')).toHaveAttribute('type', 'text');
  await page.keyboard.press('Enter'); await expect(page.locator('#tv-entry-input')).toHaveAttribute('type', 'password');
  await page.locator('#tv-entry-input').focus(); await page.keyboard.press('Enter');
  await expect(field(page, 'password')).toContainText('Password entered');
  await expect(field(page, 'password')).not.toContainText('private-demo');
  await expect(page.locator('body')).not.toContainText('private-demo');
  await field(page, 'password').click(); await expect(page.locator('#tv-entry-input')).toHaveAttribute('type', 'password');
  await page.keyboard.press('Escape');
  const state = await (await request.get(fixture + '/qa/state')).json();
  expect(state.calls.some((call: { path: string }) => call.path.includes('AuthenticateByName'))).toBe(false);
});

test('TV keyboard visibility preserves voice input and editor fits keyboard-sized viewport', async ({ page }) => {
  await page.evaluate(() => {
    const state = window as Window & { PalmSystem?: { platformBack(): void }; __platformBacks?: number };
    state.__platformBacks = 0;
    state.PalmSystem = { platformBack: () => { state.__platformBacks!++; } };
  });
  await field(page, 'password').click();
  await page.locator('#tv-entry-input').fill('composing-demo');
  for (const event of [{ key: 'Enter' }, { key: 'Escape' }, { key: 'BrowserBack' }, { key: 'Unidentified', keyCode: 461 }]) {
    await page.locator('#tv-entry-input').dispatchEvent('keydown', { ...event, isComposing: true, bubbles: true });
    await expect(page.locator('#tv-entry-editor')).toHaveCount(1);
    await expect(page.locator('#tv-entry-input')).toHaveValue('composing-demo');
    expect(await page.evaluate(() => (window as Window & { __platformBacks?: number }).__platformBacks)).toBe(0);
  }
  await page.evaluate(() => document.dispatchEvent(new CustomEvent('keyboardStateChange', { detail: { visibility: true } })));
  await page.keyboard.press('Enter');
  await expect(page.locator('#tv-entry-editor')).toHaveCount(1);
  await expect(page.locator('#tv-entry-input')).toHaveValue('composing-demo');
  await page.keyboard.press('ArrowDown'); await expect(page.locator('#tv-entry-input')).toBeFocused();
  await page.evaluate(() => document.dispatchEvent(new CustomEvent('keyboardStateChange', { detail: { visibility: false } })));
  await expect(page.locator('#tv-entry-input')).toBeFocused();
  await page.evaluate(() => document.dispatchEvent(new CustomEvent('keyboardStateChange', { detail: { visibility: true } })));
  await expect(page.locator('#tv-entry-input')).toBeFocused();
  await page.setViewportSize({ width: 1280, height: 420 });
  await expect(page.locator('#tv-entry-input')).toBeInViewport({ ratio: 1 });
  await expect(page.locator('#tv-entry-cancel')).toBeInViewport({ ratio: 1 });
  await page.screenshot({ path: 'test-results/tv-keyboard-editor-420.png' });
  await page.evaluate(() => document.dispatchEvent(new CustomEvent('keyboardStateChange', { detail: { visibility: false } })));
  await page.keyboard.press('ArrowDown'); await expect(page.locator('#tv-entry-done')).toBeFocused();
  await page.keyboard.press('Escape'); await expect(field(page, 'password')).toBeFocused();
  expect(await page.evaluate(() => (window as Window & { __platformBacks?: number }).__platformBacks)).toBe(0);
  await page.keyboard.press('Escape');
  expect(await page.evaluate(() => (window as Window & { __platformBacks?: number }).__platformBacks)).toBe(1);
});

test('TV validates required fields, recovers from bad credentials and locks pending authentication', async ({ page }) => {
  await submit(page).click(); await expect(field(page, 'server')).toBeFocused();
  await expect(page.locator('#connection-error')).toContainText('complete Jellyfin address');
  await enter(page, 'server', 'broken'); await submit(page).click();
  await expect(field(page, 'server')).toBeFocused();
  await enter(page, 'server', fixture); await submit(page).click();
  await expect(field(page, 'username')).toBeFocused();
  await expect(page.locator('#connection-error')).toContainText('username');
  await enter(page, 'username', 'tv-retry'); await enter(page, 'password', 'wrong'); await submit(page).click();
  await expect(page.locator('#connection-error')).toContainText('sign-in');
  await expect(field(page, 'password')).toBeEnabled(); await enter(page, 'password', 'demo');
  let release!: () => void;
  const wait = new Promise<void>(resolve => { release = resolve; });
  await page.route('**/Users/AuthenticateByName', async route => { await wait; await route.continue(); });
  await submit(page).click();
  for (const name of ['server', 'username', 'password']) await expect(field(page, name)).toBeDisabled();
  await expect(remember(page)).toBeDisabled(); await expect(page.getByRole('button', { name: 'Connecting…', exact: true })).toBeDisabled();
  release(); await expect(page.locator('.hero h1')).toBeVisible();
  await expect(page.locator('body')).not.toHaveClass(/tv-connecting/);
  await expect(page.locator('#rail')).toBeVisible();
});

test('TV remembered connections survive reload, switch servers, and remove only the selected connection', async ({ page }) => {
  await credentials(page, 'first'); await remember(page).click(); await submit(page).click();
  await expect(page.locator('.connection-button strong')).toHaveText('Alex');
  await page.reload(); await expect(page.locator('.hero h1')).toBeVisible();
  await page.locator('.connection-button').click(); await expect(field(page, 'server')).toBeVisible();
  await credentials(page, 'second'); await remember(page).click(); await submit(page).click();
  await expect(page.locator('.connection-button strong')).toHaveText('Sam');
  await page.locator('.connection-button').click();
  const first = page.locator('.saved-connections article').filter({ hasText: 'Alex' });
  await first.getByRole('button', { name: 'Open', exact: true }).click();
  await expect(page.locator('.connection-button strong')).toHaveText('Alex');
  await page.reload(); await expect(page.locator('.connection-button strong')).toHaveText('Alex');
  await page.locator('.connection-button').click();
  await page.locator('.saved-connections article').filter({ hasText: 'Sam' }).getByRole('button', { name: 'Sign out', exact: true }).click();
  await expect(page.locator('.saved-connections article')).toHaveCount(1);
  await page.locator('.saved-connections article').getByRole('button', { name: 'Sign out', exact: true }).click();
  await expect(page.locator('.saved-connections')).toBeHidden();
  await page.reload(); await expect(field(page, 'server')).toBeFocused();
});

test('TV unsaved connection is cleared on reload and untrusted text stays text', async ({ page }) => {
  await enter(page, 'username', '<img src=x onerror="window.__bad=true">');
  await expect(field(page, 'username').locator('img')).toHaveCount(0);
  expect(await page.evaluate(() => (window as Window & { __bad?: boolean }).__bad)).toBeUndefined();
  await credentials(page, 'tv-unsaved'); await submit(page).click(); await expect(page.locator('.hero h1')).toBeVisible();
  await page.reload(); await expect(field(page, 'server')).toBeFocused();
  await expect(field(page, 'password')).toContainText('Enter password');
});


test('TV 720p remote keeps every tab bar control visible and returns along the bar', async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 720 });
  await credentials(page, 'tv-short-rail'); await submit(page).click();
  await expect(page.locator('.hero h1')).toBeVisible();
  const rail = page.locator('#rail');
  const names = (await rail.locator('.nav-item:visible').allTextContents()).map(name => name.trim());
  await rail.getByRole('button', { name: names[0], exact: true }).focus();
  for (const name of [...names.slice(1), 'Alex']) {
    await page.keyboard.press('ArrowRight');
    const control = name === 'Alex' ? rail.locator('.connection-button') : rail.getByRole('button', { name, exact: true });
    await expect(control).toBeFocused();
    await page.screenshot({ path: `test-results/tv-720-rail-${name.replaceAll(' ', '-')}.png` });
    await expect(control).toBeInViewport({ ratio: 1 });
    await expect.poll(() => control.evaluate(element => {
      const r = element.getBoundingClientRect(), style = getComputedStyle(element);
      const outset = parseFloat(style.outlineWidth) + Math.max(0, parseFloat(style.outlineOffset));
      return r.y - outset >= -0.5 && r.bottom + outset <= innerHeight + 0.5;
    })).toBe(true);
  }
  await page.keyboard.press('Enter');
  await expect(field(page, 'server')).toBeVisible(); await expect(rail).toBeHidden();
  await expect(page.locator(':focus')).toBeInViewport({ ratio: 1 });
  expect(await page.locator(':focus').evaluate(element => Boolean(element.closest('#content')))).toBe(true);
  await page.keyboard.press('Escape'); await expect(rail).toBeVisible();
  await rail.locator('.connection-button').focus();
  for (const name of [...names].reverse()) {
    await page.keyboard.press('ArrowLeft');
    const control = rail.getByRole('button', { name, exact: true });
    await expect(control).toBeFocused(); await expect(control).toBeInViewport({ ratio: 1 });
  }
  await page.setViewportSize({ width: 1920, height: 1080 });
  for (const control of await rail.locator('.nav-item:visible,.connection-button:visible').all()) await expect(control).toBeInViewport({ ratio: 1 });
  // A focused card can scroll the page and tuck the bar away; a pointer brings it back at the top of the
  // screen. The move repeats until a scroll still settling after the focus change has finished.
  const pointAtBar = (viewport: { width: number }) => expect.poll(async () => {
    await page.mouse.move(viewport.width / 2, 40); await page.mouse.move(viewport.width / 2, 2);
    return page.evaluate(() => document.body.classList.contains('tv-scrolled'));
  }).toBe(false);
  for (const viewport of [{ width: 1280, height: 720 }, { width: 1920, height: 1080 }]) {
    await page.setViewportSize(viewport);
    await pointAtBar(viewport);
    await rail.getByRole('button', { name: 'Library', exact: true }).click();
    const first = page.locator('.media-grid .media-card').first();
    await expect(first).toBeVisible(); await first.focus(); await page.keyboard.press('ArrowDown');
    const focused = page.locator('.media-card:focus');
    await expect(focused).toHaveCount(1);
    await page.screenshot({ path: `test-results/tv-library-focus-${viewport.width}.png` });
    await expect.poll(() => focused.evaluate(element => {
      const r = element.getBoundingClientRect(), style = getComputedStyle(element);
      const outset = parseFloat(style.outlineWidth) + Math.max(0, parseFloat(style.outlineOffset));
      return r.y - outset >= -0.5 && r.bottom + outset <= innerHeight + 0.5;
    })).toBe(true);
    await pointAtBar(viewport);
    await rail.getByRole('button', { name: 'Home', exact: true }).click();
    const firstShelf = page.locator('.shelf-track .media-card').first();
    await expect(firstShelf).toBeVisible(); await firstShelf.focus(); await page.keyboard.press('ArrowRight');
    const shelfFocus = page.locator('.shelf-track .media-card:focus');
    await expect(shelfFocus).toHaveCount(1);
    await expect.poll(() => shelfFocus.evaluate(element => {
      const r = element.getBoundingClientRect(), clip = element.closest('.shelf-track')!.getBoundingClientRect(), style = getComputedStyle(element);
      const outset = parseFloat(style.outlineWidth) + Math.max(0, parseFloat(style.outlineOffset));
      return r.y - outset >= Math.max(0, clip.y) - 0.5 && r.bottom + outset <= Math.min(innerHeight, clip.bottom) + 0.5 && r.x - outset >= clip.x - 0.5 && r.right + outset <= clip.right + 0.5;
    })).toBe(true);
    await page.screenshot({ path: `test-results/tv-home-focus-${viewport.width}.png` });
  }
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});

test('TV saved connection form keeps the full focus outline visible during natural remote traversal', async ({ page }) => {
  await credentials(page, 'tv-saved-form'); await remember(page).click(); await submit(page).click();
  await expect(page.locator('.hero h1')).toBeVisible();
  for (const viewport of [{ width: 1280, height: 720 }, { width: 1920, height: 1080 }]) {
    await page.setViewportSize(viewport);
    await page.reload(); await expect(page.locator('.hero h1')).toBeVisible();
    await page.locator('.connection-button').click();
    await expect(page.locator('.saved-connections article')).toHaveCount(1);
    // Servers opens on the address field, never on the current server's Sign out.
    await expect(field(page, 'server')).toBeFocused();
    expect(await page.evaluate(() => scrollY)).toBe(0);
    // Up reaches the saved server, and the remote comes back down to the address.
    await page.keyboard.press('ArrowUp');
    await expect(page.locator('.saved-connections article button')).toBeFocused();
    await page.keyboard.press('ArrowDown');
    for (let attempt = 0; attempt < 3 && !await field(page, 'server').evaluate(element => element === document.activeElement); attempt++) {
      await page.keyboard.press('ArrowUp');
    }
    await expect(field(page, 'server')).toBeFocused();
    const controls = [field(page, 'server'), field(page, 'username'), field(page, 'password'), remember(page), submit(page)];
    for (const [index, control] of controls.entries()) {
      if (index > 0) await page.keyboard.press('ArrowDown');
      await expect(control).toBeFocused();
      await expect.poll(() => control.evaluate(element => {
        // Fields ring on focus; the submit button fills and scales like every TV button.
        const r = element.getBoundingClientRect(), style = getComputedStyle(element), ringed = style.outlineStyle !== 'none';
        const outset = ringed ? parseFloat(style.outlineWidth) + Math.max(0, parseFloat(style.outlineOffset)) : 0;
        return (ringed || style.transform !== 'none') && r.y - outset >= -0.5 && r.bottom + outset <= innerHeight + 0.5
          && r.x - outset >= -0.5 && r.right + outset <= innerWidth + 0.5;
      })).toBe(true);
    }
    await page.screenshot({ path: `test-results/tv-saved-form-focus-${viewport.width}.png` });
    await page.keyboard.press('ArrowUp'); await expect(remember(page)).toBeFocused();
    await page.keyboard.press('Enter'); await expect(remember(page)).toHaveAttribute('aria-checked', 'true');
    await page.keyboard.press('Enter'); await expect(remember(page)).toHaveAttribute('aria-checked', 'false');
    await page.keyboard.press('Escape'); await expect(page.locator('.hero h1')).toBeVisible();
  }
});
