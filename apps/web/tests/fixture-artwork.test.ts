import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { crc32 } from 'node:zlib';

test('fixture optional artwork preserves bytes, MIME, JPEG priority and SVG recovery', async t => {
  const media = await mkdtemp(resolve(tmpdir(), 'reel-fixture-artwork-'));
  t.after(() => rm(media, { recursive: true, force: true }));
  const artwork = resolve(media, 'artwork');
  await mkdir(artwork);
  const basePNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=', 'base64');
  const png = (kind: string, n: number) => {
    // A valid metadata chunk distinguishes route/index selection without artwork assets.
    const text = Buffer.from(`Fixture\0${kind}-${n}`);
    const chunk = Buffer.concat([Buffer.from('tEXt'), text]);
    const length = Buffer.alloc(4), checksum = Buffer.alloc(4);
    length.writeUInt32BE(text.length);
    checksum.writeUInt32BE(crc32(chunk));
    return Buffer.concat([basePNG.subarray(0, -12), length, chunk, checksum, basePNG.subarray(-12)]);
  };
  const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xd9]);
  await Promise.all(Array.from({ length: 6 }, (_, n) => ['poster', 'backdrop'].map(kind => writeFile(resolve(artwork, `${kind}-${n}.png`), png(kind, n)))).flat());

  const probe = createServer();
  probe.listen(0, '127.0.0.1');
  await once(probe, 'listening');
  const address = probe.address();
  assert.ok(address && typeof address === 'object');
  const port = address.port;
  await new Promise<void>((done, reject) => probe.close(error => error ? reject(error) : done()));
  const child = spawn(process.execPath, [fileURLToPath(new URL('../scripts/fixture-server.mjs', import.meta.url))], {
    env: { ...process.env, REEL_FIXTURE_MEDIA: media, REEL_FIXTURE_PORT: String(port) },
    stdio: ['ignore', 'pipe', 'pipe']
  });
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) {
      const closed = once(child, 'close');
      child.kill('SIGTERM');
      await closed;
    }
  });
  await new Promise<void>((done, reject) => {
    const timeout = setTimeout(() => reject(new Error('Fixture did not become ready')), 5000);
    child.once('error', error => { clearTimeout(timeout); reject(error); });
    child.once('exit', code => { clearTimeout(timeout); reject(new Error(`Fixture exited early: ${code}`)); });
    child.stdout.on('data', chunk => {
      if (String(chunk).includes('Disposable Reel fixture:')) { clearTimeout(timeout); done(); }
    });
  });
  const request = (path: string, user: string | null = 'demo') => fetch(`http://127.0.0.1:${port}${path}`, {
    headers: user ? { Authorization: `MediaBrowser Token="fixture-${user}"` } : {},
    signal: AbortSignal.timeout(5000)
  });
  const expectImage = async (path: string, type: string, bytes: Buffer) => {
    const response = await request(path);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('content-type'), type);
    assert.equal(response.headers.get('content-length'), String(bytes.length));
    assert.deepEqual(Buffer.from(await response.arrayBuffer()), bytes);
  };

  await t.test('every PNG poster and backdrop index returns original PNG bytes', async () => {
    for (let n = 0; n < 6; n++) {
      await expectImage(`/Items/movie-${n + 6}/Images/Primary`, 'image/png', png('poster', n));
      await expectImage(`/Items/movie-${n + 6}/Images/Backdrop`, 'image/png', png('backdrop', n));
    }
  });
  await t.test('JPEG retains priority when both formats are present', async () => {
    await writeFile(resolve(artwork, 'poster-1.jpg'), jpeg);
    await writeFile(resolve(artwork, 'backdrop-1.jpg'), jpeg);
    await expectImage('/Items/movie-1/Images/Primary', 'image/jpeg', jpeg);
    await expectImage('/Items/movie-1/Images/Backdrop', 'image/jpeg', jpeg);
  });
  await t.test('unreadable JPEG candidate falls through to PNG', async () => {
    await mkdir(resolve(artwork, 'poster-2.jpg'));
    await expectImage('/Items/movie-2/Images/Primary', 'image/png', png('poster', 2));
  });
  await t.test('missing optional artwork recovers with SVG for both image roles', async () => {
    for (const [kind, route, dimensions] of [['poster', 'Primary', 'width="600" height="900"'], ['backdrop', 'Backdrop', 'width="1440" height="810"']]) {
      await rm(resolve(artwork, `${kind}-3.png`));
      const response = await request(`/Items/movie-3/Images/${route}`);
      assert.equal(response.status, 200);
      assert.equal(response.headers.get('content-type'), 'image/svg+xml');
      assert.ok((await response.text()).includes(dimensions));
    }
  });
  await t.test('authorization and deliberate missing-art state still precede optional loading', async () => {
    const unauthorized = await request('/Items/movie-1/Images/Primary', null);
    assert.equal(unauthorized.status, 401);
    await unauthorized.arrayBuffer();
    const missing = await request('/Items/movie-1/Images/Primary', 'missingart');
    assert.equal(missing.status, 404);
    await missing.arrayBuffer();
  });
  await t.test('URL strings select a numeric index rather than a file path', async () => {
    await expectImage('/Items/%2e%2e%2foutside-4.png/Images/Primary', 'image/png', png('poster', 2));
  });
});
