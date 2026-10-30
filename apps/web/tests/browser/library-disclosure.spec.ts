import { test, expect, type Page } from '@playwright/test';

const fixture = 'http://127.0.0.1:18771';
async function connect(page: Page, server = fixture): Promise<void> {
  if (server !== fixture) await page.route(`${server}/**`, async route => {
    const url = new URL(route.request().url());
    await route.fulfill({ response: await route.fetch({ url: fixture + url.pathname + url.search }) });
  });
  await page.route(url => url.origin === server && url.pathname === '/UserViews', route => route.fulfill({ json: { Items: [{ Id: 'visual-library', Name: 'Films', Type: 'CollectionFolder' }], TotalRecordCount: 1 } }));
  await page.route(url => url.origin === server && url.pathname === '/Genres', route => route.fulfill({ json: { Items: [{ Id: 'visual-genre', Name: 'Drama', Type: 'Genre' }], TotalRecordCount: 1 } }));
  await page.goto('/');
  await page.getByLabel('Server address', { exact: true }).fill(server);
  await page.getByLabel('Username', { exact: true }).fill('library-disclosure');
  await page.getByLabel('Password', { exact: true }).fill('demo');
  await page.getByLabel('Remember this connection on this device', { exact: true }).check();
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.locator('.hero h1')).toBeVisible();
  await page.locator('#rail').getByRole('button', { name: 'Library', exact: true }).click();
  await expect(page.locator('.browse-card').first()).toBeVisible();
}
async function choose(page: Page, selector: string, value: string, parameter: string, queryValue: string): Promise<void> {
  const request = page.waitForRequest(request => {
    const url = new URL(request.url());
    return url.origin === fixture && url.pathname === '/Items' && url.searchParams.get(parameter) === queryValue;
  });
  await page.locator(selector).focus();
  await page.locator(selector).selectOption(value);
  await request;
  await expect(page.locator('.browse-loading')).toHaveCount(0);
  await expect(page.locator(selector)).toHaveValue(value);
  await expect(page.locator(selector)).toBeFocused();
  await expect(page.locator('#browse-filter-panel')).toHaveJSProperty('open', true);
}

