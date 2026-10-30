import { test, expect, type Page } from '@playwright/test';

const fixture = 'http://127.0.0.1:18771';
async function connect(page: Page, name: string, tv = false, remember = false): Promise<void> {
  if (tv) await page.route('**/reel-config.js', route => route.fulfill({ contentType: 'text/javascript', body: 'window.REEL_CONFIG={platform:"webos",previewMode:true};' }));
  await page.goto('/');
  for (const [field, label, value] of [['server', 'Server address', fixture], ['username', 'Username', 'player-experience-' + name], ['password', 'Password', 'demo']]) {
    if (tv) {
      await page.locator(`[data-tv-field="${field}"]`).click();
      await page.locator('#tv-entry-input').fill(value); await page.keyboard.press('Enter');
    } else await page.getByLabel(label, { exact: true }).fill(value);
  }
  if (remember) await page.getByLabel('Remember this connection on this device').check();
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.locator('.hero h1')).toBeVisible();
}
async function start(page: Page): Promise<void> {
  // The hero offers Resume once watch history has saved a position for the title.
  await page.locator('.hero').getByRole('button', { name: /^(Play|Resume)$/ }).click();
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeGreaterThan(.3);
}
// After Resume, the position passes the start check as soon as the saved position is applied, and the
// player ignores Play and Pause until that resume has been confirmed. Press again until the video pauses,
// never while it is already paused, so a late first press cannot start it again.
async function pause(page: Page): Promise<void> {
  const paused = () => page.locator('#video').evaluate(el => (el as HTMLVideoElement).paused);
  await expect(async () => {
    if (!await paused()) { await page.locator('#video').focus(); await page.keyboard.press('Space'); }
    expect(await paused()).toBe(true);
  }).toPass({ intervals: [250, 500, 1000], timeout: 10000 });
}
// Segment requests are matched by path, whatever their query string.
const movieSegments = (url: URL) => url.pathname.endsWith('/MediaSegments/movie-1');
const episodeSegments = (url: URL) => url.pathname.endsWith('/MediaSegments/episode-1-1');
const options = (page: Page) => page.getByRole('button', { name: 'Playback options', exact: true });
const closeOptions = (page: Page) => page.getByRole('button', { name: 'Close playback options', exact: true });

test('native player has one transport and options keep speed, chapters and stream information usable', async ({ page }, info) => {
  await connect(page, 'native'); await start(page); await pause(page);
  await expect(page.locator('#tv-transport')).toBeHidden();
  expect(await page.locator('#video').evaluate(el => (el as HTMLVideoElement).controls)).toBe(true);
  await options(page).click();
  await expect(closeOptions(page)).toBeFocused();
  await page.locator('#player-quality').focus();
  await page.locator('#video').dispatchEvent('waiting');
  await expect(page.locator('#player-quality')).toBeFocused();
  await expect(page.locator('.screen')).toHaveAttribute('inert', '');
  expect(await page.locator('#video').evaluate(el => (el as HTMLVideoElement).controls)).toBe(false);
  await page.getByLabel('Playback speed', { exact: true }).selectOption('1.5');
  expect(await page.locator('#video').evaluate(el => (el as HTMLVideoElement).playbackRate)).toBe(1.5);
  await page.getByLabel('Chapter', { exact: true }).selectOption('5');
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeCloseTo(5, 0);
  await expect(page.locator('#player-format-data')).toBeHidden();
  await page.locator('.playback-details summary').click();
  await expect(page.locator('#player-format-data')).toBeVisible();
  await expect(page.locator('#player-format-data')).toContainText('H.264');
  const facts = page.locator('#player-format-data .format-facts');
  await expect(facts.locator('.format-label')).toHaveText(['Video', 'Audio']);
  await expect(facts.nth(0).locator('.format-chip').first()).toHaveText('H.264');
  await expect(facts.nth(1).locator('.format-chip').first()).toHaveText('AAC');
  for (const line of await page.locator('#player-format-data p').allTextContents()) expect(line.split('·').length - 1).toBeLessThanOrEqual(1);
  await page.screenshot({ path: info.outputPath('playback-options-desktop.png') });
  await expect(page.locator('.player-header')).toBeHidden();
  await page.keyboard.press('Escape');
  expect(await options(page).evaluate(node => document.activeElement === node && getComputedStyle(node).visibility === 'visible')).toBe(true);
  await expect(options(page)).toBeFocused();
  expect(await page.locator('#video').evaluate(el => (el as HTMLVideoElement).controls)).toBe(true);
  await page.screenshot({ path: info.outputPath('player-desktop.png') });
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await expect(page.locator('.hero [data-action="play"]')).toHaveAccessibleName('Resume');
});

