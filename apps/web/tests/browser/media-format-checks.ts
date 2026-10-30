import { expect, type Page } from '@playwright/test';

export async function assertOpenFormatPanel(page: Page, viewport: { width: number; height: number }): Promise<void> {
  const bounds = await page.evaluate(() => {
    const read = (selector: string) => {
      const element = document.querySelector<HTMLElement>(selector)!, r = element.getBoundingClientRect();
      return { x: r.x, y: r.y, right: r.right, bottom: r.bottom, width: r.width, height: r.height,
        hitOwn: element.contains(document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2)) };
    };
    return { panel: read('#player-format'), close: read('[data-action="close-format"]') };
  });
  for (const rect of [bounds.close, bounds.panel]) {
    expect(rect.width).toBeGreaterThan(0); expect(rect.height).toBeGreaterThan(0);
    expect(rect.x).toBeGreaterThanOrEqual(0); expect(rect.y).toBeGreaterThanOrEqual(0);
    expect(rect.right).toBeLessThanOrEqual(viewport.width + .5); expect(rect.bottom).toBeLessThanOrEqual(viewport.height + .5);
  }
  expect(bounds.close.hitOwn).toBe(true);
  const panel = page.locator('#player-format'), data = page.locator('#player-format-data'), paused = await page.locator('#video').evaluate(element => (element as HTMLVideoElement).paused);
  const position = await page.locator('#video').evaluate(element => (element as HTMLVideoElement).currentTime);
  if (!(await data.isVisible())) await page.locator('.playback-details summary').click();
  await expect(data).toBeVisible();
  if (await data.evaluate(element => element.scrollHeight > element.clientHeight)) {
    await data.focus(); await page.keyboard.press('End');
    await expect.poll(() => data.evaluate(element => element.scrollTop)).toBeGreaterThan(0);
    if (paused) expect(await page.locator('#video').evaluate(element => (element as HTMLVideoElement).currentTime)).toBeCloseTo(position, 1);
  }
  await page.getByRole('button', { name: 'Close playback options', exact: true }).click(); await expect(panel).toBeHidden();
  await page.getByRole('button', { name: 'Playback options', exact: true }).click(); await expect(panel).toBeVisible();
  await page.keyboard.press('Escape'); await expect(panel).toBeHidden(); await expect(page.locator('#player')).toBeVisible();
}
