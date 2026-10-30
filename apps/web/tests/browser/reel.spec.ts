import { test, expect, type Page } from '@playwright/test';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { readFileSync } from 'node:fs';

const fixture = 'http://127.0.0.1:18771';
async function login(page: Page, username = 'demo', remember = false, url = '/', server = fixture): Promise<void> {
  await page.goto(url);
  if (await page.locator('[data-tv-field="server"]').count()) {
    for (const [field, value] of [['server', server], ['username', username], ['password', 'demo']]) {
      await page.locator(`[data-tv-field="${field}"]`).click();
      await page.locator('#tv-entry-input').fill(value);
      await page.keyboard.press('Enter');
    }
    if (remember) await page.getByRole('checkbox', { name: 'Remember this connection on this TV', exact: true }).click();
  } else {
    await page.getByLabel('Server address', { exact: true }).fill(server);
    await page.getByLabel('Username', { exact: true }).fill(username);
    await page.getByLabel('Password', { exact: true }).fill('demo');
    if (remember) await page.getByLabel('Remember this connection on this device').check();
  }
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.locator('.hero h1')).toBeVisible();
}
async function tab(page: Page, name: string): Promise<void> {
  const destination = page.locator('#rail').getByRole('button', { name, exact: true });
  if (!await destination.isVisible()) await page.getByRole('button', { name: 'More', exact: true }).click();
  await destination.click();
}
async function togglePlayback(page: Page): Promise<void> { await page.locator('#video').focus(); await page.keyboard.press('Space'); }
async function chapter(page: Page, value: string): Promise<void> { await page.getByRole('button', { name: 'Playback options', exact: true }).click(); await page.getByLabel('Chapter', { exact: true }).selectOption(value); await page.getByRole('button', { name: 'Close playback options', exact: true }).click(); }
async function skipNative(page: Page, direction: 'ArrowLeft' | 'ArrowRight', count = 1): Promise<void> { await page.locator('#video').focus(); for (let i = 0; i < count; i++) await page.keyboard.press(direction); }
async function playFirstEpisode(page: Page): Promise<void> {
  await page.getByRole('button', { name: 'Feature Out of the Blue', exact: true }).click();
  await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  await page.locator('.episode-row[data-id="episode-1-1"] .episode-play').click();
}
async function time(page: Page): Promise<number> { return page.locator('#video').evaluate(element => (element as HTMLVideoElement).currentTime); }

async function preparationFixture(page: Page, kind: 'foreign' | 'base' | 'error' | 'unusable' | 'late') {
  const allocations = new Set<string>(), cleanups: Array<{ path: string; session: string | null; live: string | null }> = [];
  let attempts = 0, foreignRequests = 0;
  await page.route('https://foreign.invalid/**', pending => { foreignRequests++; return pending.abort(); });
  page.on('request', request => {
    const url = new URL(request.url());
    if (/\/(Videos\/ActiveEncodings|LiveStreams\/Close)$/.test(url.pathname)) cleanups.push({ path: url.pathname, session: url.searchParams.get('playSessionId'), live: url.searchParams.get('liveStreamId') });
  });
  await page.route('**/LiveStreams/Close?*', async pending => {
    const response = await pending.fetch();
    if (response.ok()) allocations.delete(new URL(pending.request().url()).searchParams.get('liveStreamId') ?? '');
    await pending.fulfill({ response });
  });
  await page.route('**/Videos/ActiveEncodings?*', async pending => {
    if (kind === 'error' && new URL(pending.request().url()).searchParams.get('playSessionId') === 'cleanup-first') await pending.fulfill({ status: 503, json: {} });
    else await pending.continue();
  });
  await page.route('**/Items/movie-1/PlaybackInfo', async pending => {
    const response = await pending.fetch(), info = await response.json(), first = attempts++ === 0;
    const live = first ? 'cleanup-live-first' : 'cleanup-live-retry';
    allocations.add(live);
    info.PlaySessionId = first ? 'cleanup-first' : 'cleanup-retry'; info.MediaSources[0].LiveStreamId = live;
    if (first && kind === 'foreign') { info.MediaSources[0].SupportsDirectPlay = false; info.MediaSources[0].TranscodingUrl = 'https://foreign.invalid/stream.m3u8'; }
    if (first && kind === 'base') { info.MediaSources[0].SupportsDirectPlay = false; info.MediaSources[0].TranscodingUrl = fixture + '/outside/stream.m3u8'; }
    if (first && kind === 'error') info.ErrorCode = 'NoCompatibleStream';
    if (first && kind === 'unusable') { info.MediaSources[0].SupportsDirectPlay = false; delete info.MediaSources[0].TranscodingUrl; }
    await pending.fulfill({ response, json: info });
  });
  return { allocations, cleanups, foreignRequests: () => foreignRequests };
}

test.beforeEach(async ({ request }) => { await request.post(fixture + '/qa/reset'); });

test('bad credentials recover, opt-in session survives reload and sign-out removes it', async ({ page }) => {
  await page.goto('/');
  await page.getByLabel('Server address', { exact: true }).fill(fixture);
  await page.getByLabel('Username', { exact: true }).fill('persist');
  await page.getByLabel('Password', { exact: true }).fill('wrong');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.locator('#connection-error')).toContainText('sign-in');
  await page.getByLabel('Password', { exact: true }).fill('demo');
  await page.getByLabel('Remember this connection on this device').check();
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.locator('.hero h1')).toBeVisible();
  await page.reload(); await expect(page.locator('.hero h1')).toBeVisible();
  await tab(page, 'Servers');
  await page.getByRole('button', { name: 'Sign out', exact: true }).click();
  await expect(page.getByLabel('Username', { exact: true })).toBeVisible();
  await page.reload(); await expect(page.getByLabel('Username', { exact: true })).toBeVisible();
});

