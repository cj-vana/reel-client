import { test, expect, type Page } from '@playwright/test';
import type { DesktopBridge, DesktopCode, DesktopInitialization } from '../../src/desktop.ts';

const fixture = 'http://127.0.0.1:18771';
type Ready = Extract<DesktopInitialization, { ok: true }>;
type TestState = {
  connectionMode: 'ok' | 'deferred' | 'io' | 'uncertain'; preferenceMode: 'ok' | 'deferred' | 'uncertain';
  writes: unknown[]; preferences: Array<{ quality: number; history: boolean; expectedRevision: number }>;
  acknowledgements: string[]; resolveInitial(): void; finishSave(code?: DesktopCode): void;
  finishPreference(): void; close(): void;
};
declare global { interface Window { __desktopQA: TestState } }
async function desktop(page: Page, state: 'ready' | 'locked' | 'corrupt' | 'unavailable' = 'ready', delayed = false): Promise<void> {
  await page.route('**/reel-config.js', pending => pending.fulfill({ contentType: 'application/javascript', body: "window.REEL_CONFIG={platform:'desktop',previewMode:true};" }));
  await page.addInitScript(({ state, delayed }) => {
    const initial: Ready = { ok: true, storeState: state, ...(state === 'ready' ? { revision: 0, savedConnections: { accounts: [], activeId: null } } : {}), deviceId: '12345678-1234-1234-1234-123456789abc', preferences: { quality: 120000000, history: false }, preferenceRevision: 0 };
    let initialize!: () => void, complete!: (code?: DesktopCode) => void, preference!: () => void, close: (nonce: string) => void = () => {};
    const waiting = new Promise<void>(done => { initialize = done; });
    const qa: TestState = { connectionMode: 'ok', preferenceMode: 'ok', writes: [], preferences: [], acknowledgements: [], resolveInitial: () => initialize(), finishSave: code => complete(code), finishPreference: () => preference(), close: () => close('12345678-1234-1234-1234-123456789abc') };
    const bridge: DesktopBridge = {
      initialize: async () => { if (delayed) await waiting; return structuredClone(initial); },
      saveConnections: async value => {
        qa.writes.push(structuredClone(value));
        const code = qa.connectionMode === 'deferred' ? await new Promise<DesktopCode | undefined>(done => { complete = done; }) : qa.connectionMode === 'ok' ? undefined : qa.connectionMode;
        if (code) return { ok: false, code };
        initial.revision = value.expectedRevision + 1; initial.savedConnections = { accounts: value.accounts, activeId: value.activeId };
        return { ok: true, revision: initial.revision };
      },
      savePreferences: async value => { qa.preferences.push(structuredClone(value)); if (qa.preferenceMode === 'deferred') await new Promise<void>(done => { preference = done; }); if (qa.preferenceMode === 'uncertain') return { ok: false, code: 'uncertain' }; initial.preferenceRevision = value.expectedRevision + 1; return { ok: true, revision: initial.preferenceRevision }; },
      onCloseRequested: callback => { close = callback; return () => {}; },
      acknowledgeClose: async nonce => { qa.acknowledgements.push(nonce); return { ok: true }; }
    };
    Object.defineProperty(window, 'ReelDesktop', { value: Object.freeze(bridge) }); window.__desktopQA = qa;
  }, { state, delayed });
}
async function login(page: Page, name: string, remember = false): Promise<void> {
  await page.getByLabel('Server address', { exact: true }).fill(fixture);
  await page.getByLabel('Username', { exact: true }).fill(name);
  await page.getByLabel('Password', { exact: true }).fill('demo');
  if (remember) await page.getByLabel('Remember this connection on this device').check();
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
}
async function connectionControls(page: Page, busy: boolean): Promise<void> {
  for (const selector of ['[name=server]', '[name=username]', '[name=password]', '[name=remember]', 'button[type=submit]']) {
    const control = page.locator('#connect-form').locator(selector);
    if (busy) await expect(control).toBeDisabled(); else await expect(control).toBeEnabled();
  }
  for (const button of await page.locator('.saved-connections button').all()) { if (busy) await expect(button).toBeDisabled(); else await expect(button).toBeEnabled(); }
}
test.beforeEach(async ({ request }) => { await request.post(fixture + '/qa/reset'); });