for (const width of [390, 1440]) {
  test(`library filters keep artwork visible and preserve every filter through rerenders at ${width}`, async ({ page }, info) => {
    await page.setViewportSize({ width, height: 900 });
    await connect(page);
    const panel = page.locator('#browse-filter-panel'), toggle = page.locator('#browse-filter-toggle');
    await expect(panel).toHaveJSProperty('open', false);
    await expect(page.locator('#sort')).not.toBeVisible();
    for (const viewport of width === 390 ? [320, 390] : [width]) {
      await page.setViewportSize({ width: viewport, height: 900 });
      const first = await page.locator('.browse-card').first().boundingBox();
      expect(first!.y).toBeLessThan(viewport < 768 ? 350 : 650);
      for (const control of ['.browse-heading-actions > button:visible', '#browse-menu-toggle', '.browse-view button', '#browse-filter-toggle']) {
        for (const button of await page.locator(control).all()) {
          const box = await button.boundingBox();
          expect(box!.width).toBeGreaterThanOrEqual(44);
          expect(box!.height).toBeGreaterThanOrEqual(44);
        }
      }
      // A view opened from the navigation has a Back button only on desktop; phones and tablets use the tab bar.
      await expect(page.locator('.browse-heading-actions').getByRole('button', { name: 'Back', exact: true })).toBeVisible({ visible: viewport >= 1200 });
      // More pages remain, so the count shows, inside the filter summary in the bar.
      await expect(page.locator('.browse-bar .browse-filter-summary #browse-count')).toHaveText('60 of 75 titles');
      await expect(page.locator('#browse-count')).toBeVisible();
      // Select titles and Refresh wait in the More options menu.
      await expect(page.getByRole('button', { name: 'Select titles', exact: true })).toBeHidden();
      await page.locator('#browse-menu-toggle').click();
      for (const name of ['Select titles', 'Refresh library']) {
        const box = await page.getByRole('button', { name, exact: true }).boundingBox();
        expect(box!.height).toBeGreaterThanOrEqual(44);
        expect(box!.x).toBeGreaterThanOrEqual(0);
        expect(box!.x + box!.width).toBeLessThanOrEqual(viewport);
      }
      await page.keyboard.press('Escape');
      await expect(page.locator('#browse-menu')).toHaveJSProperty('open', false);
      await expect(page.locator('#browse-menu-toggle')).toBeFocused();
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(viewport);
      await expect.poll(() => page.locator('.browse-card img[data-art]').first().evaluate(node => { const image = node as HTMLImageElement; return image.complete && image.naturalWidth > 0 && getComputedStyle(image).opacity === '1'; })).toBe(true);
      await page.screenshot({ path: info.outputPath(`library-collapsed-${viewport}.png`) });
    }
    await toggle.focus(); await page.keyboard.press('Enter');
    await expect(panel).toHaveJSProperty('open', true);
    await choose(page, '#sort', 'DateCreated', 'sortBy', 'DateCreated,SortName');
    await choose(page, '#browse-direction', 'Ascending', 'sortOrder', 'Ascending,Ascending');
    await choose(page, '#browse-library', 'visual-library', 'parentId', 'visual-library');
    await choose(page, '#browse-genre', 'visual-genre', 'genreIds', 'visual-genre');
    await choose(page, '#browse-watch', 'Unwatched', 'isPlayed', 'false');
    const favorites = page.waitForRequest(request => new URL(request.url()).pathname === '/Items' && new URL(request.url()).searchParams.get('filters') === 'IsFavorite');
    await page.locator('#browse-favorites').click(); await favorites;
    await expect(page.locator('#browse-favorites')).toHaveAttribute('aria-checked', 'true');
    await expect(panel).toHaveJSProperty('open', true);
    await expect(toggle).toContainText('4');
    await expect(page.locator('.browse-filter-summary')).toContainText('Drama');
    await page.getByRole('button', { name: 'List', exact: true }).click();
    await expect(page.getByRole('button', { name: 'List', exact: true })).toHaveAttribute('aria-pressed', 'true');
    await expect(panel).toHaveJSProperty('open', true);
    await page.locator('.browse-filter-summary').getByRole('button', { name: 'Clear filters', exact: true }).click();
    await expect(page.locator('.browse-card').first()).toBeVisible();
    await page.getByRole('button', { name: 'List', exact: true }).click();
    await expect(page.locator('.browse-list')).toBeVisible();
    await expect(toggle).toHaveText('Filters');
    await expect(page.locator('#browse-library')).toHaveValue('');
    await expect(page.locator('#browse-genre')).toHaveValue('');
    await expect(page.locator('#browse-watch')).toHaveValue('Any');
    await expect(page.locator('#browse-favorites')).toHaveAttribute('aria-checked', 'false');
    await toggle.focus(); await page.keyboard.press('Space');
    await expect(panel).toHaveJSProperty('open', false);
    await expect(toggle).toBeFocused();
    const selectionWidth = width === 390 ? 320 : width;
    await page.setViewportSize({ width: selectionWidth, height: 900 });
    await page.getByRole('button', { name: 'Grid', exact: true }).click();
    await expect(page.getByRole('button', { name: 'Grid', exact: true })).toHaveAttribute('aria-pressed', 'true');
    await expect(page.locator('.browse-grid')).toBeVisible();
    await page.locator('#browse-menu-toggle').click();
    await page.getByRole('button', { name: 'Select titles', exact: true }).click();
    await expect(page.locator('.browse-selection-bar')).toContainText('0 selected');
    await expect(page.locator('#browse-menu-toggle')).toBeFocused();
    // Watched on a selection is one menu; it waits for a selection.
    await expect(page.locator('.browse-selection-bar').getByRole('button', { name: 'Watched', exact: true })).toBeDisabled();
    await page.locator('.browse-select').first().click();
    await expect(page.locator('.browse-selection-bar')).toContainText('1 selected');
    await expect(page.locator('.browse-select').first()).toHaveAttribute('aria-checked', 'true');
    await page.getByRole('button', { name: 'Select loaded titles', exact: true }).click();
    await expect(page.locator('.browse-selection-bar')).toContainText('60 selected');
    for (const action of ['Mark as watched', 'Mark as unwatched']) {
      await page.locator('#browse-watched-toggle').click();
      await page.getByRole('button', { name: action, exact: true }).click();
      await expect(page.getByRole('dialog')).toBeVisible();
      await expect(page.getByRole('dialog')).toContainText('60 selected titles');
      await page.getByRole('button', { name: 'Cancel', exact: true }).click();
      await expect(page.getByRole('dialog')).toHaveCount(0);
      await expect(page.locator('.browse-selection-bar')).toContainText('60 selected');
    }
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(selectionWidth);
    await page.screenshot({ path: info.outputPath(`library-selection-${selectionWidth}.png`) });
    await page.getByRole('button', { name: 'Done selecting', exact: true }).click();
    await expect(page.locator('.browse-select')).toHaveCount(0);
    await expect(page.locator('.browse-selection-bar')).toHaveCount(0);
    await page.setViewportSize({ width, height: 900 });
    await page.getByRole('button', { name: 'List', exact: true }).click();
    await page.reload();
    await expect(page.locator('.hero')).toBeVisible();
    await page.locator('#rail').getByRole('button', { name: 'Library', exact: true }).click();
    await expect(page.locator('.browse-list')).toBeVisible();
    await expect(panel).toHaveJSProperty('open', false);
    await toggle.click();
    await expect(page.locator('#sort')).toHaveValue('DateCreated');
    if (width >= 1200) await page.getByRole('button', { name: 'Back', exact: true }).click();
    else {
      await expect(page.getByRole('button', { name: 'Back', exact: true })).toBeHidden();
      await page.locator('#rail').getByRole('button', { name: 'Home', exact: true }).click();
    }
    await expect(page.locator('.hero')).toBeVisible();
    await page.locator('#rail').getByRole('button', { name: 'Library', exact: true }).click();
    await expect(panel).toHaveJSProperty('open', false);
    await page.locator('#rail').getByRole('button', { name: 'Home', exact: true }).click();
    await expect(page.locator('.hero')).toBeVisible();
    await page.locator('#rail').getByRole('button', { name: 'Library', exact: true }).click();
    await expect(panel).toHaveJSProperty('open', false);
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(width);
  });
}