test('browse, pagination, favorite, debounced search, seasons and episode details work', async ({ page }) => {
  await login(page, 'browse');
  await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  await page.getByRole('button', { name: 'Favorite', pressed: false, exact: true }).click();
  await expect(page.getByRole('button', { name: 'Favorite', pressed: true, exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Favorite', pressed: true, exact: true }).click();
  await expect(page.getByRole('button', { name: 'Favorite', pressed: false, exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Favorite', pressed: false, exact: true }).click();
  await expect(page.getByRole('button', { name: 'Favorite', pressed: true, exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Watched', pressed: false, exact: true }).click();
  await expect(page.getByRole('button', { name: 'Watched', pressed: true, exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Watched', pressed: true, exact: true }).click();
  await expect(page.getByRole('button', { name: 'Watched', pressed: false, exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Watched', pressed: false, exact: true }).click();
  await expect(page.getByRole('button', { name: 'Watched', pressed: true, exact: true })).toBeVisible();
  await tab(page, 'Favorites'); await expect(page.locator('.media-grid .media-card')).toHaveCount(1);
  await tab(page, 'Library'); await expect(page.locator('.media-grid .media-card')).toHaveCount(60);
  await page.getByRole('button', { name: 'Load more titles' }).click(); await expect(page.locator('.media-grid .media-card')).toHaveCount(75);
  await page.getByRole('button', { name: 'Series', exact: true }).click(); await expect(page.locator('.media-grid .media-card')).toHaveCount(3);
  await tab(page, 'Search');
  await page.getByRole('searchbox').fill('wrong'); await page.getByRole('searchbox').fill('Out of the Blue');
  await expect(page.locator('.media-card[data-id="series-7"]')).toBeVisible();
  await page.locator('.media-card[data-id="series-7"]').click();
  await expect(page.locator('.episode-row')).toHaveCount(3);
  await page.getByRole('combobox', { name: 'Season', exact: true }).selectOption('season-2');
  await expect(page.locator('.episode-row[data-id="episode-2-1"]')).toBeVisible();
  await page.locator('.episode-row[data-id="episode-2-1"] .episode-main').click();
  await expect(page.locator('.detail-intro h1')).toHaveText('A new beginning');
});

test('real MP4 decodes, pauses, seeks and resumes from the updated Details position', async ({ page, request }) => {
  await login(page, 'playback');
  await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  await page.getByRole('button', { name: 'Play', exact: true }).click();
  await expect.poll(() => time(page)).toBeGreaterThan(1);
  await togglePlayback(page);
  await expect.poll(() => page.locator('#video').evaluate(element => (element as HTMLVideoElement).paused)).toBe(true);
  await chapter(page, '5');
  await expect.poll(() => time(page)).toBeGreaterThanOrEqual(4.9);
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Resume', exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Resume', exact: true }).click();
  await expect.poll(() => time(page)).toBeGreaterThan(4.5);
  await skipNative(page, 'ArrowLeft');
  await expect.poll(() => time(page)).toBeLessThan(2);
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  const state = await (await request.get(fixture + '/qa/state')).json();
  expect(state.reports.filter((report: { path: string }) => report.path.startsWith('/Sessions/Playing'))).toHaveLength(0);
});

test('HLS fallback loads actual media and exposes recovery transport', async ({ page }) => {
  await login(page, 'fallback');
  await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click();
  await expect(page.locator('#player-method')).toHaveText('HLS STREAM');
  await expect.poll(() => time(page), { timeout: 25000 }).toBeGreaterThan(.5);
  await expect(page.locator('#player-state')).toBeHidden();
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
});

test('multiple connection switching keeps account artwork and UI isolated', async ({ page, request }) => {
  await login(page, 'first', true);
  await tab(page, 'Servers');
  await page.getByLabel('Server address', { exact: true }).fill(fixture);
  await page.getByLabel('Username', { exact: true }).fill('second');
  await page.getByLabel('Password', { exact: true }).fill('demo');
  await page.getByLabel('Remember this connection on this device').check();
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.locator('.connection-button strong')).toHaveText('Sam');
  await expect.poll(() => page.locator('.hero-art img').evaluate(image => getComputedStyle(image).opacity)).toBe('1');
  await tab(page, 'Servers');
  await page.locator('.saved-connections article').filter({ hasText: 'Alex' }).getByRole('button', { name: 'Open', exact: true }).click();
  await expect(page.locator('.connection-button strong')).toHaveText('Alex');
  await expect.poll(() => page.locator('.hero-art img').evaluate(image => getComputedStyle(image).opacity)).toBe('1');
  const state = await (await request.get(fixture + '/qa/state')).json();
  expect(state.calls.some((call: { path: string; user: string }) => call.path.includes('/Images/') && call.user === 'first')).toBe(true);
  expect(state.calls.some((call: { path: string; user: string }) => call.path.includes('/Images/') && call.user === 'second')).toBe(true);
  await page.reload(); await expect(page.locator('.connection-button strong')).toHaveText('Alex');
});

test('empty and optional artwork failure remain usable', async ({ page }) => {
  await login(page, 'missingart');
  await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Play', exact: true })).toBeVisible();
  await page.context().clearCookies();
  await page.evaluate(() => localStorage.clear());
  await page.goto('/');
  await page.getByLabel('Server address', { exact: true }).fill(fixture);
  await page.getByLabel('Username', { exact: true }).fill('empty');
  await page.getByLabel('Password', { exact: true }).fill('demo');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'A little quiet in here.' })).toBeVisible();
});

test('TV-size keyboard focus and narrow layout remain operable', async ({ page }) => {
  await page.setViewportSize({ width: 1920, height: 1080 });
  await login(page, 'focus');
  await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).focus();
  await page.keyboard.press('ArrowRight');
  await expect(page.locator('.hero').getByRole('button', { name: 'Details', exact: true })).toBeFocused();
  await expect.poll(() => page.locator('.hero-art img').evaluate(image => getComputedStyle(image).opacity)).toBe('1');
  await page.screenshot({ path: 'test-results/home-1920.png', fullPage: false });
  await page.setViewportSize({ width: 390, height: 844 });
  await tab(page, 'Library');
  await expect(page.locator('.media-grid .media-card').first()).toBeVisible();
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth);
  expect(overflow).toBe(false);
  await expect.poll(() => page.locator('.media-grid img').first().evaluate(image => getComputedStyle(image).opacity)).toBe('1');
  await page.screenshot({ path: 'test-results/library-390.png', fullPage: false });
});

test('packaged TV classic bundle starts from file origin and plays real MP4', async ({ page, request }) => {
  const notices = await request.get('http://127.0.0.1:18779/THIRD_PARTY_NOTICES.txt');
  expect(notices.status()).toBe(200);
  const noticeText = await notices.text();
  expect(noticeText).toContain('Copyright (c) 2017 Dailymotion');
  expect(noticeText).toContain('Copyright (c) 2015-2016, DASH Industry Forum.');
  expect(noticeText).toContain('Copyright 2013 vtt.js Contributors');
  expect(noticeText).toContain('Copyright (C) 1999 Masanao Izumo');
  expect(noticeText).toContain('END OF TERMS AND CONDITIONS');
  expect(noticeText).toContain('VoidZero Inc. and Vite contributors');
  await page.setViewportSize({ width: 1920, height: 1080 });
  await login(page, 'tv-bundle', false, pathToFileURL(resolve('.cache/package-unpacked/index.html')).toString());
  await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click();
  await expect.poll(() => time(page)).toBeGreaterThan(.5);
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
});

test('music, photos, book export, live channel and receiver inventory entry paths work', async ({ page }) => {
  await login(page, 'media', true);
  await tab(page, 'Music');
  await page.locator('.media-card[data-id="album-1"]').click();
  await page.getByRole('button', { name: 'Open collection', exact: true }).click();
  await page.locator('.media-card[data-id="audio-1"]').click();
  await page.getByRole('button', { name: 'Play', exact: true }).click();
  await expect.poll(() => time(page)).toBeGreaterThan(.5);
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await tab(page, 'Photos');
  await page.locator('.media-card[data-id="photo-album-1"]').click();
  await page.getByRole('button', { name: 'Open collection', exact: true }).click();
  await page.locator('.media-card[data-id="photo-1"]').click();
  await page.getByRole('button', { name: 'View photo', exact: true }).click();
  await expect(page.locator('#photo-full')).toBeVisible();
  await page.getByRole('button', { name: 'Close photo', exact: true }).click();
  await tab(page, 'Books');
  await page.locator('.media-card[data-id="book-1"]').click();
  const downloadEvent = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Download book', exact: true }).click();
  const download = await downloadEvent;
  expect(download.suggestedFilename()).toContain('field guide');
  await tab(page, 'Live TV');
  await page.getByRole('button', { name: 'Reel Live', exact: true }).click();
  await expect.poll(() => time(page)).toBeGreaterThan(.5);
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await tab(page, 'Devices');
  await expect(page.getByRole('heading', { name: 'Fixture living room' })).toBeVisible();
});

test('a slow favorite completion cannot overwrite another route', async ({ page }) => {
  await login(page, 'stale');
  await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  let release: (() => void) | undefined;
  const wait = new Promise<void>(resolve => { release = resolve; });
  await page.route('**/UserFavoriteItems/**', async request => { await wait; await request.continue(); });
  await page.getByRole('button', { name: 'Favorite', pressed: false, exact: true }).click();
  await tab(page, 'Library');
  await expect(page.locator('.media-grid')).toBeVisible();
  release!();
  await expect.poll(async () => page.locator('.media-grid .media-card').count()).toBe(60);
  await expect(page.locator('.detail-intro')).toHaveCount(0);
});

test('opt-in loopback watch reports keep start before stop and quality persists', async ({ page, request }) => {
  await login(page, 'reports', true);
  await tab(page, 'Settings');
  await page.locator('#quality').selectOption('2000000');
  await page.getByLabel('Private viewing').uncheck();
  await tab(page, 'Home');
  await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click();
  await expect(page.locator('#player-method')).toHaveText('HLS STREAM');
  await expect.poll(() => time(page)).toBeGreaterThan(1);
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await expect.poll(async () => {
    const state = await (await request.get(fixture + '/qa/state')).json();
    return state.reports.some((report: { path: string }) => report.path === '/Sessions/Playing/Stopped');
  }).toBe(true);
  const state = await (await request.get(fixture + '/qa/state')).json();
  const reports = state.reports.filter((report: { path: string }) => report.path.startsWith('/Sessions/Playing'));
  expect(reports[0].path).toBe('/Sessions/Playing');
  expect(reports.at(-1).path).toBe('/Sessions/Playing/Stopped');
  expect(reports.at(-1).body.PositionTicks).toBeGreaterThan(0);
  await page.reload(); await tab(page, 'Settings');
  await expect(page.locator('#quality')).toHaveValue('2000000');
});

test('partial shelf failure and actual offline recovery remain actionable', async ({ page, context }) => {
  await login(page, 'flaky');
  await expect(page.locator('.inline-notice')).toBeVisible();
  await page.locator('.inline-notice').getByRole('button', { name: 'Retry' }).click();
  await expect(page.locator('.inline-notice')).toHaveCount(0);
  await context.setOffline(true);
  await tab(page, 'Library');
  await expect(page.getByRole('alert', { name: 'Library error' })).toContainText('Your collection could not load.');
  await context.setOffline(false);
  await page.getByRole('button', { name: 'Try again', exact: true }).click();
  await expect(page.locator('.media-grid .media-card')).toHaveCount(60);
});

test('leaving Connections cancels a pending second-server sign-in', async ({ page, request }) => {
  await login(page, 'first', true);
  await tab(page, 'Servers');
  let release: (() => void) | undefined;
  const wait = new Promise<void>(resolve => { release = resolve; });
  await page.route('**/System/Info/Public', async pending => { await wait; await pending.continue().catch(() => undefined); });
  await page.getByLabel('Server address', { exact: true }).fill(fixture);
  await page.getByLabel('Username', { exact: true }).fill('second');
  await page.getByLabel('Password', { exact: true }).fill('demo');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Connecting…', exact: true })).toBeDisabled();
  await tab(page, 'Library'); release!();
  await expect(page.locator('.media-grid')).toBeVisible();
  await expect(page.locator('.connection-button strong')).toHaveText('Alex');
  const state = await (await request.get(fixture + '/qa/state')).json();
  expect(state.calls.filter((call: { path: string }) => call.path === '/Users/AuthenticateByName')).toHaveLength(1);
});

test('a known provisional token is revoked when durable sign-in saving fails', async ({ page, request }) => {
  await page.goto('/');
  await page.evaluate(() => {
    const original = Storage.prototype.setItem;
    Storage.prototype.setItem = function (key, value) { if (key === 'reel.connections.v1') throw new Error('Synthetic storage failure'); return original.call(this, key, value); };
  });
  await page.getByLabel('Server address', { exact: true }).fill(fixture);
  await page.getByLabel('Username', { exact: true }).fill('provisional');
  await page.getByLabel('Password', { exact: true }).fill('demo');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.locator('#connection-error')).toHaveText('Reel could not save this change. The previous saved connections have not been replaced. Check browser storage and try again.');
  await expect.poll(async () => {
    const state = await (await request.get(fixture + '/qa/state')).json();
    return state.calls.some((call: { path: string; user: string }) => call.path === '/Sessions/Logout' && call.user === 'provisional');
  }).toBe(true);
  expect(await page.evaluate(() => localStorage.getItem('reel.connections.v1'))).toBeNull();
});

test('malformed numeric metadata cannot execute markup in the application origin', async ({ page }) => {
  const payload = '<img src="invalid-review-resource" onerror="window.__reelReviewInjection=true">';
  await page.route('**/Items/movie-1?*', async intercepted => {
    const response = await intercepted.fetch(), item = await response.json();
    item.MediaSources[0].MediaStreams[1].Index = '1">' + payload;
    await intercepted.fulfill({ response, json: item });
  });
  await page.route('**/Shows/series-7/Episodes?*', async intercepted => {
    const response = await intercepted.fetch(), page = await response.json();
    page.Items[0].IndexNumber = payload;
    await intercepted.fulfill({ response, json: page });
  });
  await login(page, 'injection');
  await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  await expect(page.locator('[onerror]')).toHaveCount(0);
  expect(await page.evaluate(() => (window as Window & { __reelReviewInjection?: boolean }).__reelReviewInjection)).not.toBe(true);
  await tab(page, 'Library'); await page.getByRole('button', { name: 'Series', exact: true }).click();
  await page.locator('.media-card[data-id="series-7"]').click();
  await expect(page.locator('.episode-row')).toHaveCount(3);
  await expect(page.locator('[onerror]')).toHaveCount(0);
  expect(await page.evaluate(() => (window as Window & { __reelReviewInjection?: boolean }).__reelReviewInjection)).not.toBe(true);
});

test('NextUp-only Home remains usable when every other shelf is empty', async ({ page }) => {
  await page.route('**/Items/Latest?*', request => request.fulfill({ json: [] }));
  await page.route('**/UserItems/Resume?*', request => request.fulfill({ json: { Items: [] } }));
  await login(page, 'next-only');
  await expect(page.locator('.hero h1')).toHaveText('Out of the Blue');
  await expect(page.locator('.hero-meta')).toHaveText('S1 E2 Below the surface');
  await expect(page.locator('.hero').getByRole('button', { name: 'Play', exact: true })).toBeEnabled();
  await expect(page.getByRole('heading', { name: 'Up next' })).toBeVisible();
});

test('opting out of history discards a failed final report before reconnect', async ({ page, context, request }) => {
  await login(page, 'optout', true);
  await tab(page, 'Settings'); await page.getByLabel('Private viewing').uncheck();
  await tab(page, 'Home');
  await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click();
  await expect.poll(() => time(page)).toBeGreaterThan(.5);
  let failedStops = 0;
  await page.route('**/Sessions/Playing/Stopped', pending => { failedStops++; return pending.fulfill({ status: 503, json: {} }); });
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await expect.poll(() => failedStops).toBe(1);
  await tab(page, 'Settings'); await page.getByLabel('Private viewing').check();
  await page.unroute('**/Sessions/Playing/Stopped');
  const unexpectedRetry = page.waitForRequest(pending => pending.url().endsWith('/Sessions/Playing/Stopped'), { timeout: 800 }).then(() => true).catch(() => false);
  await context.setOffline(true); await context.setOffline(false);
  expect(await unexpectedRetry).toBe(false);
  const state = await (await request.get(fixture + '/qa/state')).json();
  expect(state.reports.filter((report: { path: string }) => report.path === '/Sessions/Playing/Stopped')).toHaveLength(0);
});

test('completion permits replay and next episode starts with a new item identity', async ({ page }) => {
  await login(page, 'endings');
  await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  await page.getByRole('button', { name: 'Play', exact: true }).click();
  await expect.poll(() => time(page)).toBeGreaterThan(.3);
  await skipNative(page, 'ArrowRight');
  await expect(page.locator('#player-state').getByRole('heading', { name: 'Finished watching' })).toBeVisible();
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Play', exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Play', exact: true }).click();
  await expect.poll(() => time(page)).toBeGreaterThan(.2);
  expect(await time(page)).toBeLessThan(3);
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await tab(page, 'Home'); await playFirstEpisode(page);
  await expect.poll(() => time(page)).toBeGreaterThan(.2);
  await skipNative(page, 'ArrowRight');
  await page.locator('#player-state').getByRole('button', { name: 'Below the surface', exact: true }).click();
  await expect(page.locator('#player-subtitle')).toContainText('Below the surface');
  await expect.poll(() => time(page)).toBeGreaterThan(.2);
});

test('removing an account with a failed stop does not block the next account reports', async ({ page, request }) => {
  await login(page, 'removed', true);
  await tab(page, 'Settings'); await page.getByLabel('Private viewing').uncheck();
  await tab(page, 'Home'); await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click();
  await expect.poll(() => time(page)).toBeGreaterThan(.3);
  let oldStops = 0;
  await page.route('**/Sessions/Playing/Stopped', pending => {
    if ((pending.request().headers().authorization ?? '').includes('fixture-removed')) { oldStops++; return pending.fulfill({ status: 503, json: {} }); }
    return pending.continue();
  });
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await expect.poll(() => oldStops).toBe(1);
  await tab(page, 'Servers'); await page.getByRole('button', { name: 'Sign out', exact: true }).click();
  await expect(page.locator('.saved-connections article')).toHaveCount(0);
  // Sign-out may retry the failed final stop while the old token is still valid.
  // After removal, no old-account attempt may precede or block the new account.
  const stopsAtRemoval = oldStops;
  await page.getByLabel('Server address', { exact: true }).fill(fixture);
  await page.getByLabel('Username', { exact: true }).fill('second');
  await page.getByLabel('Password', { exact: true }).fill('demo');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.locator('.connection-button strong')).toHaveText('Sam');
  await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click();
  await expect.poll(() => time(page)).toBeGreaterThan(.3);
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await expect.poll(async () => {
    const state = await (await request.get(fixture + '/qa/state')).json();
    return state.reports.some((report: { path: string; user: string }) => report.user === 'second' && report.path === '/Sessions/Playing/Stopped');
  }).toBe(true);
  expect(oldStops).toBe(stopsAtRemoval);
});

test('leaving Search cancels the pending term before another route can send it', async ({ page }) => {
  await login(page, 'search-fence');
  await tab(page, 'Search');
  const leakedQuery = page.waitForRequest(request => request.url().includes('searchTerm=synthetic-old-search'), { timeout: 800 }).then(() => true).catch(() => false);
  await page.getByRole('searchbox').fill('synthetic-old-search');
  await tab(page, 'Library');
  expect(await leakedQuery).toBe(false);
  await expect(page.getByRole('searchbox')).toHaveValue('');
  await expect(page.locator('.media-grid .media-card')).toHaveCount(60);
});

test('connection validation, narrow sign-in, base path and memory-only reload are exercised', async ({ page, request }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto('/');
  await page.getByLabel('Server address', { exact: true }).fill(fixture);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.getByLabel('Username', { exact: true })).toBeFocused();
  await page.getByLabel('Server address', { exact: true }).fill('http://remote.example');
  await page.getByLabel('Username', { exact: true }).fill('validation');
  await page.getByLabel('Password', { exact: true }).fill('demo');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.locator('#connection-error')).toContainText('Remote connections need HTTPS');
  await page.getByLabel('Server address', { exact: true }).fill('https://username:password@example.com');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.locator('#connection-error')).toContainText('without a username');
  await page.getByLabel('Server address', { exact: true }).fill(fixture + '/jellyfin');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.locator('.hero h1')).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)).toBe(false);
  const state = await (await request.get(fixture + '/qa/state')).json();
  expect(state.calls.filter((call: { path: string }) => call.path === '/Users/AuthenticateByName')).toHaveLength(1);
  await page.reload(); await expect(page.getByLabel('Username', { exact: true })).toBeVisible();
});

