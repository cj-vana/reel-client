import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests/browser',
  fullyParallel: false,
  workers: 1,
  timeout: 45000,
  reporter: [['list'], ['json', { outputFile: '.cache/browser-results.json' }]],
  use: {
    baseURL: 'http://127.0.0.1:18770',
    viewport: { width: 1440, height: 900 },
    channel: 'chrome',
    headless: true,
    launchOptions: { chromiumSandbox: true, args: ['--autoplay-policy=no-user-gesture-required'] },
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure'
  }
});
