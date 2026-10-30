import { test, expect, type APIRequestContext, type Page } from '@playwright/test';

// The intro-scan account's episodes are 330 seconds of synthetic audio sharing one theme and one piece of credits
// music (scripts/intro-fixture.mjs). Episode 2's theme plays from 30 to 70 seconds and its credits from 282;
// episode 3's from 39 to 79 and from 285. The server marks no segments, so only the scan can find them.
const fixture = 'http://127.0.0.1:18771';
type Call = { path: string; user: string | null; query: Record<string, string> };

async function connect(page: Page, name: string): Promise<void> {
  await page.goto('/');
  for (const [label, value] of [['Server address', fixture], ['Username', 'intro-scan-' + name], ['Password', 'demo']]) await page.getByLabel(label, { exact: true }).fill(value);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.locator('.hero h1')).toBeVisible();
}
async function playEpisode(page: Page, id: string): Promise<void> {
  await page.getByRole('button', { name: 'Feature Out of the Blue', exact: true }).click();
  await page.locator('.hero').getByRole('button', { name: 'Details', exact: true }).click();
  await page.locator(`.episode-row[data-id="${id}"] .episode-play`).click();
  await expect.poll(() => position(page)).toBeGreaterThan(.3);
}
const position = (page: Page) => page.locator('#video').evaluate(el => (el as HTMLVideoElement).currentTime);
const seek = (page: Page, seconds: number) => page.locator('#video').evaluate((el, value) => { (el as HTMLVideoElement).currentTime = value; }, seconds);
// The scan has finished once the episode's credits result is saved; the intro is saved before it.
async function scanned(page: Page, id: string): Promise<void> {
  await expect.poll(() => page.evaluate(episode => {
    const saved = JSON.parse(localStorage.getItem('reel.markers.v1') ?? '{}') as Record<string, { c?: number }>;
    return Object.entries(saved).some(([key, entry]) => key.endsWith('|' + episode) && entry.c !== undefined);
  }, id), { timeout: 60_000 }).toBe(true);
}
async function scans(request: APIRequestContext, user: string): Promise<Call[]> {
  const state = await (await request.get(fixture + '/qa/state')).json() as { calls: Call[] };
  return state.calls.filter(call => call.user === 'intro-scan-' + user && /^\/Audio\/[^/]+\/stream\.mp3$/.test(call.path));
}

test('finds the intro and the credits from the audio when the server marks none', async ({ page, request }) => {
  test.setTimeout(90_000);
  await request.post(fixture + '/qa/reset');
  await connect(page, 'find'); await playEpisode(page, 'episode-1-2');
  // This episode's opening and closing minutes, then the next episode's, for the comparison.
  await scanned(page, 'episode-1-2');
  expect((await scans(request, 'find')).map(call => call.path + (call.query.starttimeticks ? ' tail' : '')))
    .toEqual(['/Audio/episode-1-2/stream.mp3', '/Audio/episode-1-3/stream.mp3', '/Audio/episode-1-2/stream.mp3 tail', '/Audio/episode-1-3/stream.mp3 tail']);
  for (const call of await scans(request, 'find')) {
    expect(call.query.playsessionid).toMatch(/^reel-scan-[0-9a-f]{24}$/);
    expect(call.query.deviceid).toBeUndefined();
  }
  const skip = page.getByRole('button', { name: 'Skip intro', exact: true });
  await expect(skip).toBeHidden();
  await seek(page, 35);
  await expect(skip).toBeVisible();
  await skip.click();
  await expect.poll(() => position(page)).toBeGreaterThan(68);
  await expect(skip).toBeHidden();
  const next = page.locator('#player-next-up');
  await seek(page, 270);
  await expect.poll(() => position(page)).toBeGreaterThan(270);
  await expect(next).toBeHidden();
  await seek(page, 290);
  await expect(next).toBeVisible();
  // The scanned neighbor was never reported as played.
  const reports = await (await request.get(fixture + '/qa/state')).json() as { reports: Array<{ user: string; body?: { ItemId?: string } }> };
  expect(reports.reports.filter(report => report.user === 'intro-scan-find' && report.body?.ItemId === 'episode-1-3')).toEqual([]);
  await next.click();
  await expect(page.locator('#player-subtitle')).toContainText('S1 E3');
  await expect.poll(() => position(page)).toBeGreaterThan(.3);
  // Episode 3's intro was learned from the same comparison, so it is ready at once and nothing more downloads.
  await seek(page, 45);
  await expect(skip).toBeVisible();
  await page.waitForTimeout(6000);
  expect((await scans(request, 'find')).length).toBe(4);
});

test('skips the intro on its own when asked, with a way back to it', async ({ page, request }) => {
  test.setTimeout(90_000);
  await request.post(fixture + '/qa/reset');
  await connect(page, 'auto');
  const destination = page.locator('#rail').getByRole('button', { name: 'Settings', exact: true });
  if (!await destination.isVisible()) await page.getByRole('button', { name: 'More', exact: true }).click();
  await destination.click();
  await expect(page.getByLabel('Find intros and credits')).toBeChecked();
  await page.getByLabel('Skip intros automatically').check();
  await page.locator('#rail').getByRole('button', { name: 'Home', exact: true }).click();
  await playEpisode(page, 'episode-1-2');
  // Paused, so playback cannot reach the intro before the scan finishes, however long it takes.
  await page.locator('#video').evaluate(el => { (el as HTMLVideoElement).pause(); });
  await scanned(page, 'episode-1-2');
  expect((await scans(request, 'auto')).length).toBe(4);
  await seek(page, 29);
  await page.locator('#video').evaluate(el => (el as HTMLVideoElement).play());
  const notice = page.locator('#player-intro-notice');
  await expect(notice).toBeVisible();
  await expect(notice).toContainText('Intro skipped');
  await expect.poll(() => position(page)).toBeGreaterThan(68);
  await notice.getByRole('button', { name: 'Watch it', exact: true }).click();
  await expect(notice).toBeHidden();
  await expect.poll(() => position(page)).toBeLessThan(34);
  // Once taken back, the intro plays; the button stays available.
  await expect(page.getByRole('button', { name: 'Skip intro', exact: true })).toBeVisible();
  await page.waitForTimeout(1500);
  expect(await position(page)).toBeLessThan(40);
});
