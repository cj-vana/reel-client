// Runs the Playwright browser suite for apps/web against its synthetic fixture
// server and dev server. Run `npm run qa:prepare` and `npm run webos:stage`
// (plus the IPK inspection) in apps/web first.
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { projectRoot } from '../apps/web/scripts/source-revision.mjs';
import { assertPortFree, exited, ready, supervise } from './ci-processes.mjs';

if (process.env.REEL_CI_SYNTHETIC !== '1') throw new Error('Set REEL_CI_SYNTHETIC=1 to confirm the suite runs against synthetic fixtures only');

const ports = { app: 18770, fixture: 18771, notices: 18779 };
const unpacked = resolve(projectRoot, '.cache/package-unpacked');
const expectedNotices = await readFile(resolve(unpacked, 'THIRD_PARTY_NOTICES.txt'), 'utf8');
for (const port of Object.values(ports)) await assertPortFree(port);

await supervise(async start => {
  const fixture = start(process.execPath, ['scripts/fixture-server.mjs'], {
    cwd: projectRoot,
    env: { ...process.env, REEL_FIXTURE_PORT: String(ports.fixture), REEL_FIXTURE_MEDIA: resolve(projectRoot, '.cache/fixture') }
  });
  const app = start(process.execPath, ['node_modules/vite/bin/vite.js', '--host', '127.0.0.1'], { cwd: projectRoot });
  const notices = start(process.env.PYTHON ?? 'python3', ['-m', 'http.server', String(ports.notices), '--bind', '127.0.0.1', '--directory', unpacked], { cwd: projectRoot });
  await Promise.all([
    ready(fixture, ports.fixture, '/System/Info/Public', async response => (await response.json()).ServerName === 'Reel Test Library'),
    ready(app, ports.app, '/', async response => (await response.text()).includes('src/main.ts')),
    ready(notices, ports.notices, '/THIRD_PARTY_NOTICES.txt', async response => await response.text() === expectedNotices)
  ]);
  const tests = start(process.execPath, ['scripts/run-browser-checks.mjs', '--forbid-only', '--retries=0'], { cwd: projectRoot });
  if (await exited(tests) !== 0) throw new Error('Browser suite failed');
});