test('TV uses one remote transport with clock, range seeking, skips and real play pause', async ({ page }, info) => {
  await page.setViewportSize({ width: 1920, height: 1080 });
  await connect(page, 'tv', true); await start(page);
  await expect(page.locator('[data-action="fullscreen"]')).toBeHidden();
  await expect(page.locator('#tv-transport')).toBeVisible();
  expect(await page.locator('#video').evaluate(el => (el as HTMLVideoElement).controls)).toBe(false);
  await page.getByRole('button', { name: 'Play / pause', exact: true }).click();
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).paused)).toBe(true);
  const duration = await page.locator('#video').evaluate(el => (el as HTMLVideoElement).duration);
  const seek = page.getByRole('slider', { name: 'Playback position', exact: true });
  // On a remote the timeline moves 10 seconds a press, as far as the skip buttons.
  await seek.focus(); await page.keyboard.press('ArrowRight');
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeGreaterThanOrEqual(10);
  await expect(seek).toHaveAttribute('aria-valuetext', /of 0:14/);
  await expect(page.locator('#player-duration')).toHaveText('0:14');
  // Through the 14 second clip: from past 10 s, one skip forward stops at the end, the timeline steps back to
  // near 4 s, and one skip back stops at the start.
  const forward = page.getByRole('button', { name: 'Forward 10 seconds', exact: true }), back = page.getByRole('button', { name: 'Back 10 seconds', exact: true });
  await forward.click();
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeGreaterThan(duration - 1);
  await seek.focus(); await page.keyboard.press('ArrowLeft');
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeLessThan(duration - 9);
  await back.click();
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeLessThan(1);
  await options(page).click(); await page.getByLabel('Chapter', { exact: true }).selectOption('5');
  await closeOptions(page).click();
  expect(await page.locator('#video').evaluate(el => (el as HTMLVideoElement).controls)).toBe(false);
  await page.getByRole('button', { name: 'Play / pause', exact: true }).click();
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeGreaterThan(5.1);
  await page.getByRole('button', { name: 'Play / pause', exact: true }).click();
  await page.screenshot({ path: info.outputPath('player-tv.png') });
});

for (const viewport of [{ width: 320, height: 568 }, { width: 844, height: 390 }, { width: 1440, height: 900 }]) {
  test(`picture, options and focus remain usable at ${viewport.width}x${viewport.height}`, async ({ page }, info) => {
    await page.setViewportSize(viewport); await connect(page, 'size-' + viewport.width); await start(page);
    await page.setViewportSize({ ...viewport, width: viewport.width - 1 }); await page.setViewportSize(viewport);
    await expect(page.locator('#content')).toHaveAttribute('inert', ''); await expect(page.locator('#rail')).toHaveAttribute('inert', '');
    const picture = () => page.locator('#video').evaluate(el => { const r = el.getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height }; });
    expect(await picture()).toEqual({ x: 0, y: 0, ...viewport });
    await page.locator('#video').focus();
    await expect(page.locator('#player')).toHaveAttribute('data-controls', 'hidden', { timeout: 7000 });
    expect(await picture()).toEqual({ x: 0, y: 0, ...viewport });
    await page.mouse.move(viewport.width / 2, viewport.height / 2); await pause(page);
    await options(page).click();
    await expect(page.locator('.player-header')).toBeHidden(); await expect(page.locator('.player-companion')).toBeHidden();
    await page.screenshot({ path: info.outputPath(`options-initial-${viewport.width}.png`) });
    await page.setViewportSize({ ...viewport, width: viewport.width - 1 }); await page.setViewportSize(viewport);
    await expect(page.locator('#content')).toHaveAttribute('inert', ''); await expect(page.locator('#rail')).toHaveAttribute('inert', '');
    for (const id of ['player-quality', 'player-audio', 'player-subtitles']) { await page.keyboard.press('Tab'); await expect(page.locator('#' + id)).toBeFocused(); }
    await page.keyboard.press('Tab'); await expect(page.getByLabel('Playback speed', { exact: true })).toBeFocused();
    await page.keyboard.press('Tab'); await expect(page.getByLabel('Chapter', { exact: true })).toBeFocused();
    await page.keyboard.press('Tab'); await expect(page.getByLabel('Auto-play next episode', { exact: true })).toBeFocused();
    await page.keyboard.press('Tab'); await expect(page.locator('.playback-details summary')).toBeFocused();
    await page.keyboard.press('Enter');
    await page.keyboard.press('Tab'); await expect(page.locator('#player-format-data')).toBeFocused();
    await page.keyboard.press('Tab'); await expect(closeOptions(page)).toBeFocused();
    const dialog = await page.locator('#player-format').boundingBox();
    expect(dialog!.x).toBeGreaterThanOrEqual(0); expect(dialog!.y).toBeGreaterThanOrEqual(0);
    expect(dialog!.x + dialog!.width).toBeLessThanOrEqual(viewport.width + 1);
    expect(dialog!.y + dialog!.height).toBeLessThanOrEqual(viewport.height + 1);
    expect(await picture()).toEqual({ x: 0, y: 0, ...viewport });
    await page.screenshot({ path: info.outputPath(`options-${viewport.width}.png`) });
    await closeOptions(page).click();
    await page.screenshot({ path: info.outputPath(`player-${viewport.width}.png`) });
    await page.getByRole('button', { name: 'Close player', exact: true }).click();
    await expect(page.locator('#player')).toBeHidden();
  });
}