test('all browse filters and sort options, search submit and brand navigation are exercised', async ({ page, request }) => {
  await login(page, 'browse-options'); await tab(page, 'Library');
  await page.getByRole('button', { name: 'Movies', exact: true }).click();
  await expect(page.locator('.media-card[data-id^="series-"]')).toHaveCount(0);
  await page.getByRole('button', { name: 'Collections', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'No matching titles.' })).toBeVisible();
  await page.getByRole('button', { name: 'Playlists', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'No matching titles.' })).toBeVisible();
  await page.getByRole('button', { name: 'All titles', exact: true }).click();
  async function selectOrder(control: string, value: string, sort: string, direction: string, firstID: string) {
    const completed = page.waitForResponse(response => {
      const url = new URL(response.url());
      return url.origin === fixture && url.pathname === '/Items' && response.status() === 200
        && url.searchParams.get('sortBy') === sort && url.searchParams.get('sortOrder') === direction;
    });
    await page.locator(control).selectOption(value);
    const response = await completed; await response.finished();
    const body = await response.json(); expect(body.Items[0].Id).toBe(firstID);
    await expect(page.locator('.media-grid .media-card').first()).toHaveAttribute('data-id', firstID);
  }
  await page.locator('#browse-filter-toggle').click();
  await selectOrder('#sort', 'DateCreated', 'DateCreated,SortName', 'Descending,Ascending', 'movie-75');
  await expect(page.locator('#browse-direction')).toHaveValue('Descending');
  await expect(page.locator('.media-grid .media-card').first()).toContainText('Added');
  await selectOrder('#browse-direction', 'Ascending', 'DateCreated,SortName', 'Ascending,Ascending', 'movie-1');
  await selectOrder('#browse-direction', 'Descending', 'DateCreated,SortName', 'Descending,Ascending', 'movie-75');
  await selectOrder('#sort', 'ProductionYear', 'ProductionYear,SortName', 'Descending,Ascending', 'movie-30');
  await selectOrder('#sort', 'SortName', 'SortName', 'Ascending', 'movie-6');
  await selectOrder('#browse-direction', 'Descending', 'SortName', 'Descending', 'series-8');
  await selectOrder('#browse-direction', 'Ascending', 'SortName', 'Ascending', 'movie-6');
  await page.getByRole('searchbox').fill('Quiet Earth'); await page.getByRole('searchbox').press('Enter');
  await expect(page.locator('.media-card').first()).toContainText('Quiet Earth');
  await page.locator('#rail').getByRole('button', { name: 'Reel home', exact: true }).click();
  await expect(page.locator('.hero h1')).toBeVisible();
  const state = await (await request.get(fixture + '/qa/state')).json();
  expect(state.reports.filter((report: { path: string }) => report.path.startsWith('/Sessions/Playing'))).toHaveLength(0);
});

test('source-specific tracks, server defaults, subtitles off, speed and full screen are exercised', async ({ page, request }) => {
  await page.route('**/Items/movie-1?*', async intercepted => {
    const response = await intercepted.fetch(), item = await response.json();
    item.MediaSources.push({ ...item.MediaSources[0], Id: 'alternate-source', MediaStreams: [{ Type: 'Audio', Index: 3, Codec: 'aac', DisplayTitle: 'Alternate AAC' }, { Type: 'Subtitle', Index: 4, Codec: 'vtt', DisplayTitle: 'Alternate captions' }] });
    await intercepted.fulfill({ response, json: item });
  });
  await login(page, 'tracks'); await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  // Audio, subtitles and version sit behind one Audio and subtitles menu, which stays open while they change.
  await page.locator('#track-menu > summary').click();
  await page.locator('#media-source').selectOption('alternate-source');
  await expect(page.locator('#audio-track')).toContainText('Alternate AAC');
  await page.locator('#audio-track').selectOption('3'); await page.locator('#subtitle-track').selectOption('4');
  await page.getByRole('button', { name: 'Favorite', pressed: false, exact: true }).click();
  await expect(page.locator('#audio-track')).toHaveValue('3'); await expect(page.locator('#subtitle-track')).toHaveValue('4');
  await page.getByRole('button', { name: 'Play', exact: true }).click();
  await expect.poll(() => time(page)).toBeGreaterThan(.3);
  await page.getByRole('button', { name: 'Playback options', exact: true }).click();
  for (const speed of ['0.25', '0.5', '0.75', '1', '1.25', '1.5', '1.75', '2']) {
    await page.locator('#speed').selectOption(speed);
    expect(await page.locator('#video').evaluate(element => (element as HTMLVideoElement).playbackRate)).toBe(Number(speed));
  }
  await page.locator('#speed').selectOption('1');
  await page.getByRole('button', { name: 'Close playback options', exact: true }).click();
  await page.getByRole('button', { name: 'Full screen', exact: true }).click();
  await expect.poll(() => page.evaluate(() => document.fullscreenElement?.id)).toBe('player');
  await page.keyboard.press('Escape');
  await expect.poll(() => page.evaluate(() => document.fullscreenElement === null)).toBe(true);
  await expect(page.locator('#player')).toBeVisible();
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await expect(page.locator('#audio-track')).toHaveValue('3'); await expect(page.locator('#subtitle-track')).toHaveValue('4');
  await page.locator('#track-menu > summary').click();
  await page.locator('#media-source').selectOption('movie-1-source');
  await expect(page.locator('#audio-track')).toHaveValue(''); await expect(page.locator('#subtitle-track')).toHaveValue('');
  await page.locator('#audio-track').selectOption(''); await page.locator('#subtitle-track').selectOption('-1');
  await page.getByRole('button', { name: 'Restart', exact: true }).click();
  await expect.poll(() => time(page)).toBeGreaterThan(.2);
  expect(await time(page)).toBeLessThan(3);
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  const state = await (await request.get(fixture + '/qa/state')).json();
  const negotiations = state.reports.filter((report: { path: string }) => report.path.endsWith('/PlaybackInfo'));
  expect(negotiations[0].body.MediaSourceId).toBe('alternate-source');
  expect(negotiations[0].body.AudioStreamIndex).toBe(3); expect(negotiations[0].body.SubtitleStreamIndex).toBe(4);
  expect(negotiations.at(-1).body.SubtitleStreamIndex).toBe(-1);
  expect(negotiations.at(-1).body.StartTimeTicks).toBe(0);
});