for (const partial of [false, true]) test(`desktop ${partial ? 'partial' : 'missing'} preload fails visibly without browser-storage fallback`, async ({ page, request }) => {
  await page.route('**/reel-config.js', pending => pending.fulfill({ contentType: 'application/javascript', body: "window.REEL_CONFIG={platform:'desktop',previewMode:true};" }));
  if (partial) await page.addInitScript(() => { Object.defineProperty(window, 'ReelDesktop', { value: { initialize: async () => ({ ok: true }) } }); });
  await page.goto('/'); await expect(page.getByRole('heading', { name: 'Reel could not open.' })).toBeVisible();
  await expect(page.locator('#connect-form')).toHaveCount(0);
  expect(await page.evaluate(() => localStorage.getItem('reel.connections.v1'))).toBeNull();
  await page.getByRole('button', { name: 'Try again', exact: true }).click(); await expect(page.getByRole('heading', { name: 'Reel could not open.' })).toBeVisible();
  const state = await (await request.get(fixture + '/qa/state')).json(); expect(state.calls.some((call: { path: string }) => call.path.includes('/Users/') || call.path.includes('/System/'))).toBe(false);
});

test('desktop secure initialization has a real loading state and close before boot fences all API work', async ({ page, request }) => {
  await desktop(page, 'ready', true); await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Opening your secure connections.' })).toBeVisible(); await expect(page.locator('#connect-form')).toHaveCount(0);
  await page.evaluate(() => window.__desktopQA.close()); await expect.poll(() => page.evaluate(() => window.__desktopQA.acknowledgements.length)).toBe(1);
  await page.evaluate(() => window.__desktopQA.resolveInitial()); await expect(page.locator('#connect-form')).toHaveCount(0);
  const state = await (await request.get(fixture + '/qa/state')).json(); expect(state.calls.some((call: { path: string }) => call.path.includes('/Users/') || call.path.includes('/System/'))).toBe(false);
});

test('desktop delayed initialization publishes login only after the secure snapshot is ready', async ({ page }) => {
  await desktop(page, 'ready', true); await page.goto('/'); await expect(page.getByRole('heading', { name: 'Opening your secure connections.' })).toBeVisible();
  await page.evaluate(() => window.__desktopQA.resolveInitial()); await expect(page.locator('#connect-form')).toBeVisible(); await expect(page.getByLabel('Remember this connection on this device')).toBeEnabled();
});

for (const state of ['locked', 'corrupt', 'unavailable'] as const) test(`desktop ${state} state disables Remember and supports explicit session-only sign-in`, async ({ page }) => {
  await desktop(page, state); await page.goto('/');
  await expect(page.getByLabel('Remember this connection on this device')).toBeDisabled();
  await expect(page.locator('.connect-form .field-note').first()).toContainText(state === 'unavailable' ? 'unavailable' : state === 'locked' ? 'remain saved' : 'have not been changed');
  await page.getByLabel('Server address', { exact: true }).fill(fixture); await page.getByLabel('Username', { exact: true }).fill('nonready-error'); await page.getByLabel('Password', { exact: true }).fill('wrong');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click(); await expect(page.locator('#connection-error')).not.toBeEmpty(); await expect(page.getByLabel('Remember this connection on this device')).toBeDisabled();
  for (const selector of ['[name=server]', '[name=username]', '[name=password]', 'button[type=submit]']) await expect(page.locator('#connect-form').locator(selector)).toBeEnabled();
  await login(page, 'session-' + state); await expect(page.locator('.hero')).toBeVisible(); expect(await page.evaluate(() => window.__desktopQA.writes.length)).toBe(0);
  expect(await page.evaluate(() => localStorage.getItem('reel.connections.v1'))).toBeNull(); await page.reload(); await expect(page.locator('#connect-form')).toBeVisible();
});