test('no-chapter media hides the empty chapter field and native controls recover after options', async ({ page }) => {
  await page.route('**/Items/movie-1?*', async route => { const response = await route.fetch(); const data = await response.json(); data.Chapters = []; await route.fulfill({ response, json: data }); });
  await connect(page, 'no-chapters'); await start(page); await options(page).click();
  await expect(page.locator('#chapters-label')).toBeHidden();
  await page.getByLabel('Playback speed', { exact: true }).selectOption('0.75');
  await closeOptions(page).click();
  expect(await page.locator('#video').evaluate(el => ({ controls: (el as HTMLVideoElement).controls, rate: (el as HTMLVideoElement).playbackRate }))).toEqual({ controls: true, rate: .75 });
});


async function startEpisode(page: Page): Promise<void> {
  // TV Home has no featured choices; the series opens from its row there.
  if (await page.evaluate(() => document.documentElement.dataset.layout === 'tv')) {
    await page.locator('.shelf').filter({ hasText: 'Recently added series' }).locator('.media-card').filter({ hasText: 'Out of the Blue' }).first().click();
  } else {
    await page.getByRole('button', { name: 'Feature Out of the Blue', exact: true }).click();
    await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  }
  await page.locator('.episode-row[data-id="episode-1-1"] .episode-play').click();
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeGreaterThan(.3);
  await expect(page.getByRole('button', { name: 'Next episode', exact: true })).toBeEnabled();
}
async function finishEpisode(page: Page): Promise<void> {
  await page.locator('#video').focus(); await page.keyboard.press('ArrowRight');
  await expect(page.locator('#player')).toHaveAttribute('data-state', 'ended');
}