test('preparation controls disable, final playback error retries, and favorite error recovers', async ({ page }) => {
  await login(page, 'errors'); await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  await page.route('**/UserFavoriteItems/**', pending => pending.fulfill({ status: 503, json: {} }));
  await page.getByRole('button', { name: 'Favorite', pressed: false, exact: true }).click();
  await expect(page.locator('#toast')).toContainText('503');
  await expect(page.getByRole('button', { name: 'Favorite', pressed: false, exact: true })).toBeEnabled();
  await page.unroute('**/UserFavoriteItems/**'); await page.getByRole('button', { name: 'Favorite', pressed: false, exact: true }).click();
  await expect(page.getByRole('button', { name: 'Favorite', pressed: true, exact: true })).toBeVisible();
  let release: (() => void) | undefined; const wait = new Promise<void>(resolve => { release = resolve; });
  await page.route('**/PlaybackInfo', async pending => { await wait; await pending.fulfill({ status: 503, json: {} }); });
  await page.getByRole('button', { name: 'Play', exact: true }).click();
  await expect(page.locator('#player-state').getByRole('heading', { name: 'Setting the scene.' })).toBeVisible();
  await page.getByRole('button', { name: 'Playback options', exact: true }).click();
  await expect(page.getByLabel('Playback speed', { exact: true })).toBeDisabled();
  await page.getByRole('button', { name: 'Close playback options', exact: true }).click();
  release!();
  await expect(page.getByRole('button', { name: 'Retry from saved position' })).toBeVisible();
  await page.unroute('**/PlaybackInfo'); await page.getByRole('button', { name: 'Retry from saved position' }).click();
  await expect.poll(() => time(page)).toBeGreaterThan(.3);
  expect(await page.locator('#video').evaluate(element => (element as HTMLVideoElement).controls)).toBe(true);
  await page.getByRole('button', { name: 'Close player', exact: true }).focus(); await page.keyboard.press('Space');
  await expect(page.locator('#player')).toBeHidden();
});

test('permission recovery, loading, Back and four focus directions are exercised', async ({ page }) => {
  await page.goto('/');
  await page.getByLabel('Server address', { exact: true }).fill(fixture);
  await page.getByLabel('Username', { exact: true }).fill('expired');
  await page.getByLabel('Password', { exact: true }).fill('demo');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Let’s try that again.' })).toBeVisible();
  await page.getByRole('button', { name: 'Servers', exact: true }).last().click();
  await page.getByRole('button', { name: 'Sign out', exact: true }).click();
  await page.getByLabel('Server address', { exact: true }).fill(fixture);
  await page.getByLabel('Username', { exact: true }).fill('slow');
  await page.getByLabel('Password', { exact: true }).fill('demo');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Opening your library.' })).toBeVisible();
  await expect(page.locator('.hero h1')).toBeVisible();
  const play = page.locator('.hero').getByRole('button', { name: 'Play', exact: true });
  const details = page.locator('.hero').getByRole('button', { name: 'Details', exact: true });
  await play.focus(); await page.keyboard.press('ArrowRight'); await expect(details).toBeFocused();
  await page.keyboard.press('ArrowLeft'); await expect(play).toBeFocused();
  await page.keyboard.press('ArrowDown'); await expect(play).not.toBeFocused();
  await play.focus(); await page.keyboard.press('ArrowUp'); await expect(play).not.toBeFocused();
  await details.click(); await page.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(page.locator('.hero h1')).toBeVisible();
});

test('protected nonloopback UI blocks watched, favorite, history and book downloads', async ({ page, request }) => {
  await page.route('**/reel-config.js', route => route.fulfill({ contentType: 'text/javascript', body: 'window.REEL_CONFIG={platform:"web",previewMode:true};' }));
  await page.route('https://media.preview.test/**', async pending => {
    const original = new URL(pending.request().url());
    const response = await pending.fetch({ url: fixture + original.pathname + original.search });
    await pending.fulfill({ response });
  });
  await login(page, 'protected', true, '/', 'https://media.preview.test');
  await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Favorite', pressed: false, exact: true })).toBeDisabled();
  await expect(page.getByRole('button', { name: 'Watched', pressed: false, exact: true })).toBeDisabled();
  await expect(page.locator('.protection-note')).toContainText('View only');
  await tab(page, 'Settings'); await expect(page.getByLabel('Private viewing')).toBeDisabled();
  await tab(page, 'Books'); await page.locator('.media-card[data-id="book-1"]').click();
  await expect(page.getByRole('button', { name: 'Download book', exact: true })).toBeDisabled();
  const state = await (await request.get(fixture + '/qa/state')).json();
  expect(state.calls.filter((call: { path: string }) => /UserFavoriteItems|UserPlayedItems|Sessions\/Playing|\/Download$/.test(call.path))).toHaveLength(0);
});

test('empty Favorites and Search plus pagination failure and retry are exercised', async ({ page }) => {
  await login(page, 'empty-controls'); await tab(page, 'Favorites');
  await expect(page.getByRole('heading', { name: 'No matching titles.' })).toBeVisible();
  await tab(page, 'Search'); await expect(page.getByRole('heading', { name: 'A title in mind?' })).toBeVisible();
  await page.getByRole('searchbox').fill('synthetic-no-title');
  await expect(page.getByRole('heading', { name: 'No matching titles.' })).toBeVisible();
  await page.getByRole('searchbox').fill('');
  await expect(page.getByRole('heading', { name: 'A title in mind?' })).toBeVisible();
  await tab(page, 'Library');
  await page.route('**/Items?*', pending => new URL(pending.request().url()).searchParams.get('startIndex') === '60' ? pending.fulfill({ status: 503, json: {} }) : pending.continue());
  await page.getByRole('button', { name: 'Load more titles' }).click();
  await expect(page.getByRole('alert', { name: 'Library error' })).toContainText('503');
  await expect(page.locator('.media-grid .media-card')).toHaveCount(60);
  await expect(page.getByRole('button', { name: 'Retry next page' })).toBeEnabled();
  await page.unroute('**/Items?*');
  const retried = page.waitForResponse(response => { const url = new URL(response.url()); return url.pathname === '/Items' && url.searchParams.get('startIndex') === '60' && response.status() === 200; });
  await page.getByRole('button', { name: 'Retry next page' }).click(); await retried;
  await expect(page.locator('.media-grid .media-card')).toHaveCount(75);
});

test('logout failure preserves local sign-out, 403 recovery and reduced motion are exercised', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await login(page, 'logout', true);
  await expect.poll(() => page.locator('.hero-art img').evaluate(image => getComputedStyle(image).transitionDuration)).toBe('0s');
  await page.route('**/Items?*', pending => pending.fulfill({ status: 403, json: {} }));
  await tab(page, 'Library'); await expect(page.getByRole('alert', { name: 'Library error' })).toContainText('Your collection could not load.');
  await page.unroute('**/Items?*'); await page.getByRole('button', { name: 'Try again', exact: true }).click();
  await expect(page.locator('.media-grid .media-card')).toHaveCount(60);
  await page.route('**/Sessions/Logout', pending => pending.fulfill({ status: 503, json: {} }));
  await tab(page, 'Servers'); await page.getByRole('button', { name: 'Sign out', exact: true }).click();
  await expect(page.locator('#toast')).toContainText('Signed out here.');
  await page.reload(); await expect(page.getByLabel('Username', { exact: true })).toBeVisible();
});

test('continue card resume and a real buffering gap remain controllable and recover', async ({ page }) => {
  await login(page, 'buffering');
  await page.locator('.wide-card[data-id="movie-4"]').click();
  await expect.poll(() => time(page)).toBeGreaterThanOrEqual(2.8);
  await expect.poll(() => page.locator('#video').evaluate(element => (element as HTMLVideoElement).paused)).toBe(false);
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click();
  await expect.poll(() => time(page)).toBeGreaterThan(.3);
  await expect(page.locator('#player-state')).toContainText('Buffering', { timeout: 15000 });
  expect(await page.locator('#video').evaluate(element => (element as HTMLVideoElement).controls)).toBe(true);
  await togglePlayback(page);
  await expect.poll(() => page.locator('#video').evaluate(element => (element as HTMLVideoElement).paused)).toBe(true);
  await togglePlayback(page);
  await expect.poll(() => time(page), { timeout: 15000 }).toBeGreaterThan(5);
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
});