test('desktop encrypted-commit wait disables navigation and ordinary IO failure cleans provisional authentication before retry', async ({ page, request }) => {
  await desktop(page); await page.goto('/'); await page.evaluate(() => { window.__desktopQA.connectionMode = 'deferred'; }); await login(page, 'save-retry', true);
  await expect.poll(() => page.evaluate(() => window.__desktopQA.writes.length)).toBe(1);
  await connectionControls(page, true);
  await expect(page.getByRole('button', { name: 'Connecting…', exact: true })).toBeDisabled(); await expect(page.getByRole('button', { name: 'Settings', exact: true })).toBeDisabled();
  await page.evaluate(() => window.__desktopQA.finishSave('io')); await expect(page.locator('#connection-error')).toContainText('could not save');
  await expect.poll(async () => (await (await request.get(fixture + '/qa/state')).json()).calls.filter((call: { path: string; user: string }) => call.path === '/Sessions/Logout' && call.user === 'save-retry').length).toBe(1);
  await expect(page.getByRole('button', { name: 'Sign in', exact: true })).toBeEnabled(); await page.evaluate(() => { window.__desktopQA.connectionMode = 'ok'; });
  await connectionControls(page, false);
  await page.getByLabel('Password', { exact: true }).fill('demo'); await page.getByRole('button', { name: 'Sign in', exact: true }).click(); await expect(page.locator('.hero')).toBeVisible();
  expect(await page.evaluate(() => localStorage.getItem('reel.connections.v1'))).toBeNull();
});

test('remembering an already active session still opens Home after the encrypted commit', async ({ page }) => {
  await desktop(page); await page.goto('/'); await login(page, 'upgrade-session'); await expect(page.locator('.hero')).toBeVisible();
  await page.getByRole('button', { name: 'Servers', exact: true }).click(); await login(page, 'upgrade-session', true); await expect(page.locator('.hero')).toBeVisible();
  expect(await page.evaluate(() => window.__desktopQA.writes.length)).toBe(1);
});

test('desktop uncertain auth save quarantines controls and retains the potentially stored token', async ({ page, request }) => {
  await desktop(page); await page.goto('/'); await page.evaluate(() => { window.__desktopQA.connectionMode = 'uncertain'; }); await login(page, 'uncertain-auth', true);
  await expect(page.getByRole('heading', { name: 'Quit and reopen Reel.' })).toBeVisible(); await expect(page.getByRole('button', { name: 'Settings', exact: true })).toBeDisabled();
  await expect(page.locator('#connect-form')).toHaveCount(0); await expect(page.locator('#content')).toContainText('saved state may have changed');
  const state = await (await request.get(fixture + '/qa/state')).json(); expect(state.calls.filter((call: { path: string }) => call.path === '/Sessions/Logout')).toHaveLength(0); expect(await page.evaluate(() => window.__desktopQA.writes.length)).toBe(1);
});

test('desktop uncertain preferences quarantine later writes in the actual settings UI', async ({ page }) => {
  await desktop(page); await page.goto('/'); await login(page, 'uncertain-remove', true); await expect(page.locator('.hero')).toBeVisible();
  await page.getByRole('button', { name: 'Settings', exact: true }).click(); await page.evaluate(() => { window.__desktopQA.preferenceMode = 'uncertain'; }); await page.locator('#quality').selectOption('2000000');
  await expect(page.getByRole('heading', { name: 'Quit and reopen Reel.' })).toBeVisible(); expect(await page.evaluate(() => window.__desktopQA.preferences.length)).toBe(1);
  await expect(page.getByRole('button', { name: 'Settings', exact: true })).toBeDisabled(); await expect(page.locator('#quality')).toHaveCount(0);
});

test('desktop uncertain removal does not revoke the account from its old snapshot', async ({ page, request }) => {
  await desktop(page); await page.goto('/'); await login(page, 'uncertain-remove', true); await expect(page.locator('.hero')).toBeVisible(); await page.getByRole('button', { name: 'Servers', exact: true }).click();
  await page.evaluate(() => { window.__desktopQA.connectionMode = 'uncertain'; }); await page.getByRole('button', { name: 'Sign out', exact: true }).click(); await expect(page.getByRole('heading', { name: 'Quit and reopen Reel.' })).toBeVisible();
  const state = await (await request.get(fixture + '/qa/state')).json(); expect(state.calls.filter((call: { path: string }) => call.path === '/Sessions/Logout')).toHaveLength(0);
});