test('episode controls and season picker navigate actual episodes, including a season boundary', async ({ page }, info) => {
  await connect(page, 'episode-picker'); await startEpisode(page); await pause(page);
  await expect(page.getByRole('button', { name: 'Previous episode', exact: true })).toBeDisabled();
  await page.getByRole('button', { name: 'Episodes', exact: true }).click();
  await expect(page.getByRole('tab', { name: 'Episodes', exact: true })).toHaveAttribute('aria-selected', 'true');
  await expect(page.locator('#player-panel-heading')).toHaveText('Episodes');
  await expect(page.locator('#player-panel-context')).toHaveText('Out of the Blue');
  await expect(page.locator('.player-episode-choice').first().locator('small')).toHaveText('S1 · E1 · 14s · Now playing');
  await expect(page.locator('.player-episode-choice[aria-current="true"]')).toContainText('A new beginning');
  await page.getByLabel('Player season', { exact: true }).selectOption('season-2');
  await expect(page.locator('.player-episode-choice').first()).toHaveAttribute('data-id', 'episode-2-1');
  await expect.poll(() => page.locator('.player-episode-choice img').evaluateAll(nodes => nodes.filter(node => { const bounds = node.getBoundingClientRect(), panel = node.closest('#player-episodes-content')!.getBoundingClientRect(); return bounds.bottom > panel.top && bounds.top < panel.bottom; }).every(node => (node as HTMLImageElement).complete && (node as HTMLImageElement).naturalWidth > 0 && getComputedStyle(node).opacity === '1'))).toBe(true);
  await page.screenshot({ path: info.outputPath('episode-picker.png') });
  await page.locator('.player-episode-choice[data-id="episode-2-1"]').click();
  await expect(page.locator('#player-subtitle')).toContainText('S2');
  await expect(page.getByRole('button', { name: 'Previous episode', exact: true })).toBeEnabled();
  await page.getByRole('button', { name: 'Previous episode', exact: true }).click();
  await expect(page.locator('#player-subtitle')).toContainText('S1 E3');
  await page.getByRole('button', { name: 'Next episode', exact: true }).click();
  await expect(page.locator('#player-subtitle')).toContainText('S2 E1');
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeGreaterThan(.3);
  await page.getByRole('button', { name: 'Episodes', exact: true }).click();
  await page.locator('.player-episode-choice[aria-current="true"]').click();
  await expect(page.locator('#player-format')).toBeHidden();
  await expect(page.getByRole('button', { name: 'Episodes', exact: true })).toBeFocused();
  for (const viewport of [{ width: 844, height: 390 }, { width: 320, height: 568 }]) {
    await page.setViewportSize(viewport);
    for (const name of ['Previous episode', 'Episodes', 'Next episode']) {
      const control = page.getByRole('button', { name, exact: true }); await expect(control).toBeVisible();
      const bounds = (await control.boundingBox())!;
      expect(bounds.width).toBeGreaterThanOrEqual(44); expect(bounds.height).toBeGreaterThanOrEqual(44);
      expect(bounds.y).toBeGreaterThanOrEqual(0); expect(bounds.y + bounds.height).toBeLessThanOrEqual(viewport.height - 40);
    }
    await page.getByRole('button', { name: 'Next episode', exact: true }).click();
    await expect(page.locator('#player-subtitle')).toContainText('S2 E2');
    await expect(page.getByRole('button', { name: 'Previous episode', exact: true })).toBeEnabled();
    await page.getByRole('button', { name: 'Previous episode', exact: true }).click();
    await expect(page.locator('#player-subtitle')).toContainText('S2 E1');
    await expect(page.getByRole('button', { name: 'Next episode', exact: true })).toBeEnabled();
    await pause(page); await page.getByRole('button', { name: 'Episodes', exact: true }).click();
    await expect(page.getByLabel('Player season', { exact: true })).toBeVisible();
    const dialog = (await page.locator('#player-format').boundingBox())!;
    expect(dialog.y).toBeGreaterThanOrEqual(0); expect(dialog.y + dialog.height).toBeLessThanOrEqual(viewport.height);
    await expect(page.locator('.player-header')).toBeHidden(); await expect(page.locator('.player-companion')).toBeHidden();
    await expect.poll(() => page.locator('.player-episode-choice img').evaluateAll(nodes => nodes.filter(node => { const bounds = node.getBoundingClientRect(), panel = node.closest('#player-episodes-content')!.getBoundingClientRect(); return bounds.bottom > panel.top && bounds.top < panel.bottom; }).every(node => (node as HTMLImageElement).complete && (node as HTMLImageElement).naturalWidth > 0 && getComputedStyle(node).opacity === '1'))).toBe(true);
    await page.screenshot({ path: info.outputPath(`episode-picker-${viewport.width}.png`) });
    await closeOptions(page).click();
  }
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await expect(page.locator('.episode-row[data-id="episode-1-1"] .episode-play')).toBeFocused();
});