test('collapsed filters leave option errors and recovery reachable', async ({ page, browser }, info) => {
  await page.setViewportSize({ width: 320, height: 900 });
  await connect(page);
  let fail = true;
  await page.route(url => url.origin === fixture && url.pathname === '/Genres', route => fail ? route.fulfill({ status: 503, body: 'Temporarily unavailable' }) : route.fulfill({ json: { Items: [{ Id: 'visual-genre', Name: 'Drama', Type: 'Genre' }] } }));
  await page.locator('#browse-category-Movies').click();
  await expect(page.locator('.browse-options-error')).toBeVisible();
  await expect(page.locator('#browse-filter-panel')).toHaveJSProperty('open', false);
  fail = false;
  await page.getByRole('button', { name: 'Retry filter choices', exact: true }).click();
  await expect(page.locator('.browse-options-error')).toHaveCount(0);
  await page.locator('#browse-filter-toggle').click();
  await expect(page.locator('#browse-genre option[value="visual-genre"]')).toHaveText('Drama');
  await expect(page.locator('#browse-filter-panel')).toHaveJSProperty('open', true);
  await page.locator('#browse-filter-toggle').click();
  let releaseRefresh: (() => void) | undefined;
  const refreshGate = new Promise<void>(resolve => { releaseRefresh = resolve; });
  let failRefresh = true;
  await page.route(url => url.origin === fixture && url.pathname === '/Items', async route => {
    if (failRefresh) { await refreshGate; await route.fulfill({ status: 503, body: 'Temporarily unavailable' }); }
    else await route.continue();
  });
  // Refresh lives in the More options menu; choosing it closes the menu, and reopening shows it busy.
  await page.locator('#browse-menu-toggle').click();
  await page.getByRole('button', { name: 'Refresh library', exact: true }).click();
  await expect(page.locator('#browse-menu')).toHaveJSProperty('open', false);
  await page.locator('#browse-menu-toggle').click();
  await expect(page.getByRole('button', { name: 'Refresh library', exact: true })).toHaveAttribute('aria-busy', 'true');
  await expect(page.getByRole('button', { name: 'Refresh library', exact: true })).toBeDisabled();
  await expect(page.locator('.browse-refreshing')).toBeVisible();
  await expect(page.locator('.browse-card')).toHaveCount(60);
  releaseRefresh!();
  await expect(page.getByRole('alert', { name: 'Library error' })).toBeVisible();
  await expect(page.locator('.browse-card')).toHaveCount(60);
  await page.screenshot({ path: info.outputPath('library-refresh-error-320.png') });
  failRefresh = false;
  await page.getByRole('button', { name: 'Retry refresh', exact: true }).click();
  await expect(page.getByRole('alert', { name: 'Library error' })).toHaveCount(0);
  await page.locator('#browse-menu-toggle').click();
  await expect(page.getByRole('button', { name: 'Refresh library', exact: true })).toBeEnabled();
  await page.keyboard.press('Escape');
  await page.getByRole('searchbox').fill('synthetic-no-title');
  await page.getByRole('searchbox').press('Enter');
  await expect(page.getByRole('heading', { name: 'No matching titles.', exact: true })).toBeVisible();
  await expect(page.locator('[data-action="browse-selection"]')).toHaveCount(0);
  await page.getByRole('button', { name: 'Clear search', exact: true }).click();
  await expect(page.locator('.browse-card')).toHaveCount(60);
  let releaseFirstPage: (() => void) | undefined;
  const firstPageGate = new Promise<void>(resolve => { releaseFirstPage = resolve; });
  await page.route(url => url.origin === fixture && url.pathname === '/Items' && url.searchParams.get('includeItemTypes') === 'Series', async route => {
    await firstPageGate;
    await route.continue();
  });
  await page.locator('#browse-category-Series').click();
  await expect(page.locator('.browse-loading')).toBeVisible();
  await expect(page.locator('#browse-count')).toHaveText('Opening the collection');
  await expect(page.locator('[data-action="browse-selection"]')).toHaveCount(0);
  releaseFirstPage!();
  await expect(page.locator('.browse-card').first()).toBeVisible();
  await page.locator('#browse-menu-toggle').click();
  await expect(page.getByRole('button', { name: 'Select titles', exact: true })).toBeEnabled();
  await page.keyboard.press('Escape');
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(320);
  const protectedContext = await browser.newContext({ baseURL: 'http://127.0.0.1:18770', viewport: { width: 320, height: 900 } });
  try {
    const protectedPage = await protectedContext.newPage();
    await protectedPage.route('**/reel-config.js', route => route.fulfill({ contentType: 'text/javascript', body: 'window.REEL_CONFIG={platform:"web",previewMode:true};' }));
    await connect(protectedPage, 'https://media.preview.test');
    await protectedPage.locator('#browse-menu-toggle').click();
    await expect(protectedPage.getByRole('button', { name: 'Select titles', exact: true })).toBeDisabled();
    await expect(protectedPage.locator('.browse-protected')).toBeVisible();
    expect(await protectedPage.evaluate(() => document.documentElement.scrollWidth)).toBe(320);
  } finally { await protectedContext.close(); }
});

test('TV arrow navigation reaches the native filter disclosure and Enter opens it', async ({ page }) => {
  await page.setViewportSize({ width: 1920, height: 1080 });
  await connect(page);
  await page.evaluate(() => { document.documentElement.dataset.layout = 'tv'; });
  // Pointer controls give way to the remote: view style, the loaded count, multi-select, Back and Refresh.
  for (const button of await page.locator('.browse-heading-actions button,.browse-view button,[data-action="browse-selection"]').all()) await expect(button).toBeHidden();
  expect((await page.locator('#browse-filter-toggle').boundingBox())!.height).toBeGreaterThanOrEqual(58);
  // Categories, Filters and the collection search share one row: Right walks from the first category to Filters.
  await page.locator('#browse-category-All').focus();
  for (let step = 0; step < 8 && !await page.locator('#browse-filter-toggle').evaluate(node => node === document.activeElement); step++) await page.keyboard.press('ArrowRight');
  await expect(page.locator('#browse-filter-toggle')).toBeFocused();
  await page.keyboard.press('Enter');
  await expect(page.locator('#browse-filter-panel')).toHaveJSProperty('open', true);
  await page.keyboard.press('ArrowDown');
  await expect(page.locator('#browse-library')).toBeFocused();
});