test('desktop ordered preference controls drain history-off before close acknowledgement', async ({ page }) => {
  await desktop(page); await page.goto('/'); await login(page, 'ordered-prefs'); await expect(page.locator('.hero')).toBeVisible(); await page.getByRole('button', { name: 'Settings', exact: true }).click();
  await page.evaluate(() => { window.__desktopQA.preferenceMode = 'deferred'; }); await page.locator('#history').uncheck(); await expect.poll(() => page.evaluate(() => window.__desktopQA.preferences.length)).toBe(1);
  await page.locator('#history').check(); await page.evaluate(() => window.__desktopQA.close()); expect(await page.evaluate(() => window.__desktopQA.acknowledgements.length)).toBe(0);
  await page.evaluate(() => { window.__desktopQA.preferenceMode = 'ok'; window.__desktopQA.finishPreference(); });
  await expect.poll(() => page.evaluate(() => window.__desktopQA.acknowledgements.length)).toBe(1); expect(await page.evaluate(() => window.__desktopQA.preferences.map(value => [value.expectedRevision, value.history]))).toEqual([[0, true], [1, false]]);
});

test('EOF keeps one pending resource cleanup owned until sign-out can revoke the session', async ({ page, request }) => {
  await page.goto('/'); await login(page, 'eof-owner', true); await expect(page.locator('.hero')).toBeVisible();
  let release!: () => void, attempts = 0; const pending = new Promise<void>(done => { release = done; });
  await page.route('**/Videos/ActiveEncodings?*', async route => { attempts++; await pending; await route.continue(); });
  await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click(); await expect.poll(() => page.locator('#video').evaluate(video => (video as HTMLVideoElement).currentTime)).toBeGreaterThan(.2);
  await page.locator('#video').focus(); await page.keyboard.press('ArrowRight'); await expect(page.getByRole('heading', { name: 'Finished watching', exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Back to the library', exact: true }).click(); await page.getByRole('button', { name: 'Servers', exact: true }).click(); await page.getByRole('button', { name: 'Sign out', exact: true }).click();
  try { await expect(page.getByRole('button', { name: 'Sign out', exact: true })).toBeDisabled(); expect(attempts).toBe(1); const state = await (await request.get(fixture + '/qa/state')).json(); expect(state.calls.filter((call: { path: string }) => call.path === '/Sessions/Logout')).toHaveLength(0); }
  finally { release(); }
  await expect(page.locator('.saved-connections article')).toHaveCount(0); expect(attempts).toBe(1);
});

test('inactive account sign-out waits earlier cleanup across a new active connection', async ({ page, request }) => {
  await page.goto('/'); await login(page, 'drain-a', true); await expect(page.locator('.hero')).toBeVisible();
  let release!: () => void; const pending = new Promise<void>(done => { release = done; });
  await page.route('**/Videos/ActiveEncodings?*', async route => { await pending; await route.continue(); });
  await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click(); await expect.poll(() => page.locator('#video').evaluate(video => (video as HTMLVideoElement).currentTime)).toBeGreaterThan(.2);
  const cleanup = page.waitForRequest('**/Videos/ActiveEncodings?*'); await page.getByRole('button', { name: 'Close player', exact: true }).click(); await cleanup;
  await page.getByRole('button', { name: 'Servers', exact: true }).click(); await login(page, 'second', true); await expect(page.locator('.connection-button strong')).toHaveText('Sam'); await page.getByRole('button', { name: 'Servers', exact: true }).click();
  const accountA = page.locator('.saved-connections article').filter({ hasText: 'Alex' }); await accountA.getByRole('button', { name: 'Sign out', exact: true }).click();
  try { await expect(accountA.getByRole('button', { name: 'Sign out', exact: true })).toBeDisabled(); const state = await (await request.get(fixture + '/qa/state')).json(); expect(state.calls.filter((call: { path: string; user: string }) => call.path === '/Sessions/Logout' && call.user === 'drain-a')).toHaveLength(0); }
  finally { release(); }
  await expect(accountA).toHaveCount(0); await expect(page.locator('.connection-button strong')).toHaveText('Sam');
  await expect.poll(async () => (await (await request.get(fixture + '/qa/state')).json()).calls.filter((call: { path: string; user: string }) => call.path === '/Sessions/Logout' && call.user === 'drain-a').length).toBe(1);
});

test('inactive removal preserves active-account queued watch reports and current history policy', async ({ page, request }) => {
  await page.goto('/'); await login(page, 'inactive-history-a', true); await expect(page.locator('.hero')).toBeVisible(); await page.getByRole('button', { name: 'Servers', exact: true }).click();
  await login(page, 'second', true); await expect(page.locator('.hero')).toBeVisible(); await page.getByRole('button', { name: 'Settings', exact: true }).click(); await page.locator('#history').uncheck();
  let unavailable = true, attempts = 0;
  await page.route('**/Sessions/Playing/Stopped', async route => { attempts++; if (unavailable) await route.fulfill({ status: 503, json: {} }); else await route.continue(); });
  await page.getByRole('button', { name: 'Home', exact: true }).click(); await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click();
  await expect.poll(() => page.locator('#video').evaluate(video => (video as HTMLVideoElement).currentTime)).toBeGreaterThan(.2);
  await page.getByRole('button', { name: 'Close player', exact: true }).click(); await expect.poll(() => attempts).toBe(1);
  await page.getByRole('button', { name: 'Servers', exact: true }).click(); await page.locator('.saved-connections article').filter({ hasText: 'Alex' }).getByRole('button', { name: 'Sign out', exact: true }).click();
  await expect(page.locator('.saved-connections article')).toHaveCount(1); await expect(page.locator('.connection-button strong')).toHaveText('Sam');
  unavailable = false; await page.evaluate(() => window.dispatchEvent(new Event('online')));
  await expect.poll(async () => (await (await request.get(fixture + '/qa/state')).json()).reports.filter((report: { path: string; user: string }) => report.path === '/Sessions/Playing/Stopped' && report.user === 'second').length).toBe(1);
});

test('connection controls stay disabled through authentication and recover after success', async ({ page }) => {
  await page.goto('/'); await login(page, 'control-a', true); await expect(page.locator('.hero')).toBeVisible(); await page.getByRole('button', { name: 'Servers', exact: true }).click();
  let release!: () => void; const pending = new Promise<void>(done => { release = done; });
  await page.route('**/Users/AuthenticateByName', async route => { await pending; await route.continue(); });
  await login(page, 'second', true); try { await connectionControls(page, true); } finally { release(); }
  await expect(page.locator('.connection-button strong')).toHaveText('Sam'); await page.getByRole('button', { name: 'Servers', exact: true }).click(); await connectionControls(page, false);
});

test('connection controls prevent lost next-login input while sign-out waits for resource cleanup', async ({ page }) => {
  await page.goto('/'); await login(page, 'control-signout', true); await expect(page.locator('.hero')).toBeVisible();
  let release!: () => void; const pending = new Promise<void>(done => { release = done; }); await page.route('**/Videos/ActiveEncodings?*', async route => { await pending; await route.continue(); });
  await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click(); await expect.poll(() => page.locator('#video').evaluate(video => (video as HTMLVideoElement).currentTime)).toBeGreaterThan(.2);
  const cleanup = page.waitForRequest('**/Videos/ActiveEncodings?*'); await page.getByRole('button', { name: 'Close player', exact: true }).click(); await cleanup;
  await page.getByRole('button', { name: 'Servers', exact: true }).click(); await page.getByRole('button', { name: 'Sign out', exact: true }).click(); try { await connectionControls(page, true); } finally { release(); }
  await expect(page.locator('.saved-connections article')).toHaveCount(0); await connectionControls(page, false); await login(page, 'second'); await expect(page.locator('.connection-button strong')).toHaveText('Sam');
});

test('connection controls stay disabled while switching drains the old active account', async ({ page }) => {
  await page.goto('/'); await login(page, 'control-switch', true); await expect(page.locator('.hero')).toBeVisible(); await page.getByRole('button', { name: 'Servers', exact: true }).click(); await login(page, 'second', true); await expect(page.locator('.hero')).toBeVisible();
  let release!: () => void; const pending = new Promise<void>(done => { release = done; }); await page.route('**/Videos/ActiveEncodings?*', async route => { await pending; await route.continue(); });
  await page.locator('.hero').getByRole('button', { name: 'Play', exact: true }).click(); await expect.poll(() => page.locator('#video').evaluate(video => (video as HTMLVideoElement).currentTime)).toBeGreaterThan(.2);
  const cleanup = page.waitForRequest('**/Videos/ActiveEncodings?*'); await page.getByRole('button', { name: 'Close player', exact: true }).click(); await cleanup;
  await page.getByRole('button', { name: 'Servers', exact: true }).click(); await page.getByRole('button', { name: 'Open', exact: true }).click(); try { await connectionControls(page, true); } finally { release(); }
  await expect(page.locator('.connection-button strong')).toHaveText('Alex'); await page.getByRole('button', { name: 'Servers', exact: true }).click(); await connectionControls(page, false);
});

test('connection controls remain owned through delayed Logout before a later authentication begins', async ({ page }) => {
  await page.goto('/'); await login(page, 'delayed-logout', true); await expect(page.locator('.hero')).toBeVisible(); await page.getByRole('button', { name: 'Servers', exact: true }).click();
  let releaseLogout!: () => void; const logout = new Promise<void>(done => { releaseLogout = done; }); await page.route('**/Sessions/Logout', async route => { await logout; await route.continue(); });
  const sent = page.waitForRequest('**/Sessions/Logout'); await page.getByRole('button', { name: 'Sign out', exact: true }).click(); await sent;
  try { await connectionControls(page, true); await expect(page.locator('#connection-status')).toBeVisible(); await expect(page.locator('.saved-connections article')).toHaveCount(1); }
  finally { releaseLogout(); }
  await expect(page.locator('.saved-connections article')).toHaveCount(0); await connectionControls(page, false); await expect(page.locator('#connection-status')).toBeHidden();
  let releaseAuth!: () => void; const auth = new Promise<void>(done => { releaseAuth = done; }); await page.route('**/Users/AuthenticateByName', async route => { await auth; await route.continue(); });
  await login(page, 'second'); try { await connectionControls(page, true); } finally { releaseAuth(); }
  await expect(page.locator('.connection-button strong')).toHaveText('Sam');
});

test('uncertain preference recovery survives an inactive sign-out finishing later', async ({ page }) => {
  await desktop(page); await page.goto('/'); await login(page, 'quarantine-a', true); await expect(page.locator('.hero')).toBeVisible();
  await page.getByRole('button', { name: 'Servers', exact: true }).click(); await login(page, 'second', true); await expect(page.locator('.connection-button strong')).toHaveText('Sam');
  await page.getByRole('button', { name: 'Settings', exact: true }).click(); await page.evaluate(() => { window.__desktopQA.preferenceMode = 'deferred'; });
  await page.locator('#quality').selectOption('2000000'); await expect.poll(() => page.evaluate(() => window.__desktopQA.preferences.length)).toBe(1);
  await page.locator('#quality').selectOption('8000000'); await page.getByRole('button', { name: 'Servers', exact: true }).click();
  let releaseLogout!: () => void; const logout = new Promise<void>(done => { releaseLogout = done; }); await page.route('**/Sessions/Logout', async route => { await logout; await route.continue(); });
  const sent = page.waitForRequest('**/Sessions/Logout'); await page.locator('.saved-connections article').filter({ hasText: 'Alex' }).getByRole('button', { name: 'Sign out', exact: true }).click(); await sent;
  const settled = page.waitForResponse('**/Sessions/Logout');
  try {
    await page.evaluate(() => window.__desktopQA.finishPreference()); await expect.poll(() => page.evaluate(() => window.__desktopQA.preferences.length)).toBe(2);
    await page.evaluate(() => { window.__desktopQA.preferenceMode = 'uncertain'; window.__desktopQA.finishPreference(); });
    await expect(page.getByRole('heading', { name: 'Quit and reopen Reel.' })).toBeVisible();
  } finally { releaseLogout(); }
  await (await settled).finished(); await page.evaluate(() => new Promise<void>(done => requestAnimationFrame(() => requestAnimationFrame(() => done()))));
  await expect(page.locator('#connection-status')).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Settings', exact: true })).toBeDisabled();
  await expect(page.getByRole('heading', { name: 'Quit and reopen Reel.' })).toBeVisible(); await expect(page.locator('#connect-form')).toHaveCount(0);
});