test('episode picker exposes recoverable load failure and empty seasons without breaking the playing item', async ({ page }) => {
  await connect(page, 'episode-errors');
  await page.getByRole('button', { name: 'Feature Out of the Blue', exact: true }).click();
  await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  await expect(page.locator('.episode-row[data-id="episode-1-1"] .episode-play')).toBeVisible();
  await page.route('**/Shows/series-7/Seasons?*', route => route.fulfill({ status: 503, json: {} }));
  await page.locator('.episode-row[data-id="episode-1-1"] .episode-play').click();
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeGreaterThan(.3);
  await pause(page); await page.getByRole('button', { name: 'Episodes', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Retry episodes', exact: true })).toBeVisible();
  await page.unroute('**/Shows/series-7/Seasons?*');
  await page.getByRole('button', { name: 'Retry episodes', exact: true }).click();
  await expect(page.getByLabel('Player season', { exact: true })).toBeVisible();
  await page.route('**/Shows/series-7/Episodes?*', async route => {
    if (new URL(route.request().url()).searchParams.get('seasonId') === 'season-2') await route.fulfill({ status: 403, json: {} });
    else await route.continue();
  });
  await page.getByLabel('Player season', { exact: true }).selectOption('season-2');
  await expect(page.locator('#player-episode-list')).toContainText('does not have permission');
  await page.unroute('**/Shows/series-7/Episodes?*');
  await page.getByRole('button', { name: 'Retry episodes', exact: true }).click();
  await expect(page.locator('.player-episode-choice').first()).toHaveAttribute('data-id', 'episode-2-1');
  await page.route('**/Shows/series-7/Episodes?*', async route => {
    if (new URL(route.request().url()).searchParams.get('seasonId') === 'season-1') await route.fulfill({ json: { Items: [], TotalRecordCount: 0 } });
    else await route.continue();
  });
  await page.getByLabel('Player season', { exact: true }).selectOption('season-1');
  await expect(page.locator('#player-episode-list')).toHaveText('No episodes are available in this season.');
  await closeOptions(page).click();
  await expect(page.locator('#player-title')).toHaveText('Out of the Blue');
  expect(await page.locator('#video').evaluate(el => (el as HTMLVideoElement).paused)).toBe(true);
});

test('Skip intro is offered only within a real validated intro and seeks to its end', async ({ page }) => {
  await page.route(movieSegments, route => route.fulfill({ json: { Items: [{ Type: 'Intro', ItemId: 'movie-1', StartTicks: 10_000_000, EndTicks: 50_000_000 }] } }));
  await connect(page, 'skip-intro'); await start(page);
  await expect(page.getByRole('button', { name: 'Skip intro', exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Skip intro', exact: true }).click();
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeGreaterThanOrEqual(5);
  await expect(page.getByRole('button', { name: 'Skip intro', exact: true })).toBeHidden();
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await page.unroute(movieSegments);
  await page.route(movieSegments, route => route.fulfill({ json: { Items: [] } }));
  await page.locator('.hero [data-action="play"]').click();
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeGreaterThan(5);
  await expect(page.getByRole('button', { name: 'Skip intro', exact: true })).toBeHidden();
});

for (const viewport of [{ width: 1920, height: 1080 }, { width: 1280, height: 720 }]) {
  test(`TV Skip intro receives pointer input above the episode transport at ${viewport.width}x${viewport.height}`, async ({ page }, info) => {
    await page.setViewportSize(viewport);
    await page.route(episodeSegments, route => route.fulfill({ json: { Items: [{ Type: 'Intro', ItemId: 'episode-1-1', StartTicks: 0, EndTicks: 50_000_000 }] } }));
    await connect(page, 'tv-intro-' + viewport.width, true); await startEpisode(page); await pause(page);
    const skip = page.getByRole('button', { name: 'Skip intro', exact: true });
    await expect(skip).toBeVisible();
    await page.screenshot({ path: info.outputPath('tv-intro-with-episode-transport.png') });
    expect(await skip.evaluate(node => {
      const box = node.getBoundingClientRect();
      return node.contains(document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2));
    })).toBe(true);
    await skip.click();
    await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeGreaterThanOrEqual(5);
    await expect(skip).toBeHidden();
    expect(await page.locator('#video').evaluate(el => (el as HTMLVideoElement).paused)).toBe(true);
    await page.getByRole('button', { name: 'Next episode', exact: true }).click();
    await expect(page.locator('#player-subtitle')).toContainText('S1 E2');
    await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeGreaterThan(.3);
  });
}

test('automatic next episode has a cancellable countdown and then starts the correct fresh episode', async ({ page }, info) => {
  await connect(page, 'auto-next'); await startEpisode(page); await finishEpisode(page);
  await expect(page.locator('#autoplay-countdown')).toContainText('Next episode in');
  await page.screenshot({ path: info.outputPath('auto-next-countdown.png') });
  await page.getByRole('button', { name: 'Cancel auto-play', exact: true }).click();
  await expect(page.locator('#autoplay-countdown')).toHaveText('Auto-play cancelled');
  await page.waitForTimeout(8500);
  await expect(page.locator('#player-subtitle')).toContainText('S1 E1');
  await page.getByRole('button', { name: 'Play again', exact: true }).click();
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeGreaterThan(.3);
  await expect(page.getByRole('button', { name: 'Next episode', exact: true })).toBeEnabled();
  await finishEpisode(page);
  await expect(page.locator('#player-subtitle')).toContainText('S1 E2', { timeout: 12000 });
  await expect.poll(() => page.locator('#video').evaluate(el => ({ paused: (el as HTMLVideoElement).paused, time: (el as HTMLVideoElement).currentTime }))).toMatchObject({ paused: false });
  expect(await page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeLessThan(5);
});

test('auto-play preference persists and closing a countdown cannot start another episode', async ({ page }) => {
  await connect(page, 'auto-persistence', false, true); await startEpisode(page); await options(page).click();
  await page.getByLabel('Auto-play next episode', { exact: true }).uncheck(); await closeOptions(page).click();
  await page.reload(); await expect(page.locator('.hero h1')).toBeVisible(); await startEpisode(page);
  await options(page).click(); await expect(page.getByLabel('Auto-play next episode', { exact: true })).not.toBeChecked();
  await closeOptions(page).click(); await finishEpisode(page); await expect(page.locator('#autoplay-countdown')).toBeHidden();
  await page.getByRole('button', { name: 'Play again', exact: true }).click();
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeGreaterThan(.3);
  await options(page).click(); await page.getByLabel('Auto-play next episode', { exact: true }).check(); await closeOptions(page).click();
  await expect(page.getByRole('button', { name: 'Next episode', exact: true })).toBeEnabled();
  await finishEpisode(page); await expect(page.locator('#autoplay-countdown')).toBeVisible();
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await page.waitForTimeout(8500); await expect(page.locator('#player')).toBeHidden();
  expect(await page.locator('#video').getAttribute('src')).toBeNull();
});

test('a late intro stays visible after idle controls hide and rejects timing beyond the decoded video', async ({ page }) => {
  await page.route(movieSegments, route => route.fulfill({ json: { Items: [{ Type: 'Intro', ItemId: 'movie-1', StartTicks: 60_000_000, EndTicks: 100_000_000 }] } }));
  await connect(page, 'late-intro'); await start(page); await page.locator('#video').focus();
  await expect(page.locator('#player')).toHaveAttribute('data-controls', 'hidden', { timeout: 7000 });
  const skip = page.getByRole('button', { name: 'Skip intro', exact: true });
  await expect(skip).toBeVisible({ timeout: 7000 });
  expect(await skip.evaluate(el => !!el.closest('[inert],[aria-hidden="true"]'))).toBe(false);
  await skip.click(); await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeGreaterThanOrEqual(10);
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await page.unroute(movieSegments);
  await page.route('**/Items/movie-1?*', async route => { const response = await route.fetch(); const item = await response.json(); delete item.RunTimeTicks; await route.fulfill({ response, json: item }); });
  await page.route(movieSegments, route => route.fulfill({ json: { Items: [{ Type: 'Intro', ItemId: 'movie-1', StartTicks: 0, EndTicks: 300_000_000 }] } }));
  await page.locator('.hero [data-action="play"]').click();
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeGreaterThan(.3);
  await expect(skip).toBeHidden();
});

test('a slow Previous request cannot be replaced by the old episode automatic Next', async ({ page }) => {
  await connect(page, 'selection-race'); await startEpisode(page);
  await page.getByRole('button', { name: 'Next episode', exact: true }).click();
  await expect(page.locator('#player-subtitle')).toContainText('S1 E2');
  await expect(page.getByRole('button', { name: 'Next episode', exact: true })).toBeEnabled();
  let release!: () => void; const pending = new Promise<void>(resolve => { release = resolve; });
  await page.route('**/Items/episode-1-1?*', async route => { await pending; await route.continue(); });
  let unwantedNext = 0;
  page.on('request', request => { if (new URL(request.url()).pathname === '/Items/episode-1-3') unwantedNext++; });
  await page.locator('#video').evaluate(el => { const video = el as HTMLVideoElement; video.currentTime = video.duration - 1; });
  await page.getByRole('button', { name: 'Previous episode', exact: true }).click();
  await expect(page.locator('#player')).toHaveAttribute('data-state', 'ended');
  await page.waitForTimeout(8500); expect(unwantedNext).toBe(0);
  await expect(page.locator('#player-subtitle')).toContainText('S1 E2');
  release();
  await expect(page.locator('#player-subtitle')).toContainText('S1 E1');
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeGreaterThan(.3);
});

for (const background of [false, true]) test(`late episode metadata reconciles a real EOF${background ? ' after a synthetic visibility cancellation' : ' with an actionable countdown'}`, async ({ page }) => {
  await connect(page, 'late-metadata-' + background);
  await page.getByRole('button', { name: 'Feature Out of the Blue', exact: true }).click();
  await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  await expect(page.locator('.episode-row[data-id="episode-1-1"] .episode-play')).toBeVisible();
  let release!: () => void; const pending = new Promise<void>(resolve => { release = resolve; });
  await page.route('**/Shows/series-7/Seasons?*', async route => { await pending; await route.continue(); });
  await page.locator('.episode-row[data-id="episode-1-1"] .episode-play').click();
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeGreaterThan(.3);
  if (background) await page.evaluate(() => {
    Object.defineProperty(document, 'hidden', { configurable: true, get: () => true }); document.dispatchEvent(new Event('visibilitychange'));
  });
  await finishEpisode(page);
  if (background) await page.evaluate(() => {
    Object.defineProperty(document, 'hidden', { configurable: true, get: () => false }); document.dispatchEvent(new Event('visibilitychange'));
  });
  release();
  await expect(page.locator('#player-state').getByRole('button', { name: 'Below the surface', exact: true })).toBeVisible();
  if (background) {
    await expect(page.locator('#autoplay-countdown')).toBeHidden();
    await page.waitForTimeout(8500); await expect(page.locator('#player-subtitle')).toContainText('S1 E1');
  } else {
    await expect(page.locator('#autoplay-countdown')).toContainText('Next episode in');
    await page.getByRole('button', { name: 'Cancel auto-play', exact: true }).click();
  }
});

async function changePicture(page: Page, field: string, value: string): Promise<void> {
  await options(page).click(); await page.locator('#' + field).selectOption(value);
  await expect(page.locator('#player-format')).toBeHidden();
  await expect(page.locator('#player')).toHaveAttribute('data-state', /^(playing|paused)$/);
}
async function pausedAtFive(page: Page): Promise<void> {
  await start(page); await pause(page); await options(page).click();
  await page.getByLabel('Chapter', { exact: true }).selectOption('5'); await closeOptions(page).click();
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeCloseTo(5, 0);
}
test('picture and sound changes preserve paused position, source tracks and saved quality', async ({ page }, info) => {
  const requests: Record<string, unknown>[] = [];
  page.on('request', request => { if (request.url().includes('/PlaybackInfo') && request.method() === 'POST') requests.push(request.postDataJSON()); });
  await page.route('**/Items/movie-1?*', async route => {
    const response = await route.fetch(), item = await response.json();
    item.MediaSources.push({ ...item.MediaSources[0], Id: 'alternate-source', MediaStreams: [{ Type: 'Audio', Index: 3, DisplayTitle: 'Alternate audio' }, { Type: 'Subtitle', Index: 4, DisplayTitle: 'Alternate captions' }] });
    await route.fulfill({ response, json: item });
  });
  await connect(page, 'picture-sound', false, true); await pausedAtFive(page);
  await changePicture(page, 'player-quality', '8000000');
  expect(requests.at(-1)?.MaxStreamingBitrate).toBe(8_000_000);
  for (const [field, value, key, expected] of [['player-audio', '1', 'AudioStreamIndex', 1], ['player-subtitles', '2', 'SubtitleStreamIndex', 2], ['player-subtitles', '-1', 'SubtitleStreamIndex', -1]] as const) {
    await changePicture(page, field, value); expect(requests.at(-1)?.[key]).toBe(expected);
    expect(await page.locator('#video').evaluate(el => (el as HTMLVideoElement).paused)).toBe(true);
    await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeCloseTo(5, 0);
  }
  await changePicture(page, 'player-version', 'alternate-source');
  expect(requests.at(-1)?.MediaSourceId).toBe('alternate-source'); expect(requests.at(-1)?.AudioStreamIndex).toBeUndefined(); expect(requests.at(-1)?.SubtitleStreamIndex).toBe(-1);
  await options(page).click(); await expect(page.locator('#player-audio')).toContainText('Alternate audio'); await expect(page.locator('#player-audio')).toHaveValue('');
  await expect(page.locator('#player-subtitles')).toHaveValue('-1'); await expect(page.locator('.playback-details')).not.toHaveAttribute('open', '');
  await page.screenshot({ path: info.outputPath('picture-sound.png') }); await closeOptions(page).click();
  await changePicture(page, 'player-audio', '3'); expect(requests.at(-1)?.AudioStreamIndex).toBe(3);
  await changePicture(page, 'player-subtitles', '4'); expect(requests.at(-1)?.SubtitleStreamIndex).toBe(4);
  await changePicture(page, 'player-subtitles', ''); expect(requests.at(-1)?.SubtitleStreamIndex).toBeUndefined();
  await changePicture(page, 'player-quality', '2000000');
  expect(await page.locator('#video').evaluate(el => (el as HTMLVideoElement).paused)).toBe(true);
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeCloseTo(5, 0);
  await page.locator('#video').focus(); await page.keyboard.press('Space');
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).paused)).toBe(false);
  await changePicture(page, 'player-quality', '20000000');
  expect(await page.locator('#video').evaluate(el => (el as HTMLVideoElement).paused)).toBe(false);
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeGreaterThan(5.1);
  await page.getByRole('button', { name: 'Close player', exact: true }).click(); await page.reload(); await start(page); await options(page).click();
  await expect(page.locator('#player-quality')).toHaveValue('20000000');
});

test('failed picture changes support retry and previous options without losing paused position', async ({ page }) => {
  let fail = false, failureStatus = 503;
  await page.route('**/Items/movie-1/PlaybackInfo', route => fail ? route.fulfill({ status: failureStatus, json: { message: 'Synthetic unavailable stream' } }) : route.continue());
  await connect(page, 'picture-recovery'); await pausedAtFive(page); fail = true;
  await options(page).click(); await page.locator('#player-quality').selectOption('8000000');
  await expect(page.locator('#player')).toHaveAttribute('data-state', 'error');
  await expect(page.getByRole('button', { name: 'Use previous options', exact: true })).toBeVisible(); fail = false;
  await page.getByRole('button', { name: 'Retry from saved position', exact: true }).click();
  await expect(page.locator('#player')).toHaveAttribute('data-state', 'paused');
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeCloseTo(5, 0);
  fail = true; failureStatus = 403; await options(page).click(); await page.locator('#player-quality').selectOption('2000000');
  await expect(page.locator('#player')).toHaveAttribute('data-state', 'error'); fail = false;
  await page.getByRole('button', { name: 'Use previous options', exact: true }).click();
  await expect(page.locator('#player')).toHaveAttribute('data-state', 'paused');
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeCloseTo(5, 0);
  await options(page).click(); await expect(page.locator('#player-quality')).toHaveValue('8000000');
  expect(await page.evaluate(() => localStorage.getItem('reel.quality'))).toBe('8000000');
});

test('missing tracks are clear and closing a pending picture change fences late playback', async ({ page }) => {
  await page.route('**/Items/movie-1?*', async route => { const response = await route.fetch(), item = await response.json(); item.MediaSources[0].MediaStreams = []; await route.fulfill({ response, json: item }); });
  await connect(page, 'picture-stale'); await pausedAtFive(page); await options(page).click();
  await expect(page.locator('#player-audio')).toBeDisabled(); await expect(page.locator('#player-audio')).toContainText('No audio tracks'); await expect(page.locator('#player-version')).toHaveCount(0);
  await expect(page.locator('#player-subtitles')).toContainText('Off');
  let release!: () => void, received = false; const gate = new Promise<void>(resolve => { release = resolve; });
  await page.route('**/Items/movie-1/PlaybackInfo', async route => { received = true; await gate; try { await route.continue(); } catch { /* Request is intentionally cancelled by closing playback. */ } });
  await page.locator('#player-quality').selectOption('8000000'); await expect.poll(() => received).toBe(true);
  await options(page).click(); await expect(page.locator('#player-quality')).toBeDisabled(); await closeOptions(page).click();
  await page.getByRole('button', { name: 'Close player', exact: true }).click(); release();
  await expect(page.locator('#player')).toBeHidden(); await expect(page.locator('.hero h1')).toBeVisible();
  await page.waitForTimeout(400); expect(await page.locator('#video').evaluate(el => ({ paused: (el as HTMLVideoElement).paused, src: el.getAttribute('src') }))).toEqual({ paused: true, src: null });
});

test('fullscreen Close waits for exit and a rejected exit keeps recovery controls and focus reachable', async ({ page }) => {
  await connect(page, 'fullscreen-close-recovery'); await start(page); await pause(page);
  await page.getByRole('button', { name: 'Full screen', exact: true }).click();
  await expect.poll(() => page.evaluate(() => document.fullscreenElement?.id)).toBe('player');
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await expect(page.locator('#player')).toBeHidden();
  expect(await page.evaluate(() => document.fullscreenElement)).toBeNull();
  await expect(page.locator('.hero [data-action="play"]')).toBeFocused();
  await page.locator('.hero [data-action="play"]').click();
  await expect.poll(() => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime)).toBeGreaterThan(.3);
  await pause(page);
  await page.getByRole('button', { name: 'Full screen', exact: true }).click();
  await expect.poll(() => page.evaluate(() => document.fullscreenElement?.id)).toBe('player');
  await page.evaluate(() => { document.exitFullscreen = async () => { throw new Error('Owned one-time fullscreen exit rejection'); }; });
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await expect(page.locator('#player')).toBeVisible();
  await expect(page.getByText('Could not leave full screen. Use Exit full screen or try Close again.', { exact: true })).toBeVisible();
  await expect(page.locator('#content')).toHaveAttribute('inert', '');
  await expect(page.locator('#rail')).toHaveAttribute('inert', '');
  await expect(page.getByRole('button', { name: 'Close player', exact: true })).toBeFocused();
  await page.keyboard.press('Tab');
  expect(await page.evaluate(() => !!document.activeElement?.closest('#player'))).toBe(true);
  expect(await page.locator('#video').getAttribute('src')).toBeNull();
  await page.evaluate(() => { Reflect.deleteProperty(document, 'exitFullscreen'); });
  await page.getByRole('button', { name: 'Exit full screen', exact: true }).click();
  await expect.poll(() => page.evaluate(() => document.fullscreenElement === null)).toBe(true);
  await page.getByRole('button', { name: 'Close player', exact: true }).click();
  await expect(page.locator('#player')).toBeHidden();
  await expect(page.locator('.hero [data-action="play"]')).toBeFocused();
  expect(await page.locator('#video').getAttribute('src')).toBeNull();
});