test('season loading hides stale rows, failed selection restores and empty seasons recover', async ({ page }) => {
  await login(page, 'season-states'); await tab(page, 'Library');
  await page.getByRole('button', { name: 'Series', exact: true }).click();
  await page.locator('.media-card[data-id="series-7"]').click();
  await expect(page.locator('.episode-row[data-id="episode-1-1"]')).toBeVisible();
  let release: (() => void) | undefined; const wait = new Promise<void>(resolve => { release = resolve; });
  await page.route('**/Shows/series-7/Episodes?*', async pending => { await wait; await pending.fulfill({ status: 503, json: {} }); });
  await page.locator('#season').selectOption('season-2');
  await expect(page.locator('#season')).toBeDisabled();
  await expect(page.getByText('Opening this season.', { exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Play', exact: true })).toHaveCount(0);
  await expect(page.locator('.episode-row')).toHaveCount(0);
  release!(); await expect(page.locator('#toast')).toContainText('503');
  await expect(page.locator('#season')).toHaveValue('season-1');
  await expect(page.locator('#season')).toBeEnabled();
  await expect(page.locator('.episode-row[data-id="episode-1-1"]')).toBeVisible();
  await page.unroute('**/Shows/series-7/Episodes?*');
  await page.route('**/Shows/series-7/Episodes?*', pending => pending.fulfill({ json: { Items: [] } }));
  await page.locator('#season').selectOption('season-2');
  await expect(page.getByText('No episodes are available in this season.', { exact: true })).toBeVisible();
  await expect(page.locator('#season')).toBeEnabled();
  await page.unroute('**/Shows/series-7/Episodes?*');
  await page.locator('#season').selectOption('season-1');
  await expect(page.locator('.episode-row')).toHaveCount(3);
  let releaseLate: (() => void) | undefined; const late = new Promise<void>(resolve => { releaseLate = resolve; });
  await page.route('**/Shows/series-7/Episodes?*', async pending => { await late; await pending.fulfill({ json: { Items: [] } }).catch(() => undefined); });
  await page.locator('#season').selectOption('season-2'); await tab(page, 'Home'); releaseLate!();
  await expect(page.locator('.hero h1')).toBeVisible();
  await expect(page.locator('#season')).toHaveCount(0);
});

test('catalog empty states and route-specific server errors recover through the actual controls', async ({ page }) => {
  await login(page, 'catalog-states');
  await page.route('**/Items?*', pending => pending.fulfill({ json: { Items: [], TotalRecordCount: 0 } }));
  await tab(page, 'Music'); await expect(page.getByRole('heading', { name: 'No matching titles.' })).toBeVisible();
  await tab(page, 'Photos'); await expect(page.getByRole('heading', { name: 'No matching titles.' })).toBeVisible();
  await tab(page, 'Books'); await expect(page.getByRole('heading', { name: 'No matching titles.' })).toBeVisible();
  await page.unroute('**/Items?*');
  await page.route('**/LiveTv/Channels?*', pending => pending.fulfill({ json: { Items: [] } }));
  await tab(page, 'Live TV'); await expect(page.getByRole('heading', { name: 'No channels here yet.' })).toBeVisible();
  await page.unroute('**/LiveTv/Channels?*');
  await page.route('**/Sessions', pending => pending.fulfill({ json: [] }));
  await tab(page, 'Devices'); await expect(page.getByRole('heading', { name: 'No other screens found.' })).toBeVisible();
  await page.unroute('**/Sessions'); await tab(page, 'Home');
  await page.route('**/Items/movie-1?*', pending => pending.fulfill({ status: 503, json: {} }));
  await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Let’s try that again.' })).toBeVisible();
  await page.unroute('**/Items/movie-1?*'); await page.getByRole('button', { name: 'Try again', exact: true }).click();
  await expect(page.locator('.detail-intro h1')).toHaveText('The Quiet Earth');
  await tab(page, 'Search'); await page.route('**/Items?*', pending => pending.fulfill({ status: 503, json: {} }));
  await page.getByRole('searchbox').fill('Out of the Blue');
  await expect(page.getByRole('alert', { name: 'Library error' })).toContainText('Your collection could not load.');
  await page.unroute('**/Items?*'); await page.getByRole('button', { name: 'Try again', exact: true }).click();
  await expect(page.locator('.media-card[data-id="series-7"]')).toBeVisible();
  await page.route('**/Shows/series-7/Seasons?*', pending => pending.fulfill({ status: 403, json: {} }));
  await page.locator('.media-card[data-id="series-7"]').click();
  await expect(page.getByRole('heading', { name: 'Let’s try that again.' })).toBeVisible();
  await page.unroute('**/Shows/series-7/Seasons?*'); await page.getByRole('button', { name: 'Try again', exact: true }).click();
  await expect(page.locator('.episode-row')).toHaveCount(3);
});

test('settings persist both history states and all quality options while modal focus stays contained', async ({ page }) => {
  await login(page, 'modal-settings', true); await tab(page, 'Settings');
  for (const quality of ['120000000', '20000000', '8000000', '2000000']) {
    await page.locator('#quality').selectOption(quality);
    await expect(page.locator('#quality')).toHaveValue(quality);
  }
  await page.getByLabel('Private viewing').uncheck(); await page.reload(); await tab(page, 'Settings');
  await expect(page.getByLabel('Private viewing')).not.toBeChecked();
  await expect(page.locator('#quality')).toHaveValue('2000000');
  await page.getByLabel('Private viewing').check(); await page.reload(); await tab(page, 'Settings');
  await expect(page.getByLabel('Private viewing')).toBeChecked();
  await page.locator('#quality').selectOption('120000000');
  await page.getByRole('button', { name: 'Manage servers', exact: true }).click();
  await expect(page.getByLabel('Server address', { exact: true })).toBeVisible();
  await tab(page, 'Photos'); await page.locator('.media-card[data-id="photo-1"]').click();
  await page.getByRole('button', { name: 'View photo', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Close photo', exact: true })).toBeFocused();
  await page.keyboard.press('Tab'); await expect(page.getByRole('button', { name: 'Close photo', exact: true })).toBeFocused();
  await page.keyboard.press('Shift+Tab'); await expect(page.getByRole('button', { name: 'Close photo', exact: true })).toBeFocused();
  await page.keyboard.press('Escape'); await expect(page.locator('#photo-viewer')).toBeHidden();
  await tab(page, 'Home'); await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click();
  await expect.poll(() => time(page)).toBeGreaterThan(.3);
  await page.getByRole('button', { name: 'Full screen', exact: true }).focus();
  await page.keyboard.press('Tab'); await expect(page.locator('#video')).toBeFocused();
  await page.keyboard.press('Tab'); await expect(page.getByRole('button', { name: 'Close player', exact: true })).toBeFocused();
  await page.keyboard.press('Shift+Tab'); await expect(page.locator('#video')).toBeFocused();
  await page.keyboard.press('Shift+Tab'); await expect(page.getByRole('button', { name: 'Full screen', exact: true })).toBeFocused();
  await chapter(page, '0'); await expect.poll(() => time(page)).toBeLessThan(2);
  await page.keyboard.press('Escape'); await expect(page.locator('#player')).toBeHidden();
});

test('malformed optional rating does not prevent a usable Home', async ({ page }) => {
  await page.route('**/Items/Latest?*', async pending => {
    const response = await pending.fetch(), items = await response.json();
    for (const item of items) item.CommunityRating = 'invalid-optional-rating';
    await pending.fulfill({ response, json: items });
  });
  await login(page, 'malformed-rating');
  await expect(page.locator('.hero h1')).toBeVisible();
  await expect(page.locator('.rating')).toHaveCount(0);
  await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Play', exact: true })).toBeEnabled();
});

test('switching accounts aborts in-flight artwork bodies after headers and new artwork recovers', async ({ page, request }) => {
  await login(page, 'cancel-art', true);
  await expect.poll(async () => (await (await request.get(fixture + '/qa/state')).json()).calls.filter((call: { user: string; path: string }) => call.user === 'cancel-art' && call.path.includes('/Images/')).length).toBeGreaterThan(0);
  await tab(page, 'Servers');
  await page.getByLabel('Server address', { exact: true }).fill(fixture);
  await page.getByLabel('Username', { exact: true }).fill('second');
  await page.getByLabel('Password', { exact: true }).fill('demo');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.locator('.connection-button strong')).toHaveText('Sam');
  await expect.poll(async () => (await (await request.get(fixture + '/qa/state')).json()).artworkCancellations).toBeGreaterThan(0);
  await expect.poll(() => page.locator('.hero-art img').evaluate(image => getComputedStyle(image).opacity)).toBe('1');
});

test('concurrent favorite and watched completions preserve both successful changes', async ({ page }) => {
  await login(page, 'concurrent-flags'); await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  let releaseFavorite: (() => void) | undefined, releaseWatched: (() => void) | undefined;
  const favorite = new Promise<void>(resolve => { releaseFavorite = resolve; });
  const watched = new Promise<void>(resolve => { releaseWatched = resolve; });
  await page.route('**/UserFavoriteItems/**', async pending => { await favorite; await pending.continue(); });
  await page.route('**/UserPlayedItems/**', async pending => { await watched; await pending.continue(); });
  await page.getByRole('button', { name: 'Favorite', pressed: false, exact: true }).click();
  await page.getByRole('button', { name: 'Watched', pressed: false, exact: true }).click();
  await expect(page.getByRole('button', { name: 'Watched', pressed: false, exact: true })).toBeDisabled();
  releaseWatched!(); await expect(page.getByRole('button', { name: 'Watched', pressed: true, exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Favorite', pressed: false, exact: true })).toBeDisabled();
  releaseFavorite!(); await expect(page.getByRole('button', { name: 'Favorite', pressed: true, exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Favorite', pressed: true, exact: true })).toBeVisible();
  await page.unroute('**/UserFavoriteItems/**'); await page.unroute('**/UserPlayedItems/**');
  await tab(page, 'Home'); await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Favorite', pressed: true, exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Watched', pressed: true, exact: true })).toBeVisible();
});

test('Home footer has readable text contrast and the application document stays labeled', async ({ page }) => {
  await login(page, 'contrast'); await page.locator('.page-footer').scrollIntoViewIfNeeded();
  const ratio = await page.locator('.page-footer').evaluate(footer => {
    const luminance = (rgb: string) => {
      const colors = rgb.match(/[\d.]+/g)!.slice(0, 3).map(value => Number(value) / 255).map(value => value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4);
      return colors[0] * .2126 + colors[1] * .7152 + colors[2] * .0722;
    };
    const foreground = luminance(getComputedStyle(footer).color), background = luminance(getComputedStyle(document.documentElement).backgroundColor);
    return (Math.max(foreground, background) + .05) / (Math.min(foreground, background) + .05);
  });
  expect(ratio).toBeGreaterThanOrEqual(4.5);
  await expect(page).toHaveTitle('Reel');
  await expect(page.locator('html')).toHaveAttribute('lang', 'en');
});

test('returning to an item while its save is pending refreshes the completed result and control', async ({ page }) => {
  await login(page, 'return-pending'); await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  let release: (() => void) | undefined; const wait = new Promise<void>(resolve => { release = resolve; });
  await page.route('**/UserFavoriteItems/**', async pending => { await wait; await pending.continue(); });
  await page.getByRole('button', { name: 'Favorite', pressed: false, exact: true }).click();
  await tab(page, 'Home'); await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Favorite', pressed: false, exact: true })).toBeDisabled();
  release!(); await expect(page.getByRole('button', { name: 'Favorite', pressed: true, exact: true })).toBeEnabled();
});

test('stalled book body shows pending, times out safely and the download control retries', async ({ page }) => {
  await login(page, 'book-timeout'); await tab(page, 'Books'); await page.locator('.media-card[data-id="book-1"]').click();
  await page.getByRole('button', { name: 'Download book', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Downloading…', exact: true })).toBeDisabled();
  await page.getByRole('button', { name: 'Favorite', pressed: false, exact: true }).click();
  await expect(page.getByRole('button', { name: 'Favorite', pressed: true, exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Downloading…', exact: true })).toBeDisabled();
  await expect(page.locator('#toast')).toContainText('stopped loading', { timeout: 22000 });
  await expect(page.getByRole('button', { name: 'Download book', exact: true })).toBeEnabled();
  const download = page.waitForEvent('download'); await page.getByRole('button', { name: 'Download book', exact: true }).click();
  expect((await download).suggestedFilename()).toContain('field guide');
});

test('narrow player has one native transport with working keyboard and chapter actions', async ({ page }) => {
  await page.setViewportSize({ width: 320, height: 568 }); await login(page, 'narrow-player');
  await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click();
  await expect.poll(() => time(page)).toBeGreaterThan(.3);
  await expect(page.locator('#tv-transport')).toBeHidden();
  expect(await page.locator('#video').evaluate(element => (element as HTMLVideoElement).controls)).toBe(true);
  await expect(page.getByRole('button', { name: 'Playback options', exact: true })).toBeVisible();
  await togglePlayback(page);
  await expect.poll(() => page.locator('#video').evaluate(element => (element as HTMLVideoElement).paused)).toBe(true);
  await chapter(page, '5'); await expect.poll(() => time(page)).toBeGreaterThanOrEqual(4.9);
  await skipNative(page, 'ArrowLeft'); await expect.poll(() => time(page)).toBeLessThan(1);
  // The default skip is 10 seconds on every client.
  await skipNative(page, 'ArrowRight'); await expect.poll(() => time(page)).toBeGreaterThan(9);
  expect(await page.locator('#player').evaluate(element => element.scrollWidth <= innerWidth)).toBe(true);
  await page.screenshot({ path: 'test-results/player-320.png' });
  await page.getByRole('button', { name: 'Close player', exact: true }).click(); await expect(page.locator('#player')).toBeHidden();
});

test('container fullscreen retains player controls, format dialog and keyboard focus before Back', async ({ page }) => {
  await login(page, 'fullscreen-keyboard'); await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click();
  await expect.poll(() => time(page)).toBeGreaterThan(.3);
  await togglePlayback(page);
  await page.getByRole('button', { name: 'Full screen', exact: true }).click();
  await expect.poll(() => page.evaluate(() => document.fullscreenElement?.id)).toBe('player');
  await page.getByRole('button', { name: 'Exit full screen', exact: true }).focus();
  await page.keyboard.press('Tab'); await expect(page.locator('#video')).toBeFocused();
  await page.keyboard.press('Tab'); await expect(page.getByRole('button', { name: 'Close player', exact: true })).toBeFocused();
  await page.keyboard.press('Shift+Tab'); await expect(page.locator('#video')).toBeFocused();
  await page.keyboard.press('Shift+Tab'); await expect(page.getByRole('button', { name: 'Exit full screen', exact: true })).toBeFocused();
  await page.getByRole('button', { name: 'Playback options', exact: true }).click(); await expect(page.locator('#player-format')).toBeVisible();
  for (const id of ['player-quality', 'player-audio', 'player-subtitles']) { await page.keyboard.press('Tab'); await expect(page.locator('#' + id)).toBeFocused(); }
  await page.keyboard.press('Tab'); await expect(page.getByLabel('Playback speed', { exact: true })).toBeFocused();
  await page.keyboard.press('Tab'); await expect(page.getByLabel('Chapter', { exact: true })).toBeFocused();
  await page.keyboard.press('Tab'); await expect(page.getByLabel('Auto-play next episode', { exact: true })).toBeFocused();
  await page.keyboard.press('Tab'); await expect(page.locator('.playback-details summary')).toBeFocused();
  await page.keyboard.press('Enter');
  await page.keyboard.press('Tab'); await expect(page.locator('#player-format-data')).toBeFocused();
  expect(await page.evaluate(() => document.fullscreenElement?.contains(document.activeElement))).toBe(true);
  await page.keyboard.press('Escape'); await expect(page.locator('#player-format')).toBeHidden();
  await expect.poll(() => page.evaluate(() => document.fullscreenElement?.id)).toBe('player');
  await page.keyboard.press('Escape'); await expect.poll(() => page.evaluate(() => document.fullscreenElement === null)).toBe(true);
  await expect(page.locator('#player')).toBeVisible();
  await page.keyboard.press('Escape'); await expect(page.locator('#player')).toBeHidden();
});


test('rejected preparation foreign stream URL releases ownership and Retry remains usable', async ({ page, request }) => {
  const h = await preparationFixture(page, 'foreign'); await login(page, 'cleanup-foreign', false, '/', fixture + '/jellyfin');
  await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Retry from saved position' })).toBeVisible();
  await expect.poll(() => h.allocations.size).toBe(0);
  expect(h.cleanups.filter(call => call.session === 'cleanup-first')).toHaveLength(1);
  expect(h.cleanups.filter(call => call.live === 'cleanup-live-first')).toHaveLength(1);
  expect(h.foreignRequests()).toBe(0);
  await page.getByRole('button', { name: 'Retry from saved position' }).click();
  await expect.poll(() => time(page)).toBeGreaterThan(.3);
  expect(h.allocations.size).toBe(1);
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await expect.poll(() => h.allocations.size).toBe(0);
  expect(h.cleanups.filter(call => call.session === 'cleanup-retry')).toHaveLength(1);
  expect(h.cleanups.filter(call => call.live === 'cleanup-live-retry')).toHaveLength(1);
  const state = await (await request.get(fixture + '/qa/state')).json();
  expect(state.calls.filter((call: { path: string }) => call.path.startsWith('/Sessions/Playing'))).toHaveLength(0);
});


test('rejected preparation out-of-base stream URL releases ownership and Retry remains usable', async ({ page, request }) => {
  const h = await preparationFixture(page, 'base'); await login(page, 'cleanup-base', false, '/', fixture + '/jellyfin');
  await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Retry from saved position' })).toBeVisible();
  await expect.poll(() => h.allocations.size).toBe(0);
  expect(h.cleanups.filter(call => call.session === 'cleanup-first')).toHaveLength(1);
  expect(h.cleanups.filter(call => call.live === 'cleanup-live-first')).toHaveLength(1);
  expect(h.foreignRequests()).toBe(0);
  await page.getByRole('button', { name: 'Retry from saved position' }).click();
  await expect.poll(() => time(page)).toBeGreaterThan(.3);
  expect(h.allocations.size).toBe(1);
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await expect.poll(() => h.allocations.size).toBe(0);
  expect(h.cleanups.filter(call => call.session === 'cleanup-retry')).toHaveLength(1);
  expect(h.cleanups.filter(call => call.live === 'cleanup-live-retry')).toHaveLength(1);
  const state = await (await request.get(fixture + '/qa/state')).json();
  expect(state.calls.filter((call: { path: string }) => call.path.startsWith('/Sessions/Playing'))).toHaveLength(0);
});


test('rejected preparation ErrorCode with source releases ownership and Retry remains usable', async ({ page, request }) => {
  const h = await preparationFixture(page, 'error'); await login(page, 'cleanup-error', false, '/', fixture + '/jellyfin');
  await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Retry from saved position' })).toBeVisible();
  await expect.poll(() => h.allocations.size).toBe(0);
  expect(h.cleanups.filter(call => call.session === 'cleanup-first')).toHaveLength(1);
  expect(h.cleanups.filter(call => call.live === 'cleanup-live-first')).toHaveLength(1);
  expect(h.foreignRequests()).toBe(0);
  await page.getByRole('button', { name: 'Retry from saved position' }).click();
  await expect.poll(() => time(page)).toBeGreaterThan(.3);
  expect(h.allocations.size).toBe(1);
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await expect.poll(() => h.allocations.size).toBe(0);
  expect(h.cleanups.filter(call => call.session === 'cleanup-retry')).toHaveLength(1);
  expect(h.cleanups.filter(call => call.live === 'cleanup-live-retry')).toHaveLength(1);
  const state = await (await request.get(fixture + '/qa/state')).json();
  expect(state.calls.filter((call: { path: string }) => call.path.startsWith('/Sessions/Playing'))).toHaveLength(0);
});


test('rejected preparation source without playable flags releases ownership and Retry remains usable', async ({ page, request }) => {
  const h = await preparationFixture(page, 'unusable'); await login(page, 'cleanup-unusable', false, '/', fixture + '/jellyfin');
  await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Retry from saved position' })).toBeVisible();
  await expect.poll(() => h.allocations.size).toBe(0);
  expect(h.cleanups.filter(call => call.session === 'cleanup-first')).toHaveLength(1);
  expect(h.cleanups.filter(call => call.live === 'cleanup-live-first')).toHaveLength(1);
  expect(h.foreignRequests()).toBe(0);
  await page.getByRole('button', { name: 'Retry from saved position' }).click();
  await expect.poll(() => time(page)).toBeGreaterThan(.3);
  expect(h.allocations.size).toBe(1);
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await expect.poll(() => h.allocations.size).toBe(0);
  expect(h.cleanups.filter(call => call.session === 'cleanup-retry')).toHaveLength(1);
  expect(h.cleanups.filter(call => call.live === 'cleanup-live-retry')).toHaveLength(1);
  const state = await (await request.get(fixture + '/qa/state')).json();
  expect(state.calls.filter((call: { path: string }) => call.path.startsWith('/Sessions/Playing'))).toHaveLength(0);
});


test('closing pending preparation releases late ownership without disturbing newer playback', async ({ page, request }) => {
  await page.addInitScript(() => {
    const fetchOriginal = window.fetch.bind(window);
    let gated = false;
    window.fetch = async (input, init) => {
      const url = input instanceof Request ? input.url : String(input);
      if (!gated && url.includes('/PlaybackInfo')) {
        gated = true;
        const response = await fetchOriginal(input, { ...init, signal: undefined });
        return new Promise<Response>(resolve => { (window as typeof window & { __releasePlayback: () => void }).__releasePlayback = () => resolve(response); });
      }
      return fetchOriginal(input, init);
    };
  });
  const h = await preparationFixture(page, 'late'); await login(page, 'cleanup-late');
  await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click();
  await expect.poll(() => page.evaluate(() => typeof (window as typeof window & { __releasePlayback?: () => void }).__releasePlayback)).toBe('function');
  await expect(page.locator('#player-state').getByRole('heading', { name: 'Setting the scene.' })).toBeVisible();
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click();
  await expect.poll(() => time(page)).toBeGreaterThan(.3);
  expect(h.allocations.size).toBe(2);
  await page.evaluate(() => (window as typeof window & { __releasePlayback: () => void }).__releasePlayback());
  await expect.poll(() => h.allocations.size).toBe(1);
  expect(h.cleanups.filter(call => call.session === 'cleanup-first')).toHaveLength(1);
  await expect(page.locator('#player')).toBeVisible();
  expect(await page.locator('#video').getAttribute('src')).toContain('cleanup-retry');
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await expect.poll(() => h.allocations.size).toBe(0);
  expect(h.cleanups.filter(call => call.session === 'cleanup-retry')).toHaveLength(1);
  const state = await (await request.get(fixture + '/qa/state')).json();
  expect(state.calls.filter((call: { path: string }) => call.path.startsWith('/Sessions/Playing'))).toHaveLength(0);
});

test('narrow Search keeps the whole field and input visible and usable', async ({ page }) => {
  await page.setViewportSize({ width: 320, height: 844 });
  await login(page, 'narrow-search');
  await tab(page, 'Search');
  const search = page.getByRole('searchbox');
  await search.fill('Out of the Blue');
  await expect(search).toBeFocused();
  await expect(page.locator('.media-card[data-id="series-7"]')).toBeVisible();
  for (const control of [page.locator('.search-field'), search]) {
    const bounds = await control.boundingBox();
    const contentBounds = await page.locator('#content').boundingBox();
    expect(bounds).not.toBeNull(); expect(contentBounds).not.toBeNull();
    expect(bounds!.x).toBeGreaterThanOrEqual(contentBounds!.x);
    expect(bounds!.width).toBeGreaterThan(100);
    expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(320);
    expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(contentBounds!.x + contentBounds!.width);
  }
  await page.screenshot({ path: 'test-results/narrow-search-320.png' });
  await page.locator('.media-card[data-id="series-7"]').click();
  await expect(page.locator('.detail-intro h1')).toHaveText('Out of the Blue');
});


test('narrow saved connections retain readable account text and contained actions', async ({ page }) => {
  await page.setViewportSize({ width: 320, height: 844 });
  await login(page, 'first', true);
  await tab(page, 'Servers');
  async function accountLayout(width: number) {
    await page.setViewportSize({ width, height: 900 });
    const rows = page.locator('.saved-connections article');
    await expect(rows.first()).toBeVisible();
    const bounds = await rows.evaluateAll(elements => elements.map(element => {
      const text = element.querySelector('div')!, address = element.querySelector('small')!;
      const rect = (node: Element) => { const value = node.getBoundingClientRect(); return { x: value.x, right: value.right, y: value.y, bottom: value.bottom, width: value.width, height: value.height }; };
      const style = getComputedStyle(address);
      return { row: rect(element), text: rect(text), address: rect(address), addressLine: parseFloat(style.lineHeight) || parseFloat(style.fontSize) * 1.5, controls: [...element.querySelectorAll('button')].map(rect) };
    }));
    await page.screenshot({ path: `test-results/saved-connections-${width}.png`, fullPage: true });
    for (const entry of bounds) {
      expect(entry.text.width).toBeGreaterThanOrEqual(80);
      expect(entry.address.height).toBeLessThanOrEqual(entry.addressLine * 4);
      expect(entry.row.x).toBeGreaterThanOrEqual(0);
      expect(entry.row.right).toBeLessThanOrEqual(width + 0.5);
      for (const control of entry.controls) {
        expect(control.width).toBeGreaterThan(0);
        expect(control.x).toBeGreaterThanOrEqual(entry.row.x - 0.5);
        expect(control.right).toBeLessThanOrEqual(entry.row.right + 0.5);
        if (width <= 720) expect(control.y).toBeGreaterThanOrEqual(entry.text.bottom - 0.5);
      }
    }
    const form = page.locator('#connect-form');
    const formBounds = await form.boundingBox(); expect(formBounds).not.toBeNull();
    expect(formBounds!.x + formBounds!.width).toBeLessThanOrEqual(width + 0.5);
    for (const control of await form.locator('input:not([type=checkbox]),button[type=submit]').all()) {
      const box = await control.boundingBox(); expect(box).not.toBeNull();
      expect(box!.x).toBeGreaterThanOrEqual(formBounds!.x);
      expect(box!.x + box!.width).toBeLessThanOrEqual(formBounds!.x + formBounds!.width + 0.5);
    }
  }
  await accountLayout(320);
  await page.getByLabel('Server address', { exact: true }).fill(fixture);
  await page.getByLabel('Username', { exact: true }).fill('second');
  await page.getByLabel('Password', { exact: true }).fill('demo');
  await page.getByLabel('Remember this connection on this device').check();
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.locator('.connection-button strong')).toHaveText('Sam');
  await tab(page, 'Servers');
  for (const width of [320, 390, 720, 1440]) await accountLayout(width);
  await page.setViewportSize({ width: 320, height: 844 });
  await page.locator('.saved-connections article').filter({ hasText: 'Alex' }).getByRole('button', { name: 'Open', exact: true }).click();
  await expect(page.locator('.connection-button strong')).toHaveText('Alex');
  await page.reload(); await expect(page.locator('.connection-button strong')).toHaveText('Alex');
  await tab(page, 'Servers');
  await page.locator('.saved-connections article').filter({ hasText: 'Sam' }).getByRole('button', { name: 'Sign out', exact: true }).click();
  await expect(page.locator('.saved-connections article')).toHaveCount(1);
  await accountLayout(320);
  await page.locator('.saved-connections article').getByRole('button', { name: 'Sign out', exact: true }).click();
  await expect(page.locator('.saved-connections article')).toHaveCount(0);
  await expect(page.getByLabel('Username', { exact: true })).toBeVisible();
});

test('full-viewport video stays the same size as overlays hide and wake across narrow and short layouts', async ({ page }) => {
  await login(page, 'theatre-overlays');
  let savedPosition = 0;
  for (const viewport of [{ width: 320, height: 568 }, { width: 844, height: 390 }, { width: 1440, height: 900 }]) {
    await page.setViewportSize(viewport);
    const play = page.locator('.hero [data-action="play"][data-id="movie-1"]');
    if (savedPosition > .3) await expect(play).toHaveAccessibleName('Resume');
    await play.click();
    await expect.poll(() => time(page)).toBeGreaterThan(Math.max(.3, savedPosition - .3));
    const frame = () => page.locator('#video').evaluate(element => { const r=element.getBoundingClientRect();return { x:r.x,y:r.y,width:r.width,height:r.height,fit:getComputedStyle(element).objectFit }; });
    expect(await page.locator('#video').evaluate(element=>(element as HTMLVideoElement).controls)).toBe(true);
    const visible=await frame();expect(visible).toEqual({x:0,y:0,width:viewport.width,height:viewport.height,fit:'contain'});
    await page.locator('#video').focus();
    await expect(page.locator('#player')).toHaveAttribute('data-controls','hidden',{timeout:7000});
    expect(await frame()).toEqual(visible);
    await page.mouse.move(viewport.width/2,viewport.height/2);
    await expect(page.locator('#player')).toHaveAttribute('data-controls','visible');
    await page.getByRole('button',{name:'Playback options',exact:true}).click();
    await expect(page.getByRole('button',{name:'Close playback options',exact:true})).toBeVisible();
    expect(await page.locator('#video').evaluate(element=>(element as HTMLVideoElement).controls)).toBe(false);
    expect(await frame()).toEqual(visible);
    await page.getByRole('button',{name:'Close playback options',exact:true}).click();
    expect(await page.locator('#video').evaluate(element=>(element as HTMLVideoElement).controls)).toBe(true);
    savedPosition = await time(page);
    await page.getByRole('button',{name:'Close player',exact:true}).click();
    await expect(page.locator('.hero h1')).toBeVisible();
  }
});

test('persisted page lifecycle closes playback and restores the library without replaying on pageshow', async ({ page }) => {
  await login(page, 'cached-player-return');
  const reports: string[]=[];page.on('request',request=>{if(request.url().includes('/Sessions/Playing'))reports.push(request.url());});
  await page.locator('.hero').getByRole('button',{name:'Play',exact:true}).click();
  await expect.poll(()=>time(page)).toBeGreaterThan(.3);
  await page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pagehide',{persisted:true})));
  await expect(page.locator('#player')).toBeHidden();
  await expect.poll(()=>page.locator('#video').evaluate(element=>(element as HTMLVideoElement).paused)).toBe(true);
  await page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true})));
  await expect(page.locator('.hero h1')).toBeVisible();await expect(page.locator('#player')).toBeHidden();
  expect(await page.locator('#content').getAttribute('aria-hidden')).toBeNull();
  expect(await page.locator('#content').getAttribute('inert')).toBeNull();
  expect(await page.locator('#video').getAttribute('src')).toBeNull();expect(reports).toEqual([]);
  await expect(page.locator('.hero [data-action="play"][data-id="movie-1"]')).toBeFocused();
  await expect(page.locator('.hero [data-action="play"][data-id="movie-1"]')).toHaveAccessibleName('Resume');
});

for (const terminal of ['ended','error'] as const) test(`Format yields to ${terminal} before its terminal action receives focus`, async ({ page, request }) => {
  await login(page, 'format-terminal-' + terminal);
  await page.locator('.hero').getByRole('button',{name:'Play',exact:true}).click();await expect.poll(()=>time(page)).toBeGreaterThan(.3);
  await page.getByRole('button',{name:'Playback options',exact:true}).click();await expect(page.locator('#player-format')).toBeVisible();
  await expect(page.locator('.screen')).toHaveAttribute('inert','');
  expect(await page.locator('#video').evaluate(element=>(element as HTMLVideoElement).controls)).toBe(false);
  if (terminal === 'ended') {
    await page.locator('#video').evaluate(element=>{const video=element as HTMLVideoElement;video.currentTime=video.duration-.15;});
    await expect(page.locator('#player-state').getByRole('button',{name:'Play again',exact:true})).toBeFocused();
  } else {
    const negotiation = (url: URL) => url.origin === fixture && url.pathname === '/Items/movie-1/PlaybackInfo';
    const badMedia = (url: URL) => url.origin === fixture && url.pathname === '/Videos/movie-1/stream' && url.searchParams.get('qaTerminal') === 'invalid-media';
    let failedNegotiations = 0;
    await page.route(negotiation, pending => { expect(pending.request().method()).toBe('POST'); failedNegotiations++; return pending.fulfill({status:503,json:{}}); });
    await page.route(badMedia, pending => pending.fulfill({status:200,contentType:'video/mp4',body:'Reel deliberately invalid media bytes'}));
    const failedFallback = page.waitForResponse(response => negotiation(new URL(response.url())) && response.status() === 503);
    // Reload an owned invalid media resource to obtain a real native MediaError, not a dispatched error event.
    const nativeError = await page.locator('#video').evaluate((element, url) => new Promise<{ trusted: boolean; code: number | undefined }>(resolve => {
      const video = element as HTMLVideoElement;
      video.addEventListener('error', event => resolve({trusted:event.isTrusted,code:video.error?.code}), {once:true,capture:true});
      video.src = url; video.load();
    }), fixture + '/Videos/movie-1/stream?qaTerminal=invalid-media');
    expect(nativeError.trusted).toBe(true);expect(nativeError.code).toBeGreaterThanOrEqual(3);
    await (await failedFallback).finished();expect(failedNegotiations).toBe(1);
    await expect(page.getByRole('button',{name:'Retry from saved position',exact:true})).toBeFocused();
    await expect(page.locator('#player-format')).toBeHidden();
    expect(await page.locator('.screen').getAttribute('inert')).toBeNull();
    expect(await page.locator('#video').evaluate(element=>(element as HTMLVideoElement).controls)).toBe(true);
    await page.unroute(negotiation);await page.unroute(badMedia);
    const recovered = page.waitForResponse(response => negotiation(new URL(response.url())) && response.status() === 200);
    await page.getByRole('button',{name:'Retry from saved position',exact:true}).click();await (await recovered).finished();
    await expect.poll(()=>time(page)).toBeGreaterThan(.3);
    await expect(page.getByRole('button',{name:'Retry from saved position',exact:true})).toHaveCount(0);
    expect(failedNegotiations).toBe(1);
  }
  await expect(page.locator('#player-format')).toBeHidden();expect(await page.locator('.screen').getAttribute('inert')).toBeNull();
  expect(await page.locator('#video').evaluate(element=>(element as HTMLVideoElement).controls)).toBe(true);
  await page.getByRole('button',{name:'Close player',exact:true}).click();await expect(page.locator('#player')).toBeHidden();
  const state=await(await request.get(fixture+'/qa/state')).json();
  expect(state.reports.filter((report:{path:string})=>report.path.startsWith('/Sessions/Playing'))).toHaveLength(0);
});

test('cached Details restores its initiating Play focus and selected subtitles without autoplay', async ({ page }) => {
  await login(page,'cached-detail-focus');await page.locator('.hero').getByRole('button',{name:'Details',exact:true}).click();
  await page.locator('#track-menu > summary').click();await page.locator('#subtitle-track').selectOption('-1');await page.getByRole('button',{name:'Play',exact:true}).click();await expect.poll(()=>time(page)).toBeGreaterThan(.3);
  await page.evaluate(()=>{window.dispatchEvent(new PageTransitionEvent('pagehide',{persisted:true}));window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true}));});
  await expect(page.locator('.detail-intro h1')).toHaveText('The Quiet Earth');await expect(page.locator('#player')).toBeHidden();
  await expect(page.locator('.detail-intro [data-action="play"][data-id="movie-1"]')).toBeFocused();
  await expect(page.locator('.detail-intro [data-action="play"][data-id="movie-1"]')).toHaveAccessibleName('Resume');
  await expect(page.locator('#subtitle-track')).toHaveValue('-1');
  expect(await page.locator('#video').getAttribute('src')).toBeNull();expect(await page.locator('#video').evaluate(element=>(element as HTMLVideoElement).paused)).toBe(true);
});

test('fullscreen Next metadata failure shows status inside the player and the same Next action recovers', async ({ page }) => {
  await login(page,'fullscreen-next-status');await playFirstEpisode(page);await expect.poll(()=>time(page)).toBeGreaterThan(.3);
  await page.getByRole('button',{name:'Full screen',exact:true}).click();await expect.poll(()=>page.evaluate(()=>document.fullscreenElement?.id)).toBe('player');
  await page.route('**/Items/episode-1-2?*',pending=>pending.fulfill({status:503,json:{}}));
  await page.locator('#video').evaluate(element=>{const video=element as HTMLVideoElement;video.currentTime=video.duration-.15;});
  const next=page.locator('#player-state').getByRole('button',{name:'Below the surface',exact:true});await expect(next).toBeVisible();await next.click();
  await expect(page.locator('#player #toast')).toBeVisible();await expect(page.locator('#player #toast')).toContainText('503');
  expect(await page.locator('#toast').evaluate(element=>document.fullscreenElement?.contains(element))).toBe(true);
  await page.unroute('**/Items/episode-1-2?*');await next.click();await expect(page.locator('#player-subtitle')).toContainText('Below the surface');await expect.poll(()=>time(page)).toBeGreaterThan(.2);
  await page.mouse.move(30,30);await page.getByRole('button',{name:'Close player',exact:true}).click();await expect(page.locator('#player')).toBeHidden();
  expect(await page.locator('#player #toast').count()).toBe(0);
});


test('cached Details resumes a cancelled pending season without stale rows or a permanent spinner', async ({ page }) => {
  await login(page,'cached-season-focus');await tab(page,'Library');await page.locator('.media-card[data-id="series-7"]').click();
  await expect(page.locator('.episode-row[data-id="episode-1-1"]')).toBeVisible();
  let release!:()=>void;const held=new Promise<void>(resolve=>{release=resolve;});
  await page.route('**/Shows/series-7/Episodes?*',async pending=>{await held;await pending.continue().catch(()=>undefined);});
  await page.locator('#season').selectOption('season-2');await expect(page.locator('#season')).toBeDisabled();
  await page.evaluate(()=>{window.dispatchEvent(new PageTransitionEvent('pagehide',{persisted:true}));window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true}));});
  release();await expect(page.locator('#season')).toHaveValue('season-2');await expect(page.locator('#season')).toBeEnabled();
  await expect(page.getByText('Opening this season.',{exact:true})).toHaveCount(0);await expect(page.locator('.episode-row[data-id="episode-1-1"]')).toHaveCount(0);
  await expect(page.locator('.episode-row[data-id="episode-2-1"]')).toBeVisible();
  await expect(page.locator('#player')).toBeHidden();
});

test('late Next metadata failure after Close cannot publish into the restored library', async ({ page }) => {
  await login(page,'late-next-status');await playFirstEpisode(page);await expect.poll(()=>time(page)).toBeGreaterThan(.3);
  let release!:()=>void;const held=new Promise<void>(resolve=>{release=resolve;});
  await page.route('**/Items/episode-1-2?*',async pending=>{await held;await pending.fulfill({status:503,json:{}});});
  await page.locator('#video').evaluate(element=>{const video=element as HTMLVideoElement;video.currentTime=video.duration-.15;});
  const requested=page.waitForRequest(request=>new URL(request.url()).pathname==='/Items/episode-1-2');
  await page.locator('#player-state').getByRole('button',{name:'Below the surface',exact:true}).click();await requested;
  await page.getByRole('button',{name:'Close player',exact:true}).click();await expect(page.locator('#player')).toBeHidden();
  const completed=page.waitForResponse(response=>new URL(response.url()).pathname==='/Items/episode-1-2'&&response.status()===503);
  release();await (await completed).finished();
  for(let check=0;check<6;check++){await page.waitForTimeout(100);await expect(page.locator('#toast')).toBeHidden();await expect(page.locator('.detail-intro h1')).toHaveText('Out of the Blue');}
});

async function installActualTizenAdapter(page: Page): Promise<void> {
  const policy = readFileSync(new URL('../../../tizen/src/policy.mjs', import.meta.url), 'utf8').replace(/^export /gm, '');
  const adapter = readFileSync(new URL('../../../tizen/src/adapter.mjs', import.meta.url), 'utf8').replace(/^import .*from '\.\/policy\.mjs';\n/m, '').replace(/^export /gm, '');
  await page.addScriptTag({ content: `(function(){'use strict';\n${policy}\n${adapter}\ninstallTizenAdapter(window,document);\n})();` });
}
for (const transition of ['hidden','offline','stop'] as const) test(`Tizen adapter ${transition} closes Format then player without allowing ordinary inert activation`, async ({ page, context }) => {
  await login(page, 'tizen-format-stop-' + transition);await installActualTizenAdapter(page);
  await page.locator('.hero [data-action="play"][data-id="movie-1"]').click();await expect.poll(()=>time(page)).toBeGreaterThan(.3);
  await page.getByRole('button',{name:'Full screen',exact:true}).click();await expect.poll(()=>page.evaluate(()=>document.fullscreenElement?.id)).toBe('player');
  await page.getByRole('button',{name:'Playback options',exact:true}).click();await expect(page.locator('#player-format')).toBeVisible();
  // Exercise the activation guard rather than force a user tap through an inert overlay.
  await page.locator('#player [data-action="close-player"]').evaluate(element=>(element as HTMLButtonElement).click());
  await expect(page.locator('#player')).toBeVisible();await expect(page.locator('#player-format')).toBeVisible();
  try {
    if(transition==='offline')await context.setOffline(true);
    else if(transition==='hidden')await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'));});
    else await page.evaluate(()=>document.dispatchEvent(new KeyboardEvent('keydown',{key:'MediaStop',keyCode:413,bubbles:true,cancelable:true})));
    await expect(page.locator('#player-format')).toBeHidden();await expect(page.locator('#player')).toBeHidden();
    await expect.poll(()=>page.evaluate(()=>document.fullscreenElement===null)).toBe(true);
    expect(await page.locator('#video').evaluate(element=>(element as HTMLVideoElement).paused)).toBe(true);
    expect(await page.locator('#content').getAttribute('inert')).toBeNull();expect(await page.locator('#content').getAttribute('aria-hidden')).toBeNull();
  } finally {
    if(transition==='offline')await context.setOffline(false);
    else if(transition==='hidden')await page.evaluate(()=>{delete (document as unknown as {hidden?:boolean}).hidden;document.dispatchEvent(new Event('visibilitychange'));});
  }
});
